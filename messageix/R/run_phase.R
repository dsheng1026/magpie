# |  One phase of MAgPIE runs, submitted.
# |
# |  Three phases run MAgPIE, and this file runs any of them:
# |
# |    calibrate  one run, which solves for the land-use intensity trajectory
# |               (tau) the rest of the pipeline rests on. Technological change
# |               is solved for rather than imposed, which is what makes the
# |               trajectory meaningful, and the run is made against a
# |               business-as-usual second-generation bioenergy demand path.
# |    price      one run per bioenergy price level. Each pays the same price for
# |               first- and second-generation bioenergy and holds everything
# |               else still -- land-use intensity fixed at the calibrated
# |               trajectory, GHG price zero everywhere -- so what the sweep
# |               produces is one bioenergy demand trajectory per price level.
# |    demand     one run per bioenergy price and GHG price pair: the set the
# |               emulator is fitted to. Bioenergy enters as the demand the price
# |               sweep settled on rather than as a price, land-use intensity is
# |               solved for again, and the GHG price is what is swept.
# |
# |  The run set is not written down anywhere. It comes from the experiment:
# |  one calibration run, one price run per bioenergy price level, one demand run
# |  per pair, bioenergy price outer. expected_run_folders() in utils_paths.R
# |  builds that grid, and this file submits it in the order it returns.
# |
# |  This is an internal command. The front door is messageix/run.R, which runs
# |  the phases in order and waits between them; this file is what it calls, and
# |  what to reach for when one phase has to be re-run or watched on its own.
# |
# |  Usage, from the MAgPIE model root:
# |    Rscript messageix/R/run_phase.R --phase=calibrate
# |    Rscript messageix/R/run_phase.R --phase=price --experiment=biodiversity
# |    Rscript messageix/R/run_phase.R --phase=demand --list
# |
# |  Flags:
# |    --phase=NAME       calibrate, price or demand; required
# |    --experiment=NAME  an experiment of messageix/experiments.R (default: default)
# |    --set=key=value    override one setting; repeatable
# |    --patch=NAME       the packed inputs this phase reads (price and demand;
# |                       found by name when only one is on disk)
# |    --list             print the run set and stop
# |    --validate         resolve the settings, print the assembled cfg deltas, stop
# |    --dry-run          do everything except call start_run()
# |    --help             print usage and stop
# |  Every option is accepted as --key=value and as --key value. An unrecognised
# |  flag, a positional argument, or a repeated flag stops the run: a mistyped
# |  sweep is cheaper to catch here than 84 runs later.
# |
# |  Packed inputs travel as tarballs with content-hashed names (utils_paths.R).
# |  This file never invents one. It takes --patch=NAME, or finds the single
# |  "<experiment>_<price|demand>_<8 hex>.tgz" in the patch directory. Several
# |  candidates mean several builds are on disk and it cannot know which is
# |  current, so it stops and asks -- picking the newest would silently pair a
# |  run with the wrong inputs. messageix/run.R passes --patch=NAME for exactly
# |  this reason: a phase it runs reads the tarball it has just packed, whatever
# |  else is in the directory.
# |
# |  Interface
# |    run_stage(pcfg, stage, be, ghg, dry_run)  -> invisible(cfg); one MAgPIE run
# |    run_phase_main(argv)                      -> invisible; the whole CLI
# |    parse_phase_args(argv)                    -> list; parsed flags
# |    discover_patch(pcfg, stage)               -> chr; packed tarballs on disk
# |    resolve_patch(pcfg, stage, requested)     -> chr(1); the tarball to use
# |    assert_patch_installed(cfg)               -> invisible(TRUE); info.txt names this patch
# |    cfg_deltas(pcfg, stage, cfg)              -> data.frame; cfg vs. MAgPIE defaults
# |
# |  Dependencies: base R, tibble/dplyr, the messageix/R/ layer, and MAgPIE's
# |  scripts/start_functions.R.

# One line loads the whole messageix/R/ layer: each file there loads the files it
# needs itself, and utils_runs.R sits at the bottom of that chain.
if (!exists("run_modelstat", mode = "function")) source("messageix/R/utils_runs.R")
assert_magpie_root()
if (!exists("start_run", mode = "function"))     source("scripts/start_functions.R")

