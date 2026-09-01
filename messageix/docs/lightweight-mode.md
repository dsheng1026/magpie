# Lightweight mode

For a MAgPIE-side collaborator who already runs MAgPIE interactively on the
PIK cluster, and wants to vet the price sweep by eye before starting the
demand sweep. This flow uses the same scripts the chained pipeline uses. It
skips `messageix/run.R`'s automatic phase-to-phase waiting, and submits runs
through MAgPIE's own interactive menu instead of `run_phase.R`'s automated
submission. Three steps: declare a narrative, generate and submit each run by
hand, pack and vet between phases.

## 1. Declare or edit a narrative

Every setting a run can take, its type and its default are listed in
[`tool-surface.md`](tool-surface.md), section 3. Levers live in
`config/*.csv`; the settings reference names every row a narrative CSV may
carry.

The worked example already in this repo is
`messageix/config/narratives_biodiversity.csv`, layered over
`narratives_base.csv`:

```
setting;biodiversity
base;default
bii_target;0.78
yields_scenario;cc
```

`base;default` starts the `biodiversity` column from the `default` column of
`narratives_base.csv` and changes only the two rows named below it. A new
narrative follows the same shape: pick a `base` to start from, name only the
rows that differ.

## 2. Generate a start script and submit it yourself

`R/start_script_gen.R` has no command line of its own. It is a small function
library called from an R session, on the same `pcfg`/`cfg` objects
`run_phase.R` builds internally:

```r
source("messageix/R/run_phase.R")          # brings resolve_config()/stage_cfg()
source("messageix/R/start_script_gen.R")   # brings write_project_start_script()

pcfg <- resolve_config(experiment = "biodiversity")
cfg  <- stage_cfg(pcfg, stage = 1)         # stage 1: calibrate, no be/ghg needed
write_project_start_script(cfg, pcfg, stage = 1)
```

This writes the script twice: into `scripts/start/projects/<name>.R`, where
MAgPIE's own start menu finds it, and into
`messageix/generated/start_scripts/<name>.R`, a retained copy for
reproducibility. Then, from the MAgPIE model root:

```
Rscript start.R
```

and pick option 8, "projects". MAgPIE lists the generated script; choosing it
submits it the normal way, same as any hand-written project script. Nothing
here polls the cluster or waits for the run to finish.

A price or demand run needs the price level(s) that run covers:

```r
cfg <- stage_cfg(pcfg, stage = 2, be = 5)          # one bioenergy price level
write_project_start_script(cfg, pcfg, stage = 2, be = 5)
```

The generator writes one script per run. A full price sweep (one run per
level in `prices_bioenergy`) or demand sweep (one run per bioenergy/GHG price
pair) means generating and submitting one script per level or pair, same menu
each time. `run_phase.R --phase=price` or `--phase=demand` runs the same loop
automatically when that suits better; both build from the same `stage_cfg()`.

## 3. Pack between phases and vet by eye

The calibration run's `fulldata.gdx` still has to be packed into the input
tarball the price sweep reads:

```
Rscript messageix/R/pack_price.R --experiment=biodiversity
```

Submit the price sweep as in step 2, one script per bioenergy level, then vet
it with your own plots; this mode adds no automated check of its own.

Once the price sweep looks right, pack its output for the demand sweep. This
needs the GHG price file (`f56_pollutant_prices.cs3`); nothing in this
repository builds it, so obtain it first (`Rscript messageix/R/pack_demand.R`
run with no `--f56` prints what it has to contain and who to ask):

```
Rscript messageix/R/pack_demand.R --experiment=biodiversity --f56=PATH
```

Submit the demand sweep as in step 2, one script per bioenergy/GHG pair. When
every run has reported, reduce it to the matrix MESSAGEix reads:

```
Rscript messageix/run.R matrix biodiversity
```

## What this mode does not do

Nothing here polls a running job, waits between phases, or chains one phase
into the next automatically. `messageix/run.R`, which does all three, remains
available and suits an unattended sweep better. This mode suits someone
submitting and watching runs by hand, one phase at a time.

## What to review

Everything this mode touches is already in the repository:

- `config/*.csv`, the narratives and designs a run declares
- `R/world_levers.R`, each lever's meaning, unit and default
- `R/start_script_gen.R`, what a generated start script contains
- `R/pack_price.R`, `R/pack_demand.R`, what gets packed between phases
- the `golden` experiment, the reproduction check a new narrative must pass

That is the whole review surface for this mode.
