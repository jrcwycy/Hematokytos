# slurm/lr/

The four Slurm batch scripts for the long-read (Nanopore/PacBio) split-pipe
workflow. Each sources [`../lib/lr_common.sh`](../lib/lr_common.sh) (which
sources `common.sh` for the shared env / scratch / logging helpers and loads
`config/pipeline.config`), and each requires `REPO_ROOT` / `RUN_ID` in the
environment.

> These are **normally driven by `bin/lr_submit.sh`**, which discovers the fastq
> chunks, writes the manifest, and submits the stages below with the right
> resources, array range, and `--dependency` wiring — all with
> `sbatch --export=ALL`. You rarely call them by hand (the snippets here are for
> re-running a subset).

## The DAG

`refs` and `genpairs` run **concurrently** — `genpairs` (`LR_generate_pairs`) is
pure linker detection on raw reads and never touches the genome, so it does not
wait on the reference build. `finalize` depends on `afterok` of *both*.
`guesskit` is an **optional, off-DAG probe** you slot between them to pick the
kit empirically; `bin/lr_submit.sh` does not submit it.

```
   refs (1 job)                    genpairs[0..N-1]  (job ARRAY)
   ┌────────────────┐              ┌───────────────────────────┐
   │ split-pipe     │              │ one task per fastq chunk  │
   │   mkref (STAR) │  concurrent  │ LR_generate_pairs (edlib) │
   │ minimap2 -d    │   (no dep    │ -> split_R1 + split_R2    │
   │ GTF -> junc BED│    between)  └─────────────┬─────────────┘
   └───────┬────────┘                            │
           │        ┌·· guesskit (optional ··┐   │
           │        ·  --mode pre on subset  ·   │
           │        ·  -> kit_bc_scores.csv  ·   │
           │        └························┘   │
           └────────────────┬───────────────────┘
                            │  afterok (refs + genpairs)
                            ▼
                     finalize (1 job)
       concat ▸ pre ▸ minimap2 ▸ stats patch ▸ sam->bam ▸ post ▸ stage
                            │
                            ▼
                        RESULTS_DIR
```

---

## 1. refs — `00_refs.sbatch`

* **Type:** single job.
* **Inputs:** `FASTA_PATH`, `GTF_PATH`, `GENOME_NAME` (config).
* **Runs (once, into `$SHARED_BASE/refs/$GENOME_NAME/`):**
  1. `split-pipe --mode mkref` → STAR reference (`PARSE_GENOME_DIR`, used by
     `--mode pre`/`post`).
  2. `minimap2 -x $MM2_INDEX_PRESET -d` → long-read index (`MM2_INDEX`).
  3. GTF → `convert2bed` → junction BED (`JUNC_BED`, minimap2 `--junc-bed`).
* **Chromosome-prefix detail:** mkref prefixes chrom names with the genome name
  (`mkref_chr_geno_prefix=True`). The script reads the built `chrName.txt` to
  derive the *exact* prefix (e.g. `hg38_` or empty) and applies the **same**
  prefix to the minimap2 FASTA and the BED, or coordinates won't match the STAR
  reference.
* **Outputs / markers:** `PARSE_DONE` on the STAR dir + existence checks on the
  `.mmi` / `.bed` (sub-step idempotency), then a top-level
  `REFS_DONE` (= `$SHARED_BASE/refs/$GENOME_NAME/REFS_DONE`). Present `REFS_DONE`
  → the whole stage is skipped and reused.
* **Resources:** `REFS_CPUS` / `REFS_MEM` / `REFS_TIME` (default `16` / `64G` / `08:00:00`).

## 2. genpairs — `10_genpairs.sbatch`

* **Type:** **Slurm JOB ARRAY**, one task per fastq chunk. `$SLURM_ARRAY_TASK_ID`
  selects line `id+1` of the chunk manifest (`$WORK_DIR/chunks.txt`, written by
  `bin/lr_discover_chunks.sh`).
* **Inputs:** one fastq chunk per task; `CHEMISTRY`, `LR_L1DIST`, `LR_L2DIST`,
  `LR_PAIRS_SCRIPT` (config — must point at `LR_generate_pairs_*.py` from your
  own licensed split-pipe install).
* **Runs:** `python LR_generate_pairs_…py --fastq <chunk> --new_fname split
  --out_dir $WORK_DIR/pairs/<stem>/ --chemistry <v3> --l1dist --l2dist` — edlib
  linker detection splits each long read into `split_R1` (transcript) + `split_R2`
  (barcode). Each task writes to its **own** dir because `LR_generate_pairs` also
  emits fixed-name `unmatched.fastq` / `empty_cDNA.fastq` that would collide
  across concurrent tasks; those diagnostics are deleted, and the kept pair is
  `pigz`-compressed.
* **Outputs / markers:** `split_R1.fastq.gz` + `split_R2.fastq.gz` per chunk dir,
  with a per-chunk `PARSE_DONE` marker (`done_marker` → `$out/PARSE_DONE`). A
  chunk yielding zero pairs is a warning (empty-but-valid `.gz` kept so the array
  still completes `afterok`), not a failure.
