# |  Build the GHG price file a MAgPIE feedback run reads, out of MESSAGE output.
# |
# |  messageix/R/pack_demand.R refuses to run without f56_pollutant_prices.cs3 and
# |  says, in f56_missing_message(), that nothing in this repository can build one.
# |  This is the other end of that sentence: the file is a MESSAGE product, and
# |  this is where a MESSAGE run is turned into it.
# |
# |    MESSAGE IAMC csv  ->  regional carbon price  ->  weighting rule
# |                      ->  currency deflation     ->  pollutant expansion
# |                      ->  f56_pollutant_prices.cs3
# |
# |  Two of those steps have a worked default from IAMC convention, marked
# |  ASSUMPTION below; each is narrated as it is applied and listed again at the
# |  end of the run. The third, the pollutant map, is marked DECISION and has no
# |  default: it stops the run until it is given, because a defaulted GWP set is
# |  the one wrong value nothing downstream can catch.
# |
# |  One MESSAGE run gives one price trajectory and therefore one scenario column.
# |  Use --append to add that column to an f56 built from an earlier run; the
# |  demand sweep needs one column per GHG price level and they arrive one at a
# |  time.
# |
# |  Scope: this prepares an input. It does not judge the run it came from.
# |
# |  Usage, from the MAgPIE model root:
# |    Rscript messageix/optional/feedback_prep/prep_carbon_price.R \
# |      --iamc /abs/path/message_output.csv --weights none --deflator 1.13 \
# |      --pollutant-map messageix/optional/feedback_prep/pollutant_map.csv
# |
# |    --iamc PATH           MESSAGE output in IAMC csv form; required
# |    --weights RULE        ASSUMPTION. the IAMC variable weighting regional
# |                          carbon prices into one trajectory; default
# |                          "Emissions|CO2". "none" keeps prices regional
# |    --deflator NUM        ASSUMPTION. multiplier onto USD17MER; default read
# |                          from the price variable's own currency unit
# |    --pollutant-map PATH  DECISION. one row per MAgPIE pollutant; required, and
# |                          there is no default. Start from
# |                          messageix/optional/feedback_prep/pollutant_map.template.txt
# |    --price-variable VAR  carbon price variable (default "Price|Carbon")
# |    --scenario NAME       the scenario to read, when the file holds several
# |    --column NAME         scenario column to write (default "feedback")
# |    --append PATH         f56 to add the column to, instead of a new file
# |    --out PATH            file to write (default under --out-dir)
# |    --out-dir DIR         default messageix/optional/feedback_prep/output/<experiment>
# |    --experiment NAME     an experiment of messageix/experiments.R
# |    --set key=value       override one setting; repeatable
# |    --help
# |
# |  Every option is accepted as --key value and as --key=value.
# |
# |  Interface
# |    read_iamc(path, scenario)              -> tidy df(model, scenario, region, variable,
# |                                              unit, year, value); one run only
# |    assert_one_run(tbl, path, scenario)    -> df; stops on several runs or duplicate rows
# |    magpie_region_codes(pcfg)              -> named chr; MESSAGEix name -> MAgPIE code
# |    match_regions(labels, pcfg)            -> chr; IAMC region labels -> MAgPIE codes
# |    weighted_carbon_price(prices, weights, rule) -> df(region, year, value)
# |    default_deflator(unit)                 -> num(1) or NULL; from the currency unit
# |    POLLUTANT_MAP_TEMPLATE                 -> chr(1); the shipped blank template
# |    read_pollutant_map(path)               -> df(pollutant, factor)
# |    expand_pollutants(prices, map, column) -> magpie object over (i, t, pollutant.scenario)
# |    check_f56_structure(x)                 -> invisible(TRUE); order, pollutants, NA
# |    prep_carbon_price(pcfg, ...)           -> chr(1); the file written
# |
# |  Dependencies: magclass, readr/dplyr/tidyr, and the messageix/R/ config layer.

