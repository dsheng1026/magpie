# |  Build the patch tarball stage 3 reads. This is the pipeline step patch_step3.
# |
# |  Stage 3 imposes bioenergy as a demand trajectory and sweeps the GHG price,
# |  so it needs two overridden input files:
# |
# |    f60_bioenergy_dem.cs3    the base scenario columns plus one column per
# |                             bioenergy price level, holding the second-
# |                             generation bioenergy production the matching
# |                             stage-2 run settled on
# |    f56_pollutant_prices.cs3 the base scenario columns plus one column per
# |                             GHG price level of the preset
# |
# |      7 stage-2 fulldata.gdx  ->  reportProductionBioenergy  ->  f60 columns
# |      caller-supplied file    ->                                 f56 columns
# |                              ->  patch_input/<preset>_demand_<hash>.tgz
# |
# |  Appending the columns is what makes them selectable. When MAgPIE unpacks
# |  input tarballs it reads the scenario column names out of the files that
# |  arrived and writes them into its own GAMS set files. So a column named
# |  "default_BE10" appended to f60_bioenergy_dem.cs3 becomes a name
# |  cfg$gms$c60_2ndgen_biodem can ask for, with nobody editing a set file. Those
# |  set files are written by the machine; never edit them by hand.
# |
# |  Nothing here builds the f56 file. The G####exp2110 GHG price trajectories
# |  are not generated anywhere in this repository, and what their labels mean --
# |  which price level, in which year and currency, and what growth rate the
# |  "exp2110" extension applies out to 2110 -- cannot be worked out from the
# |  code around them. This step therefore takes the file from whoever runs it
# |  (--f56=PATH), checks it against the narrative, and stops with a message saying
# |  what is missing when it is not there. It will not guess: a wrong trajectory
# |  would change all 84 stage-3 runs while looking entirely plausible.
# |
# |  The non-CO2 price cap is not expected inside f56. Supply uncapped
# |  trajectories: cfg$gms$s56_limit_ch4_n2o_price applies the cap inside GAMS
# |  to whichever scenario c56_pollutant_prices selects, so changing
# |  nonco2_price_cap_usd17_tc needs no file inside any tarball edited.
# |
# |  Usage
# |    Rscript messageix/patches/build_step3_patch.R --f56=PATH [flags]   (from the model root)
# |
# |    --f56=PATH           f56_pollutant_prices.cs3 carrying the preset's GHG
# |                         price columns; required
# |    --preset=NAME        narrative column of the narratives file (default "default")
# |    --csv=PATH           narratives file (default: default_preset_csv())
# |    --set=key=value      override one setting; repeatable. Any narrative or
# |                         infrastructure key; see messageix/docs/parameters.md
# |    --seed=PATH          f60_bioenergy_dem.cs3 to append to (default
# |                         modules/60_bioenergy/input/f60_bioenergy_dem.cs3,
# |                         which any prior run has already unpacked there)
# |    --help
# |
# |  Every option is accepted as --key=value and as --key value.
# |
# |  The tarball name is narrated as ">> PACK: ..." and repeated bare on the
# |  last line of stdout. In-process callers source this file and use the
# |  return value:
# |
# |      pcfg <- resolve_config("default")
# |      pcfg <- with_patch(pcfg, 3, build_step3_patch(pcfg, f56 = "…/f56_pollutant_prices.cs3"))
# |
# |  Interface
# |    GAP_FILL_YEARS / GAP_FILL_HOLD_FROM / HIST_YEARS / HIST_VALUES  documented defaults
# |    gap_fill_years(x, years, hold_from)  -> magpie object with no year gaps
# |    sort_years(x, years)                 -> magpie object, years ascending
# |    zero_history(x, hist_years, hist_values) -> magpie object
# |    taxable_pollutants(sets_file)        -> chr; GAMS set pollutants(pollutants_all)
# |    seed_required_columns(input_gms)     -> chr; f60 columns GAMS dereferences unconditionally
# |    assert_seed(seed, pcfg)              -> invisible(TRUE)
# |    assert_stage2_complete(pcfg)         -> invisible(TRUE); all 7 runs present and solved
# |    extract_bioenergy_column(pcfg, be)   -> magpie object, PJ per yr, one scenario column
# |    validate_f56(path, pcfg)             -> invisible(TRUE)
# |    build_step3_patch(pcfg, f56, seed)   -> chr(1); tarball name
# |
# |  Dependencies: magclass, magpie4, and messageix/patches/build_step2_patch.R
# |  for pack_patch() and the shared CLI helpers, which brings the messageix/R/
# |  layer with it (including the solvedness contract shared with the matrix
# |  builders). The two generators write into the same patch directory under the
# |  same naming and archive-layout contract, and that contract is defined once,
# |  there. Run from the MAgPIE model root.

