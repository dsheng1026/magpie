# |  The naming contract for the MAgPIE -> MESSAGEix pipeline.
# |
# |  Every folder name, run title, GAMS scenario-column name and patch-tarball
# |  name is built here and nowhere else. Names carry the full design (SSP,
# |  BII target, bioenergy price, GHG price, stage), so re-running a stage is
# |  idempotent and no crosswalk file is needed.
# |
# |  Two encodings of the bioenergy price level are in play and both are
# |  required, because MAgPIE reads them in different places:
# |    folder token    zero-padded to 2   BE00 BE05 BE07 BE10 BE15 BE25 BE45
# |    scenario column unpadded           SSP2_BD00_BE0 _BE5 _BE7 _BE10 ...
# |  The scenario column is the name of a column in f60_bioenergy_dem.cs3 and
# |  must match byte for byte what cfg$gms$c60_2ndgen_biodem requests.
# |
# |  Patch tarballs are content-hashed. MAgPIE decides whether to re-extract
# |  inputs by comparing tarball *filenames* against input/info.txt
# |  (scripts/start_functions.R, download trigger), never checksums, so
# |  rewriting a tarball under its old name leaves the model running on stale
# |  data and stale generated sets.gms. A name that changes with the content
# |  makes reuse-on-re-run correct by construction.
# |
# |  Run folder layout:
# |    stage 1  output/<identifier>/<title>
# |    stage 2  output/<identifier>/<preflag>/<title>
# |    stage 3  output/<identifier>/<preflag>/<title>
# |  Stage 1 sits one level up because its tau trajectory is reusable across
# |  narratives -- but only across narratives that agree on every stage-1
# |  setting, and several of those are preset-driven (c13_tccost,
# |  c14_yields_scenario, c_timesteps, the step-1 protection and bioenergy-demand
# |  scenarios, the input tarballs). Two presets that differ in any of them write
# |  to the same folder and the second overwrites the first. The condition is
# |  therefore made checkable rather than assumed: stage 1 writes a fingerprint
# |  of those settings into its run folder and the step-1.5 generator refuses to
# |  build a patch from a run whose fingerprint disagrees with its preset
# |  (messageix/R/utils_runs.R).
# |
# |  Interface
# |    pad_int(x, width)                    -> chr; zero-padded integer, errors on non-integers
# |    be_token(be)                         -> chr; "BE05"
# |    ghg_token(ghg)                       -> chr; "G0400"
# |    bio_scen_tag(be)                     -> chr; "BIO05", the matrix BIOscen tag
# |    ghg_scen_tag(ghg)                    -> chr; "GHG400", the matrix GHGscen tag
# |    region_rename                        -> named chr; MAgPIE region code -> MESSAGEix name
# |    preflag(pcfg)                        -> chr(1); "SSP2_BD00"
# |    scen_column(pcfg, be)                -> chr; "SSP2_BD00_BE5" (unpadded)
# |    ghg_scenario(pcfg, ghg)              -> chr; "G0400exp2110"
# |    stage_token(stage)                   -> chr(1); 1|2|3 -> "tau"|"price"|"demand"
# |    run_title(pcfg, stage, be, ghg)      -> chr(1); cfg$title for one run
# |    results_folder(pcfg, stage)          -> chr(1); cfg$results_folder template with :title:
# |    run_folder(pcfg, stage, be, ghg)     -> chr(1); concrete run directory, repo-relative
# |    locate_run_folder(pcfg, stage, be, ghg) -> chr(1) path, or NA_character_ if absent
# |    expected_run_folders(pcfg, stage)    -> data.frame(be, ghg, title, folder)
# |    content_hash(files, n = 8)           -> chr(1); lower-case hex digest of file contents
# |    patch_tarball_name(preset, stage, files) -> chr(1); "<preset>_<stage>_<hash>.tgz"
# |
# |  Dependencies: base R (tools, utils) and messageix/R/utils_log.R.

if (!exists("log_die", mode = "function")) source("messageix/R/utils_log.R")

# ---- integer tokens ---------------------------------------------------------

# Zero-pad an integer-valued number. Non-integers are rejected rather than
# rounded: the folder token and the scenario column would disagree silently
# (BE08 vs _BE7.5) and the run would fail deep inside GAMS on an unknown set
# element instead of here.
pad_int <- function(x, width) {
  x <- as.numeric(x)
  if (any(is.na(x))) log_die("pad_int: non-numeric value")
  if (any(abs(x - round(x)) > 1e-9)) {
    log_die("pad_int: the naming contract admits integers only, got ", x)
  }
  if (any(x < 0)) log_die("pad_int: negative value ", x)
  formatC(round(x), width = width, flag = "0", format = "d")
}

