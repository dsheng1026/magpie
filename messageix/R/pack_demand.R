# |  Pack the inputs the demand sweep reads.
# |
# |  The demand sweep imposes bioenergy as a demand trajectory and sweeps the GHG
# |  price, so it needs two overridden input files:
# |
# |    f60_bioenergy_dem.cs3    the base scenario columns plus one column per
# |                             bioenergy price level, holding the second-
# |                             generation bioenergy production the matching
# |                             price-sweep run settled on
# |    f56_pollutant_prices.cs3 the base scenario columns plus one column per
# |                             GHG price level of the experiment
# |
# |      price sweep fulldata.gdx  ->  reportProductionBioenergy  ->  f60 columns
# |      caller-supplied file      ->                                 f56 columns
# |                                ->  patch_input/<experiment>_demand_<hash>.tgz
# |
# |  Appending the columns is what makes them selectable. When MAgPIE unpacks
# |  input tarballs it reads the scenario column names out of the files that
# |  arrived and writes them into its own GAMS set files. So a column named
# |  "default_BE10" appended to f60_bioenergy_dem.cs3 becomes a name
# |  cfg$gms$c60_2ndgen_biodem can ask for, with nobody editing a set file. Those
# |  set files are written by the machine; never edit them by hand.
# |
# |  Nothing here builds the f56 file. It is taken from whoever runs this step
# |  (--f56=PATH) and checked against the experiment -- the structure only: the
# |  columns it has to carry, the pollutants, the model years and that no value is
# |  missing. The prices in it are taken on trust, because nothing here can tell a
# |  plausible trajectory from the right one.
# |
# |  Run this script without --f56 and it prints the whole story: what the file
# |  has to contain, why this repository cannot build it, who to ask for it, and
# |  the one thing to check when asking (the trajectories must be uncapped). That
# |  message is where all of it is written down.
# |
# |  The pipeline packs this itself, on the way from the price phase to the
# |  demand phase. Run it by hand to rebuild the packed inputs alone.
# |
# |  Usage
# |    Rscript messageix/R/pack_demand.R --f56=PATH [flags]   (from the model root)
# |
# |    --f56=PATH           f56_pollutant_prices.cs3 carrying the experiment's GHG
# |                         price columns; required
# |    --experiment=NAME    an experiment of messageix/experiments.R (default "default")
# |    --set=key=value      override one setting; repeatable. Any lever of the
# |                         world (messageix/R/world_levers.R), the sampling plan,
# |                         or an infrastructure setting
# |                         (messageix/R/pipeline_infrastructure.R)
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
# |      pcfg <- with_patch(pcfg, 3, pack_demand(pcfg, f56 = "…/f56_pollutant_prices.cs3"))
# |
# |  A lever of the world whose mechanism is data contributes files here: every
# |  data lever registered for the demand phase is asked what it wants packed,
# |  and its files travel in this tarball beside the two above. See
# |  messageix/R/world_levers.R.
# |
# |  Interface
# |    GAP_FILL_YEARS / GAP_FILL_HOLD_FROM / HIST_YEARS / HIST_VALUES  documented defaults
# |    gap_fill_years(x, years, hold_from, settled) -> magpie object with no year gaps
# |    sort_years(x, years)                 -> magpie object, years ascending
# |    zero_history(x, hist_years, hist_values) -> magpie object
# |    taxable_pollutants(sets_file)        -> chr; GAMS set pollutants(pollutants_all)
# |    seed_required_columns(input_gms, preloop_gms) -> chr; f60 columns every run looks up
# |    assert_seed(seed, pcfg)              -> invisible(TRUE)
# |    assert_stage2_complete(pcfg)         -> invisible(TRUE); every price run present and solved
# |    extract_bioenergy_column(pcfg, be)   -> magpie object, PJ per yr, one scenario column
# |    validate_f56(path, pcfg)             -> invisible(TRUE)
# |    pack_demand(pcfg, f56, seed)   -> chr(1); tarball name
# |
# |  Dependencies: magclass, magpie4, readr/stringr/purrr, and
# |  messageix/R/pack_price.R
# |  for pack_patch() and the shared year helpers, which brings the messageix/R/
# |  layer with it (including the solvedness contract shared with the matrix
# |  builders). The two generators write into the same patch directory under the
# |  same naming and archive-layout contract, and that contract is defined once,
# |  there. Run from the MAgPIE model root.

