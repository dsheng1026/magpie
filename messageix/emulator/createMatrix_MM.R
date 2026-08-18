# |  Stage 4a: build the emulator matrix from the stage-3 run grid.
# |
# |  One report.mif per run is mapped through MM_linkage_mapping.csv by
# |  iamc::write.reportProject(), tagged with its scenario coordinates and
# |  concatenated into a single CSV that MESSAGEix reads. report.mif is the only
# |  data source; woodfuel is absent from it and is added afterwards by
# |  add_woodfuel_to_matrix.R.
# |
# |  A single in-memory pass: map, read, tag, combine, write. No intermediate
# |  mapped mif is kept on disk.
# |
# |  Usage, from the MAgPIE model root:
# |    Rscript messageix/emulator/createMatrix_MM.R \
# |      --run-dir output/MESSAGEix_5ff27be8/SSP2_BD00 \
# |      --out     /abs/path/to/magpie_input_SSP2_ref.csv
# |
# |    --run-dir DIR      directory holding the stage-3 run folders; required
# |    --out FILE         matrix CSV to write, used exactly as given; required
# |    --preset NAME      narrative column of the preset CSV; default "default"
# |    --csv PATH         preset CSV; default default_preset_csv()
# |    --allow-unmapped   report unmapped mapping variables instead of stopping
# |    --help             print usage and stop
# |
# |  Every option is accepted as "--key value" and as "--key=value".
# |
# |  The grid, the run names and the matrix scenario tags all come from the
# |  preset, so the same command builds any narrative. Nothing is written unless
# |  every run in the grid exists, solved, and mapped completely: a partial
# |  matrix is indistinguishable from a complete one downstream.
# |
# |  Dependencies: iamc, stringr, gdx2, magpie4 (solve status), and
# |  messageix/R/{utils_log,utils_paths,utils_config,utils_runs}.R.

suppressPackageStartupMessages({
  library(iamc)      # write.reportProject()
  library(stringr)   # str_match() on the mif's own Scenario field
})

if (!exists("log_die", mode = "function"))        source("messageix/R/utils_log.R")
if (!exists("run_title", mode = "function"))      source("messageix/R/utils_paths.R")
if (!exists("resolve_config", mode = "function")) source("messageix/R/utils_config.R")
if (!exists("run_modelstat", mode = "function"))  source("messageix/R/utils_runs.R")

# The mapping travels with the scripts that use it, so it is addressed relative
# to the model root rather than passed in: it is part of the pipeline, not a
# per-run choice.
MAP_FILE <- "messageix/emulator/MM_linkage_mapping.csv"

MIF_NAME <- "report.mif"
GDX_NAME <- "fulldata.gdx"

# Intensive variables of the mapping: per-unit quantities that must not be
# summed across regions. All 81 mapping rows carry spatial = "reg+glo", which is
# correct only where write.reportProject passes the mif's own World row through.
# check_intensive_aggregation() below tests that on the finished matrix.
INTENSIVE_VARIABLES <- c("Price|Carbon|CO2",
                         "Price|Primary Energy|Biomass",
                         "Biodiversity|BII",
                         "Landuse intensity indicator Tau")

# ---- arguments --------------------------------------------------------------

USAGE <- paste(
  "Usage: Rscript messageix/emulator/createMatrix_MM.R \\",
  "         --run-dir <directory holding the stage-3 run folders> \\",
  "         --out     <matrix CSV to write> \\",
  paste0("        [--preset default] [--csv ", default_preset_csv(), "] \\"),
  "        [--allow-unmapped] [--help]",
  "",
  "Every option is accepted as --key value and as --key=value.",
  sep = "\n")