# Bioenergy price folder token, 2 digits.
be_token <- function(be) paste0("BE", pad_int(be, 2L))

# GHG price folder token, 4 digits.
ghg_token <- function(ghg) paste0("G", pad_int(ghg, 4L))

# ---- emulator matrix tags ---------------------------------------------------

# A third encoding of the same two integers, for the matrix's own scenario
# columns: the folder GHG token is 4-digit (G0000) while the GHGscen tag is
# 3-digit and grows past it (GHG000 .. GHG4000), and the BIOscen tag pads to 2
# like the folder token but under a different prefix. Neither encoding is
# derivable from the other, so both are built here from the price level.
bio_scen_tag <- function(be)  paste0("BIO", pad_int(be, 2L))
ghg_scen_tag <- function(ghg) paste0("GHG", pad_int(ghg, 3L))

# MAgPIE R12 code -> MESSAGEix long name: the region vocabulary of the matrix
# and of the woodfuel table added to it, which must be one vocabulary or the two
# tables share no key. "World" maps to itself; "GLO" is the safety net for a
# mapped mif carrying the MAgPIE-style global code instead of the mif's "World".
# Unmatched regions pass through unchanged.
region_rename <- c(
  AFR = "SubSaharanAfrica",  CHA = "ChinaReg",          CPA = "PlannedAsiaChina",
  EEU = "CentralEastEurope", FSU = "FormerSovietUnion", LAM = "LatinAmericaCarib",
  MEA = "MidEastNorthAfrica", NAM = "NorthAmerica",     PAO = "PacificOECD",
  PAS = "OtherPacificAsia",  SAS = "SouthAsia",         WEU = "WesternEurope",
  GLO = "World",             World = "World"
)

# ---- narrative and scenario names -------------------------------------------

# Narrative prefix: SSP plus the BII target in whole percent.
# The 2-digit pad restricts bii_target to multiples of 0.01 below 1; anything
# finer would collide (0.075 and 0.75 both padding to "75").
preflag <- function(pcfg) {
  bl <- as.numeric(pcfg$bii_target)
  if (is.na(bl) || bl < 0 || bl >= 1) {
    log_die("preflag: bii_target must lie in [0, 1), got ", bl)
  }
  if (abs(bl * 100 - round(bl * 100)) > 1e-9) {
    log_die("preflag: bii_target must be a multiple of 0.01, got ", bl)
  }
  paste0(pcfg$ssp, "_BD", pad_int(round(bl * 100), 2L))
}

# Column name of the second-generation bioenergy demand trajectory that stage 2
# writes into f60_bioenergy_dem.cs3 and stage 3 selects with c60_2ndgen_biodem.
# Unpadded on purpose -- see the header.
scen_column <- function(pcfg, be) {
  be <- as.numeric(be)
  if (any(is.na(be))) log_die("scen_column: non-numeric bioenergy price")
  paste0(preflag(pcfg), "_BE", format(be, trim = TRUE, scientific = FALSE))
}

# Column name of the GHG price trajectory in f56_pollutant_prices.cs3.
# The suffix records the extension rule of the trajectory beyond the last
# reported year (default "exp2110": exponentially extended to 2110).
ghg_scenario <- function(pcfg, ghg) {
  paste0(ghg_token(ghg), pcfg$ghg_price_scenario_suffix)
}

# ---- stages -----------------------------------------------------------------

# Stage number -> the word used in run titles and patch names.
stage_token <- function(stage) {
  tokens <- c("tau", "price", "demand")
  stage <- .as_stage(stage)
  tokens[stage]
}

# Accept a stage as 1|2|3 or as its token, return the integer.
.as_stage <- function(stage) {
  tokens <- c("tau", "price", "demand")
  if (is.character(stage) && stage[1L] %in% tokens) return(match(stage[1L], tokens))
  s <- suppressWarnings(as.integer(stage[1L]))
  if (is.na(s) || !s %in% 1:3) {
    log_die("stage must be 1, 2, 3 or one of tau/price/demand, got ", stage[1L])
  }
  s
}

# ---- run titles and folders -------------------------------------------------

