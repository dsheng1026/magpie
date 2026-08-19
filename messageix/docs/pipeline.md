# The MAgPIE → MESSAGEix land-use emulator pipeline

Science documentation for `messageix/`. Written for a researcher who knows MESSAGEix but is
new to MAgPIE. Scientific authorship of the pipeline: Di Sheng (IIASA).

The emulator answers one question for MESSAGEix: **how much second-generation bioenergy can
land deliver at a given bioenergy price and GHG price, and what land outcomes — emissions,
prices, land cover — follow.** Three phases of MAgPIE runs, the packing between them, and a
reduce phase produce that response surface.

---

## 1. Workflow

```
Input tarballs  rev4.119, R12 (region set 5ff27be8)
      |
calibrate       1 run,  tau solved for, BAU bioenergy demand
      |
      |  pack   tau                    -> the inputs the price sweep reads
      |
price           7 runs, tau held fixed, GHG price 0
      |
      |  pack   bioenergy demand + GHG price trajectories
      |                                -> the inputs the demand sweep reads
      |
demand          84 runs (7 BE x 12 GHG), tau solved for
      |
reduce          84 report.mif -> MM_linkage_mapping.csv -> matrix CSV
                84 fulldata.gdx -> woodfuel -> Primary Energy|Biomass
      |
MESSAGEix land emulator matrix
```

Two words are used precisely throughout. A **phase** is one of the four units named on the
left — `calibrate`, `price`, `demand`, `reduce`; the first three are groups of MAgPIE runs.
An **experiment** is one entry of `messageix/experiments.R`: a world (`narrative()`) and a
sampling plan (`design()`).

**Packing** is what happens between phases: the artefact one phase produced is written into a
MAgPIE patch tarball the next phase reads. It is code, not a manual step — `pack_price.R` and
`pack_demand.R` in `messageix/R/` build it, `messageix/R/utils_paths.R` names it — and it is not
a phase: nobody schedules it, it happens when what it would write is not already there, and it
is narrated as `>> PACK: ...`.

### How it is run

Two files are the user surface: `messageix/experiments.R` declares the experiments and
`messageix/run.R` runs them, one experiment at a time and one phase after another. The commands
and their flags are in `Rscript messageix/run.R --help` and in [`../README.md`](../README.md).
Four properties of a run belong here, because they are what makes a multi-day cluster pipeline
reproducible:

- **It waits.** MAgPIE submits its runs and returns, so a phase that has finished has only
  finished submitting. Between phases the pipeline polls until every run folder the experiment
  expects holds a `fulldata.gdx` whose model status is solved, narrating solved/total as it
  goes. It stops early — rather than waiting out the timeout — when the queue reports no MAgPIE
  jobs left while runs are still missing. After the demand sweep the wait also requires each
  run's `report.mif`: one job solves and then reports, minutes apart, and the reduce phase
  reads the report rather than the solver output.
- **It skips what is finished.** A run phase when every run has solved, the reduce phase when
  its `_woodfuel` CSV exists, packing when its content-hashed tarball is on disk. Restarting
  after a failure resumes rather than repeats.
- **It fails before it costs anything.** The whole command is checked before the first
  submission: the settings resolve, no two experiments write their runs or their matrix to one
  path, each phase's input either exists or is produced earlier in the same command, the
  calibration run's input tarballs are reachable, and no phase faces two candidate packed
  tarballs. The `f56` check is the point of the exercise: the supplied file must carry every
  pollutant GAMS taxes, both sub-dimensions the right way round, one column per GHG price level
  of the experiment, and every model year. Discovering a missing column while packing the
  demand sweep's inputs costs the calibration run and the seven price runs made before it.
- **A failure stops it.** A phase that exits non-zero ends the command: nothing after it
  starts, the closing summary names it, and the experiments after it are reported "not reached"
  — what an unattended run through a broken cluster should do.

### calibrate — the reference trajectory

Tau is MAgPIE's land-use intensity trajectory: a regional productivity parameter comparable
to a total-factor-productivity calibration in an IAM. The calibrate phase runs MAgPIE once with
technological change **solved for** (`cfg$gms$tc` unset, realization `endo_jan22`) against the
business-as-usual second-generation bioenergy demand path
`c60_2ndgen_biodem = "R34M410-SSP2-NPi2025"`, and exports the tau trajectory the model settles
on. The reference tau is therefore exactly as reasonable as the MAgPIE team's BAU
calibration.

