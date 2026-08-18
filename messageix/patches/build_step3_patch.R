# |  Build the patch tarball stage 3 consumes (pipeline step 2.5).
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
# |  Appending the columns is what makes them selectable: download_and_update()
# |  reads the scenario column names out of the distributed files and writes
# |  them into modules/60_bioenergy/*/sets.gms and
# |  modules/56_ghg_policy/price_aug22/sets.gms, so cfg$gms$c60_2ndgen_biodem =
# |  "SSP2_BD00_BE10" resolves without anyone editing a set file. Those set
# |  files are machine-generated; never hand-edit them.
# |
# |  THE f56 GENERATOR DOES NOT EXIST. Nothing in dsheng1026/magpie or
# |  dsheng1026/MAgPIE_emulator constructs the G####exp2110 trajectories, and
# |  their semantics -- what price level the label denotes, in which year and
# |  currency, and what growth rate "exp2110" applies out to 2110 -- are not
# |  recoverable from the surrounding code. This generator therefore takes the
# |  file from the caller (--f56=PATH), validates it against the preset, and
# |  stops with a message naming what is missing when it is absent. It does not
# |  guess: a wrong trajectory would change every one of the 84 stage-3 runs
# |  while looking entirely plausible.
# |
# |  The non-CO2 price cap is not expected inside f56. Supply uncapped
# |  trajectories: cfg$gms$s56_limit_ch4_n2o_price applies the cap inside GAMS
# |  to whichever scenario c56_pollutant_prices selects, so changing
# |  pipeline$nonco2_price_cap_usd17_tc needs no file inside any tarball edited.
# |
# |  Usage
# |    Rscript messageix/patches/build_step3_patch.R --f56=PATH [flags]   (from the model root)
# |
# |    --f56=PATH           f56_pollutant_prices.cs3 carrying the preset's GHG
# |                         price columns; required
# |    --preset=NAME        narrative column of the preset CSV (default "default")
# |    --csv=PATH           preset CSV (default: default_preset_csv())
# |    --set=key=value      override one preset row; repeatable
# |    --seed=PATH          f60_bioenergy_dem.cs3 to append to (default
# |                         modules/60_bioenergy/input/f60_bioenergy_dem.cs3,
# |                         which any prior run's download_and_update() places)
# |    --help
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
# |  Dependencies: magclass, magpie4, messageix/R/utils_config.R,
# |  messageix/R/utils_runs.R (the solvedness contract, shared with the matrix
# |  builders) and messageix/patches/build_step2_patch.R for the shared CLI
# |  parser and pack_patch() -- the two generators write into the same patch
# |  directory under the same naming and archive-layout contract, and that
# |  contract is defined once, there. Run from the MAgPIE model root.

if (!exists("resolve_config", mode = "function")) source("messageix/R/utils_config.R")
if (!exists("run_modelstat", mode = "function"))  source("messageix/R/utils_runs.R")
if (!exists("pack_patch", mode = "function"))     source("messageix/patches/build_step2_patch.R")

# ---- documented defaults ----------------------------------------------------

# The 5-year grid the bioenergy columns are written on. MAgPIE's t_all runs to
# 2150 while a run reports only its own time steps, so the grid is wider than
# any single run's output and the gaps are filled below.
GAP_FILL_YEARS <- seq(1995, 2150, by = 5)

# Years at or beyond this one copy the value of this year instead of
# interpolating: past 2100 there is no later reported year to average against,
# and holding the level flat is the pipeline's documented convention.
GAP_FILL_HOLD_FROM <- 2100

# Second-generation bioenergy is set to zero over the historical period: the
# technology is not deployed at scale in these years and MAgPIE harmonises the
# early years against a reference scenario regardless
# (modules/60_bioenergy/1st2ndgen_priced_feb24/preloop.gms). A vector of
# non-zero values can replace HIST_VALUES without any structural change; it is
# recycled across regions and years the way any magpie assignment is.
HIST_YEARS  <- c("y1995", "y2000", "y2005", "y2010", "y2015")
HIST_VALUES <- 0

