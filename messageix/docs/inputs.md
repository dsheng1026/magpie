# Input tarballs — signpost

**The repository carries no input data.** This page documents which MAgPIE input tarballs the
pipeline needs, how MAgPIE finds them, and where to get them. The tarballs are not currently
redistributable (see `decisions.md`, Q6).

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
| `patch` | generated between phases — see below |

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
region set with the region-name table that has to agree with them
(`../data/region_names_R12.csv`). An experiment names the set (`region_set = "R12"`) and
never the files, so everything that has to travel together does. A tarball set at another
resolution needs its own table beside it — `pipeline.md` §8, "New region set", is the
recipe.

`5ff27be8` is the hash MAgPIE assigns to the MESSAGE R12 region mapping
(`AFR CHA CPA EEU FSU LAM MEA NAM PAO PAS SAS WEU`); upstream's default H12 mapping hashes to
`62eff8f7`. **The region set is delivered by the tarball, never by a committed file** — MAgPIE
rebuilds `core/sets.gms` from the mapping inside the tarball on every input download
(`pipeline.md` §4).

---

## Where the tarballs are

**Currently: Di Sheng's shared drive and the PIK cluster. Ask Di Sheng for the exact paths and
for access** — they are not recorded here yet, and the tarballs are private within IIASA.

Also worth confirming with Di when you ask: whether the R12 set is reachable through a
`cfg$repositories` entry on the PIK cluster or has to be placed by hand, and whether the older
R12 patch `MMEmuR12_rev4.96.tgz` is now fully redundant (nothing in this pipeline reads it,
which suggests yes).

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
cluster that includes the internal data paths. Both repository entries are infrastructure
settings (`../R/utils_env.R` asks for them), so a site with the tarballs somewhere else adds an
entry rather than editing code.

To place a tarball by hand, put it in a directory and add that directory to `cfg$repositories`.
Do **not** unpack it yourself: MAgPIE extracts each archive flat and then routes every file to
the module `input/` folder whose own `input/files` manifest claims it, with unclaimed files
going to `input/`.

---

## `patch_input/` — the tarballs packed between phases

A "patch" in MAgPIE terms is a project-specific selective override of base inputs, not a
software patch. The pipeline packs two of them, and nothing is assembled by hand:

| Read by | Contents | Packed by |
| --- | --- | --- |
| the price sweep | `f13_tau_scenario.csv` — the trajectory the calibration run solved for | `../R/pack_price.R` |
| the demand sweep | `f60_bioenergy_dem.cs3` with one bioenergy demand column per price level; `f56_pollutant_prices.cs3` with the GHG price trajectory columns **supplied by whoever runs the pipeline** (`--f56=PATH`) — nothing here builds them, see `decisions.md`, Open items | `../R/pack_demand.R` |

They are written to `patch_input/` at the repository root — a directory that does not exist in
a fresh clone and that the packing creates. Packed tarballs are build artefacts and are never
committed. Their names carry a digest of the contents, for reasons that are part of how MAgPIE
distributes inputs (`pipeline.md` §3).

No `SSP2_tau.tgz` is consumed anywhere. It existed only to patch a base tarball that was stale
relative to the MAgPIE version being run; a correctly updated tarball makes it redundant.

---

## Future: the version × region matrix

An input tarball is specific to a MAgPIE version — code and module structure change across
releases — **and** to a region resolution, because it encodes the cell-to-region mapping. The
full picture is a matrix of MAgPIE version × region set. This pipeline pins exactly one cell of
it: **v4.11.0 × R12**.

Adding a cell means: obtain the matching tarball set, name it (on the region axis, a new
`region_sets()` entry pairing the tarballs with a region-name table), point an experiment at
it, calibrate again, and rerun validation. The output folder name follows from the tarballs, so
the new cell cannot land in the old one's folders. The first intended move is the version axis
— v4.14.0 — which doubles as the first exercise of the upstream-merge path.

**Cell-level aggregation is the other axis, and it is not built.** The intended path is to
accept cell-level MAgPIE input and aggregate to a custom region set at run time rather than
depending on a pre-built tarball per region set. That is the door to country-level work
(R10, India, China). Recorded here as the design direction; nothing in the repository
implements it yet.