if (!exists("resolve_config", mode = "function")) source("messageix/R/utils_config.R")
# taxable_pollutants() lives in pack_demand.R. Sourcing only utils_config.R left every
# pollutant check here guarded on a function that did not exist, so none of them fired.
if (!exists("taxable_pollutants", mode = "function")) source("messageix/R/pack_demand.R")

# ---- reading MESSAGE output -------------------------------------------------

# IAMC wide csv to long. Both delimiters are tried: European exports use ";".
read_iamc <- function(path, scenario = NULL) {
  if (!file.exists(path)) log_die("--iamc: file not found: ", path)
  raw <- readr::read_delim(path, delim = ",", show_col_types = FALSE,
                           progress = FALSE, name_repair = "minimal")
  if (ncol(raw) <= 1L) {
    raw <- readr::read_delim(path, delim = ";", show_col_types = FALSE,
                             progress = FALSE, name_repair = "minimal")
  }
  names(raw) <- tolower(names(raw))
  needed <- c("region", "variable", "unit")
  absent <- setdiff(needed, names(raw))
  if (length(absent)) {
    log_die("--iamc: ", path, " has no column(s) ", absent,
            "; an IAMC table carries Model, Scenario, Region, Variable, Unit and one column per year")
  }
  year_cols <- names(raw)[grepl("^[0-9]{4}$", names(raw))]
  if (!length(year_cols)) log_die("--iamc: ", path, " carries no year columns")
  out <- tidyr::pivot_longer(raw, dplyr::all_of(year_cols),
                             names_to = "year", values_to = "value")
  out$year <- as.integer(out$year)
  # Model and scenario are kept so the file can be checked for being one run.
  for (col in c("model", "scenario")) {
    if (!col %in% names(out)) out[[col]] <- NA_character_
  }
  out <- out[, c("model", "scenario", "region", "variable", "unit", "year", "value")]
  assert_one_run(out, path, scenario)
}

# One IAMC file usually holds several scenarios. Dropping model and scenario and
# grouping on region and year sums them, and the result passes every other check
# in this folder: no NA, every region and year present. MAgPIE is then held to a
# demand MESSAGE never asked for and the run solves. So the file has to be one
# run, and saying which one is the caller's job.
assert_one_run <- function(tbl, path, scenario = NULL) {
  if (!is.null(scenario)) {
    keep <- !is.na(tbl$scenario) & tbl$scenario == scenario
    if (!any(keep)) {
      log_die("--scenario: '", scenario, "' is not in ", path,
              ". It carries: ", unique(stats::na.omit(tbl$scenario)))
    }
    tbl <- tbl[keep, ]
  }
  runs <- unique(tbl[, c("model", "scenario")])
  if (nrow(runs) > 1L) {
    log_die(path, " carries ", nrow(runs), " model-scenario combinations: ",
            paste(paste(runs$model, runs$scenario, sep = " / "), collapse = "; "),
            ". Averaging a carbon price or summing a demand across them is not a run ",
            "MESSAGE ever produced. Name one with --scenario")
  }
  key <- paste(tbl$region, tbl$variable, tbl$year, sep = "\r")
  dup <- unique(key[duplicated(key)])
  if (length(dup)) {
    shown <- utils::head(sub("\r", " / ", gsub("\r", " / ", dup)), 5L)
    log_die(path, " has ", length(dup), " region/variable/year combination(s) reported more ",
            "than once within a single scenario, for example ", shown,
            ". Every consumer here would silently add them together")
  }
  tbl
}

# MESSAGEix region name -> MAgPIE region code, the region table read backwards.
magpie_region_codes <- function(pcfg) {
  fwd <- region_rename(pcfg)
  stats::setNames(names(fwd), unname(fwd))
}

