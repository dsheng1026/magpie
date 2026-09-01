# The tool surface

What every setting is and why it exists, how an experiment is declared, what one
command does underneath it, where the seams are, and what is still open. Written
for a MAgPIE-side reader who knows the model and wants to know what this overlay
adds around it.

For the short path — declare a narrative, generate a start script, run the two
sweeps, reduce to a matrix — see [`lightweight-mode.md`](lightweight-mode.md)
instead; this page is the full reference.

Two other pages remain. [`pipeline.md`](pipeline.md) holds the science: what tau
is, how the patch tarballs work inside MAgPIE, how the matrix and the woodfuel
step are built, and how a build is validated. [`decisions.md`](decisions.md) is
the decision log: why each choice was made and what is unresolved. This page
holds the surface and the settings, and it absorbs the earlier
`parameters.md` and `inputs.md` pages.

**Contents.** 1 What the tool is. 2 Declaring an experiment. 3 The settings
reference. 4 What you need before you can run. 5 One command, and what happens
underneath. 6 Modularity. 7 Why it is built this way. 8 Open questions.

---

## 1. What the tool is

`messageix/` turns a MAgPIE checkout into a repeatable producer of one artefact:
the land-use emulator matrix MESSAGEix reads. The matrix answers one question
for MESSAGEix, which is how much second-generation bioenergy land can deliver at
a given bioenergy price and GHG price, and what land outcomes follow. Producing
it takes 92 MAgPIE runs in the tested configuration: one calibration run, seven
price runs, and 84 demand runs on a 7 by 12 price grid. The tool declares those
92 runs from a short description of the world they are made in, submits them in
the right order, packs the output of each phase into the input of the next,
waits for the cluster, and reduces the finished runs to the matrix. Everything
it adds lives under `messageix/`, so no path outside that folder differs from
upstream `magpiemodel/magpie` and a merge of a newer PIK tag stays clean.

---

## 2. Declaring an experiment

### The two halves

An experiment is a world and a plan for sampling it.

| Half | Constructor | What it decides |
| --- | --- | --- |
| the world | `narrative()` | which SSP, which region set, how strictly biodiversity is protected, how costly yield improvements are |
| the sampling plan | `design()` | which bioenergy price levels the price sweep visits, and which GHG price levels the demand sweep visits |

`experiment(narrative(), design())` puts the two together.
`messageix/experiments.R` holds a named list of them, loaded from the CSVs
under `messageix/config/` — the primary surface, detailed in "The CSV surface"
below:

```r
EXPERIMENTS <- experiments_from_csv(
  narratives = c("messageix/config/narratives_base.csv",
                 "messageix/config/narratives_biodiversity.csv"),
  designs    = "messageix/config/designs.csv")
```

Written out in the constructors the loader calls, the three entries this
resolves to are:

```r
list(
  default      = experiment(narrative(), design()),
  golden       = experiment(narrative(nonco2_price_cap_usd17_tc = 200,
                                      tc_cost = "high",
                                      protect_scenario_step1 = "BH")),
  biodiversity = experiment(narrative(bii_target = 0.78, yields_scenario = "cc"))
)
```

### `default` and `golden`

Two of those entries are reference points and it matters which is which.

**`default`** is the registry defaults with nothing overridden. Since 2026-08-31
those defaults carry the Earth Commission values decided in the 2026-08-25
session: a non-CO2 price cap of 734, `tc_cost = "medium"`, and step-1 protection
`"none"`. It is the world to start a new experiment from.

**`golden`** pins the three values the golden runs were made with, before the
defaults moved: cap 200, `tc_cost = "high"`, step-1 protection `"BH"`. It is the
experiment that rebuilds `magpie_input_SSP2_ref_woodfuel.csv`, the validated
reference this pipeline has to reproduce before it is trusted with anything new.
Run it after a version bump, a tarball change, or any edit to the phase logic.

The split exists because the two jobs pull in opposite directions. A default
that tracks the current scientific decision is what a new experiment should
inherit. A reproduction target has to stay frozen. Keeping both in one entry
would mean one of the two silently drifting.

`golden` owns the pinned reference paths. It is the experiment the naming rules
special-case, so it writes `output/MESSAGEix_5ff27be8/` and
`magpie_input_SSP2_ref_woodfuel.csv`, the paths the pinned runs have always had.
Reproduction is therefore regeneration in place: the reference file is rebuilt
rather than compared against a copy under another name. `default` takes a name
token like any other experiment, `output/MESSAGEix_5ff27be8_default/` and
`magpie_input_SSP2_default_woodfuel.csv`.

`golden` is opt-in. A bare `Rscript messageix/run.R` runs every experiment
except this one, so a routine command does not spend a calibration run and 84
demand runs re-proving the reference. It runs when it is named:
`Rscript messageix/run.R golden`.

Both constructors take overrides only. Whatever an entry leaves unnamed keeps
the registered default, so an experiment reads as the short list of what makes
it different. The name on the left becomes the output folder, the matrix file
name, and the bioenergy demand column the phases hand to each other, so it takes
letters, digits, dash and underscore.

The split between the two halves: the world is everything that would still be true if
the sampling grid were finer. The sampling plan is everything that decides how
many runs there are. A biodiversity target is a world setting. A twelve-level
GHG price grid is a sampling plan.

### The lever registry

The settings `narrative()` accepts are registered in
[`../R/world_levers.R`](../R/world_levers.R), one block per lever. A block
carries the lever's meaning, its unit, what values it may take, its default, and
how it reaches MAgPIE. Nothing else in the pipeline holds a list of levers, and
no document restates them, so adding a lever is adding a block. Section 3 below
is generated by hand from that registry and follows it; where the two disagree,
the registry is right.

A lever declares one of three mechanism classes, which is the whole of how a
lever can work:

- **`switch`** puts a value on `cfg$gms`. Three constructors cover it.
  `to_switch()` writes the value straight onto a named MAgPIE switch.
  `by_phase_logic()` hands it to the phase logic in `R/utils_config.R`, for a
  lever whose value differs by phase or moves a second switch with it.
  `by_scenario_config()` selects one of MAgPIE's own stock scenario
  configurations.
- **`data`** changes the input files the runs read. The lever names the phase
  and supplies a function that writes its files into the tarball packed for that
  phase. The packing scripts already call it. No data lever is registered yet.
  The class exists so the first one is a block in the registry rather than an
  edit to the packing scripts.
- **`structural`** changes the shape of the world rather than a value in it.
  `region_set` is the only one. It resolves through `region_sets()` in
  `R/pipeline_infrastructure.R`, which pairs a region set with its four input
  tarballs and its region-name table.

### What validation catches

Validation happens where a value is written, in three layers.

1. **The setting must exist.** `narrative(bi_target = 0.78)` stops on the
   misspelling and prints the registered lever names. A price grid passed to
   `narrative()` stops with a message pointing at `design()`.
2. **The type must hold.** Each lever declares `num`, `chr`, `lgl`, `num_vec`,
   or `chr_vec`, and the value is coerced to it. `bii_target = "high"` stops.
3. **The lever's own `check()` must pass.** `bii_target` has to lie in `[0, 1)`.
   `cropland_max_growth` has to be positive. `nonco2_price_cap_usd17_tc` has to
   be positive.

