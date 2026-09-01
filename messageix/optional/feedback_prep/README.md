# feedback_prep -- the MESSAGE side of the emulator feedback check

Takes the output of a MESSAGE run made with the MAgPIE emulator under test and
produces the two inputs a MAgPIE feedback run needs:

  a. the weighted-average carbon price, as `f56_pollutant_prices.cs3`
  b. second-generation bioenergy demand, as a tidy CSV in PJ per yr

**Scope.** This is a feedback-preparation step. It produces the numbers a human
reads to judge whether the linkage worked; it does not interpret a mismatch and
does not decide what to fix.

**Before a production run, read [Assumptions to confirm](#assumptions-to-confirm).**
Five values -- three variable names and two numeric conventions -- have worked
defaults because nobody has written the decisions down yet, and none of them
fails loudly when wrong. A sixth, the pollutant map, has no default and stops the
run until you give it one.

## Why this folder exists

`messageix/R/pack_demand.R` refuses to run without an `f56_pollutant_prices.cs3`
and prints, in `f56_missing_message()`, that nothing in this repository can build
one. That file is a MESSAGE product. This folder is where it gets built, so the
demand sweep stops depending on a tarball passed around by hand.

The bioenergy half closes the other side of the same handshake. The price sweep
settles on a second-generation bioenergy production per region and year, and
`pack_demand.R` reads it back out with `extract_bioenergy_column()` to build the
`f60_bioenergy_dem.cs3` columns. What MESSAGE asked for and what MAgPIE supplied
are two different numbers, and a new emulator is trusted only once someone has
looked at both.

## Inputs

One IAMC-format CSV or xlsx of MESSAGE output (`Model, Scenario, Region,
Variable, Unit`, then one column per year), holding at least:

| Quantity          | Variable looked for                        | Unit accepted        |
| ----------------- | ------------------------------------------ | -------------------- |
| Carbon price      | `Price\|Carbon`                             | US$2005/2010/2017 per t CO2 |
| Weighting series  | `Emissions\|CO2`                            | any, used as a weight |
| Scenario          | the file's only one, or `--scenario`        | -- |
| Bioenergy demand  | `Primary Energy\|Biomass\|...`, see below   | EJ/yr or PJ/yr       |

Every one of those names is an assumption. They are listed with their overrides
under **Assumptions to confirm** below.

A file holding more than one model/scenario combination stops the run: averaging
a carbon price or summing a demand across scenarios is not a run MESSAGE ever
produced. Name one with `--scenario`. Duplicate region/variable/year rows within
one scenario stop it too.

Region labels are translated to MAgPIE codes through
`messageix/data/region_names_R12.csv`, the same table the emulator matrix and the
woodfuel step use, in whichever of three spellings the file carries.

## Outputs

Written into `--out-dir` (default `messageix/optional/feedback_prep/output/<experiment>/`):

| File                        | What it is                                                     |
| --------------------------- | -------------------------------------------------------------- |
| `f56_pollutant_prices.cs3`  | ready for `pack_demand.R --f56=`; structure-checked on write    |
| `bioenergy_demand.csv`      | region, year, value (PJ per yr), source variable(s)             |
| `f60_bioenergy_dem.cs3`     | the demand as a column a MAgPIE run can select                   |
| `feedback_prep_manifest.csv`| what was read, what was resolved, what came from a default, when |

The manifest records the values the run actually used, not the flags you typed,
and lists separately which of them came from a default. A comparison made later
is only interpretable next to it.

## Usage

```
Rscript messageix/optional/feedback_prep/feedback_prep.R \\
  --iamc /abs/path/message_output.csv \\
  --pollutant-map my_pollutant_map.txt
```

Those two are the required arguments. Every other value has a worked default, and
each one that gets used is narrated as it is applied, written into the manifest
under `values_from_defaults`, and listed again at the end of the run. Override
any of them:

```
Rscript messageix/optional/feedback_prep/feedback_prep.R \
  --iamc      /abs/path/message_output.csv \
  --weights   "Emissions|CO2" \
  --deflator  1.13 \
  --pollutant-map my_pollutant_map.txt \
  --biovar    "Primary Energy|Biomass|Energy Crops" \
  --experiment default
```

Each half also runs alone: `prep_carbon_price.R`, `prep_bioenergy_demand.R`.
Every option is accepted as `--key value` and as `--key=value`, matching the rest
of `messageix/`.

## ASSUMPTIONS TO CONFIRM

**Read this before a production run.** Nothing below fails when it is wrong. The
files still write, MAgPIE still solves, and every run inherits the error. These
are the assumptions the scripts make when you do not tell them otherwise.

### Input variable names

The MESSAGE output is read by IAMC variable name, and the names below are
conventions rather than guarantees. Confirm they are what your reporting
actually emits.

| What         | Assumed variable                                   | Override           |
| ------------ | -------------------------------------------------- | ------------------ |
| Carbon price | `Price\|Carbon`                                     | `--price-variable` |
| Price weight | `Emissions\|CO2`                                    | `--weights`        |
| 2G bioenergy | first of `Primary Energy\|Biomass\|Energy Crops`, the `Modern\|w/ CCS` + `w/o CCS` pair, or `Primary Energy\|Biomass\|Modern` that the file carries in full | `--biovar` (repeatable, summed) |

The bioenergy choice is the one most likely to be wrong for you. `Energy Crops`
is tried first because purpose-grown lignocellulosic biomass is what MAgPIE
supplies and is the variable the REMIND-MAgPIE coupling uses for the same
handshake. The `Modern` fallbacks are broader: on a run that also burns residues
they count biomass MAgPIE never grew, which inflates the demand it is held to.
The run reports which set it used.

Residue and first-generation streams are in none of the default sets. Name them
with `--biovar` if your linkage means to include them.

### Numeric conventions

| What                | Assumed                                                    | Override           |
| ------------------- | ---------------------------------------------------------- | ------------------ |
| Weighting           | regional prices averaged by the weight variable, into one global trajectory. `--weights none` keeps them regional | `--weights`        |
| Currency deflator   | read from the price variable's own unit: 1.23 for US$2005 (the pipeline's `currency_2005_to_2017`), **1.13 for US$2010**, 1 for US$2017 | `--deflator`       |
| Pollutant factors   | **no default -- required** | `--pollutant-map`  |