# pack_price.R brings the shared packing and CLI helpers, and with them
# the whole messageix/R/ layer.
if (!exists("pack_patch", mode = "function")) source("messageix/R/pack_price.R")

# ---- documented defaults ----------------------------------------------------

# The five-year grid the bioenergy columns are written on. MAgPIE's full year set
# runs to 2150 while a run reports only the time steps it solved, so the grid is
# wider than any one run's output and the gaps are filled in below.
GAP_FILL_YEARS <- seq(1995, 2150, by = 5)

# Years at or after this one take this year's value instead of being
# interpolated: past 2100 there is no later reported year to average against, so
# the level is held flat. That is the documented convention of this pipeline.
#
# It makes 2100 the one year that cannot be filled in. Every earlier year on the
# grid can be averaged from its neighbours, but 2100 is what all the later ones
# are held at, so a run that does not report it stops the packing rather than
# being patched around. That is deliberate: 2100 is inside the horizon every run
# solves for, and a demand-sweep run that has not reported it has not finished
# reporting.
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
#
#   settled  years whose value is decided further down whatever the report says
#            -- the historical period, which zero_history() overwrites. There is
#            nothing to average for one of these, so it goes straight in at the
#            value it will end up with. It is still a missing year, and the
#            neighbours it would have been averaged from are still required: a
#            report with a hole in it is a broken report wherever the hole falls.
gap_fill_years <- function(x, years = GAP_FILL_YEARS, hold_from = GAP_FILL_HOLD_FROM,
                           settled = HIST_YEARS, settled_value = HIST_VALUES) {
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
      value <- if (name %in% settled) settled_value
               else (x[, neighbours[1L], ] + x[, neighbours[2L], ]) / 2
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
#   the noselect column       the demand path applied in regions outside the
#                             selected policy set. Its name is MAgPIE's own
#                             default for c60_2ndgen_biodem_noselect.
#   the harmonisation column  the path every run's early years are overwritten
#                             with, so that the near past is the same in all of
#                             them.
#
# Both names are read out of the bioenergy module's own code, not written down
# here: a MAgPIE version that renames either one then stops this step with a
# message naming the file that asks for it, instead of failing inside GAMS in
# every run of the sweep.
#
# This is also why the new columns are appended to the base tarball's own file
# rather than written into a fresh one holding only what this step produced.
seed_required_columns <- function(
    input_gms   = "modules/60_bioenergy/1st2ndgen_priced_feb24/input.gms",
    preloop_gms = "modules/60_bioenergy/1st2ndgen_priced_feb24/preloop.gms") {
  if (!file.exists(input_gms)) {
    log_die("seed_required_columns: ", input_gms, " not found; run from the MAgPIE model root")
  }
  lines <- readr::read_lines(input_gms, progress = FALSE)
  hit <- stringr::str_which(lines, "^\\$setglobal\\s+c60_2ndgen_biodem_noselect\\s")
  if (!length(hit)) {
    log_die("seed_required_columns: no c60_2ndgen_biodem_noselect setglobal in ", input_gms)
  }
  noselect <- lines[hit[1L]] |>
    stringr::str_remove("^\\$setglobal\\s+c60_2ndgen_biodem_noselect\\s+") |>
    stringr::str_trim()

  if (!file.exists(preloop_gms)) {
    log_die("seed_required_columns: ", preloop_gms, " not found; run from the MAgPIE model root")
  }
  # The harmonisation column is the one the module reads by a name written out in
  # full, rather than through a switch. Anything in %...% is a switch and is a
  # scenario the run selects, not a column every run needs.
  found <- stringr::str_match_all(
    readr::read_lines(preloop_gms, progress = FALSE),
    "f60_bioenergy_dem\\(\\s*t\\s*,\\s*i\\s*,\\s*\"([^\"%]+)\"\\s*\\)")
  harmonised <- unique(unlist(lapply(found, function(hit) hit[, 2L]), use.names = FALSE))
  harmonised <- harmonised[!is.na(harmonised) & nzchar(harmonised)]
  if (!length(harmonised)) {
    log_die("seed_required_columns: ", preloop_gms, " names no bioenergy demand column in full, ",
            "so the column every run's early years are harmonised against cannot be read out of ",
            "it. This version of the bioenergy module has moved or renamed it, and this check ",
            "has to move with it")
  }
  unique(c(noselect, harmonised))
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
            ", which MAgPIE looks up in every run -- their names come out of the bioenergy ",
            "module's own input.gms and preloop.gms. This is not the base tarball's own file")
  }
  new_columns <- purrr::map_chr(pcfg$prices_bioenergy, function(be) scen_column(pcfg, be))
  clash <- intersect(new_columns, columns)
  if (length(clash)) {
    log_die("the bioenergy demand file ", seed, " already carries ", clash,
            ". Start from the unpatched base file, not from one an earlier patch tarball wrote")
  }
  invisible(TRUE)
}

