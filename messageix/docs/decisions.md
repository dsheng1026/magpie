# Decision record

Why `messageix/` is shaped the way it is. Science and pipeline authorship: Di Sheng (IIASA).
Resolutions Q1–Q8 come from the science review of the pipeline design; Q9 from a read-only
investigation of the fork against upstream `v4.11.0`.

---

## Science decisions

### Q1 — Woodfuel double counting

**Resolved: no double counting. Woodfuel is included; the 18 GJ/tDM conversion stands.**

The woodfuel post-processor adds forest-harvest woodfuel to `Primary Energy|Biomass`, which
the mapping also feeds from `Demand|Bioenergy|++|Traditional Burning`. Checked and confirmed
to be distinct quantities. The 18 GJ/tDM energy content is a MAgPIE-team value and
deliberately overrides the `fm_attributes` entry in the gdx.

What remains, and is documented rather than fixed: MAgPIE will not calibrate its bioenergy
supply outputs to IEA statistics while the scope of bioenergy modelled in MAgPIE is still
expanding, so a structural gap persists between MAgPIE's land-use bioenergy supply and
MESSAGE's demand side. Downstream, the land emulator bridges it with a slack variable in
bioenergy that phases to zero across calibration and future model years. GLOBIOM's supply
sits closer to MESSAGE demand. This is the current operating mode, flagged and documented —
not a methodological error.

The open question in the `add_woodfuel_to_matrix.R` header is retired; the file states the
resolution as fact.

### Q2 — Non-CO2 carbon price cap

**Resolved: a model decision, implemented as an explicit config parameter.**

The cap is 200 USD17MER/tC (roughly 55 USD17/tCO2). Rationale: empirical MAC curves show
non-CO2 abatement is comparatively cheap up to a point and becomes trivial above ~$200/tC.
For the Earth Commission scenarios, which address food security, an uncapped non-CO2 carbon
price drives food prices implausibly high under strong mitigation. The same logic was applied
independently in the sustainable-CDR paper. Earth Commission keeps the $200 cap, confirmed
through Isabel and Florian.

Implementation follows the MAgPIE team's own approach: `cfg$gms$s56_limit_ch4_n2o_price`,
a native switch (default 4920 USD17MER/tC) that GAMS applies to whatever price trajectory
`c56_pollutant_prices` selects. The previous method — capping `f56_pollutant_prices.cs3`
inside a hand-built `SSP2_demand_cap.tgz` — becomes unnecessary, and the separate `_cap`
variant of the step-3 tarball disappears. Changing the cap now requires no artefact
regeneration. The sustainable-CDR paper branch retains the patch-file method.

### Q3 — The defaults table

**Resolved: `c14_yields_scenario`, `c13_tccost`, `s30_annual_max_growth` and
`s44_cost_bii_missing` become user-configurable.**

All four were set by Florian from prior experiments and had been treated as fixed for the
MESSAGE–MAgPIE linkage. They do not need to be locked for every project. `c14_yields_scenario`
in particular switches to the with-climate-change setting for Earth Commission: those
scenarios approach 2 °C, where climate yield impacts are material. At 1–1.5 °C the `nocc`
setting is defensible. The sustainable-CDR paper keeps the existing values.

### Q4 — Price grids

**Resolved: documented and configurable, current values as the tested default.**

The bioenergy and GHG price categories behave differently from other categories in the
emulators, so the levels were chosen by observing where the land-use models shift behaviour
under different price signals — a wide range with enough coverage at the inflection points
that weighted-average interpolation lands on a reasonable surface. Jan Dittrich saw no need to
update them on the MAgPIE version bump. Oliver was interested in updating the levels for the
GLOBIOM emulator but was under-resourced. Users with a strong motivation and the resources to
retrain the emulator should feel free to change the boundary levels and ranges. Once the tool
supports large-ensemble runs, whether the levels need revision becomes an empirical question
rather than a judgement call.

### Q5 — Tau sensitivity

**Parked post-MVP.** Substantively the same question as Q4: rerun step 2 under scaled tau
trajectories and compare bioenergy supply responses. Worth doing, not worth blocking the MVP.

