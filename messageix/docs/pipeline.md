# The MAgPIE → MESSAGEix land-use emulator pipeline

Science documentation for `messageix/`. Written for a researcher who knows MESSAGEix but is
new to MAgPIE. Scientific authorship of the pipeline: Di Sheng (IIASA).

The emulator answers one question for MESSAGEix: **how much second-generation bioenergy can
land deliver at a given bioenergy price and GHG price, and what land outcomes — emissions,
prices, land cover — follow.** Three MAgPIE run stages, two generation steps between them,
and a matrix step produce that response surface.

---

## 1. Workflow

```
Input tarballs  rev4.119, R12 (regionscode 5ff27be8)
      |
Step 1     reference tau            1 run,  tau endogenous, BAU bioenergy demand
      |
Step 1.5   extract tau            → step-2 patch tarball
      |
Step 2     price-driven            7 runs, tau exogenous, GHG price 0
      |
Step 2.5   extract bioenergy demand + carbon price trajectories
                                  → step-3 patch tarball
      |
Step 3     demand-driven          84 runs (7 BE x 12 GHG), tau endogenous
      |
Matrix     84 report.mif -> MM_linkage_mapping.csv -> matrix CSV
           84 fulldata.gdx -> woodfuel -> Primary Energy|Biomass
      |
MESSAGEix land emulator matrix
```

Steps 1.5 and 2.5 are code, not manual steps. Every artefact that moves between stages is
produced by a script in `messageix/patches/` and named by `messageix/R/utils_paths.R`.

### Step 1 — reference tau

Tau is MAgPIE's land-use intensity trajectory: a regional productivity parameter comparable
to a total-factor-productivity calibration in an IAM. Step 1 runs MAgPIE once with
technological change **endogenous** (`cfg$gms$tc` unset, realization `endo_jan22`) against the
business-as-usual second-generation bioenergy demand path
`c60_2ndgen_biodem = "R34M410-SSP2-NPi2025"`, and exports the tau trajectory the model solves
for. The reference tau is therefore exactly as reasonable as the MAgPIE team's BAU
calibration.

Step 1 runs under the NPi GHG price scenario (`c56_pollutant_prices` unset, so the MAgPIE
default `R34M410-SSP2-NPi2025` applies) and under land conservation `c22_protect_scenario =
"BH"` — steps 2 and 3 use `"none"`. It also runs with `c44_bii_decrease = 0` where steps 2
and 3 use `1`, and leaves `s30_annual_max_growth`, `s44_cost_bii_missing` and the `s60_*`
switches at MAgPIE defaults. These asymmetries are properties of the golden runs and are
reproduced exactly by the `default` preset.

One run per MAgPIE version per set of step-1 settings. The run folder
`output/<identifier>/<ssp>_tau` carries no narrative token, because a reference tau is reusable
across narratives — but only across narratives that agree on every step-1-relevant setting, and
`c13_tccost`, `c14_yields_scenario`, `c_timesteps`, the step-1 protection and bioenergy-demand
scenarios and the input tarball names are all preset-driven. Step 1 therefore writes
`messageix_stage1_fingerprint.txt` into its run folder, listing exactly those settings, and step
1.5 refuses to extract tau from a run whose fingerprint disagrees with the preset it was invoked
with (`messageix/R/utils_runs.R`). Within one version and one fingerprint, an existing trajectory
is reused.

### Step 1.5 — tau → step-2 patch tarball

`messageix/patches/build_step2_patch.R` reads `ov_tau` from the step-1 `fulldata.gdx`,
writes `f13_tau_scenario.csv`, and packs it into a patch tarball in `patch_input/`. See
§2 for the tau mechanics and §3 for the tarball mechanism.

### Step 2 — price-driven, 7 runs

Seven runs impose bioenergy price incentives of **0, 5, 7, 10, 15, 25, 45 $2005/GJ**, scaled
by 1.23 into MAgPIE's internal $2017 unit and applied to both
`s60_bioenergy_1st_price` and `s60_bioenergy_2nd_price`. The GHG price is set to zero by
selecting `c56_pollutant_prices = "SSPDB-SSP2-Ref-MESSAGE-GLOBIOM"`, a standard scenario in
the base tarball that is zero across all regions and periods. Tau is fixed to the step-1
reference via `cfg$gms$tc <- "exo"`.