# ---- reading the price sweep ------------------------------------------------

# Every price-sweep run has to be there and solved before anything is read out
# of them. Inputs packed from six runs out of seven yield a demand sweep trained
# on a gap, and nothing downstream can tell. A run whose solve status cannot be
# read at all counts as unusable here: each of these runs becomes one column of
# the packed file, and a column nobody can vouch for does not belong in it.
assert_stage2_complete <- function(pcfg) {
  runs <- expected_run_folders(pcfg, 2L)
  assert_runs_solved(runs, where = dirname(results_folder(pcfg, 2L)), strict = TRUE,
                     closing = paste("Re-run or resubmit the listed runs.",
                                     "Nothing is packed."))
}

# Second-generation bioenergy production of one price-sweep run, in PJ per yr,
# named as the column the demand sweep will select with c60_2ndgen_biodem.
extract_bioenergy_column <- function(pcfg, be) {
  folder <- locate_run_folder(pcfg, 2L, be = be)
  if (is.na(folder)) log_die("price-sweep run folder not found: ", run_folder(pcfg, 2L, be = be))
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
  lines <- readr::read_lines(sets_file, progress = FALSE)
  start <- stringr::str_which(lines, stringr::fixed("pollutants(pollutants_all)"))
  if (!length(start)) log_die("taxable_pollutants: no pollutants set declared in ", sets_file)
  block <- paste(lines[start[1L]:min(start[1L] + 20L, length(lines))], collapse = " ")
  # The set members are what sits between the first pair of slashes.
  members <- block |>
    stringr::str_remove("^[^/]*/") |>
    stringr::str_remove("/.*$") |>
    stringr::str_split_1(",") |>
    stringr::str_trim()
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
  wanted <- vapply(pcfg$prices_ghg, function(g) ghg_scenario(pcfg, g), character(1))
  paste0(
    ">> FATAL: no GHG price file was given (--f56=PATH), and nothing in this repository\n",
    "  can build one.\n",
    "  What is needed: a cs3 file over (t_all, i, pollutants, ghgscen56) in USD17MER per t,\n",
    "  with one column per GHG price level of experiment '", pcfg$experiment, "':\n    ",
    paste(wanted, collapse = ", "), "\n",
    "  Why it is not built here: nothing in this repository generates these columns, and what\n",
    "  their labels mean -- which price level ", wanted[length(wanted)], " stands for, in which year and\n",
    "  currency, and what growth rate the '", pcfg$ghg_price_scenario_suffix, "' extension applies -- cannot be\n",
    "  worked out from the code around them. Guessing at them from the labels would change\n",
    "  every demand run while looking plausible, so this step refuses to guess.\n",
    "  What to do: ask Di Sheng for the script that builds these trajectories, or for the\n",
    "  SSP2_demand_cap.tgz tarball, and take f56_pollutant_prices.cs3 out of it\n",
    "  (tar xzf <tarball> f56_pollutant_prices.cs3). Then run this command again with\n",
    "  --f56=<that file>.\n",
    "  One thing to check when you ask: the non-CO2 price cap is NOT expected inside the\n",
    "  file. The trajectories must be uncapped. The cap is applied inside GAMS by\n",
    "  cfg$gms$s56_limit_ch4_n2o_price, set from nonco2_price_cap_usd17_tc (",
    pcfg$nonco2_price_cap_usd17_tc, " USD17MER per tC for this experiment).")
}

