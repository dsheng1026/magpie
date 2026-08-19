# Input tarballs — signpost

**This directory holds no data.** It documents which MAgPIE input tarballs the pipeline needs,
how MAgPIE finds them, and where to get them. The tarballs are not currently redistributable
(see `../docs/decisions.md`, Q6).

---

## What the pipeline needs

MAgPIE reads all input data from version- and region-specific tarballs named in `cfg$input`.
The pipeline pins MAgPIE **v4.11.0** and the **MESSAGE R12** region set, regionscode
**`5ff27be8`**, input revision **rev4.119**:

| `cfg$input` entry | Filename |
| --- | --- |
| `regional` | `rev4.119_5ff27be8_magpie.tgz` |
| `cellular` | `rev4.119_5ff27be8_1b5c3817_cellularmagpie_c200_MRI-ESM2-0-ssp245_lpjml-8e6c5eb1.tgz` |
| `validation` | `rev4.119_5ff27be8_validation.tgz` |
| `additional` | `additional_data_rev4.62.tgz` |
| `patch` | generated — see below |

The `cellular` name encodes more than the region set: `1b5c3817` is the cellular data hash,
`c200` the cluster count, `MRI-ESM2-0-ssp245` the climate forcing, and `lpjml-8e6c5eb1` the
LPJmL run. An SSP change means a different cellular tarball, not just a different `setScenario`
column.

Two entries need confirmation before the first production run. The golden runs used
`additional_data_rev4.62.tgz` where v4.11.0 defaults to `rev4.63`, and carried **no**
`calibration` entry at all where the MAgPIE default ships `calibration_H12_FAO_13Mar25.tgz`.
Whether the updated R12 set ships `rev4.63` and a matching R12 calibration tarball is an open
question for Di Sheng.

The four names are one entry in `../R/pipeline_infrastructure.R`, listed together as the `R12`
region set. A narrative names the set (`region_set;R12`) and never the files, so the tarballs
and everything that has to agree with them move together.

What has to agree with them is the region-name table the same entry carries,
`../presets/region_names_R12.csv` for this set. It translates MAgPIE's region codes into the
names MESSAGEix uses, and it is the only place those names appear. A tarball set at another
resolution therefore needs its own table beside it — `../docs/pipeline.md` §8, "New region
set", is the recipe.

---

## `5ff27be8` — the regionscode, and why no region file is committed

`5ff27be8` is the hash MAgPIE assigns to the MESSAGE R12 region mapping
(`AFR CHA CPA EEU FSU LAM MEA NAM PAO PAS SAS WEU`). Upstream's default H12 mapping hashes to
`62eff8f7`.

**The R12 region set is delivered by the tarball. It is never delivered by a committed file.**
Every time MAgPIE unpacks its inputs it rebuilds `core/sets.gms` — the sets `h`, `i`, `supreg`,
`iso`, `j`, `cell`, `i_to_iso` — from the region mapping carried inside the tarball itself
(`input/spatial_header.rda`), and rewrites the `Regionscode:` line in `main.gms` from the same
source. `core/sets.gms` carries a "DO NOT MODIFY, WILL BE LOST" banner and `/input/` is
gitignored.

So: **do not commit `core/sets.gms`, `main.gms`, or any module `input.gms`/`sets.gms`.** A run
rewrites them; a dirty working tree after a run is normal MAgPIE behaviour. Changing the region
set means changing `cfg$input` in the preset, nothing else.

If the region set changes on a tree that has already run, set `cfg$force_download <- TRUE`.
MAgPIE decides whether to unpack inputs again by comparing tarball **filenames** against
`input/info.txt` and never looks inside the files, so it will otherwise keep the old data. A
fresh clone has no `info.txt` and downloads regardless.

---

## Where the tarballs are

**Currently: Di Sheng's shared drive and the PIK cluster. Ask Di Sheng for the exact paths and
for access** — they are not recorded here yet, and the tarballs are private within IIASA.

Also worth confirming with Di when you ask: whether the R12 set is reachable through a
`cfg$repositories` entry on the PIK cluster or has to be placed by hand, and whether the older
R12 patch `MMEmuR12_rev4.96.tgz` is now fully redundant (it is commented out in every pipeline
start script, which suggests yes).

