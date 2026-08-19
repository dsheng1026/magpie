# |  The naming contract for the MAgPIE -> MESSAGEix pipeline.
# |
# |  Every folder name, run title, GAMS scenario-column name and patch-tarball
# |  name is built here and nowhere else. A name carries the design it stands
# |  for, so re-running a stage lands in the same place and no crosswalk file is
# |  needed.
# |
# |  One experiment, one folder. Everything an experiment varies is in the
# |  identifier it is given, so the names below it need carry only the position
# |  in the sweep:
# |
# |    stage 1   output/<identifier>/tau
# |    stage 2   output/<identifier>/BE05
# |    stage 3   output/<identifier>/BE05_G0400
# |
# |  Price levels are written one way and one way only: zero-padded, 2 digits
# |  for the bioenergy price and 4 for the GHG price. The same padded token names
# |  the run folder, the bioenergy demand column the stage-2 patch writes, and
# |  the column stage 3 asks for -- so the two sides of that handshake cannot
# |  drift apart. Whole numbers only: a price of 7.5 has no token.
# |
# |  Patch tarballs are content-hashed. MAgPIE decides whether to unpack input
# |  data again by comparing the tarball names it was asked for against the names
# |  recorded in input/info.txt, and never looks inside the files. A tarball
# |  rewritten under its old name is therefore ignored, and the run quietly
# |  proceeds on the previous run's data. Letting the name change with the
# |  contents makes reuse on a re-run correct by construction.
# |
# |  Interface
# |    pad_int(x, width)                    -> chr; zero-padded integer, errors on non-integers
# |    be_token(be)                         -> chr; "BE05"
# |    ghg_token(ghg)                       -> chr; "G0400"
# |    bio_scen_tag(be)                     -> chr; "BIO05", the matrix BIOscen tag
# |    ghg_scen_tag(ghg)                    -> chr; "GHG400", the matrix GHGscen tag
# |    region_names_file(pcfg)              -> chr(1); the region set's region-name table
# |    region_rename(pcfg)                  -> named chr; MAgPIE region code -> MESSAGEix name
# |    scen_column(pcfg, be)                -> chr; "default_BE05"
# |    ghg_scenario(pcfg, ghg)              -> chr; "G0400exp2110"
# |    stage_token(stage)                   -> chr(1); 1|2|3 -> "tau"|"price"|"demand"
# |    phase_of_stage(stage)                -> chr(1); the phase name a stage runs under
# |    stage_of_phase(phase)                -> int(1); the stage a phase name stands for
# |    run_title(pcfg, stage, be, ghg)      -> chr(1); cfg$title for one run
# |    results_folder(pcfg, stage)          -> chr(1); cfg$results_folder template with :title:
# |    run_folder(pcfg, stage, be, ghg)     -> chr(1); concrete run directory, repo-relative
# |    locate_run_folder(pcfg, stage, be, ghg) -> chr(1) path, or NA_character_ if absent
# |    expected_run_folders(pcfg, stage)    -> data.frame(be, ghg, title, folder)
# |    matrix_grid(pcfg, run_dir, layout)   -> data.frame(be, ghg, title, folder); matrix row order
# |    content_hash(files)                  -> chr(1); lower-case hex digest of file contents
# |    patch_tarball_name(experiment, stage, files) -> chr(1); "<experiment>_<stage>_<hash>.tgz"
# |
# |  Dependencies: base R (tools), tibble/dplyr/tidyr/purrr, and
# |  messageix/R/utils_log.R. region_rename()
# |  additionally uses data_dir() and read_pipeline_csv() from utils_config.R,
# |  which are loaded by the time any resolved experiment exists.

if (!exists("log_die", mode = "function")) source("messageix/R/utils_log.R")

# ---- integer tokens ---------------------------------------------------------

# Zero-pad an integer-valued number. Non-integers are rejected rather than
# rounded: a rounded token would name a run for a price it was not run at, and
# the mistake would surface only when somebody read the results.
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

# ---- region names -----------------------------------------------------------

# The table of region names this experiment works in. It comes with the region
# set, so it cannot disagree with the input tarballs. A bare file name is a file
# in messageix/data/; a name with a directory in it is used as given, so a
# table kept outside the repository also works.
region_names_file <- function(pcfg) {
  name <- as.character(pcfg$region_names)
  if (!length(name) || !nzchar(name)) {
    log_die("region set '", pcfg$region_set, "' names no region-name table")
  }
  if (identical(basename(name), name)) file.path(data_dir(), name) else name
}

# Read once per file, not once per run: the woodfuel step asks for this table
# inside a loop over 84 runs.
.REGION_RENAME_CACHE <- new.env(parent = emptyenv())

