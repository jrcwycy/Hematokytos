# config/

| File | Role |
|---|---|
| `pipeline.config` | **Single source of truth.** Sourced by every script in `bin/` and `slurm/`; every value is overridable from the environment (e.g. `SLURM_ACCOUNT=myaccount KIT=WT_mini bin/lr_submit.sh`). |

## Most important knobs

| Setting | Meaning | Default |
|---|---|---|
| `SLURM_ACCOUNT` | Slurm allocation | `myaccount` |
| `KIT` / `CHEMISTRY` | Parse kit + chemistry (`split-pipe --kit_list`) | `WT` / `v3` |
| `FASTQ_DIR` | Directory of raw long-read fastq chunks | `/path/to/long_read_fastqs/` |
| `GENOME_NAME` | Reference label / path component | `hg38` |
| `SCRATCH_BASE` | Per-user fast scratch (heavy I/O) | `/scratch/$USER` |
| `SHARED_BASE` | Group-shared scratch folder (refs + staged results) | `/scratch/shared_data/parse` |
| `RESULTS_DIR` | Where deliverables are staged | `$SHARED_BASE/analysis/<RUN_ID>` |
| `LR_SUBLIB` | Name of the single long-read sublibrary | `my_sublibrary` |
| `LR_PAIRS_SCRIPT` | Path to `LR_generate_pairs_*.py` from **your own** licensed split-pipe install (required, no default) | _(none — must be set)_ |
| `MM2_XPRESET` | minimap2 alignment preset (ONT `splice`, HiFi `splice:hq`) | `splice` |
| `LR_PARFILE_LINES` | split-pipe long-read parfile lines | see `pipeline.config` |
| `LR_ARRAY_THROTTLE` | Max genpairs chunks running at once | `100` |

All values marked `>>> EDIT <<<` in `pipeline.config` need to be set for your
cluster and data before a real run — the shipped defaults are placeholders.

See the [top-level README](../README.md) for workflow overviews and
[`../docs/longread-pipeline.md`](../docs/longread-pipeline.md) for the full
stage-by-stage guide.
