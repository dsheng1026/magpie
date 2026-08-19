# |  The reduce phase, second of two: add forest-harvest woodfuel to the emulator
# |  matrix.
# |
# |  Woodfuel -- wood harvested and burned for energy -- is not in the results
# |  file the matrix is built from, so it is read instead from each demand-sweep run's
# |  solver output and added to the matrix's Primary Energy|Biomass rows, matched
# |  on the scenario tags, the region and the year. The matrix createMatrix_MM.R
# |  wrote is left as it is; the result goes to a new *_woodfuel file, and that
# |  file is the one the MESSAGEix linkage reads.
# |
# |  Adding it here does not double count. The mapping also routes a Traditional
# |  Burning term into Primary Energy|Biomass, but that is a different quantity
# |  from forest-harvest woodfuel; the two do not overlap.
# |
# |  Based on woodfuel extraction code from Kristine Karstens.
# |
# |  Run it through the pipeline -- Rscript messageix/run.R matrix NAME -- unless
# |  one step is being debugged on its own. That command runs both halves of the
# |  reduce phase in order and hands them the same experiment, the same run
# |  directory and the same layout. Nothing here can check that: this step matches
# |  its rows against the matrix by scenario tag and region, so a matrix built for
# |  one experiment and woodfuel extracted for another would join on whatever the
# |  two happen to have in common.
# |
# |  Usage, from the MAgPIE model root:
# |    Rscript messageix/R/add_woodfuel_to_matrix.R \
# |      --run-dir output/MESSAGEix_5ff27be8 \
# |      --matrix  /abs/path/to/magpie_input_SSP2_ref.csv
# |
# |    --run-dir DIR      directory holding the demand sweep's run folders; required
# |    --matrix FILE      matrix CSV createMatrix_MM.R wrote, used as given; required
# |    --out FILE         output CSV; default is --matrix with "_woodfuel" appended
# |    --experiment NAME  an experiment of messageix/experiments.R; default "default"
# |    --set key=value    override one setting; repeatable
# |    --layout=legacy    read run folders named the way an older set of runs on
# |                       the cluster names them; for checking this pipeline's
# |                       output against those runs, not for producing anything
# |    --help             print usage and stop
# |
# |  Every option is accepted as "--key value" and as "--key=value".
# |
# |  Nothing is written unless every run in the grid exists and solved, and
# |  nothing is written unless every Primary Energy|Biomass row of the matrix
# |  receives woodfuel: added to some scenarios or regions and not others, it is
# |  worse than none at all, because the result cannot be told apart from a
# |  complete one.
# |
# |  The region names come from the region set's own table,
# |  the one the matrix was renamed with, so the two tables always share a key.
# |  Every region a run reports must appear in that table; one that does not
# |  stops the step, because region sets overlap and a partial match would leave
# |  some regions quietly without woodfuel.
# |
# |  Dependencies: gdx2, magclass, magpie4 (solve status), readr/dplyr/tidyr/
# |  tibble/stringr, and the messageix/R/ layer, loaded through utils_runs.R.

suppressPackageStartupMessages({
  library(gdx2)      # readGDX()
  library(magclass)  # getYears() and as.data.frame() on the magpie object
})

# One line loads the whole messageix/R/ layer: each file there loads the files it
# needs itself, and utils_runs.R sits at the bottom of that chain.
if (!exists("run_modelstat", mode = "function")) source("messageix/R/utils_runs.R")

# Energy content of woodfuel dry matter, GJ per tonne of dry matter. A
# MAgPIE-team value, used deliberately in place of the energy content carried in
# the solver output. It is not a setting because it is a property of the fuel,
# not of an experiment.
WOODFUEL_GJ_PER_TDM <- 18

# The matrix variable woodfuel is added to, and the unit its rows must carry.
TARGET_VARIABLE <- "Primary Energy|Biomass"
TARGET_UNIT     <- "EJ/yr"

# Woodfuel beyond 2110 is outside the MESSAGEix horizon and outside the matrix.
LAST_YEAR <- "y2110"

# The name the global row carries in the matrix. It is what the region-name
# table maps MAgPIE's global code to, and the row this step writes the summed
# regional woodfuel into.
WORLD_NAME <- "World"

# ---- arguments --------------------------------------------------------------

SYNOPSIS <- paste("usage: Rscript messageix/R/add_woodfuel_to_matrix.R --run-dir=DIR",
                  "--matrix=FILE [--out=FILE] [--experiment=NAME] [--set=key=value]",
                  "[--layout=legacy] [--help]")