Fixing tau isolates the price response: land supplies bioenergy under a known productivity
path. Each run reports second-generation bioenergy production by region — seven demand
trajectories.

Two switches must be moved off their MAgPIE defaults or the sweep is distorted:
`s60_2ndgen_bioenergy_dem_min = 0` (default 1 mio. GJ/yr imposes a demand floor) and
`s60_bioenergy_1st_subsidy = 0` (default 6.5 USD17/GJ acts as a price floor).

### Step 2.5 — bioenergy demand + carbon prices → step-3 patch tarball

`messageix/patches/build_step3_patch.R` reads the seven step-2 `fulldata.gdx`, extracts
regional second-generation bioenergy production with
`magpie4::reportProductionBioenergy(detail = FALSE, level = "reg")` filtered to
`"2nd generation|++"`, converts EJ/yr to PJ/yr (`x 1000`; MAgPIE's "mio. GJ" is PJ), and
appends seven new scenario columns to `f60_bioenergy_dem.cs3`.

Two cleaning rules apply, both documented defaults:

- **Gap fill.** Years absent from the run report are filled by the mean of the adjacent
  five-year steps; years after 2100 are held at the 2100 value.
- **Historical zeroing.** Second-generation production is set to zero for 1995–2015. No such
  production existed. MAgPIE's exogenous read-lock (heading to 2025) means these values do
  not move results; the code holds them as a named vector so a historical path can replace
  the zeros without structural change.

The cs3 is **seeded from the base tarball's own `f60_bioenergy_dem.cs3`** before the seven
columns are appended. The seed is not optional: `c60_2ndgen_biodem_noselect` defaults to
`R34M410-SSP2-NPi2025` and is dereferenced unconditionally in
`modules/60_bioenergy/1st2ndgen_priced_feb24/preloop.gms`, so that column must survive into
the patched file or GAMS fails on an unknown set element.

The same tarball carries `f56_pollutant_prices.cs3` with twelve `G####exp2110` GHG price
trajectory columns over `(t_all, i, pollutants, ghgscen56)` in USD17MER per t. **That file is
supplied by the caller** (`--f56=PATH`); no generator for it exists in the repository (see
`decisions.md`, open items). What the generator does do is check it: the pollutant sub-dimension
must come first and must equal the GAMS `pollutants` set, because `scripts/start_functions.R`
reads the `ghgscen56` set from `dim = 2` — a transposed file would write pollutant names into
`ghgscen56` and no run could resolve its `c56_pollutant_prices` column.

### Step 3 — demand-driven, 84 runs

The seven bioenergy demand paths become exogenous inputs
(`c60_2ndgen_biodem = "<preflag>_BE<be>"`), crossed with twelve GHG price trajectories
**0, 10, 20, 50, 100, 200, 400, 600, 1000, 2000, 3000, 4000**, exponentially extended to
2110. Tau returns to endogenous so land-use intensity responds freely to the combined price
and demand signal. Bioenergy prices are zero here: the stage is demand-driven, not
price-driven.

These 84 runs are the emulator's sampling grid. Each produces `report.mif` (matrix input)
and `fulldata.gdx` (woodfuel input), roughly 1 GB per run.

**The non-CO2 carbon price cap is a config value, not a data edit.**
`cfg$gms$s56_limit_ch4_n2o_price` caps the carbon price applied to CH4 and N2O inside GAMS,
whatever trajectory `c56_pollutant_prices` selects. The preset sets it to **200 USD17MER/tC**
(roughly 55 USD17/tCO2) against a MAgPIE default of 4920. Nothing inside a patch tarball is
capped, so changing the cap is a one-line preset change with no artefact regeneration.

---

## 2. Tau mechanics

`modules/13_tc/exo/realization.gms` states the contract: the `tau` function in the `magpie4`
package generates `f13_tau_scenario.csv`, region- and time-specific, from an existing run;
the file replaces the dummy in `modules/13_tc/input/`.

Two equivalent exports:

```r
magpie4::tau(gdx, file = "f13_tau_scenario.csv")

write.magpie(readGDX(gdx, "ov_tau", select = list(type = "level")),
             "f13_tau_scenario.csv")
```

`ov_tau(t, h, tautype, type)` at `type = "level"` has exactly the shape of
`f13_tau_scenario(t_all, h, tautype)` declared in `modules/13_tc/exo/input.gms`. The second
form is the one used by MAgPIE's own project start scripts (`paper_peatlandTax.R`,
`project_BEST.R`, `project_WetHorizons.R`).