# ---- one run ----------------------------------------------------------------

# Start one MAgPIE run for the given stage and sweep position.
#
#   pcfg     resolved experiment, carrying the packed inputs for the two sweeps
#   stage    1, 2 or 3 (or "tau"/"price"/"demand")
#   be       bioenergy price level, USD2005/GJ; required for the two sweeps
#   ghg      GHG price level; required for the demand sweep
#   dry_run  assemble and narrate the cfg, then stop short of start_run()
#   first    TRUE for the first run of a phase, which is the one whose inputs are
#            checked against input/info.txt after start_run() returns
#
# codeCheck = FALSE turns off MAgPIE's check that its own GAMS source is
# internally consistent. That check reads model code, which is identical for
# every run of a sweep, so running it 84 times finds the same thing 84 times and
# costs minutes each. It is off because this pipeline changes data, never model
# code; if the model code itself has been edited, check it once by hand before
# submitting a sweep.
run_stage <- function(pcfg, stage, be = NULL, ghg = NULL, dry_run = FALSE, first = TRUE) {
  stage <- .as_stage(stage)
  cfg <- stage_cfg(pcfg, stage, be = be, ghg = ghg)
  log_step("RUN", cfg$title, " -> ", sub(":title:", cfg$title, cfg$results_folder, fixed = TRUE))
  if (dry_run) {
    log_step("SKIP", "start_run() not called for ", cfg$title, " (--dry-run)")
    return(invisible(cfg))
  }
  tryCatch(
    start_run(cfg, codeCheck = FALSE),
    error = function(e) {
      log_die("run '", cfg$title, "' did not start: ", conditionMessage(e))
    }
  )

  # Inputs are distributed once per phase, by the first run: every run of a
  # sweep carries the same cfg$input, so checking the first one is checking all
  # of them.
  if (first) assert_patch_installed(cfg)

  # The calibration run folder is addressed by name, so it records the settings
  # it was solved under. See messageix/R/utils_runs.R.
  if (stage == 1L) {
    folder <- run_folder(pcfg, 1L)
    if (dir.exists(folder)) {
      log_step("WRITE", write_stage1_fingerprint(pcfg, folder))
    } else {
      log_warn("start_run() left no ", folder, ", so no ", STAGE1_FINGERPRINT_FILE,
               " was written; the price phase will not be able to check that the trajectory ",
               "it reads was solved for experiment '", pcfg$experiment, "'")
    }
  }
  invisible(cfg)
}

# MAgPIE unpacks input data again only when the list of tarball names it has
# been asked for differs from the list recorded in input/info.txt. It compares
# names, never contents, so a packed tarball reusing a name a previous run
# already saw is skipped without a word -- the trap that content-hashed names
# exist to close. This check confirms the trap stayed closed: once the first run
# of a phase has started, the info file must name that phase's tarball.
assert_patch_installed <- function(cfg, info = "input/info.txt") {
  patch <- cfg$input[["patch"]]
  if (is.null(patch) || !nzchar(patch)) return(invisible(TRUE))
  if (!exists(".get_info", mode = "function")) {
    log_warn("scripts/start_functions.R defines no .get_info(), so ", info,
             " was not checked against the packed inputs ", patch)
    return(invisible(TRUE))
  }
  if (!file.exists(info)) {
    log_warn(info, " does not exist, so the packed inputs ", patch,
             " could not be confirmed as installed")
    return(invisible(TRUE))
  }
  used <- .get_info(info, "^Used data set:", ": ")
  if (!patch %in% used) {
    log_die(info, " does not name the packed inputs ", patch, "; it names ", used,
            ". MAgPIE compares tarball names rather than contents, so this run is reading a ",
            "previous run's inputs and a stale generated sets.gms. Set cfg$force_download or ",
            "remove ", info, ", then run this phase again.")
  }
  log_step("CHECK", info, " names the packed inputs ", patch)
  invisible(TRUE)
}

# ---- packed inputs ----------------------------------------------------------

