# |  Shared runner for the three pipeline stage drivers.
# |
# |  The drivers in this folder say WHAT an experiment is; this file says HOW it
# |  is orchestrated. A driver declares its stage and a few banner lines and
# |  delegates to run_driver_main(); everything below -- argument parsing, preset
# |  resolution, patch-tarball lookup, the run banner, the loop over the run set,
# |  and the call into MAgPIE's start_run() -- happens here exactly once, so the
# |  three stages cannot drift apart.
# |
# |  A run set is not written down anywhere. It is derived from the preset:
# |    stage 1  one reference run
# |    stage 2  one run per be_prices level
# |    stage 3  one run per (be_prices x ghg_prices) pair, bioenergy price outer
# |  expected_run_folders() in utils_paths.R builds that grid, and the drivers
# |  submit it in the order it returns.
# |
# |  Every script here runs from the MAgPIE model root, MAgPIE's own convention:
# |
# |      Rscript messageix/start/driver_step1_tau.R    [flags]
# |      Rscript messageix/start/driver_step2_price.R  [flags]
# |      Rscript messageix/start/driver_step3_demand.R [flags]
# |
# |  Flags, shared by all three drivers:
# |    --preset=NAME   narrative column of the narratives file      (default: default)
# |    --csv=PATH      narratives file                              (default: messageix/presets/narratives.csv)
# |    --patch=NAME    patch tarball in the patch repository   (stages 2 and 3; default: discovered)
# |    --list          print the run set and stop
# |    --validate      resolve the config, print the assembled cfg deltas, stop
# |    --dry-run       do everything except call start_run()
# |    --help          print usage and stop
# |  Every option is accepted as --key=value and as --key value. An unrecognised
# |  flag, a positional argument, or a repeated flag stops the run: a mistyped
# |  sweep is cheaper to catch here than 84 runs later.
# |
# |  Patch tarballs are generated artefacts with content-hashed names
# |  (utils_paths.R). A driver never invents one. It takes --patch=NAME, or finds
# |  the single "<preset>_<stage>_<8 hex>.tgz" in the patch repository. Several
# |  candidates mean several generator outputs are on disk and the driver cannot
# |  know which is current, so it stops and asks -- picking the newest would
# |  silently pair a run with the wrong inputs. The pipeline driver passes
# |  --patch=NAME for exactly this reason: a stage it runs reads the tarball the
# |  generator before it just built, whatever else is in the directory.
# |
# |  Interface
# |    run_stage(pcfg, stage, be, ghg, dry_run)   -> invisible(cfg); one MAgPIE run
# |    run_driver_main(stage, headline, notes, argv) -> invisible; the whole CLI
# |    parse_stage_args(argv, stage)              -> list; parsed flags
# |    discover_patch(pcfg, stage)                -> chr; patch tarballs on disk
# |    resolve_patch(pcfg, stage, requested)      -> chr(1); the tarball to use
# |    patch_generator(stage)                     -> chr(1); script that builds it
# |    assert_patch_installed(cfg)                -> invisible(TRUE); info.txt names this patch
# |    cfg_deltas(pcfg, stage, cfg)               -> data.frame; cfg vs. MAgPIE defaults
# |
# |  Dependencies: base R, the messageix/R/ layer, and MAgPIE's
# |  scripts/start_functions.R. No CRAN packages beyond what MAgPIE itself needs.

# One line loads the whole messageix/R/ layer: each file there loads the files it
# needs itself, and utils_runs.R sits at the bottom of that chain.
if (!exists("run_modelstat", mode = "function")) source("messageix/R/utils_runs.R")
assert_magpie_root()
if (!exists("start_run", mode = "function"))     source("scripts/start_functions.R")

# ---- one run ----------------------------------------------------------------