# build_step2_patch.R brings the shared packing and CLI helpers, and with them
# the whole messageix/R/ layer.
if (!exists("pack_patch", mode = "function")) source("messageix/patches/build_step2_patch.R")

# ---- documented defaults ----------------------------------------------------

# The five-year grid the bioenergy columns are written on. MAgPIE's full year set
# runs to 2150 while a run reports only the time steps it solved, so the grid is
# wider than any one run's output and the gaps are filled in below.
GAP_FILL_YEARS <- seq(1995, 2150, by = 5)

# Years at or after this one take this year's value instead of being
# interpolated: past 2100 there is no later reported year to average against, so
# the level is held flat. That is the documented convention of this pipeline.
GAP_FILL_HOLD_FROM <- 2100

# Second-generation bioenergy is set to zero over the historical period, in
# mio. GJ per yr. It was not deployed at any scale in these years, and MAgPIE
# harmonises its early years against a reference path regardless, so the values
# do not move results. Replacing HIST_VALUES with a vector of non-zero values
# needs no other change: it is recycled across regions and years.
HIST_YEARS  <- c("y1995", "y2000", "y2005", "y2010", "y2015")
HIST_VALUES <- 0

# The second-generation bioenergy row of MAgPIE's bioenergy production report.
# Matched on the start of the name, because the report appends the unit to it.
BIOENERGY_VARIABLE <- "2nd generation|++"

# EJ per yr -> PJ per yr. The bioenergy report comes out in EJ per yr, while
# f60_bioenergy_dem is declared in mio. GJ per yr, and one mio. GJ is one PJ.
EJ_TO_PJ <- 1000

# ---- year handling ----------------------------------------------------------

# Fill in the years a run did not report. Before hold_from, a missing year takes
# the average of the years either side of it on the five-year grid, so the later
# one has to be there. Two missing years in a row means a broken report rather
# than something to interpolate through, and stops here instead of spreading
# empty values onward.
gap_fill_years <- function(x, years = GAP_FILL_YEARS, hold_from = GAP_FILL_HOLD_FROM) {
  hold_year <- paste0("y", hold_from)
  for (year in years) {
    name <- paste0("y", year)
    if (name %in% magclass::getYears(x)) next
    if (year < hold_from) {
      neighbours <- paste0("y", c(year - 5, year + 5))
      absent <- setdiff(neighbours, magclass::getYears(x))
      if (length(absent)) {
        log_die("gap_fill_years: ", name, " is missing and so is ", absent,
                "; adjacent-year averaging needs both neighbours")
      }
      value <- (x[, neighbours[1L], ] + x[, neighbours[2L], ]) / 2
    } else {
      if (!hold_year %in% magclass::getYears(x)) {
        log_die("gap_fill_years: ", name, " is missing and ", hold_year,
                " is not available to hold it at")
      }
      value <- x[, hold_year, ]
    }
    x <- magclass::add_columns(x, addnm = name, dim = 2, fill = NA)
    x[, name, ] <- value
  }
  x
}

# Keep the grid years only and put them in ascending order. Filled-in years are
# added at the end, so without this the file would be written with its years out
# of order.
sort_years <- function(x, years = GAP_FILL_YEARS) {
  x[, paste0("y", years), ]
}