# Packed input tarballs for this experiment and stage that are on disk.
discover_patch <- function(pcfg, stage) {
  dir <- patch_repo_dir(pcfg)
  if (!dir.exists(dir)) return(character(0))
  sort(list.files(dir, pattern = .patch_pattern(pcfg, stage)))
}

# The naming contract of patch_tarball_name() as a regular expression: the
# experiment's name, the stage token, and an 8-character content hash.
.patch_pattern <- function(pcfg, stage) {
  paste0("^", .regex_literal(pcfg$experiment), "_", stage_token(stage), "_[0-9a-f]{8}\\.tgz$")
}

# The packed inputs a phase will run against.
#
#   requested  the value of --patch, or NULL to discover it
#   must_exist FALSE lets --validate assemble and check a cfg before anything
#              has been packed; the tarball name is then a placeholder and
#              cfg$input carries it as such
resolve_patch <- function(pcfg, stage, requested = NULL, must_exist = TRUE) {
  dir <- patch_repo_dir(pcfg)
  build <- paste0("Rscript ", patch_generator_script(stage), " --experiment=", pcfg$experiment,
                  if (.as_stage(stage) == 3L) " --f56=PATH" else "")
  if (!is.null(requested)) {
    # A named tarball is checked against the same pattern discovery uses: the
    # name carries the experiment and the phase, so one phase's tarball handed to
    # another, or another experiment's tarball handed to this one, is a name
    # error before it is a data error.
    if (!grepl(.patch_pattern(pcfg, stage), requested)) {
      log_die("--patch=", requested, " does not match the naming contract for the ",
              phase_of_stage(stage), " phase of experiment '", pcfg$experiment, "': <experiment>_",
              stage_token(stage), "_<8 hex>.tgz. A tarball from another phase or another ",
              "experiment carries different inputs. Build this one with: ", build)
    }
    if (must_exist && !file.exists(file.path(dir, requested))) {
      log_die("--patch=", requested, " is not in ", dir, ". Build it with: ", build)
    }
    return(requested)
  }
  found <- discover_patch(pcfg, stage)
  if (length(found) == 1L) return(found)
  if (length(found) == 0L) {
    if (!must_exist) {
      log_warn("nothing packed for this phase in ", dir, " yet; every other setting is checked ",
               "and cfg$input carries a placeholder. Build the real thing with: ", build)
      return(paste0("<pending: ", patch_generator_script(stage), ">"))
    }
    log_die("the ", phase_of_stage(stage), " phase needs its packed inputs and none is in ", dir,
            ". Build them with: ", build)
  }
  log_die("the ", phase_of_stage(stage), " phase has ", length(found),
          " candidate tarballs in ", dir, " (", paste(found, collapse = ", "),
          "). The content hashes differ, so they hold different inputs; name the one to use ",
          "with --patch=NAME.")
}

# Escape a string for use inside a regular expression. Experiment names are free
# text and a "." in one would otherwise match any character.
.regex_literal <- function(x) gsub("([][{}()*+?.^$|\\\\])", "\\\\\\1", x)

# ---- command line -----------------------------------------------------------

# The one-line reminder that follows a command-line mistake. --help prints the
# full text below instead.
.synopsis_phase <- paste(
  "usage: Rscript messageix/R/run_phase.R --phase=calibrate|price|demand",
  "[--experiment=NAME] [--set=key=value] [--patch=NAME] [--list] [--validate]",
  "[--dry-run] [--help]")

