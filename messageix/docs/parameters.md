# Parameter reference

Every setting the pipeline has, in three tiers: what a narrative varies, what the machine
overrides, and what the pipeline works out for itself. If you are looking for how to run
things, start at [`../README.md`](../README.md); for what the pipeline computes,
[`pipeline.md`](pipeline.md).

The three tiers exist because the settings have three different owners:

| Tier | Lives in | Who changes it |
| --- | --- | --- |
| Narrative | [`../presets/narratives.csv`](../presets/narratives.csv) | the researcher designing the experiment |
| Infrastructure | [`../R/pipeline_infrastructure.R`](../R/pipeline_infrastructure.R) | whoever is adapting the pipeline to a machine, or testing a variation |
| Derived | worked out in [`../R/utils_config.R`](../R/utils_config.R) | nobody — setting one is an error |

---

## 1. Narrative settings

Rows of `presets/narratives.csv`. Columns are narratives; a new narrative is a new column.
An empty cell takes the default below, so a column may leave any row out.

| Row | Meaning | Unit / allowed values | Default |
| --- | --- | --- | --- |
| `ssp` | Which shared socioeconomic pathway the run follows. Applied from MAgPIE's own `config/scenario_config.csv` before anything else here, and the first token of every run name | `SSP1` … `SSP5` | `SSP2` |
| `region_set` | The set of world regions the run solves for. It selects the input tarballs and the region-name table together, so runs and matrix cannot end up at different resolutions | a set the pipeline knows: `R12` | `R12` |
| `bii_target` | Share of the biodiversity intactness index to maintain (`s44_bii_target`) | fraction of 1, in [0, 1). Tried so far: 0 / 0.7 / 0.74 / 0.78 | `0` |
| `mp_substitution` | Share of ruminant meat and dairy demand met by microbial protein instead (`s15_rumdairy_scp_substitution`, divided by 100 on the way in) | percent, 0–100. Tried so far: 0 / 25 / 50 / 75 | `0` |
| `protect_scenario` | Land protection scenario in stages 2 and 3 (`c22_protect_scenario`) | a MAgPIE protection scenario, e.g. `none`, `BH`, `WDPA` | `none` |
| `protect_scenario_step1` | Land protection scenario the reference land-use intensity trajectory is calibrated under, in stage 1 | as above | `BH` |
| `yields_scenario` | Whether crop yields carry climate change impacts (`c14_yields_scenario`). `nocc` is defensible at 1–1.5 °C of warming; scenarios approaching 2 °C should use `cc`, where impacts are material | `cc` \| `nocc` | `nocc` |
| `tc_cost` | How costly yield-increasing technological change is (`c13_tccost`). `high` makes intensifying existing cropland expensive, so the model leans more on expanding it | `high` \| `medium` \| `low` | `high` |
| `cropland_max_growth` | Ceiling on how fast cropland may expand in a region (`s30_annual_max_growth`). A deliberate brake on how fast the sweep may reallocate land; MAgPIE's own default lifts it entirely | fraction per year, positive. `Inf` = no brake | `0.02` |
| `bii_missing_cost` | Cost charged where the biodiversity intactness index has no data (`s44_cost_bii_missing`). Ten times MAgPIE's default, so data gaps are not the cheapest place to put land-use pressure | USD17MER, non-negative | `10000000` |
| `nonco2_price_cap_usd17_tc` | Cap on the price applied to CH4 and N2O in stage 3 (`s56_limit_ch4_n2o_price`; MAgPIE default 4920). Roughly 55 USD17 per tCO2: empirical abatement-cost curves show very little non-CO2 abatement above this price, and it keeps food prices plausible under strong mitigation | USD17MER per tC, positive | `200` |
| `be_prices` | Bioenergy price levels stage 2 sweeps. Chosen where land-use models change behaviour, with enough coverage around the turning points that interpolating between them lands on a sensible surface | USD2005 per GJ, comma-separated whole numbers | `0,5,7,10,15,25,45` |
| `ghg_prices` | GHG price levels stage 3 sweeps. Each is a label, not a price: it names one column of the supplied `f56_pollutant_prices.cs3`, which carries the trajectory the label stands for | comma-separated whole numbers | `0,10,…,4000` |

Vectors are comma-joined inside one cell; the file's delimiter is `;` so they need no quoting.
Lines starting with `#` are comments and the first line that is not one is the header.

**Any MAgPIE switch, for power users.** A row written `gms$<switch>` is assigned straight onto
`cfg$gms` at every stage. It is the escape hatch for a switch this pipeline does not expose —
`gms$food;anthro_iso_jun22`, say. A switch the pipeline already decides is refused rather than
silently overridden, and the message names the setting to use instead. Those switches are:
`c_timesteps`, `c13_tccost`, `c14_yields_scenario`, `s30_annual_max_growth`,
`s44_cost_bii_missing`, `s60_2ndgen_bioenergy_dem_min`, `s60_bioenergy_1st_subsidy`, and the
ones stage logic owns (`tc`, `c44_bii_decrease`, `s44_bii_target`, `c22_protect_scenario`,
`s15_rumdairy_scp_substitution`, `c60_2ndgen_biodem`, `c56_pollutant_prices`,
`c56_pollutant_prices_noselect`, `s56_limit_ch4_n2o_price`, `s60_bioenergy_1st_price`,
`s60_bioenergy_2nd_price`).