# Overwrite the historical period. See HIST_YEARS / HIST_VALUES.
zero_history <- function(x, hist_years = HIST_YEARS, hist_values = HIST_VALUES) {
  absent <- setdiff(hist_years, magclass::getYears(x))
  if (length(absent)) log_die("zero_history: no such year in the data: ", absent)
  x[, hist_years, ] <- hist_values
  x
}

# ---- the f60 seed -----------------------------------------------------------

# Two bioenergy demand columns MAgPIE looks up by name in every run, whichever
# scenario was selected. A starting file missing either one stops the run on an
# unknown set element:
#   c60_2ndgen_biodem_noselect  the demand path applied in regions outside the
#                               selected policy set; its name is MAgPIE's own
#                               default, read out of the module settings
#   R32M46-SSP2EU-NPi           the path every run's early years are harmonised
#                               against, named directly in the model code
# This is why the new columns are appended to the base tarball's own file rather
# than written into a fresh one holding only what this step produced.
seed_required_columns <- function(
    input_gms = "modules/60_bioenergy/1st2ndgen_priced_feb24/input.gms") {
  if (!file.exists(input_gms)) {
    log_die("seed_required_columns: ", input_gms, " not found; run from the MAgPIE model root")
  }
  lines <- readLines(input_gms, warn = FALSE)
  hit <- grep("^\\$setglobal[[:space:]]+c60_2ndgen_biodem_noselect[[:space:]]", lines)
  if (!length(hit)) {
    log_die("seed_required_columns: no c60_2ndgen_biodem_noselect setglobal in ", input_gms)
  }
  noselect <- trimws(sub("^\\$setglobal[[:space:]]+c60_2ndgen_biodem_noselect[[:space:]]+", "",
                         lines[hit[1L]]))
  unique(c(noselect, "R32M46-SSP2EU-NPi"))
}

# The starting file must be f60_bioenergy_dem.cs3 as it comes in the base input
# tarball: it has to carry the two columns above, and none of the columns this
# step is about to add. Appending to an already-patched file would list the same
# scenario name twice.
assert_seed <- function(seed, pcfg) {
  if (!file.exists(seed)) {
    log_die("the bioenergy demand file to append to was not found: ", seed,
            ". It is f60_bioenergy_dem.cs3 as it comes in the base input tarballs, which any ",
            "earlier run has already unpacked into modules/60_bioenergy/input/. Run a stage ",
            "first so the inputs are unpacked, or name the file with --seed=PATH")
  }
  columns <- magclass::getNames(magclass::read.magpie(seed))
  required <- seed_required_columns()
  absent <- setdiff(required, columns)
  if (length(absent)) {
    log_die("the bioenergy demand file ", seed, " is missing the scenario column(s) ", absent,
            ", which MAgPIE looks up in every run. This is not the base tarball's own file")
  }
  new_columns <- vapply(pcfg$be_prices, function(be) scen_column(pcfg, be), character(1))
  clash <- intersect(new_columns, columns)
  if (length(clash)) {
    log_die("the bioenergy demand file ", seed, " already carries ", clash,
            ". Start from the unpatched base file, not from one an earlier patch tarball wrote")
  }
  invisible(TRUE)
}

# ---- stage-2 extraction -----------------------------------------------------

# Every stage-2 run has to be there and solved before anything is read out of
# them. A patch tarball built from six runs out of seven yields 84 stage-3 runs
# trained on a gap, and nothing downstream can tell. A run whose solve status
# cannot be read at all counts as unusable here: each of these runs becomes one
# column of the patch tarball, and a column nobody can vouch for does not belong
# in it.
assert_stage2_complete <- function(pcfg) {
  runs <- expected_run_folders(pcfg, 2L)
  assert_runs_solved(runs, where = dirname(results_folder(pcfg, 2L)), strict = TRUE,
                     closing = paste("Re-run or resubmit the listed runs.",
                                     "No patch tarball is written."))
}

