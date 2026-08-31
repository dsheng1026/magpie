# |  Post-run checks on a finished bioenergy x GHG demand sweep.
# |
# |  vet_pre_run.R gates a run before it starts. This is the other side: three
# |  checks that only make sense once a whole stage-3 sweep has solved and
# |  reported, reading report.mif out of the run folders the same way
# |  messageix/R/createMatrix_MM.R does. It does not decide whether the matrix
# |  built from those runs is usable -- that is messageix/feedback_prep/'s and
# |  messageix/feedback_run/'s question -- only whether the sweep it was built
# |  from looks like the sweep that was asked for.
# |
# |  Two of the three checks are ported from the MAgPIE-side collaborator's
# |  vetting notebooks: a sanity check on the non-CO2 price cap, and a look at
# |  bioenergy production across the price grid. The third, on the pollutant
# |  map's global warming potentials, generalises a hazard those notebooks hit
# |  in passing -- two of their own chunks used two different GWP bases without
# |  saying so.
# |
# |  A check returns one of three statuses:
# |
# |    PASS  the condition holds
# |    WARN  worth reading before trusting the matrix; does not stop anything
# |    FAIL  the matrix built from this sweep is wrong
# |
# |  vet_post_matrix() stops on any FAIL. Nothing here writes, moves or fixes
# |  anything.
# |
# |  Usage, from the MAgPIE model root:
# |    Rscript messageix/vetting/vet_post_matrix.R --experiment default
# |
# |    --experiment NAME      an experiment of messageix/experiments.R
# |    --pollutant-map PATH   the map gwp_basis checks, instead of
# |                           messageix/data/MM_linkage_mapping.csv
# |    --set key=value        override one setting; repeatable
# |    --warn-only            report FAILs and exit 0 instead of stopping
# |    --help
# |
# |  Every option is accepted as --key value and as --key=value.
# |
# |  Interface
# |    vet_post_checks()                    -> named list of list(describe, fn)
# |    vet_post_matrix(pcfg, ...)           -> data.frame(check, status, detail); stops on FAIL
# |    read_report_mif(path)                -> data.frame; one run's report, trailing column dropped
# |    report_long(path, variables)         -> data.frame(Region, Variable, Unit, year, value, ...)
# |
# |  Dependencies: messageix/vetting/vet_pre_run.R for vet_result()/vet_try(), which
# |  brings the whole messageix/R/ layer with it, and
# |  messageix/feedback_prep/prep_carbon_price.R for read_pollutant_map(). Run from
# |  the MAgPIE model root.

if (!exists("vet_result", mode = "function")) source("messageix/vetting/vet_pre_run.R")
if (!exists("read_pollutant_map", mode = "function")) {
  source("messageix/feedback_prep/prep_carbon_price.R")
}
if (!exists("MIF_NAME")) source("messageix/R/utils_runs.R")

# ---- reading report.mif -----------------------------------------------------

# One run's raw report.mif: semicolon-delimited, '#' comment lines, and a
# trailing column the export leaves with no header. Dropped by name, the way
# createMatrix_MM.R drops it, rather than by position.
read_report_mif <- function(path) {
  if (!file.exists(path)) log_die("report.mif not found: ", path)
  raw <- utils::read.delim(path, sep = ";", comment.char = "#",
                           check.names = FALSE, stringsAsFactors = FALSE)
  raw[, nzchar(names(raw)), drop = FALSE]
}

# One run's report, long over year, filtered to the variables asked for.
# Returns a zero-row frame (not an error) when the run reports none of them --
# callers decide whether an absent variable is a WARN or nothing to say.
report_long <- function(path, variables) {
  raw <- read_report_mif(path)
  raw <- raw[raw$Variable %in% variables, , drop = FALSE]
  if (!nrow(raw)) return(raw[0, , drop = FALSE])
  year_cols <- grep("^X?[0-9]{4}$", names(raw), value = TRUE)
  if (!length(year_cols)) log_die(path, " has no year columns to gather")
  long <- tidyr::pivot_longer(raw, cols = dplyr::all_of(year_cols),
                              names_to = "year", values_to = "value")
  long$year <- as.integer(sub("^X", "", long$year))
  long$value <- suppressWarnings(as.numeric(long$value))
  long
}

# The stage-3 run folders that exist on disk, in the same order and from the
# same helper the reduce phase reads (messageix/R/utils_paths.R). A missing
# folder is not this script's problem -- vet_pre_run's calibration_reuse and
# the reduce phase's assert_runs_solved() say so already -- so absent runs are
# skipped rather than failed.
.stage3_runs_present <- function(pcfg) {
  grid <- expected_run_folders(pcfg, 3L)
  grid[dir.exists(grid$folder), , drop = FALSE]
}

