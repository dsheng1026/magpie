# |  The reduce phase, first of two: build the emulator matrix from the demand
# |  sweep's runs.
# |
# |  Each run writes its results as report.mif, in MAgPIE's own variable names.
# |  This script renames, aggregates and unit-converts those variables into the
# |  ones MESSAGEix expects, using the recipe in MM_linkage_mapping.csv, tags each
# |  run with the bioenergy and GHG prices it was run at, and writes the whole set
# |  as one CSV. report.mif is the only source of data here. Woodfuel is not in
# |  it, and add_woodfuel_to_matrix.R adds that afterwards.
# |
# |  Everything happens in one pass in memory -- map, read, tag, combine, write --
# |  and no half-finished file is left on disk.
# |
# |  Run it through the pipeline -- Rscript messageix/run.R matrix NAME -- unless
# |  one step is being debugged on its own. That command runs both halves of the
# |  reduce phase in order and hands them the same experiment, the same run
# |  directory and the same layout. Nothing here can check that: the woodfuel step
# |  matches its rows against this matrix by scenario tag and region, so two
# |  invocations made for different experiments would produce a matrix and a
# |  woodfuel table that do not belong together.
# |
# |  Usage, from the MAgPIE model root:
# |    Rscript messageix/R/createMatrix_MM.R \
# |      --run-dir output/MESSAGEix_5ff27be8 \
# |      --out     /abs/path/to/magpie_input_SSP2_ref.csv
# |
# |    --run-dir DIR      directory holding the demand sweep's run folders; required
# |    --out FILE         matrix CSV to write, used exactly as given; required
# |    --experiment NAME  an experiment of messageix/experiments.R; default "default"
# |    --set key=value    override one setting; repeatable
# |    --allow-unmapped   report unmapped mapping variables instead of stopping
# |    --layout=legacy    read run folders named the way an older set of runs on
# |                       the cluster names them; for checking this pipeline's
# |                       output against those runs, not for producing anything
# |    --help             print usage and stop
# |
# |  Every option is accepted as "--key value" and as "--key=value".
# |
# |  The grid, the run names, the region names and the matrix scenario tags all
# |  come from the experiment, so the same command builds any of them. Nothing is
# |  written unless every run in the grid exists, solved, and mapped completely:
# |  a partial matrix is indistinguishable from a complete one downstream.
# |
# |  Dependencies: iamc, readr/dplyr/tidyr/tibble/stringr, gdx2 and magpie4
# |  (solve status), and the messageix/R/ layer, loaded through utils_runs.R.

suppressPackageStartupMessages({
  library(iamc)      # write.reportProject()
})

# One line loads the whole messageix/R/ layer: each file there loads the files it
# needs itself, and utils_runs.R sits at the bottom of that chain.
if (!exists("run_modelstat", mode = "function")) source("messageix/R/utils_runs.R")

# The mapping travels with the scripts that use it, so it is addressed relative
# to the model root rather than passed in: it is part of the pipeline, not a
# per-run choice.
MAP_FILE <- "messageix/data/MM_linkage_mapping.csv"

# The results file each run writes is MIF_NAME, named once for the whole
# pipeline in messageix/R/utils_runs.R: the pipeline driver waits for it, and
# this step builds the matrix out of it.

# Intensive variables: prices, indices and other per-unit quantities, which have
# no meaning when added up across regions. Every row of the mapping asks for
# regions plus a global value ("reg+glo"), which is right only where the global
# value is taken from the run's own World row rather than summed from the
# regions. check_intensive_aggregation() below tests that on the finished matrix.
INTENSIVE_VARIABLES <- c("Price|Carbon|CO2",
                         "Price|Primary Energy|Biomass",
                         "Biodiversity|BII",
                         "Landuse intensity indicator Tau")

# ---- arguments --------------------------------------------------------------

SYNOPSIS <- paste("usage: Rscript messageix/R/createMatrix_MM.R --run-dir=DIR --out=FILE",
                  "[--experiment=NAME] [--set=key=value] [--allow-unmapped] [--layout=legacy]",
                  "[--help]")

