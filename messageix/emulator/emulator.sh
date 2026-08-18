#!/bin/bash
# =============================================================================
# emulator.sh  --  run the whole matrix pipeline as ONE serial SLURM job.
#
#
# Submit from the directory containing MM_linkage_emulator.R:
#     sbatch emulator.sh
# =============================================================================

#SBATCH --job-name=MMemultr
#SBATCH --output=mp2msg_%A_%a.log   # %A = array job id, %a = task index
#SBATCH --qos=priority            # e.g. the QOS your MAgPIE runs use
#SBATCH --time=02:00:00            # generous; serial map+matrix over 84 mifs
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1          # the pipeline is single-threaded
#SBATCH --mem=8G                   # peak is reading one 8-9 MB mif via iamc
#SBATCH --array=0-3                 # four tasks: indices 0,1,2,3
#SBATCH --mail-type=BEGIN,END
#SBATCH --mail-user=sheng@iiasa.ac.at

set -euo pipefail

module purge
# Load the standard PIAM R environment and shared package library.
module load defaults/piam/1.27
module load gcc/15.2.0    

module list
Rscript -e 'library(Rcpp); library(iamc)'

# Rscript createMatrix_MM.R \
#   /p/projects/magpie/users/dish/magpie/output/MESSAGEix_5ff27be8/SSP2_BD00 \
#   magpie_input_SSP2_ref.csv

# Rscript createMatrix_MM.R \
#   /p/projects/magpie/users/dish/magpie/output/MESSAGEix_5ff27be8_LAND/SSP2_BD78 \
#   magpie_input_SSP2_LAND.csv

# Rscript createMatrix_MM.R \
#   /p/projects/magpie/users/dish/magpie/output/MESSAGEix_5ff27be8_FOOD/SSP2_BD00 \
#   magpie_input_SSP2_FOOD.csv

# Rscript createMatrix_MM.R \
#   /p/projects/magpie/users/dish/magpie/output/MESSAGEix_5ff27be8_ALL/SSP2_BD78 \
#   magpie_input_SSP2_ALL.csv


base_dirs=(
  "/p/projects/magpie/users/dish/magpie/output/MESSAGEix_5ff27be8/SSP2_BD00"
  "/p/projects/magpie/users/dish/magpie/output/MESSAGEix_5ff27be8_LAND/SSP2_BD78"
  "/p/projects/magpie/users/dish/magpie/output/MESSAGEix_5ff27be8_FOOD/SSP2_BD00"
  "/p/projects/magpie/users/dish/magpie/output/MESSAGEix_5ff27be8_ALL/SSP2_BD78"
)

out_files=(
  "magpie_input_SSP2_ref.csv"
  "magpie_input_SSP2_LAND.csv"
  "magpie_input_SSP2_FOOD.csv"
  "magpie_input_SSP2_ALL.csv"
)

i="${SLURM_ARRAY_TASK_ID}"

echo "=== array task ${i}: ${out_files[$i]} from ${base_dirs[$i]} ==="

Rscript createMatrix_MM.R "${base_dirs[$i]}" "${out_files[$i]}"