It runs under the NPi GHG price scenario (`c56_pollutant_prices` unset, so the MAgPIE
default `R34M410-SSP2-NPi2025` applies) and under land conservation `c22_protect_scenario =
"BH"` — the two sweeps use `"none"`. It also runs with `c44_bii_decrease = 0` where the sweeps
use `1`, and leaves `s30_annual_max_growth`, `s44_cost_bii_missing` and the `s60_*`
switches at MAgPIE defaults. These asymmetries are properties of the golden runs and are
reproduced exactly by the `default` experiment.

One run per experiment, in `output/<identifier>/tau`. A folder is addressed by name and a
re-run may overwrite it, so it can hold a tau solved before one of the settings behind it
changed — the technological-change cost, the yield scenario, the model horizon, the protection
and bioenergy-demand scenarios it calibrates under, or the input tarballs. The phase therefore
writes `messageix_stage1_fingerprint.txt` into its run folder, listing exactly those settings,
and packing refuses to take tau out of a run whose record disagrees with the experiment it was
invoked for (`messageix/R/utils_runs.R`). Within one MAgPIE version and one record, an existing
trajectory is used as it stands.

### Packing: calibrate → price

`messageix/R/pack_price.R` reads `ov_tau` from the calibration `fulldata.gdx`,
writes `f13_tau_scenario.csv`, and packs it into a patch tarball in `patch_input/`. See
§2 for the tau mechanics and §3 for the tarball mechanism.

### price — the bioenergy price sweep, 7 runs

Seven runs impose bioenergy price incentives of **0, 5, 7, 10, 15, 25, 45 $2005/GJ** — the
`design()` default — scaled by 1.23 into MAgPIE's internal $2017 unit and applied to both
`s60_bioenergy_1st_price` and `s60_bioenergy_2nd_price`. The GHG price is set to zero by
selecting `c56_pollutant_prices = "SSPDB-SSP2-Ref-MESSAGE-GLOBIOM"`, a standard scenario in
the base tarball that is zero across all regions and periods. Tau is held at the calibrated
trajectory via `cfg$gms$tc <- "exo"`.

Holding tau fixed isolates the price response: land supplies bioenergy under a known
productivity path. Each run reports second-generation bioenergy production by region — seven
demand trajectories.

Two switches must be moved off their MAgPIE defaults or the sweep is distorted:
`s60_2ndgen_bioenergy_dem_min = 0` (default 1 mio. GJ/yr imposes a demand floor) and
`s60_bioenergy_1st_subsidy = 0` (default 6.5 USD17/GJ acts as a price floor).

### Packing: price → demand

`messageix/R/pack_demand.R` reads the seven price-sweep `fulldata.gdx`, extracts
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

The new columns are **appended to the base tarball's own `f60_bioenergy_dem.cs3`**, not written
into a fresh file. That is not optional. MAgPIE looks up two demand columns by name in every
run whatever scenario was selected — the `c60_2ndgen_biodem_noselect` default
`R34M410-SSP2-NPi2025`, used in regions outside the selected policy set, and
`R32M46-SSP2EU-NPi`, the path early years are harmonised against — so both have to survive into
the patched file or GAMS stops on an unknown set element. Neither name is written down in the
pipeline: both are read out of the bioenergy module's own code every time the inputs are packed,
so a MAgPIE version that renames one of them stops the packing rather than every run.

The same tarball carries `f56_pollutant_prices.cs3` with twelve `G####exp2110` GHG price
trajectory columns over `(t_all, i, pollutants, ghgscen56)` in USD17MER per t. **That file is
supplied by whoever runs the pipeline** (`--f56=PATH`); nothing in the repository generates it
(see `decisions.md`, open items). What the packing step does do is check its **structure**: the
pollutant sub-dimension must come first and must match MAgPIE's set of taxable pollutants
exactly, because MAgPIE builds its list of selectable GHG price scenarios from the *second*
sub-dimension of the file — written the other way round, the pollutant names would become the
scenario list and no run could resolve its `c56_pollutant_prices` column — and the file must
carry one column per GHG price level the experiment sweeps, every model year, and no gaps. The
prices themselves are not checked and cannot be: a wrong trajectory under the right column name
passes every check here and changes all 84 runs, which is why the file comes from the person who
knows what is in it.

### demand — the GHG price sweep, 84 runs