# What --help prints. One text for all three phases, differing only in what the
# phase produces and in whether it reads packed inputs.
.usage_phase <- function(stage) {
  stage <- .as_stage(stage)
  produces <- c(
    "the reference run whose land-use intensity trajectory the rest of the pipeline rests on",
    "the bioenergy price sweep: one run per bioenergy price level of the experiment",
    "the emulator training set: one run per bioenergy price and GHG price pair")[stage]
  c(paste0("Submit ", produces, "."),
    "",
    paste0("  Rscript messageix/R/run_phase.R --phase=", phase_of_stage(stage),
           " [flags]   (from the MAgPIE model root)"),
    "",
    "Flags:",
    "  --phase=NAME       calibrate, price or demand; required",
    "  --experiment=NAME  an experiment of messageix/experiments.R (default: default)",
    "  --set=key=value    override one setting for this command; repeatable. Any lever of",
    "                     the world (messageix/R/world_levers.R), the sampling plan, or an",
    "                     infrastructure setting (messageix/R/pipeline_infrastructure.R)",
    if (stage > 1L) c(
      "  --patch=NAME       the packed inputs this phase reads: the tarball carrying what the",
      "                     phase before it produced. Needed only when more than one is on",
      "                     disk; otherwise it is found by its name. messageix/run.R always",
      "                     passes it, naming the tarball it has just packed."),
    "  --list             print the runs this phase would submit, and whether each run folder",
    "                     is already there, then stop",
    "  --validate         print every setting this phase changes against MAgPIE's own",
    "                     defaults, and what varies across the sweep, then stop",
    "  --dry-run          assemble and narrate every run's config; submit nothing",
    "  --help             this text",
    "",
    "Every option is accepted as --key=value and as --key value.",
    if (stage > 1L) c(
      "The runs come from the experiment, not from the command line: which prices are swept,",
      "and what the runs are called, are settings in messageix/experiments.R.",
      paste0("Pack this phase's inputs first with: Rscript ", patch_generator_script(stage),
             " --experiment=NAME")),
    if (stage == 1L)
      "This phase is one run, and every setting behind it comes from the experiment.",
    "",
    "The whole pipeline, phases in order and waiting between them: Rscript messageix/run.R")
}

# Parse the flags. Every one but --phase is optional and order does not matter;
# anything else stops the run with the one-line usage.
parse_phase_args <- function(argv) {
  opt <- parse_flags(argv,
                     known      = c("phase", "experiment", "patch"),
                     flags      = c("list", "validate", "dry-run", "help"),
                     repeatable = "set",
                     usage      = .synopsis_phase)
  # --help before --phase: the text differs only in what the phase produces, so a
  # command line that names one gets that phase's text and one that does not gets
  # the first phase's.
  if (isTRUE(opt$help)) {
    return(list(help = TRUE,
                stage = if (is.null(opt$phase)) 1L else stage_of_phase(opt$phase)))
  }
  if (is.null(opt$phase)) {
    log_die("--phase is required: calibrate, price or demand. ", .synopsis_phase)
  }
  stage <- stage_of_phase(opt$phase)
  if (stage == 1L && !is.null(opt$patch)) {
    log_die("--patch is not a flag of the calibrate phase: the reference run reads the base ",
            "input tarballs and nothing else. ", .synopsis_phase)
  }
  chosen <- c("--list", "--validate", "--dry-run")[c(isTRUE(opt$list), isTRUE(opt$validate),
                                                     isTRUE(opt[["dry-run"]]))]
  if (length(chosen) > 1L) {
    log_die(paste(chosen, collapse = " and "), " do different things; pick one. ", .synopsis_phase)
  }
  list(stage      = stage,
       experiment = if (is.null(opt$experiment)) "default" else opt$experiment,
       set        = opt$set,
       patch      = opt$patch,
       list       = isTRUE(opt$list),
       validate   = isTRUE(opt$validate),
       dry_run    = isTRUE(opt[["dry-run"]]),
       help       = FALSE)
}

# ---- reporting --------------------------------------------------------------

# Fixed-width table under the log_banner continuation prefix, so the output
# stays greppable as ">>" lines.
.print_table <- function(df, indent = "   ") {
  cols <- lapply(df, as.character)
  widths <- vapply(seq_along(cols), function(i) {
    max(nchar(c(names(df)[i], cols[[i]])))
  }, numeric(1))
  line <- function(cells) {
    cells <- mapply(formatC, cells, width = widths, MoreArgs = list(flag = "-"))
    cat(">>", indent, paste(cells, collapse = "  "), "\n", sep = "")
  }
  line(names(df))
  line(strrep("-", widths))
  for (i in seq_len(nrow(df))) line(vapply(cols, `[`, character(1), i))
  utils::flush.console()
  invisible(NULL)
}