Two properties the export must satisfy, both checked in R before the tarball is packed
because the GAMS-side failure is opaque:

- **Every value strictly positive.** `modules/13_tc/exo/presolve.gms` aborts the run if any
  tau is ≤ 0, then fixes `vm_tau.fx(h, tautype)` to the file values.
- **Full coverage** of every model year in `coup2110` for every superregion `h`.

Tau travels between stages as a patch tarball, not as a workflow step, because MAgPIE reads
inputs either from the version-pinned base tarball or from a patch tarball — there is no
third channel. The patch stops being hand-assembled; it does not stop being a patch.

---

## 3. Patch tarballs

**A patch tarball is MAgPIE's project-override mechanism, not a software patch.**
`cfg$input` is a named character vector of tarball filenames:

```r
cfg$input <- c(regional   = "rev4.119_5ff27be8_magpie.tgz",
               cellular   = "rev4.119_5ff27be8_1b5c3817_cellularmagpie_c200_MRI-ESM2-0-ssp245_lpjml-8e6c5eb1.tgz",
               validation = "rev4.119_5ff27be8_validation.tgz",
               additional = "additional_data_rev4.6x.tgz",
               patch      = "<generated>.tgz")
```

Mechanics that matter:

- **Order.** Later entries overwrite earlier ones. The `patch` entry is listed **last**.
- **Resolution.** `cfg$repositories` is searched in order. The pipeline prepends the PIK
  public repository and `"./patch_input"` to `getOption("magpie_repos")`, so a generated patch
  is a plain `.tgz` in `patch_input/` at the model root. That directory does not exist in a
  fresh clone; the generator creates it.
- **Layout.** `gms::download_distribute()` extracts every tarball flat and routes each file to
  the module `input/` folder whose `input/files` manifest names it; unclaimed files go to
  `input/`. **A patch tarball therefore contains bare filenames at the archive root — no
  directory structure.**

Relevant manifests:

| Manifest | Files the pipeline overrides |
| --- | --- |
| `modules/13_tc/input/files` | `f13_tau_scenario.csv` |
| `modules/56_ghg_policy/input/files` | `f56_pollutant_prices.cs3` |
| `modules/60_bioenergy/input/files` | `f60_bioenergy_dem.cs3` |

### Patch names are content-hashed

`start_run()` decides whether to re-extract inputs with

```r
if (!setequal(cfg$input, input_old) | cfg$force_download) download_and_update(cfg)
```

where `input_old` is read from `input/info.txt`. **The comparison is over tarball filenames,
not contents.** Regenerating a patch under a name a previous run already used is a silent
no-op: MAgPIE keeps the old data, keeps the old regenerated set files, and the run proceeds
with stale inputs and no warning.

The pipeline therefore names generated patches `<preset>_<stage>_<8hexhash>.tgz`, where the
hash derives from the tarball contents. New contents mean a new name, so re-extraction is
correct by construction and re-running with unchanged inputs correctly skips the download.
`run_stage()` asserts the mechanism held: after `start_run()` returns for the first run of a
stage, `input/info.txt` must name that stage's patch tarball, or the run is reading a previous
run's inputs and the stage stops.

---

## 4. Set auto-regeneration, and why the tree goes dirty

`download_and_update()` runs two generators after distributing files.

**`.update_sets_core()`** writes `core/sets.gms` — the sets `h`, `i`, `supreg(h,i)`, `iso`,
`j`, `cell(i,j)`, `i_to_iso(i,iso)` — from the `map` object loaded out of the tarball's own
`input/spatial_header.rda`. The file carries a "DO NOT MODIFY, WILL BE LOST" banner and
`.update_sets_core` hard-fails on a mismatch between the header's region list and the cellular
data. **The R12 region set is delivered by the input tarball. It is never delivered by a
committed file.**