# Second-generation bioenergy production of one stage-2 run, in PJ per yr, named
# as the column stage 3 will select with c60_2ndgen_biodem.
extract_bioenergy_column <- function(pcfg, be) {
  folder <- locate_run_folder(pcfg, 2L, be = be)
  if (is.na(folder)) log_die("stage-2 run folder not found: ", run_folder(pcfg, 2L, be = be))
  gdx <- file.path(folder, RUN_GDX_FILE)
  report <- magpie4::reportProductionBioenergy(gdx, detail = FALSE, level = "reg")
  report <- report[, , BIOENERGY_VARIABLE, pmatch = TRUE]
  # Exactly one hit, not at least one: a prefix that matched two variables would
  # reach magclass::setNames() with a name of the wrong length and fail there,
  # in a message about magclass rather than about the report.
  hits <- if (!length(report)) 0L else magclass::ndata(report)
  if (hits != 1L) {
    log_die("extract_bioenergy_column: the report of ", gdx, " holds ", hits,
            " variable(s) matching the prefix '", BIOENERGY_VARIABLE, "'",
            if (hits > 1L) paste0(" (", paste(magclass::getNames(report), collapse = ", "), ")") else "",
            "; exactly one is required")
  }
  magclass::setNames(report * EJ_TO_PJ, scen_column(pcfg, be))
}

# Global total of one scenario column in one year, in EJ per yr. This is the
# number the checks below are made on.
global_bioenergy_ej <- function(x, year = "y2100") {
  if (!year %in% magclass::getYears(x)) {
    log_die("global_bioenergy_ej: no ", year, " in the data")
  }
  totals <- as.vector(magclass::dimSums(x[, year, ], dim = 1)) / EJ_TO_PJ
  stats::setNames(totals, magclass::getNames(x))
}

# ---- f56 --------------------------------------------------------------------

# The pollutants MAgPIE is able to put a price on, read out of the model's own
# declaration rather than copied here: a second copy would quietly go out of date
# at the next MAgPIE version.
taxable_pollutants <- function(sets_file = "modules/56_ghg_policy/price_aug22/sets.gms") {
  if (!file.exists(sets_file)) {
    log_die("taxable_pollutants: ", sets_file, " not found; run from the MAgPIE model root")
  }
  lines <- readLines(sets_file, warn = FALSE)
  start <- grep("pollutants\\(pollutants_all\\)", lines)
  if (!length(start)) log_die("taxable_pollutants: no pollutants set declared in ", sets_file)
  block <- paste(lines[start[1L]:min(start[1L] + 20L, length(lines))], collapse = " ")
  spec <- sub("^[^/]*/", "", block)
  spec <- sub("/.*$", "", spec)
  members <- trimws(strsplit(spec, ",", fixed = TRUE)[[1L]])
  members <- members[nzchar(members)]
  if (!length(members)) log_die("taxable_pollutants: empty pollutants set in ", sets_file)
  members
}