USAGE <- c(
  "Add the woodfuel each demand-sweep run harvests to the emulator matrix. Woodfuel is",
  "missing from the results file the matrix is built from, so it is read from each",
  "run's solver output instead and added to the Primary Energy|Biomass rows, matched",
  "on scenario tag, region and year. The matrix given as --matrix is left as it is;",
  "the result is written to a new file, and that new file is the one MESSAGEix reads.",
  "",
  "  Rscript messageix/R/add_woodfuel_to_matrix.R --run-dir=DIR --matrix=FILE [flags]",
  "                                                     (from the MAgPIE model root)",
  "",
  "Flags:",
  "  --run-dir=DIR      the directory holding the demand sweep's run folders; required",
  "  --matrix=FILE      the matrix CSV createMatrix_MM.R wrote, used as given; required",
  "  --out=FILE         where to write the result (default: --matrix with _woodfuel before",
  "                     the extension). It may not be --matrix itself.",
  "  --experiment=NAME  an experiment of messageix/experiments.R (default: default)",
  "  --set=key=value    override one setting for this build; repeatable",
  "  --layout=legacy    read run folders named the way an older set of runs on the cluster",
  "                     names them (SSP2_BD00_BE05_G0400demand). It is there to check this",
  "                     pipeline's matrix against those runs without renaming a folder of",
  "                     them; nothing produces runs in that layout.",
  "  --help             this text",
  "",
  "Every option is accepted as --key=value and as --key value.",
  "Nothing is written unless every run of the set is there and solved, every region a",
  "run reports is named in the experiment's region-name table, and every Primary Energy|Biomass",
  "row of the matrix receives woodfuel: added to some scenarios or regions and not",
  "others it is worse than none at all.")

# parse_flags() is the one command-line parser the pipeline uses
# (messageix/R/utils_config.R).
opt <- parse_flags(commandArgs(trailingOnly = TRUE),
                   known      = c("run-dir", "matrix", "out", "experiment", "layout"),
                   flags      = "help",
                   repeatable = "set",
                   usage      = SYNOPSIS)

if (isTRUE(opt$help)) {
  cat(USAGE, sep = "\n")
  cat("\n")
  quit(save = "no")
}

for (required in c("run-dir", "matrix")) {
  if (is.null(opt[[required]])) log_die("--", required, " is required. ", SYNOPSIS)
}

base_output_dir <- opt[["run-dir"]]
layout          <- if (is.null(opt$layout)) "current" else opt$layout
if (!layout %in% c("current", "legacy")) {
  log_die("--layout takes 'current' or 'legacy', got '", layout, "'")
}
matrix_in       <- opt[["matrix"]]
matrix_out      <- if (is.null(opt$out)) sub("\\.csv$", "_woodfuel.csv", matrix_in) else opt$out

pcfg <- config_from_flags(opt, cli_overrides(opt$set))

if (!dir.exists(base_output_dir)) log_die("--run-dir does not exist: ", base_output_dir)
if (!file.exists(matrix_in))      log_die("--matrix does not exist: ", matrix_in)
if (identical(normalizePath(matrix_out, mustWork = FALSE),
              normalizePath(matrix_in,  mustWork = FALSE))) {
  log_die("--out would overwrite --matrix; the unaugmented matrix is the input to this step")
}

# ---- extraction -------------------------------------------------------------

# Woodfuel from one run's solver output as a table of Region, year and
# woodfuel_EJ, still in MAgPIE's own region codes and with years written the way
# the matrix writes them ("1995"). Forestry demand comes out in Mt dry matter per
# yr, so the conversion is Mt -> t (1e6), then t x GJ per t -> EJ (1e-9).
woodfuel_ej_from_gdx <- function(gdx_path) {
  demand <- gdx2::readGDX(gdx_path, "pm_demand_forestry")[, , "woodfuel"]
  ej <- demand * 1e6 * WOODFUEL_GJ_PER_TDM / 1e9
  ej <- ej[, getYears(ej) <= LAST_YEAR, ]
  ej |>
    as.data.frame() |>
    tibble::as_tibble() |>
    dplyr::transmute(Region      = as.character(Region),
                     year        = stringr::str_remove(as.character(Year), "^y"),
                     woodfuel_EJ = as.numeric(Value))
}

