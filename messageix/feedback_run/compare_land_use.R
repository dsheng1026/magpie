# |  Put the feedback run's land use next to MESSAGE's, in one table.
# |
# |    feedback run report.mif  ->  MM_linkage_mapping.csv  ->  MESSAGEix variables
# |    MESSAGE IAMC csv         ->  the same variables
# |      ->  land_use_comparison.csv  (both values and their difference, per cell)
# |      ->  comparison_coverage.csv  (what only one side reported)
# |
# |  The mapping is the one the emulator matrix is built with, so the two sides
# |  are compared in the vocabulary the linkage itself uses. Nothing is aggregated
# |  beyond what the mapping does, and no region or year is dropped.
# |
# |  Scope: this writes the comparison. It does not grade it. There is no
# |  threshold, no tolerance and no verdict here on purpose: what counts as an
# |  acceptable difference depends on the variable, the emulator and what the run
# |  is for, and a number in this file that looked like a pass mark would be
# |  read as one. A person reads the table.
# |
# |  Usage, from the MAgPIE model root:
# |    Rscript messageix/feedback_run/compare_land_use.R \
# |      --run-dir output/MESSAGEix_5ff27be8/feedback/feedback_feedback \
# |      --iamc /abs/path/message_output.csv
# |
# |    --run-dir DIR      the feedback run's folder, holding report.mif; required
# |    --iamc PATH        the MESSAGE output the run was prepared from; required
# |    --variable VAR     restrict to this MESSAGEix variable; repeatable
# |    --scenario NAME    the MESSAGE scenario to read, when the file holds several
# |    --out-dir DIR      default <run-dir>/feedback_comparison
# |    --experiment NAME  an experiment of messageix/experiments.R
# |    --set key=value    override one setting; repeatable
# |    --allow-unmapped   report mapping variables the run did not write, instead
# |                       of stopping
# |    --help
# |
# |  Every option is accepted as --key value and as --key=value.
# |
# |  Interface
# |    run_report(run_dir)                   -> chr(1); the run's report.mif
# |    mapped_report(mif, mapping, ...)      -> df; report.mif in MESSAGEix variables
# |    magpie_side(run_dir, pcfg, ...)       -> df(variable, region, year, magpie)
# |    message_side(iamc, variables, scenario) -> df(variable, region, year, message)
# |    compare_land_use(pcfg, ...)           -> named chr; the files written
# |
# |  Dependencies: iamc for write.reportProject(), readr/dplyr/tidyr, and
# |  messageix/feedback_prep/prep_carbon_price.R for read_iamc(), which brings the
# |  messageix/R/ config layer with it. Run from the MAgPIE model root.

if (!exists("read_iamc", mode = "function")) {
  source("messageix/feedback_prep/prep_carbon_price.R")
}
# write.reportProject() is qualified rather than attached: nothing in this source
# chain loads iamc, and the bare call died on every invocation.
if (!requireNamespace("iamc", quietly = TRUE)) {
  log_die("the iamc package is not installed; compare_land_use.R needs it for ",
          "write.reportProject(), the same mapping call createMatrix_MM.R makes")
}

MAP_FILE <- "messageix/data/MM_linkage_mapping.csv"

run_report <- function(run_dir) {
  if (!dir.exists(run_dir)) log_die("--run-dir: ", run_dir, " does not exist")
  mif <- file.path(run_dir, "report.mif")
  if (!file.exists(mif)) {
    log_die("--run-dir: ", run_dir, " holds no report.mif. The run has not finished, or its ",
            "output modules did not include the reporting step (cfg$output)")
  }
  mif
}

# report.mif through the linkage mapping, in MESSAGEix variable names. Same call
# createMatrix_MM.R makes, and the same package, so the two cannot disagree about
# what a variable means.
mapped_report <- function(mif, mapping, allow_unmapped = FALSE) {
  out <- tempfile(fileext = ".mif")
  log <- tempfile(fileext = ".log")
  on.exit(unlink(c(out, log)), add = TRUE)
  iamc::write.reportProject(mif = mif, mapping = mapping, file = out, missing_log = log)

  # The same parse as unmapped_variables() in createMatrix_MM.R. That file cannot be
  # sourced (it runs its build at top level), so this is a copy; change both together.
  missing <- if (file.exists(log)) {
    grep("^\\s*#|^\\s*$", readLines(log, warn = FALSE), value = TRUE, invert = TRUE)
  } else character(0)
  if (length(missing)) {
    msg <- c(">> the mapping asked for variables the run did not report:", missing)
    if (isTRUE(allow_unmapped)) {
      log_report(msg)
      log_warn(length(missing), " mapping variable(s) unmapped (--allow-unmapped)")
    } else {
      log_report(msg)
      log_die(length(missing), " mapping variable(s) are absent from ", mif,
              ". A comparison missing rows on one side reads as agreement. ",
              "Pass --allow-unmapped to report them and carry on")
    }
  }
  read_iamc(out)
}