**`.update_sets_modules()`** reads the *scenario column names* out of the distributed input
files and writes them into GAMS set files:

| Source file | Set | Written to |
| --- | --- | --- |
| `f56_pollutant_prices.cs3` | `ghgscen56` | `modules/56_ghg_policy/price_aug22/sets.gms` |
| `f56_emis_policy.csv` | `scen56` | same |
| `f60_bioenergy_dem.cs3` | `scen2nd60` | `modules/60_bioenergy/{1stgen_priced_dec18,1st2ndgen_priced_feb24}/sets.gms` |

**This is the whole trick.** Appending a column named `SSP2_BD00_BE10` to
`f60_bioenergy_dem.cs3`, or `G0400exp2110` to `f56_pollutant_prices.cs3`, makes it a valid set
member automatically, so `cfg$gms$c60_2ndgen_biodem <- "SSP2_BD00_BE10"` resolves. Never
hand-edit these `sets.gms` files — the next download overwrites them.

Note the corollary: `.update_sets_modules()` runs only inside `download_and_update()`. Skip
the download and the sets are not refreshed either — the second reason patch names are
content-hashed.

Separately, `apply_cfg()` runs `lucode2::manipulateConfig()` over `main.gms` and **every**
`modules/*/*/input.gms` on every run, rewriting `$setglobal` and scalar values from `cfg$gms`.
`.update_info()` rewrites the VERSION INFO block in `main.gms`, including the `Regionscode:`
line.

**Consequence: a dirty working tree after a run is normal MAgPIE behaviour.** `core/sets.gms`,
`main.gms`, the module `input.gms` and `sets.gms` files are build products of `cfg$input` and
`cfg$gms`. Committing them buys nothing, costs a merge conflict on every upstream version bump,
and is overwritten by the next run. **Never `git add` them.** Everything the pipeline needs to
say about model configuration is said in `messageix/presets/scenario_config.csv`; everything it
needs to say about geometry is said by `cfg$input`.

One operational exception: if the region set changes on a tree that has already run, set
`cfg$force_download <- TRUE`. A fresh clone has no `input/info.txt` and downloads regardless.

---

## 5. Matrix generation and woodfuel

**Matrix.** `messageix/emulator/createMatrix_MM.R` reads the 84 `report.mif`, applies
`MM_linkage_mapping.csv` through `iamc::write.reportProject()` to rename, aggregate and
unit-convert MAgPIE variables into the MESSAGEix set, tags each run with its scenario
coordinates, concatenates, and writes one CSV.

Output schema: `Region, Variable, Unit, SSPscen, GHGscen, BIOscen, SDGscen` followed by year
columns ascending. `Model` and `Scenario` are dropped. R12 codes are renamed to MESSAGEix
long names (`AFR → SubSaharanAfrica`, `CHA → ChinaReg`, `CPA → PlannedAsiaChina`,
`EEU → CentralEastEurope`, `FSU → FormerSovietUnion`, `LAM → LatinAmericaCarib`,
`MEA → MidEastNorthAfrica`, `NAM → NorthAmerica`, `PAO → PacificOECD`,
`PAS → OtherPacificAsia`, `SAS → SouthAsia`, `WEU → WesternEurope`, `GLO → World`).

`MM_linkage_mapping.csv` is semicolon-delimited with columns
`piam_variable;Variable;factor;weight;spatial`; many-to-one rows sum into one target. The
numeric factors carry science:

| Rows | Factor | Meaning |
| --- | --- | --- |
| most | `1` | pass-through |
| `Emissions\|N2O\|*` | `1000` | Mt N2O → kt N2O |
| `Carbon Removal\|*` | `-1` | emissions sign flipped to removals |
| CH4 → `Emissions\|GHG\|AFOLU` | `27` | AR6 GWP100, CH4 |
| N2O → `Emissions\|GHG\|AFOLU` | `273` | AR6 GWP100, N2O |
| price rows | `0.81300813` | US$2017 → US$2005, the reciprocal of the 1.23 used on bioenergy prices |

