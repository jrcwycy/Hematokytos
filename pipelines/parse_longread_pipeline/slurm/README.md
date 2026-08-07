# slurm/

The Slurm batch scripts that do the heavy lifting for the long-read pipeline,
in [`lr/`](lr/). They are *not* invoked by hand but submitted (with
dependencies, resources, and array ranges wired up) by
[`bin/lr_submit.sh`](../bin/lr_submit.sh). See [`lr/README.md`](lr/README.md)
for the four stages in detail.

## How a job finds the repo

Every `*.sbatch` here begins with `: "${REPO_ROOT:?…}"` and then sources a
shared library from `$REPO_ROOT/slurm/lib/`. `REPO_ROOT` (and `RUN_ID`, the
manifest, etc.) reach the job **through the environment**, because
`lr_submit.sh` submits with `sbatch --export=ALL`. This is deliberate: a
running Slurm job executes from a private **spool copy** of the script, so
`$0` / `${BASH_SOURCE}` inside the job do **not** point at the repo — the path
has to come from the exported environment, not from the script's own
location.

The sourced library loads `config/pipeline.config` and provides the shared
env / scratch / logging helpers used by every stage:

* `lib/common.sh` — logging (`banner`/`log`/`warn`/`die`), `activate_env`
  (conda env + `split-pipe` on `PATH`), `setup_scratch` (creates `WORK_DIR`,
  points `TMPDIR` at scratch), `nthreads` (= `SLURM_CPUS_PER_TASK`), and path
  helpers.
* `lib/lr_common.sh` — sources `common.sh`, then adds the long-read layout
  helpers (`lr_chunk_manifest`, `lr_pairs_root`, `lr_chunk_dir`,
  `lr_sublib_dir`, `lr_parfile`, `lr_refs_done`, `chunk_stem`).

## Files

| File | Stage | Description |
|---|---|---|
| `lr/00_refs.sbatch`     | refs     | Single job: STAR ref (`--mode mkref`) + minimap2 index + GTF→junction BED, built once into the shared folder. `REFS_DONE`. |
| `lr/05_guesskit.sbatch` | guesskit | Single job (optional, off-DAG probe): `--mode pre` on a subset → `kit_bc_scores.csv` to pick the kit empirically. |
| `lr/10_genpairs.sbatch` | genpairs | **Job array** (1 task/fastq chunk): `LR_generate_pairs` (edlib linker split) → `split_R1`+`split_R2`. Per-chunk `PARSE_DONE`. |
| `lr/20_process.sbatch`  | finalize | Single job: concat ▸ `--mode pre` ▸ minimap2 ▸ patch stats ▸ sam→bam ▸ `--mode post` ▸ stage to `RESULTS_DIR`. |
| `lib/common.sh`    | — | Config load, logging, conda env, scratch, threads, path helpers. |
| `lib/lr_common.sh` | — | Sources `common.sh`; adds long-read layout / marker helpers. |

## See also

* [`lr/README.md`](lr/README.md) — the four long-read stages in detail.
* [`../README.md`](../README.md) — top-level overview and quick start.
* [`../docs/architecture.md`](../docs/architecture.md) — scratch/staging data flow, dependency model, re-runs.
* [`../docs/longread-pipeline.md`](../docs/longread-pipeline.md) — long-read rationale, stats-patch and version-porting notes.
