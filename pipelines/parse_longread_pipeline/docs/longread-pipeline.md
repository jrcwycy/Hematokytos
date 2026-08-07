# Long-read pipeline

A guide to running Parse Biosciences' `split-pipe` on **long-read**
(Oxford Nanopore / PacBio) data, driven by `bin/lr_submit.sh` +
`slurm/lr/*.sbatch`.

## Why long-read needs a different path

`split-pipe`'s standard short-read path (`--mode all`, STAR) expects paired
Illumina `R1`/`R2` files per sublibrary. Long-read data doesn't fit that
shape:

* there are no paired `*_R1_*` / `*_R2_*` files — long-read fastq input is a
  flat set of basecalled chunks, all belonging to **one** Parse sublibrary;
* the cell barcode + UMI are *inside* each long read, behind Parse's two
  linker sequences — they must be **extracted** before any barcode calling;
* alignment needs a long-read, spliced aligner (minimap2), not STAR's
  short-read mode.

This pipeline follows Parse's official long-read procedure (published in
Parse's support documentation for `split-pipe`): split each long read into a
synthetic R1 (transcript) + R2 (barcode), then feed those to `split-pipe` with
minimap2 substituted for STAR.

## The DAG

`bin/lr_submit.sh` runs on a login node and submits a Slurm dependency DAG. It
does **no** heavy work itself — it discovers chunks, writes a manifest, and
wires the jobs together with `--dependency`.

```
   refs (1 job)                       genpairs[0..N-1]  (job ARRAY)
   ┌──────────────────┐               ┌───────────────────────────┐
   │ split-pipe mkref │               │ one task per fastq chunk  │
   │ minimap2 -d      │   (concurrent │ LR_generate_pairs (edlib) │
   │ GTF -> junc BED  │    — no dep   │ -> split_R1 + split_R2    │
   └────────┬─────────┘    between    └─────────────┬─────────────┘
            │               them)                   │
            │   genpairs does NOT use the genome,    │
            │   so it does not wait on refs.         │
            └──────────────┬─────────────────────────┘
                           │  afterok (both)
                           ▼
                      finalize (1 job)
        concat ▸ pre ▸ minimap2 ▸ stats patch ▸ sam->bam ▸ post ▸ stage
                           │
                           ▼
                       RESULTS_DIR  (shared scratch)
```

* **refs ∥ genpairs run concurrently.** `LR_generate_pairs` is pure linker
  detection on the raw reads — it never touches the genome — so the array does
  not wait on the reference build. `lr_submit.sh` submits both and makes
  `finalize` depend on `afterok` of *both*.
* **refs** is skipped entirely if a `REFS_DONE` marker is already present
  (`$SHARED_BASE/refs/<GENOME_NAME>/REFS_DONE`).
* **guesskit** (`slurm/lr/05_guesskit.sbatch`) is an *optional, off-DAG* helper
  you run between genpairs and finalize to pick the kit empirically. It is not
  submitted by `lr_submit.sh`.

## Stages in detail

### refs — `slurm/lr/00_refs.sbatch`

Builds the three reference artifacts **once** into the shared folder
(`$SHARED_BASE/refs/<GENOME_NAME>/`) and drops a `REFS_DONE` marker so later runs
reuse them.

| Step | Command | Output |
|---|---|---|
| 1. STAR ref | `split-pipe --mode mkref --genome_name <name> --fasta … --genes …` | `…/refs/<name>/star/` (used by `--mode pre`/`post`) |
| 2. minimap2 index | `minimap2 -x map-ont -d` on a chrom-prefixed FASTA | `…/minimap2/<name>.map-ont.mmi` |
| 3. junction BED | GTF → `convert2bed` → prefix | `…/minimap2/<name>.genes.bed` (minimap2 `--junc-bed`) |

* **Inputs:** `FASTA_PATH`, `GTF_PATH` (e.g. a 10x Genomics `refdata-gex`
  bundle), `GENOME_NAME`.
