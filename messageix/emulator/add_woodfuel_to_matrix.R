# |  Stage 4b: add forest-harvest woodfuel to the emulator matrix.
# |
# |  Woodfuel is not reported in report.mif, so it is read from each stage-3
# |  run's fulldata.gdx and added to the matrix's Primary Energy|Biomass rows,
# |  matched on scenario tag, region and year. The matrix createMatrix_MM.R wrote
# |  is left untouched; the result goes to a new *_woodfuel file, which is the
# |  file the MESSAGEix linkage consumes.
# |
# |  Woodfuel is not captured by the Traditional Burning component of
# |  Primary Energy|Biomass that the mapping also feeds: the two are distinct
# |  quantities and adding woodfuel here does not double count
# |  (messageix/docs/decisions.md, Q1).
# |
# |  Based on woodfuel extraction code from Kristine Karstens.
# |
# |  Usage, from the MAgPIE model root:
# |    Rscript messageix/emulator/add_woodfuel_to_matrix.R \
# |      --run-dir output/MESSAGEix_5ff27be8/SSP2_BD00 \
# |      --matrix  /abs/path/to/magpie_input_SSP2_ref.csv
# |
# |    --run-dir DIR      directory holding the stage-3 run folders; required
# |    --matrix FILE      matrix CSV createMatrix_MM.R wrote, used as given; required
# |    --out FILE         output CSV; default is --matrix with "_woodfuel" appended
# |    --preset NAME      narrative column of the preset CSV; default "default"
# |    --csv PATH         preset CSV; default default_preset_csv()
# |    --help             print usage and stop
# |
# |  Every option is accepted as "--key value" and as "--key=value".
# |
# |  Nothing is written unless every run in the grid exists and solved: woodfuel
# |  added to some scenarios and not others is worse than none at all.
# |
# |  Dependencies: gdx2, magclass, magpie4 (solve status), and
# |  messageix/R/{utils_log,utils_paths,utils_config,utils_runs}.R.

suppressPackageStartupMessages({
  library(gdx2)      # readGDX()
  library(magclass)  # getYears() and as.data.frame() on the magpie object
})

if (!exists("log_die", mode = "function"))        source("messageix/R/utils_log.R")
if (!exists("run_title", mode = "function"))      source("messageix/R/utils_paths.R")
if (!exists("resolve_config", mode = "function")) source("messageix/R/utils_config.R")
if (!exists("run_modelstat", mode = "function"))  source("messageix/R/utils_runs.R")

GDX_NAME <- "fulldata.gdx"

# Energy content of woodfuel dry matter, GJ per tonne. A MAgPIE-team value that
# deliberately overrides the fm_attributes entry carried in the gdx. Not exposed
# in the preset: it is a property of the fuel, not of a scenario.
WOODFUEL_GJ_PER_TDM <- 18

# The matrix variable woodfuel is added to, and the unit its rows must carry.
TARGET_VARIABLE <- "Primary Energy|Biomass"
TARGET_UNIT     <- "EJ/yr"

# Woodfuel beyond 2110 is outside the MESSAGEix horizon and outside the matrix.
LAST_YEAR <- "y2110"

# ---- arguments --------------------------------------------------------------

USAGE <- paste(
  "Usage: Rscript messageix/emulator/add_woodfuel_to_matrix.R \\",
  "         --run-dir <directory holding the stage-3 run folders> \\",
  "         --matrix  <matrix CSV createMatrix_MM.R wrote> \\",
  "        [--out <output CSV>] \\",
  paste0("        [--preset default] [--csv ", default_preset_csv(), "] [--help]"),
  "",
  "Every option is accepted as --key value and as --key=value.",
  sep = "\n")

# parse_flags() is the pipeline's one CLI parser (messageix/R/utils_config.R).
# "--preset-csv" is an unadvertised alias of "--csv": the flag name the preset
# CSV goes by is "--csv" in every entry point, and the alias keeps a command
# written against the longer spelling working.
opt <- parse_flags(commandArgs(trailingOnly = TRUE),
                   known   = c("run-dir", "matrix", "out", "preset", "csv"),
                   flags   = "help",
                   aliases = c("preset-csv" = "csv"),
                   usage   = USAGE)

if (isTRUE(opt$help)) {
  cat(USAGE, "\n", sep = "")
  quit(save = "no")
}

