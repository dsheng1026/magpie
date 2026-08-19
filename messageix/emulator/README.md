# emulator — the matrix step

Turns a finished set of stage-3 runs into the land-use emulator matrix MESSAGEix reads. This is the `matrix` step of the pipeline, and it comes in two halves.

- `createMatrix_MM.R` maps each run's `report.mif` through `MM_linkage_mapping.csv` and writes one matrix CSV for the whole set.
- `add_woodfuel_to_matrix.R` adds forest-harvest woodfuel from each run's `fulldata.gdx` to `Primary Energy|Biomass` — the variable is missing from `report.mif` — and writes `*_woodfuel.csv`, the file the linkage reads.
- `run_matrix.sh` runs both in sequence, locally or as a SLURM job (`--submit`, and `--submit --narratives all` for one array task per narrative).

Run from the MAgPIE model root: `bash messageix/emulator/run_matrix.sh --preset default`. With no `--out`, the matrix is written to `<--matrix-dir>/<the narrative's own matrix name>.csv` and the woodfuel step appends `_woodfuel` — which is how the golden artefact name `magpie_input_SSP2_ref_woodfuel.csv` is reproduced.

The two R scripts take `--key value` and `--key=value` alike; `run_matrix.sh` is a shell wrapper and takes the `--key value` form only. All three name the narratives file `--csv` and carry `--help`. The SLURM queue, the environment modules and the notification address are infrastructure settings, asked for through [`../R/utils_env.R`](../R/utils_env.R); `run_matrix.sh` holds no copy of them, and asks the R layer for everything it needs about a narrative in a single call.

Both halves rename MAgPIE's region codes to MESSAGEix names from the one table the narrative's region set carries ([`../presets/region_names_R12.csv`](../presets/region_names_R12.csv) for the pinned R12 set) — one table, so the matrix and the woodfuel added to it cannot end up with different names for the same region. Both stop if a run reports a region the table does not name: region sets overlap heavily (R10 and R12 share eleven of twelve codes), so runs at the wrong resolution would otherwise be renamed where the codes happen to agree and left in MAgPIE's codes where they do not.

For checking this pipeline's matrix against stage-3 runs made before it, both scripts take `--layout=legacy`, which reads the older folder names (`SSP2_BD00_BE45_G4000demand`) without anything being renamed. Nothing produces runs in that layout, and the matrix content is the same either way — no run folder name reaches a column of the matrix.

The woodfuel half also stops if any `Primary Energy|Biomass` row of the matrix ends up with no woodfuel in any year — the failure that a partial region or scenario match produces, and the one that is invisible in the finished file.

Both halves stop before writing if any run in the set is missing or unsolved — one definition of "solved", `SOLVED_MODELSTAT` in [`../R/utils_runs.R`](../R/utils_runs.R), shared with the two patch steps. Pipeline science and the full step-by-step: [`../docs/pipeline.md`](../docs/pipeline.md).
