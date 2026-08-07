# bin/

Entrypoint scripts for the long-read (Nanopore/PacBio) workflow: raw reads are
split into synthetic barcode/transcript pairs by `LR_generate_pairs`, then
driven through `split-pipe --mode pre` → minimap2 → `split-pipe --mode post`.
All scripts source [`../config/pipeline.config`](../config/pipeline.config),
so every value is overridable from the environment (e.g. `KIT=WT
bin/lr_submit.sh`). Run them from an HPC login node with `sbatch` available.

| Script | Purpose | Key invocation |
|---|---|---|
| `lr_install_env.sh` | One-time: build the conda env with split-pipe + minimap2, bedops, edlib, biopython (python 3.12). Requires `PKG_DIR` pointing at your own licensed split-pipe install. | `PKG_DIR=/path/to/ParseBiosciences-Pipeline.X.Y.Z bash bin/lr_install_env.sh 2>&1 \| tee install_lr.log` |
| `lr_discover_chunks.sh` | List the flat long-read fastq chunks (one sublibrary, no R1/R2) → sorted, one path/line for the array index. | `bin/lr_discover_chunks.sh \| wc -l` |
| `lr_submit.sh` | Discover chunks + submit the long-read DAG (refs ∥ genpairs array → finalize → stage). | `bin/lr_submit.sh` |

## `lr_submit.sh` flags

| Flag | Effect |
|---|---|
| `--dry-run` (`-n`) | Print the plan + resolved paths; submit nothing. |
| `--no-finalize` | Submit refs + genpairs only (stop before finalize). |
| `--finalize-only` | Submit only finalize (refs + genpairs already done); pass the same `RUN_ID`. |

Staged flow (pick the kit empirically between the two):

```bash
bin/lr_submit.sh --no-finalize                    # refs + genpairs only
# decide WT vs WT_mini (slurm/lr/05_guesskit.sbatch → process/kit_bc_scores.csv)
RUN_ID=<same id> KIT=<chosen> bin/lr_submit.sh --finalize-only
```

Re-run failed genpairs chunks (each is idempotent via a `PARSE_DONE` marker):
`sbatch --array=<failed ids> … slurm/lr/10_genpairs.sbatch`.
