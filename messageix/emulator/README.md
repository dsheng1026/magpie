# emulator — step 4, matrix generation

Turns a finished stage-3 run grid into the land-use emulator matrix MESSAGEix reads.

- `createMatrix_MM.R` maps each run's `report.mif` through `MM_linkage_mapping.csv` and writes one matrix CSV for the whole grid.
- `add_woodfuel_to_matrix.R` adds forest-harvest woodfuel from each run's `fulldata.gdx` to `Primary Energy|Biomass` — the variable is absent from `report.mif` — and writes `*_woodfuel.csv`, the file the linkage consumes.
- `run_matrix.sh` runs both in sequence, locally or as a SLURM job (`--submit`, and `--submit --narratives all` for one array task per narrative).

Run from the MAgPIE model root: `bash messageix/emulator/run_matrix.sh --preset default`. With no `--out`, the matrix is written to `<--matrix-dir>/<pipeline$matrix_basename>.csv` and the woodfuel step appends `_woodfuel` — which is how the golden artefact name `magpie_input_SSP2_ref_woodfuel.csv` is reproduced.

All three take `--key value` and `--key=value` alike, name the preset CSV `--csv`, and carry `--help`. The SLURM queue, the environment modules and the notification address are read from the preset through [`../R/utils_env.R`](../R/utils_env.R); `run_matrix.sh` holds no copy of them.

Both steps stop before writing if any run in the grid is missing or unsolved — one solvedness contract, `SOLVED_MODELSTAT` in [`../R/utils_runs.R`](../R/utils_runs.R), shared with the patch generators. Pipeline science and the full step-by-step: [`../docs/pipeline.md`](../docs/pipeline.md).