A fourth guard sits beside these. `narrative(gms = list(...))` reaches MAgPIE
switches the pipeline does not expose, and it refuses any switch the pipeline
decides for itself. The refusal names the lever to set instead. The effect is
that a mistake stops at the line it was written on rather than 84 runs later.

### The CSV surface

CSV is the primary surface for declaring an experiment. The 2026-08-25 session
decided narrative and design configuration returns to CSV — a project with many
settings reads better as a table, layered overrides are natural in that shape,
and a config file sent by a collaborator can be run directly — and
`messageix/experiments.R` now loads the three experiments this pipeline ships
(`default`, `golden`, `biodiversity`) from the files under `messageix/config/`
rather than declaring them in R. The importer is
[`../R/utils_config_csv.R`](../R/utils_config_csv.R).

The loader is an importer over the constructors rather than a second
configuration system. It reads a table, coerces each cell to the type the
setting declares, and calls `narrative()` or `design()` with the result. The
lever registry stays the only authority on what a setting means and what it may
be, and nothing below `experiments.R` knows a CSV was involved. Every row name a
CSV may carry is a setting named in section 3.

The file shape follows MAgPIE's own `scenario_config.csv` convention. The first
column names the setting, and every further column is one narrative with its
name in the header:

```
;ssp2;biodiversity
bii_target;0;0.78
yields_scenario;nocc;cc
```

Four reading rules cover the rest. An empty cell sets nothing and leaves the
setting at whatever an earlier file or the default gave it. A `#` line is a
comment. The delimiter is whichever of `;` and `,` the header row uses, so a
semicolon-delimited European export needs no conversion. A cell holding several
values separates them with `|`, and numbers may use spaces instead, so
`0|5|7|10` and `0 5 7 10` are the same grid.

A narrative CSV takes any registered lever as a row, plus `gms$<switch>` for a
MAgPIE switch the pipeline does not expose, plus `base`. A design CSV takes
`prices_bioenergy` and `prices_ghg`. Any other row name stops the read and names
the file and the row.

**Layering** is the part that motivated the decision. The loaders take several
files and read them in order. A narrative named in two files keeps everything
the earlier file gave it and takes the later file's values only for the settings
that file names:

```r
EXPERIMENTS <- experiments_from_csv(
  narratives = c("messageix/config/narratives_base.csv",
                 "messageix/config/narratives_biodiversity.csv"),
  designs    = "messageix/config/designs.csv")
```

`narratives_base.csv` declares `default` and `golden`. `narratives_biodiversity.csv`,
read second, changes one lever and touches nothing else: its `biodiversity`
column names `base = default`, so it starts from that column and overrides
only `bii_target` and `yields_scenario`. A column that names neither an earlier
narrative nor a `base` starts from the registered defaults. A design column
that names no narrative is refused rather than dropped silently.

The CSV and R surfaces coexist. `c(EXPERIMENTS, list(name = experiment(...)))`
adds an R-declared experiment to the ones read from CSV, and `--set` still
reaches every setting of both.

---

## 3. The settings reference

### 3.1 How to read this section, and how to set anything in it

Every setting belongs to one of four owners. The owner decides where the setting
is written and who is expected to change it.

| Owner | Declared in | Changed by | Section |
| --- | --- | --- | --- |
| the world | `R/world_levers.R` | `narrative()`, a narrative CSV row, `--set` | 3.2 |
| the sampling plan | `design_spec()` in `R/utils_config.R` | `design()`, a design CSV row, `--set` | 3.3 |
| infrastructure | `infrastructure_spec()` in `R/pipeline_infrastructure.R` | an `MAGPIE_MM_*` environment variable, `--set` | 3.4 |
| derived | worked out by the pipeline | nothing; setting one is an error | 3.5 |

Four ways to give a setting a value, in increasing precedence:

```r
# 1. the registered default, in the file that declares the setting
# 2. an environment variable, for one machine (infrastructure settings only)
MAGPIE_MM_QOS=standby Rscript messageix/run.R

# 3. the experiment, in R or in a CSV row
narrative(bii_target = 0.78)

# 4. --set, for one command; repeatable, and it reaches every settable key
Rscript messageix/run.R default --set bii_target=0.74 --set qos=standby
```

A vector on a command line or in an environment variable is comma-joined
(`--set prices_ghg=0,100,1000`). In a CSV cell the separator is `|`, and spaces
work too for numbers.

**CSV row names are the setting names.** A lever is a row of a narrative CSV
under its own name, and the two sampling-plan settings are rows of a design CSV
under theirs. Each entry below repeats its row name so this section is the one
place to look one up. Infrastructure settings have no CSV row: they are
operational rather than scientific, so they arrive from the environment or from
`--set` (section 3.4).

Each entry below carries the same fields. **What it does** is the plain-language
meaning. **Switch** is the MAgPIE `cfg$gms` name it becomes, where it becomes
one. **Applies in** names the phases it is set at, out of `calibrate`, `price`
and `demand`. **Values** is what it may be. **Default** is what it is if nothing
says otherwise, with the reason for that value, which is one of four kinds:
MAgPIE's own default, a decision of the 2026-08-25 Earth Commission session, a
value inherited from the earlier MAgPIE emulator work, or a property of the
linkage to MESSAGEix.

### 3.2 The world: levers of `narrative()`

Eleven levers are registered. `lever_names()` prints the current set, and each
one's block in `R/world_levers.R` is its authoritative documentation.

#### `ssp`

**What it does.** Selects the shared socioeconomic pathway the runs follow:
population, income, and demand growth. It is the first token of every matrix
name.
**Switch.** None directly. It is a `by_scenario_config()` lever, so the pipeline
calls MAgPIE's own `gms::setScenario(cfg, ssp)` against MAgPIE's
`config/scenario_config.csv` before it sets anything of its own. An SSP
therefore arrives as MAgPIE's own bundle of several dozen switches, and this
pipeline sets a handful on top of that bundle. This answers the question raised
in the 2026-08-25 session about where the full SSP2 specification comes from
once the fixed config CSV is out of the way: it comes from MAgPIE, not from
here.
**Applies in.** calibrate, price, demand.
**Values.** `SSP1` to `SSP5`, each a column of MAgPIE's own scenario config.
**CSV row.** `ssp`, in a narrative CSV.
**Default.** `SSP2`. It is the pathway the golden runs were made in. Changing it
also needs a matching cellular input tarball, because the cellular tarball
carries the climate forcing of one pathway.

#### `region_set`

**What it does.** Selects the set of world regions MAgPIE solves for. It picks
the four input tarballs and the region-name table together, so the runs and the
matrix cannot end up at different resolutions.
**Switch.** None. It is the one `structural` lever, resolved through
`region_sets()` in `R/pipeline_infrastructure.R`.
**Applies in.** Everywhere, since it decides which data every phase reads.
**Values.** A region set the pipeline knows. `R12` is the only one so far.
**CSV row.** `region_set`, in a narrative CSV.
**Default.** `R12`, which is MESSAGE's twelve world regions. Adding another is
one entry in `region_sets()` plus its region-name table in `data/` (recipe in
section 6).

#### `bii_target`