# Start one MAgPIE run for the given stage and sweep position.
#
#   pcfg     resolved preset, carrying the patch tarball for stages 2 and 3
#   stage    1, 2 or 3 (or "tau"/"price"/"demand")
#   be       bioenergy price level, USD2005/GJ; required for stages 2 and 3
#   ghg      GHG price level; required for stage 3
#   dry_run  assemble and narrate the cfg, then stop short of start_run()
#   first    TRUE for the first run of a stage, which is the one whose inputs are
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

  # Inputs are distributed once per stage, by the first run: every run of a
  # sweep carries the same cfg$input, so checking the first one is checking all
  # of them.
  if (first) assert_patch_installed(cfg)

  # The stage-1 run folder is shared across narratives, so it records which
  # narrative solved it. See messageix/R/utils_runs.R.
  if (stage == 1L) {
    folder <- run_folder(pcfg, 1L)
    if (dir.exists(folder)) {
      log_step("WRITE", write_stage1_fingerprint(pcfg, folder))
    } else {
      log_warn("start_run() left no ", folder, ", so no ", STAGE1_FINGERPRINT_FILE,
               " was written; patch_step2 will not be able to check that the tau trajectory ",
               "it reads was solved under preset '", pcfg$preset, "'")
    }
  }
  invisible(cfg)
}

# MAgPIE unpacks input data again only when the list of tarball names it has
# been asked for differs from the list recorded in input/info.txt. It compares
# names, never contents, so a patch tarball reusing a name a previous run
# already saw is skipped without a word -- the trap that content-hashed names
# exist to close. This check confirms the trap stayed closed: once the first run
# of a stage has started, the info file must name this stage's patch tarball.
assert_patch_installed <- function(cfg, info = "input/info.txt") {
  patch <- cfg$input[["patch"]]
  if (is.null(patch) || !nzchar(patch)) return(invisible(TRUE))
  if (!exists(".get_info", mode = "function")) {
    log_warn("scripts/start_functions.R defines no .get_info(), so ", info,
             " was not checked against the patch tarball ", patch)
    return(invisible(TRUE))
  }
  if (!file.exists(info)) {
    log_warn(info, " does not exist, so the patch tarball ", patch,
             " could not be confirmed as installed")
    return(invisible(TRUE))
  }
  used <- .get_info(info, "^Used data set:", ": ")
  if (!patch %in% used) {
    log_die(info, " does not name the patch tarball ", patch, "; it names ", used,
            ". MAgPIE compares tarball names rather than contents, so this run is reading a ",
            "previous run's inputs and a stale generated sets.gms. Set cfg$force_download or ",
            "remove ", info, ", then re-run the stage.")
  }
  log_step("CHECK", info, " names the patch tarball ", patch)
  invisible(TRUE)
}

# ---- patch tarballs ---------------------------------------------------------

# The script that builds the patch tarball a stage reads. Stage 2 reads what
# patch_step2 takes out of the stage-1 run; stage 3 reads what patch_step3 takes
# out of the stage-2 runs.
patch_generator <- function(stage) {
  paste0("messageix/patches/build_step", .as_stage(stage), "_patch.R")
}

# Generated patch tarballs for this narrative and stage that are on disk.
discover_patch <- function(pcfg, stage) {
  dir <- patch_repo_dir(pcfg)
  if (!dir.exists(dir)) return(character(0))
  sort(list.files(dir, pattern = .patch_pattern(pcfg, stage)))
}

# The naming contract of patch_tarball_name() as a regular expression: the
# narrative's name, the stage token, and an 8-character content hash.
.patch_pattern <- function(pcfg, stage) {
  paste0("^", .regex_literal(pcfg$preset), "_", stage_token(stage), "_[0-9a-f]{8}\\.tgz$")
}

