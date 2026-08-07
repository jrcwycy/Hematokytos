# parse-longread-pipeline

A SLURM orchestration wrapper that runs Parse Biosciences' `split-pipe`
single-cell RNA-seq pipeline on **long-read** (Oxford Nanopore / PacBio) data,
with maximum parallelism, scratch-first I/O, and idempotent re-runs.

## Licensing — read this first

**`split-pipe` is Parse Biosciences licensed software and is not included in
this repo.** This repo contains only original orchestration code: Slurm batch
scripts, a config file, and docs that call `split-pipe` / `minimap2` /
`samtools` as external tools. To use it you need your own licensed copy of
`split-pipe` (available to Parse customers) and Parse's `LR_generate_pairs`
script, which ships with it. See [Setup](#setup) below.

## Why long-read needs a different path

`split-pipe`'s standard mode expects paired short-read Illumina `R1`/`R2`
files per sublibrary, aligned with STAR. Long-read data doesn't have that
shape: each read carries the cell barcode/UMI *and* the cDNA together, behind
two known linker sequences, and needs a splice-aware long-read aligner
instead of STAR. This pipeline follows Parse's published long-read procedure:
split each long read into a synthetic barcode/transcript pair
(`LR_generate_pairs`), then run `split-pipe --mode pre` → **minimap2**
(replacing STAR) → `split-pipe --mode post`.

## Software stack

| Component | Role |
|---|---|
| `split-pipe` (Parse Biosciences, licensed — bring your own; v1.7.3 used here) | Barcode calling, postprocessing, DGE matrices, QC report |
| `LR_generate_pairs` (Parse, ships with split-pipe — bring your own) | Splits each long read into a synthetic transcript read + barcode read |
| STAR | Builds the reference index `split-pipe --mode pre/post` needs (STAR itself does not align in this workflow) |
| minimap2 | Spliced long-read alignment (`-x splice`), replacing STAR for the mapping step |
| samtools | SAM → BAM conversion |
| bedops (`convert2bed`) | GTF → BED for minimap2's splice-junction hints |
| Python 3.12, biopython, edlib | Runtime + fuzzy linker matching for `LR_generate_pairs` |

See [`docs/longread-pipeline.md`](docs/longread-pipeline.md) for exact
version constraints (e.g. the python-3.12 pin) and installation detail.

## The DAG

```
   refs (1 job)                       genpairs[0..N-1]  (job ARRAY)
   ┌──────────────────┐               ┌───────────────────────────┐
   │ split-pipe mkref │               │ one task per fastq chunk  │
   │ minimap2 -d      │   concurrent  │ LR_generate_pairs (edlib) │
   │ GTF -> junc BED  │   (no dep)    │ -> split_R1 + split_R2    │
   └────────┬─────────┘               └─────────────┬─────────────┘
            └──────────────┬────────────────────────┘
                           │  afterok (both)
                           ▼
                      finalize (1 job)
        concat ▸ pre ▸ minimap2 ▸ stats patch ▸ sam->bam ▸ post ▸ stage
                           │
                           ▼
                       RESULTS_DIR
```

* **refs** (`slurm/lr/00_refs.sbatch`) — built once into shared storage and
  reused via a `REFS_DONE` marker.
* **genpairs** (`slurm/lr/10_genpairs.sbatch`) — a Slurm job array, one task
  per fastq chunk; splits each long read into a barcode/transcript pair.
  Independent of the reference, so it runs concurrently with refs.
* **guesskit** (`slurm/lr/05_guesskit.sbatch`, optional) — empirically
  determines the Parse kit (e.g. WT vs WT Mini) from the data before
  committing to the full run.
* **finalize** (`slurm/lr/20_process.sbatch`) — concat → barcode calling →
  minimap2 alignment → patch alignment stats (minimap2 doesn't emit the STAR
  log that `--mode post` expects) → SAM→BAM → postprocess/DGE/report → stage
  deliverables.

Full stage-by-stage detail: [`docs/longread-pipeline.md`](docs/longread-pipeline.md).

## Setup

1. Get a licensed copy of `split-pipe` from Parse Biosciences and unpack it
   somewhere, e.g. `~/ParseBiosciences-Pipeline.X.Y.Z/`.
2. Build the conda environment:
   ```bash
   PKG_DIR=~/ParseBiosciences-Pipeline.X.Y.Z bash bin/lr_install_env.sh 2>&1 | tee install_lr.log
   ```
3. Edit [`config/pipeline.config`](config/pipeline.config) — every value
   marked `>>> EDIT <<<` needs a real value for your cluster and data
   (Slurm account, scratch paths, `FASTQ_DIR`, reference FASTA/GTF, and
   `LR_PAIRS_SCRIPT` pointing at `LR_generate_pairs_*.py` inside your
   `PKG_DIR`).
4. Preview, then submit:
   ```bash
   bin/lr_submit.sh --dry-run          # preview the plan + resolved paths
   bin/lr_submit.sh                    # submit refs ∥ genpairs -> finalize
   ```

Override any config value from the environment, e.g.
`SLURM_ACCOUNT=myaccount KIT=WT_mini bin/lr_submit.sh`.

### Staged submission (pick the kit empirically first)

```bash
bin/lr_submit.sh --no-finalize          # submit refs + genpairs only
# run slurm/lr/05_guesskit.sbatch, read process/kit_bc_scores.csv,
# then finalize with the winning kit:
RUN_ID=<same id> KIT=<chosen> bin/lr_submit.sh --finalize-only
```

## Layout

```
parse-longread-pipeline/
├── bin/
│   ├── lr_submit.sh              # orchestrator: discover chunks, submit the DAG
│   ├── lr_discover_chunks.sh     # fastq dir -> chunk list (array index)
│   └── lr_install_env.sh         # build the conda env (one-time)
├── slurm/
│   ├── lr/
│   │   ├── 00_refs.sbatch        # STAR ref + minimap2 index + junction BED
│   │   ├── 05_guesskit.sbatch    # empirical kit determination (helper)
│   │   ├── 10_genpairs.sbatch    # JOB ARRAY: LR_generate_pairs per chunk
│   │   └── 20_process.sbatch     # finalize: pre ▸ minimap2 ▸ post ▸ stage
│   └── lib/
│       ├── common.sh             # shared logging / scratch / env helpers
│       └── lr_common.sh          # long-read path/marker helpers
├── config/
│   └── pipeline.config           # single source of truth
├── samples/                      # your SampleLoadingTable (.xlsm) goes here
├── docs/
│   ├── longread-pipeline.md      # detailed stage-by-stage guide
│   ├── output-structure.md       # what the results directory contains
│   └── architecture.md           # data flow, dependency model, re-runs
└── .gitignore                    # blocks accidental commits of Parse-licensed files
```

## Outputs

`split-pipe --mode post` produces, per sublibrary, DGE matrices
(`DGE_filtered/`, `DGE_unfiltered/`, MatrixMarket format), an interactive
HTML QC report, and an annotated alignment BAM. Full layout:
[`docs/output-structure.md`](docs/output-structure.md).

## Re-runs

Every stage is idempotent via marker files (`REFS_DONE`, per-chunk
`PARSE_DONE`, and finalize's per-step markers), so a failed or interrupted run
resumes from the last completed step instead of starting over. See
[`docs/architecture.md`](docs/architecture.md#failure-handling--re-runs).