The seven bioenergy demand paths become exogenous inputs
(`c60_2ndgen_biodem = "<experiment>_BE<pad2>"`), crossed with twelve GHG price trajectories
**0, 10, 20, 50, 100, 200, 400, 600, 1000, 2000, 3000, 4000**, exponentially extended to
2110. Tau is solved for again, so land-use intensity responds freely to the combined price
and demand signal. Bioenergy prices are zero here: the phase is demand-driven, not
price-driven.

These 84 runs are the emulator's sampling grid — the `design()` default; a coarser `prices_ghg`
is fewer of them. Each produces `report.mif` (matrix input)
and `fulldata.gdx` (woodfuel input), roughly 1 GB per run.

**The non-CO2 carbon price cap is a config value, not a data edit.**
`cfg$gms$s56_limit_ch4_n2o_price` caps the carbon price applied to CH4 and N2O inside GAMS,
whatever trajectory `c56_pollutant_prices` selects. The narrative sets it to **200 USD17MER/tC**
(roughly 55 USD17/tCO2) against a MAgPIE default of 4920. Nothing inside a patch tarball is
capped, so changing the cap is a one-line change in `experiments.R` with no artefact
regeneration.

---

## 2. Tau mechanics

MAgPIE's exogenous technological-change realization expects `f13_tau_scenario.csv`: a
region- and time-specific file, produced from an existing run, which replaces the placeholder
shipped in the base input tarballs.

Two equivalent ways to write it:

```r
magpie4::tau(gdx, file = "f13_tau_scenario.csv")

write.magpie(readGDX(gdx, "ov_tau", select = list(type = "level")),
             "f13_tau_scenario.csv")
```

`ov_tau(t, h, tautype, type)` at `type = "level"` has exactly the shape MAgPIE declares for
`f13_tau_scenario(t_all, h, tautype)`, so no reshaping is needed. The packing step uses the
second form.

Two properties the exported file must satisfy. Both are checked in R before the tarball is
packed, because the GAMS-side failure arrives much later and says little:

- **Every value strictly positive.** MAgPIE aborts the price-sweep runs on a tau of zero or below
  ("tau value of 0 detected in at least one region!") before fixing `vm_tau.fx(h, tautype)` to
  the file's values.
- **Full coverage** of every model year in `coup2110` for every superregion `h`. A missing year
  is read as zero, which is the same abort one step later.

Tau travels between phases inside a patch tarball rather than as a loose file, because MAgPIE
reads its inputs either from the version-pinned base tarballs or from a patch tarball and there
is no third channel. What this pipeline changes is that the patch tarball is generated rather
than assembled by hand; it is still a patch tarball.

---

## 3. Patch tarballs

**A patch tarball is MAgPIE's project-override mechanism, not a software patch.**
`cfg$input` is a named character vector of tarball filenames:

```r
cfg$input <- c(regional   = "rev4.119_5ff27be8_magpie.tgz",
               cellular   = "rev4.119_5ff27be8_1b5c3817_cellularmagpie_c200_MRI-ESM2-0-ssp245_lpjml-8e6c5eb1.tgz",
               validation = "rev4.119_5ff27be8_validation.tgz",
               additional = "additional_data_rev4.62.tgz",
               patch      = "<generated>.tgz")
```

Mechanics that matter:

- **Order.** Later entries overwrite earlier ones. The `patch` entry is listed **last**.
- **Resolution.** `cfg$repositories` is searched in order. The pipeline puts the PIK public
  repository and `"./patch_input"` ahead of whatever `getOption("magpie_repos")` provides, so a
  generated patch tarball is a plain `.tgz` in `patch_input/` at the model root. That directory
  does not exist in a fresh clone; the patch steps create it.
- **Layout.** MAgPIE unpacks every tarball flat and then sends each file to the module `input/`
  folder whose own `input/files` manifest claims it; files nothing claims stay in `input/`.
  **A patch tarball therefore contains bare filenames at the archive root — no directory
  structure.** A directory prefix hides the file from every manifest and it goes nowhere.

Relevant manifests:

| Manifest | Files the pipeline overrides |
| --- | --- |
| `modules/13_tc/input/files` | `f13_tau_scenario.csv` |
| `modules/56_ghg_policy/input/files` | `f56_pollutant_prices.cs3` |
| `modules/60_bioenergy/input/files` | `f60_bioenergy_dem.cs3` |

### Patch names are content-hashed