**The 1.13 deflator** is the only defaulted number in this folder with no second
source in the repository. The USD2005 factor is the pipeline's own, so the
deflator into MAgPIE and its reciprocal back out cannot drift apart; the 2010
figure has no such anchor.

### The pollutant map has no default, on purpose

`--pollutant-map` is required. Running without it prints what the file must
contain, read out of the GAMS `pollutants` set, and stops.

The GWP values have to be the ones the MESSAGE run itself accounted with. A run
reporting on AR5 needs 28 and 265; AR6 is 27.0 and 273. When the two models price
non-CO2 gases on different horizons, nothing downstream catches it -- the file
passes every structural check and every MAgPIE run inherits the error. It is the
one value here that no later step can question, which is why this step refuses to
guess rather than defaulting and warning.

Copy `pollutant_map.template.txt`, fill the factor column, and pass your copy.
The template ships with the factors blank and documents what each is made of: the
mass basis (`co2_c` per tonne of carbon carries 44/12; `n2o_n_*` per tonne of
nitrogen carries 44/28) times the GWP.

### Region names

Region labels are matched against `messageix/data/region_names_R12.csv` in three
spellings: the long MESSAGEix name (`SubSaharanAfrica`), the bare MAgPIE code
(`AFR`), and the prefixed form reporting usually emits (`R12_AFR`). All three
resolve through that one table, so no mapping is invented here. A label matching
none of them stops the run and names what the table does carry.

## Provenance

No script was ported. The two computations here are written against this
repository's own `f56` and `f60` contracts. The working carbon-price and
bioenergy numbers behind earlier runs were produced as ad-hoc console work and
were never a script, confirmed 2026-08-31, so there was nothing to adapt.

Two upstream references informed the shape rather than the content:

- `message_data/projects/justmip/utils/scenario_extractors.py`,
  `extract_emission_price()` -- the shape of a `PRICE_EMISSION` pull and its
  `USD/tC` unit convention.
- `message_data/tools/utilities/add_globiom.py` -- the MESSAGE-to-land-model
  handoff this folder is the MAgPIE-side analogue of.

Everything under **Assumptions to confirm** is the part that stands in for a
decision nobody has written down yet. Once those are settled, edit the defaults
in place: `DEFAULT_WEIGHT_VARIABLE` and `DEFLATOR_2010_TO_2017` in `prep_carbon_price.R`,
and `DEFAULT_BIOENERGY_VARIABLES` in `prep_bioenergy_demand.R`. The pollutant map
stays a required argument. The readers, writers and structural checks around them
do not change.