# ---- the checks -------------------------------------------------------------

NONCO2_PRICE_VARS <- c("Prices|GHG Emission|CH4|Peatland", "Prices|GHG Emission|N2O|Peatland")
BE_PRODUCTION_VAR <- "Production|Bioenergy|2nd generation|++|Bioenergy crops"
AR6_GWP100 <- c(CH4 = 27, N2O = 273)
GWP_BASES  <- list(AR4 = c(CH4 = 25, N2O = 298),
                   AR5 = c(CH4 = 28, N2O = 265),
                   AR6 = c(CH4 = 27, N2O = 273))

# GWP100 the fallback below assumes when a unit string does not name its own
# basis: the source notebooks' own reading, AR5.
FALLBACK_GWP_AR5 <- c(CH4 = 28, N2O = 265)

# What a Prices|GHG Emission unit string takes to reach USD17MER per tC, for
# one pollutant. Two things ride on it and both are silent when guessed wrong:
# the dollar year the value is stated in, and whether it is already per tCO2 or
# still per tCO2-equivalent (needing a GWP divided out before the 44/12 mass
# step to carbon). When the string does not say, this falls back to the source
# notebooks' own reading -- 2005 dollars, tCO2-equivalent on an AR5 GWP -- and
# names the assumption rather than taking the fallback silently.
price_unit_conversion <- function(unit, pollutant, pcfg) {
  u <- tolower(unit)
  assumed <- character(0)

  if (grepl("2017", u, fixed = TRUE)) {
    dollar_factor <- 1
  } else if (grepl("2010", u, fixed = TRUE)) {
    dollar_factor <- 1 / DEFLATOR_2010_TO_2017
  } else if (grepl("2005", u, fixed = TRUE)) {
    dollar_factor <- 1 / pcfg$currency_2005_to_2017
  } else {
    assumed <- c(assumed, paste0("unit '", unit, "' does not name a dollar year; assumed 2005"))
    dollar_factor <- 1 / pcfg$currency_2005_to_2017
  }

  is_tc  <- grepl("/tc$", u) || grepl("/t c$", u)
  is_eq  <- grepl("co2[ -]?eq", u)
  is_co2 <- grepl("tco2", u) || grepl("t co2", u, fixed = TRUE)

  if (is_tc) {
    mass_factor <- 1
  } else if (is_eq) {
    mass_factor <- (44 / 12) / FALLBACK_GWP_AR5[[pollutant]]
  } else if (is_co2) {
    mass_factor <- 44 / 12
  } else {
    assumed <- c(assumed, paste0("unit '", unit, "' does not name tC, tCO2 or tCO2eq; ",
                                 "assumed tCO2-equivalent"))
    mass_factor <- (44 / 12) / FALLBACK_GWP_AR5[[pollutant]]
  }

  list(factor = dollar_factor * mass_factor, assumed = assumed)
}

# The CH4/N2O global warming potential a mapping file is built on, read two
# ways depending on which map is in play.
#
# MM_linkage_mapping.csv (messageix/R/createMatrix_MM.R's map): its CH4 and N2O
# rows onto "Emissions|GHG|AFOLU (Mt CO2e/yr)" already report in the pollutant's
# own native mass unit, so the factor column *is* the GWP.
gwp_factors_from_mm_mapping <- function(path) {
  if (!file.exists(path)) log_die("MM_linkage_mapping.csv not found: ", path)
  m <- utils::read.delim(path, sep = ";", comment.char = "#", stringsAsFactors = FALSE)
  ghg_rows <- m[grepl("GHG|AFOLU", m$Variable, fixed = TRUE), , drop = FALSE]
  ch4 <- ghg_rows$factor[grepl("^Emissions\\|CH4", ghg_rows$piam_variable)]
  n2o <- ghg_rows$factor[grepl("^Emissions\\|N2O", ghg_rows$piam_variable)]
  if (!length(ch4) || !length(n2o)) {
    log_die(path, " has no CH4 and N2O row mapped onto Emissions|GHG|AFOLU")
  }
  c(CH4 = ch4[1], N2O = n2o[1])
}