The last row is a coupling across two files: `createMatrix_MM.R` reads the `factor` of every row
whose target `Variable` starts with `Price|` and stops the build unless it equals
`1 / pipeline$currency_2005_to_2017` to within `1e-6`. Moving the deflator without moving the
mapping is a stop, not a silently mis-converted price row.

The build **fails** rather than emitting a partial matrix when any of the 84 runs is missing
or unsolved. Solvedness is a `modelstat` check, not `file.exists()`. A non-empty
`missing_log` — a variable named in the mapping that no run produced — is reported, never
silently written as NA.

**Woodfuel.** Forest-harvest woodfuel is absent from `report.mif`, so
`add_woodfuel_to_matrix.R` reads `pm_demand_forestry[, , "woodfuel"]` (Mt DM) from each run's
`fulldata.gdx`, converts at **18 GJ/tDM** — a MAgPIE-team value that deliberately overrides
the `fm_attributes` entry in the gdx — truncates at 2110, builds a `World` row as the plain
sum over regions, and adds the result to the `Primary Energy|Biomass` rows, matched on
`BIOscen | GHGscen | Region | year`.

Adding woodfuel does **not** double count against the `Demand|Bioenergy|++|Traditional
Burning` term that the mapping also routes into `Primary Energy|Biomass`. What does persist
is a structural gap between MAgPIE's land-use bioenergy supply and MESSAGE's demand: MAgPIE
does not calibrate bioenergy supply to IEA statistics while its bioenergy scope is still
expanding. The gap is bridged downstream by a slack variable in the land emulator that phases
to zero across calibration and future model years. This is the documented operating mode, not
a methodological error. GLOBIOM's supply sits closer to MESSAGE demand.

The woodfuel extraction builds on code by Kristine Karstens (PIK); the credit stays in the
file header.

**One check to run against the first matrix.** All 81 mapping rows carry `spatial = reg+glo`.
Intensive quantities — `Biodiversity|BII`, `Price|Primary Energy|Biomass`, `Price|Carbon|CO2`,
`Landuse intensity indicator Tau` — must not be summed across regions. If a World value looks
roughly 13x too large, change those rows to `spatial = reg`. The five `Food Demand` rows carry
`weight = Population (million people)` and are weight-averaged. Also confirm that
`Emissions|CO2|AFOLU` equals land-use change plus crop-residue burning.

---

## 6. Defaults that carry science weight

Each is a deliberate choice with a provenance. `E` = exposed in the scenario config;
`D` = documented default, not exposed; `C` = structural identity; `F` = fixed by the stage.

| Setting | Value | Provenance |  |
| --- | --- | --- | --- |
| `c14_yields_scenario` | `nocc` — yields exclude climate change | Defensible at 1–1.5 °C; Earth Commission switches to the with-climate-change setting because those scenarios approach 2 °C where yield impacts are material. | E |
| `c13_tccost` | `high` | Florian, prior experiments | E |
| `s30_annual_max_growth` | `0.02` — cropland growth capped at 2 %/yr per region | Florian, prior experiments. MAgPIE default `Inf` | E |
| `s44_cost_bii_missing` | `1e7` USD — 10x the MAgPIE default | Florian, prior experiments | E |
| `s56_limit_ch4_n2o_price` | `200` USD17MER/tC | Empirical MAC curves show non-CO2 abatement above ~$200/tC is trivial; for Earth Commission the cap also keeps food prices plausible under strong mitigation. MAgPIE default `4920` | E |
| `s44_bii_target` | `0` | Narrative parameter; tested alternatives 0.7 / 0.74 / 0.78 | E |
| `c44_bii_decrease` | `1` in steps 2–3, `0` in step 1 | Derived from the BII target | E |
| `c22_protect_scenario` | `BH` in step 1, `none` in steps 2–3 | Property of the golden runs; see `decisions.md`, open items | E |
| `s15_rumdairy_scp_substitution` | `0` | Narrative parameter; tested alternatives 25 / 50 / 75 % | E |
| Bioenergy price vector | `0, 5, 7, 10, 15, 25, 45` $2005/GJ | Levels chosen where land-use models shift behaviour, with coverage at the inflection points so weighted-average interpolation lands on a reasonable surface. Confirmed as still appropriate on the version bump | E |
| GHG price vector | `0 … 4000`, exponentially extended to 2110 | as above | E |
| Currency conversion | `1.23` for $2005 → $2017 | MAgPIE-team factor. **Standing attention item** — MAgPIE's base year moves when MAgPIE updates; revisit on every version bump. One value, two reciprocal uses (`x1.23` on prices into MAgPIE, `x0.813` on prices out via the mapping) | E |
| `c_timesteps` | `coup2110` | MESSAGE horizon; MAgPIE default `coup2100`. A required preset row: the patch generators validate their output against the model years of this token | C |
| `s60_2ndgen_bioenergy_dem_min` | `0` | MAgPIE default 1 mio. GJ/yr would floor the demand sweep. Exposed as a `gms$` preset row, applied at steps 2–3 only | E |
| `s60_bioenergy_1st_subsidy` | `0` | MAgPIE default 6.5 USD17/GJ acts as a price floor. Exposed as a `gms$` preset row, applied at steps 2–3 only | E |
| Woodfuel energy content | `18` GJ/tDM | MAgPIE-team value, overriding the gdx `fm_attributes` entry | D |
| Gap fill | adjacent-year mean; post-2100 held at 2100 | Carried from the established workflow | D |
| Historical 2nd-gen bioenergy | zero for 1995–2015 | No such production existed; all teams carry zeros. Coded as a replaceable vector | D |
| GWP100 | CH4 27, N2O 273 | AR6 | D |
| `tc` realization | `exo` in step 2, endogenous elsewhere | Defines the stage | F |

