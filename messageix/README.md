# messageix/ — MAgPIE → MESSAGEix land-use emulator pipeline

**Status: under construction** (target 2026-08-25).

A reproducible path from the pinned MAgPIE version (tag `v4.11.0`, branch
`iiasa-4.11.0`) to the land-use emulator matrix MESSAGEix consumes. Everything
the linkage adds lives under `messageix/`, and **no path outside this folder
differs from upstream `magpiemodel/magpie`** — merging a newer PIK tag is clean
by construction.

## Three concepts, two files

| Concept | Where | What it is |
| --- | --- | --- |
| the **world** | [`experiments.R`](experiments.R), `narrative()` | which SSP, which regions, how strictly biodiversity is protected, how costly yield improvements are |
| the **sampling plan** | [`experiments.R`](experiments.R), `design()` | which bioenergy and GHG price levels the two sweeps visit |
| the **engine** | [`run.R`](run.R) | the command that runs them |

Everything else — the phases, the waiting, the packing between phases, the
naming — is machinery below those two files, and you do not have to read it to
run an experiment.

## Before you can run anything

Two things come from outside this repository, and neither is in it. Get both
before you start: the first phase cannot begin without one, and the third cannot
be packed without the other.

1. **The MAgPIE input tarballs** — four archives, several GB in total, holding
   everything MAgPIE reads. They are downloaded from PIK's public repository if
   it is reachable from your machine, and otherwise have to be placed by hand in
   a directory MAgPIE searches. Which four, how MAgPIE finds them and where to
   get them: [`docs/inputs.md`](docs/inputs.md).
2. **The GHG price file** — `f56_pollutant_prices.cs3`, one column per GHG price
   level the demand sweep visits. **Nothing in this repository builds it**; ask
   Di Sheng for it. What it has to contain is written out in full by
   `Rscript messageix/R/pack_demand.R` run with no `--f56`, and described in
   [`docs/pipeline.md`](docs/pipeline.md).

`Rscript messageix/run.R status` reports on both without running anything.

## Quickstart

Edit `experiments.R`. An experiment is one list entry: a name, and what differs
from the defaults. Leave `design()` out and you get the grid the pipeline was
tested on, 7 bioenergy prices × 12 GHG prices = 84 demand runs — 92 MAgPIE runs
in all, once the one calibration run and the seven price runs are counted.

```r
EXPERIMENTS <- list(
  default      = experiment(narrative(), design()),
  biodiversity = experiment(narrative(bii_target = 0.78, yields_scenario = "cc"))
)
```

Then run it, from the MAgPIE model root (the directory holding
`config/default.cfg`):

```bash
Rscript messageix/run.R status                                    # what is finished, what would run
Rscript messageix/run.R --f56=/path/to/f56_pollutant_prices.cs3   # every experiment, in order
Rscript messageix/run.R biodiversity --f56=…                      # just this one
Rscript messageix/run.R matrix default                            # the reduce phase alone
Rscript messageix/run.R --help                                    # every flag, in full
```

An experiment goes through four phases — `calibrate`, `price`, `demand`,
`reduce` — and `run.R` runs them in order, waiting for the cluster between them,
skipping whatever is already finished, and packing what one phase produced into
the inputs the next reads. Everything is checked before the first run is
submitted. What each phase computes: [`docs/pipeline.md`](docs/pipeline.md).

Nothing else has to be filled in: the output folder, the run names, the matrix
file name and the input tarballs are worked out from the experiment's own name
and its region set, so two experiments cannot land in each other's folders and
the entry named `default` keeps the names the pinned runs have always had. A
misspelled setting, a value of the wrong type and one outside its range each
stop at the line they were written on, not 84 runs later.

`status` prints each experiment's identifier — `MESSAGEix_5ff27be8` for the
`default` experiment on the pinned R12 set — and that is the folder its runs go
into. `5ff27be8` is **MAgPIE's own code for the region mapping**, read out of the
input tarball's name; it is not a git hash. It changes when the region set
changes and at no other time, so a new MAgPIE version does not move anybody's
runs.