# stop() truncates its message at options("warning.length"), which a list of 84
# run names overruns. Failure reports are printed in full first; the fatal line
# then only names the count.
print_report <- function(lines) {
  cat(paste(lines, collapse = "\n"), "\n", sep = "")
  utils::flush.console()
}

for (required in c("run-dir", "matrix")) {
  if (is.null(opt[[required]])) log_die("--", required, " is required\n", USAGE)
}

base_output_dir <- opt[["run-dir"]]
matrix_in       <- opt[["matrix"]]
matrix_out      <- if (is.null(opt$out)) sub("\\.csv$", "_woodfuel.csv", matrix_in) else opt$out

pcfg <- resolve_config(preset = if (is.null(opt$preset)) "default" else opt$preset,
                       csv    = if (is.null(opt$csv)) default_preset_csv() else opt$csv)

if (!dir.exists(base_output_dir)) log_die("--run-dir does not exist: ", base_output_dir)
if (!file.exists(matrix_in))      log_die("--matrix does not exist: ", matrix_in)
if (identical(normalizePath(matrix_out, mustWork = FALSE),
              normalizePath(matrix_in,  mustWork = FALSE))) {
  log_die("--out would overwrite --matrix; the unaugmented matrix is the input to this step")
}

if (basename(base_output_dir) != preflag(pcfg)) {
  log_warn("--run-dir is named '", basename(base_output_dir), "' but preset '",
           pcfg$preset, "' describes '", preflag(pcfg), "'")
}

# ---- extraction -------------------------------------------------------------

# Woodfuel from one run's gdx as a tidy frame (Region, year, woodfuel_EJ), with
# MAgPIE-native region codes and matrix-style years ("1995").
# pm_demand_forestry is Mt DM per year: Mt -> t is 1e6, GJ -> EJ is 1e-9.
woodfuel_ej_from_gdx <- function(gdx_path) {
  demand <- gdx2::readGDX(gdx_path, "pm_demand_forestry")[, , "woodfuel"]
  ej <- demand * 1e6 * WOODFUEL_GJ_PER_TDM / 1e9
  ej <- ej[, getYears(ej) <= LAST_YEAR, ]
  d  <- as.data.frame(ej)
  data.frame(Region      = as.character(d$Region),
             year        = sub("^y", "", as.character(d$Year)),
             woodfuel_EJ = as.numeric(d$Value),
             stringsAsFactors = FALSE)
}

# ---- run pre-flight ---------------------------------------------------------

# Bioenergy price varies fastest, GHG price slowest -- the order createMatrix_MM.R
# builds the matrix in.
grid <- expand.grid(be = pcfg$be_prices, ghg = pcfg$ghg_prices, KEEP.OUT.ATTRS = FALSE)
grid$title  <- vapply(seq_len(nrow(grid)),
                      function(k) run_title(pcfg, 3L, be = grid$be[k], ghg = grid$ghg[k]),
                      character(1))
grid$folder <- file.path(base_output_dir, grid$title)

log_banner("WOODFUEL", list(
  preset      = pcfg$preset,
  narrative   = preflag(pcfg),
  runs        = nrow(grid),
  "run dir"   = base_output_dir,
  "energy content" = paste0(WOODFUEL_GJ_PER_TDM, " GJ/tDM"),
  "matrix in" = matrix_in,
  out         = matrix_out
))

log_step("CHECK", "run folders and solve status")
missing_gdx <- character(0)
unsolved    <- character(0)
unverified  <- character(0)

for (k in seq_len(nrow(grid))) {
  gdx_path <- file.path(grid$folder[k], GDX_NAME)
  if (!file.exists(gdx_path)) {
    missing_gdx <- c(missing_gdx, grid$title[k])
    next
  }
  status <- run_modelstat(gdx_path)
  if (!length(status)) {
    unverified <- c(unverified, grid$title[k])
  } else if (!all(status %in% SOLVED_MODELSTAT)) {
    unsolved <- c(unsolved, paste0(grid$title[k], " (modelstat ",
                                   paste(sort(unique(setdiff(status, SOLVED_MODELSTAT))),
                                         collapse = "/"), ")"))
  }
}