# "field  source  old -> new", one delta per line, wrapping onto a second line
# when the pair is too long to read across. A table would be shaped by its
# widest cell, and cfg$input alone is 200 characters.
.print_deltas <- function(df, indent = "   ", wrap_at = 118L) {
  fw <- max(nchar(df$field))
  sw <- max(nchar(df$source))
  for (i in seq_len(nrow(df))) {
    head <- sprintf(">>%s%-*s  %-*s  ", indent, fw, df$field[i], sw, df$source[i])
    pair <- paste0(df$magpieDefault[i], " -> ", df$assembled[i])
    if (identical(df$magpieDefault[i], df$assembled[i])) {
      cat(head, df$assembled[i], "  (MAgPIE default)\n", sep = "")
      next
    }
    if (nchar(head) + nchar(pair) <= wrap_at) {
      cat(head, pair, "\n", sep = "")
    } else {
      cat(head, df$magpieDefault[i], "\n", sep = "")
      cat(">>", strrep(" ", nchar(head) - 2L), "-> ", df$assembled[i], "\n", sep = "")
    }
  }
  utils::flush.console()
  invisible(NULL)
}

# The run set: one line per run, with whether its folder is already on disk.
# Presence is not solvedness -- the reduce phase checks the model status.
print_run_set <- function(pcfg, stage, runs) {
  tab <- tibble::tibble(
    n      = seq_len(nrow(runs)),
    be     = dplyr::if_else(is.na(runs$be), "-", format(runs$be, trim = TRUE)),
    ghg    = dplyr::if_else(is.na(runs$ghg), "-", format(runs$ghg, trim = TRUE)),
    title  = runs$title,
    folder = runs$folder,
    onDisk = dplyr::if_else(dir.exists(runs$folder), "yes", "no")
  )
  log_step("CONFIG", nrow(runs), " run(s) in the ", phase_of_stage(stage),
           " phase of experiment '", pcfg$experiment, "'")
  .print_table(tab)
}

# MAgPIE's own starting point, before setScenario, the experiment, or stage logic.
.baseline_cfg <- function() {
  cfg <- NULL
  source("config/default.cfg", local = TRUE)
  if (is.null(cfg)) log_die("config/default.cfg did not define cfg")
  cfg
}

# One cfg field as a single comparable string. Character vectors are joined
# as they are: format() would pad them to a common width and turn
# c("output_check", "rds_report") into a value that differs from itself.
.as_text <- function(x) {
  if (is.null(x)) return("<unset>")
  if (!is.null(names(x)) && length(x) > 1L) {
    return(paste(paste0(names(x), "=", unname(x)), collapse = " "))
  }
  if (is.numeric(x)) return(paste(format(x, trim = TRUE, scientific = FALSE), collapse = ","))
  paste(as.character(x), collapse = ",")
}

# Everything one assembled cfg changes relative to config/default.cfg, with
# where the change came from:
#   ssp      the SSP column of MAgPIE's config/scenario_config.csv
#   setting  a narrative, design or infrastructure setting in scope for this phase
#   stage    stage logic in utils_config.R; nothing else may touch these
#   run      run control (names, folders, inputs, execution environment)
# This is how the golden runs are audited: one line per setting that is not a
# MAgPIE default. Every stage-controlled switch appears whether or not it moves,
# because "the stage set it and it happens to equal the MAgPIE default" and "the
# stage never set it" are different facts.
cfg_deltas <- function(pcfg, stage, cfg, base = .baseline_cfg()) {
  setting_keys <- stage_gms_keys(pcfg, stage)
  stage_keys <- stage_controlled_switches()
  rows <- list()

  for (key in union(names(base$gms), names(cfg$gms))) {
    old <- .as_text(base$gms[[key]])
    new <- .as_text(cfg$gms[[key]])
    origin <- if (key %in% stage_keys) "stage" else if (key %in% setting_keys) "setting" else "ssp"
    if (identical(old, new) && origin != "stage") next
    rows[[length(rows) + 1L]] <- tibble::tibble(field = paste0("gms$", key), source = origin,
                                                magpieDefault = old, assembled = new)
  }

  control <- list(title = cfg$title, results_folder = cfg$results_folder,
                  input = cfg$input, output = cfg$output, qos = cfg$qos,
                  force_replace = cfg$force_replace,
                  `info$flag` = cfg$info$flag, `info$flag2` = cfg$info$flag2,
                  repositories = names(cfg$repositories))
  baseline <- list(title = base$title, results_folder = base$results_folder,
                   input = base$input, output = base$output, qos = base$qos,
                   force_replace = base$force_replace,
                   `info$flag` = base$info$flag, `info$flag2` = base$info$flag2,
                   repositories = names(base$repositories))
  for (key in names(control)) {
    old <- .as_text(baseline[[key]])
    new <- .as_text(control[[key]])
    if (identical(old, new)) next
    rows[[length(rows) + 1L]] <- tibble::tibble(field = key, source = "run",
                                                magpieDefault = old, assembled = new)
  }

  dplyr::bind_rows(rows) |>
    dplyr::arrange(match(source, c("run", "stage", "setting", "ssp")), field)
}