**What it does.** Sets how much of the biodiversity intactness index the model
has to maintain. A higher target protects more habitat, which constrains where
cropland and bioenergy can expand.
**Switch.** `s44_bii_target`, paired with `c44_bii_decrease`. The pairing is the
point of the phase logic: BII loss is permitted exactly when no target is
imposed, so setting one without the other would misstate the world.
**Applies in.** calibrate, price, demand. The calibrate phase was added under
the 2026-08-25 decision that step-1 parameters are narrative settings; before
that the target could not be set for the calibration run.
**Values.** A fraction of 1, in `[0, 1)`. Values used so far are 0, 0.7, 0.74
and 0.78.
**CSV row.** `bii_target`, in a narrative CSV.
**Default.** `0`, meaning no target. This is the reference world the golden runs
were made in, and it is why `c44_bii_decrease` is left permitting loss.

#### `mp_substitution`

**What it does.** Sets how much ruminant meat and dairy demand is met by
microbial protein instead. Higher substitution frees pasture and cropland.
**Switch.** `s15_rumdairy_scp_substitution`, divided by 100 on the way in
because MAgPIE takes a share rather than a percent.
**Applies in.** price, demand.
**Values.** A percent from 0 to 100. Values used so far are 0, 25, 50 and 75.
**CSV row.** `mp_substitution`, in a narrative CSV.
**Default.** `0`, the reference world of the golden runs.

#### `protect_scenario`

**What it does.** Sets which land protection scenario applies in the two sweeps.
It decides which land is off limits to conversion.
**Switch.** `c22_protect_scenario`.
**Applies in.** price, demand.
**Values.** A MAgPIE protection scenario, for example `none`, `BH`
(biodiversity hotspots), `WDPA` (protected areas).
**CSV row.** `protect_scenario`, in a narrative CSV.
**Default.** `none`, which is MAgPIE's own default and what the golden runs
used in these two phases.

#### `protect_scenario_step1`

**What it does.** Sets the protection scenario the reference land-use intensity
trajectory is calibrated under. It is separate from `protect_scenario` because
the calibration run and the sweeps can legitimately differ here.
**Switch.** `c22_protect_scenario`, in the calibrate phase only.
**Applies in.** calibrate.
**Values.** As `protect_scenario`.
**CSV row.** `protect_scenario_step1`, in a narrative CSV.
**Default.** `none`, which is MAgPIE's own default, following the 2026-08-25
decision that step-1 parameters default to MAgPIE's values rather than to values
inherited from the earlier scripts.
**Golden value.** `BH`. The golden runs calibrated under biodiversity-hotspot
protection and then applied the result exogenously without protection in the
sweeps. The `golden` experiment pins it. Whether that asymmetry was deliberate
is still open (section 8).

#### `yields_scenario`

**What it does.** Decides whether crop yields carry climate change impacts.
**Switch.** `c14_yields_scenario`.
**Applies in.** calibrate, price, demand.
**Values.** `nocc` excludes impacts; `cc` includes them.
**CSV row.** `yields_scenario`, in a narrative CSV.
**Default.** `nocc`. It is defensible at 1 to 1.5 degrees of warming, where
yield impacts are small. Scenarios approaching 2 degrees should use `cc`, where
they are material. This default was reviewed in the 2026-08-25 session and left
as it is, pending confirmation with the team.

#### `tc_cost`

**What it does.** Sets how costly yield-increasing technological change is.
Expensive intensification makes the model lean more on expanding cropland
instead.
**Switch.** `c13_tccost`.
**Applies in.** calibrate, price, demand.
**Values.** `high`, `medium`, `low`.
**CSV row.** `tc_cost`, in a narrative CSV.
**Default.** `medium`, which is MAgPIE's own default. It was `high`, inherited
from the earlier emulator scripts, and moved to `medium` under the 2026-08-25
decision that the Earth Commission run stays as close to MAgPIE's own
configuration as possible.
**Golden value.** `high`, pinned by the `golden` experiment. Anyone wanting the
inherited behaviour in a new experiment sets `tc_cost = "high"` explicitly.

#### `cropland_max_growth`

**What it does.** Caps how fast cropland may expand in a region. It is a
deliberate brake on how fast the sweep may reallocate land.
**Switch.** `s30_annual_max_growth`.
**Applies in.** price, demand.
**Values.** A positive fraction per year. `0.02` caps expansion at 2 percent per
year. `Inf` lifts the brake entirely.
**CSV row.** `cropland_max_growth`, in a narrative CSV.
**Default.** `0.02`, inherited from the earlier MAgPIE emulator work. MAgPIE's
own default is `Inf`.

#### `bii_missing_cost`

**What it does.** Sets the cost charged where the biodiversity intactness index
has no data, so that data gaps are not the cheapest place for the model to put
land-use pressure.
**Switch.** `s44_cost_bii_missing`.
**Applies in.** price, demand.
**Values.** Non-negative, in USD17MER.
**CSV row.** `bii_missing_cost`, in a narrative CSV.
**Default.** `10000000`, which is ten times MAgPIE's own default. Inherited from
the earlier emulator work, and kept for the reason above.

#### `nonco2_price_cap_usd17_tc`

**What it does.** Caps the price the model applies to CH4 and N2O. Without a
cap, a high GHG price drives implausible non-CO2 abatement and implausible food
prices.
**Switch.** `s56_limit_ch4_n2o_price`.
**Applies in.** demand only. The calibration run is made under a near-term
policy price path, where capping would move the trajectory the whole pipeline
rests on, and the price sweep runs at zero GHG price, where a cap is inert.
**Values.** Positive, in USD17MER per tonne of carbon. Note the unit: per tonne
of carbon, not per tonne of CO2. Multiply a USD-per-tCO2 figure by 3.67 to get
this one.
**CSV row.** `nonco2_price_cap_usd17_tc`, in a narrative CSV.
**Default.** `734`, which is the Earth Commission target of 200 USD2017 per
tCO2 (200 times 3.67). Decided in the 2026-08-25 session.
**Golden value.** `200`, pinned by the `golden` experiment. 200 USD17 per tC is
about 55 USD per tCO2, far below the intended cap. MAgPIE's own default is
`4920`, effectively uncapped for this purpose.

#### The escape hatch: `gms$<switch>`

`narrative(gms = list(food = "anthro_iso_jun22"))` in R, or a `gms$food` row in
a narrative CSV, assigns any MAgPIE switch the pipeline does not expose. It is
applied at every phase. A switch the pipeline decides for itself is refused, and
the refusal names the lever to set instead. Those refused switches are the ones
the phase logic and the infrastructure settings own: `c_timesteps`,
`c13_tccost`, `c14_yields_scenario`, `s30_annual_max_growth`,
`s44_cost_bii_missing`, `s60_2ndgen_bioenergy_dem_min`,
`s60_bioenergy_1st_subsidy`, `tc`, `c44_bii_decrease`, `s44_bii_target`,
`c22_protect_scenario`, `s15_rumdairy_scp_substitution`, `c60_2ndgen_biodem`,
`c56_pollutant_prices`, `c56_pollutant_prices_noselect`,
`s56_limit_ch4_n2o_price`, `s60_bioenergy_1st_price` and
`s60_bioenergy_2nd_price`. `pipeline_owned_switches()` prints the current list.

### 3.3 The sampling plan: settings of `design()`

