# Data Preparation Notebooks

Notebooks for preparing `AnnData` objects used throughout the project. They take raw data, perform QC, harmonize/integrate counts, and generate embeddings. Notebooks for constructing the native reference atlas are in `Hematokytos/figure1/`.

## Notebooks
- `integrate_scfib_ihsc.ipynb` – QC and integration for control and reprogrammed cells (Related to Figure 2)
- `timeseries_reprogram.ipynb` – QC for time-series reprogrammed cells (Related to Figure 3)
- `combine_atlas_data.ipynb` – Generate the integrated reference dataset (Related to Figure 4)
- `atlas_embedding.ipynb` – Compute UMAP embedding for the integrated reference atlas (Related to Figure 4)
- `get_Ng2024_rawcounts.R` – Retrieve raw counts from Ng 2024 dataset
- `make_Ng2024_adata.ipynb` – Add raw counts to Ng 2024 .h5ad
- `bm_scfib_hsc.ipynb` – Gene-level integration of control, reprogrammed cells, and bone marrow data (Related to Figure 4)
- `make_isoform_adata.ipynb` – Isoform-level integration of control, reprogrammed cells, and bone marrow data (Related to Figure 5)