# The patch tarball a stage will run against.
#
#   requested  the value of --patch, or NULL to discover it
#   must_exist FALSE lets --validate assemble and check a cfg before the
#              generator has ever run; the tarball name is then a placeholder
#              and cfg$input carries it as such
resolve_patch <- function(pcfg, stage, requested = NULL, must_exist = TRUE) {
  dir <- patch_repo_dir(pcfg)
  if (!is.null(requested)) {
    # A named tarball is checked against the same pattern discovery uses: the
    # name carries the narrative and the stage, so a stage-2 tarball handed to
    # stage 3, or another narrative's tarball handed to this one, is a name error
    # before it is a data error.
    if (!grepl(.patch_pattern(pcfg, stage), requested)) {
      log_die("--patch=", requested, " does not match the naming contract for stage ",
              .as_stage(stage), " of narrative '", pcfg$preset, "': <narrative>_",
              stage_token(stage), "_<8 hex>.tgz. A tarball from another stage or another ",
              "narrative carries different inputs. Generate this one with: Rscript ",
              patch_generator(stage), " --preset=", pcfg$preset)
    }
    if (must_exist && !file.exists(file.path(dir, requested))) {
      log_die("--patch=", requested, " is not in ", dir,
              ". Generate it with: Rscript ", patch_generator(stage))
    }
    return(requested)
  }
  found <- discover_patch(pcfg, stage)
  if (length(found) == 1L) return(found)
  if (length(found) == 0L) {
    if (!must_exist) {
      log_warn("no generated patch tarball in ", dir, " yet; every other setting is checked ",
               "and cfg$input carries a placeholder. Build the real one with: Rscript ",
               patch_generator(stage), " --preset=", pcfg$preset)
      return(paste0("<pending: ", patch_generator(stage), ">"))
    }
    log_die("stage ", .as_stage(stage), " needs its patch tarball and none is in ", dir,
            ". Generate it with: Rscript ", patch_generator(stage),
            " --preset=", pcfg$preset)
  }
  log_die("stage ", .as_stage(stage), " has ", length(found), " candidate patch tarballs in ", dir,
          " (", paste(found, collapse = ", "),
          "). The content hashes differ, so they hold different inputs; name the one to use with --patch=NAME.")
}

# Escape a string for use inside a regular expression. Preset names are free
# text and a "." in one would otherwise match any character.
.regex_literal <- function(x) gsub("([][{}()*+?.^$|\\\\])", "\\\\\\1", x)

# ---- command line -----------------------------------------------------------

.DRIVER_SCRIPT <- c("driver_step1_tau.R", "driver_step2_price.R", "driver_step3_demand.R")

# The one-line reminder that follows a command-line mistake. --help prints the
# full text below instead.
.synopsis <- function(stage) {
  stage <- .as_stage(stage)
  paste0("usage: Rscript messageix/start/", .DRIVER_SCRIPT[stage],
         " [--preset=NAME] [--csv=PATH] ", if (stage > 1L) "[--patch=NAME] " else "",
         "[--list] [--validate] [--dry-run] [--help]")
}

# What --help prints. One text for all three stages, differing only in what the
# stage produces and in whether it reads a patch tarball.
.usage <- function(stage) {
  stage <- .as_stage(stage)
  produces <- c(
    "the reference run whose land-use intensity trajectory the rest of the pipeline rests on",
    "the bioenergy price sweep: one run per bioenergy price level in the preset",
    "the emulator training set: one run per bioenergy price and GHG price pair")[stage]
  c(paste0("Submit ", produces, "."),
    "",
    paste0("  Rscript messageix/start/", .DRIVER_SCRIPT[stage],
           " [flags]   (from the MAgPIE model root)"),
    "",
    "Flags:",
    "  --preset=NAME   narrative column of the narratives file (default: default)",
    paste0("  --csv=PATH      narratives file (default: ", default_preset_csv(), ")"),
    if (stage > 1L) c(
      "  --patch=NAME    the patch tarball this stage reads: the file carrying the inputs",
      "                  the step before it generated. Needed only when more than one is",
      "                  on disk; otherwise it is found by its name. The pipeline driver",
      "                  always passes it, naming the tarball it has just built."),
    "  --list          print the runs this stage would submit, and whether each run",
    "                  folder is already there, then stop",
    "  --validate      print every setting this stage changes against MAgPIE's own",
    "                  defaults, and what varies across the sweep, then stop",
    "  --dry-run       assemble and narrate every run's config; submit nothing",
    "  --help          this text",
    "",
    "Every option is accepted as --key=value and as --key value.",
    if (stage > 1L) c(
      "The runs come from the preset, not from the command line: which prices are swept,",
      "and what the runs are called, are settings in the narratives file.",
      paste0("Build the patch tarball first with: Rscript ", patch_generator(stage),
             " --preset=NAME")),
    if (stage == 1L)
      "This stage is one run, and every setting behind it comes from the narratives file.")
}