Two settings, declared in `design_spec()` in `R/utils_config.R`. They multiply:
seven bioenergy levels times twelve GHG levels is the 84 demand runs of the
tested grid.

#### `prices_bioenergy`

**What it does.** Names the bioenergy price levels the price sweep visits. One
price run per level, and each level becomes one bioenergy demand column that the
demand sweep later selects from.
**Switch.** Not a switch of its own. Each level is multiplied by the
`currency_2005_to_2017` deflator and enters the price sweep as both
`s60_bioenergy_1st_price` and `s60_bioenergy_2nd_price`, which the phase logic
sets together.
**Applies in.** price, and through the packed demand columns, demand.
**Values.** Whole numbers, in USD2005 per GJ. Each becomes a run name and a
scenario column name (`BE05`), so a price of 7.5 has no token and is refused.
**CSV row.** `prices_bioenergy`, in a design CSV.
**Default.** `0, 5, 7, 10, 15, 25, 45`. The levels are placed where land-use
models change behaviour, with enough coverage around the turning points that
interpolating between them lands on a sensible surface. Inherited from the
earlier emulator work and reconfirmed at the version bump.

#### `prices_ghg`

**What it does.** Names the GHG price levels the demand sweep visits. One demand
run per bioenergy and GHG price pair.
**Switch.** Not a switch. Each level names one column of the supplied
`f56_pollutant_prices.cs3` file, selected through `c56_pollutant_prices` and
`c56_pollutant_prices_noselect`.
**Applies in.** demand.
**Values.** Whole numbers. Each is a label rather than a price: it names a
column, and that column carries the trajectory the label stands for. The names
appear in run folders (`G0400`) and in scenario names (`G0400exp2110`).
**CSV row.** `prices_ghg`, in a design CSV.
**Default.** `0, 10, 20, 50, 100, 200, 400, 600, 1000, 2000, 3000, 4000`, the
twelve-column grid the golden runs used. A level with no matching column in the
supplied file is caught by the pre-flight before any run is submitted.

### 3.4 Infrastructure

Code defaults in `R/pipeline_infrastructure.R`. Each has an environment variable
for a machine and a `--set` for one command. The environment variable beats the
code default, and `--set` beats both. None of these is a CSV row: a narrative
CSV carries levers, a design CSV carries the two price grids, and a row naming
an infrastructure key stops the read.

#### MAgPIE switches that are properties of the linkage

These are infrastructure rather than world settings because they follow from
MESSAGEix and from the emulator's shape, not from the scenario being told.

**`timesteps`** (`MAGPIE_MM_TIMESTEPS`, switch `c_timesteps`, every phase).
Which years the model solves for. Default `coup2110` rather than MAgPIE's
`coup2100`, because MESSAGEix runs to 2110 and the emulator has to cover its
horizon. The packing steps check their output against the model years of this
token.

**`bioenergy_dem_min`** (`MAGPIE_MM_BIOENERGY_DEM_MIN`, switch
`s60_2ndgen_bioenergy_dem_min`, price and demand). A floor under
second-generation bioenergy demand, in mio. GJ per year. Default `0`, so the low
end of the demand sweep is not truncated. MAgPIE's own default of 1 would put a
floor under it and flatten the bottom of the response surface.

**`bioenergy_1st_subsidy`** (`MAGPIE_MM_BIOENERGY_1ST_SUBSIDY`, switch
`s60_bioenergy_1st_subsidy`, price and demand). A subsidy on first-generation
bioenergy, in USD17MER per GJ. Default `0`, and it has to stay zero: MAgPIE's
own default of 6.5 acts as a price floor underneath the bioenergy price sweep.

**`biodem_scenario_step1`** (`MAGPIE_MM_BIODEM_SCENARIO_STEP1`, switch
`c60_2ndgen_biodem`, calibrate). The business-as-usual second-generation
bioenergy demand path the reference trajectory is calibrated against. Default
`R34M410-SSP2-NPi2025`, inherited from the earlier emulator work.

**`ghg_price_scenario_step2`** (`MAGPIE_MM_GHG_PRICE_SCENARIO_STEP2`, switch
`c56_pollutant_prices`, price). The GHG price scenario the price sweep runs
under. Default `SSPDB-SSP2-Ref-MESSAGE-GLOBIOM`, which is zero in every region
and every period, so the bioenergy price is the only signal that sweep varies.

**`ghg_price_scenario_suffix`** (`MAGPIE_MM_GHG_PRICE_SCENARIO_SUFFIX`, demand).
The suffix on the demand sweep's GHG price scenario names, recording how the
trajectory is extended past the last reported year. Default `exp2110`, meaning
extended exponentially to 2110. It is part of a name supplied from outside this
repository, so it changes only when the supplier's naming changes.

#### A science-adjacent constant

**`currency_2005_to_2017`** (`MAGPIE_MM_CURRENCY_2005_TO_2017`). The USD2005 to
USD2017 MER deflator. It multiplies the bioenergy price sweep on the way into
MAgPIE, and its reciprocal (0.81300813) converts prices back out again in
`data/MM_linkage_mapping.csv`. Default `1.23`, a MAgPIE-team factor. This is a
standing attention item: MAgPIE's base year moves when MAgPIE updates, so
revisit it at every version bump, and move both numbers together. The reduce
phase checks that the mapping's factor is the reciprocal of this setting.

#### Inputs beyond the region set

**`input_calibration`** (`MAGPIE_MM_INPUT_CALIBRATION`). The calibration tarball
entry of `cfg$input`. Default empty, meaning no calibration entry at all, which
is what the golden runs used. MAgPIE v4.11.0 would default to
`calibration_H12_FAO_13Mar25.tgz`, which is an H12 artefact rather than an R12
one.

#### Calibration reuse

**`project`** (`MAGPIE_MM_PROJECT`). Names the project an experiment belongs to.
When it is set, the calibrate phase writes to `output/_calibration/<project>/tau`
instead of the experiment's own folder, so every experiment carrying that
project value and the same tau-determining settings reuses one calibration run.
Default empty, which keeps the per-experiment folder. This setting implements
the 2026-08-25 decision that step 1 runs once per project rather than once per
experiment, because tau is fixed across every run of a project. The stage-1
fingerprint still guards the reuse, so two experiments that share a project but
differ in a tau-determining setting get an error rather than a wrong trajectory.

#### Run control, waiting, and the cluster

