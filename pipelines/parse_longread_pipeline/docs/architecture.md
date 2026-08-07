# Architecture

How this repo turns Parse's `split-pipe` into a parallel, long-read-capable
Slurm pipeline.

## Why a separate long-read path

`split-pipe`'s standard mode (`--mode all`) expects paired short (Illumina)
reads — `R1` (barcode) / `R2` (cDNA) — aligned with STAR. Long-read data
(Oxford Nanopore, PacBio) doesn't have that structure: each read carries the
cDNA *and* the cell barcode/UMI together, behind two known linker sequences,
and needs a splice-aware long-read aligner rather than STAR. This pipeline
reformats each long read into a synthetic short-read-style pair and drives
`split-pipe` through it, substituting `minimap2` for STAR at the alignment
step — following Parse's own published long-read procedure.

## The DAG

`bin/lr_submit.sh` runs on a login node and submits a Slurm dependency DAG. It
does **no** heavy work itself — it discovers fastq chunks, writes a manifest,
and wires the jobs together with `--dependency`.

```
                              (no dependency between them)
   ┌──────────────────┐                          ┌───────────────────────────┐
   │     refs         │  ‖  CONCURRENT WITH  ‖    │      genpairs[]           │
   │ 1 job            │                          │  job ARRAY, 1/fastq chunk  │
   │ mkref + minimap2 │                          │  LR_generate_pairs/chunk   │
   │ index + junc BED │                          │  (edlib linker split)      │
   └────────┬─────────┘                          └─────────────┬─────────────┘
            └───────────────────┬───────────────────────────────┘
                                │  afterok (BOTH)
                                ▼
                            finalize (1 job)
            concat ▸ pre ▸ minimap2 ▸ stats patch ▸ sam->bam ▸ post ▸ stage
```

* **refs runs concurrently with genpairs.** `LR_generate_pairs` only does edlib
  linker detection on the raw reads — it never touches the genome — so the array
  has no reason to wait on the reference build. `lr_submit.sh` submits both and
  gates `finalize` on `afterok` of *both*. refs is skipped if a `REFS_DONE`
  marker already exists in the shared reference folder.
* **finalize** is a single job (only one sublibrary, so no `--mode comb`
  merge step). It concatenates the per-chunk pairs, then runs `split-pipe
  --mode pre`, minimap2 spliced alignment, a `pre_align_stats.csv` patch
  (minimap2 doesn't write STAR's `Log.final.out`, which `--mode post` reads),
  sam→bam, `--mode post`, and stages the deliverables.
* **guesskit** (optional, off-DAG) — an empirical probe you can run between
  genpairs and finalize to determine the Parse kit from the data instead of
  assuming it. Not submitted by `lr_submit.sh`; see
  [`../slurm/lr/README.md`](../slurm/lr/README.md).

See [`longread-pipeline.md`](longread-pipeline.md) for the full stage-by-stage
guide.

## Scratch-first I/O

Heavy, churny, and temporary data must not live on slow/persistent storage.
Heavy intermediates live on **per-user scratch** (`WORK_DIR`); the reference
and the deliverables live in a **group-shared** folder so they're reused/shared
across runs and users.

```
WORK_DIR = SCRATCH_BASE/parse_lr_demux/<RUN_ID>/    ← per-user fast scratch
├── tmp/                                            ← $TMPDIR
├── chunks.txt                                      ← chunk manifest (run-defining)
├── pairs/<chunk>/                                  ← one per array task
│     split_R1.fastq.gz, split_R2.fastq.gz, PARSE_DONE
├── sublib/<sublib>/                                ← finalize working tree
│     concat_split_R{1,2}.fastq.gz, parfile.txt,
│     process/ (barcode_head, *.bam, pre_align_stats.csv, DGE_*, report),
│     PARSE_DONE_concat, PARSE_DONE_pre, PARSE_DONE
├── kitcheck/                                       ← guesskit subset + scores
└── logs/                                           ← refs/genpairs[]/finalize stdout

SHARED_BASE = <shared scratch>/parse/
├── refs/<GENOME_NAME>/                             ← built once, reused (REFS_DONE)
│     star/ (split-pipe mkref), minimap2/*.mmi, minimap2/*.genes.bed
└── analysis/<RUN_ID>/<sublib>/                     ← RESULTS_DIR (staged deliverables)
```

`slurm/lib/common.sh:setup_scratch()` creates `WORK_DIR` and points `TMPDIR`
there for every job. The finalize stage rsyncs the deliverables to
`RESULTS_DIR` as its last step. Scratch is fast and large but often **purged**
on a schedule — `RESULTS_DIR` on the shared/persistent volume is the durable
copy.

## Why a login-node controller (not a job that submits jobs)

Submitting the DAG from the login node with `--dependency` is the portable,
scheduler-native pattern: the array gets true multi-node parallelism, Slurm
enforces ordering, and you can re-submit any single stage. Having a running job
spawn its own children is fragile (and disallowed on some clusters). The
controller here is a thin shell script; the cluster does the real work.

## Consistency across jobs

`lr_submit.sh` pins `RUN_ID` once, sources and re-exports the resolved config
(`set -a; source config; set +a`), and submits every job with `--export=ALL`.
So refs, every array task, and finalize compute identical paths (`WORK_DIR`,
etc.) and agree on kit/chemistry/reference — even if you overrode a value via
the environment at submit time. Each `.sbatch` re-sources the same config from
`$REPO_ROOT` (passed in the environment, because an sbatch job runs from a
Slurm spool copy where `$0` no longer points at the repo).

## Parallelism

* **Across chunks** — genpairs is a job ARRAY sized `0..N-1` (one task per
  fastq chunk), throttled to `LR_ARRAY_THROTTLE` (default 100) concurrent
  tasks. This is the wide fan-out; each task is light (single-threaded edlib).
* **refs concurrent with genpairs** — the reference build (the other long
  step) overlaps the entire array instead of serializing before it.
* **Within finalize** — `split-pipe`, minimap2, and samtools all use
  `--nthreads = FINAL_CPUS`; spliced alignment is the bottleneck there.

## Failure handling & re-runs

* **Per-chunk `PARSE_DONE`.** Each genpairs task drops a `PARSE_DONE` marker in
  its `pairs/<chunk>/` dir and skips if it's already there — so re-running only
  the failures is just `sbatch --array=<failed ids> slurm/lr/10_genpairs.sbatch`
  (manifest + scratch unchanged). A chunk that yields zero pairs is a warning,
  not a failure, so the array still satisfies `afterok`.
* **Finalize step markers.** Finalize is resumable at sub-step granularity:
  `PARSE_DONE_concat` (concat done), `PARSE_DONE_pre` (`--mode pre` done), and
  `PARSE_DONE` (full completion). A re-run reuses whatever's marked and picks
  up from the first unfinished step; delete a marker to force that step to
  redo.

## Resource tuning

In `config/pipeline.config`:

| Stage | Knobs | Notes |
|---|---|---|
| refs | `REFS_CPUS/_MEM/_TIME` | human STAR index ≈ 40 GB RAM |
| genpairs | `GENPAIRS_CPUS/_MEM/_TIME`, `LR_ARRAY_THROTTLE` | light per-task, throttle for queue politeness |
| finalize | `FINAL_CPUS/_MEM/_TIME` | the heavy stage: alignment + postprocess |