* **Chromosome-name prefix — the critical detail.** `split-pipe mkref` prefixes
  every chromosome name with the genome name (`mkref_chr_geno_prefix=True`), so a
  contig becomes e.g. `hg38_chr1`. The minimap2 FASTA and the junction BED must
  carry the **same** prefix or alignment coordinates won't line up with the STAR
  reference that `--mode post` uses. The script does **not** assume the prefix —
  it reads the built `star/.../chrName.txt`, derives the exact prefix
  (`<name>_` if the first entry starts with it, else empty), and applies it to both
  the FASTA (`sed 's/^>/>PREFIX/'`) and the BED (`sed 's/^/PREFIX/'`).
* For the junction BED, every GTF line missing a `transcript_id` first gets a
  synthetic one (`awk`), because `convert2bed --input=gtf` requires it.
* Idempotent at sub-step granularity (a `PARSE_DONE` marker on the STAR dir, and
  existence checks on the `.mmi` / `.bed`), then a top-level `REFS_DONE`.

### genpairs — `slurm/lr/10_genpairs.sbatch`

A **Slurm job array**, one task per fastq chunk. `$SLURM_ARRAY_TASK_ID` selects
line `id+1` of the chunk manifest (`$WORK_DIR/chunks.txt`, written by
`bin/lr_discover_chunks.sh`).

Each task runs:

```bash
python LR_generate_pairs_1.0.0.py \
    --fastq <chunk> --new_fname split --out_dir $WORK_DIR/pairs/<stem>/ \
    --chemistry v3 --l1dist 1 --l2dist 1
```

* `LR_generate_pairs` uses **edlib** to find the two Parse linkers in each read
  (within `l1dist`/`l2dist` edits), then splits the read into `split_R1`
  (transcript / cDNA) and `split_R2` (the barcode-bearing tail). This script is
  Parse's own tool, shipped with their long-read documentation / your licensed
  split-pipe install — point `LR_PAIRS_SCRIPT` at your own copy of it.
* **Why each task gets its own directory** (`$WORK_DIR/pairs/<stem>/`): besides
  the pair, `LR_generate_pairs` always emits fixed-name `unmatched.fastq` and
  `empty_cDNA.fastq`. Concurrent array tasks writing to a shared dir would
  collide on those names. Per-chunk dirs isolate them.
* The script writes **uncompressed** fastq; the task then `pigz`-compresses the
  pair it keeps (`split_R1.fastq.gz`, `split_R2.fastq.gz`) and deletes the
  `unmatched`/`empty_cDNA` diagnostics to save scratch.
* A chunk that yields **zero** pairs (empty/odd chunk) is a warning, not a
  failure — an empty but valid `.gz` is kept so the array still completes
  `afterok` and concat simply contributes nothing from it.
* **Idempotent:** a `PARSE_DONE` marker is dropped per chunk dir; a task that
  finds it skips. Failed indices are re-runnable with `sbatch --array=<ids>`.

### guesskit — `slurm/lr/05_guesskit.sbatch` (optional)

Determines the **kit** empirically from the data before committing the full run.
Needs the STAR ref (refs) and some completed chunk pairs (genpairs).

* Concatenates a **subset** of completed chunks (`LR_KIT_SAMPLE_CHUNKS`, default
  30) into a small `sub_R1.fastq.gz` under `$WORK_DIR/kitcheck/`.
* Runs a quick `split-pipe --mode pre --one_step --kit WT` (any valid probe kit —
  scoring evaluates **all** kits) on that subset.
* `split-pipe` scores the observed round-1 barcodes against every kit's whitelist
  (`kits.guess_kit_from_bc`) and writes `process/kit_bc_scores.csv`, copied to
  `$WORK_DIR/kit_bc_scores.csv`. The highest-scoring kit is the one to pass to
  finalize as `KIT=`.

### finalize — `slurm/lr/20_process.sbatch`

Runs once, after the array, and takes the single sublibrary all the way to
deliverables. Because there is only one sublibrary, there is **no `--mode comb`**
step (combine only exists to merge multiple sublibraries).

Seven sub-steps:

1. **concat** — concatenate every chunk's `split_R1.fastq.gz` / `split_R2.fastq.gz`
   in **stable manifest order** into `concat_split_R1.fastq.gz` / `…_R2…`.
   Missing chunks are warned and skipped; at least one must be present. Marker:
   `PARSE_DONE_concat`.