| Key | Environment variable | What it does | Default and why |
| --- | --- | --- | --- |
| `output_modules` | `MAGPIE_MM_OUTPUT_MODULES` | `cfg$output`, the post-processing scripts each run executes when it finishes | `output_check,rds_report`. The reduce phase reads `report.mif`, which these produce |
| `force_replace` | `MAGPIE_MM_FORCE_REPLACE` | `cfg$force_replace`; whether a re-run may overwrite a run folder of the same name | `TRUE`. Names are derived from the settings, so re-running one is routine rather than exceptional |
| `poll_seconds` | `MAGPIE_MM_POLL_SECONDS` | Seconds between checks while the pipeline waits for a phase's runs | `300`. Each check reads the model status out of every finished run, so it is not free; runs take hours and five minutes resolves them finely enough |
| `timeout_hours` | `MAGPIE_MM_TIMEOUT_HOURS` | Hours to wait for one phase before giving up | `48`. Covers the 84-run demand sweep queued behind other work. A phase still unfinished after that needs a person rather than more waiting |
| `qos` | `MAGPIE_MM_QOS` | SLURM quality of service, which picks the submission script a run is handed to (`scripts/run_submit/submit_<qos>.sh`) | `priority`, a PIK-cluster queue name (the cluster offers standard, priority and standby). A site without it must override |
| `slurm_modules` | `MAGPIE_MM_MODULES` | Environment modules loaded before Rscript, in load order | `defaults/piam/1.27,R/4.3.2,gcc/15.2.0`. `gcc` must come last: the compiled piam packages need a C++ runtime symbol that only this module's libstdc++ provides, and a module loaded after it puts an older one in front |
| `mail_user` | `MAGPIE_MM_MAIL_USER` | Address SLURM mails job notifications to | empty, so job scripts carry no mail instructions at all. No personal address is committed |
| `patch_repo` | `MAGPIE_MM_PATCH_REPO` | Directory the packing steps write their tarballs into, and the first place MAgPIE looks for input tarballs | `./patch_input`, created on first use and never committed |
| `magpie_public_repo` | `MAGPIE_MM_PUBLIC_REPO` | Repository serving the base input tarballs | `https://rse.pik-potsdam.de/data/magpie/public`, PIK's public repository |
| `matrix_sdg_scen` | `MAGPIE_MM_MATRIX_SDG_SCEN` | Value written into the `SDGscen` column of every matrix row | `noSDG_rcpref`, the tag the golden matrix carries |

### 3.5 Derived values: settable by nothing

Worked out from the settings above. An experiment that could choose its own
names could choose another experiment's, and since a re-run may overwrite a
folder of the same name, the second run would replace the first silently.
Setting one of these is an error.

| Value | Rule | `default` | `biodiversity` |
| --- | --- | --- | --- |
| `regionscode` | the middle token of the regional tarball name, `rev<revision>_<code>_magpie.tgz` | `5ff27be8` | `5ff27be8` |
| `identifier` | `MESSAGEix_<regionscode>` for the experiment named `golden`, `MESSAGEix_<regionscode>_<name>` for any other. It is the folder every run goes into | `MESSAGEix_5ff27be8_default` | `MESSAGEix_5ff27be8_biodiversity` |
| `matrix_basename` | `magpie_input_<ssp>_ref` for `golden`, `magpie_input_<ssp>_<name>` for any other. The woodfuel step appends `_woodfuel` | `magpie_input_SSP2_default` | `magpie_input_SSP2_biodiversity` |
| `region_names` and the four input tarballs | whatever `region_set` pairs them with | the R12 set | the R12 set |

The experiment literally named `golden` is the one that carries no name token,
so it derives `MESSAGEix_5ff27be8` and `magpie_input_SSP2_ref`. That is what
keeps the pinned runs and the reference matrix where they have always been, and
it makes reproduction a regeneration of that file rather than a comparison
against a copy under another name. Every other experiment, `default` included,
carries its own name.

`5ff27be8` is MAgPIE's own code for the MESSAGE R12 region mapping
(`AFR CHA CPA EEU FSU LAM MEA NAM PAO PAS SAS WEU`), read out of the tarball
name rather than computed here. Upstream's default H12 mapping hashes to
`62eff8f7`. The code is not a git hash: it moves when the region mapping moves
and at no other time, so a new MAgPIE version does not move anybody's runs.

### 3.6 Settled in code, and not settings at all

These values are used where they are computed. Changing one means editing the
code that uses it, which is deliberate.

| Value | Where | Why it is not exposed |
| --- | --- | --- |
| Woodfuel energy content, 18 GJ per tonne dry matter | `R/add_woodfuel_to_matrix.R` | One physical constant, a MAgPIE-team value, used once and deliberately in place of the energy content in the solver output |
| Gap filling: adjacent-year mean, everything past 2100 held at the 2100 value | `R/pack_demand.R` | Past 2100 there is no later reported year to average against |
| Historical second-generation bioenergy zeroed for 1995 to 2015 | `R/pack_demand.R` | No such production existed, and MAgPIE harmonises its early years against a reference path regardless |
| GWP100 factors, CH4 27 and N2O 273 (AR6) | `data/MM_linkage_mapping.csv` | They belong with the variable mapping that applies them |
| The three phase asymmetries: the calibrate-phase protection scenario, the `c44_bii_decrease` pairing, and the demand-only non-CO2 cap | `stage_cfg()` in `R/utils_config.R` | They are what makes a phase that phase. An experiment changing one by accident would stop reproducing the reference runs |

---

## 4. What you need before you can run

The repository carries no input data. Two things come from outside it, and
neither is in the tree. `Rscript messageix/run.R status` reports on both without
running anything.

### The four input tarballs

MAgPIE reads all input data from version- and region-specific tarballs named in
`cfg$input`. The pipeline pins MAgPIE v4.11.0 and the MESSAGE R12 region set,
regionscode `5ff27be8`, input revision rev4.119:

| `cfg$input` entry | File |
| --- | --- |
| `regional` | `rev4.119_5ff27be8_magpie.tgz` |
| `cellular` | `rev4.119_5ff27be8_1b5c3817_cellularmagpie_c200_MRI-ESM2-0-ssp245_lpjml-8e6c5eb1.tgz` |
| `validation` | `rev4.119_5ff27be8_validation.tgz` |
| `additional` | `additional_data_rev4.62.tgz` |
| `patch` | generated between phases, see section 5 |

The cellular name encodes more than the region set: `1b5c3817` is the cellular
data hash, `c200` the cluster count, `MRI-ESM2-0-ssp245` the climate forcing,
and `lpjml-8e6c5eb1` the LPJmL run. Changing the SSP therefore needs a different
cellular tarball rather than only a different `ssp` setting.

The four names are one entry in `R/pipeline_infrastructure.R`, listed together
as the `R12` region set with the region-name table that has to agree with them
(`data/region_names_R12.csv`). An experiment names the set and never the files,
so everything that has to travel together does.

The tarballs are held within IIASA and on the PIK cluster, and they are not
currently redistributable (`decisions.md`, Q6). Ask the pipeline's author for
the paths and for access. Two entries need confirmation before the first
production run, and both are in section 8.

### How MAgPIE finds them

MAgPIE searches `cfg$repositories` in order and takes the first hit for each
file name. The pipeline sets:

```r
cfg$repositories <- append(
  list("https://rse.pik-potsdam.de/data/magpie/public" = NULL,   # PIK public repository
       "./patch_input"                                 = NULL),  # generated patches, local
  getOption("magpie_repos"))                                     # site defaults, incl. PIK cluster paths
```

Both repository entries are infrastructure settings, asked for in
`R/utils_env.R`, so a site holding the tarballs elsewhere adds an entry rather
than editing code. To place a tarball by hand, put it in a directory and add
that directory to `cfg$repositories`. Do not unpack it: MAgPIE extracts each
archive flat and routes every file to the module `input/` folder whose own
`input/files` manifest claims it, with unclaimed files going to `input/`.

### The GHG price file