**The golden runs** are the validated reference runs behind
`magpie_input_SSP2_ref_woodfuel.csv`, the matrix this pipeline has to reproduce
before it is trusted with anything new. The `default` experiment is the one that
reproduces them; how that is checked is
[`docs/pipeline.md`](docs/pipeline.md) §10.

## Where the settings live

Each setting is documented once, in the file that owns it, beside the code that
reads it.

| Settings | Documented in | Changed by |
| --- | --- | --- |
| the world, one block per lever | [`R/world_levers.R`](R/world_levers.R) | `narrative()` in `experiments.R` |
| the sampling plan | `design_spec()` in [`R/utils_config.R`](R/utils_config.R) | `design()` in `experiments.R` |
| infrastructure: queue, modules, waiting, linkage constants | `infrastructure_spec()` in [`R/pipeline_infrastructure.R`](R/pipeline_infrastructure.R) | `MAGPIE_MM_*` per machine, `--set key=value` per command |
| derived names: folders, matrix, tarballs | [`R/pipeline_infrastructure.R`](R/pipeline_infrastructure.R) | nothing — setting one is an error |

`--set key=value` reaches every world and sampling-plan setting too
(`--set bii_target=0.74`), which is how a variation is tried without adding an
experiment.

## Extending the world

The levers `narrative()` accepts are registered in
[`R/world_levers.R`](R/world_levers.R), one self-contained block each, and that
registry is the only place they are listed — so adding a lever is adding a
block, and the file carries a worked example of each kind. A lever that changes
the input files rather than a `cfg$gms` value supplies the function that writes
them into the tarball packed for one phase, which the packing scripts already
ask for. A different region composition is not a lever at all: it is one entry
in `region_sets()` in
[`R/pipeline_infrastructure.R`](R/pipeline_infrastructure.R) plus its
region-name table in `data/`.

Levers outside the land system — carbon capture, transport, buildings — belong
to MESSAGEix, which this pipeline supplies rather than models.

## Layout

- `experiments.R` — the experiments: what to run
- `run.R` — the command: how to run them
- `R/` — everything else, flat: `pipeline.R` (the phases, the plan, the checks),
  `run_phase.R` (one phase of MAgPIE runs), `pack_price.R` / `pack_demand.R` (the
  packing between phases), `createMatrix_MM.R` / `add_woodfuel_to_matrix.R` (the
  reduce phase), and the shared layer — settings, naming, logging, environment
- `data/` — the region-name table, and the variable mapping the matrix is built with
- `docs/` — `pipeline.md` (the science), `inputs.md` (the input tarballs: which
  ones, how MAgPIE finds them, where to get them), `decisions.md` (why it is
  built this way, and what is open)
- `NOTICE` — the upstream project, the licence relationship, and who wrote what

`run_phase.R`, the two packing scripts and the two reduce scripts are the
debugging surface: each also runs on its own
(`Rscript messageix/R/pack_price.R --experiment=NAME`) when one step has to be
rebuilt or watched alone. Every R entry point takes `--help` and accepts each
option both as `--key=value` and as `--key value`. Start with
[`docs/pipeline.md`](docs/pipeline.md) for what the pipeline computes and
[`docs/inputs.md`](docs/inputs.md) for what you need before you can run it.

## Two things that surprise people

- **A dirty working tree after a run is normal.** `core/sets.gms`, `main.gms`
  and every module `input.gms`/`sets.gms` are regenerated from `cfg$input` and
  `cfg$gms` on every run, and are never committed — the region set travels in
  the input tarball and the configuration travels in `experiments.R`. See
  [`docs/decisions.md`](docs/decisions.md), Q9.
- **Upstream's root `.gitignore` matches `*.cs*`**, which catches CSV files
  under `messageix/` too. `messageix/.gitignore` un-ignores the two tables in
  `data/`; any other new `.csv` or `.cs3` here has to be staged with
  `git add -f`. The root `.gitignore` stays untouched — no path outside
  `messageix/` differs from upstream.

## Attribution

The science and pipeline are Di Sheng's work; this overlay packages them.
See [`NOTICE`](NOTICE).