---

## 7. Naming contract

Defined once, in `messageix/R/utils_paths.R`. Two encodings of the bioenergy level are in
play and both are required:

| Token | Form | Example |
| --- | --- | --- |
| Narrative prefix | `paste0("SSP2_BD", pad2(round(bl * 100)))` | `SSP2_BD00` |
| Folder BE token | `BE` + zero-pad to 2 | `BE00 BE05 BE07 BE10 BE15 BE25 BE45` |
| Folder GHG token | `G` + zero-pad to 4 | `G0000 … G4000` |
| Scenario column name | `paste0(preflag, "_BE", be)` — **unpadded** | `SSP2_BD00_BE0 … _BE45` |
| Identifier | regionscode-stamped | `MESSAGEix_5ff27be8` |
| Results folder | `output/<identifier>/<preflag>/<title>` | `output/MESSAGEix_5ff27be8/SSP2_BD00/SSP2_BD00_BE45_G4000demand` |
| Step-2 title | `<preflag>_BE<pad2>_G0000price` | |
| Step-3 title | `<preflag>_BE<pad2>_G<pad4>demand` | |
| Matrix tags | `BIO` + pad2, `GHG` + pad3 | `BIO45`, `GHG4000` |
| Generated patch | `<preset>_<stage>_<8hexhash>.tgz` | |
| Step-1 fingerprint | `<step-1 run folder>/messageix_stage1_fingerprint.txt` | |

The unpadded scenario column name is load-bearing: it is what step 2.5 writes into
`f60_bioenergy_dem.cs3` and what step 3 requests through `c60_2ndgen_biodem`. The two must
match exactly or GAMS fails on an unknown set element, so both are derived from the same
integer in one place and asserted against each other.

---

## 8. Configuration

One CSV, one column per narrative — the MAgPIE team's own approach.
`messageix/presets/scenario_config.csv` holds two row families:

- `gms$<switch>;value` — assigned into `cfg$gms`, i.e. straight into GAMS.
- `pipeline$<key>;value` — pipeline keys: price vectors, currency conversion, tarball names,
  identifier, BII target, MP substitution, step-1 protection scenario, patch destinations.

Vectors are comma-joined. The reader (`messageix/R/utils_config.R`) accepts `;` or `,` as the
delimiter and stops on an unknown key. Resolution produces a frozen list that the three stage
drivers consume. **A new narrative is a new column, not a new start script.**

`gms$c_timesteps` is the one required row: the patch generators validate their output against
the model years of that token, and inferring it from the working tree would tie a patch to
whichever run last rewrote `main.gms`. `pipeline$matrix_basename` names the matrix CSV
`run_matrix.sh` writes when `--out` is not given (see §10).