# Region labels in an IAMC file onto MAgPIE region codes. Three spellings are
# accepted because MESSAGE output is written in all three: the long MESSAGEix
# name the region table carries ("SubSaharanAfrica"), the bare MAgPIE code
# ("AFR"), and the prefixed form reporting usually emits ("R12_AFR"). All three
# resolve through the one region table, so nothing here invents a mapping.
match_regions <- function(labels, pcfg) {
  codes <- magpie_region_codes(pcfg)
  known <- names(region_rename(pcfg))

  out <- rep(NA_character_, length(labels))
  hit <- labels %in% names(codes)
  out[hit] <- unname(codes[labels[hit]])

  bare <- sub("^[A-Za-z][A-Za-z0-9]*_", "", labels)
  hit <- is.na(out) & bare %in% known
  out[hit] <- bare[hit]

  if (anyNA(out)) {
    log_die("region(s) ", unique(labels[is.na(out)]), " are not in ", region_names_file(pcfg),
            " under any accepted spelling. It names ", known,
            ", which this step also accepts as the long MESSAGEix name and with a region-set ",
            "prefix (R12_AFR)")
  }
  out
}

# ---- ASSUMPTION 1: the weighting rule ---------------------------------------

# The default weight. A carbon price is a price per tonne, so the only average
# of twelve regional prices that means anything is the one weighted by the
# tonnes each price applies to. Emissions|CO2 is the IAMC variable carrying them
# and is what this weights by unless told otherwise. An unweighted mean of
# regional prices is not a price and is deliberately not offered.
DEFAULT_WEIGHT_VARIABLE <- "Emissions|CO2"

# Collapse regional carbon prices, or leave them regional.
#
#   rule "none"  regional prices pass through unchanged
#   otherwise    `rule` names an IAMC variable; regional prices are averaged
#                with it as the weight, into one trajectory held in every region
#
# Which is right is a property of the MESSAGE run. A run with one global carbon
# price and no regional differentiation wants "none", and the two give the same
# answer there anyway. A run whose regional prices genuinely differ needs the
# weighting, and needs someone to have agreed it is the right weight.
weighted_carbon_price <- function(prices, weights, rule) {
  if (identical(rule, "none")) {
    return(prices[, c("region", "year", "value")])
  }
  if (!nrow(weights)) {
    log_die("--weights: no rows for variable '", rule, "' in the IAMC file. ",
            "Name a variable the file carries, or pass --weights none to keep regional prices")
  }
  j <- dplyr::inner_join(prices, weights, by = c("region", "year"),
                         suffix = c("", "_w"))
  missing_years <- setdiff(unique(prices$year), unique(j$year))
  if (length(missing_years)) {
    log_die("--weights: variable '", rule, "' covers no value for year(s) ", missing_years,
            ", which the price series has")
  }
  glo <- dplyr::summarise(dplyr::group_by(j, .data$year),
                          value = stats::weighted.mean(.data$value, .data$value_w),
                          .groups = "drop")
  if (any(is.na(glo$value))) {
    log_die("--weights: the weighted mean is NA in year(s) ",
            glo$year[is.na(glo$value)], "; the weight sums to zero there")
  }
  # One trajectory, repeated across regions: MAgPIE prices every region.
  tidyr::expand_grid(region = unique(prices$region), glo)
}

# ---- ASSUMPTION 2: the currency deflator ------------------------------------

# MAgPIE wants USD17MER; IAMC output states its own currency in the unit string.
# The 2005 factor is the pipeline's own (currency_2005_to_2017), so the deflator
# into MAgPIE and its reciprocal back out of MAgPIE cannot drift apart. The 2010
# factor is the US GDP deflator over 2010-2017 and is the one number here with no
# second source in this repository, which is why it is reported every run.
DEFLATOR_2010_TO_2017 <- 1.13

default_deflator <- function(unit, pcfg) {
  u <- tolower(paste(unique(unit), collapse = " "))
  if (grepl("2017|us\\$17|usd17", u)) return(list(value = 1, basis = "already USD2017"))
  if (grepl("2010|us\\$10|usd10", u)) {
    return(list(value = DEFLATOR_2010_TO_2017, basis = "USD2010 to USD2017 MER"))
  }
  if (grepl("2005|us\\$05|usd05", u)) {
    return(list(value = pcfg$currency_2005_to_2017,
                basis = "USD2005 to USD2017 MER, from currency_2005_to_2017"))
  }
  NULL
}