USAGE <- c(
  "Build the emulator matrix from a finished demand sweep: read each run's",
  "results file, rename and convert its variables into the ones MESSAGEix expects,",
  "tag each run with the prices it was run at, and write one CSV for the whole set.",
  "Woodfuel is not in it yet -- add_woodfuel_to_matrix.R adds that afterwards.",
  "",
  "  Rscript messageix/R/createMatrix_MM.R --run-dir=DIR --out=FILE [flags]",
  "                                                     (from the MAgPIE model root)",
  "",
  "Flags:",
  "  --run-dir=DIR      the directory holding the demand sweep's run folders; required",
  "  --out=FILE         the matrix CSV to write, used exactly as given; required",
  "  --experiment=NAME  an experiment of messageix/experiments.R (default: default)",
  "  --set=key=value    override one setting for this build; repeatable",
  "  --allow-unmapped   build even when the mapping asks for variables the runs did",
  "                     not report. They are listed either way; without this flag",
  "                     they stop the build.",
  "  --layout=legacy    read run folders named the way an older set of runs on the",
  "                     cluster names them (SSP2_BD00_BE05_G0400demand). It is there",
  "                     to check this pipeline's matrix against those runs without",
  "                     renaming a folder of them; nothing produces runs in that",
  "                     layout.",
  "  --help             this text",
  "",
  "Every option is accepted as --key=value and as --key value.",
  "Which runs are expected, how they are named and how the matrix is tagged all come",
  "from the experiment, so the same command builds any of them. Nothing is written",
  "unless every run of the set is there, solved, and completely mapped: a matrix",
  "built from part of the set cannot be told from a complete one further downstream.")

# parse_flags() is the one command-line parser the pipeline uses
# (messageix/R/utils_config.R).
opt <- parse_flags(commandArgs(trailingOnly = TRUE),
                   known      = c("run-dir", "out", "experiment", "layout"),
                   flags      = c("allow-unmapped", "help"),
                   repeatable = "set",
                   usage      = SYNOPSIS)

if (isTRUE(opt$help)) {
  cat(USAGE, sep = "\n")
  cat("\n")
  quit(save = "no")
}

for (required in c("run-dir", "out")) {
  if (is.null(opt[[required]])) log_die("--", required, " is required. ", SYNOPSIS)
}

base_output_dir <- opt[["run-dir"]]
matrix_file     <- opt[["out"]]
allow_unmapped  <- isTRUE(opt[["allow-unmapped"]])
layout          <- if (is.null(opt$layout)) "current" else opt$layout
if (!layout %in% c("current", "legacy")) {
  log_die("--layout takes 'current' or 'legacy', got '", layout, "'")
}

pcfg <- config_from_flags(opt, cli_overrides(opt$set))

if (!dir.exists(base_output_dir)) log_die("--run-dir does not exist: ", base_output_dir)
if (!file.exists(MAP_FILE))       log_die("mapping file not found: ", MAP_FILE,
                                          " (run from the MAgPIE model root)")

# Prices go into MAgPIE multiplied by currency_2005_to_2017 (USD2005 ->
# USD2017) and come back out of it multiplied by the reciprocal, which is written
# into the mapping file. The two numbers live in two different files and nothing
# else keeps them in step, so moving one at a MAgPIE base-year change and not the
# other would produce a matrix whose price rows are converted with the wrong
# factor. This check turns that into a stop instead of a silence.
assert_price_factor <- function(mapping_path, pcfg, tolerance = 1e-6) {
  map <- read_pipeline_csv(mapping_path, "mapping file")
  rows <- dplyr::filter(map, startsWith(Variable, "Price|"))
  if (!nrow(rows)) {
    log_die("no target variable starting with 'Price|' in ", mapping_path,
            "; currency_2005_to_2017 has nothing to agree with")
  }
  wanted <- 1 / pcfg$currency_2005_to_2017
  found <- suppressWarnings(as.numeric(rows$factor))
  bad <- which(is.na(found) | abs(found - wanted) > tolerance)
  if (length(bad)) {
    log_die("currency mismatch: currency_2005_to_2017 = ", pcfg$currency_2005_to_2017,
            " implies a factor of ", signif(wanted, 9),
            " on the price rows of ", mapping_path, ", which carry ", rows$factor[bad],
            " for ", rows$Variable[bad],
            ". The deflator into MAgPIE and its reciprocal out of MAgPIE move together.")
  }
  invisible(TRUE)
}

assert_price_factor(MAP_FILE, pcfg)

# ---- mapping ----------------------------------------------------------------

# The only place the iamc package is used: read one run's report.mif, apply the
# mapping, write the result to a temporary file. Swapping iamc for another
# mapping package means rewriting this function body and nothing else.
apply_mapping <- function(mif_path, mapping_path, out_path, log_path) {
  write.reportProject(
    mif         = mif_path,
    mapping     = mapping_path,
    file        = out_path,
    missing_log = log_path
  )
  invisible(out_path)
}

# The variables the mapping asked for but the run did not report. The mapping
# step always writes a "#--- ... ---#" banner into its log, so the log being
# non-empty proves nothing; only lines that are neither comments nor blank do.
unmapped_variables <- function(log_path) {
  if (!file.exists(log_path)) return(character(0))
  grep("^\\s*#|^\\s*$", readLines(log_path, warn = FALSE), value = TRUE, invert = TRUE)
}