The `default` column reproduces the golden runs exactly. Presets are read, never edited by
the pipeline.

**Command lines.** Every entry point takes `--key=value`; the two emulator scripts and
`run_matrix.sh` additionally take `--key value`, and all of them name the preset CSV `--csv`
(`--preset-csv` stays accepted as an unadvertised alias). All five carry `--help`.

---

## 9. Execution environment

Emulator generation runs on the **PIK cluster**. This is a storage constraint, not a
preference: a single MAgPIE run produces over 1 GB and full emulator generation needs roughly
**90 GB**, against a ~100 GB quota on UniCC. Three reporting levels per run inflate the output
further; trimming that is a conversation with the MAgPIE team, not a pipeline task. Access is
by requesting a PIK cluster account. Running the whole pipeline on UniCC is a long-term
aspiration.

Nothing about the environment is hard-coded. Module lists, QOS, repositories and mail
settings come from `messageix/R/utils_env.R`, driven by the preset and overridable per machine
through `MAGPIE_MM_QOS`, `MAGPIE_MM_MODULES` and `MAGPIE_MM_MAIL_USER`. `run_matrix.sh` holds no
copy of them: it asks the R layer, and passes the answers to `sbatch` on the command line. The
`#SBATCH` block inside that file is the fallback for a direct `sbatch run_matrix.sh`, which the
scheduler reads before anything can ask R.

The environment the pipeline is tested against:

```
module purge
module load defaults/piam/1.27
module load R/4.3.2
module load gcc/15.2.0      # last: the compiled piam packages (gdx2 -> Rcpp)
                            # need CXXABI_1.3.15 from this libstdc++
```

Submission: `start_run()` detects SLURM and runs `sbatch submit_<cfg$qos>.sh` from the run
folder, using MAgPIE's own `scripts/run_submit/` scripts. `qos = "priority"` is a PIK QOS
name and comes from the preset.

---

## 10. Validation

**Golden master.** With the pinned R12 tarball and the `default` preset, the emitted matrix
matches `magpie_input_SSP2_ref_woodfuel.csv` (the `SSP2_BD00` family) region by region and
variable by variable within solver tolerance. The pre-woodfuel `magpie_input_SSP2_ref.csv` is
the intermediate check. Both names come out of the preset: `pipeline$matrix_basename` is
`magpie_input_SSP2_ref`, `run_matrix.sh` writes `<matrix-dir>/<matrix_basename>.csv`, and the
woodfuel step appends `_woodfuel`. A `--out` that names something else produces a matrix under
that name instead, and the byte comparison then needs the golden name passed explicitly.

**Structural checks on every build:**

- All 84 step-3 runs present and solved before the matrix step starts — hard failure, not a
  warning. "Solved" is one set of GAMS model statuses, `{1, 2, 7}`, defined once in
  `messageix/R/utils_runs.R` and applied by both patch generators and both matrix scripts.
- `missing_log` empty or explained.
- Full year coverage, no NA after gap fill: tau and the f56 columns are NA-checked, and every
  f60 bioenergy column is NA-checked after gap filling and historical zeroing.
- `input/info.txt` names the patch tarball the generator just wrote — asserted in `run_stage()`
  after `start_run()` returns for the first run of a stage.
- The step-1 fingerprint agrees with the preset the step-2 patch is being built for — hard
  failure, because a mismatch means the reference tau belongs to another narrative.
- The mapping's price factor is the reciprocal of `pipeline$currency_2005_to_2017` (§5).
- Monotonicity spot check: the step-2.5 generator **warns**, with the numbers, when global
  second-generation bioenergy supply in 2100 falls as the bioenergy price rises. A warning
  rather than a stop — a small inversion can be a solver artefact where the response surface is
  near-flat.
- World-versus-region check on the intensive variables (§5).

**Upstream contract.** No path outside `messageix/` differs from upstream `magpiemodel/magpie`.
Merging a newer PIK tag is clean by construction. Adopting a new release means: merge the tag,
obtain the matching input tarball, regenerate the reference tau, rerun validation. The start
scripts and emulator code stay stable across versions; only data artefacts change.
