# Output structure

What the long-read pipeline stages to `RESULTS_DIR` (the shared scratch
folder, `…/shared_data/parse/analysis/<RUN_ID>/`), and what each piece is.

> Heavy intermediates (`concat_split_R{1,2}.fastq.gz`, `process/barcode_head.fastq.gz`,
> `process/aligned.sam`) are **not** staged — they stay on `WORK_DIR` scratch.
> What lands in `RESULTS_DIR` is the deliverable set below.

```
RESULTS_DIR/
├── chunks.txt                         # provenance: the fastq chunks that were processed
└── <sublibrary>/                      # e.g. $LR_SUBLIB
    ├── all-sample_analysis_summary.html   # ★ START HERE — interactive QC report
    ├── all_summaries.zip                  # all report CSVs + figures, zipped
    ├── agg_sample_summary.csv             # one-line-per-sample summary
    ├── parfile.txt                        # the long-read split-pipe parfile used
    ├── split-pipe_*.log[.1]               # split-pipe run log(s)
    ├── PARSE_DONE, _concat, _pre          # pipeline stage markers (idempotency)
    │
    ├── all-sample/                     # the per-sample deliverable (see note ↓)
    │   ├── DGE_filtered/               # ★ cell-called expression matrix
    │   │   ├── count_matrix.mtx        #   MatrixMarket, cells × genes, integer counts
    │   │   ├── cell_metadata.csv       #   one row per CELL (matrix rows)
    │   │   └── all_genes.csv           #   one row per GENE (matrix columns)
    │   ├── DGE_unfiltered/             # same triple, ALL barcodes (pre cell-calling)
    │   │   ├── count_matrix.mtx
    │   │   ├── cell_metadata.csv
    │   │   └── all_genes.csv
    │   ├── report/                     # CSVs behind the HTML report
    │   │   ├── analysis_summary.csv    #   headline stats (cells, median genes/tscp, …)
    │   │   ├── cluster_assignment.csv  #   Leiden cluster per cell
    │   │   ├── cluster_diff_exp.csv    #   per-cluster marker genes
    │   │   ├── expressed_genes.csv, tscp_counts.csv, tscp_cutoff_calc.csv
    │   │   └── cell_counts_by_rnd{1,2,3}_well.csv, tscp_median_by_rnd{1,2,3}_well.csv
    │   └── figures/                    # PNGs: UMAPs (cluster/gene/tscp/read),
    │                                   #   per-round-well cell & transcript barplots
    │
    └── process/                        # read-level outputs + alignment + provenance
        ├── barcode_headAligned_anno.bam    # ★ annotated alignment BAM (typically the largest file)
        ├── aw_uf_count_matrix.mtx.gz        # all-well unfiltered matrix (gzipped)
        ├── aw_uf_cell_metadata.csv.gz, aw_uf_bc_counts.csv.gz
        ├── tscp_assignment.csv.gz           # per-read transcript/UMI assignment
        ├── all_genes.csv, barcode_data.csv, well_vbc_counts.csv
        ├── pre_align_stats.csv              # QC stats (incl. the patched reads_align_* rows)
        ├── bcc_read_length_counts.csv
        ├── no_barcode_R{1,2}.fastq          # reads with no valid barcode (pre_keep_no_bc_fq=True)
        ├── env_conda_info.txt, env_version_info.txt   # environment provenance
        └── run_proc_def.json[.*], mem_profile.txt     # run config + profiling
```

## Where to start

1. **`<sublibrary>/all-sample_analysis_summary.html`** — open in a browser; the
   full QC dashboard (cell calling, saturation, per-well counts, UMAPs).
2. **`all-sample/DGE_filtered/`** — the expression matrix for downstream analysis.
3. **`all-sample/report/analysis_summary.csv`** — the headline numbers as plain CSV.

## The DGE matrix (MatrixMarket triple)

Parse emits sparse **MatrixMarket** matrices, **not** `.h5ad`. Each `DGE_*` dir is
a triple: `count_matrix.mtx` + the row labels (`cell_metadata.csv`, one per cell)
+ the column labels (`all_genes.csv`, one per gene). The `.mtx` header states the
orientation, e.g. `%Rows=cells (N), Cols=genes (M)`.

`cell_metadata.csv` columns: `bc_wells, sample, species, gene_count, tscp_count,
mread_count, bc1_well, bc2_well, bc3_well`.
`all_genes.csv` columns: `gene_id, gene_name, genome`.

Load into scanpy (matrix is already cells × genes = AnnData `obs` × `var`):

```python
import scanpy as sc, pandas as pd
d = "…/all-sample/DGE_filtered"
adata = sc.read_mtx(f"{d}/count_matrix.mtx")          # (cells, genes)
adata.obs = pd.read_csv(f"{d}/cell_metadata.csv")
adata.var = pd.read_csv(f"{d}/all_genes.csv")
adata.var_names = adata.var["gene_id"]
```

## "all-sample" vs per-sample

If `SAMPLE_TABLE` is left empty, split-pipe pools every well into a single
output directory named **`all-sample`**. If you instead run `finalize` with a
real `--samp_sltab`, you get **one directory per biological sample** (named
from the table) in place of `all-sample/`, each with its own `DGE_filtered/`,
`DGE_unfiltered/`, `report/`, and `figures/`. The top-level `process/` outputs
are shared across samples.

See [`longread-pipeline.md`](longread-pipeline.md) for how these are produced and
[`architecture.md`](architecture.md) for the scratch→results staging model.
