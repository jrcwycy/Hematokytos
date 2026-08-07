# Reference Atlas Analysis Notebooks

Workflows for constructing and analysing the reference atlas used throughout the project. They collect public hematopoietic datasets, harmonize annotations and generate figures.

## Notebooks
- `gather_hsc_data.ipynb` – Collect public datasets from CELLxGENE
- `get_metadata.ipynb` – Retrieve and clean cell metadata
- `standardize_labels.ipynb` – Harmonize cell type annotations
- `list_studies.ipynb` – Create .csv with dataset IDs
- `build_reference.ipynb` – Generate the combined reference dataset
- `summarize_obs.ipynb` – Summaries of reference dataset cell populations
- `make_embedding.ipynb` – Compute UMAP/embedding for the atlas
- `summarize_sample_1.ipynb` – Atlas summary (Figure S1)
- `native_atlas.ipynb` – Figure preparation notebook (Figure 1, S2)
- `basename_DEG.ipynb` – Expression analysis by basename groups (Figure S3)
- `hsc_compartment.ipynb` – Gene expression in the hematopoietic compartment (Figures S4, S5)
- `cell_type_DEG.ipynb` – Differential expression across cell types (Figures S6-S8)