`f56_pollutant_prices.cs3` carries one column per GHG price level the demand
sweep visits. Nothing in this repository builds it, and the semantics of the
column labels cannot be recovered from the code, so it has to be supplied
through `--f56=PATH`. What it has to contain is written out in full by
`Rscript messageix/R/pack_demand.R` run with no `--f56`. The pre-flight checks
that the supplied file carries every column, pollutant and model year every
selected experiment asks of it, before anything is submitted.

### Where the packed tarballs go

The packing steps write into `patch_input/` at the repository root, a directory
that does not exist in a fresh clone and that the packing creates. Two tarballs
are packed and nothing is assembled by hand:

| Read by | Contents | Packed by |
| --- | --- | --- |
| the price sweep | `f13_tau_scenario.csv`, the trajectory the calibration run solved for | `R/pack_price.R` |
| the demand sweep | `f60_bioenergy_dem.cs3` with one bioenergy demand column per price level, and `f56_pollutant_prices.cs3` as supplied | `R/pack_demand.R` |

Packed tarballs are build artefacts and are never committed. Their names carry a
digest of their contents, for reasons in section 5.

---

## 5. One command, and what happens underneath

### The command

```bash
Rscript messageix/run.R status                                    # what is finished, what would run
Rscript messageix/run.R --f56=/path/to/f56_pollutant_prices.cs3   # every experiment, in order
Rscript messageix/run.R biodiversity --f56=...                    # just this one
Rscript messageix/run.R matrix default                            # the reduce phase alone
Rscript messageix/run.R --help                                    # every flag
```

`run.R` runs the four phases in order, waits for the cluster between them, skips
whatever is already finished, and packs what one phase produced into the inputs
the next reads. `--submit` hands the whole multi-day sequence to the cluster as
one job and returns.

### The pipeline

```
experiments.R  or  config/*.csv
      |
      |  resolve_config()   defaults -> narrative -> design -> --set, then derive
      v
    pcfg    validated once, read-only afterwards
      |
      |  stage_cfg(pcfg, stage, be, ghg)   one complete MAgPIE cfg per run
      v
calibrate       1 run,  tau solved for
      |  PACK  tau -> patch tarball the price sweep reads
price           7 runs, tau held fixed, GHG price 0
      |  PACK  bioenergy demand + GHG price trajectories -> the demand sweep's inputs
demand          84 runs (7 BE x 12 GHG)
      |
reduce          84 report.mif -> matrix CSV;  84 fulldata.gdx -> woodfuel
      v
    the land emulator matrix MESSAGEix reads
```

What each phase computes is in [`pipeline.md`](pipeline.md), sections 1 to 5.

### Config assembly

Settings flow one way. `experiments.R` or a CSV produces a narrative and a
design. `resolve_config()` merges them over the registered defaults, applies any
`--set` overrides, derives the read-only names, and validates the result once.
The output is `pcfg`, a list of class `mm_pcfg`, and it is read-only from that
point. The single legal mutation is `with_patch()`, which records the name of a
patch tarball a generator has just produced.

`stage_cfg(pcfg, stage, be, ghg)` turns `pcfg` into one complete MAgPIE `cfg`
for one run. It is where the phase logic lives, and it is the only place that
decides which switch a `by_phase_logic()` lever moves at which phase.

### The naming contract

Every folder name, run title, GAMS scenario-column name and patch-tarball name
is built in [`../R/utils_paths.R`](../R/utils_paths.R) and nowhere else. One
experiment writes into one folder, so the names below the identifier carry only
the position in the sweep.

| Token | Form | Example |
| --- | --- | --- |
| BE token | `BE` plus zero-pad to 2 | `BE00 BE05 BE07 BE10 BE15 BE25 BE45` |
| GHG token | `G` plus zero-pad to 4 | `G0000` to `G4000` |
| Identifier | regionscode, plus the experiment's name unless it is `default` | `MESSAGEix_5ff27be8` |
| Results folder | `output/<identifier>/<title>` | `output/MESSAGEix_5ff27be8/BE45_G4000` |
| Calibrate title | `tau`, or `output/_calibration/<project>/tau` when `project` is set | `tau` |
| Price title | the BE token | `BE05` |
| Demand title | BE token, underscore, GHG token | `BE45_G4000` |
| Bioenergy demand column | `<experiment>_<BE token>` | `default_BE05` |
| GHG price column | GHG token plus the extension suffix | `G0400exp2110` |
| Matrix tags | `BIO` plus pad2, `GHG` plus pad3 | `BIO45`, `GHG4000` |
| Packed tarball | `<experiment>_<price\|demand>_<8 hex>.tgz` | |
| Calibration record | `<calibrate folder>/messageix_stage1_fingerprint.txt` | |

Price levels are written one way only, zero-padded. The bioenergy demand column
name is a handshake between two steps of this pipeline: packing writes those
columns into `f60_bioenergy_dem.cs3`, and the demand sweep asks for one of them
through `c60_2ndgen_biodem`. They have to match character for character or GAMS
stops on an unknown set element, so both are built by the same function from the
same integer. The GHG price column is different in kind, because those
trajectories arrive from outside under the names their author gave them.

### Calibration reuse

An experiment's calibration run is found by name, and `force_replace` is `TRUE`,
so a folder can hold a trajectory solved under settings the experiment has since
changed. Two mechanisms handle that.

The **stage-1 fingerprint** makes staleness checkable. The calibrate phase
writes `messageix_stage1_fingerprint.txt` into its run folder, holding sorted
`key=value` lines for every setting the calibration depends on: the stage-1
switches, the SSP, the stage-1 protection scenario, the stage-1 bioenergy demand
path, and the four input tarballs. Packing refuses to take tau out of a run
whose record disagrees with the experiment it was invoked for, and the error
names which settings differ.

The **`project` setting** (section 3.4) moves the calibrate phase into
`output/_calibration/<project>/tau`, so experiments in one project share one
calibration run. The fingerprint still guards it.

### Patch tarballs

A patch tarball is MAgPIE's project-override mechanism rather than a software
patch. MAgPIE reads its inputs either from the version-pinned base tarballs or
from a patch tarball, and there is no third channel, so tau and the GHG price
trajectories travel between phases inside one.

The names are content-hashed: `<experiment>_<stage>_<8 hex>.tgz`, where the
digest is over the contents of the files that go inside. This matters because
MAgPIE decides whether to unpack input data again by comparing tarball names
against the names recorded in `input/info.txt`, and never looks inside the
files. A tarball rewritten under its old name would be ignored, and the run
would proceed quietly on the previous run's data. Letting the name change with
the contents makes reuse on a re-run correct by construction. Identical content
regenerates the same name, so MAgPIE correctly skips the re-extraction.

### Waiting, skipping, and the pre-flight

MAgPIE submits its runs and returns, so a phase that has finished has only
finished submitting. Between phases the pipeline polls until every run folder
the experiment expects holds a `fulldata.gdx` whose GAMS model status is solved,
narrating solved out of total. It stops early when the queue reports no MAgPIE
jobs left while runs are still missing, which means they died. After the demand
sweep it also waits for each run's `report.mif`, because one job solves and then
reports, minutes apart, and the reduce phase reads the report.

A phase that is already finished is skipped, so a restart after a failure picks
up where the failure was. `--force` runs a phase anyway.

