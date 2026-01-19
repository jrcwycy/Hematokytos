#!/bin/bash

#SBATCH --job-name=capybara_basename 
#SBATCH --account=indikar1
#SBATCH --partition=largemem,standard
#SBATCH --mail-user=cstansbu@umich.edu
#SBATCH --mail-type=END,FAIL
#SBATCH --mem=150G
#SBATCH --time=36:00:00
#SBATCH --nodes=1                     
#SBATCH --ntasks=1                    
#SBATCH --cpus-per-task=16


ref_path="/nfs/turbo/umms-indikar/shared/projects/HSC/pipeline_outputs/integrated_anndata/capybara/basename_ref.h5ad"
data_path="/nfs/turbo/umms-indikar/shared/projects/HSC/pipeline_outputs/integrated_anndata/pseudotime.h5ad"
output_dir="/nfs/turbo/umms-indikar/shared/projects/HSC/pipeline_outputs/integrated_anndata/capybara/"
prefix="basename"

Rscript run_capybara.R \
  --ref_path="$ref_path" \
  --data_path="$data_path" \
  --output_dir="$output_dir" \
  --prefix="$prefix"