---

## 2. Infrastructure settings

Code defaults in `R/pipeline_infrastructure.R`. Two ways to override one without editing a
tracked file:

- **environment variable** — for a machine: `MAGPIE_MM_QOS=standby Rscript …`
- **`--set key=value`** — for one command: `--set qos=standby`, repeatable. Every R entry point
  that builds a config takes it.

An environment variable beats the code default; `--set` beats both.

| Key | `--set` form | Environment variable | Meaning | Default |
| --- | --- | --- | --- | --- |
| `timesteps` | `--set timesteps=…` | `MAGPIE_MM_TIMESTEPS` | Which years the model solves for (`c_timesteps`). `coup2110` rather than MAgPIE's `coup2100` because MESSAGEix runs to 2110; the patch steps check their output against the model years of this token | `coup2110` |
| `bioenergy_dem_min` | `--set bioenergy_dem_min=…` | `MAGPIE_MM_BIOENERGY_DEM_MIN` | Floor under second-generation bioenergy demand at stages 2–3 (`s60_2ndgen_bioenergy_dem_min`), mio. GJ/yr. Zero so the low end of the demand sweep is not truncated | `0` |
| `bioenergy_1st_subsidy` | `--set bioenergy_1st_subsidy=…` | `MAGPIE_MM_BIOENERGY_1ST_SUBSIDY` | Subsidy on first-generation bioenergy at stages 2–3 (`s60_bioenergy_1st_subsidy`), USD17MER/GJ. Must be zero, or it acts as a price floor under the bioenergy price sweep | `0` |
| `currency_2005_to_2017` | `--set currency_2005_to_2017=…` | `MAGPIE_MM_CURRENCY_2005_TO_2017` | USD2005 → USD2017 MER deflator. It multiplies the bioenergy price sweep on the way into MAgPIE, and its reciprocal (0.81300813) converts prices back out in `MM_linkage_mapping.csv`. It moves when MAgPIE's base year moves — revisit at every version bump, and move both numbers together | `1.23` |
| `biodem_scenario_step1` | `--set biodem_scenario_step1=…` | `MAGPIE_MM_BIODEM_SCENARIO_STEP1` | The business-as-usual bioenergy demand path the reference trajectory is calibrated against in stage 1 (`c60_2ndgen_biodem`) | `R34M410-SSP2-NPi2025` |
| `ghg_price_scenario_step2` | `--set ghg_price_scenario_step2=…` | `MAGPIE_MM_GHG_PRICE_SCENARIO_STEP2` | GHG price scenario for stage 2 (`c56_pollutant_prices`). This one is zero in every region and period, so the bioenergy price is the only signal stage 2 varies | `SSPDB-SSP2-Ref-MESSAGE-GLOBIOM` |
| `ghg_price_scenario_suffix` | `--set ghg_price_scenario_suffix=…` | `MAGPIE_MM_GHG_PRICE_SCENARIO_SUFFIX` | Suffix on the stage-3 GHG price scenario names, recording how the trajectory is extended past the last reported year | `exp2110` |
| `input_calibration` | `--set input_calibration=…` | `MAGPIE_MM_INPUT_CALIBRATION` | Calibration tarball. Empty means no calibration entry at all, which is what the pinned runs used | *(empty)* |
| `output_modules` | `--set output_modules=a,b` | `MAGPIE_MM_OUTPUT_MODULES` | Post-processing scripts each run executes when it finishes (`cfg$output`) | `output_check,rds_report` |
| `force_replace` | `--set force_replace=FALSE` | `MAGPIE_MM_FORCE_REPLACE` | Whether re-running a name may overwrite its run folder. `TRUE`, because run names are worked out from the settings and re-running one is meant to be routine | `TRUE` |
| `poll_seconds` | `--set poll_seconds=…` | `MAGPIE_MM_POLL_SECONDS` | Seconds between checks while the pipeline waits for a stage's runs. Each check reads the solve status out of every finished run, so it is not free | `300` |
| `timeout_hours` | `--set timeout_hours=…` | `MAGPIE_MM_TIMEOUT_HOURS` | Hours to wait for one stage before giving up. 48 covers the 84-run stage-3 sweep sitting behind other people's work in the queue | `48` |
| `qos` | `--set qos=standby` | `MAGPIE_MM_QOS` | SLURM quality of service, which picks the submission script a run is handed to (`scripts/run_submit/submit_<qos>.sh`). `priority` is a PIK queue name; a site without it must override | `priority` |
| `slurm_modules` | `--set slurm_modules=a,b` | `MAGPIE_MM_MODULES` | Environment modules loaded before Rscript, in load order. `gcc` must come last: the compiled piam packages need a C++ runtime symbol that only that module's libstdc++ provides | `defaults/piam/1.27,R/4.3.2,gcc/15.2.0` |
| `mail_user` | `--set mail_user=…` | `MAGPIE_MM_MAIL_USER` | Address SLURM mails job notifications to. Empty means job scripts carry no mail instructions at all | *(empty)* |
| `patch_repo` | `--set patch_repo=…` | `MAGPIE_MM_PATCH_REPO` | Directory the patch steps write their tarballs into, and the first place MAgPIE looks for input tarballs | `./patch_input` |
| `magpie_public_repo` | `--set magpie_public_repo=…` | `MAGPIE_MM_PUBLIC_REPO` | Repository serving the base input tarballs | `https://rse.pik-potsdam.de/data/magpie/public` |
| `matrix_sdg_scen` | `--set matrix_sdg_scen=…` | `MAGPIE_MM_MATRIX_SDG_SCEN` | Value written into the `SDGscen` column of every matrix row | `noSDG_rcpref` |

