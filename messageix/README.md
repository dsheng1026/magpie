# messageix/ — MAgPIE → MESSAGEix land-use emulator pipeline

**Status: under construction** (target 2026-08-25).

This overlay consolidates the MESSAGE–MAgPIE linkage into one place: a
reproducible path from the pinned MAgPIE version (tag `v4.11.0`, branch
`iiasa-4.11.0`) to the land-use emulator matrix MESSAGEix consumes.

Everything the linkage adds lives under `messageix/`. **No path outside this
folder differs from upstream `magpiemodel/magpie`** — merging a newer PIK tag is
clean by construction.

## Pipeline

1. **Reference tau** — one run calibrated against BAU second-generation bioenergy demand; exports the tau trajectory
2. **Extract tau** → generate the step-2 patch tarball
3. **Price-driven** — 7 runs across bioenergy price incentives, GHG price 0, tau exogenous
4. **Extract updated bioenergy demand + carbon price trajectories** → generate the step-3 patch tarball
5. **Demand-driven** — 7 × 12 = 84 runs across GHG price trajectories, tau endogenous
6. **Matrix generation** — 84 report.mif via MM_linkage_mapping.csv, plus woodfuel from fulldata.gdx

Patch tarballs are MAgPIE's project-override mechanism (selective overrides on
top of the version-pinned base input tarball), generated fresh on a first run
and named with a content hash so regeneration is never a silent no-op.

Runs happen on the PIK cluster: roughly 1 GB per run, ~90 GB for a full
emulator generation.

> Note: upstream MAgPIE's root `.gitignore` matches `*.cs*`, which catches CSV files
> under `messageix/` too. The tracked preset CSV is unaffected, but a NEW `.csv` or
> `.cs3` file added under `messageix/` must be staged with `git add -f`. The
> `.gitignore` itself stays untouched — no path outside `messageix/` differs from
> upstream.

## Layout

- `R/` — shared layer: config resolution, the naming contract, logging, execution environment, run assertions
- `start/` — the three stage drivers (tau, price-driven, demand-driven) and the shared runner
- `patches/` — patch-tarball generators for steps 1.5 and 2.5
- `emulator/` — matrix generation and woodfuel post-processing, merged from dsheng1026/MAgPIE_emulator
- `presets/` — scenario configuration, one column per narrative; `default` reproduces the golden runs
- `inputs/` — input tarball signpost: how to obtain and place the pinned R12 tarball
- `docs/` — `pipeline.md` (the science), `decisions.md` (why it is built this way, and what is open)

Start here: `docs/pipeline.md` for what the pipeline computes, `inputs/README.md`
for what you need before you can run it.

## Running MAgPIE mutates tracked files

`core/sets.gms`, `main.gms` and every module `input.gms`/`sets.gms` are
regenerated from `cfg$input` and `cfg$gms` on every run. **A dirty working tree
after a run is normal, and those files are never committed** — the region set
travels in the input tarball and the configuration travels in
`presets/scenario_config.csv`. See `docs/decisions.md`, Q9.

## Attribution

The science and pipeline are Di Sheng's work; this overlay packages them.
See `NOTICE`.