# MAgPIE region code -> MESSAGEix region name, as a named character vector.
#
# This is the region vocabulary of the emulator matrix and of the woodfuel table
# added to it. Both are renamed from this one table, because two tables that
# disagree by a single name produce two files that share no key and a woodfuel
# step that quietly adds nothing. A region the table does not name passes
# through unchanged.
#
# Working at another region resolution is one new region set: its tarballs and
# this table, listed together in messageix/R/pipeline_infrastructure.R. See
# messageix/docs/pipeline.md, "New region set".
region_rename <- function(pcfg) {
  path <- region_names_file(pcfg)
  key <- normalizePath(path, mustWork = FALSE)
  cached <- .REGION_RENAME_CACHE[[key]]
  if (!is.null(cached)) return(cached)

  if (!file.exists(path)) {
    log_die("region-name table not found: ", path, ". Region set '", pcfg$region_set,
            "' names '", pcfg$region_names, "', and a bare file name is looked for in ",
            data_dir())
  }
  tab <- read_pipeline_csv(path, "region-name table")
  if (ncol(tab) < 2L) {
    log_die("region-name table ", path, " has ", ncol(tab),
            " column(s); it takes two: the MAgPIE region code and the MESSAGEix name")
  }
  codes <- trimws(tab[[1L]])
  names_out <- trimws(tab[[2L]])
  keep <- nzchar(codes) & nzchar(names_out)
  if (!any(keep)) log_die("region-name table ", path, " holds no region rows")
  if (anyDuplicated(codes[keep])) {
    log_die("region-name table ", path, " names the region code(s) ",
            unique(codes[keep][duplicated(codes[keep])]), " more than once")
  }
  out <- stats::setNames(names_out[keep], codes[keep])
  assign(key, out, envir = .REGION_RENAME_CACHE)
  out
}

# ---- scenario column names --------------------------------------------------

# Column name of the second-generation bioenergy demand trajectory that the
# price sweep writes into f60_bioenergy_dem.cs3 and the demand sweep selects
# with c60_2ndgen_biodem. It carries the experiment's name so that one glance at
# the file says which experiment the column belongs to, and the same padded
# price token the run folder uses so the two cannot disagree.
scen_column <- function(pcfg, be) {
  paste0(pcfg$experiment, "_", be_token(be))
}

# Column name of the GHG price trajectory in f56_pollutant_prices.cs3. The
# suffix records the extension rule of the trajectory beyond the last reported
# year (default "exp2110": exponentially extended to 2110). These columns are
# supplied from outside the pipeline, so this spelling is not ours to change.
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

# The phase a stage runs under, in the words the command line uses: the
# reference run is calibrate, the two sweeps are price and demand.
phase_of_stage <- function(stage) c("calibrate", "price", "demand")[.as_stage(stage)]