# pollutant_map.txt (messageix/feedback_prep/prep_carbon_price.R's map, read
# with its own read_pollutant_map()): ch4 is priced per t CH4, so its factor is
# the GWP directly; n2o_n_direct is priced per t N and carries a 44/28 mass
# conversion to t N2O on top of the GWP, backed out here so both readings land
# on the same basis.
gwp_factors_from_pollutant_map <- function(path) {
  map <- read_pollutant_map(path)
  ch4 <- map$factor[map$pollutant == "ch4"]
  n2o <- map$factor[map$pollutant == "n2o_n_direct"]
  if (!length(ch4) || !length(n2o) || is.na(ch4[1]) || is.na(n2o[1])) {
    log_die(path, " has no ch4 and n2o_n_direct factor to read a GWP from")
  }
  c(CH4 = ch4[1], N2O = n2o[1] / (44 / 28))
}

vet_post_checks <- function() {
  list(
    nonco2_cap_readback = list(
      describe = "the Peatland non-CO2 price never exceeds the experiment's cap",
      fn = function(ctx) vet_try({
        grid <- .stage3_runs_present(ctx$pcfg)
        if (!nrow(grid)) {
          return(vet_result("WARN", paste0("no stage-3 run folders found under ",
                                           results_folder(ctx$pcfg, 3L))))
        }
        cap <- ctx$pcfg$nonco2_price_cap_usd17_tc
        tol <- max(1e-6, 1e-6 * abs(cap))
        over <- character(0)
        assumed <- character(0)
        checked <- 0L

        for (k in seq_len(nrow(grid))) {
          mif <- file.path(grid$folder[k], MIF_NAME)
          if (!file.exists(mif)) next
          long <- report_long(mif, NONCO2_PRICE_VARS)
          if (!nrow(long)) next
          for (r in seq_len(nrow(long))) {
            if (is.na(long$value[r])) next
            pollutant <- if (grepl("CH4", long$Variable[r], fixed = TRUE)) "CH4" else "N2O"
            conv <- price_unit_conversion(long$Unit[r], pollutant, ctx$pcfg)
            assumed <- union(assumed, conv$assumed)
            usd17_tc <- long$value[r] * conv$factor
            checked <- checked + 1L
            if (is.finite(usd17_tc) && usd17_tc > cap + tol) {
              over <- c(over, sprintf("%s %s y%d: %.4g USD17MER/tC", grid$title[k],
                                      pollutant, long$year[r], usd17_tc))
            }
          }
        }
        if (!checked) {
          return(vet_result("WARN", paste0("no '", paste(NONCO2_PRICE_VARS, collapse = "', '"),
                                           "' rows found in any stage-3 report.mif")))
        }
        if (length(over)) {
          return(vet_result("FAIL", paste0(
            length(over), " of ", checked, " Peatland price reading(s) exceed the cap of ",
            cap, " USD17MER/tC: ", paste(over, collapse = "; "))))
        }
        detail <- paste0(checked, " Peatland price reading(s) across ", nrow(grid),
                         " run(s) held under ", cap, " USD17MER/tC")
        if (length(assumed)) detail <- paste0(detail, ". ", paste(assumed, collapse = "; "))
        vet_result("PASS", detail)
      })),

    bioenergy_monotonicity = list(
      describe = "World 2nd-gen bioenergy production is non-decreasing in the BE price, per GHG level",
      fn = function(ctx) vet_try({
        grid <- .stage3_runs_present(ctx$pcfg)
        if (!nrow(grid)) {
          return(vet_result("WARN", paste0("no stage-3 run folders found under ",
                                           results_folder(ctx$pcfg, 3L))))
        }
        pieces <- list()
        for (k in seq_len(nrow(grid))) {
          mif <- file.path(grid$folder[k], MIF_NAME)
          if (!file.exists(mif)) next
          long <- report_long(mif, BE_PRODUCTION_VAR)
          long <- long[long$Region %in% c("World", "GLO"), , drop = FALSE]
          if (!nrow(long)) next
          pieces[[length(pieces) + 1L]] <- data.frame(
            be = grid$be[k], ghg = grid$ghg[k], year = long$year, value = long$value)
        }
        if (!length(pieces)) {
          return(vet_result("WARN", paste0("no World/GLO '", BE_PRODUCTION_VAR,
                                           "' rows found in any stage-3 report.mif")))
        }
        all <- do.call(rbind, pieces)
        inverted <- character(0)
        for (g in sort(unique(all$ghg))) {
          for (y in sort(unique(all$year[all$ghg == g]))) {
            sub <- all[all$ghg == g & all$year == y, ]
            sub <- sub[order(sub$be), ]
            if (nrow(sub) < 2L || anyNA(sub$value)) next
            d <- diff(sub$value)
            bad <- which(d < -1e-6)
            for (b in bad) {
              inverted <- c(inverted, sprintf("y%d %s %s->%s: %.4g -> %.4g",
                                              y, ghg_token(g), be_token(sub$be[b]),
                                              be_token(sub$be[b + 1L]), sub$value[b],
                                              sub$value[b + 1L]))
            }
          }
        }
        if (length(inverted)) {
          return(vet_result("WARN", paste0(length(inverted), " inversion(s) -- solver noise at ",
                                           "small margins is common, read before trusting the ",
                                           "matrix: ", paste(inverted, collapse = "; "))))
        }
        vet_result("PASS", paste0(nrow(all), " (BE, GHG, year) point(s) checked, all monotone"))
      })),

    gwp_basis = list(
      describe = "the pollutant map in use carries AR6 GWP100 factors (CH4=27, N2O=273)",
      fn = function(ctx) vet_try({
        if (!is.null(ctx$pollutant_map)) {
          found <- gwp_factors_from_pollutant_map(ctx$pollutant_map)
          source_label <- ctx$pollutant_map
        } else {
          mm_path <- file.path(data_dir(), "MM_linkage_mapping.csv")
          found <- gwp_factors_from_mm_mapping(mm_path)
          source_label <- mm_path
        }
        mismatch <- abs(found - AR6_GWP100) > 0.5
        if (any(mismatch)) {
          basis_hit <- vapply(GWP_BASES, function(b) all(abs(found - b) <= 0.5), logical(1))
          matched <- names(GWP_BASES)[basis_hit]
          return(vet_result("FAIL", paste0(
            source_label, " carries CH4=", found[["CH4"]], ", N2O=", found[["N2O"]],
            if (length(matched)) paste0(" (", matched[1L], " values)") else " (no known basis)",
            "; AR6 GWP100 wants CH4=27, N2O=273. Three bases are in circulation and none says ",
            "so on its own: AR4 25/298, AR5 28/265, AR6 27/273. A price built on one basis and ",
            "read by a run assuming another passes every structural check and is wrong in ",
            "every run.")))
        }
        vet_result("PASS", paste0(source_label, ": CH4=", found[["CH4"]], ", N2O=", found[["N2O"]]))
      }))
  )
}

