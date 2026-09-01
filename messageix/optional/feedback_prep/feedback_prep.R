# |  Run both halves of the MESSAGE-side preparation and record what was done.
# |
# |  prep_carbon_price.R  ->  f56_pollutant_prices.cs3
# |  prep_bioenergy_demand.R  ->  bioenergy_demand.csv, f60_bioenergy_dem.cs3
# |  this file               ->  feedback_prep_manifest.csv
# |
# |  The manifest is the point of running them together. The comparison someone
# |  makes later has to be able to say which MESSAGE run, which weighting rule and
# |  which bioenergy variables the MAgPIE run it is looking at was fed, and none of
# |  that is recoverable from the two cs3 files afterwards.
# |
# |  Scope: this prepares inputs. It does not judge the linkage, and it does not
# |  decide what to change when the comparison disagrees. That reading stays with
# |  a person.
# |
# |  Usage, from the MAgPIE model root:
# |    Rscript messageix/optional/feedback_prep/feedback_prep.R \
# |      --iamc /abs/path/message_output.csv \
# |      --experiment default
# |
# |  Every value beyond --iamc has a worked default, so that command is enough to
# |  produce a first set of files. The defaults are narrated as they are applied,
# |  written into the manifest under values_from_defaults, and listed again at the
# |  end. Override any of them: --weights, --deflator, --pollutant-map, --biovar.
# |
# |  Options are the union of the two scripts'; see their headers or --help.
# |
# |  Interface
# |    feedback_prep(pcfg, ...) -> named chr; every file written
# |
# |  Dependencies: messageix/optional/feedback_prep/prep_bioenergy_demand.R, which brings
# |  prep_carbon_price.R and the messageix/R/ config layer with it.

if (!exists("prep_bioenergy_demand", mode = "function")) {
  source("messageix/optional/feedback_prep/prep_bioenergy_demand.R")
}

# What the run was fed, written beside what it produced.
write_manifest <- function(path, entries) {
  df <- data.frame(key = names(entries),
                   value = vapply(entries, function(x) paste(x, collapse = " | "), character(1)),
                   row.names = NULL, stringsAsFactors = FALSE)
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  readr::write_delim(df, path, delim = ";")
  log_step("WRITE", path)
  path
}

feedback_prep <- function(pcfg, iamc, weights_rule = NULL, deflator = NULL,
                          pollutant_map = NULL, variables = character(0),
                          price_variable = "Price|Carbon", scenario = NULL,
                          column = "feedback", seed = NULL, out_dir = NULL,
                          write_cs3 = TRUE) {
  dir <- if (is.null(out_dir)) {
    file.path("messageix", "optional", "feedback_prep", "output", pcfg$experiment)
  } else out_dir
  log_banner("feedback prep", list(
    experiment = pcfg$experiment,
    iamc       = iamc,
    weights    = weights_rule,
    deflator   = deflator,
    column     = column,
    out        = dir))

  f56 <- prep_carbon_price(pcfg, iamc = iamc, weights_rule = weights_rule,
                           deflator = deflator, pollutant_map = pollutant_map,
                           price_variable = price_variable, scenario = scenario,
                           column = column, out_dir = dir)
  bio <- prep_bioenergy_demand(pcfg, iamc = iamc, variables = variables,
                               scenario = scenario, column = column, seed = seed,
                               out_dir = dir, write_cs3 = write_cs3)

  # The manifest records what the two steps resolved, not what the caller typed.
  # Whenever a default filled a value in, the two differ, and only the first is
  # a record of the run.
  rp <- attr(f56, "resolved")
  rb <- attr(bio, "resolved")
  assumed <- c(rp$assumed, rb$assumed)

  manifest <- write_manifest(file.path(dir, "feedback_prep_manifest.csv"), list(
    prepared_at        = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    experiment         = pcfg$experiment,
    region_set         = pcfg$region_set,
    message_output     = normalizePath(iamc, mustWork = FALSE),
    price_variable     = price_variable,
    message_scenario   = if (is.null(scenario)) "the file's only one" else scenario,
    weighting_rule     = rp$weighting_rule,
    currency_deflator  = rp$currency_deflator,
    pollutant_map      = rp$pollutant_map,
    bioenergy_variables = rb$bioenergy_variables,
    values_from_defaults = if (length(assumed)) assumed else "none",
    scenario_column    = column,
    f56_file           = f56,
    bioenergy_csv      = unname(bio["csv"]),
    f60_file           = if ("cs3" %in% names(bio)) unname(bio["cs3"]) else ""))

  out <- c(f56 = as.character(f56), bio, manifest = manifest)
  if (length(assumed)) {
    log_warn(length(assumed), " value(s) came from a default and are recorded in the ",
             "manifest under values_from_defaults. Confirm them before a production run")
  }
  log_step("DONE", "feedback prep wrote ", length(out), " files into ", dir)
  out
}

# ---- command line -----------------------------------------------------------

if (invoked_directly("feedback_prep.R")) {
  usage <- paste(sub("^# \\|", "", grep("^# \\|",
                 readLines("messageix/optional/feedback_prep/feedback_prep.R"),
                 value = TRUE)), collapse = "\n")
  flags <- parse_flags(commandArgs(trailingOnly = TRUE),
                       known = c("iamc", "weights", "deflator", "pollutant-map",
                                 "price-variable", "scenario", "column", "seed",
                                 "out-dir", "experiment"),
                       flags = c("help", "no-cs3"), repeatable = c("set", "biovar"),
                       usage = usage)
  if (isTRUE(flags$help)) { log_report(usage); quit(status = 0) }
  if (is.null(flags$iamc)) log_die("--iamc is required", "\n", usage)
  pcfg <- config_from_flags(flags, cli_overrides(flags$set))
  feedback_prep(
    pcfg, iamc = flags$iamc, weights_rule = flags$weights,
    deflator = if (is.null(flags$deflator)) NULL else as.numeric(flags$deflator),
    pollutant_map = flags[["pollutant-map"]],
    variables = if (is.null(flags$biovar)) character(0) else unlist(flags$biovar),
    price_variable = if (is.null(flags[["price-variable"]])) "Price|Carbon" else flags[["price-variable"]],
    scenario = flags$scenario,
    column = if (is.null(flags$column)) "feedback" else flags$column,
    seed = flags$seed, out_dir = flags[["out-dir"]],
    write_cs3 = !isTRUE(flags[["no-cs3"]]))
}
