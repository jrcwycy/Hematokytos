#!/bin/bash

#SBATCH --job-name=slurm_ hematokytos 
#SBATCH --account=indikar1
#SBATCH --partition=gpu_mig40
#SBATCH --mail-user=cstansbu@umich.edu
#SBATCH --mail-type=END,FAIL
#SBATCH --mem=200G
#SBATCH --gpus=1
#SBATCH --time=36:00:00
#SBATCH --nodes=1                     
#SBATCH --ntasks=1                    
#SBATCH --cpus-per-task=16
#SBATCH --output=/scratch/indikar_root/indikar1/shared_data/hematokytos/%j.out

python preprocess.py 