# ---- DECISION: the pollutant map --------------------------------------------

# This one has no default and stops the run when it is not given. A defaulted GWP
# set is the one assumption here that nothing downstream can catch: a MESSAGE run
# accounting on AR5 (28, 265) silently inheriting AR6 (27.0, 273) writes prices
# that pass every structural check and are wrong in every run.
POLLUTANT_MAP_TEMPLATE <- "messageix/optional/feedback_prep/pollutant_map.template.txt"

# What a map has to contain, printed when the one given cannot be used.
pollutant_map_message <- function() {
  paste0(
    "  A pollutant map is a semicolon- or comma-separated file with columns\n",
    "  `pollutant;factor`, one row per member of MAgPIE's GAMS set pollutants:\n",
    "    ", paste(taxable_pollutants(), collapse = ", "), "\n",
    "  `factor` multiplies the deflated CO2 price to give that pollutant's price in\n",
    "  the unit MAgPIE prices it in. Two things ride on it and both are silent when\n",
    "  wrong: the mass basis (co2_c is priced per tonne of CARBON, so its factor\n",
    "  carries 44/12 = 3.6667 on top of anything else) and the global warming\n",
    "  potentials used for ch4 and n2o, which have to be the ones the MESSAGE run\n",
    "  itself accounted with.\n",
    "  Start from ", POLLUTANT_MAP_TEMPLATE, ", which lists the pollutants and documents\n",
    "  what each factor is made of. It ships with the factors blank on purpose.\n",
    "  Why it is not filled in here: the GWP horizon is a property of the MESSAGE run's\n",
    "  own accounting, and a plausible wrong set changes every run while looking right.\n",
    "  The non-CO2 cap does NOT belong in the file. Trajectories stay uncapped; the\n",
    "  cap is applied inside GAMS by cfg$gms$s56_limit_ch4_n2o_price.")
}

read_pollutant_map <- function(path) {
  if (is.null(path)) {
    log_report(pollutant_map_message())
    log_die("no pollutant map was given (--pollutant-map=PATH). What it has to contain, ",
            "and why nothing here fills it in, is printed above")
  }
  if (!file.exists(path)) {
    log_report(pollutant_map_message())
    log_die("--pollutant-map: file not found: ", path)
  }
  m <- readr::read_delim(path, delim = ";", show_col_types = FALSE,
                         progress = FALSE, comment = "#")
  if (ncol(m) <= 1L) {
    m <- readr::read_delim(path, delim = ",", show_col_types = FALSE,
                           progress = FALSE, comment = "#")
  }
  names(m) <- tolower(names(m))
  absent <- setdiff(c("pollutant", "factor"), names(m))
  if (length(absent)) log_die("--pollutant-map: ", path, " has no column(s) ", absent)
  m$factor <- as.numeric(m$factor)
  if (any(is.na(m$factor))) {
    log_report(pollutant_map_message())
    log_die("--pollutant-map: ", path, " has a non-numeric factor for pollutant(s) ",
            m$pollutant[is.na(m$factor)])
  }
  required <- taxable_pollutants()
  absent <- setdiff(required, m$pollutant)
  if (length(absent)) {
    log_die("--pollutant-map: ", path, " prices no value for pollutant(s) ", absent,
            "; the GAMS set pollutants requires all of ", required)
  }
  m[, c("pollutant", "factor")]
}

# Print what was assumed rather than supplied, beside the file it went into.
# Silent when the caller named everything.
report_assumptions <- function(assumed, produced) {
  if (!length(assumed)) return(invisible(NULL))
  log_report(c(
    paste0(">> CONFIRM: ", length(assumed), " value(s) in ", basename(produced),
           " came from a default, not from you:"),
    paste0("     - ", assumed),
    "   Each is defensible and none is verifiable from the MESSAGE output alone.",
    "   Check them against the run's own accounting before a production run."))
  invisible(NULL)
}

