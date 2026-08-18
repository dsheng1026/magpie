# messageix/ — MAgPIE → MESSAGEix land-use emulator pipeline

**Status: under construction** (target 2026-08-25).

This overlay consolidates the MESSAGE–MAgPIE linkage into one place: a
reproducible path from the pinned MAgPIE version (tag `v4.11.0`, branch
`iiasa-4.11.0`) to the land-use emulator matrix MESSAGEix consumes.

## Pipeline

1. **Reference tau** — one run calibrated against BAU second-generation bioenergy demand; exports the tau trajectory
2. **Extract tau** → generate the step-2 patch tarball
3. **Price-driven** — 7 runs across bioenergy price incentives, GHG price 0, tau exogenous
4. **Extract updated bioenergy demand + carbon price trajectories** → generate the step-3 patch tarball
5. **Demand-driven** — 7 × 12 = 84 runs across GHG price trajectories, tau endogenous
6. **Matrix generation** — 84 report.mif via MM_linkage_mapping.csv, plus woodfuel from fulldata.gdx

Patch tarballs are MAgPIE's project-override mechanism (selective overrides on
top of the version-pinned base input tarball), generated fresh on a first run.

## Layout

- `inputs/` — input tarball signpost (how to obtain and place the pinned R12 tarball)
- `start/` — parameterised pipeline start scripts
- `patches/` — patch-tarball generators
- `emulator/` — matrix generation, merged from dsheng1026/MAgPIE_emulator
- `presets/` — scenario configuration, one column per narrative
- `docs/` — pipeline science documentation

## Attribution

The science and pipeline are Di Sheng's work; this overlay packages them.
See `NOTICE`.