# What the person running this has to obtain, and from whom. Deliberately long:
# this is the one input the pipeline cannot rebuild for itself, and a terse
# "file missing" would send the reader hunting for a generator that does not
# exist. It is printed as a report rather than raised, because R cuts a stop()
# message off after about a thousand characters and the instruction at the end of
# this one is the part that matters.
f56_missing_message <- function(pcfg) {
  wanted <- vapply(pcfg$ghg_prices, function(g) ghg_scenario(pcfg, g), character(1))
  paste0(
    ">> FATAL: no GHG price file was given (--f56=PATH), and nothing in this repository\n",
    "  can build one.\n",
    "  What is needed: a cs3 file over (t_all, i, pollutants, ghgscen56) in USD17MER per t,\n",
    "  with one column per GHG price level of narrative '", pcfg$preset, "':\n    ",
    paste(wanted, collapse = ", "), "\n",
    "  Why it is not built here: nothing in this repository generates these columns, and what\n",
    "  their labels mean -- which price level ", wanted[length(wanted)], " stands for, in which year and\n",
    "  currency, and what growth rate the '", pcfg$ghg_price_scenario_suffix, "' extension applies -- cannot be\n",
    "  worked out from the code around them. Guessing at them from the labels would change\n",
    "  every stage-3 run while looking plausible, so this step refuses to guess.\n",
    "  What to do: ask Di Sheng for the script that builds these trajectories, or for the\n",
    "  SSP2_demand_cap.tgz tarball, and take f56_pollutant_prices.cs3 out of it\n",
    "  (tar xzf <tarball> f56_pollutant_prices.cs3). Then run this command again with\n",
    "  --f56=<that file>.\n",
    "  One thing to check when you ask: the non-CO2 price cap is NOT expected inside the\n",
    "  file. The trajectories must be uncapped. The cap is applied inside GAMS by\n",
    "  cfg$gms$s56_limit_ch4_n2o_price, set from nonco2_price_cap_usd17_tc (",
    pcfg$nonco2_price_cap_usd17_tc, " USD17MER per tC for this narrative).")
}

# Check the supplied GHG price file against the narrative before it is packed. A
# column stage 3 asks for but the file does not carry fails inside GAMS 84 times
# over, one run at a time, hours after the runs were submitted.
#
# The order of the two sub-dimensions is fixed, not a matter of taste. MAgPIE
# declares the table as f56_pollutant_prices(t_all, i, pollutants, ghgscen56) --
# pollutant first, scenario second -- and it builds its list of selectable GHG
# price scenarios by reading the second sub-dimension of whatever file arrives.
# A file written the other way round therefore turns the pollutant names into
# the scenario list, and every column stage 3 asks for fails to resolve. Hence
# the check on the first sub-dimension rather than a guess at which is which.
validate_f56 <- function(path, pcfg) {
  if (!file.exists(path)) log_die("--f56: file not found: ", path)
  x <- magclass::read.magpie(path)
  parts <- strsplit(magclass::getNames(x), ".", fixed = TRUE)
  widths <- unique(lengths(parts))
  if (length(widths) != 1L || widths != 2L) {
    log_die("--f56: ", path, " does not carry a (pollutant, scenario) column structure; ",
            "expected a cs3 over (t_all, i, pollutants, ghgscen56)")
  }
  found_pollutants <- unique(vapply(parts, `[`, character(1), 1L))
  found_scenarios  <- unique(vapply(parts, `[`, character(1), 2L))
  pollutants <- taxable_pollutants()

  if (!setequal(found_pollutants, pollutants)) {
    if (setequal(found_scenarios, pollutants)) {
      log_die("--f56: ", path, " has its two sub-dimensions the wrong way round. The first ",
              "holds ", found_pollutants, " and the second holds ", found_scenarios,
              ", but MAgPIE expects the pollutant first and the scenario second, and builds its ",
              "list of selectable GHG price scenarios from the second one. As written, the ",
              "pollutant names would become the scenario list and no run could find its ",
              "c56_pollutant_prices column. Rewrite the file with the pollutant first.")
    }
    absent <- setdiff(pollutants, found_pollutants)
    if (length(absent)) {
      log_die("--f56: ", path, " prices no value for pollutant(s) ", absent,
              "; the GAMS set pollutants requires all of ", pollutants)
    }
    log_die("--f56: ", path, " prices pollutant(s) ", setdiff(found_pollutants, pollutants),
            " that the GAMS set pollutants does not declare; it requires exactly ", pollutants)
  }

  wanted <- vapply(pcfg$ghg_prices, function(g) ghg_scenario(pcfg, g), character(1))
  absent <- setdiff(wanted, found_scenarios)
  if (length(absent)) {
    log_die("--f56: ", path, " carries no scenario column(s) ", absent,
            ", which stage 3 selects with c56_pollutant_prices under preset '", pcfg$preset, "'")
  }
  years <- timestep_years(configured_timesteps(pcfg))
  absent <- setdiff(years, magclass::getYears(x))
  if (length(absent)) {
    log_die("--f56: ", path, " covers no value for model year(s) ", absent)
  }
  if (any(is.na(as.vector(x)))) log_die("--f56: ", path, " contains NA")
  invisible(TRUE)
}