# ---- building the file ------------------------------------------------------

# Regional prices and the map to a magpie object over (i, t, pollutant.scenario).
# The sub-dimension order is pollutant first: MAgPIE builds its list of
# selectable GHG price scenarios from the second one, so a file written the other
# way round turns the pollutant names into the scenario list.
expand_pollutants <- function(prices, map, column) {
  regions <- sort(unique(prices$region))
  years <- sort(unique(prices$year))
  names_ <- paste(map$pollutant, column, sep = ".")
  x <- magclass::new.magpie(cells_and_regions = regions,
                            years = years,
                            names = names_,
                            fill = NA_real_)
  wide <- tidyr::pivot_wider(prices[, c("region", "year", "value")],
                             names_from = "year", values_from = "value")
  wide <- as.data.frame(wide)
  rownames(wide) <- wide$region
  base <- as.matrix(wide[regions, as.character(years), drop = FALSE])
  for (k in seq_len(nrow(map))) {
    x[, , names_[k]] <- base * map$factor[k]
  }
  x
}

# The checks pack_demand.R's validate_f56() makes that do not need an experiment:
# the two sub-dimensions and their order, the pollutant list, and no NA. The
# scenario-completeness check stays with validate_f56(), which knows the sweep.
check_f56_structure <- function(x) {
  parts <- strsplit(magclass::getNames(x), ".", fixed = TRUE)
  widths <- unique(lengths(parts))
  if (length(widths) != 1L || widths != 2L) {
    log_die("the file being written does not carry a (pollutant, scenario) column structure")
  }
  found <- unique(vapply(parts, `[`, character(1), 1L))
  required <- taxable_pollutants()
  if (!setequal(found, required)) {
    log_die("the file being written prices pollutants ", found,
            " where the GAMS set pollutants requires exactly ", required)
  }
  if (any(is.na(as.vector(x)))) log_die("the file being written contains NA")
  invisible(TRUE)
}