# Parse the driver flags. Every flag is optional and order does not matter;
# anything else stops the run with the one-line usage.
parse_stage_args <- function(argv, stage) {
  stage <- .as_stage(stage)
  opt <- parse_flags(argv,
                     known   = c("preset", "csv", "patch"),
                     flags   = c("list", "validate", "dry-run", "help"),
                     aliases = c("preset-csv" = "csv"),
                     usage   = .synopsis(stage))
  if (stage == 1L && !is.null(opt$patch)) {
    log_die("--patch is not a stage 1 flag: the reference run reads the base input tarballs ",
            "and nothing else. ", .synopsis(stage))
  }
  chosen <- c("--list", "--validate", "--dry-run")[c(isTRUE(opt$list), isTRUE(opt$validate),
                                                     isTRUE(opt[["dry-run"]]))]
  if (length(chosen) > 1L) {
    log_die(paste(chosen, collapse = " and "), " do different things; pick one. ", .synopsis(stage))
  }
  list(preset   = if (is.null(opt$preset)) "default" else opt$preset,
       csv      = if (is.null(opt$csv)) default_preset_csv() else opt$csv,
       patch    = opt$patch,
       list     = isTRUE(opt$list),
       validate = isTRUE(opt$validate),
       dry_run  = isTRUE(opt[["dry-run"]]),
       help     = isTRUE(opt$help))
}

# ---- reporting --------------------------------------------------------------

# Fixed-width table under the log_banner continuation prefix, so a driver's
# whole output stays greppable as ">>" lines.
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
# Presence is not solvedness -- the matrix build checks modelstat separately.
print_run_set <- function(pcfg, stage, runs) {
  tab <- data.frame(
    n      = seq_len(nrow(runs)),
    be     = ifelse(is.na(runs$be), "-", format(runs$be, trim = TRUE)),
    ghg    = ifelse(is.na(runs$ghg), "-", format(runs$ghg, trim = TRUE)),
    title  = runs$title,
    folder = runs$folder,
    onDisk = ifelse(dir.exists(runs$folder), "yes", "no"),
    stringsAsFactors = FALSE
  )
  log_step("CONFIG", nrow(runs), " run(s) in stage ", .as_stage(stage),
           " of narrative '", pcfg$preset, "'")
  .print_table(tab)
}

# MAgPIE's own starting point, before setScenario, the narrative, or stage logic.
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
#   setting  a narrative or infrastructure setting, in scope for this stage
#   stage    stage logic in utils_config.R; nothing else may touch these
#   run      run control (names, folders, inputs, execution environment)
# This is how the golden runs are audited: one line per setting that is not a
# MAgPIE default. Every stage-controlled switch appears whether or
# not it moves, because "the stage set it and it happens to equal the MAgPIE
# default" and "the stage never set it" are different facts.
cfg_deltas <- function(pcfg, stage, cfg, base = .baseline_cfg()) {
  setting_keys <- stage_gms_keys(pcfg, stage)
  stage_keys <- stage_controlled_switches()
  rows <- list()

  for (key in union(names(base$gms), names(cfg$gms))) {
    old <- .as_text(base$gms[[key]])
    new <- .as_text(cfg$gms[[key]])
    origin <- if (key %in% stage_keys) "stage" else if (key %in% setting_keys) "setting" else "ssp"
    if (identical(old, new) && origin != "stage") next
    rows[[length(rows) + 1L]] <- data.frame(field = paste0("gms$", key), source = origin,
                                            magpieDefault = old, assembled = new,
                                            stringsAsFactors = FALSE)
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
    rows[[length(rows) + 1L]] <- data.frame(field = key, source = "run",
                                            magpieDefault = old, assembled = new,
                                            stringsAsFactors = FALSE)
  }

  out <- do.call(rbind, rows)
  out[order(match(out$source, c("run", "stage", "preset", "ssp")), out$field), ]
}