# Add the woodfuel table to the matrix's target rows, matched on the two
# scenario tags, the region and the year. The matrix is pivoted long, joined and
# pivoted back, which is what makes the match one join rather than a lookup key
# pasted together per cell.
#
#   mat        the matrix: id columns, then one column per year
#   wf         Region, year, woodfuel_EJ, BIOscen, GHGscen
#   year_cols  the year columns of mat, in the order they appear in it
#
# Returns the matrix with woodfuel added, how many cells changed, and the rows
# of mat that received any -- the caller stops on a target row that received
# none, which is the failure this step exists to catch.
add_woodfuel <- function(mat, wf, year_cols) {
  long <- mat |>
    dplyr::mutate(.row = dplyr::row_number()) |>
    tidyr::pivot_longer(dplyr::all_of(year_cols), names_to = ".column", values_to = ".value") |>
    dplyr::mutate(year = stringr::str_remove(.column, "^X")) |>
    dplyr::left_join(wf, by = c("BIOscen", "GHGscen", "Region", "year"))

  hit <- long$Variable == TARGET_VARIABLE & !is.na(long$woodfuel_EJ)
  long$.value[hit] <- long$.value[hit] + long$woodfuel_EJ[hit]

  # .row keeps the rows apart through the round trip, so two rows that agreed on
  # every id column would not be silently merged into one.
  wide <- long |>
    dplyr::select(-year, -woodfuel_EJ) |>
    tidyr::pivot_wider(names_from = ".column", values_from = ".value") |>
    dplyr::arrange(.row) |>
    dplyr::select(-.row)

  list(matrix = wide, added = sum(hit), touched = sort(unique(long$.row[hit])))
}

# ---- run pre-flight ---------------------------------------------------------

# The runs to read, in the same order the matrix was built in: both halves of the
# reduce phase take the grid from reduce_run_grid() in
# messageix/R/utils_runs.R, which is also where a --run-dir that is not this
# experiment's is caught.
grid <- reduce_run_grid(pcfg, base_output_dir, layout)

# The region names, read from the same table the matrix was renamed with. Two
# different tables would produce two files with no region name in common, and a
# woodfuel step that added nothing to anything.
regions <- region_rename(pcfg)

log_banner("REDUCE - woodfuel", list(
  experiment  = pcfg$experiment,
  layout      = layout,
  runs        = nrow(grid),
  "run dir"   = base_output_dir,
  "energy content" = paste0(WOODFUEL_GJ_PER_TDM, " GJ/tDM"),
  "region names"   = region_names_file(pcfg),
  "matrix in" = matrix_in,
  out         = matrix_out
))

log_step("CHECK", "run folders and solve status")
assert_runs_solved(grid, where = base_output_dir,
                   closing = "Re-run or resubmit the listed runs. The matrix is left unaugmented.")

# ---- extract ----------------------------------------------------------------

log_step("WOODFUEL", "extracting from ", nrow(grid), " runs")
wf_all <- list()
for (k in seq_len(nrow(grid))) {
  be  <- grid$be[k]
  ghg <- grid$ghg[k]
  wf  <- woodfuel_ej_from_gdx(file.path(grid$folder[k], RUN_GDX_FILE))

  # Every region the run reports has to be named in the table. A partial match
  # is the dangerous case, not a total mismatch: region sets overlap heavily --
  # R10 and R12 share eleven of their twelve codes -- so a run at the wrong
  # resolution would have woodfuel added for the codes that happen to agree and
  # silently none for the rest. Both sides are named here because the fix is
  # either a different set of runs or a different region-name table.
  unnamed <- setdiff(unique(wf$Region), names(regions))
  if (length(unnamed)) {
    log_die("run ", grid$title[k], " reports region(s) ", paste(unnamed, collapse = ", "),
            " that ", region_names_file(pcfg), " does not name. It names ",
            paste(names(regions), collapse = ", "),
            ". Either this run is at another region resolution than this experiment, or the ",
            "table ",
            "is missing rows; either way some regions would be left without woodfuel.")
  }

  # World is the plain sum over regions: woodfuel is extensive. A code the table
  # already maps to World -- MAgPIE's own global code, should a run ever report
  # one -- is left out of the sum and out of the result, because counting it
  # would double the global total and leave two rows competing for the same
  # matrix cell. The sum over the regions is the same quantity anyway.
  regional <- wf |>
    dplyr::filter(regions[Region] != WORLD_NAME) |>
    dplyr::mutate(Region = unname(regions[Region]))
  world <- regional |>
    dplyr::group_by(year) |>
    dplyr::summarise(woodfuel_EJ = sum(woodfuel_EJ, na.rm = TRUE), .groups = "drop") |>
    dplyr::mutate(Region = WORLD_NAME)
  wf_all[[k]] <- dplyr::bind_rows(regional, world) |>
    dplyr::mutate(BIOscen = bio_scen_tag(be), GHGscen = ghg_scen_tag(ghg))
}
wf_all <- dplyr::bind_rows(wf_all)
log_step("WOODFUEL", nrow(wf_all), " values collected")

