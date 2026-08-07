# Trajectory Inference Notebooks

Pseudotime ordering and RNA velocity analysis. Includes notebooks for QC and analysis of the timeseries reprogram dataset.

## Notebooks

- `cell_cycle.ipynb` – Cell cycle gene analysis (Figure S13)
- `pseudotime.ipynb` – Diffusion pseudotime analysis (Figure S14)
- `scvelo.ipynb` – RNA velocity analysis using scVelo (3C-E, 3G-H, S14, S16)
- `scvelo-enrichr.ipynb` – Velocity pseudotime correlations and enrichr analysis (Figures 3F, S14, S15)
- `timeseries_integration.ipynb` - Testing different integration methods for initial, reprogram, and time-series reprogram datasets
- `integ_benchmarking.ipynb` - Benchmarking results across integration methods (Figure S18)
- `timeseries_embedding.ipynb` - Code to make final embedding of integrated datasets (Figure S19)
- `timeseries_clusters.ipynb` - Clustering analysis for time-series data (Figure S19)
- `project_pseudotime.ipynb` - Pseudotime projection (Figure S20)
- `pipeline_compare.ipynb` – Comparison between Parse pipeline run outputs with and without sample table
- `QC_longread.ipynb` – Comparison of per-cell QC metrics between long-read datasets generated in this study