* **Resources:** `GENPAIRS_CPUS` / `GENPAIRS_MEM` / `GENPAIRS_TIME` (default
  `2` / `8G` / `02:00:00`); array concurrency capped by `LR_ARRAY_THROTTLE`
  (default `100`, applied as `--array=0-(N-1)%THROTTLE`).

## 3. guesskit — `05_guesskit.sbatch` (optional probe)

* **Type:** single job, **off-DAG** (run by hand between genpairs and finalize;
  not submitted by `bin/lr_submit.sh`). Needs the STAR ref (refs) + some
  completed chunk pairs (genpairs).
* **Inputs:** completed chunk pairs under `$WORK_DIR/pairs/`; `PARSE_GENOME_DIR`,
  `CHEMISTRY`, `LR_PARFILE_LINES` (config).
* **Runs:** concatenates a **subset** of completed chunks (`LR_KIT_SAMPLE_CHUNKS`,
  default 30) into `$WORK_DIR/kitcheck/`, then `split-pipe --mode pre --one_step
  --kit <LR_KIT_PROBE, default WT>` on it — any valid probe kit, because scoring
  evaluates **all** kits.
* **Outputs:** `process/kit_bc_scores.csv` (copied to `$WORK_DIR/kit_bc_scores.csv`)
  scoring observed round-1 barcodes against every kit whitelist
  (`kits.guess_kit_from_bc`). The top score is the kit to pass to finalize as
  `KIT=` (WT vs WT_mini, etc). No completion marker.
* **Resources:** shares the finalize knobs (`FINAL_CPUS` / `FINAL_MEM` /
  `FINAL_TIME`) when launched via the staged-submission recipe.

## 4. finalize — `20_process.sbatch`

* **Type:** single job (runs after the array). There is **no `--mode comb`** —
  each run has only one sublibrary, so combine is unneeded.
* **Inputs:** the per-chunk pairs (genpairs), the references (`PARSE_GENOME_DIR`,
  `MM2_INDEX`, `JUNC_BED` — all asserted present), the chunk manifest, `KIT`,
  `CHEMISTRY`, `LR_PARFILE_LINES`, optional `SAMPLE_TABLE` (config).
* **Runs (7 sub-steps):** concat per-chunk pairs in stable manifest order →
  `split-pipe --mode pre --one_step` (barcode calling, with a `--parfile`) →
  `pigz` `barcode_head.fastq` → `minimap2 --MD -a -u f -x $MM2_XPRESET --junc-bed`
  (spliced alignment) → **patch** `process/pre_align_stats.csv` (add
  `reads_align_input`/`unique`/`multimap`; minimap2 doesn't write STAR's
  `Log.final.out`, but `--mode post` reads these) → `samtools view -b` →
  `process/barcode_headAligned.out.bam` → `split-pipe --mode post`
  (postprocess → mol → dge → reports) → `rsync` deliverables to `RESULTS_DIR`.
* **Outputs / markers:** `RESULTS_DIR/<LR_SUBLIB>/` (DGE matrices, reports), with
  **per-step markers** in `$WORK_DIR/sublib/<LR_SUBLIB>/`:
  | Marker | Step it gates |
  |---|---|
  | `PARSE_DONE_concat` | concat of all per-chunk pairs |
  | `PARSE_DONE_pre`    | `split-pipe --mode pre` (barcode calling) |
  | `PARSE_DONE`        | full completion (through `--mode post`) |

  A re-run reuses any step whose marker exists and picks up from there (delete a
  marker to force a clean redo of that step).
* **Resources:** `FINAL_CPUS` / `FINAL_MEM` / `FINAL_TIME` (default
  `16` / `64G` / `24:00:00`).

---

## Idempotency & re-running a subset

Every stage is restart-safe via markers (`REFS_DONE`, per-chunk `PARSE_DONE`, the
finalize per-step markers above), so re-submitting skips work that already
finished.

To re-run only failed **genpairs** array indices (manifest + scratch unchanged):

```bash
# which indices failed?
sacct -j <genpairsJobId> --format=JobID,State,ExitCode | grep -v COMPLETED
# resubmit just those:
REPO_ROOT=$PWD RUN_ID=<run> LR_CHUNK_MANIFEST=$WORK_DIR/chunks.txt \
  sbatch --account=<acct> --export=ALL --array=3,7,11 10_genpairs.sbatch
```

To resume **finalize**, re-submit it (`bin/lr_submit.sh --finalize-only`, or
`sbatch 20_process.sbatch` with `REPO_ROOT`/`RUN_ID` exported); completed steps
are skipped via their markers.

See [`../../docs/longread-pipeline.md`](../../docs/longread-pipeline.md) for the
full procedure, the `pre_align_stats.csv` rationale, and version-porting notes,
and [`../README.md`](../README.md) for the batch-script overview.