Before a run starts, MAgPIE compares the list of tarball names it has been asked for against
the list recorded in `input/info.txt`, and unpacks the inputs again only if the two differ (or
if `cfg$force_download` is set). **The comparison is over tarball filenames, not contents.**
Rebuilding a patch tarball under a name a previous run already used is therefore a silent
no-op: MAgPIE keeps the old data, keeps the old generated set files, and the run proceeds on
stale inputs with nothing in any log to say so.

The pipeline therefore names packed tarballs `<experiment>_<price|demand>_<8hexdigest>.tgz`,
where the digest is taken over the contents. New contents mean a new name, so unpacking again
is correct by construction, and re-running with unchanged inputs correctly skips the download.
The phase runner then checks that this held: once the first run of a phase has started,
`input/info.txt` must name that phase's packed tarball, or the run is reading a previous run's
inputs and the phase stops.

The cost of that naming is that packing changed content leaves the previous tarball beside the
new one — nothing deletes it — and a phase facing two candidates refuses to guess. Two things
keep that out of the way. The pipeline hands each phase the tarball just packed for it, read
from the last line the packing script prints, so a phase run in the same command is never
choosing. And pre-flight stops the command before anything is submitted when packing would run
while a tarball for that experiment and phase is already on disk: remove it, or run the phase
on its own with `--patch=NAME`.

---

## 4. Set auto-regeneration, and why the tree goes dirty

`download_and_update()` runs two generators after distributing files.

**The region sets** — `h`, `i`, `supreg(h,i)`, `iso`, `j`, `cell(i,j)`, `i_to_iso(i,iso)` —
are written into `core/sets.gms` from the region mapping carried inside the tarball itself
(`input/spatial_header.rda`). The file carries a "DO NOT MODIFY, WILL BE LOST" banner, and the
generator stops outright if the mapping's region list disagrees with the gridded data. **The
R12 region set is delivered by the input tarball. It is never delivered by a committed file.**

**The scenario sets** are read out of the *column names* of the distributed input files and
written into GAMS set files:

| Source file | Set | Written to |
| --- | --- | --- |
| `f56_pollutant_prices.cs3` | `ghgscen56` | `modules/56_ghg_policy/price_aug22/sets.gms` |
| `f56_emis_policy.csv` | `scen56` | same |
| `f60_bioenergy_dem.cs3` | `scen2nd60` | `modules/60_bioenergy/{1stgen_priced_dec18,1st2ndgen_priced_feb24}/sets.gms` |

**This is the whole trick.** Appending a column named `default_BE10` to
`f60_bioenergy_dem.cs3`, or `G0400exp2110` to `f56_pollutant_prices.cs3`, makes it a valid set
member automatically, so `cfg$gms$c60_2ndgen_biodem <- "default_BE10"` resolves. Never
hand-edit these `sets.gms` files — the next download overwrites them.

Note the corollary: this refresh happens only when inputs are actually unpacked. Skip the
download and the sets are not refreshed either — the second reason patch tarball names carry a
content digest.

Separately, every run rewrites the `$setglobal` and scalar values in `main.gms` and in **every**
`modules/*/*/input.gms` from `cfg$gms`, and rewrites the VERSION INFO block in `main.gms`,
including the `Regionscode:` line.

**Consequence: a dirty working tree after a run is normal MAgPIE behaviour.** `core/sets.gms`,
`main.gms`, the module `input.gms` and `sets.gms` files are build products of `cfg$input` and
`cfg$gms`. Committing them buys nothing, costs a merge conflict on every upstream version bump,
and is overwritten by the next run. **Never `git add` them.** Everything the pipeline needs to
say about model configuration is said in `messageix/experiments.R`; everything it
needs to say about geometry is said by `cfg$input`.

One operational exception: if the region set changes on a tree that has already run, set
`cfg$force_download <- TRUE`. A fresh clone has no `input/info.txt` and downloads regardless.

---

## 5. Matrix generation and woodfuel

**Matrix.** `messageix/R/createMatrix_MM.R` reads the 84 `report.mif`, applies
`MM_linkage_mapping.csv` through `iamc::write.reportProject()` to rename, aggregate and
unit-convert MAgPIE variables into the MESSAGEix set, tags each run with the prices it was run at,
concatenates, and writes one CSV.

Output schema: `Region, Variable, Unit, SSPscen, GHGscen, BIOscen, SDGscen` followed by year
columns ascending. `Model` and `Scenario` are dropped. MAgPIE region codes are renamed to
MESSAGEix names (`AFR → SubSaharanAfrica`, and so on) from the table the experiment's region set
carries — `messageix/data/region_names_R12.csv` for the pinned R12 set.
A region a run reports that the table does not name stops the build. The woodfuel step reads
the same table and applies the same rule, which is what lets the two tables be joined; the
names live in one file and in no code (§8, "New region set").

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