# --validate output: the full delta table for the first run of the phase, then
# what varies across the rest of the sweep. Splitting it that way keeps an
# 84-run phase readable while still showing every value that moves.
print_cfg_deltas <- function(pcfg, stage, runs) {
  stage <- .as_stage(stage)
  cfgs <- lapply(seq_len(nrow(runs)), function(i) {
    stage_cfg(pcfg, stage, be = .sweep_arg(runs$be[i]), ghg = .sweep_arg(runs$ghg[i]))
  })
  base <- .baseline_cfg()

  log_step("CONFIG", phase_of_stage(stage), " run 1 of ", length(cfgs), ": ", runs$title[1L],
           " -- cfg deltas against config/default.cfg")
  .print_deltas(cfg_deltas(pcfg, stage, cfgs[[1L]], base))

  if (length(cfgs) == 1L) return(invisible(TRUE))

  # Over the union of every run's delta fields, not the first run's: a sweep
  # position whose value equals the MAgPIE default (bioenergy price 0) drops out
  # of that run's own delta table but still varies across the sweep.
  fields <- unique(unlist(lapply(cfgs, function(cfg) cfg_deltas(pcfg, stage, cfg, base)$field)))
  varying <- Filter(function(field) {
    values <- vapply(cfgs, function(cfg) .delta_value(pcfg, stage, cfg, field), character(1))
    length(unique(values)) > 1L
  }, fields)

  log_step("CONFIG", "settings that vary across the ", length(cfgs), " runs")
  tab <- tibble::tibble(n = seq_along(cfgs), title = runs$title)
  for (field in varying) {
    tab[[field]] <- vapply(cfgs, function(cfg) .delta_value(pcfg, stage, cfg, field), character(1))
  }
  .print_table(tab)
  invisible(TRUE)
}

# The assembled value of one field named as cfg_deltas() names it.
.delta_value <- function(pcfg, stage, cfg, field) {
  if (startsWith(field, "gms$")) return(.as_text(cfg$gms[[sub("^gms\\$", "", field)]]))
  switch(field,
    title          = .as_text(cfg$title),
    results_folder = .as_text(cfg$results_folder),
    input          = .as_text(cfg$input),
    output         = .as_text(cfg$output),
    qos            = .as_text(cfg$qos),
    force_replace  = .as_text(cfg$force_replace),
    `info$flag`    = .as_text(cfg$info$flag),
    `info$flag2`   = .as_text(cfg$info$flag2),
    repositories   = .as_text(names(cfg$repositories)),
    log_die("cfg delta field '", field, "' has no accessor")
  )
}

# A sweep coordinate from expected_run_folders(): NA means the phase does not
# use it, and stage_cfg() expects NULL for that.
.sweep_arg <- function(x) if (is.na(x)) NULL else x

# ---- entry point ------------------------------------------------------------