if (length(missing_gdx) || length(unsolved)) {
  report <- c(
    paste0(nrow(grid), " runs expected under ", base_output_dir, "; the grid is incomplete."),
    if (length(missing_gdx)) paste0("  no ", GDX_NAME, " (", length(missing_gdx), "):\n    ",
                                    paste(missing_gdx, collapse = "\n    ")),
    if (length(unsolved))    paste0("  did not solve (", length(unsolved), "):\n    ",
                                    paste(unsolved, collapse = "\n    ")),
    "Re-run or resubmit the listed runs. The matrix is left unaugmented."
  )
  print_report(report)
  log_die(length(missing_gdx) + length(unsolved), " of ", nrow(grid),
          " runs are missing or unsolved; see the list above")
}

if (length(unverified)) {
  log_warn("solve status unreadable for ", length(unverified), " run(s); ", GDX_NAME,
           " carries no modelstat symbol, so those runs are checked for existence only:\n    ",
           paste(unverified, collapse = "\n    "))
}

# ---- extract ----------------------------------------------------------------

log_step("WOODFUEL", "extracting from ", nrow(grid), " runs")
wf_all <- list()
for (k in seq_len(nrow(grid))) {
  be  <- grid$be[k]
  ghg <- grid$ghg[k]
  wf  <- woodfuel_ej_from_gdx(file.path(grid$folder[k], GDX_NAME))

  # Guards against a gdx from another region set (H12 rather than R12), which
  # would otherwise match nothing and add nothing.
  if (!length(intersect(wf$Region, names(region_rename)))) {
    log_die("run ", grid$title[k], ": gdx regions are not the expected set: ",
            paste(unique(wf$Region), collapse = ", "))
  }

  # World is the plain sum over regions: woodfuel is extensive.
  world <- aggregate(woodfuel_EJ ~ year, data = wf, FUN = sum, na.rm = TRUE)
  world$Region <- "World"
  wf <- rbind(wf, world[, c("Region", "year", "woodfuel_EJ")])

  wf$Region  <- ifelse(wf$Region %in% names(region_rename),
                       region_rename[wf$Region], wf$Region)
  wf$BIOscen <- bio_scen_tag(be)
  wf$GHGscen <- ghg_scen_tag(ghg)
  wf_all[[k]] <- wf
}
wf_all <- do.call(rbind, wf_all)
log_step("WOODFUEL", nrow(wf_all), " values collected")

# ---- add to the matrix ------------------------------------------------------

log_step("MATRIX", "adding woodfuel to '", TARGET_VARIABLE, "'")
mat <- read.csv(matrix_in, header = TRUE, check.names = FALSE, stringsAsFactors = FALSE)

# Year column headers survive read.csv as "1995" or "X1995" depending on
# check.names; both forms map back to the bare year the woodfuel table uses.
year_cols <- grep("^X?[0-9]{4}$", names(mat), value = TRUE)
year_of   <- setNames(sub("^X", "", year_cols), year_cols)

wf_all$key <- with(wf_all, paste(BIOscen, GHGscen, Region, year, sep = "|"))
wf_lookup  <- setNames(wf_all$woodfuel_EJ, wf_all$key)

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

added <- 0L
for (r in which(is_pe)) {
  for (yc in year_cols) {
    key <- paste(mat$BIOscen[r], mat$GHGscen[r], mat$Region[r], year_of[[yc]], sep = "|")
    add <- wf_lookup[key]
    if (!is.na(add)) {
      mat[r, yc] <- as.numeric(mat[r, yc]) + as.numeric(add)
      added <- added + 1L
    }
  }
}
log_step("MATRIX", added, " cells updated across ", sum(is_pe), " ", TARGET_VARIABLE, " rows")

# The full expectation is (rows) x (years present in both the gdx and the
# matrix). Far fewer means a region-name or scenario-tag mismatch between the
# two tables, which the run-folder and region guards above are meant to catch.
if (added == 0L) log_die("no cells matched; the woodfuel table and the matrix share no key")

# ---- write ------------------------------------------------------------------

dir.create(dirname(matrix_out), recursive = TRUE, showWarnings = FALSE)
write.csv(mat, file = matrix_out, row.names = FALSE)
log_step("WRITE", matrix_out)

# A spot check for whoever compares the two matrices: Primary Energy|Biomass at
# (BIO00, GHG000, World, 2050) in the *_woodfuel file exceeds the same cell of
# the input matrix by exactly the summed regional woodfuel EJ of that run-year.