The last row couples two files. `createMatrix_MM.R` reads the `factor` of every row whose target
`Variable` starts with `Price|` and stops the build unless it equals
`1 / currency_2005_to_2017` to within `1e-6`. Moving the deflator without moving the
mapping is a stop, not a silently mis-converted price row.

The build **fails** rather than writing a partial matrix when any of the 84 runs is missing or
unsolved. "Solved" means the GAMS model status is checked, not that `fulldata.gdx` exists — an
infeasible run writes one too. A variable named in the mapping that no run produced is reported
in full before anything is written, never silently left as NA; `--allow-unmapped` builds anyway,
still listing them.

**Woodfuel.** Forest-harvest woodfuel is absent from `report.mif`, so
`add_woodfuel_to_matrix.R` reads `pm_demand_forestry[, , "woodfuel"]` (Mt DM) from each run's
`fulldata.gdx`, converts at **18 GJ/tDM** — a MAgPIE-team value that deliberately overrides
the `fm_attributes` entry in the gdx — truncates at 2110, builds a `World` row as the plain
sum over the regions (a global code the region table already maps to `World` is left out of
that sum and out of the result, so the global total cannot be counted twice), and adds the
result to the `Primary Energy|Biomass` rows, matched on `BIOscen | GHGscen | Region | year`.
It writes nothing unless every one of those rows received woodfuel in at least one year.

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
`Landuse intensity indicator Tau` — must not be added up across regions. `createMatrix_MM.R`
tests those four automatically and warns when a World value equals the sum of the regional ones;
if it does, change those rows to `spatial = reg`. The five `Food Demand` rows carry
`weight = Population (million people)` and are weight-averaged. Also confirm by hand that
`Emissions|CO2|AFOLU` equals land-use change plus crop-residue burning — the matrix scripts
cannot check that one.

---

## 6. Defaults that carry science weight

Each is a deliberate choice. `N` = a `narrative()` or `design()` setting in
`messageix/experiments.R`; `I` = an infrastructure setting in code, overridable per machine or
per command; `D` = documented default, settled where it is used; `F` = fixed by the phase. Where
a value was settled in earlier MAgPIE work rather than derived here, `decisions.md` records the
lineage.

| Setting | Value | Why | Owner |
| --- | --- | --- | --- |
| `c14_yields_scenario` | `nocc` — yields exclude climate change | Defensible at 1–1.5 °C, where yield impacts are small. Scenarios approaching 2 °C should use `cc`, where they are material. | N |
| `c13_tccost` | `high` | Makes intensifying existing cropland expensive, so the model leans more on expansion. Settled in earlier MAgPIE experiments. MAgPIE default `medium` | N |
| `s30_annual_max_growth` | `0.02` — cropland growth capped at 2 %/yr per region | A deliberate brake on how fast the sweep may reallocate land. Settled in earlier MAgPIE experiments. MAgPIE default `Inf`, i.e. no brake | N |
| `s44_cost_bii_missing` | `1e7` USD17MER — 10x the MAgPIE default | Keeps gaps in the BII data from being the cheapest place to put land-use pressure. Settled in earlier MAgPIE experiments | N |
| `s56_limit_ch4_n2o_price` | `200` USD17MER/tC | Empirical abatement-cost curves show very little non-CO2 abatement is available above roughly this price, and the cap keeps food prices plausible under strong mitigation. MAgPIE default `4920` | N |
| `s44_bii_target` | `0` | Narrative setting; alternatives tested so far 0.7 / 0.74 / 0.78 | N |
| `c44_bii_decrease` | `1` in the two sweeps, `0` in the calibrate phase | Follows from the BII target: loss is permitted exactly where no target is imposed | F |
| `c22_protect_scenario` | `BH` in the calibrate phase, `none` in the two sweeps | Property of the golden runs; see `decisions.md`, open items | N |
| `s15_rumdairy_scp_substitution` | `0` | Narrative setting; alternatives tested so far 25 / 50 / 75 % | N |
| `prices_bioenergy` | `0, 5, 7, 10, 15, 25, 45` $2005/GJ | Levels chosen where land-use models change behaviour, with enough coverage around the turning points that interpolating between them lands on a sensible surface. Reconfirmed at the version bump | N |
| `prices_ghg` | `0 … 4000`, exponentially extended to 2110 | as above | N |
| Currency conversion | `1.23` for $2005 → $2017 | A MAgPIE-team factor. **Standing attention item** — MAgPIE's base year moves when MAgPIE updates, so revisit at every version bump. One value, two reciprocal uses (`x1.23` on prices into MAgPIE, `x0.813` on prices out via the mapping), and both must move together | I |
| `c_timesteps` | `coup2110` | The MESSAGE horizon; MAgPIE default `coup2100`. Packing checks its output against the model years of this token | I |
| `s60_2ndgen_bioenergy_dem_min` | `0` | MAgPIE's default of 1 mio. GJ/yr would put a floor under the demand sweep. Applied in the two sweeps only | I |
| `s60_bioenergy_1st_subsidy` | `0` | MAgPIE's default of 6.5 USD17/GJ acts as a price floor under the bioenergy price sweep. Applied in the two sweeps only | I |
| Woodfuel energy content | `18` GJ/tDM | A MAgPIE-team value, used in place of the energy content carried in the solver output | D |
| Gap fill | adjacent-year mean; post-2100 held at 2100 | Past 2100 there is no later reported year to average against, so the level is held flat | D |
| Historical 2nd-gen bioenergy | zero for 1995–2015 | No such production existed, and MAgPIE harmonises its early years against a reference path regardless. Coded as a replaceable vector | D |
| GWP100 | CH4 27, N2O 273 | AR6 | D |
| `tc` realization | `exo` in the price sweep, solved for elsewhere | This is what defines the phase | F |