# Check the supplied GHG price file against the experiment before it is packed.
# A column the demand sweep asks for but the file does not carry fails inside
# GAMS once per run, hours after the runs were submitted.
#
# This is a check on the structure and on nothing else: the two sub-dimensions
# and their order, one column per GHG price level the experiment sweeps, every
# model year, and no missing value. The prices themselves are trusted. A file
# carrying the wrong trajectory under the right column name passes here and
# changes every demand run, which is why the file comes from the person who knows
# what is in it.
#
# The order of the two sub-dimensions is fixed, not a matter of taste. MAgPIE
# declares the table as f56_pollutant_prices(t_all, i, pollutants, ghgscen56) --
# pollutant first, scenario second -- and it builds its list of selectable GHG
# price scenarios by reading the second sub-dimension of whatever file arrives.
# A file written the other way round therefore turns the pollutant names into
# the scenario list, and every column the demand sweep asks for fails to resolve. Hence
# the check on the first sub-dimension rather than a guess at which is which.
validate_f56 <- function(path, pcfg) {
  if (!file.exists(path)) log_die("--f56: file not found: ", path)
  x <- magclass::read.magpie(path)
  parts <- stringr::str_split(magclass::getNames(x), stringr::fixed("."))
  widths <- unique(lengths(parts))
  if (length(widths) != 1L || widths != 2L) {
    log_die("--f56: ", path, " does not carry a (pollutant, scenario) column structure; ",
            "expected a cs3 over (t_all, i, pollutants, ghgscen56)")
  }
  found_pollutants <- unique(purrr::map_chr(parts, 1L))
  found_scenarios  <- unique(purrr::map_chr(parts, 2L))
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

  wanted <- vapply(pcfg$prices_ghg, function(g) ghg_scenario(pcfg, g), character(1))
  absent <- setdiff(wanted, found_scenarios)
  if (length(absent)) {
    log_die("--f56: ", path, " carries no scenario column(s) ", absent,
            ", which the demand sweep selects with c56_pollutant_prices under experiment '",
            pcfg$experiment, "'")
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

# Pack the demand sweep's inputs and return the tarball's name.
#
#   pcfg  resolved experiment
#   f56   f56_pollutant_prices.cs3 to bundle; required (see f56_missing_message)
#   seed  f60_bioenergy_dem.cs3 to append the new columns to; defaults to the
#         base tarball's own file in modules/60_bioenergy/input/
pack_demand <- function(pcfg, f56 = NULL, seed = NULL) {
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
  for (be in pcfg$prices_bioenergy) {
    column <- extract_bioenergy_column(pcfg, be)
    column <- gap_fill_years(column)
    column <- sort_years(column)
    column <- zero_history(column)
    if (any(is.na(as.vector(column)))) {
      log_die("bioenergy column ", magclass::getNames(column), " carries NA after gap filling ",
              "and historical zeroing; the price-sweep report of ", run_title(pcfg, 2L, be = be),
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

  # Does supply rise with price? Every price-sweep run sits at the same zero GHG
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
                           pcfg$prices_bioenergy[falls], totals[falls],
                           pcfg$prices_bioenergy[falls + 1L], totals[falls + 1L]),
                   collapse = "; "),
             ". Check the price-sweep runs at those levels before training on this.")
  } else {
    log_step("CHECK", "2100 supply is non-decreasing in the bioenergy price: ",
             paste(sprintf("%.2f", totals), collapse = " -> "), " EJ per yr")
  }

  staged_f56 <- file.path(stage_dir, "f56_pollutant_prices.cs3")
  if (!file.copy(f56, staged_f56)) log_die("cannot stage the f56 file from ", f56)
  log_step("CHECK", "f56 from ", f56, " carries the ", length(pcfg$prices_ghg),
           " GHG price column(s) of experiment '", pcfg$experiment,
           "' over every model year. What the trajectories in them say is taken as given, ",
           "including that they are uncapped")

  # A lever of the world may change the files the runs read rather than a value
  # in the config. Every such lever registered for this phase is asked what it
  # wants packed; one sitting at its default contributes nothing, which is why
  # this line changes no tarball until a data lever is registered.
  files <- c(staged_f60, staged_f56, lever_patch_files(pcfg, 3L, stage_dir))

  name <- pack_patch(files, pcfg, 3L)
  log_step("PACK", file.path(patch_repo_dir(pcfg), name), " (", length(files), " file(s))")
  name
}

# ---- CLI entry point --------------------------------------------------------

.synopsis_pack_demand <- paste(
  "usage: Rscript messageix/R/pack_demand.R --f56=PATH [--experiment=NAME]",
  "[--set=key=value] [--seed=PATH] [--help]")

.usage_pack_demand <- c(
  "Pack the inputs the demand sweep reads: the second-generation bioenergy demand the",
  "price sweep settled on, one column per bioenergy price level, appended to",
  "f60_bioenergy_dem.cs3; and the GHG price trajectories, which you supply, as",
  "f56_pollutant_prices.cs3. Both go into <patch_repo>/<experiment>_demand_<digest>.tgz.",
  "",
  "  Rscript messageix/R/pack_demand.R --f56=PATH [flags]   (from the MAgPIE model root)",
  "",
  "The pipeline packs this itself on the way from the price phase to the demand phase",
  "(Rscript messageix/run.R). Run this when the packed inputs have to be rebuilt alone.",
  "",
  "Flags:",
  "  --f56=PATH          the GHG price trajectories for this experiment, as a cs3 file with",
  "                      one column per GHG price level. Required. Its structure is checked",
  "                      against the experiment before anything is packed; the prices in it",
  "                      are not. Run this script without --f56 and it prints in full what",
  "                      the file has to contain and who to ask for it.",
  "  --experiment=NAME   an experiment of messageix/experiments.R (default: default)",
  "  --set=key=value     override one setting for this build; repeatable. Any lever of the",
  "                      world (bii_target, messageix/R/world_levers.R), the sampling plan,",
  "                      or an infrastructure setting (qos,",
  "                      messageix/R/pipeline_infrastructure.R)",
  "  --seed=PATH         the f60_bioenergy_dem.cs3 the new columns are appended to. The",
  "                      default is the copy any earlier run has already unpacked into",
  "                      modules/60_bioenergy/input/. It must be the base tarball's own",
  "                      file, not one an earlier packed tarball wrote.",
  "  --help              this text",
  "",
  "Every option is accepted as --key=value and as --key value.",
  "The tarball name is written as the last line of output, so a script can read it",
  "with `tail -n 1`. The name carries a digest of the contents: rebuilding the same",
  "inputs gives the same name, and changed inputs give a new one.")

if (invoked_directly("pack_demand.R")) {
  .opt <- parse_flags(commandArgs(trailingOnly = TRUE),
                      known      = c("experiment", "f56", "seed"),
                      flags      = "help",
                      repeatable = "set",
                      usage      = .synopsis_pack_demand)
  if (isTRUE(.opt$help)) {
    cat(.usage_pack_demand, sep = "\n")
    cat("\n")
  } else {
    .pcfg <- config_from_flags(.opt, cli_overrides(.opt$set))
    log_step("CONFIG", "experiment '", .pcfg$experiment, "'")
    .name <- pack_demand(.pcfg, f56 = .opt$f56, seed = .opt$seed)
    cat(.name, "\n", sep = "")
  }
}
