# |  Pull second-generation bioenergy demand out of MESSAGE output.
# |
# |  The other half of the handshake the price sweep makes. MAgPIE is told how
# |  much second-generation bioenergy to supply through a column of
# |  f60_bioenergy_dem.cs3; messageix/R/pack_demand.R builds those columns from
# |  what the price sweep settled on, with extract_bioenergy_column(). What
# |  MESSAGE actually asked for is a different number, and it lives here.
# |
# |    MESSAGE IAMC csv  ->  named bioenergy variables, summed per region and year
# |                      ->  EJ/yr to PJ/yr
# |                      ->  bioenergy_demand.csv   (for the human comparison)
# |                      ->  f60_bioenergy_dem.cs3  (for the feedback run)
# |
# |  Two files because they have two readers. The csv is what someone looks at
# |  beside MAgPIE's supply; the cs3 is a column a MAgPIE run can select with
# |  cfg$gms$c60_2ndgen_biodem.
# |
# |  Scope: this prepares an input. It does not judge the run it came from.
# |
# |  Usage, from the MAgPIE model root:
# |    Rscript messageix/optional/feedback_prep/prep_bioenergy_demand.R \
# |      --iamc /abs/path/message_output.csv \
# |      --biovar "Primary Energy|Biomass|Modern|w/o CCS" \
# |      --biovar "Primary Energy|Biomass|Modern|w/ CCS"
# |
# |    --iamc PATH        MESSAGE output in IAMC csv form; required
# |    --biovar VAR       ASSUMPTION. an IAMC variable to count as second-generation
# |                       bioenergy demand; repeatable, summed. Default: the first
# |                       of Energy Crops, the Modern CCS pair, or Modern that the
# |                       file carries in full
# |    --scenario NAME    the MESSAGE scenario to read, when the file holds several
# |    --column NAME      f60 scenario column to write (default "feedback")
# |    --seed PATH        f60_bioenergy_dem.cs3 to append the column to; default
# |                       modules/60_bioenergy/input/f60_bioenergy_dem.cs3
# |    --no-cs3           write the csv only, skip the f60 file
# |    --out-dir DIR      default messageix/optional/feedback_prep/output/<experiment>
# |    --experiment NAME  an experiment of messageix/experiments.R
# |    --set key=value    override one setting; repeatable
# |    --help
# |
# |  Every option is accepted as --key value and as --key=value.
# |
# |  Interface
# |    DEFAULT_BIOENERGY_VARIABLES              -> list of candidate variable sets
# |    resolve_bioenergy_variables(tbl)          -> chr; the first set the file has in full
# |    ej_to_pj(value, unit)                    -> num; 1000x, and stops on a unit it cannot read
# |    bioenergy_demand(tbl, variables, pcfg)   -> df(region, year, value_pj, variables)
# |    write_f60_column(demand, column, seed, out) -> chr(1); the file written
# |    prep_bioenergy_demand(pcfg, ...)         -> named chr; the files written
# |
# |  Dependencies: magclass, readr/dplyr/tidyr, messageix/optional/feedback_prep/prep_carbon_price.R
# |  for read_iamc() and magpie_region_codes(), which brings the config layer with it.

if (!exists("read_iamc", mode = "function")) {
  source("messageix/optional/feedback_prep/prep_carbon_price.R")
}

# ---- ASSUMPTION: which variables are second-generation bioenergy ------------

# There is no single IAMC variable for it, and which one a MESSAGE run reports
# depends on how that run's reporting was configured. These are the candidate
# sets in preference order; the first set every member of which is in the file
# is the one used, and which was chosen is reported.
#
# Energy Crops first because that is the quantity MAgPIE actually supplies:
# purpose-grown lignocellulosic biomass, the second generation by definition, and
# the variable the REMIND-MAgPIE coupling uses for the same handshake. The Modern
# pair is the fallback for a run that reports the CCS split but not the feedstock
# split; it is broader, and on a run that also burns residues it is broader than
# what MAgPIE grows.
#
# Residues and first-generation streams are deliberately in neither set. Counting
# them inflates the demand MAgPIE is held to, and the run still solves.
DEFAULT_BIOENERGY_VARIABLES <- list(
  c("Primary Energy|Biomass|Energy Crops"),
  c("Primary Energy|Biomass|Modern|w/o CCS", "Primary Energy|Biomass|Modern|w/ CCS"),
  c("Primary Energy|Biomass|Modern"))