# Second-generation bioenergy variable of magpie4::reportProductionBioenergy.
# Matched by prefix (pmatch): the report appends units to the variable name.
BIOENERGY_VARIABLE <- "2nd generation|++"

# EJ per yr -> PJ per yr. reportProductionBioenergy reports EJ; f60_bioenergy_dem
# is declared in mio. GJ per yr (modules/60_bioenergy/1st2ndgen_priced_feb24/
# input.gms), and one mio. GJ is one PJ.
EJ_TO_PJ <- 1000

# ---- year handling ----------------------------------------------------------

# Fill the years a run did not report. Below hold_from a missing year takes the
# mean of its two neighbours on the 5-year grid, which requires the later
# neighbour to be present -- two consecutive gaps are a broken report, not a
# case to interpolate through, so they stop here rather than propagating NA.
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

# Restrict to the grid and put the years in ascending order: add_columns
# appends, so a filled object carries its new years at the end and the cs3
# would be written out of order.
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

# Two f60 scenario columns GAMS dereferences by name whatever the run selects,
# so a seed missing either fails on an unknown set element:
#   c60_2ndgen_biodem_noselect  the demand path used in regions outside the
#                               selected policy set, read from its $setglobal
#                               default in the module input.gms
#   R32M46-SSP2EU-NPi           hardcoded in preloop.gms, which harmonises
#                               every run's early years against it
# This is why the seed is the base tarball's own file rather than a fresh
# object holding only the new columns.
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

# The seed must be the base f60_bioenergy_dem.cs3 as distributed, carrying the
# columns above and none of the columns this generator is about to append --
# appending to an already-patched file duplicates set members.
assert_seed <- function(seed, pcfg) {
  if (!file.exists(seed)) {
    log_die("f60 seed not found: ", seed, ". It is the base tarball's own ",
            "f60_bioenergy_dem.cs3, placed in modules/60_bioenergy/input/ by ",
            "download_and_update() during any prior run. Run a stage first, or pass --seed=PATH")
  }
  columns <- magclass::getNames(magclass::read.magpie(seed))
  required <- seed_required_columns()
  absent <- setdiff(required, columns)
  if (length(absent)) {
    log_die("f60 seed ", seed, " is missing the scenario column(s) ", absent,
            ", which GAMS dereferences unconditionally; it is not the base tarball's file")
  }
  new_columns <- vapply(pcfg$be_prices, function(be) scen_column(pcfg, be), character(1))
  clash <- intersect(new_columns, columns)
  if (length(clash)) {
    log_die("f60 seed ", seed, " already carries ", clash,
            "; seed from the unpatched base file, not from a previously generated patch")
  }
  invisible(TRUE)
}

# ---- stage-2 extraction -----------------------------------------------------

# Every stage-2 run must be present and solved before anything is extracted:
# a patch built from six of seven runs produces 84 stage-3 runs silently
# trained on a gap. Problems are collected and reported together so one pass
# tells the researcher which runs to resubmit.
assert_stage2_complete <- function(pcfg) {
  runs <- expected_run_folders(pcfg, 2L)
  problems <- character(0)
  for (i in seq_len(nrow(runs))) {
    gdx <- file.path(runs$folder[i], "fulldata.gdx")
    if (!dir.exists(runs$folder[i])) {
      problems <- c(problems, paste0(runs$title[i], ": no run folder ", runs$folder[i]))
    } else if (!file.exists(gdx)) {
      problems <- c(problems, paste0(runs$title[i], ": no fulldata.gdx in ", runs$folder[i]))
    } else {
      status <- try(assert_run_solved(gdx, runs$title[i]), silent = TRUE)
      if (inherits(status, "try-error")) {
        problems <- c(problems, sub("^[^:]*: *", "", conditionMessage(attr(status, "condition"))))
      }
    }
  }
  if (length(problems)) {
    log_die("stage 2 is incomplete -- ", length(problems), " of ", nrow(runs),
            " run(s) unusable:\n  ", paste(problems, collapse = "\n  "))
  }
  invisible(TRUE)
}