# ---- build ------------------------------------------------------------------

# The runs to read, in the order their rows go into the matrix. Both halves of
# the reduce phase take the grid from the same place; reduce_run_grid() in
# messageix/R/utils_runs.R is where the order is decided and where a --run-dir
# that is not this experiment's is caught.
grid <- reduce_run_grid(pcfg, base_output_dir, layout)

log_banner("REDUCE - the emulator matrix", list(
  experiment = pcfg$experiment,
  layout     = layout,
  runs       = nrow(grid),
  "run dir"  = base_output_dir,
  mapping    = MAP_FILE,
  out        = matrix_file
))

# Every run is checked before any is read: a matrix built from a subset of the
# grid is silently wrong downstream, so the gaps are collected and reported in
# full rather than one at a time.
log_step("CHECK", "run folders and solve status")
assert_runs_solved(grid, where = base_output_dir, extra = MIF_NAME,
                   closing = "Re-run or resubmit the listed runs. No matrix is written.")
log_step("CHECK", nrow(grid), " runs present and solved")

id_cols <- c("Region", "Variable", "Unit", "SSPscen", "GHGscen", "BIOscen", "SDGscen")

# The region vocabulary of the matrix, read once from the experiment's
# region-name table. The woodfuel step reads the same table, which is what lets the two
# tables be joined afterwards.
regions <- region_rename(pcfg)
log_step("CONFIG", "region names from ", region_names_file(pcfg), " (",
         length(regions), " entries)")

pieces   <- list()
unmapped <- list()

for (k in seq_len(nrow(grid))) {
  be  <- grid$be[k]
  ghg <- grid$ghg[k]
  log_step("MATRIX", "mapping ", grid$title[k])

  tmp_map <- tempfile(fileext = ".mif")
  tmp_log <- tempfile(fileext = ".log")
  apply_mapping(file.path(grid$folder[k], MIF_NAME), MAP_FILE, tmp_map, tmp_log)
  misses <- unmapped_variables(tmp_log)
  if (length(misses)) unmapped[[grid$title[k]]] <- misses

  df <- readr::read_delim(tmp_map, delim = ";", col_types = readr::cols(),
                          name_repair = "minimal", guess_max = Inf, progress = FALSE)
  unlink(c(tmp_map, tmp_log))

  # Drop the trailing empty column the mif export leaves behind. It has no name
  # to select it by, so it goes by the one thing that identifies it.
  df <- df[, nzchar(names(df)), drop = FALSE]

  # The results file carries its own Scenario field, which is the run title
  # MAgPIE wrote. Taking the prices back out of the data and checking them
  # against the folder catches a run folder holding some other run's results.
  tag_be  <- as.integer(stringr::str_match(df$Scenario[1], "(?:^|_)BE(\\d+)")[, 2])
  tag_ghg <- as.integer(stringr::str_match(df$Scenario[1], "(?:^|_)G(\\d+)")[, 2])
  if (is.na(tag_be) || is.na(tag_ghg) || tag_be != be || tag_ghg != ghg) {
    log_die("run folder ", grid$title[k], " holds a report for scenario '",
            df$Scenario[1], "'")
  }

  df <- dplyr::mutate(df,
                      SSPscen = pcfg$ssp,
                      GHGscen = ghg_scen_tag(ghg),
                      BIOscen = bio_scen_tag(be),
                      SDGscen = pcfg$matrix_sdg_scen)

  # Every region the run reports has to be named in the table. Region sets
  # overlap heavily -- R10 and R12 share eleven of their twelve codes -- so a
  # run at the wrong resolution would otherwise be renamed where the codes
  # happen to agree and left in MAgPIE's own codes where they do not, producing
  # a matrix that looks complete and carries two vocabularies. The fix is either
  # a different set of runs or a different region-name table, so both are named.
  unnamed <- setdiff(unique(df$Region), names(regions))
  if (length(unnamed)) {
    log_die("run ", grid$title[k], " reports region(s) ", paste(unnamed, collapse = ", "),
            " that ", region_names_file(pcfg), " does not name. It names ",
            paste(names(regions), collapse = ", "),
            ". Either these runs are at another region resolution than this experiment, or ",
            "the table is missing rows.")
  }
  # Model and Scenario are not part of the target format; the four tag columns
  # carry the same information in the shape MESSAGEix reads.
  df <- df |>
    dplyr::mutate(Region = unname(regions[Region])) |>
    dplyr::select(-dplyr::any_of(c("Model", "Scenario")))

  pieces[[length(pieces) + 1]] <- df
}

