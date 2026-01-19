# CAPYBARA Scripts

Shell wrappers and an R script for running
[Capybara](https://github.com/nstoparczyk/capybara) to assign cell
identities.

## Contents
- `run_capybara.R` – Core R script that performs Capybara label assignment
- `capybara_*.sh` – Example SLURM submission scripts for different analyses
- `simplify.ipynb` – Notebook demonstrating how results can be simplified

## Usage
Modify the input and output paths inside the shell scripts and submit them
via `sbatch`. The R script expects an AnnData `.h5ad` input and a labelled
reference dataset.