magpie_side <- function(run_dir, pcfg, allow_unmapped = FALSE) {
  tbl <- mapped_report(run_report(run_dir), MAP_FILE, allow_unmapped)
  # report.mif is written in MAgPIE region codes; the comparison is made in
  # MESSAGEix names, which is what the MESSAGE file uses.
  rename <- region_rename(pcfg)
  unknown <- setdiff(unique(tbl$region), names(rename))
  if (length(unknown)) {
    log_die("the run reports region(s) ", unknown, " that ", region_names_file(pcfg),
            " does not name")
  }
  tbl$region <- unname(rename[tbl$region])
  out <- tbl[, c("variable", "region", "year", "value", "unit")]
  names(out)[names(out) == "value"] <- "magpie"
  names(out)[names(out) == "unit"] <- "magpie_unit"
  out
}

message_side <- function(iamc, variables, scenario = NULL) {
  tbl <- read_iamc(iamc, scenario)
  tbl <- tbl[tbl$variable %in% variables, ]
  out <- tbl[, c("variable", "region", "year", "value", "unit")]
  names(out)[names(out) == "value"] <- "message"
  names(out)[names(out) == "unit"] <- "message_unit"
  out
}

compare_land_use <- function(pcfg, run_dir, iamc, variables = character(0),
                             scenario = NULL, out_dir = NULL, allow_unmapped = FALSE) {
  mp <- magpie_side(run_dir, pcfg, allow_unmapped)
  if (length(variables)) {
    absent <- setdiff(variables, unique(mp$variable))
    if (length(absent)) log_die("--variable: the mapped run reports no ", absent)
    mp <- mp[mp$variable %in% variables, ]
  }
  # Both sides are read over the mapping's own target vocabulary, so a variable
  # only one of them reports is visible instead of being silently excluded.
  # The mapping writes its targets as "Name (unit)"; write.reportProject() splits
  # the unit off into its own column, so the bare name is what to match on.
  targets <- unique(read_pipeline_csv(MAP_FILE, "mapping file")$Variable)
  targets <- trimws(sub("\\s*\\([^()]*\\)$", "", targets))
  if (length(variables)) targets <- intersect(targets, variables)
  ms <- message_side(iamc, targets, scenario)

  both <- dplyr::inner_join(mp, ms, by = c("variable", "region", "year"))
  both$difference <- both$magpie - both$message
  # Relative difference is undefined where MESSAGE reports zero, and a zero is a
  # real answer for several land-use variables. Left as NA rather than infinite.
  both$relative_difference <- ifelse(both$message == 0, NA_real_,
                                     both$difference / both$message)
  both$unit_mismatch <- both$magpie_unit != both$message_unit

  only_magpie  <- setdiff(unique(mp$variable), unique(ms$variable))
  only_message <- setdiff(unique(ms$variable), unique(mp$variable))
  coverage <- rbind(
    data.frame(variable = only_magpie, reported_by = "magpie only",
               stringsAsFactors = FALSE),
    data.frame(variable = only_message, reported_by = "message only",
               stringsAsFactors = FALSE))

  dir <- if (is.null(out_dir)) file.path(run_dir, "feedback_comparison") else out_dir
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  comparison <- file.path(dir, "land_use_comparison.csv")
  readr::write_delim(both, comparison, delim = ";")
  log_step("WRITE", comparison, " (", nrow(both), " rows over ",
           length(unique(both$variable)), " variables)")

  cov_file <- file.path(dir, "comparison_coverage.csv")
  readr::write_delim(coverage, cov_file, delim = ";")
  log_step("WRITE", cov_file, " (", nrow(coverage), " variable(s) on one side only)")

  if (any(both$unit_mismatch)) {
    log_warn(sum(both$unit_mismatch), " row(s) compare values whose units differ; ",
             "the unit_mismatch column marks them")
  }
  log_step("DONE", "comparison written. Read it; nothing here grades it")
  c(comparison = comparison, coverage = cov_file)
}

# ---- command line -----------------------------------------------------------

if (invoked_directly("compare_land_use.R")) {
  usage <- paste(sub("^# \\|", "", grep("^# \\|",
                 readLines("messageix/feedback_run/compare_land_use.R"),
                 value = TRUE)), collapse = "\n")
  flags <- parse_flags(commandArgs(trailingOnly = TRUE),
                       known = c("run-dir", "iamc", "scenario", "out-dir", "experiment"),
                       flags = c("help", "allow-unmapped"),
                       repeatable = c("set", "variable"), usage = usage)
  if (isTRUE(flags$help)) { log_report(usage); quit(status = 0) }
  if (is.null(flags[["run-dir"]])) log_die("--run-dir is required", "\n", usage)
  if (is.null(flags$iamc)) log_die("--iamc is required", "\n", usage)
  pcfg <- config_from_flags(flags, cli_overrides(flags$set))
  compare_land_use(pcfg, run_dir = flags[["run-dir"]], iamc = flags$iamc,
                   variables = if (is.null(flags$variable)) character(0) else unlist(flags$variable),
                   scenario = flags$scenario, out_dir = flags[["out-dir"]],
                   allow_unmapped = isTRUE(flags[["allow-unmapped"]]))
}