# The first candidate set the file carries in full.
resolve_bioenergy_variables <- function(tbl) {
  have <- unique(tbl$variable)
  for (set in DEFAULT_BIOENERGY_VARIABLES) {
    if (all(set %in% have)) return(set)
  }
  biomass <- grep("Biomass", have, value = TRUE, fixed = TRUE)
  log_report(c(
    ">> none of the default second-generation bioenergy variable sets is in the file:",
    paste0("     - ", vapply(DEFAULT_BIOENERGY_VARIABLES, paste, character(1), collapse = " + ")),
    if (length(biomass)) c("   biomass variables the file does carry:",
                           paste0("     - ", biomass))
    else "   the file carries no variable with 'Biomass' in its name"))
  log_die("--biovar: name the variable(s) to count as second-generation bioenergy demand. ",
          "What the file carries is listed above")
}

# IAMC energy is EJ/yr; MAgPIE's f60 is PJ/yr. Any other unit stops the run.
ej_to_pj <- function(value, unit) {
  u <- unique(trimws(tolower(unit)))
  if (length(u) != 1L) log_die("--biovar: the named variables carry mixed units: ", u)
  if (u %in% c("ej/yr", "ej/year", "ej per yr")) return(value * 1000)
  if (u %in% c("pj/yr", "pj/year", "pj per yr")) return(value)
  log_die("--biovar: unit '", u, "' is neither EJ/yr nor PJ/yr, and this step will not ",
          "guess at a conversion. Report the variables in EJ/yr or PJ/yr")
}

# Sum the named variables per region and year, in PJ/yr, on MAgPIE region codes.
bioenergy_demand <- function(tbl, variables, pcfg) {
  sub <- tbl[tbl$variable %in% variables, ]
  absent <- setdiff(variables, unique(sub$variable))
  if (length(absent)) {
    log_die("--biovar: variable(s) ", absent, " are not in the IAMC file")
  }
  sub$value <- ej_to_pj(sub$value, sub$unit)

  sub$region <- match_regions(sub$region, pcfg)
  # After mapping, not before: the region table sends both GLO and World to World.
  sub <- sub[!sub$region %in% c("GLO", "World"), ]

  out <- dplyr::summarise(dplyr::group_by(sub, .data$region, .data$year),
                          value_pj = sum(.data$value), .groups = "drop")
  if (any(is.na(out$value_pj))) {
    log_die("bioenergy demand is NA in ", sum(is.na(out$value_pj)),
            " region-year cell(s); the IAMC file has gaps in the named variables")
  }
  out$variables <- paste(variables, collapse = " + ")
  out
}