# ---- generator --------------------------------------------------------------

# Build the stage-3 patch tarball and return its name.
#
#   pcfg  resolved preset
#   f56   f56_pollutant_prices.cs3 to bundle; required (see f56_missing_message)
#   seed  f60_bioenergy_dem.cs3 to append the new columns to; defaults to the
#         base tarball's own file in modules/60_bioenergy/input/
build_step3_patch <- function(pcfg, f56 = NULL, seed = NULL) {
  assert_magpie_root()
  # The GHG price file is checked first. It is the one input this repository
  # cannot produce, and on a fresh checkout a complaint about the bioenergy
  # starting file would otherwise arrive before it and hide it.
  if (is.null(f56)) {
    log_report(f56_missing_message(pcfg))
    log_die("no GHG price file was given (--f56=PATH). What the file has to contain, and who ",
            "to ask for it, is printed in full above.")
  }
  if (is.null(seed)) seed <- "modules/60_bioenergy/input/f60_bioenergy_dem.cs3"
  assert_seed(seed, pcfg)
  validate_f56(f56, pcfg)
  assert_stage2_complete(pcfg)

  stage_dir <- tempfile("mm_patch_demand_")
  dir.create(stage_dir, recursive = TRUE)
  on.exit(unlink(stage_dir, recursive = TRUE), add = TRUE)

  staged_f60 <- file.path(stage_dir, "f60_bioenergy_dem.cs3")
  if (!file.copy(seed, staged_f60)) log_die("cannot stage the f60 seed from ", seed)

  columns <- NULL
  for (be in pcfg$be_prices) {
    column <- extract_bioenergy_column(pcfg, be)
    column <- gap_fill_years(column)
    column <- sort_years(column)
    column <- zero_history(column)
    if (any(is.na(as.vector(column)))) {
      log_die("bioenergy column ", magclass::getNames(column), " carries NA after gap filling ",
              "and historical zeroing; the stage-2 report of ", run_title(pcfg, 2L, be = be),
              " has a hole the 5-year grid cannot close. GAMS would read those cells as zero.")
    }
    magclass::write.magpie(column, file_name = staged_f60, file_type = "cs3", append = TRUE)
    columns <- magclass::mbind(columns, column)
    log_step("EXTRACT", magclass::getNames(column), ": ",
             round(global_bioenergy_ej(column), 2), " EJ per yr global in 2100")
  }

  # Read the file back and check it says what was just written. Cheap, and this
  # is the point at which an append can silently misalign years or regions.
  written <- magclass::read.magpie(staged_f60)
  written <- written[, , magclass::getNames(columns)]
  delta <- max(abs(global_bioenergy_ej(written) - global_bioenergy_ej(columns)))
  if (delta > 1e-6) {
    log_die("the bioenergy columns read back out of ", staged_f60, " disagree with what was ",
            "written by ", signif(delta, 4), " EJ per yr. The append misaligned years or regions")
  }
  log_step("CHECK", "f60 carries ", magclass::ndata(written), " new scenario column(s) over ",
           length(magclass::getYears(written)), " years; round-trip agrees")

  # Does supply rise with price? Every stage-2 run sits at the same zero GHG
  # price, so the only thing separating these columns is the bioenergy price, and
  # supply should not fall as that price rises. A warning rather than a stop: a
  # small inversion can be a solver artefact where the response is nearly flat,
  # while a large one means the sweep is not measuring what the stage claims.
  # The numbers are printed so the reader can tell which of the two it is.
  totals <- global_bioenergy_ej(columns)
  falls <- which(diff(totals) < 0)
  if (length(falls)) {
    log_warn("second-generation bioenergy supply in 2100 falls as the bioenergy price rises: ",
             paste(sprintf("BE%s %.2f -> BE%s %.2f EJ per yr",
                           pcfg$be_prices[falls], totals[falls],
                           pcfg$be_prices[falls + 1L], totals[falls + 1L]),
                   collapse = "; "),
             ". Check the stage-2 runs at those levels before training on this patch.")
  } else {
    log_step("CHECK", "2100 supply is non-decreasing in the bioenergy price: ",
             paste(sprintf("%.2f", totals), collapse = " -> "), " EJ per yr")
  }

  staged_f56 <- file.path(stage_dir, "f56_pollutant_prices.cs3")
  if (!file.copy(f56, staged_f56)) log_die("cannot stage the f56 file from ", f56)
  log_step("CHECK", "f56 from ", f56, " carries the ", length(pcfg$ghg_prices),
           " GHG price column(s) of preset '", pcfg$preset, "', uncapped")

  name <- pack_patch(c(staged_f60, staged_f56), pcfg, 3L)
  log_step("PACK", file.path(patch_repo_dir(pcfg), name), " (2 files)")
  name
}