# ---- add to the matrix ------------------------------------------------------

log_step("MATRIX", "adding woodfuel to '", TARGET_VARIABLE, "'")
mat <- readr::read_csv(matrix_in, col_types = readr::cols(), name_repair = "minimal",
                       guess_max = Inf, progress = FALSE)

# Year column headers are written bare ("1995"); a file that has been through a
# reader which repairs names carries them as "X1995", and both forms map back to
# the bare year the woodfuel table uses.
year_cols <- stringr::str_subset(names(mat), "^X?[0-9]{4}$")

# Woodfuel is added to these columns, so they have to be numbers. A column that
# arrived as text carries something that is not a number, and adding to it would
# either fail here or quietly write NA into the matrix.
not_numeric <- year_cols[!vapply(mat[year_cols], is.numeric, logical(1))]
if (length(not_numeric)) {
  log_die("year column(s) ", paste(not_numeric, collapse = ", "), " of ", matrix_in,
          " are not numeric; woodfuel cannot be added to them")
}

is_pe <- mat$Variable == TARGET_VARIABLE
if (!any(is_pe)) log_die("target variable not found in ", matrix_in, ": ", TARGET_VARIABLE)

# The addition is in EJ/yr. A row in any other unit would be silently corrupted
# by it, so a unit mismatch stops the run rather than warning.
if (!"Unit" %in% names(mat)) log_die("matrix has no Unit column: ", matrix_in)
units_seen <- unique(mat$Unit[is_pe])
if (!all(units_seen == TARGET_UNIT)) {
  log_die(TARGET_VARIABLE, " carries unit(s) ", paste(units_seen, collapse = ", "),
          " in ", matrix_in, "; woodfuel is added in ", TARGET_UNIT)
}

augmented <- add_woodfuel(mat, wf_all, year_cols)
mat <- augmented$matrix
log_step("MATRIX", augmented$added, " cells updated across ", sum(is_pe), " ",
         TARGET_VARIABLE, " rows")

# Every Primary Energy|Biomass row must have received woodfuel in at least one
# year. A row left untouched means its scenario tag, region or years find no
# match in the woodfuel table, and the matrix would then carry woodfuel for some
# scenarios and regions and not others -- which nothing downstream can tell
# apart from a complete file. The rows are listed so the disagreeing key is
# visible rather than guessed at.
missed <- setdiff(which(is_pe), augmented$touched)
if (length(missed)) {
  shown <- utils::head(missed, 20L)
  log_report(c(
    paste0(length(missed), " of ", sum(is_pe), " ", TARGET_VARIABLE,
           " row(s) in ", matrix_in, " received no woodfuel in any year:"),
    paste0("    ", mat$BIOscen[shown], " ", mat$GHGscen[shown], " ", mat$Region[shown]),
    if (length(missed) > 20L) paste0("    ... and ", length(missed) - 20L, " more"),
    paste0("  The woodfuel table covers ", length(unique(wf_all$Region)), " region(s), ",
           length(unique(wf_all$BIOscen)), " bioenergy and ", length(unique(wf_all$GHGscen)),
           " GHG price tag(s). Nothing was written.")))
  log_die("woodfuel is missing for ", length(missed), " ", TARGET_VARIABLE,
          " row(s); they are listed above")
}

# ---- write ------------------------------------------------------------------

dir.create(dirname(matrix_out), recursive = TRUE, showWarnings = FALSE)
write.csv(mat, file = matrix_out, row.names = FALSE)
log_step("WRITE", matrix_out)

# A spot check for whoever compares the two matrices: Primary Energy|Biomass at
# (BIO00, GHG000, World, 2050) in the *_woodfuel file should exceed the same cell
# of the input matrix by exactly the summed regional woodfuel, in EJ per yr, of
# that run and year.