Before anything is submitted, `preflight()` checks the whole request while it is
still cheap. Every selected experiment resolves. Each phase's input either
exists or is produced earlier in the same command. The supplied GHG price file
carries every column, pollutant and model year every selected experiment asks of
it. Nothing is about to pack a second tarball beside one already on disk. The
input tarballs are reachable. Two experiments cannot be writing to one folder. A
missing GHG price column found after two phases have run is hours of cluster
time spent for nothing.

### Where it runs

Emulator generation runs on the PIK cluster. This is a storage constraint rather
than a preference: one MAgPIE run produces over 1 GB, a full generation needs
roughly 90 GB, and the UniCC quota is about 100 GB. Access is by requesting a
PIK cluster account and a project allocation on it.

Nothing about the environment is hard-coded. The module list, the QoS, the
repositories and the mail address are infrastructure settings (section 3.4),
asked for in `R/utils_env.R`. The submitted job script holds no copy of them: it
is generated from the resolved experiment, so the queue, the module lines and
the mail address come from the same place as everything else. Submission itself
is MAgPIE's own: `start_run()` detects SLURM and runs
`sbatch submit_<qos>.sh` from the run folder.

The tested environment is `defaults/piam/1.27`, `R/4.3.2`, then `gcc/15.2.0`
last. Beyond what MAgPIE needs (`gms`, `lucode2`, `magclass`, `gdx2`, `magpie4`)
and `iamc` for the variable mapping, this pipeline uses `readr`, `dplyr`,
`tidyr`, `tibble`, `purrr` and `stringr`, all namespace-qualified and never
attached, so sourcing this code into a session masks nothing.

---

## 6. Modularity: where the seams are

Each seam below can be worked on without reading the others. The point of the
layout is that a change of one kind is a change in one place.

| Seam | File | What changing it means |
| --- | --- | --- |
| the levers of the world | `R/world_levers.R` | one self-contained block per lever; nothing else lists them |
| the sampling plan | `design_spec()` in `R/utils_config.R` | the two price grids and their defaults |
| region sets | `region_sets()` in `R/pipeline_infrastructure.R` | one entry pairing four tarballs with a region-name table in `data/` |
| infrastructure | `infrastructure_spec()` in `R/pipeline_infrastructure.R` | queue, modules, waiting, patch directory, linkage constants |
| naming | `R/utils_paths.R` | every folder, run title, scenario column and tarball name |
| config assembly | `R/utils_config.R` | how a resolved experiment becomes one MAgPIE `cfg` per run |
| the CSV importer | `R/utils_config_csv.R` | how a table becomes constructor calls; it adds no settings of its own |
| phase sequencing | `R/pipeline.R`, `run.R` | which phases exist, what is checked, what is skipped |
| one phase of runs | `R/run_phase.R` | how a phase submits its runs |
| packing | `R/pack_price.R`, `R/pack_demand.R` | what travels from one phase to the next |
| the reduce phase | `R/createMatrix_MM.R`, `R/add_woodfuel_to_matrix.R` | how 84 runs become the matrix |
| the variable mapping | `data/MM_linkage_mapping.csv` | which MAgPIE variables become which matrix rows, and the GWP factors |

Every one of those scripts also runs on its own, which is the debugging surface.
`Rscript messageix/R/pack_price.R --experiment=NAME` rebuilds one packing step
without the driver. Every entry point takes `--help`, and each option works as
both `--key=value` and `--key value`.

### What a MAgPIE-side collaborator can change alone

- **A new world setting.** Add one block to `R/world_levers.R`. It becomes
  available to `narrative()`, to a narrative CSV row, and to `--set` at once,
  with its documentation, its default and its check in the same block. The
  worked examples in that file cover each mechanism class.
- **A different sampling grid.** A `design()` call, a design CSV row, or
  `--set prices_ghg=0,100,1000`. No code changes.
- **A whole project configuration from a collaborator.** Drop the CSV into
  `messageix/config/`, layer it over the base file, and run it.
- **A MAgPIE switch the pipeline does not expose.** `narrative(gms = list(...))`
  in R, or a `gms$<switch>` row in a narrative CSV.
- **A per-machine environment.** `MAGPIE_MM_QOS`, `MAGPIE_MM_MODULES`,
  `MAGPIE_MM_PATCH_REPO` and the rest, set once in a shell profile. No file in
  the repository records one machine's setup.

### A new region set

Which regions MAgPIE solves for is the one structural lever, and moving to
another set is one lookup entry plus one table:

1. Obtain the input tarballs for that region set and put them where
   `cfg$repositories` finds them (section 4).
2. Write `messageix/data/region_names_R10.csv`: one row per MAgPIE region code,
   plus the `GLO` and `World` rows that keep the global total named
   consistently.
3. Add an `R10` entry to `region_sets()` in `R/pipeline_infrastructure.R`,
   pairing the four tarball names with that table.
4. Set `region_set = "R10"` in an experiment. The identifier follows, because it
   carries the region code out of the new regional tarball, so R10 runs cannot
   land in the R12 folders.
5. Calibrate again for that experiment and run the pipeline.

Both halves of the reduce phase read that one table, the matrix builder to
rename the mapped results and the woodfuel half to rename what it extracts, so
the two cannot disagree. Both require the table to name every region their runs
report, and both stop naming both sides when it does not. A total mismatch is
the harmless case. The dangerous one is partial: R10 and R12 share eleven of
their twelve codes, so runs at the wrong resolution would be renamed where the
codes agree and left in MAgPIE's codes where they do not, giving a matrix that
looks complete and carries two vocabularies.

What does not come free is cell-level aggregation to an arbitrary region set at
run time. That needs a tarball per region set today, and it is the door to
country-level work (section 8).

### The seams being added

Four pieces from the 2026-08-25 session are in progress at the time of writing.
They are described here from the spec's design
(`specs/2026-08-25-earth-commission-config-and-feedback-loop.md`), and their
final file names may differ.

- **`messageix/optional/feedback_prep/`**, in the MESSAGE branch. It takes
  MESSAGE output from a run that used the emulator under test, and computes
  the weighted-average carbon price and the second-generation bioenergy
  demand. Its science assumptions (the weighting variable, the deflator, the
  GWP basis, and which bioenergy variables are summed) are listed under
  "ASSUMPTIONS TO CONFIRM" in `feedback_prep/README.md` and await
  confirmation. The pollutant map is a required argument and stops the run
  when absent; the others apply defaults that do not fail loudly when wrong.
  Read that section before a production run. Optional; not part of the
  lightweight flow ([`lightweight-mode.md`](lightweight-mode.md)).
- **`messageix/optional/feedback_run/`**, for MAgPIE. It takes
  `feedback_prep`'s output, runs a standalone MAgPIE run, and produces
  results to compare against MESSAGE's land-use output. Optional, alongside
  `feedback_prep/`, for the same reason.
- **A vetting module** inside the MAgPIE folder within MESSAGEix. It runs simple
  checks before MESSAGE runs. The feedback pair validates after a run; this one
  gates before one.
- **A generated start script**, written into `magpie/scripts/start/projects/` as
  part of experiment setup, so a user can pick the project from MAgPIE's own
  option 8 menu and submit it rather than hand-writing a script. That folder is
  git-ignored by MAgPIE's own convention, so the generated script dirties the
  working tree and is never committed. A retained copy is kept elsewhere,
  because the script encodes all the run settings.

---

## 7. Why it is built this way