# Second-generation bioenergy production of one stage-2 run, as the scenario
# column stage 3 will select with c60_2ndgen_biodem. The column name is
# unpadded (scen_column), while the run folder token is zero-padded -- both
# encodings are live and utils_paths.R derives each from the same integer.
extract_bioenergy_column <- function(pcfg, be) {
  folder <- locate_run_folder(pcfg, 2L, be = be)
  if (is.na(folder)) log_die("stage-2 run folder not found: ", run_folder(pcfg, 2L, be = be))
  gdx <- file.path(folder, "fulldata.gdx")
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

# Global total of a scenario column in a given year, in EJ per yr -- the
# structural check on the extracted trajectory.
global_bioenergy_ej <- function(x, year = "y2100") {
  if (!year %in% magclass::getYears(x)) {
    log_die("global_bioenergy_ej: no ", year, " in the data")
  }
  totals <- as.vector(magclass::dimSums(x[, year, ], dim = 1)) / EJ_TO_PJ
  stats::setNames(totals, magclass::getNames(x))
}

# ---- f56 --------------------------------------------------------------------

# The GAMS set of taxable pollutants, read from its declaration rather than
# copied here: a second copy would drift at the next MAgPIE version bump.
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

# What the caller has to obtain, and from whom. Deliberately long: this is the
# one place in the pipeline where a required artefact cannot be rebuilt from
# the repositories, and a terse "file missing" would send the reader looking
# for a generator that is not there.
f56_missing_message <- function(pcfg) {
  wanted <- vapply(pcfg$ghg_prices, function(g) ghg_scenario(pcfg, g), character(1))
  paste0(
    "no f56_pollutant_prices.cs3 supplied (--f56=PATH), and this repository cannot generate one.\n",
    "  Needed: a cs3 file over (t_all, i, pollutants, ghgscen56) in USD17MER per t, carrying\n",
    "  one column per GHG price level of preset '", pcfg$preset, "':\n    ",
    paste(wanted, collapse = ", "), "\n",
    "  Missing: the trajectory generator. Nothing in dsheng1026/magpie or\n",
    "  dsheng1026/MAgPIE_emulator builds these columns, and the label semantics -- what\n",
    "  price level ", wanted[length(wanted)], " denotes, in which year and currency, and what\n",
    "  growth rate the '", pcfg$ghg_price_scenario_suffix, "' extension applies -- are not\n",
    "  recoverable from the surrounding code. Reverse-engineering them from the labels would\n",
    "  change every stage-3 run while looking plausible, so this generator refuses to guess.\n",
    "  Next step: ask Di Sheng for the generator script, or for the SSP2_demand_cap.tgz\n",
    "  tarball, and extract f56_pollutant_prices.cs3 from it (tar xzf … f56_pollutant_prices.cs3).\n",
    "  Then rerun with --f56=<that file>.\n",
    "  Note: the non-CO2 price cap is NOT expected inside the file. Supply the uncapped\n",
    "  trajectories -- the cap is applied inside GAMS by cfg$gms$s56_limit_ch4_n2o_price,\n",
    "  set from pipeline$nonco2_price_cap_usd17_tc (", pcfg$nonco2_price_cap_usd17_tc,
    " USD17MER per tC for this preset).")
}

# Check a caller-supplied f56 against the preset before it is packed: a column
# the stage-3 driver requests but the file lacks fails 84 times in GAMS, one
# run at a time, hours after submission.
#
# The order of the two sub-dimensions is fixed, not a matter of taste:
# f56_pollutant_prices(t_all, i, pollutants, ghgscen56) is declared that way in
# modules/56_ghg_policy/price_aug22/input.gms, and scripts/start_functions.R:78
# reads the ghgscen56 set out of the distributed file with getNames(..., dim = 2).
# A transposed file therefore writes pollutant names into ghgscen56 and every
# c56_pollutant_prices column the stage requests fails to resolve. Hence an
# assertion on dim 1 rather than a guess at which component is which.
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
      log_die("--f56: ", path, " is transposed. Its first sub-dimension holds ", found_pollutants,
              " and its second holds ", found_scenarios,
              ", but scripts/start_functions.R reads the ghgscen56 set from dim = 2 and the table ",
              "is declared f56_pollutant_prices(t_all, i, pollutants, ghgscen56). Write the ",
              "pollutant first: as it stands the pollutant names would become the scenario set ",
              "and no run could resolve its c56_pollutant_prices column.")
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
  # The f56 check comes first: it is the one input this repository cannot
  # produce, and on a fresh tree a seed error would otherwise hide it.
  if (is.null(f56)) log_die(f56_missing_message(pcfg))
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

  # The written file, re-read, must agree with what was extracted. Cheap, and
  # it is the step where a cs3 append silently misaligns years or regions.
  written <- magclass::read.magpie(staged_f60)
  written <- written[, , magclass::getNames(columns)]
  delta <- max(abs(global_bioenergy_ej(written) - global_bioenergy_ej(columns)))
  if (delta > 1e-6) {
    log_die("f60 round-trip mismatch of ", signif(delta, 4),
            " EJ per yr between the extracted columns and ", staged_f60)
  }
  log_step("CHECK", "f60 carries ", magclass::ndata(written), " new scenario column(s) over ",
           length(magclass::getYears(written)), " years; round-trip agrees")

  # Monotonicity spot check. Every stage-2 run sits at the same zero GHG price,
  # so the only thing separating these columns is the bioenergy price, and
  # supply should not fall as that price rises. A warning rather than a stop:
  # a small inversion can be a solver artefact at a near-flat part of the
  # response surface, while a large one means the sweep is not measuring what
  # the stage claims. The numbers are printed so the reader can tell which.
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

.usage_step3 <- c(
  "Build the patch tarball stage 3 consumes: the stage-2 bioenergy demand columns",
  "appended to f60_bioenergy_dem.cs3, plus a caller-supplied f56_pollutant_prices.cs3,",
  "packed into <patch_repo>/<preset>_demand_<hash>.tgz.",
  "",
  "  Rscript messageix/patches/build_step3_patch.R --f56=PATH [flags]   (from the MAgPIE model root)",
  "",
  "  --f56=PATH        f56_pollutant_prices.cs3 carrying the preset's GHG price columns.",
  "                    Required: this repository holds no generator for those trajectories.",
  "  --preset=NAME     narrative column of the preset CSV (default: default)",
  paste0("  --csv=PATH        preset CSV (default: ", default_preset_csv(), ")"),
  "  --set=key=value   override one preset row; repeatable",
  "  --seed=PATH       f60_bioenergy_dem.cs3 to append to",
  "                    (default: modules/60_bioenergy/input/f60_bioenergy_dem.cs3)",
  "  --help            this text",
  "",
  "The tarball name is the last line of stdout.")

if (invoked_directly("build_step3_patch.R")) {
  .argv <- cli_args(commandArgs(trailingOnly = TRUE))
  if (!is.null(.argv$flags$help)) {
    cat(.usage_step3, sep = "\n")
  } else {
    assert_known_flags(.argv$flags, c("preset", "csv", "f56", "seed"), .usage_step3)
    .preset <- if (is.null(.argv$flags$preset)) "default" else .argv$flags$preset
    .csv <- if (is.null(.argv$flags$csv)) default_preset_csv() else .argv$flags$csv
    log_step("CONFIG", "preset '", .preset, "' from ", .csv)
    .pcfg <- resolve_config(.preset, .csv, cli_overrides(.argv$sets))
    .name <- build_step3_patch(.pcfg, f56 = .argv$flags$f56, seed = .argv$flags$seed)
    cat(.name, "\n", sep = "")
  }
}