# parse_flags() is the pipeline's one CLI parser (messageix/R/utils_config.R).
# "--preset-csv" is an unadvertised alias of "--csv": the flag name the preset
# CSV goes by is "--csv" in every entry point, and the alias keeps a command
# written against the longer spelling working.
opt <- parse_flags(commandArgs(trailingOnly = TRUE),
                   known   = c("run-dir", "out", "preset", "csv"),
                   flags   = c("allow-unmapped", "help"),
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

for (required in c("run-dir", "out")) {
  if (is.null(opt[[required]])) log_die("--", required, " is required\n", USAGE)
}

base_output_dir <- opt[["run-dir"]]
matrix_file     <- opt[["out"]]
allow_unmapped  <- isTRUE(opt[["allow-unmapped"]])

pcfg <- resolve_config(preset = if (is.null(opt$preset)) "default" else opt$preset,
                       csv    = if (is.null(opt$csv)) default_preset_csv() else opt$csv)

if (!dir.exists(base_output_dir)) log_die("--run-dir does not exist: ", base_output_dir)
if (!file.exists(MAP_FILE))       log_die("mapping file not found: ", MAP_FILE,
                                          " (run from the MAgPIE model root)")

# The mapping converts prices back out of MAgPIE's USD2017 with the reciprocal
# of pipeline$currency_2005_to_2017. The deflator and its reciprocal live in two
# different files and nothing else ties them together, so a preset that moved
# one at a MAgPIE base-year change would emit a matrix whose price rows are
# converted with the other. The check makes that a stop rather than a silence.
assert_price_factor <- function(mapping_path, pcfg, tolerance = 1e-6) {
  header <- readLines(mapping_path, n = 1L, warn = FALSE)
  sep <- if (grepl(";", header, fixed = TRUE)) ";" else ","
  map <- utils::read.table(mapping_path, sep = sep, header = TRUE, quote = "\"",
                           comment.char = "", colClasses = "character",
                           check.names = FALSE, stringsAsFactors = FALSE)
  rows <- map[startsWith(map$Variable, "Price|"), , drop = FALSE]
  if (!nrow(rows)) {
    log_die("no target variable starting with 'Price|' in ", mapping_path,
            "; pipeline$currency_2005_to_2017 has nothing to agree with")
  }
  wanted <- 1 / pcfg$currency_2005_to_2017
  found <- suppressWarnings(as.numeric(rows$factor))
  bad <- which(is.na(found) | abs(found - wanted) > tolerance)
  if (length(bad)) {
    log_die("currency mismatch: pipeline$currency_2005_to_2017 = ", pcfg$currency_2005_to_2017,
            " in ", pcfg$csv, " implies a factor of ", signif(wanted, 9),
            " on the price rows of ", mapping_path, ", which carry ", rows$factor[bad],
            " for ", rows$Variable[bad],
            ". The deflator into MAgPIE and its reciprocal out of MAgPIE move together.")
  }
  invisible(TRUE)
}

assert_price_factor(MAP_FILE, pcfg)

# The run folders sit one level below a folder named for the narrative. A
# mismatch means the preset and the run directory describe different narratives;
# the run pre-flight below then fails with the full list of names it looked for.
if (basename(base_output_dir) != preflag(pcfg)) {
  log_warn("--run-dir is named '", basename(base_output_dir), "' but preset '",
           pcfg$preset, "' describes '", preflag(pcfg), "'")
}

# The matrix is built from the stage-3 training set; matrix_run_suffix records
# which stage that is and must agree with the names the contract builds.
if (!endsWith(run_title(pcfg, 3L, be = pcfg$be_prices[1], ghg = pcfg$ghg_prices[1]),
              pcfg$matrix_run_suffix)) {
  log_die("pipeline$matrix_run_suffix ('", pcfg$matrix_run_suffix,
          "') is not the suffix of the stage-3 run titles")
}

# ---- mapping ----------------------------------------------------------------

# The one iamc-dependent step: read a run's report.mif, apply the mapping, write
# a mapped mif to a temporary path. Replacing iamc with piamInterfaces means
# replacing this function body and nothing else.
apply_mapping <- function(mif_path, mapping_path, out_path, log_path) {
  write.reportProject(
    mif         = mif_path,
    mapping     = mapping_path,
    file        = out_path,
    missing_log = log_path
  )
  invisible(out_path)
}

# Mapping variables the run did not report. write.reportProject always writes a
# "#--- ... ---#" banner into the log, so a non-empty file is not evidence of a
# miss; only non-comment, non-blank lines are.
unmapped_variables <- function(log_path) {
  if (!file.exists(log_path)) return(character(0))
  grep("^\\s*#|^\\s*$", readLines(log_path, warn = FALSE), value = TRUE, invert = TRUE)
}

# ---- build ------------------------------------------------------------------

# Bioenergy price varies fastest, GHG price slowest. The order sets the row
# order of the matrix CSV and matches the golden reference.
grid <- expand.grid(be = pcfg$be_prices, ghg = pcfg$ghg_prices, KEEP.OUT.ATTRS = FALSE)
grid$title  <- vapply(seq_len(nrow(grid)),
                      function(k) run_title(pcfg, 3L, be = grid$be[k], ghg = grid$ghg[k]),
                      character(1))
grid$folder <- file.path(base_output_dir, grid$title)

log_banner("MATRIX", list(
  preset     = pcfg$preset,
  narrative  = preflag(pcfg),
  runs       = nrow(grid),
  "run dir"  = base_output_dir,
  mapping    = MAP_FILE,
  out        = matrix_file
))

# Every run is checked before any is read: a matrix built from a subset of the
# grid is silently wrong downstream, so the gaps are collected and reported in
# full rather than one at a time.
log_step("CHECK", "run folders and solve status")
missing_mif <- character(0)
missing_gdx <- character(0)
unsolved    <- character(0)
unverified  <- character(0)

for (k in seq_len(nrow(grid))) {
  mif_path <- file.path(grid$folder[k], MIF_NAME)
  gdx_path <- file.path(grid$folder[k], GDX_NAME)
  if (!file.exists(mif_path)) missing_mif <- c(missing_mif, grid$title[k])
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

if (length(missing_mif) || length(missing_gdx) || length(unsolved)) {
  report <- c(
    paste0(nrow(grid), " runs expected under ", base_output_dir, "; the grid is incomplete."),
    if (length(missing_mif)) paste0("  no ", MIF_NAME, " (", length(missing_mif), "):\n    ",
                                    paste(missing_mif, collapse = "\n    ")),
    if (length(missing_gdx)) paste0("  no ", GDX_NAME, " (", length(missing_gdx), "):\n    ",
                                    paste(missing_gdx, collapse = "\n    ")),
    if (length(unsolved))    paste0("  did not solve (", length(unsolved), "):\n    ",
                                    paste(unsolved, collapse = "\n    ")),
    "Re-run or resubmit the listed runs. No matrix is written."
  )
  print_report(report)
  log_die(length(unique(c(missing_mif, missing_gdx))) + length(unsolved), " of ", nrow(grid),
          " runs are missing or unsolved; see the list above")
}

if (length(unverified)) {
  log_warn("solve status unreadable for ", length(unverified), " run(s); ", GDX_NAME,
           " exists but carries no modelstat symbol, so those runs are checked for ",
           "existence only:\n    ", paste(unverified, collapse = "\n    "))
}
log_step("CHECK", nrow(grid), " runs present and solved")

id_cols <- c("Region", "Variable", "Unit", "SSPscen", "GHGscen", "BIOscen", "SDGscen")

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

  df <- read.csv(tmp_map, sep = ";", check.names = FALSE, stringsAsFactors = FALSE)
  unlink(c(tmp_map, tmp_log))

  # Drop the trailing empty column the mif export leaves behind.
  df <- df[, !grepl("^X?$", names(df)) & names(df) != "", drop = FALSE]

  # The mif carries its own Scenario field ("SSP2_BD00_BE45_G4000demand"), which
  # is the run title MAgPIE wrote. Reading the tags from the data and checking
  # them against the folder catches a run folder holding another run's report.
  tag_be  <- as.integer(str_match(df$Scenario[1], "_BE(\\d+)_")[, 2])
  tag_ghg <- as.integer(str_match(df$Scenario[1], "_G(\\d+)")[, 2])
  if (is.na(tag_be) || is.na(tag_ghg) || tag_be != be || tag_ghg != ghg) {
    log_die("run folder ", grid$title[k], " holds a report for scenario '",
            df$Scenario[1], "'")
  }

  df$SSPscen <- pcfg$matrix_ssp_scen
  df$GHGscen <- ghg_scen_tag(ghg)
  df$BIOscen <- bio_scen_tag(be)
  df$SDGscen <- pcfg$matrix_sdg_scen

  hit <- df$Region %in% names(region_rename)
  df$Region[hit] <- region_rename[df$Region[hit]]

  # Model and Scenario are not part of the target format; the four tag columns
  # carry the same information in the shape MESSAGEix reads.
  df$Model <- NULL
  df$Scenario <- NULL

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
  print_report(report)
  if (allow_unmapped) {
    log_warn(length(variables), " mapping variable(s) unmapped; --allow-unmapped is set")
  } else {
    log_die(length(variables), " mapping variable(s) unmapped; see the list above")
  }
}

matrix_df <- do.call(rbind, pieces)

# No two rows may share a scenario coordinate: a duplicate means two runs were
# tagged identically and one of them is silently unreachable.
dup_n <- sum(duplicated(matrix_df[id_cols]))
if (dup_n > 0) log_die(dup_n, " rows share an id-column key")

# Id columns first, then year columns in ascending numeric order.
year_cols <- setdiff(names(matrix_df), id_cols)
year_cols <- year_cols[order(as.numeric(year_cols))]
matrix_df <- matrix_df[, c(id_cols, year_cols)]

# ---- structural checks ------------------------------------------------------

# Intensive variables must not be region-summed. Where the mapping's "reg+glo"
# passes the mif's own World row through, the World value sits inside the range
# of the regional values; where it sums them, it equals their total (roughly 13x
# a typical region for R12). The comparison runs on the scenario and year with
# the largest regional total, so a variable that is zero at a zero price is
# still tested somewhere it has signal.
check_intensive_aggregation <- function(df, variables) {
  years <- setdiff(names(df), id_cols)
  year_col <- years[which.max(as.numeric(years))]
  for (v in variables) {
    rows <- df[df$Variable == v, , drop = FALSE]
    if (!nrow(rows)) next
    key    <- paste(rows$BIOscen, rows$GHGscen)
    value  <- suppressWarnings(as.numeric(rows[[year_col]]))
    is_glo <- rows$Region == "World"
    if (!any(is_glo) || !any(!is_glo)) next
    reg_sum <- tapply(value[!is_glo], key[!is_glo], sum, na.rm = TRUE)
    glo     <- tapply(value[is_glo],  key[is_glo],  sum, na.rm = TRUE)
    scen    <- names(reg_sum)[which.max(abs(reg_sum))]
    if (is.null(scen) || is.na(glo[scen]) || is.na(reg_sum[scen])) next
    tolerance <- 1e-6 * max(abs(reg_sum[scen]), 1)
    if (abs(glo[scen] - reg_sum[scen]) <= tolerance) {
      log_warn(v, " at ", scen, ", ", year_col, ": World = ", signif(glo[scen], 6),
               " equals the sum over regions = ", signif(reg_sum[scen], 6),
               ". An intensive variable is being summed; set spatial = 'reg' for its ",
               "row in ", MAP_FILE, ".")
    } else {
      log_step("CHECK", v, " at ", scen, ", ", year_col, ": World = ",
               signif(glo[scen], 6), ", regional sum = ", signif(reg_sum[scen], 6),
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