---

## Repository and infrastructure decisions

### Q6 — Input tarball redistribution

**Open, with a path.** Private within IIASA now. Escalation in order: Di talks to Keywan
first, then the MAgPIE team (a meeting is scheduled to learn how to update the tarball); team
leaders settle public hosting later. Interim storage is Di's shared drive, with an
IIASA-wide model-data share under consideration. If the MAgPIE repository cannot host the
tarball, the fallback is a public archive release covering MESSAGE R12, R10, India and China
variants, with the repository pinned to that release. `messageix/inputs/` carries a signpost,
not data.

### Q7 — Undocumented tarball files and the missing steps

**Resolved: `SSP2_tau.tgz` is dropped; two patch tarballs remain, both generated by code.**

`SSP2_tau.tgz` exists only because the base tarball Di was handed is stale relative to the
MAgPIE version she runs — it supplies files the newer version expects. With a correctly
updated tarball it is redundant. It stays on the sustainable-CDR paper branch for
reproducibility and is not carried forward.

The two remaining patches — price-driven and demand-driven — are generated fresh on a first
run for maximum reproducibility and reused on re-runs. Two generation steps that the original
workflow diagram omitted are now explicit code: extract tau after step 1, and extract updated
second-generation bioenergy demand plus carbon price trajectories after step 2.

**Tau stays a patch.** The question of promoting it to an ordinary workflow step was raised
and answered by MAgPIE's design: the model reads inputs either from the version-pinned base
tarball or from an additional patch tarball that selectively overrides files. There is no
third channel. What changes is that the patch becomes a build artefact instead of a
hand-assembled file.

### Q8 — Execution environment

**Resolved: PIK cluster for emulator generation.** A single MAgPIE run produces over 1 GB and
full emulator generation needs roughly 90 GB. The PIK cluster has no storage cap and is
already set up with the job submission scripts and environment; UniCC's ~100 GB quota does not
fit. Three reporting levels per run inflate output further — trimming that is a possible
future conversation with the MAgPIE team, not an MVP task. Access is by requesting a PIK
cluster account. Running the whole pipeline on UniCC remains a long-term aspiration, so the
repository makes paths and the R environment configurable rather than hard-coding them.

### Q9 — Upstream-file exceptions

**Resolved with the strongest possible result: zero commits outside `messageix/`.**

The design assumed the fork would carry documented deltas against upstream. It carries none.
Every file the working branch modified outside `messageix/` is a machine-regenerated build
artefact, a value already expressible through `cfg$gms`, dead commented-out code, or a stray
binary.

Evidence:

- **`core/sets.gms` is machine-generated.** The file carries a "DO NOT MODIFY, WILL BE LOST"
  banner, and the entire regional diff sits inside the generated block.
  `scripts/start_functions.R` regenerates it on every input download via `.update_sets_core()`
  → `gms::writeSets()`, reading the region map out of the tarball's own
  `input/spatial_header.rda`. `.update_sets_core()` even hard-fails if that header disagrees
  with the cellular data, so a committed R12 `sets.gms` sitting on an h12 tarball cannot
  silently survive. `/input/` is gitignored — the region mapping is never tracked.
- **The tarball name closes the loop.** `rev4.119_5ff27be8_*` carries regionscode `5ff27be8`,
  and `5ff27be8` is exactly what `.update_info()` wrote into the `Regionscode:` line of
  `main.gms` in the golden runs. Tarball name → header object → generated file.
- **PIK does it this way too.** `scripts/start/projects/project_sim4nexus.R` composes tarball
  names from a region-mapping → regionscode lookup. Upstream's answer to "run MAgPIE on a
  non-H12 region set" is *change `cfg$input`*, never *edit `core/sets.gms`*.
- **`main.gms` and every module `input.gms` are rewritten on every run.** `apply_cfg()` runs
  `lucode2::manipulateConfig()` over `main.gms` and every `modules/*/*/input.gms` from
  `cfg$gms`. So `c_timesteps`, `c13_tccost`, `c14_yields_scenario`, `s30_annual_max_growth`,
  `s44_cost_bii_missing` and `c44_bii_decrease` in the diff are run residue — the state a
  working tree was left in, then committed.