---

## 7. Naming contract

Defined once, in `messageix/R/utils_paths.R`. One experiment writes into one folder, so the
names below it carry only the position in the sweep. A price level is written one way and one
way only — zero-padded — wherever it appears.

| Token | Form | Example |
| --- | --- | --- |
| BE token | `BE` + zero-pad to 2 | `BE00 BE05 BE07 BE10 BE15 BE25 BE45` |
| GHG token | `G` + zero-pad to 4 | `G0000 … G4000` |
| Identifier | regionscode, plus the experiment's name unless it is `default` | `MESSAGEix_5ff27be8` |
| Results folder | `output/<identifier>/<title>` | `output/MESSAGEix_5ff27be8/BE45_G4000` |
| Calibrate title | `tau` | `tau` |
| Price title | `<BE token>` | `BE05` |
| Demand title | `<BE token>_<GHG token>` | `BE45_G4000` |
| Bioenergy demand column | `<experiment>_<BE token>` | `default_BE05`, `biodiversity_BE05` |
| GHG price column | `<GHG token>` + the extension suffix | `G0400exp2110` |
| Matrix tags | `BIO` + pad2, `GHG` + pad3 | `BIO45`, `GHG4000` |
| Packed tarball | `<experiment>_<price\|demand>_<8hexhash>.tgz` | |
| Calibration record | `<calibration run folder>/messageix_stage1_fingerprint.txt` | |

The bioenergy demand column name is a handshake between two steps of this pipeline and nothing
else: packing writes those columns into `f60_bioenergy_dem.cs3` and the demand sweep asks for
one of them through `c60_2ndgen_biodem`. They must match character for character or GAMS stops on
an unknown set element, so both are built by the same function from the same integer. The GHG
price column is different in kind — those trajectories are supplied from outside the pipeline
under the names their author gave them, so `G0400exp2110` is a contract this repository keeps
rather than a name it chooses.

### An experiment's identity is derived, not chosen

Read the table again from the run's point of view: a run folder is
`output/<identifier>/<title>`, and the title carries only the position in the sweep. Nothing
below the identifier records the biodiversity target, the microbial-protein share, the
protection scenario, the yield scenario or the region set.

The identifier is therefore what separates one experiment from another, and it does so by
construction:

```
identifier       = MESSAGEix_<regionscode>                for the experiment named `default`
                   MESSAGEix_<regionscode>_<experiment>   for every other experiment
matrix_basename  = magpie_input_<ssp>_ref                 for the experiment named `default`
                   magpie_input_<ssp>_<experiment>        for every other experiment
regionscode        the middle token of the regional tarball name, rev<revision>_<code>_magpie.tgz
```