**Constructors with a registry, rather than a settings file read at run time.**
The 19 August build replaced the single preset CSV with `narrative()` and
`design()`. Three gains decided it. A value is validated at the line it is
written on rather than at resolution time. A sweep over one setting becomes an
`lapply` or a `for` loop instead of a hand-copied column. Six documented entry
scripts collapse to one command whose vocabulary is the four phases rather than
six internal steps. The registry carries the second half of that: each lever is
documented in its own block, so there is no second list to keep in step, and the
Earth Commission protocol's future levers (dietary patterns, food waste,
intensification, nitrogen-use efficiency, protection shares, afforestation
modes, bioenergy ceilings) are each one block.

**CSV as a thin importer rather than a rewrite.** `decisions.md` left the CSV
question open and named this exact shape as the resolution: a loader that reads
the table and calls the same constructors sits on top of `experiments.R` without
changing anything below it, and both surfaces can exist at once. The 2026-08-25
session then chose CSV as the primary surface, for layered overrides and for
direct reuse of a collaborator's config file. Building it as an importer means
the decision cost nothing below `experiments.R`: one file, no new settings, no
second validation path, and a lever added to the registry appears in both
surfaces at once.

**One documented place per setting.** The earlier preset CSV held MAgPIE
switches, tarball names, queue names, polling intervals and folder names in one
file behind a forty-line comment wall. Splitting the settings by owner is what
makes section 3 possible: a lever's documentation is its block, an
infrastructure setting's documentation is its `unit` field, and neither is
restated anywhere that could fall out of step.

**Derived names rather than declared ones.** The identifier used to be a row
that a new configuration had to remember to change, enforced by a warning that a
hurried reader scrolls past, and forgetting it meant one narrative silently
overwriting another's runs. Deriving it from the region code and the experiment
name makes the collision impossible by construction, and `run.R` asserts it
anyway before submitting.

**Content-hashed patch tarballs.** MAgPIE compares tarball names rather than
contents, so a stable name plus changed contents is a silent wrong-data bug. The
hash moves the correctness into the name.

**Step-1 parameters as narrative settings, defaulting to MAgPIE's own values.**
The calibration run inherited its parameters from the earlier emulator scripts.
The 2026-08-25 session made them narrative settings that default to MAgPIE's
defaults, as a standing principle for every future emulator generation rather
than a one-off for the Earth Commission run. `tc_cost` and
`protect_scenario_step1` moved accordingly, and `bii_target` gained the
calibrate phase.

**Tau cached per project.** Tau is fixed across every run of a project, so
recalibrating per experiment spends a full MAgPIE run to reproduce a number the
project already has. Keying stage 1 on a project identifier was the 2026-08-25
decision. The fingerprint stays, because a shared cache makes a stale trajectory
easier to hit rather than harder.

**`feedback_prep` rather than `magpie_calibrate`.** The name `magpie_calibrate`
was used through most of the 2026-08-25 session; the name changed near the end
of it, because "calibrate" overstated what the module does. Its scope is a
preparation step: compute the weighted-average carbon price and the
second-generation bioenergy demand, and hand off ready-made inputs for the
standalone MAgPIE run. Diagnosing a mismatch is human work that happens
afterwards. The structured meeting notes for that date still carry the earlier
name.

---

## 8. Open questions

### Raised in the 2026-08-25 session and still open

- **Where a new matrix enters the workflow.** Whether generating a new emulator
  matrix and swapping it into MESSAGE are one step or two sequential ones was
  left unresolved. The current answer from this side is that they are sequential
  and this pipeline stops at the matrix, but the MESSAGE-side half of that
  handoff is undocumented.
- **How a user selects among several emulators at MESSAGE runtime.** The goal is
  four or five emulators varying by bioenergy, biodiversity and other
  considerations, selectable when MESSAGE runs. The selection mechanism on the
  MESSAGE side is undecided.
- **Whether the feedback and vetting steps can be automated.** Introducing a new
  emulator into MESSAGE can raise feasibility problems, and resolving one is
  MESSAGE-side work. The optimistic path is that an emulator added through the
  MESSAGE-side registration function and passing the normal scenario workflow
  needs no further human intervention. This is unverified and was flagged in
  the session as a risk.
- **Whether MAgPIE's interactive package-update prompt conflicts with the
  pipeline's forced download.** Both touch the same input tarballs. The
  tentative answer was that it depends on the user and they probably coexist.
  This is unverified.
- **Built-in submission or custom PIK-cluster submission.** The leaning is to document
  MAgPIE's own job-submission and QoS flow well rather than build custom
  tooling. The PIK cluster has three QoS tiers and a project allocation there is a
  prerequisite either way. Undecided.
- **Which repository the feedback run belongs in.** Partly resolved: it runs
  outside the MAgPIE wrapper, in `messageix/optional/feedback_prep/` and
  `messageix/optional/feedback_run/` on the MESSAGE side. The exact
  repository boundary is not settled.
- **`yields_scenario`.** The session flagged the step-1 parameters for review
  and this one was left at `nocc` pending confirmation with the team rather than
  changed.

### Open in the pipeline itself

- **The `f56_pollutant_prices.cs3` generator does not exist.** Nothing in either
  repository builds the twelve `G####exp2110` columns, and the semantics of the
  labels cannot be recovered from the code. The file has to be supplied. The
  pipeline builds the seam and names exactly what is missing when it is absent.
- **The step-1 protection asymmetry.** The golden runs calibrated under `BH` and
  applied the result exogenously without protection in the sweeps. Whether that
  was deliberate or leftover is unconfirmed.
- **The abandoned preset CSV.** `config/projects/scenario_config_genie.csv` is
  loaded by none of the original start scripts, so fourteen of its rows were not
  in effect in the runs that produced the golden matrix, and several of its
  values are stale. The 2026-08-25 session put it explicitly out of scope for
  now. Whether it was abandoned deliberately is still open.
- **Intensive variables in the matrix mapping.** All 81 mapping rows ask for a
  global value beside the regional ones, which is right only where the global
  value comes from the run's own World row. Prices, `Biodiversity|BII` and
  `Landuse intensity indicator Tau` are per-unit quantities and must never be a
  sum across regions. The reduce phase tests this on every build, and no golden
  build has run yet, so the answer is unknown.
- **Input tarball questions.** Whether the updated R12 set ships
  `additional_data_rev4.63` and a matching R12 calibration tarball, the exact
  tarball paths on the cluster and the shared drive, whether the R12 set
  resolves through a `cfg$repositories` entry on the PIK cluster or has to be
  placed by hand, whether `MMEmuR12_rev4.96.tgz` is now redundant, and whether
  the bioenergy demand seed file substitution is equivalent. `decisions.md`,
  "Open items", carries the full list.
- **ISO-level raw inputs from the MAgPIE team.** Relevant when spatial
  composition or input-tarball spatial mapping updates enter the pipeline. Out
  of current scope. The ask is that ISO-level raw inputs keep being provided per
  MAgPIE version.
- **Cell-level aggregation at run time.** The intended path is to accept
  cell-level MAgPIE input and aggregate to a custom region set when a run
  starts, rather than depending on a pre-built tarball per region set. That is
  the door to R10, India and China work. Recorded as the design direction;
  nothing implements it yet.
