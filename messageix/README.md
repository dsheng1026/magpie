# messageix/ — MAgPIE → MESSAGEix land-use emulator pipeline

**Status: under construction** (target 2026-08-25).

This overlay consolidates the MESSAGE–MAgPIE linkage into one place: a
reproducible path from the pinned MAgPIE version (tag `v4.11.0`, branch
`iiasa-4.11.0`) to the land-use emulator matrix MESSAGEix consumes.

Everything the linkage adds lives under `messageix/`. **No path outside this
folder differs from upstream `magpiemodel/magpie`** — merging a newer PIK tag is
clean by construction.

## Pipeline

Six steps. A **stage** is one of the three groups of MAgPIE runs; a **step** is
one of the six units the pipeline driver runs, named here as the driver names
them.

1. `stage1_tau` — **reference tau**: one run calibrated against business-as-usual second-generation bioenergy demand, which exports the land-use intensity trajectory (tau)
2. `patch_step2` — **extract tau** → the patch tarball stage 2 reads
3. `stage2_price` — **price-driven**: 7 runs across bioenergy price incentives, GHG price 0, tau held fixed
4. `patch_step3` — **extract the realised bioenergy demand + the GHG price trajectories** → the patch tarball stage 3 reads
5. `stage3_demand` — **demand-driven**: 7 × 12 = 84 runs across GHG price trajectories, tau solved for
6. `matrix` — **matrix generation**: 84 report.mif through MM_linkage_mapping.csv, plus woodfuel from fulldata.gdx

A patch tarball is MAgPIE's project-override mechanism — selective overrides on
top of the version-pinned base input tarballs. The pipeline builds them fresh and
names them with a digest of their contents, so rebuilding one is never a silent
no-op.

Runs happen on the PIK cluster: roughly 1 GB per run, ~90 GB for a full
emulator generation.

## Defining and running narratives

A **narrative** is a column of [`presets/narratives.csv`](presets/narratives.csv). That file is
the experiment design and nothing else: rows are the settings a narrative varies, columns are
the narratives you want to compare. Nothing in the code lists them — adding a narrative to the
experiment means adding a column, and that is the only editing surface.

```
key;default;biodiversity
ssp;SSP2;SSP2
region_set;R12;R12
bii_target;0;0.78
mp_substitution;0;0
protect_scenario;none;none
protect_scenario_step1;BH;BH
yields_scenario;nocc;cc
tc_cost;high;high
cropland_max_growth;0.02;0.02
bii_missing_cost;10000000;10000000
nonco2_price_cap_usd17_tc;200;200
be_prices;0,5,7,10,15,25,45;0,5,7,10,15,25,45
ghg_prices;0,10,20,50,100,200,400,600,1000,2000,3000,4000;0,10,20,50,100,200,400,600,1000,2000,3000,4000
```

**The recipe.** Copy the `default` column and change what the narrative is about. That is the
whole of it — the shipped `biodiversity` column is the recipe worked through, differing in two
cells: a biodiversity-intactness target of 0.78, and crop yields that carry climate change
impacts.

Nothing else has to be filled in, because everything a narrative needs beyond its own settings
is worked out for it:

| Worked out | Rule | `biodiversity` gets |
| --- | --- | --- |
| the output folder | the region code plus the column name | `output/MESSAGEix_5ff27be8_biodiversity/` |
| the run names inside it | the position in the sweep | `tau`, `BE05`, `BE05_G0400` |
| the matrix file | the SSP plus the column name | `magpie_input_SSP2_biodiversity_woodfuel.csv` |
| the input tarballs and the region-name table | whatever `region_set` pairs them with | the pinned R12 set |

So two narratives cannot land in each other's folders, and the `default` column keeps the names
the pinned runs have always had. The file is semicolon-delimited, which is what Excel opens
natively on a European locale; a cell may hold a comma-separated list without quoting.

Every setting, what it means and what it may be — plus the operational settings that live in
code and how to override them for one machine or one command — is in
[`docs/parameters.md`](docs/parameters.md).

## How to run it

From the MAgPIE model root (the directory holding `config/default.cfg`), there
are three levels, each the front door for a different question.

**The experiment — every narrative.** `driver_ensemble.R` runs the full pipeline
for each narrative in turn:

```bash
Rscript messageix/start/driver_ensemble.R --f56=/path/to/f56_pollutant_prices.cs3
Rscript messageix/start/driver_ensemble.R --presets=default,biodiversity
Rscript messageix/start/driver_ensemble.R --list        # the plan, narrative by narrative
```

With no `--presets` it runs every column of the narratives file. It checks the whole
set before starting anything — every narrative's preset resolves, its GHG price
file carries what that narrative asks of it, no two narratives write to the same
place — and it narrates a plan you can read before committing cluster time.
Narratives run one at a time, so a reference run solved for one is used again by
the next whenever their settings agree; where they do not — whether the run is
already on disk or an earlier narrative of this same experiment is about to write
it — the plan says the reference run will be solved again rather than letting the
pipeline discover it halfway through.

**A narrative that fails ends the experiment.** The narratives after it are
reported "not reached" and nothing of theirs is started; an unattended run that
carries on through a broken cluster wastes days. `--keep-going` asks for the
opposite: the failure goes into the closing summary and the next narrative
starts. Either way, running the experiment again picks up where it stopped.