Longer term: an IIASA-wide model-data share is under consideration; public hosting is a
team-leader decision, with a public archive release covering MESSAGE R12, R10, India and China
variants as the fallback if the MAgPIE repository cannot host the data. The repository would
then pin to that release.

---

## How MAgPIE finds them — `cfg$repositories`

MAgPIE searches `cfg$repositories` **in order** and takes the first hit for each filename. The
pipeline sets:

```r
cfg$repositories <- append(
  list("https://rse.pik-potsdam.de/data/magpie/public" = NULL,   # PIK public repository
       "./patch_input"                                 = NULL),  # generated patches, local
  getOption("magpie_repos"))                                     # site defaults, incl. PIK cluster paths
```

`getOption("magpie_repos")` carries whatever the local R environment provides — on the PIK
cluster that includes the internal data paths. The repository list is a configurable
environment setting (`../R/utils_env.R`), so a site with the tarballs somewhere else adds an
entry rather than editing code.

To place a tarball by hand, put it in a directory and add that directory to `cfg$repositories`.
Do **not** unpack it yourself: MAgPIE extracts each archive flat and then routes every file to
the module `input/` folder whose own `input/files` manifest claims it, with unclaimed files
going to `input/`.

---

## `patch_input/` — generated patch tarballs

A "patch" in MAgPIE terms is a project-specific selective override of base inputs, not a
software patch. A patch tarball is a plain `.tgz` containing **bare filenames at the archive
root, no directory structure**, listed **last** in `cfg$input` so it overrides earlier
entries.

The pipeline builds stage 2's patch tarball and the `f60` half of stage 3's; nothing is
assembled by hand inside the repository:

| Read by | Contents | Built by |
| --- | --- | --- |
| Stage 2 (price-driven) | `f13_tau_scenario.csv` — the reference tau trajectory from stage 1 | `patch_step2` (`../patches/build_step2_patch.R`) |
| Stage 3 (demand-driven) | `f60_bioenergy_dem.cs3` with seven new bioenergy demand columns; `f56_pollutant_prices.cs3` with twelve GHG price trajectory columns **supplied by whoever runs the pipeline** (`--f56=PATH`) — nothing here builds them, see `../docs/decisions.md`, Open items | `patch_step3` (`../patches/build_step3_patch.R`) |

They are written to `patch_input/` at the repository root — a directory that does not exist in
a fresh clone and that the generators create. Generated patches are build artefacts and are
never committed.

**Patch tarball names carry a digest of the contents** (`<preset>_<stage>_<8hex>.tgz`). MAgPIE
decides whether to unpack inputs again by comparing tarball names and never their contents, so
reusing a name with new contents is a silent no-op that leaves the run on stale data. A name
that changes with the contents makes rebuilding correct and reuse safe, and the drivers check
the result: once the first run of a stage has started, `input/info.txt` must name that stage's
patch tarball.

No `SSP2_tau.tgz` is consumed anywhere. It existed only to patch a base tarball that was stale
relative to the MAgPIE version being run; a correctly updated tarball makes it redundant.

---

## Future: the version × region matrix

An input tarball is specific to a MAgPIE version — code and module structure change across
releases — **and** to a region resolution, because it encodes the cell-to-region mapping. The
full picture is a matrix of MAgPIE version × region set. This pipeline pins exactly one cell of
it: **v4.11.0 × R12**.

Adding a cell means: obtain the matching tarball set, name it (on the region axis, a new
`region_sets()` entry pairing the tarballs with a region-name table), point a narrative column
at it, regenerate the reference tau (stage 1), and rerun validation. The output folder name
follows from the tarballs, so the new cell cannot land in the old one's folders. The first intended
move is the version axis — v4.14.0 — which doubles as the first exercise of the upstream-merge
path.

**Cell-level aggregation is the other axis, and it is not built.** The intended path is to
accept cell-level MAgPIE input and aggregate to a custom region set at run time rather than
depending on a pre-built tarball per region set. That is the door to country-level work
(R10, India, China). Recorded here as the design direction; nothing in the repository
implements it yet.