# cfg$title for a single run.
#   stage 1  "<ssp>_tau"                       reference tau, one run
#   stage 2  "<preflag>_BE<pp>_G0000price"     GHG price is zero throughout
#   stage 3  "<preflag>_BE<pp>_G<pppp>demand"
run_title <- function(pcfg, stage, be = NULL, ghg = NULL) {
  stage <- .as_stage(stage)
  if (stage == 1L) return(paste0(pcfg$ssp, "_tau"))
  if (is.null(be)) log_die("run_title: stage ", stage, " needs a bioenergy price")
  if (stage == 2L) {
    return(paste0(preflag(pcfg), "_", be_token(be), "_", ghg_token(0), "price"))
  }
  if (is.null(ghg)) log_die("run_title: stage 3 needs a GHG price")
  paste0(preflag(pcfg), "_", be_token(be), "_", ghg_token(ghg), "demand")
}

# cfg$results_folder, in MAgPIE's template form. start_run() substitutes
# :title: with cfg$title. No :date: placeholder: run folders are addressed by
# name from expected_run_folders(), which a timestamp would defeat.
results_folder <- function(pcfg, stage) {
  stage <- .as_stage(stage)
  if (stage == 1L) return(file.path("output", pcfg$identifier, ":title:"))
  file.path("output", pcfg$identifier, preflag(pcfg), ":title:")
}

# The concrete directory a run writes to, relative to the model root.
run_folder <- function(pcfg, stage, be = NULL, ghg = NULL) {
  title <- run_title(pcfg, stage, be = be, ghg = ghg)
  sub(":title:", title, results_folder(pcfg, stage), fixed = TRUE)
}

# The run folder if it exists on disk, NA_character_ otherwise. Callers collect
# the NAs and fail once with the full list, rather than dying on the first gap.
# Existence is not solvedness -- check modelstat in fulldata.gdx for that.
locate_run_folder <- function(pcfg, stage, be = NULL, ghg = NULL) {
  path <- run_folder(pcfg, stage, be = be, ghg = ghg)
  if (dir.exists(path)) path else NA_character_
}

# Every run a stage is expected to produce, in loop order (bioenergy price
# outer, GHG price inner), matching the order the drivers submit them.
# Columns: be, ghg, title, folder. ghg is NA for stage 1.
expected_run_folders <- function(pcfg, stage) {
  stage <- .as_stage(stage)
  grid <- if (stage == 1L) {
    data.frame(be = NA_real_, ghg = NA_real_)
  } else if (stage == 2L) {
    data.frame(be = pcfg$be_prices, ghg = 0)
  } else {
    expand.grid(ghg = pcfg$ghg_prices, be = pcfg$be_prices)[, c("be", "ghg")]
  }
  grid <- as.data.frame(grid, stringsAsFactors = FALSE)
  rownames(grid) <- NULL
  grid$title <- vapply(seq_len(nrow(grid)), function(i) {
    run_title(pcfg, stage, be = grid$be[i], ghg = grid$ghg[i])
  }, character(1))
  grid$folder <- vapply(seq_len(nrow(grid)), function(i) {
    run_folder(pcfg, stage, be = grid$be[i], ghg = grid$ghg[i])
  }, character(1))
  grid
}

# ---- patch tarball naming ---------------------------------------------------

# Digest of a set of file contents, independent of file order and of the
# directory the files are staged in. tools::md5sum digests each file; the
# per-file digests are sorted by basename, concatenated and digested again via
# a temporary file, because tools::md5sum works on files rather than strings.
# Base R only -- the pipeline must run on a cluster R with no extra packages.
content_hash <- function(files, n = 8L) {
  missing <- files[!file.exists(files)]
  if (length(missing)) log_die("content_hash: file not found: ", missing)
  sums <- tools::md5sum(normalizePath(files, mustWork = TRUE))
  ord <- order(basename(files))
  payload <- paste0(basename(files)[ord], ":", unname(sums)[ord], collapse = "\n")
  tmp <- tempfile("mm_hash_")
  on.exit(unlink(tmp), add = TRUE)
  writeLines(payload, tmp)
  substr(unname(tools::md5sum(tmp)), 1L, n)
}

# Name of a generated patch tarball: "<preset>_<stage>_<8 hex>.tgz".
# The hash is over the files that go inside, so regenerating identical content
# yields the same name (MAgPIE skips the re-download, correctly) and changed
# content yields a new one (MAgPIE re-extracts and regenerates the module sets).
patch_tarball_name <- function(preset, stage, files) {
  if (!length(files)) log_die("patch_tarball_name: no files to hash")
  paste0(preset, "_", stage_token(stage), "_", content_hash(files), ".tgz")
}
