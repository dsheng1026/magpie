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
   get them: [`docs/tool-surface.md`](docs/tool-surface.md), section 4.
2. **The GHG price file** — `f56_pollutant_prices.cs3`, one column per GHG price
   level the demand sweep visits. **Nothing in this repository builds it**; ask
   Di Sheng for it. What it has to contain is written out in full by
   `Rscript messageix/R/pack_demand.R` run with no `--f56`, and described in
   [`docs/pipeline.md`](docs/pipeline.md).

`Rscript messageix/run.R status` reports on both without running anything.

## Quickstart

Edit the CSVs under `config/` — that is where the three experiments this
pipeline ships (`default`, `golden`, `biodiversity`) are declared, and where a
new one goes. A column is a name and what differs from the defaults; an empty
cell keeps the grid the pipeline was tested on, 7 bioenergy prices × 12 GHG
prices = 84 demand runs — 92 MAgPIE runs in all, once the one calibration run
and the seven price runs are counted. `experiments.R` loads them:

```r
EXPERIMENTS <- experiments_from_csv(
  narratives = c("messageix/config/narratives_base.csv",
                 "messageix/config/narratives_biodiversity.csv"),
  designs    = "messageix/config/designs.csv")
```

The columns of both files, and how to add or layer one, are below in
[The experiments as CSV](#the-experiments-as-csv). Writing an experiment
directly in R — for a one-off run or a generated sweep — is the alternative,
documented in `experiments.R` itself.

Then run it, from the MAgPIE model root (the directory holding
`config/default.cfg`):

```bash
Rscript messageix/run.R status                                    # what is finished, what would run
Rscript messageix/run.R --f56=/path/to/f56_pollutant_prices.cs3   # every experiment except golden, in order
Rscript messageix/run.R biodiversity --f56=…                      # just this one
Rscript messageix/run.R golden --f56=…                            # the golden reproduction check -- opt-in only
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
the entry named `golden` keeps the names the pinned runs have always had. A
misspelled setting, a value of the wrong type and one outside its range each
stop at the line they were written on, not 84 runs later.

`status` prints each experiment's identifier — `MESSAGEix_5ff27be8` for the
`golden` experiment on the pinned R12 set — and that is the folder its runs go
into. `5ff27be8` is **MAgPIE's own code for the region mapping**, read out of the
input tarball's name; it is not a git hash. It changes when the region set
changes and at no other time, so a new MAgPIE version does not move anybody's
runs.

**The golden runs** are the validated reference runs behind
`magpie_input_SSP2_ref_woodfuel.csv`, the matrix this pipeline has to reproduce
before it is trusted with anything new. The `golden` experiment is the one that
reproduces them, and it is opt-in: left out of a bare `Rscript messageix/run.R`
so a routine sweep does not spend a calibration run and 84 demand runs
re-proving it, and run only when named explicitly. How the reproduction is
checked is [`docs/pipeline.md`](docs/pipeline.md) §10.

## Where the settings live

Each setting is documented once, in the file that owns it, beside the code that
reads it.

| Settings | Documented in | Changed by |
| --- | --- | --- |
| the world, one block per lever | [`R/world_levers.R`](R/world_levers.R) | a narrative CSV, or `narrative()` in `experiments.R` |
| the sampling plan | `design_spec()` in [`R/utils_config.R`](R/utils_config.R) | a design CSV, or `design()` in `experiments.R` |
| infrastructure: queue, modules, waiting, linkage constants | `infrastructure_spec()` in [`R/pipeline_infrastructure.R`](R/pipeline_infrastructure.R) | `MAGPIE_MM_*` per machine, `--set key=value` per command |
| `project`: share one calibration run across experiments | `infrastructure_spec()` in [`R/pipeline_infrastructure.R`](R/pipeline_infrastructure.R) | `MAGPIE_MM_PROJECT`, `--set project=...` per command |
| derived names: folders, matrix, tarballs | [`R/pipeline_infrastructure.R`](R/pipeline_infrastructure.R) | nothing — setting one is an error |

`--set key=value` reaches every world and sampling-plan setting too
(`--set bii_target=0.74`), which is how a variation is tried without adding an
experiment.

### Sharing one calibration run across a project

`project` (`MAGPIE_MM_PROJECT`) is empty by default, which keeps today's
one-experiment-one-folder rule: stage 1 (`calibrate`) writes to its own
experiment's output folder. Set it and stage 1 writes to
`output/_calibration/<project>/tau` instead, so every experiment sharing that
project name reuses the same calibration run rather than each solving its own.
That is worth doing when several experiments in one project agree on
everything the reference land-use intensity trajectory depends on (SSP,
region set, the stage-1 protection and bioenergy-demand scenarios, `bii_target`
and the input tarballs) and differ only downstream, in the price or demand
sweep — reusing tau then saves a calibration run per experiment instead of
buying anything.

Tau is fixed per project: the folder is addressed by the project's name, not
the experiment's, so it can only ever hold one calibration. If an experiment
sharing a project asks for settings that differ from what is already recorded
there, the pipeline stops with an error naming the settings that differ and
their two values, rather than re-solving into the same folder and silently
overwriting what an earlier experiment left there. Rename the project so the
experiment gets its own calibration, or align its settings with the ones the
project already recorded.

`project` becomes a path segment, a SLURM job name and an rsync argument, so it
takes letters, digits, dash and underscore only, the same as an experiment
name.

## The experiments as CSV

CSV is the primary surface: `config/narratives_base.csv`,
`config/narratives_biodiversity.csv` and `config/designs.csv` declare the
three experiments this pipeline ships, and `experiments.R` just loads them.
Reach for CSV first — it is what a project with many settings, a sweep that
reads better as a table, or a config file a collaborator sends carries
naturally. The loaders in [`R/utils_config_csv.R`](R/utils_config_csv.R) call
the same `narrative()` and `design()` constructors `experiments.R` would call
directly, so the levers, their types and their checks are identical either way
and nothing below `experiments.R` knows which surface was used.

```r
EXPERIMENTS <- experiments_from_csv(
  narratives = c("messageix/config/narratives_base.csv",
                 "messageix/config/narratives_biodiversity.csv"),
  designs    = "messageix/config/designs.csv")
```

Writing an experiment directly in R remains available — for a one-off run or a
generated sweep, documented in `experiments.R` itself — and the two surfaces
coexist: `c(EXPERIMENTS, list(name = experiment(...)))` adds an R-declared
experiment to the ones read from CSV. Give it a name the CSVs do not use — a
name declared on both surfaces is an error (`load_experiments()` dies on it),
not a silent override — and `--set key=value` still reaches every setting of
both.

### The shape of both files

MAgPIE's own `scenario_config.csv` convention: **the first column names the
setting and every further column is one narrative**, its header the experiment's
name. The header cell of the first column is ignored, `#` lines are comments,
and the delimiter is whichever of `;` and `,` the header row uses — a
semicolon-delimited European export needs no conversion.

```
;ssp2;biodiversity
bii_target;0;0.78
yields_scenario;nocc;cc
```

| Cell | Means |
| --- | --- |
| a value | that setting takes it, coerced to the type the setting declares |
| empty | that setting is not set here — it keeps what an earlier file, or the default, gave it |
| `0\|5\|7\|10` | a vector, for a lever or design row that takes one: `\|` separates the levels, and spaces do too where they are numbers (`0 5 7 10`) |
| `gms$<switch>` cell | always a scalar — a MAgPIE switch is not a vector here, and a `\|` in one is refused rather than split |

A column name becomes an output folder and a scenario column, so it takes
letters, digits, dash and underscore only. A row naming something that is not a
setting stops the read, naming the file and the row — a misspelled lever never
runs 84 runs of the wrong world.

### Narrative CSV rows

| Row | What it sets |
| --- | --- |
| any lever registered in [`R/world_levers.R`](R/world_levers.R) | that lever. Each block there carries the lever's meaning, its unit, what it may be and its default — this file is the only place they are listed, and the CSV enumerates it rather than holding a list of its own |
| `gms$<switch>` | a MAgPIE switch this pipeline does not otherwise expose, e.g. `gms$food`. A switch the pipeline decides for itself is refused, and the message names the lever to set instead |
| `base` | the narrative this column inherits from, for layering (below) |

`Rscript -e 'source("messageix/R/world_levers.R"); cat(lever_names(), sep="\n")'`
prints the rows a narrative CSV may carry.

### Design CSV rows

Two rows, both grids of price levels, both integer-valued and non-negative.
Their meaning and their defaults are declared in `design_spec()` in
[`R/utils_config.R`](R/utils_config.R); the columns are narrative names, as
above.

| Row | What it sets | Typical | Default |
| --- | --- | --- | --- |
| `prices_bioenergy` | the bioenergy price levels the price sweep visits, USD2005/GJ. One price run each | `0\|5\|7\|10\|15\|25\|45` | the tested grid, 7 levels |
| `prices_ghg` | the GHG price levels the demand sweep visits. Each names one column of `f56_pollutant_prices.cs3` rather than being a price itself | `0\|100\|500\|1000\|4000` for a coarse sweep | the tested grid, 12 levels |

The two multiply: 7 × 12 is the 84 demand runs the default grid is made of.

### Layering

The loaders take several files and read them in order. **A narrative named in
two files keeps everything the earlier file gave it and takes the later file's
values only for the settings that file names.** That is the point of the CSV
surface: a shared defaults file, then a project file that changes one lever and
touches nothing else.

```
# defaults.csv               # project.csv, read second
setting,ssp2                 setting;ssp2
bii_target,0                 bii_target;0.78
yields_scenario,nocc
```

`ssp2` comes out with `bii_target = 0.78` and `yields_scenario = "nocc"`.

Where the project file names its narrative something of its own, the `base` row
says what to start from — any narrative already read, in this file above it or
in an earlier one. `config/narratives_biodiversity.csv` is the worked example:
layered over `config/narratives_base.csv`, it starts `biodiversity` from that
file's `default` column and changes only two levers:

```
setting;biodiversity
base;default
bii_target;0.78
yields_scenario;cc
```

A column that names neither an earlier file's narrative nor a `base` starts from
the registered defaults. Design CSVs layer the same way, and a design column
naming no narrative is refused rather than silently dropped.

### Committing one

Upstream's root `.gitignore` matches `*.cs*`. `messageix/.gitignore` un-ignores
`config/*.csv`, so a config file placed there is staged normally; one placed
anywhere else under `messageix/` needs `git add -f`.

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

- `experiments.R` — loads the experiments declared in `config/`; also where an
  experiment can be declared directly in R
- `run.R` — the command: how to run them
- `R/` — everything else, flat: `pipeline.R` (the phases, the plan, the checks),
  `run_phase.R` (one phase of MAgPIE runs), `pack_price.R` / `pack_demand.R` (the
  packing between phases), `createMatrix_MM.R` / `add_woodfuel_to_matrix.R` (the
  reduce phase), `utils_config_csv.R` (experiments read from CSV), and the
  shared layer — settings, naming, logging, environment
- `config/` — the narrative and design CSVs that declare the pipeline's
  experiments, the primary surface for adding or changing one
- `data/` — the region-name table, and the variable mapping the matrix is built with
- `docs/` — `tool-surface.md` (every setting, the run command, the inputs you
  need first, and the open questions), `pipeline.md` (the science),
  `decisions.md` (why it is built this way, and what is open)
- `NOTICE` — the upstream project, the licence relationship, and who wrote what

`run_phase.R`, the two packing scripts and the two reduce scripts are the
debugging surface: each also runs on its own
(`Rscript messageix/R/pack_price.R --experiment=NAME`) when one step has to be
rebuilt or watched alone. Every R entry point takes `--help` and accepts each
option both as `--key=value` and as `--key value`. Start with
[`docs/tool-surface.md`](docs/tool-surface.md) for the settings and what you
need before you can run it, and [`docs/pipeline.md`](docs/pipeline.md) for what
the pipeline computes.

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