**One narrative.** `driver_pipeline.R` runs all six steps for a single column:

```bash
Rscript messageix/start/driver_pipeline.R --f56=/path/to/f56_pollutant_prices.cs3
```

It starts each step as its own process, waits between stages until every run has
solved — and, after stage 3, until every run has written its `report.mif`, which
is what the matrix step reads — and skips whatever is already finished, so
re-running after a failure picks up where it stopped. `--f56` supplies the GHG
price trajectories, which nothing here generates; before the first run is
submitted it is checked against the narrative, column by column and year by year,
not merely for existing.

Look before you leap:

```bash
Rscript messageix/start/driver_pipeline.R --list        # the six steps, what is finished, and what would stop the run
Rscript messageix/start/driver_pipeline.R --validate    # check the whole span, print the assembled configs
Rscript messageix/start/driver_pipeline.R --help
```

`--validate` is the rehearsal for a tree where nothing has been built yet.
`--dry-run` assembles the real run configs instead, so it needs each stage's patch
tarball to be on disk already — pre-flight says so before anything runs.

Part of the pipeline: `--from=STEP`, `--until=STEP`, `--skip=STEP[,STEP]`, and
`--force=STEP[,STEP]` to re-run a step that is already finished (naming a step the
span leaves out is an error, not a no-op). `--preset=NAME` picks the narrative;
the ensemble driver takes all of these too and passes them through to every
narrative it runs.

**Leaving it running.** A narrative waits out three stages of cluster runs, up to
48 hours each, and an experiment does that once per narrative — days, in a process
a login node will eventually kill. `--submit`, on either driver, writes a job
script to `output/messageix_jobs/` and hands the whole command to SLURM using the
preset's own queue, modules and notification address:

```bash
Rscript messageix/start/driver_ensemble.R --f56=/path/to/f56_pollutant_prices.cs3 --submit
```

The job asks for the wait limit once per stage it will wait for, plus two hours,
and carries a job name of its own so the wait does not mistake the orchestrator
for one of the runs it is waiting for. Where there is no scheduler, background it
by hand instead:

```bash
nohup Rscript messageix/start/driver_pipeline.R --f56=/path/to/f56_pollutant_prices.cs3 \
      > pipeline.log 2>&1 &
tail -f pipeline.log
```

**One step at a time.** Both drivers run exactly these commands, and they
remain the interface for running, debugging or re-running a single step:

```bash
Rscript messageix/start/driver_step1_tau.R                      # stage1_tau    reference tau
Rscript messageix/patches/build_step2_patch.R                   # patch_step2   tau -> stage 2's patch tarball
Rscript messageix/start/driver_step2_price.R                    # stage2_price  bioenergy price sweep
Rscript messageix/patches/build_step3_patch.R --f56=PATH        # patch_step3   demand + GHG prices -> stage 3's patch tarball
Rscript messageix/start/driver_step3_demand.R                   # stage3_demand emulator training set
bash    messageix/emulator/run_matrix.sh                        # matrix        matrix + woodfuel, on the cluster
```

Each takes `--help`. Every option of every R entry point is accepted both as
`--key=value` and as `--key value`; `run_matrix.sh` is a shell wrapper and takes
the `--key value` form only. The matrix wrapper is the one to use when the matrix
step should go to SLURM rather than run where you are standing; the pipeline
driver runs the two matrix scripts directly.

> Note: upstream MAgPIE's root `.gitignore` matches `*.cs*`, which catches CSV files
> under `messageix/` too. The tracked narratives file is unaffected, but a NEW `.csv` or
> `.cs3` file added under `messageix/` must be staged with `git add -f`. The
> `.gitignore` itself stays untouched — no path outside `messageix/` differs from
> upstream.

## Layout

- `R/` — shared layer: config resolution, the naming contract, logging, execution environment, run assertions
- `start/` — the experiment driver (`driver_ensemble.R`, a set of narratives), the
  pipeline driver (`driver_pipeline.R`, one narrative end to end), the three stage
  drivers (tau, price-driven, demand-driven) and the shared runner
- `patches/` — the two patch-tarball builders, `patch_step2` and `patch_step3`
- `emulator/` — matrix generation and woodfuel post-processing
- `presets/` — `narratives.csv`, one column per narrative (`default` reproduces the golden
  runs), plus the region-name table that translates MAgPIE's region codes into MESSAGEix names
- `inputs/` — input tarball signpost: how to obtain and place the pinned R12 tarball
- `docs/` — `pipeline.md` (the science), `parameters.md` (every setting), `decisions.md` (why it is built this way, and what is open)

Start here: `docs/pipeline.md` for what the pipeline computes, `inputs/README.md`
for what you need before you can run it.

## Running MAgPIE mutates tracked files

`core/sets.gms`, `main.gms` and every module `input.gms`/`sets.gms` are
regenerated from `cfg$input` and `cfg$gms` on every run. **A dirty working tree
after a run is normal, and those files are never committed** — the region set
travels in the input tarball and the configuration travels in
`presets/narratives.csv`. See `docs/decisions.md`, Q9.

## Attribution

The science and pipeline are Di Sheng's work; this overlay packages them.
See `NOTICE`.
