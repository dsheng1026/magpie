#!/bin/bash
# =============================================================================
# add_woodfuel.sh  --  run the woodfuel post-processor as one serial job.
#
# Run AFTER the matrix job has produced magpie_input_SSP2_BD00.xlsx. This reads
# the 84 fulldata.gdx files, extracts woodfuel, and writes the *_woodfuel.xlsx.
#
# Submit from the directory containing add_woodfuel_to_matrix.R:
#     sbatch add_woodfuel.sh
# =============================================================================
 
#SBATCH --job-name=mp2msg_woodfuel
#SBATCH --output=mp2msg_woodfuel_%A_%a.log
#SBATCH --qos=priority           # same QOS your MAgPIE runs use
#SBATCH --time=02:00:00            # 84 quick gdx reads + one xlsx read/write
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1          # serial
#SBATCH --mem=8G                   # peak: one gdx read + matrix held in memory
#SBATCH --array=0-3  
#SBATCH --mail-type=BEGIN,END
#SBATCH --mail-user=sheng@iiasa.ac.at
 
set -euo pipefail
 
# Same R environment as the matrix job. gcc/15.2.0 loaded LAST so the piam
# compiled packages (incl. gdx2 -> Rcpp) find CXXABI_1.3.15 in libstdc++.
module purge
module load defaults/piam/1.27
module load R/4.3.2
module load gcc/15.2.0
 
base_dirs=(
  "/p/projects/magpie/users/dish/magpie/output/MESSAGEix_5ff27be8/SSP2_BD00"
  "/p/projects/magpie/users/dish/magpie/output/MESSAGEix_5ff27be8_LAND/SSP2_BD78"
  "/p/projects/magpie/users/dish/magpie/output/MESSAGEix_5ff27be8_FOOD/SSP2_BD00"
  "/p/projects/magpie/users/dish/magpie/output/MESSAGEix_5ff27be8_ALL/SSP2_BD78"
)
 
matrix_ins=(
  "/p/projects/magpie/users/dish/emulator/magpie_input_SSP2_ref.csv"
  "/p/projects/magpie/users/dish/emulator/magpie_input_SSP2_LAND.csv"
  "/p/projects/magpie/users/dish/emulator/magpie_input_SSP2_FOOD.csv"
  "/p/projects/magpie/users/dish/emulator/magpie_input_SSP2_ALL.csv"
)
 
i="${SLURM_ARRAY_TASK_ID}"
 
echo "=== array task ${i}: woodfuel for ${matrix_ins[$i]} from ${base_dirs[$i]} ==="
 
Rscript add_woodfuel_to_matrix.R "${base_dirs[$i]}" "${matrix_ins[$i]}"