if (!length(pieces)) log_die("no runs mapped under ", base_output_dir)

# A mapping variable no run reports is a mapping that has drifted from the model
# version. Reported in full before anything is written, because the alternative
# is a matrix silently missing a variable MESSAGEix expects.
if (length(unmapped)) {
  variables <- sort(unique(unlist(unmapped, use.names = FALSE)))
  counts    <- vapply(variables,
                      function(v) sum(vapply(unmapped, function(x) v %in% x, logical(1))),
                      integer(1))
  report <- c(
    paste0(length(variables), " mapping variable(s) in ", MAP_FILE,
           " are absent from the runs' report.mif:"),
    paste0("    ", variables, "   [", counts, " of ", nrow(grid), " runs]"),
    "Fix the mapping against this MAgPIE version, or pass --allow-unmapped to build anyway."
  )
  log_report(report)
  if (allow_unmapped) {
    log_warn(length(variables), " mapping variable(s) unmapped; --allow-unmapped is set")
  } else {
    log_die(length(variables), " mapping variable(s) unmapped; see the list above")
  }
}

matrix_df <- dplyr::bind_rows(pieces)

# No two rows may share a scenario coordinate: a duplicate means two runs were
# tagged identically and one of them is silently unreachable.
dup_n <- sum(duplicated(dplyr::select(matrix_df, dplyr::all_of(id_cols))))
if (dup_n > 0) log_die(dup_n, " rows share an id-column key")

# Id columns first, then year columns in ascending numeric order.
year_cols <- setdiff(names(matrix_df), id_cols)
year_cols <- year_cols[order(as.numeric(year_cols))]
matrix_df <- dplyr::select(matrix_df, dplyr::all_of(c(id_cols, year_cols)))

# ---- structural checks ------------------------------------------------------

# Intensive variables must not be added up across regions. Where the global
# value is taken from the run's own World row, it sits inside the range of the
# regional values; where the regions have been summed instead, it equals their
# total -- roughly thirteen times a typical region at R12. The test is made on
# the scenario and year with the largest regional total, so a variable that is
# zero at a zero price is still tested somewhere it has signal.
check_intensive_aggregation <- function(df, variables) {
  years <- setdiff(names(df), id_cols)
  year_col <- years[which.max(as.numeric(years))]
  for (v in variables) {
    rows <- dplyr::filter(df, Variable == v)
    if (!nrow(rows)) next
    totals <- tibble::tibble(
        scenario = paste(rows$BIOscen, rows$GHGscen),
        where    = dplyr::if_else(rows$Region == "World", "world", "regions"),
        value    = suppressWarnings(as.numeric(rows[[year_col]]))) |>
      dplyr::group_by(scenario, where) |>
      dplyr::summarise(total = sum(value, na.rm = TRUE), .groups = "drop") |>
      tidyr::pivot_wider(names_from = where, values_from = total)
    if (!all(c("world", "regions") %in% names(totals))) next
    totals <- dplyr::filter(totals, !is.na(world), !is.na(regions))
    if (!nrow(totals)) next
    # The scenario with the largest regional total: a variable that is zero at a
    # zero price is still tested somewhere it has signal.
    worst <- dplyr::slice_max(totals, abs(regions), n = 1L, with_ties = FALSE)
    tolerance <- 1e-6 * max(abs(worst$regions), 1)
    if (abs(worst$world - worst$regions) <= tolerance) {
      log_warn(v, " at ", worst$scenario, ", ", year_col, ": World = ", signif(worst$world, 6),
               " equals the sum over regions = ", signif(worst$regions, 6),
               ". An intensive variable is being summed; set spatial = 'reg' for its ",
               "row in ", MAP_FILE, ".")
    } else {
      log_step("CHECK", v, " at ", worst$scenario, ", ", year_col, ": World = ",
               signif(worst$world, 6), ", regional sum = ", signif(worst$regions, 6),
               " -- not summed")
    }
  }
}

check_intensive_aggregation(matrix_df, INTENSIVE_VARIABLES)

# ---- write ------------------------------------------------------------------

dir.create(dirname(matrix_file), recursive = TRUE, showWarnings = FALSE)
write.csv(matrix_df, file = matrix_file, row.names = FALSE)

log_step("WRITE", matrix_file, " (", nrow(matrix_df), " rows, ",
         length(unique(matrix_df$Variable)), " variables, ", length(pieces), " runs)")

# A check this script cannot make on its own, for whoever compares matrices:
# Emissions|CO2|AFOLU should equal land-use change plus crop-residue burning,
# with no agricultural-CO2 term -- that term is absent from report.mif.
