#!/bin/bash

#SBATCH --job-name=hematokytos_deg
#SBATCH --account=indikar1
#SBATCH --partition=largemem
#SBATCH --mail-user=cstansbu@umich.edu
#SBATCH --mail-type=END,FAIL
#SBATCH --mem=250G
#SBATCH --time=72:00:00
#SBATCH --nodes=1                     
#SBATCH --ntasks=1                    
#SBATCH --cpus-per-task=16
#SBATCH --output=/scratch/indikar_root/indikar1/shared_data/hematokytos/%j.out


module load launcher
export LAUNCHER_WORKDIR=$PWD
export LAUNCHER_JOB_FILE=$HOME/git_repositories/hematokytos/reference_atlas/DEG/launcher-file.txt
$LAUNCHER_DIR/paramrun