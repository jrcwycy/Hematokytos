# Data Preparation Notebooks

Notebooks for preparing `AnnData` objects used throughout the project. They take raw data, perform QC, harmonize/integrate counts, and generate embeddings. Notebooks for constructing the native reference atlas are in `Hematokytos/figure1/`.

## Notebooks
- `integrate_scfib_ihsc.ipynb` - QC and integration for control and reprogrammed cells (Results 2.2)
- `combine_atlas_data.ipynb` - Generate the integrated reference dataset (Results 2.4)
- `atlas_embedding.ipynb` - Compute UMAP embedding for the integrated reference atlas 
- `get_Ng2024_rawcounts.R` - Retrieve raw counts from Ng 2024 dataset
- `bm_scfib_hsc.ipynb` - Gene-level integration of control, reprogrammed cells, and bone marrow data (Results 2.4) 
- `make_isoform_adata.ipynb` - Isoform-level integration of control, reprogrammed cells, and bone marrow data (Results 2.5)