# Build the f56 for one MESSAGE run and write it. Returns the path.
prep_carbon_price <- function(pcfg, iamc, weights_rule = NULL, deflator = NULL,
                              pollutant_map = NULL, price_variable = "Price|Carbon",
                              scenario = NULL, column = "feedback", append = NULL,
                              out = NULL, out_dir = NULL) {
  # Anything resolved from a default rather than supplied is collected here and
  # printed again at the end. An assumption named once, 40 lines above the
  # result, is an assumption nobody read.
  assumed <- character(0)

  if (is.null(weights_rule)) {
    weights_rule <- DEFAULT_WEIGHT_VARIABLE
    assumed <- c(assumed, paste0("weighting rule: regional prices weighted by '",
                                 weights_rule, "' (--weights)"))
  }
  map <- read_pollutant_map(pollutant_map)
  tbl <- read_iamc(iamc, scenario)

  prices <- tbl[tbl$variable == price_variable, ]
  if (!nrow(prices)) {
    log_die("--price-variable: '", price_variable, "' is not in ", iamc,
            ". Variables it does carry, first 20: ", utils::head(unique(tbl$variable), 20L))
  }
  log_step("EXTRACT", "carbon price '", price_variable, "' in ",
           paste(unique(prices$unit), collapse = "/"), " over ", length(unique(prices$region)),
           " regions and ", length(unique(prices$year)), " years")

  if (is.null(deflator)) {
    guess <- default_deflator(prices$unit, pcfg)
    if (is.null(guess)) {
      log_die("--deflator: not given, and the currency of '", price_variable, "' cannot be ",
              "read from its unit '", paste(unique(prices$unit), collapse = "/"),
              "'. MAgPIE wants USD17MER. Recognised units name 2005, 2010 or 2017; ",
              "supply the multiplier with --deflator for anything else")
    }
    deflator <- guess$value
    assumed <- c(assumed, paste0("currency deflator: ", deflator, ", ", guess$basis,
                                 " (--deflator)"))
  }
  # A zero deflator writes an all-zero price file that passes every structural
  # check; a non-numeric one reaches the NA check with a message about the wrong thing.
  if (!is.numeric(deflator) || length(deflator) != 1L || !is.finite(deflator) || deflator <= 0) {
    log_die("--deflator: ", deflator, " is not a finite positive number")
  }

  weights <- tbl[tbl$variable == weights_rule, c("region", "year", "value")]
  names(weights)[names(weights) == "value"] <- "value_w"
  prices <- weighted_carbon_price(prices, weights, weights_rule)

  # Region labels come in however MESSAGE wrote them and go out as MAgPIE codes.
  prices$region <- match_regions(prices$region, pcfg)
  # After mapping, not before: the region table sends both GLO and World to World,
  # so a global row arrives here as either code depending on how MESSAGE wrote it.
  prices <- prices[!prices$region %in% c("GLO", "World"), ]

  prices$value <- prices$value * deflator
  log_step("EXTRACT", "deflated to USD17MER with a factor of ", deflator)

  x <- expand_pollutants(prices, map, column)

  if (!is.null(append)) {
    if (!file.exists(append)) log_die("--append: file not found: ", append)
    old <- magclass::read.magpie(append)
    clash <- intersect(magclass::getNames(x), magclass::getNames(old))
    if (length(clash)) {
      log_die("--append: ", append, " already carries column(s) ", clash,
              ". Name the new column with --column, or start from a file that does not have it")
    }
    x <- magclass::mbind(old, x)
  }
  check_f56_structure(x)

  if (is.null(out)) {
    dir <- if (is.null(out_dir)) {
      file.path("messageix", "optional", "feedback_prep", "output", pcfg$experiment)
    } else out_dir
    dir.create(dir, recursive = TRUE, showWarnings = FALSE)
    out <- file.path(dir, "f56_pollutant_prices.cs3")
  }
  dir.create(dirname(out), recursive = TRUE, showWarnings = FALSE)
  magclass::write.magpie(x, out)
  log_step("WRITE", out, " (", length(magclass::getNames(x)), " columns, scenario '", column, "')")
  report_assumptions(assumed, out)
  # What was actually used, for the manifest. A record of the flags would say
  # nothing about the run whenever a default filled one in, which is the case
  # this file is built for.
  attr(out, "resolved") <- list(weighting_rule = weights_rule,
                                currency_deflator = deflator,
                                pollutant_map = pollutant_map,
                                assumed = assumed)
  out
}

# ---- command line -----------------------------------------------------------

if (invoked_directly("prep_carbon_price.R")) {
  usage <- paste(sub("^# \\|", "", grep("^# \\|", readLines("messageix/optional/feedback_prep/prep_carbon_price.R"),
                                        value = TRUE)), collapse = "\n")
  flags <- parse_flags(commandArgs(trailingOnly = TRUE),
                       known = c("iamc", "weights", "deflator", "pollutant-map",
                                 "price-variable", "scenario", "column", "append", "out",
                                 "out-dir", "experiment"),
                       flags = c("help"), repeatable = c("set"), usage = usage)
  if (isTRUE(flags$help)) { log_report(usage); quit(status = 0) }
  if (is.null(flags$iamc)) log_die("--iamc is required", "\n", usage)
  pcfg <- config_from_flags(flags, cli_overrides(flags$set))
  prep_carbon_price(
    pcfg, iamc = flags$iamc, weights_rule = flags$weights,
    deflator = if (is.null(flags$deflator)) NULL else as.numeric(flags$deflator),
    pollutant_map = flags[["pollutant-map"]],
    price_variable = if (is.null(flags[["price-variable"]])) "Price|Carbon" else flags[["price-variable"]],
    scenario = flags$scenario,
    column = if (is.null(flags$column)) "feedback" else flags$column,
    append = flags$append, out = flags$out, out_dir = flags[["out-dir"]])
}