- **The remainder is junk.** Commented-out experiments in
  `modules/44_biodiversity/bii_target/{equations,preloop}.gms`; a comment-only change in
  `config/default.cfg` describing an excluded module; a stray `.RData` session image.

The one genuine content change — `gms$food` from `anthropometrics_jan18` to
`anthro_iso_jun22` in `config/projects/scenario_config_genie.csv` — is a fix for an upstream
bug: at v4.11.0 `modules/15_food/` contains only `anthro_iso_jun22`, so the upstream project
CSV cannot resolve the food module. Because the preset moves into `messageix/presets/`, the
fix travels inside the overlay and the upstream CSV stays byte-identical. Worth a one-line
issue to PIK.

**Operational consequence.** MAgPIE runs mutate tracked files in place — `core/sets.gms`,
`main.gms`, module `input.gms` and `sets.gms`. **A dirty working tree after a run is normal.**
These files are regenerated on every run: never `git add` them. Nothing in `messageix/` touches
git, so this is a rule for the person at the keyboard, not a guard the tooling enforces.

**Test consequence.** The upstream contract sharpens from "only documented exceptions
conflict" to *no path outside `messageix/` differs from upstream*.

### Repository strategy — a clean branch in Di's fork

Three options were weighed: fork the existing working branch, PR into it, or start clean.
Options preserving the existing history keep attribution intact but carry trial-and-error
work onto what may become an IIASA repository. The decision was Di's, and it was for the
clean branch, on three grounds: the working branch is only about three commits ahead of the
published tag; part of those commits are workarounds that a correct input tarball makes
unnecessary; and one adds a biodiversity module (Sri Ram's `bii_spatially_resolved`, untested)
that can be left out.

Concretely:

- **Host:** `dsheng1026/magpie` itself. No new fork. A transfer to an IIASA organisation
  later, if ever, happens without content changes.
- **Base:** branch `iiasa-4.11.0` created at tag `v4.11.0` — the exact commit the working
  branch departs from. Clean by construction, not by cleanup.
- **Content:** the MESSAGE linkage work is re-applied deliberately into the top-level
  `messageix/` overlay. The `_test` / `_H12` / `_5_SSPs` script copies and the workaround
  commits never enter the branch.
- **Emulator:** `dsheng1026/MAgPIE_emulator` is merged into `messageix/emulator/` via
  `git subtree add`, preserving commit history and authorship inside the consolidated branch.

**Attribution.** The hosting decision dissolves most of the problem: the branch lives in Di's
own fork and the subtree merge carries her emulator history. What remains is that overlay
commits are pushed by Setu Pelz, so `README.md` and `NOTICE` state plainly that Di Sheng is
the pipeline's author and scientific lead and that the repository work is packaging. This is a
requirement, not a courtesy. MAgPIE is AGPL-3.0-or-later with the MAgPIE License Exception;
PIK's `LICENSE` and `CITATION.cff` stay untouched. The woodfuel extraction builds on code by
Kristine Karstens (PIK) and keeps that credit in the file header.

**Excluded from the port:** the `bii_spatially_resolved` module and its start script (untested;
reintroduce later as its own deltas if wanted); workaround commits made unnecessary by a
correct input tarball; `.RData`; the `_test` / `_H12` / `_5_SSPs` start-script variants, whose
behaviour is reproduced by preset columns rather than file copies.

### Deliberate deviations from the specification

Two spec sentences the build supersedes on purpose, recorded so that a later reader diffing the
spec against the repository does not log them as gaps.

- **`c44_bii_decrease` is stage-owned, not a preset row.** The spec's Q9 has the preset CSV
  adding `c44_bii_decrease;0`. The build makes it stage logic instead (`R/utils_config.R`,
  `stage_controlled_switches()`): its value differs by stage — `0` in step 1, `1` in steps 2–3
  when no BII target is imposed — so a single preset row could only be ignored at two stages out
  of three or break golden-master invariance. A preset that sets it is rejected with a message
  naming the `pipeline$` key to use instead.
- **No `gms$food` row.** The spec has the `anthropometrics_jan18` → `anthro_iso_jun22` fix
  travelling inside `messageix/presets/`. There is no bug to carry: the fix existed in
  `config/projects/scenario_config_genie.csv`, and that CSV is never loaded by this pipeline
  (see "The abandoned preset" above). The overlay's preset does not set the food module at all,
  so MAgPIE's own default resolves.

### The configuration surface — three tiers (2026-08-19)

The single preset CSV was one file holding everything: MAgPIE switches, tarball names, cluster
queue, polling intervals, output folder names, and a forty-line comment wall explaining them.
It was honest about what the pipeline does and hostile to a researcher who only wants to change
a biodiversity target. The surface is now split by who owns each setting. **Narrative** —
thirteen rows in `presets/narratives.csv`, the settings an experiment varies, in a file Excel
opens cleanly. **Infrastructure** — everything operational, plus the constants that are
properties of the linkage rather than of a narrative, as code defaults in
`R/pipeline_infrastructure.R` with an `MAGPIE_MM_*` environment variable and a `--set
key=value` on top. **Derived** — the region code, the output folder, the matrix name and the
input tarballs, worked out from the region set and the column name. The identifier was the
sharpest case: it used to be a row a new column had to remember to change, enforced by a
warning that a hurried person would scroll past, and forgetting it meant one narrative silently
overwriting another's runs. Deriving it as `MESSAGEix_<regionscode>[_<column>]` makes the
collision impossible by construction, so the warning and the ensemble driver's collision
machinery both collapse to one assertion. `default` derives to the same names it always had, so
the pinned runs and `magpie_input_SSP2_ref_woodfuel.csv` are untouched. Every setting is
documented once, in `docs/parameters.md`, instead of in a comment wall nobody reads inside the
file they are editing.

---

### Run names are ours (2026-08-19)

Folder and run names were ported from the original scripts and carried their habits: a
`SSP2_BD00` subfolder level repeating what the identifier already says, a `BD00` token in every
run name, trailing words (`price`, `demand`) naming the stage the folder is already under, and
two spellings of the same bioenergy price level — `BE05` in folder names, `_BE5` unpadded in the
scenario column `c60_2ndgen_biodem` asks for. The two spellings were the sharpest of these: they
had to be kept in step by hand, and a mismatch fails deep inside GAMS on an unknown set element.

Names are now derived from one scheme: `output/<identifier>/tau`, `output/<identifier>/BE05`,
`output/<identifier>/BE05_G0400`. **Run labels for the bioenergy demand scenarios are unified to
the padded form** (`<narrative>_BE05`), a deliberate label-only deviation from the original
runs — the data behind them is identical, the GAMS solution is label-independent, and the
emulator matrix is unaffected, because no run or column label reaches any column of it. The GHG
price columns are untouched (`G0400exp2110`): those trajectories are supplied from outside this
repository under the names their author gave them, so their spelling is a contract, not a
choice. Golden-master validation compares matrix content on
`Region × Variable × scenario tags × year`, never on folder spellings or row order. For checking
against stage-3 runs made before this pipeline, the two matrix scripts take `--layout=legacy`,
which reads the older folder names without anything being renamed; it produces nothing.

---

### Version pin

The repository pins **v4.11.0**. The golden reference matrix is a v4.11.0 artefact, so this is
the version at which the golden-master test means anything. Upstream and Di's other working
branch are at v4.14.0. Moving to 4.14.0 is the intended first version bump, which doubles as
the first exercise of the upstream-merge path.

---

## Divergences fixed rather than ported

The pipeline as it stood carried several defects. The port fixes them rather than reproducing
them.

**BII target 0 vs 0.78.** The step-2 and step-3 start scripts ran `blV <- c(0)` — narrative
`SSP2_BD00` — while the step-2.5 extractor was configured with `blV <- c(0.78)`, an `_ALL`
output directory and an `_ALL` patch destination, i.e. the `SSP2_BD78` narrative whose step-2
runs the committed scripts do not produce. Running the committed scripts in sequence fails at
the point the extractor changes into a directory that does not exist. **Fix:** one preset
drives the BII target, the MP substitution, the folder prefix and the patch destination across
all three stages and both extractors. For the `default` preset that is `bl = 0`, `mp = 0`,
`preflag = SSP2_BD00`, golden file `magpie_input_SSP2_ref_woodfuel.csv`.

**The `c56_pollutant_prices_nonselect` typo.** The step-3 loop set
`cfg$gms$c56_pollutant_prices_nonselect` — no such switch exists. The real one,
`c56_pollutant_prices_noselect`, was set once before the loop to `G0000exp2110` and never
updated, so all 84 runs used the zero-price scenario for the non-selected-countries share.
Harmless in this configuration only: `policy_countries56` covers all ISO countries, so
`p56_region_price_shr = 1` and the `noselect` term is multiplied by zero. It becomes a live
bug the moment anyone restricts `policy_countries56`. The bogus name also propagates into
`check_config()`. **Fix:** the misspelled line is deleted and the correctly named switch is
set in lockstep with `c56_pollutant_prices` inside the loop.

**Partial-matrix tolerance.** Both matrix scripts warned on a missing run and wrote output
anyway, and treated a non-empty `missing_log` as a message. **Fix:** hard failure before
matrix generation if any of the 84 runs is missing or unsolved, with solvedness taken from a
`modelstat` check rather than file existence, and `missing_log` surfaced as a build result.

**Two argument conventions.** `createMatrix_MM.R` prepended a hardcoded output directory to
its second argument while `add_woodfuel_to_matrix.R` used the same argument raw — so the two
wrapper scripts had to pass different things, and the usage string of the first was wrong for
its own code. **Fix:** one convention, an absolute output path, in both scripts and both usage
strings.

**Module environment.** `emulator.sh` omitted `module load R/4.3.2`, which its sibling loads.
**Fix:** one configurable environment block for both, with `gcc` loaded last so the compiled
piam packages resolve `CXXABI_1.3.15`. The list itself lives in the preset and reaches the shell
wrapper through `messageix/R/utils_env.R`, so `run_matrix.sh` states no module, queue or mail
address of its own.

**A shared step-1 run folder across narratives.** The step-1 folder used to sit above the
narrative folders, so a second narrative's step-1 run could silently overwrite the first's and
the step-2 patch would be built on the wrong tau. Deriving the identifier per narrative settled
the cross-narrative half of this: each narrative now has its own `output/<identifier>/tau`, and
one reference tau is no longer shared between them. The remaining exposure is a narrative
against its own past — a folder is addressed by name, `cfg$force_replace` is `TRUE`, and a
stage-1 setting may have changed since the folder was filled. **Fix:** step 1 writes
`messageix_stage1_fingerprint.txt` into its run folder and
`build_step2_patch.R` refuses to extract tau from a run whose fingerprint disagrees with its
preset. The folder names are unchanged — they are part of the golden-master artefact — so the
collision becomes an error rather than a rename.

**Personal state.** Hard-coded personal cluster paths, a hard-coded mail
address, `_ALL` / `_LAND` / `_FOOD` literals in bash arrays, dead variables, four-way
commented-out path variants, and stale references to renamed files are all removed. Narratives
are preset columns; paths and the R environment come from configuration.

**The abandoned preset.** `config/projects/scenario_config_genie.csv` is not loaded by any of
the three pipeline start scripts — they call `setScenario(cfg, "SSP2")` against the stock
config and then set roughly fifteen parameters inline. Fourteen of the preset's rows were
therefore **not in effect** in the runs that produced the golden matrix, and several of its
values are stale (`R32M46-SSP2EU-NPi` is a pre-rev4.119 scenario name). Porting it wholesale
would change the science silently and break the golden-master test. The `default` preset
column is built from what the start scripts actually set. Whether the CSV was abandoned
deliberately on the move to 4.11.0 or is an unnoticed regression is one for Di.

---

## Open items

**Blocking the step-3 patch generator:**

- **The `f56_pollutant_prices.cs3` generator is missing.** Nothing in either source repository
  constructs the twelve `G####exp2110` columns. The semantics are not reverse-engineerable
  from the labels: whether `G0400` denotes 400 $/tCO2 in a base year, a 2100 endpoint, or
  something else, and what growth rule "exp" applies, cannot be recovered from the code. Ask
  Di for the script. Failing that, read the twelve columns out of her existing
  `SSP2_demand_cap.tgz` and re-derive the trajectory — which requires the tarball. The
  pipeline builds the seam: an existing file or tarball is accepted through configuration, and
  the failure message names exactly what is missing.
  For reference when the script arrives: the table is
  `f56_pollutant_prices(t_all, i, pollutants, ghgscen56)` in USD17MER per t; MAgPIE's own
  REMIND-report importer converts CO2 by 44/12 to US$/tC and N2O by 44/28 to US$/tN and leaves
  CH4 as-is; `c56_mute_ghgprices_until` (default `y2030`) mutes prices up to that year
  regardless, and `s56_minimum_cprice = 3.67` USD17/tC applies regardless.

**Pending confirmation from Di:**

- **`SSP2_price.tgz` contents.** With a correctly updated base tarball, does the step-2 patch
  reduce to `f13_tau_scenario.csv` alone, or does it also carry the stale-tarball fixes that
  motivated `SSP2_tau.tgz`? If the latter, the extra files need enumerating.
- **Step-1 protection scenario.** Step 1 runs `c22_protect_scenario = "BH"` while steps 2 and
  3 run `"none"` — tau calibrated under a protection scenario and then applied exogenously
  without it. Deliberate or leftover? Preserved as-is for the golden-master run either way.
- **The abandoned preset CSV** (above): deliberate or an unnoticed regression?
- **`f60_bioenergy_dem_R12_orig.cs3`.** The step-2.5 extractor required this seed file from a
  personal directory; it exists in neither repository. It is almost certainly the R12
  `f60_bioenergy_dem.cs3` as shipped by the base tarball, kept aside so repeated appends do not
  compound. The port takes the seed from `modules/60_bioenergy/input/` after
  `download_and_update`. Confirm the substitution is equivalent.
- **`additional_data_rev4.62` vs `rev4.63`, and the R12 calibration tarball.** The golden runs
  used `additional_data_rev4.62.tgz` where v4.11.0 defaults to `rev4.63`, and carried no
  `calibration` entry at all where the default ships `calibration_H12_FAO_13Mar25.tgz`. Will
  the updated R12 tarball set ship `rev4.63` and a matching R12 calibration tarball?
- **Tarball location and reachability.** Exact paths on the PIK cluster and the shared drive;
  whether the R12 tarball resolves through a `cfg$repositories` entry on the cluster or must be
  placed by hand; and whether `MMEmuR12_rev4.96.tgz` is fully redundant now that it is
  commented out in every pipeline start script.
- **Narrative scope.** The emulator wrappers were wired for four narratives
  (`ref` / `LAND` / `FOOD` / `ALL`). Confirm the MVP is `ref` = `SSP2_BD00` only, matching
  `magpie_input_SSP2_ref_woodfuel.csv`.

**Tracked, not blocking:**

- **Tarball hosting** (Q6 above).
- **The `GENIE_4` feedback stage** — one MAgPIE run taking bioenergy demand and GHG prices
  back from a MESSAGE solution, i.e. the coupled feedback loop downstream of the emulator.
  Documented, out of MVP scope.
- **Intensive variables in the mapping.** All 81 mapping rows carry `spatial = reg+glo`.
  Prices, `Biodiversity|BII` and `Landuse intensity indicator Tau` are per-unit quantities that
  must not be summed across regions; if their World values come out roughly 13x too large,
  those rows change to `spatial = reg`. Settled in seconds against the golden matrix on the
  first build; record the answer here.