# --validate output: the full delta table for the first run of the stage, then
# what varies across the rest of the sweep. Splitting it that way keeps an
# 84-run stage readable while still showing every value that moves.
print_cfg_deltas <- function(pcfg, stage, runs) {
  stage <- .as_stage(stage)
  cfgs <- lapply(seq_len(nrow(runs)), function(i) {
    stage_cfg(pcfg, stage, be = .sweep_arg(runs$be[i]), ghg = .sweep_arg(runs$ghg[i]))
  })
  base <- .baseline_cfg()

  log_step("CONFIG", "stage ", stage, " run 1 of ", length(cfgs), ": ", runs$title[1L],
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
  tab <- data.frame(n = seq_along(cfgs), title = runs$title, stringsAsFactors = FALSE)
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

# A sweep coordinate from expected_run_folders(): NA means the stage does not
# use it, and stage_cfg() expects NULL for that.
.sweep_arg <- function(x) if (is.na(x)) NULL else x

# ---- the driver entry point -------------------------------------------------

# The whole command line of one stage driver.
#
#   stage     1, 2 or 3
#   headline  banner title, naming the stage and what it produces
#   notes     named character vector appended to the banner: the experiment
#             facts that belong in the head of a log file
#   argv      command-line arguments, without the R interpreter's own
run_driver_main <- function(stage, headline, notes = NULL,
                            argv = commandArgs(trailingOnly = TRUE)) {
  stage <- .as_stage(stage)
  opt <- parse_stage_args(argv, stage)
  if (opt$help) {
    cat(.usage(stage), sep = "\n")
    cat("\n")
    return(invisible(TRUE))
  }

  pcfg <- resolve_config(preset = opt$preset, csv = opt$csv)
  runs <- expected_run_folders(pcfg, stage)

  entries <- list(narrative = pcfg$preset, csv = opt$csv, identifier = pcfg$identifier)
  entries$runs <- nrow(runs)
  entries[["output to"]] <- results_folder(pcfg, stage)
  log_banner(headline, c(entries, as.list(notes)))

  # --list needs no patch tarball: run names come from the narrative alone.
  if (opt$list) {
    print_run_set(pcfg, stage, runs)
    return(invisible(runs))
  }

  if (stage > 1L) {
    patch <- resolve_patch(pcfg, stage, requested = opt$patch, must_exist = !opt$validate)
    pcfg <- with_patch(pcfg, stage, patch)
    log_step("CONFIG", "patch tarball ", patch, " from ", patch_repo_dir(pcfg))
  }

  if (opt$validate) {
    print_cfg_deltas(pcfg, stage, runs)
    log_step("CHECK", "config resolves; nothing was run (--validate)")
    return(invisible(TRUE))
  }

  for (i in seq_len(nrow(runs))) {
    run_stage(pcfg, stage, be = .sweep_arg(runs$be[i]), ghg = .sweep_arg(runs$ghg[i]),
              dry_run = opt$dry_run, first = (i == 1L))
  }
  log_step(if (opt$dry_run) "SKIP" else "SUBMIT",
           nrow(runs), " run(s) of stage ", stage,
           if (opt$dry_run) " assembled; start_run() not called (--dry-run)" else " handed to start_run()")
  invisible(TRUE)
}