2. **pre** — `split-pipe --mode pre --one_step --kit $KIT --chemistry v3
   --fq1 <concat R1> --genome_dir <star> --parfile <parfile>`. This does barcode
   calling and emits `process/barcode_head.fastq` + `process/pre_align_stats.csv`.
   Marker: `PARSE_DONE_pre`. (`--samp_sltab` is added only if `SAMPLE_TABLE` is
   set; leave unset to process every well as one pooled "all-sample" output.)
3. **minimap2** — `pigz` the `barcode_head.fastq`, then spliced long-read
   alignment:
   ```bash
   minimap2 --MD -a -u f -x splice -t N --junc-bed <bed> <mmi> barcode_head.fastq.gz > aligned.sam
   ```
4. **stats patch** — patch `process/pre_align_stats.csv` (details below).
5. **sam→bam** — `samtools view -b aligned.sam > process/barcode_headAligned.out.bam`
   (the exact name `--mode post` expects, `PF_BAM_RAW`), then delete the large SAM.
6. **post** — `split-pipe --mode post --chemistry v3 --genome_dir <star>
   --parfile <parfile>` runs postprocess → mol → dge → reports to completion.
   Marker: `PARSE_DONE`.
7. **stage** — `rsync` the sublibrary output to `RESULTS_DIR/<LR_SUBLIB>/`,
   excluding the bulky intermediates (concat fastqs, `barcode_head.fastq.gz`,
   `aligned.sam`).

#### Why the `pre_align_stats.csv` patch is required

In the normal STAR path, `--mode pre` runs STAR and parses STAR's `Log.final.out`
to fill three counters in `pre_align_stats.csv`:

```
reads_align_input
reads_align_unique
reads_align_multimap
```

`split-pipe --mode post` **reads** those three values
(`align.py:have_postprocess_ins`) to drive postprocessing. But in the long-read
path we replaced STAR with **minimap2**, and minimap2 does **not** write STAR's
`Log.final.out` — so those rows are absent and `--mode post` would have nothing
to read. The finalize step therefore computes them from the SAM and rewrites the
file:

* `reads_align_input` = `reads_valid_barcode` (read back out of the same CSV);
* `reads_align_unique` = `samtools view -c -q 60 -F 0x904` (primary, mapped,
  MAPQ ≥ 60);
* `reads_align_multimap` = (primary mapped, any MAPQ) − unique.

The MAPQ-60 threshold matches the parfile's `mol_min_mapq_score 60` (minimap2's
unique-map score; STAR uses 255).

## Parfile & version notes

Parse's published long-read article was written against an older split-pipe
release; some parfile keys have changed across versions (e.g. an older
`pre_check_name_R1R2` key was dropped in favor of `pre_check_name_match
False`, which covers the same intent — R1/R2 read names won't match after the
long-read split). **Verify the parfile keys below against your installed
split-pipe version's documentation** before a real run:

```
pre_check_name_match False    # R1/R2 names won't match after the LR split
mol_min_mapq_score   60       # minimap2 unique-map MAPQ (STAR uses 255)
pre_keep_no_bc_fq    True     # keep reads with no barcode (per Parse LR doc)
pre_min_R1_len       10       # LR transcript reads can be short
```

`LR_generate_pairs_*.py` itself is Parse's tool, shipped attached to their
long-read documentation / your licensed split-pipe distribution — it is not
included in this repo; point `LR_PAIRS_SCRIPT` at your own copy.

## Kit & chemistry

* **Chemistry** (`v1`/`v2`/`v3`/`v4`) determines which linker sequences
  `LR_generate_pairs` looks for and the expected barcode-read length. Verify
  empirically on a real chunk (read retention rate + expected linkers present)
  rather than assuming it from a kit label.
* **Kit** (`WT`, `WT_mini`, etc.) is best **determined empirically** rather
  than trusted from a label: run `guesskit` and read `kit_bc_scores.csv` —
  `split-pipe` scores the observed round-1 barcodes against every kit
  whitelist, and the top score is the kit. Set it for finalize via `KIT=`.
* **Sample assignment.** Leave `SAMPLE_TABLE` empty to let `split-pipe`
  process every well into one pooled "all-sample" output. Supply a real
  Evercode SampleLoadingTable (`--samp_sltab`) to get per-sample outputs
  instead — see [`../samples/README.md`](../samples/README.md).

## Environment

`split-pipe` and the long-read tools live in a conda env (`CONDA_ENV`, default
`spipe`), built once by `bin/lr_install_env.sh`:

```bash
PKG_DIR=/path/to/ParseBiosciences-Pipeline.X.Y.Z bash bin/lr_install_env.sh 2>&1 | tee install_lr.log
```

It creates the env and installs:

| Source | Packages |
|---|---|
| Parse's `install_dependencies_conda.sh` (in your licensed install) | split-pipe's own deps: STAR, samtools, pigz, gcc, numba |
| `pip install .` (your licensed install) | split-pipe itself (compiles Cython) |
| bioconda | minimap2, bedops (`convert2bed`) |
| pip | biopython, edlib (needed by `LR_generate_pairs`) |

* **python 3.12** is pinned: split-pipe needs `python >= 3.12.8`, and Parse
  pins `numba <= 0.61.2`, which has **no** build for 3.13/3.14 as of this
  writing — 3.12 is the line that satisfies both.
* `pigz` and GNU `parallel` are otherwise assumed system-provided.
* Every job activates the env via `activate_env()` in `slurm/lib/common.sh`
  (`conda activate $CONDA_ENV`), which also asserts `split-pipe` is on `PATH`.

## Running it

Quick start:

```bash
PKG_DIR=/path/to/ParseBiosciences-Pipeline.X.Y.Z bash bin/lr_install_env.sh   # one-time
bin/lr_submit.sh --dry-run          # preview the plan + resolved paths
bin/lr_submit.sh                    # submit refs ∥ genpairs -> finalize
```

Override any config value from the environment, e.g.:

```bash
SLURM_ACCOUNT=myaccount KIT=WT_mini bin/lr_submit.sh
```

### Staged submission

To pause and decide the kit before the (long) finalize:

```bash
bin/lr_submit.sh --no-finalize                    # submit refs + genpairs only
# ... wait for genpairs, then determine the kit:
sbatch --account=<acct> --export=ALL \
    --output=$WORK_DIR/logs/guesskit_%j.out slurm/lr/05_guesskit.sbatch
# ... read $WORK_DIR/kit_bc_scores.csv, then finalize with the chosen kit:
RUN_ID=<same> KIT=<winner> bin/lr_submit.sh --finalize-only
```

`--finalize-only` submits only finalize (refs + genpairs already complete). With
no upstream job to depend on, it starts immediately; pass `FIN_DEP=<jobid>` to
gate it behind a specific job for a manual re-run.

### Monitoring

```bash
squeue --me                         # all your jobs (refs / genpairs[] / finalize)
tail -f $WORK_DIR/logs/*.out        # live logs
sacct -j <genpairsJobId> --format=JobID,State,ExitCode   # per-array-task status
```

### Re-running failed genpairs chunks

The array is idempotent (per-chunk `PARSE_DONE`), so re-submit only the failures:

```bash
# which array indices failed?
sacct -j <genpairsJobId> --format=JobID,State,ExitCode | grep -v COMPLETED
# resubmit just those (manifest + scratch unchanged):
REPO_ROOT=$PWD RUN_ID=<run> LR_CHUNK_MANIFEST=$WORK_DIR/chunks.txt \
  sbatch --account=<acct> --export=ALL --array=3,7,11 slurm/lr/10_genpairs.sbatch
```

### Resuming finalize

Finalize carries **per-step markers**, so a re-run skips the expensive steps it
already finished:

| Marker (in `$WORK_DIR/sublib/<sublib>/`) | Step it gates |
|---|---|
| `PARSE_DONE_concat` | the concat of all per-chunk pairs |
| `PARSE_DONE_pre`    | `split-pipe --mode pre` (barcode calling) |
| `PARSE_DONE`        | full completion (through `--mode post`) |

Just re-submit finalize (`bin/lr_submit.sh --finalize-only`, or `sbatch
slurm/lr/20_process.sbatch` with `REPO_ROOT`/`RUN_ID` exported): concat and pre
are reused if their markers exist, and it picks up from minimap2. To force a
clean redo of a step, delete its marker first.

## Outputs

Deliverables land in `RESULTS_DIR` = `$SHARED_BASE/analysis/<RUN_ID>`, under
`<RUN_ID>/<LR_SUBLIB>/`. The chunk manifest is copied alongside for provenance.
See [`output-structure.md`](output-structure.md) for the full layout.