# The other way round: the stage a phase name stands for.
stage_of_phase <- function(phase) {
  phases <- c("calibrate", "price", "demand")
  hit <- match(as.character(phase)[1L], phases)
  if (is.na(hit)) {
    log_die("'", phase, "' is not a phase that runs MAgPIE. Those are: ",
            paste(phases, collapse = ", "))
  }
  hit
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

# cfg$title for a single run: the position in the sweep, and nothing else.
# Everything the experiment varies is already in the folder it sits in.
#   stage 1  "tau"
#   stage 2  "BE05"
#   stage 3  "BE05_G0400"
run_title <- function(pcfg, stage, be = NULL, ghg = NULL) {
  stage <- .as_stage(stage)
  if (stage == 1L) return("tau")
  if (is.null(be)) log_die("run_title: stage ", stage, " needs a bioenergy price")
  if (stage == 2L) return(be_token(be))
  if (is.null(ghg)) log_die("run_title: stage 3 needs a GHG price")
  paste0(be_token(be), "_", ghg_token(ghg))
}

# cfg$results_folder, in MAgPIE's template form. start_run() substitutes
# :title: with cfg$title. No :date: placeholder: run folders are addressed by
# name from expected_run_folders(), which a timestamp would defeat.
results_folder <- function(pcfg, stage) {
  .as_stage(stage)
  file.path("output", pcfg$identifier, ":title:")
}

# The concrete directory a run writes to, relative to the model root.
run_folder <- function(pcfg, stage, be = NULL, ghg = NULL) {
  title <- run_title(pcfg, stage, be = be, ghg = ghg)
  sub(":title:", title, results_folder(pcfg, stage), fixed = TRUE)
}

# The run folder if it exists on disk, NA_character_ otherwise. Callers collect
# the NAs and fail once with the full list, rather than dying on the first gap.
# Existence is not solvedness -- utils_runs.R answers that question.
locate_run_folder <- function(pcfg, stage, be = NULL, ghg = NULL) {
  path <- run_folder(pcfg, stage, be = be, ghg = ghg)
  if (dir.exists(path)) path else NA_character_
}

# Every run a stage is expected to produce, in loop order (bioenergy price
# outer, GHG price inner), matching the order the phases submit them.
# Columns: be, ghg, title, folder. ghg is NA for stage 1.
#
# tidyr::expand_grid varies its last argument fastest, which is what puts the
# GHG price on the inside of the demand sweep.
expected_run_folders <- function(pcfg, stage) {
  stage <- .as_stage(stage)
  grid <- if (stage == 1L) {
    tibble::tibble(be = NA_real_, ghg = NA_real_)
  } else if (stage == 2L) {
    tibble::tibble(be = pcfg$prices_bioenergy, ghg = 0)
  } else {
    tidyr::expand_grid(be = pcfg$prices_bioenergy, ghg = pcfg$prices_ghg)
  }
  dplyr::mutate(grid,
                title  = purrr::map2_chr(be, ghg, function(b, g) run_title(pcfg, stage, be = b, ghg = g)),
                folder = purrr::map2_chr(be, ghg, function(b, g) run_folder(pcfg, stage, be = b, ghg = g)))
}

# Run titles as an older set of runs on the cluster spells them: the SSP and the
# biodiversity target in front, a word for the stage behind. Nothing writes
# these -- they exist so the matrix step can be pointed at runs made before this
# pipeline and used to check its output against them, without a folder of runs
# having to be renamed.
.legacy_run_title <- function(pcfg, be, ghg) {
  bl <- as.numeric(pcfg$bii_target)
  if (abs(bl * 100 - round(bl * 100)) > 1e-9 || bl < 0 || bl >= 1) {
    log_die("the legacy layout writes the biodiversity target as two digits, so it takes a ",
            "multiple of 0.01 below 1; this experiment has bii_target ", bl)
  }
  paste0(pcfg$ssp, "_BD", pad_int(round(bl * 100), 2L), "_",
         be_token(be), "_", ghg_token(ghg), "demand")
}

# The stage-3 runs in the order the emulator matrix wants them: bioenergy price
# varies fastest, GHG price slowest. Both matrix steps build their grid here so
# their rows line up with each other. The run folders sit directly under the
# directory the caller names, because the matrix steps are pointed at a run
# directory rather than deriving one.
#
#   layout  "current" for runs this pipeline made; "legacy" to read a set of
#           runs made before it, which is a validation exercise and not a way
#           to produce anything
#
# Columns: be, ghg, title, folder.
matrix_grid <- function(pcfg, run_dir, layout = c("current", "legacy")) {
  layout <- match.arg(layout)
  title_of <- function(be, ghg) {
    if (identical(layout, "legacy")) .legacy_run_title(pcfg, be, ghg)
    else run_title(pcfg, 3L, be = be, ghg = ghg)
  }
  # The bioenergy price varies fastest here, the other way round from the order
  # the runs are submitted in, because this is the matrix's own row order.
  tidyr::expand_grid(ghg = pcfg$prices_ghg, be = pcfg$prices_bioenergy) |>
    dplyr::select(be, ghg) |>
    dplyr::mutate(title  = purrr::map2_chr(be, ghg, title_of),
                  folder = file.path(run_dir, title))
}

# ---- patch tarball naming ---------------------------------------------------

# Digest of a set of file contents, independent of file order and of the
# directory the files are staged in. tools::md5sum digests each file; the
# per-file digests are sorted by basename, concatenated and digested again via
# a temporary file, because tools::md5sum works on files rather than strings.
# Base R only -- the pipeline must run on a cluster R with no extra packages.
#
# Eight characters, not a settable width: the drivers recognise a generated
# tarball by a pattern that spells out eight, so a shorter or longer digest
# would produce a name the driver refuses to use.
content_hash <- function(files) {
  n <- 8L
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

# Name of a generated patch tarball: "<experiment>_<stage>_<8 hex>.tgz".
# The hash is over the files that go inside, so regenerating identical content
# yields the same name (MAgPIE skips the re-download, correctly) and changed
# content yields a new one (MAgPIE re-extracts and regenerates the module sets).
patch_tarball_name <- function(experiment, stage, files) {
  if (!length(files)) log_die("patch_tarball_name: no files to hash")
  paste0(experiment, "_", stage_token(stage), "_", content_hash(files), ".tgz")
}
