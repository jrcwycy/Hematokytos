# samples/

Holds your Parse **SampleLoadingTable** — an `.xlsm` that maps wells to
biological sample names. `split-pipe` reads it (`--samp_sltab`) to label the
per-sample outputs.

This repo does not ship an example table — Parse's stock templates are
distributed with your licensed split-pipe install / Evercode kit
documentation. Get your real (or template) table from there, put it in this
directory, and point `SAMPLE_TABLE` at it in
[`../config/pipeline.config`](../config/pipeline.config) (or via the
environment):

```bash
SAMPLE_TABLE="$REPO_ROOT/samples/my_real_table.xlsm" bin/lr_submit.sh
```

Leave `SAMPLE_TABLE=""` (empty) for an **all-sample** run — `split-pipe`
processes every well into one combined output, with no per-sample labels.
Real per-sample labels can always be applied later by re-running just
`finalize` (`slurm/lr/20_process.sbatch`) with a real table.

## The kit must match the table's plate geometry

`KIT` and the table's well layout have to agree, or barcode→sample mapping is
wrong. Check your kit's documentation for the expected plate geometry (e.g.
Evercode WT is 48 wells / 4 rows; WT Mini is 12 wells / 1 row) and use the
matching table.