# What belongs at the head of a log file: the facts of the phase that produced it.
.phase_notes <- function(stage) {
  list(
    c("technological change" = "solved for, not imposed (endo_jan22): the land-use intensity trajectory is what this run is for",
      "what it produces"     = "ov_tau (level) in fulldata.gdx",
      "read by"              = "the price phase, through the inputs packed out of this run",
      "packed inputs"        = "none: the reference run uses the base input tarballs alone"),
    c("technological change" = "fixed (tc = exo) at the calibrated land-use intensity trajectory",
      "swept"                = "s60_bioenergy_1st_price and s60_bioenergy_2nd_price, USD2005 per GJ x currency_2005_to_2017",
      "GHG price"            = "a scenario that is zero everywhere, so the bioenergy price is the only signal",
      "packed inputs"        = "f13_tau_scenario.csv, the calibrated trajectory",
      "read by"              = "the demand phase, whose bioenergy demand columns come out of these runs"),
    c("technological change" = "solved for, not imposed (endo_jan22)",
      "bioenergy"            = "demand trajectory from the price sweep via c60_2ndgen_biodem; prices at their default of zero",
      "swept"                = "c56_pollutant_prices and c56_pollutant_prices_noselect, in lockstep",
      "non-CO2 price cap"    = "s56_limit_ch4_n2o_price from nonco2_price_cap_usd17_tc, USD17MER per tC",
      "packed inputs"        = "f60_bioenergy_dem.cs3 and f56_pollutant_prices.cs3",
      "read by"              = "the reduce phase - report.mif and fulldata.gdx of every run")
  )[[.as_stage(stage)]]
}

.phase_headline <- function(stage) {
  c("calibrate - the reference land-use intensity trajectory",
    "price - the bioenergy price sweep",
    "demand - the GHG price sweep (the emulator training set)")[.as_stage(stage)]
}

run_phase_main <- function(argv = commandArgs(trailingOnly = TRUE)) {
  opt <- parse_phase_args(argv)
  if (isTRUE(opt$help)) {
    cat(.usage_phase(opt$stage), sep = "\n")
    cat("\n")
    return(invisible(TRUE))
  }
  stage <- opt$stage

  pcfg <- resolve_config(experiment = opt$experiment, overrides = cli_overrides(opt$set))
  runs <- expected_run_folders(pcfg, stage)

  entries <- list(experiment = pcfg$experiment, identifier = pcfg$identifier)
  entries$runs <- nrow(runs)
  entries[["output to"]] <- results_folder(pcfg, stage)
  log_banner(.phase_headline(stage), c(entries, as.list(.phase_notes(stage))))

  # --list needs nothing packed: run names come from the experiment alone.
  if (opt$list) {
    print_run_set(pcfg, stage, runs)
    return(invisible(runs))
  }

  if (stage > 1L) {
    patch <- resolve_patch(pcfg, stage, requested = opt$patch, must_exist = !opt$validate)
    pcfg <- with_patch(pcfg, stage, patch)
    log_step("CONFIG", "packed inputs ", patch, " from ", patch_repo_dir(pcfg))
  }

  if (opt$validate) {
    print_cfg_deltas(pcfg, stage, runs)
    log_step("CHECK", "the settings resolve; nothing was run (--validate)")
    return(invisible(TRUE))
  }

  # Pre-run vetting: read-only checks that stop on FAIL before anything is submitted.
  if (!exists("vet_pre_run", mode = "function")) source("messageix/vetting/vet_pre_run.R")
  vet_pre_run(pcfg, stage)

  for (i in seq_len(nrow(runs))) {
    run_stage(pcfg, stage, be = .sweep_arg(runs$be[i]), ghg = .sweep_arg(runs$ghg[i]),
              dry_run = opt$dry_run, first = (i == 1L))
  }
  log_step(if (opt$dry_run) "SKIP" else "SUBMIT",
           nrow(runs), " run(s) of the ", phase_of_stage(stage), " phase",
           if (opt$dry_run) " assembled; start_run() not called (--dry-run)" else " handed to start_run()")
  invisible(TRUE)
}

# Only when this file is the command being run: messageix/run.R sources it for
# the run-set helpers and must not set a sweep going by doing so.
if (invoked_directly("run_phase.R")) run_phase_main()