Two experiments cannot collide, because two entries of one list cannot share a name — `run.R`
asserts it once before anything starts rather than assuming it. The experiment named `default`
carries no name token, which is what keeps the pinned matrix at
`magpie_input_SSP2_ref_woodfuel.csv`. An experiment's name becomes a folder name and a GAMS set
element, so it takes letters, digits, dash and underscore only.

Nothing may set these values. An experiment that could choose its own names could choose another
experiment's, and since a re-run may overwrite a folder of the same name, the second run would
replace the first without saying so.

---

## 8. Region sets

Which regions MAgPIE solves for is the one structural lever of the world. An experiment names a
region set (`region_set = "R12"`) and never the files: the set is what pairs the four input
tarballs with the region-name table that has to agree with them, listed together in
`region_sets()` in `messageix/R/pipeline_infrastructure.R`.

Everything else about the configuration surface — which settings exist, who owns each of them,
and how one is overridden per machine or per command — is documented in the file that declares
it; [`../README.md`](../README.md) says which file that is for each kind of setting.

### New region set

The emulator matrix is written in MESSAGEix region names, and MAgPIE reports MAgPIE region
codes. The translation is a two-column file, not code:
`messageix/data/region_names_R12.csv`, which the R12 region set carries and which is
resolved relative to `messageix/data/`. Both halves of the reduce phase read it — the matrix
builder to rename the mapped results, the woodfuel half to rename what it extracts. One file,
so the two tables cannot disagree.

Both steps require the file to name **every** region their runs report, and stop naming both
sides when it does not. A total mismatch is the harmless case; the dangerous one is partial,
because region sets overlap — R10 and R12 share eleven of their twelve codes — so runs at the
wrong resolution would be renamed where the codes agree and left in MAgPIE's codes where they
do not, giving a matrix that looks complete and carries two vocabularies. The woodfuel step
adds one more stop of the same kind: every `Primary Energy|Biomass` row of the matrix must
receive woodfuel in at least one year, so a scenario tag or region that finds no match is an
error rather than a quietly thinner file.

Moving to another region set, R10 for instance, is one lookup entry and one table:

1. Obtain the input tarballs for that region set and put them where `cfg$repositories` finds
   them (`inputs.md`).
2. Write `messageix/data/region_names_R10.csv`: one row per MAgPIE region code, plus the
   `GLO` and `World` rows that keep the global total named consistently.
3. Add an `R10` entry to `region_sets()` in `messageix/R/pipeline_infrastructure.R`, pairing
   the four tarball names with that table.
4. Set `region_set = "R10"` in an experiment's `narrative()` — the identifier follows, because
   it carries the region code out of the new regional tarball, so R10 runs cannot land in the
   R12 folders.
5. Calibrate again for that experiment and run the pipeline.

The lookup entry is the only code that changes, and it is a list of file names. What does not
come free is cell-level aggregation to an arbitrary region set at run time — that needs a
tarball per region set today (`inputs.md`, "Future: the version × region matrix").

---

## 9. Execution environment

Emulator generation runs on the **PIK cluster**. This is a storage constraint, not a
preference: a single MAgPIE run produces over 1 GB and full emulator generation needs roughly
**90 GB**, against a ~100 GB quota on UniCC. Three reporting levels per run inflate the output
further; trimming that is a conversation with the MAgPIE team, not a pipeline task. Access is
by requesting a PIK cluster account. Running the whole pipeline on UniCC is a long-term
aspiration.

Nothing about the environment is hard-coded. Module lists, QOS, repositories and mail settings
are infrastructure settings: a code default in `messageix/R/pipeline_infrastructure.R`, which
documents each of them, overridable per machine through `MAGPIE_MM_QOS`, `MAGPIE_MM_MODULES`
and `MAGPIE_MM_MAIL_USER`, and per command through `--set`. `messageix/R/utils_env.R` is where
they are asked for. The job script the pipeline submits holds no copy of them: it is generated
from the resolved experiment, so the queue, the module lines and the mail address come from the
same place as everything else.

The environment the pipeline is tested against:

```
module purge
module load defaults/piam/1.27
module load R/4.3.2
module load gcc/15.2.0      # last: the compiled piam packages (gdx2 -> Rcpp)
                            # need CXXABI_1.3.15 from this libstdc++
```

**R packages.** Beyond what MAgPIE itself needs (`gms`, `lucode2`, `magclass`, `gdx2`,
`magpie4`) and `iamc` for the variable mapping, the pipeline's own code uses the tidyverse
packages it does its table work with: `readr`, `dplyr`, `tidyr`, `tibble`, `purrr` and
`stringr`. They are in the PIK `defaults/piam` module above. They are used namespace-qualified
(`dplyr::filter`) and never attached, so nothing this pipeline loads masks a base function in a
session that sources it.

