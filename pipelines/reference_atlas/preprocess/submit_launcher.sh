#!/bin/bash

#SBATCH --job-name=launcher_hematokytos
#SBATCH --account=indikar1
#SBATCH --partition=gpu_mig40
#SBATCH --mail-user=cstansbu@umich.edu
#SBATCH --mail-type=END,FAIL
#SBATCH --mem=250G
#SBATCH --gpus=1
#SBATCH --time=72:00:00
#SBATCH --nodes=1                     
#SBATCH --ntasks=1                    
#SBATCH --cpus-per-task=16
#SBATCH --output=/scratch/indikar_root/indikar1/shared_data/hematokytos/%j.out


module load launcher
export LAUNCHER_WORKDIR=$PWD
export LAUNCHER_JOB_FILE=$HOME/git_repositories/hematokytos/reference_atlas/preprocess/launcher-file.txt
$LAUNCHER_DIR/paramrun