# ---- CLI entry point --------------------------------------------------------

.synopsis_step3 <- paste(
  "usage: Rscript messageix/patches/build_step3_patch.R --f56=PATH [--preset=NAME]",
  "[--csv=PATH] [--set=key=value] [--seed=PATH] [--help]")

.usage_step3 <- c(
  "Pack the inputs stage 3 reads into one patch tarball: the second-generation",
  "bioenergy demand the stage-2 runs settled on, one column per bioenergy price level,",
  "appended to f60_bioenergy_dem.cs3; and the GHG price trajectories, which you supply,",
  "as f56_pollutant_prices.cs3. Both go into",
  "<patch_repo>/<preset>_demand_<digest>.tgz.",
  "",
  "  Rscript messageix/patches/build_step3_patch.R --f56=PATH [flags]   (from the MAgPIE model root)",
  "",
  "Flags:",
  "  --f56=PATH        the GHG price trajectories for this narrative, as a cs3 file with",
  "                    one column per GHG price level. Required, and checked against the",
  "                    preset before anything is packed: nothing in this repository builds",
  "                    these trajectories. Run this script without --f56 and it prints",
  "                    what the file has to contain and who to ask for it.",
  "  --preset=NAME     narrative column of the narratives file (default: default)",
  paste0("  --csv=PATH        narratives file (default: ", default_preset_csv(), ")"),
  "  --set=key=value   override one setting for this build; repeatable. Any narrative or",
  "                    infrastructure key (bii_target, qos) -- the full list is in",
  "                    messageix/docs/parameters.md",
  "  --seed=PATH       the f60_bioenergy_dem.cs3 the new columns are appended to. The",
  "                    default is the copy any earlier run has already unpacked into",
  "                    modules/60_bioenergy/input/. It must be the base tarball's own",
  "                    file, not one an earlier patch tarball wrote.",
  "  --help            this text",
  "",
  "Every option is accepted as --key=value and as --key value.",
  "The tarball name is written as the last line of output, so a script can read it",
  "with `tail -n 1`. The name carries a digest of the contents: rebuilding the same",
  "inputs gives the same name, and changed inputs give a new one.")

if (invoked_directly("build_step3_patch.R")) {
  .opt <- parse_flags(commandArgs(trailingOnly = TRUE),
                      known      = c("preset", "csv", "f56", "seed"),
                      flags      = "help",
                      repeatable = "set",
                      aliases    = c("preset-csv" = "csv"),
                      usage      = .synopsis_step3)
  if (isTRUE(.opt$help)) {
    cat(.usage_step3, sep = "\n")
    cat("\n")
  } else {
    .pcfg <- config_from_flags(.opt, cli_overrides(.opt$set))
    log_step("CONFIG", "preset '", .pcfg$preset, "' from ", .pcfg$csv)
    .name <- build_step3_patch(.pcfg, f56 = .opt$f56, seed = .opt$seed)
    cat(.name, "\n", sep = "")
  }
}