Submission: `start_run()` detects SLURM and runs `sbatch submit_<cfg$qos>.sh` from the run
folder, using MAgPIE's own `scripts/run_submit/` scripts. `qos = "priority"` is a PIK QOS
name and is an infrastructure default.

---

## 10. Validation

**The golden runs.** With the pinned R12 tarballs and the `default` experiment, the emitted
matrix matches `magpie_input_SSP2_ref_woodfuel.csv` region by region and variable by variable
within solver tolerance. The pre-woodfuel `magpie_input_SSP2_ref.csv` is the intermediate
check. Both names are derived from the experiment: the entry named `default` gives
`magpie_input_SSP2_ref`, the reduce phase writes that under `--matrix-dir`, and the woodfuel
half appends `_woodfuel`.

**Compare on keys, not on line order.** The comparison is a join on
`Region × Variable × SSPscen × GHGscen × BIOscen × SDGscen × year`, and it passes when every key
in one file is in the other and every value agrees within tolerance. Row order is an
implementation detail of whichever script emitted the file — deterministic, so a diff of two
files this pipeline wrote is readable, but never the thing being checked. A `diff` that reports
every line as changed because the sort order moved says nothing about the science. In R:

```r
key <- c("Region", "Variable", "Unit", "SSPscen", "GHGscen", "BIOscen", "SDGscen")
reference <- readr::read_csv("magpie_input_SSP2_ref_woodfuel.csv")
built     <- readr::read_csv("output/emulator/magpie_input_SSP2_ref_woodfuel.csv")
merged <- dplyr::inner_join(reference, built, by = key, suffix = c(".ref", ".new"))
stopifnot(nrow(merged) == nrow(reference), nrow(merged) == nrow(built))
# then compare the year columns pairwise within tolerance
```

**Checking against runs made before this pipeline.** Di's existing demand-sweep runs on the PIK
cluster are the cheap validation: the reduce phase alone, over runs that already exist, rather
than 84 fresh jobs. Those folders carry the older names (`SSP2_BD00/SSP2_BD00_BE45_G4000demand`),
so both reduce scripts take `--layout=legacy` (`Rscript messageix/run.R matrix NAME
--layout=legacy` passes it through), which builds the grid with those names instead of this
pipeline's. It exists for that comparison and nothing else — no step produces runs in that
layout, and the matrix content is identical either way, because a run folder's name reaches no
column of the matrix:

```bash
Rscript messageix/R/createMatrix_MM.R --layout=legacy \
  --run-dir <Di's demand-sweep directory> --out /tmp/check.csv
Rscript messageix/R/add_woodfuel_to_matrix.R --layout=legacy \
  --run-dir <Di's demand-sweep directory> --matrix /tmp/check.csv
```

**Structural checks on every build:**

- All 84 demand runs present and solved before the reduce phase starts — hard failure, not a
  warning. "Solved" is one set of GAMS model statuses, `{1, 2, 7}` (proven optimum, local
  optimum, feasible without a proof), defined once in `messageix/R/utils_runs.R` and applied by
  both packing scripts and both halves of the reduce phase.
- `missing_log` empty or explained.
- Full year coverage, no NA after gap fill: tau and the f56 columns are NA-checked, and every
  f60 bioenergy column is NA-checked after gap filling and historical zeroing.
- `input/info.txt` names the tarball just packed — asserted by the phase runner after
  `start_run()` returns for the first run of a phase.
- The calibration record agrees with the experiment being packed for — hard failure, because a
  mismatch means the trajectory was solved for other settings.
- The mapping's price factor is the reciprocal of the `currency_2005_to_2017` setting (§5).
- Monotonicity spot check: packing the demand sweep's inputs **warns**, with the numbers, when
  global second-generation bioenergy supply in 2100 falls as the bioenergy price rises. A warning
  rather than a stop — a small inversion can be a solver artefact where the response surface is
  near-flat.
- World-versus-region check on the intensive variables (§5).

**Upstream contract.** No path outside `messageix/` differs from upstream `magpiemodel/magpie`.
Merging a newer PIK tag is clean by construction. Adopting a new release means: merge the tag,
obtain the matching input tarball, calibrate again, rerun validation. The pipeline code stays
stable across versions; only data artefacts change.