# ---- the report -------------------------------------------------------------

# Run every check and return the report. Stops on any FAIL unless warn_only,
# in which case the caller reads the returned frame.
vet_post_matrix <- function(pcfg, pollutant_map = NULL, warn_only = FALSE) {
  ctx <- list(pcfg = pcfg, pollutant_map = pollutant_map)
  checks <- vet_post_checks()

  log_banner("post-run matrix vetting", list(
    experiment = pcfg$experiment,
    "run dir"  = dirname(results_folder(pcfg, 3L)),
    checks     = length(checks)))

  rows <- lapply(names(checks), function(id) {
    spec <- checks[[id]]
    # Two layers of vet_try on purpose, as in vet_pre_run.R: a check body wraps
    # its own so a failure inside becomes that check's FAIL, and this one
    # catches a body that dies before its own wrapper.
    res <- vet_try(spec$fn(ctx))
    log_step("CHECK", sprintf("%-22s %-4s %s", id, res$status,
                              if (nzchar(res$detail)) res$detail else spec$describe))
    data.frame(check = id, status = res$status, describe = spec$describe,
               detail = res$detail, stringsAsFactors = FALSE)
  })
  report <- do.call(rbind, rows)

  failed <- report$check[report$status == "FAIL"]
  warned <- report$check[report$status == "WARN"]
  if (length(warned)) log_warn(length(warned), " check(s) to read: ", warned)
  if (length(failed)) {
    if (isTRUE(warn_only)) {
      log_warn(length(failed), " check(s) failed: ", failed, " (--warn-only)")
    } else {
      log_die(length(failed), " post-run check(s) failed: ", paste(failed, collapse = ", "),
              ". The matrix built from this sweep is not to be trusted until they are read")
    }
  } else {
    log_step("DONE", "post-run matrix vetting passed for experiment ", pcfg$experiment)
  }
  invisible(report)
}

# ---- command line -----------------------------------------------------------

if (invoked_directly("vet_post_matrix.R")) {
  usage <- paste(sub("^# \\|", "", grep("^# \\|",
                 readLines("messageix/vetting/vet_post_matrix.R"), value = TRUE)), collapse = "\n")
  flags <- parse_flags(commandArgs(trailingOnly = TRUE),
                       known = c("experiment", "pollutant-map"),
                       flags = c("help", "warn-only"), repeatable = c("set"), usage = usage)
  if (isTRUE(flags$help)) { log_report(usage); quit(status = 0) }
  pcfg <- config_from_flags(flags, cli_overrides(flags$set))
  vet_post_matrix(pcfg, pollutant_map = flags[["pollutant-map"]],
                  warn_only = isTRUE(flags[["warn-only"]]))
}