# Append the demand as one scenario column of f60_bioenergy_dem.cs3.
write_f60_column <- function(demand, column, seed, out) {
  if (!file.exists(seed)) {
    log_die("--seed: ", seed, " not found. It is f60_bioenergy_dem.cs3 as it comes in the ",
            "base input tarballs, which any earlier run has already unpacked into ",
            "modules/60_bioenergy/input/. Run a stage first, or name the file with --seed=PATH")
  }
  old <- magclass::read.magpie(seed)
  if (column %in% magclass::getNames(old)) {
    log_die("--column: ", seed, " already carries '", column,
            "'. Start from the unpatched base file, or name the column differently")
  }
  years <- magclass::getYears(old, as.integer = TRUE)
  absent <- setdiff(years, unique(demand$year))
  if (length(absent)) {
    log_die("the MESSAGE output covers no bioenergy demand for model year(s) ", absent,
            ", which ", seed, " has. A gap here becomes a zero MAgPIE takes at face value")
  }
  regions <- magclass::getRegions(old)
  absent <- setdiff(regions, unique(demand$region))
  if (length(absent)) log_die("the MESSAGE output covers no region(s) ", absent)

  x <- magclass::new.magpie(cells_and_regions = regions, years = years,
                            names = column, fill = NA_real_)
  wide <- as.data.frame(tidyr::pivot_wider(demand[, c("region", "year", "value_pj")],
                                           names_from = "year", values_from = "value_pj"))
  rownames(wide) <- wide$region
  x[, , column] <- as.matrix(wide[regions, as.character(years), drop = FALSE])
  if (any(is.na(as.vector(x)))) log_die("the f60 column being written contains NA")

  dir.create(dirname(out), recursive = TRUE, showWarnings = FALSE)
  magclass::write.magpie(magclass::mbind(old, x), out)
  log_step("WRITE", out, " (column '", column, "' appended to ",
           length(magclass::getNames(old)), " existing)")
  out
}

prep_bioenergy_demand <- function(pcfg, iamc, variables = character(0),
                                  scenario = NULL, column = "feedback", seed = NULL,
                                  out_dir = NULL, write_cs3 = TRUE) {
  tbl <- read_iamc(iamc, scenario)
  assumed <- character(0)
  if (!length(variables)) {
    variables <- resolve_bioenergy_variables(tbl)
    assumed <- c(assumed, paste0("second-generation bioenergy: ",
                                 paste(variables, collapse = " + "), " (--biovar)"))
  }
  demand <- bioenergy_demand(tbl, variables, pcfg)
  log_step("EXTRACT", "second-generation bioenergy demand over ",
           length(unique(demand$region)), " regions and ",
           length(unique(demand$year)), " years, from ", length(variables), " variable(s)")

  dir <- if (is.null(out_dir)) {
    file.path("messageix", "optional", "feedback_prep", "output", pcfg$experiment)
  } else out_dir
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)

  csv <- file.path(dir, "bioenergy_demand.csv")
  readr::write_delim(demand, csv, delim = ";")
  log_step("WRITE", csv, " (", nrow(demand), " rows, PJ per yr)")
  files <- c(csv = csv)

  if (isTRUE(write_cs3)) {
    if (is.null(seed)) seed <- "modules/60_bioenergy/input/f60_bioenergy_dem.cs3"
    files["cs3"] <- write_f60_column(demand, column, seed,
                                     file.path(dir, "f60_bioenergy_dem.cs3"))
  }
  report_assumptions(assumed, csv)
  attr(files, "resolved") <- list(bioenergy_variables = variables, assumed = assumed)
  files
}

# ---- command line -----------------------------------------------------------

if (invoked_directly("prep_bioenergy_demand.R")) {
  usage <- paste(sub("^# \\|", "", grep("^# \\|",
                 readLines("messageix/optional/feedback_prep/prep_bioenergy_demand.R"),
                 value = TRUE)), collapse = "\n")
  flags <- parse_flags(commandArgs(trailingOnly = TRUE),
                       known = c("iamc", "scenario", "column", "seed", "out-dir", "experiment"),
                       flags = c("help", "no-cs3"), repeatable = c("set", "biovar"),
                       usage = usage)
  if (isTRUE(flags$help)) { log_report(usage); quit(status = 0) }
  if (is.null(flags$iamc)) log_die("--iamc is required", "\n", usage)
  pcfg <- config_from_flags(flags, cli_overrides(flags$set))
  prep_bioenergy_demand(
    pcfg, iamc = flags$iamc,
    variables = if (is.null(flags$biovar)) character(0) else unlist(flags$biovar),
    scenario = flags$scenario,
    column = if (is.null(flags$column)) "feedback" else flags$column,
    seed = flags$seed, out_dir = flags[["out-dir"]],
    write_cs3 = !isTRUE(flags[["no-cs3"]]))
}