`--set` also reaches every narrative setting (`--set bii_target=0.74`), which is how a variation
is tried without adding a column.

### Region sets

A region set is one entry in `R/pipeline_infrastructure.R` pairing the four input tarballs with
the region-name table that goes with them. `R12` is the only one so far:

| Part | Value |
| --- | --- |
| regional | `rev4.119_5ff27be8_magpie.tgz` |
| cellular | `rev4.119_5ff27be8_1b5c3817_cellularmagpie_c200_MRI-ESM2-0-ssp245_lpjml-8e6c5eb1.tgz` |
| validation | `rev4.119_5ff27be8_validation.tgz` |
| additional | `additional_data_rev4.62.tgz` |
| region names | [`../presets/region_names_R12.csv`](../presets/region_names_R12.csv) |

Adding one is that entry plus its region-name table; a narrative then says `region_set;R10` and
nothing else changes. The recipe is in [`pipeline.md`](pipeline.md) §8, "New region set".

---

## 3. Derived values

Worked out from the settings above. Nothing may set them — a narrative that could choose its
own names could choose another narrative's, and the second run would overwrite the first
without saying so.

| Value | Rule | `default` | `biodiversity` |
| --- | --- | --- | --- |
| `regionscode` | the middle token of the regional tarball name, `rev<revision>_<code>_magpie.tgz` | `5ff27be8` | `5ff27be8` |
| `identifier` | `MESSAGEix_<regionscode>` for the column named `default`, `MESSAGEix_<regionscode>_<column>` for any other. It is the folder every run of the narrative goes into | `MESSAGEix_5ff27be8` | `MESSAGEix_5ff27be8_biodiversity` |
| `matrix_basename` | `magpie_input_<ssp>_ref` for `default`, `magpie_input_<ssp>_<column>` for any other. The woodfuel step appends `_woodfuel` | `magpie_input_SSP2_ref` | `magpie_input_SSP2_biodiversity` |
| `region_names`, the four input tarballs | whatever `region_set` pairs them with | the R12 set | the R12 set |

Run names below the identifier are derived too, and carry only the position in the sweep:
`tau` for the reference run, `BE05` for a stage-2 run, `BE05_G0400` for a stage-3 one. So is
the bioenergy demand column stage 2 writes and stage 3 selects, `<narrative>_BE05`. The full
table is in [`pipeline.md`](pipeline.md) §7.

Two consequences worth stating plainly. **A narrative's name becomes a folder name and a GAMS
set element**, so it takes letters, digits, dash and underscore only, and two columns of one
file cannot share a name. And **the `default` column carries no name token**, which is what
keeps the pinned matrix at `magpie_input_SSP2_ref_woodfuel.csv`.

---

## 4. Settled in code, and why

Not settings at all: values used where they are computed, which changing means editing the code
that uses them.

| Value | Where | Why it is not exposed |
| --- | --- | --- |
| Woodfuel energy content, 18 GJ per tonne dry matter | `emulator/add_woodfuel_to_matrix.R` | one physical constant, used once |
| Gap filling: adjacent-year mean, everything past 2100 held at the 2100 value | `patches/build_step3_patch.R` | past 2100 there is no later reported year to average against |
| Historical second-generation bioenergy zeroed for 1995–2015 | `patches/build_step3_patch.R` | no such production existed |
| GWP100 factors, CH4 27 and N2O 273 (AR6) | `emulator/MM_linkage_mapping.csv` | they belong with the variable mapping that applies them |
| The three stage asymmetries — protection scenario, BII decrease, and where the non-CO2 cap applies | `R/utils_config.R`, `stage_cfg()` | they are what makes a stage that stage; a narrative changing one by accident would stop reproducing the pinned runs |
