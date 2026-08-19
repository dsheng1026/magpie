# |  Run a set of narratives: the experiment, one command.
# |
# |  A narrative is a column of the narratives file, and the set of narratives
# |  that exists is the set of columns that exists -- there is no list of
# |  experiments anywhere in the code, and adding one to the experiment means
# |  adding a column, not editing a script.
# |
# |  This file picks narratives out of that file and runs the whole pipeline for
# |  each of them in turn, as a fresh process running exactly the command a
# |  person would type to run one narrative alone:
# |
# |      Rscript messageix/start/driver_pipeline.R --preset=<narrative> ...
# |
# |  So there are three levels, and each one only knows its own job: this file
# |  says which narratives the experiment is made of, driver_pipeline.R says how
# |  one narrative is produced, and the per-step scripts say what each step does.
# |
# |  The narratives run one after another rather than together. The cluster is
# |  what actually runs the MAgPIE runs, so starting two narratives at once only
# |  queues the same work twice over.
# |
# |  If a narrative fails, the experiment stops there. The narratives after it
# |  are reported "not reached" and nothing of theirs is started -- an unattended
# |  run that carries on through a broken cluster wastes days. --keep-going asks
# |  for the opposite, and records the failure in the closing summary.
# |
# |  An experiment waits out every stage of every narrative in sequence, which is
# |  measured in days, so --submit hands the whole thing to the cluster as one
# |  job and returns.
# |
# |  Before anything starts, every narrative is checked: its settings resolve, its
# |  GHG price file carries every column and year that narrative asks of it, and
# |  its input tarballs are reachable. One file is passed to every narrative, and
# |  narratives may sweep different GHG price levels, so the file has to satisfy
# |  all of them -- a column missing for the last one would otherwise surface
# |  after the first has run in full.
# |
# |  Usage, from the MAgPIE model root:
# |    Rscript messageix/start/driver_ensemble.R --f56=PATH       # every narrative
# |    Rscript messageix/start/driver_ensemble.R --f56=PATH --submit   # as one cluster job
# |    Rscript messageix/start/driver_ensemble.R --presets=default,biodiversity
# |    Rscript messageix/start/driver_ensemble.R --list           # the plan, per narrative
# |
# |  Interface
# |    ensemble_presets(requested, csv)      -> chr; the narratives to run
# |    narratives_resolving_stage1(configs)  -> chr; those whose reference run is stale
# |    narrative_plan(steps, pcfg, popt, resolves) -> data.frame; one narrative's step plan
# |    narrative_options(opt, preset)        -> list; the pipeline options for one narrative
# |    ensemble_collisions(configs, opt)     -> chr; narratives that write to the same place
# |    ensemble_command(opt, preset, plan)   -> chr; the pipeline command line
# |    ensemble_flags_through(opt)           -> chr; this command line, for the submitted copy
# |    ensemble_main(argv)                   -> invisible; the whole command line
# |
# |  Dependencies: messageix/start/driver_pipeline.R, for the step definitions,
# |  the per-step state check and the plan. Run from the MAgPIE model root.

source("messageix/start/driver_pipeline.R")

# ---- which narratives --------------------------------------------------------

# The narratives to run. "all", the default, is every column of the narratives file --
# the experiment is what the CSV says it is. A named list runs a subset, in the
# order named.
ensemble_presets <- function(requested, csv) {
  available <- preset_columns(csv)
  if (is.null(requested) || identical(trimws(requested), "all")) {
    if (!length(available)) log_die(csv, " offers no narrative columns")
    return(available)
  }
  wanted <- trimws(strsplit(requested, ",", fixed = TRUE)[[1L]])
  wanted <- wanted[nzchar(wanted)]
  if (!length(wanted)) log_die("--presets needs at least one narrative name, or 'all'")
  unknown <- setdiff(wanted, available)
  if (length(unknown)) {
    log_die("--presets names ", unknown, ", which is not a column of ", csv,
            ". The narratives it offers: ", paste(available, collapse = ", "))
  }
  if (anyDuplicated(wanted)) {
    log_die("--presets names ", unique(wanted[duplicated(wanted)]),
            " more than once; a narrative is run once")
  }
  wanted
}

# ---- the reference run -------------------------------------------------------

# Narratives whose reference run folder holds a tau solved under other settings.
# Each narrative has its own output folder, so no two narratives compete for the
# folder; what they do compete with is their own past, since a folder is
# addressed by name and a setting behind stage 1 may have changed since it was
# filled. stage1_state() answers that, and lives in messageix/R/utils_runs.R
# with the record it reads, because the pipeline driver asks the same question
# when it decides whether stage 1 is finished.
narratives_resolving_stage1 <- function(configs) {
  names(configs)[vapply(configs, function(pcfg) {
    identical(stage1_state(pcfg), "differs")
  }, logical(1))]
}

# ---- one narrative's plan ----------------------------------------------------

# The options driver_pipeline.R would have been given for this narrative. Every
# flag but the narrative itself is passed straight through, so a narrative run
# from here and the same narrative run by hand see the same settings.
narrative_options <- function(opt, preset) {
  popt <- opt
  popt$presets <- NULL
  popt$preset <- preset
  popt
}

# One narrative's step plan, with what the reference run on disk means for it.
# Where that run cannot be reused, the step is planned to run again and says so,
# which is the difference between reading it in the plan and hitting it two
# steps later.
#
#   resolves  TRUE when the reference run on disk was solved under settings this
#             narrative has since changed, so it has to be solved again
narrative_plan <- function(steps, pcfg, popt, resolves = FALSE) {
  plan <- plan_steps(steps, pcfg, popt)
  i <- match("stage1_tau", plan$step)
  state <- stage1_state(pcfg)
  if (resolves) {
    plan$detail[i] <- paste0(run_folder(pcfg, 1L), " holds a run solved under other settings; ",
                             "it is solved again")
    if (!identical(plan$state[i], "skipped")) {
      plan$state[i] <- "re-solve"
      plan$action[i] <- "run"
      plan$complete[i] <- FALSE
    }
  } else if (identical(state, "unrecorded")) {
    plan$detail[i] <- paste0(plan$detail[i], "; solved under settings it did not record")
  }
  plan
}

# ---- what stops the whole set ------------------------------------------------

# Two narratives writing to one path. Run folders and matrix names are both
# derived from the narrative's own name, so distinct columns cannot land on the
# same path -- this asserts it rather than trusting it, because the cost of
# being wrong is one narrative's results silently replacing another's.
ensemble_collisions <- function(configs, opt) {
  problems <- character(0)
  names <- names(configs)

  same <- function(paths, what) {
    for (path in unique(paths[duplicated(paths)])) {
      sharing <- names[paths == path]
      problems <<- c(problems, paste0(
        "narratives ", paste(sharing, collapse = " and "), " both write ", what, " to ", path,
        ". Narrative names must differ from each other."))
    }
  }

  same(vapply(configs, function(p) dirname(results_folder(p, 3L)), character(1)), "their runs")
  same(vapply(configs, function(p) matrix_csv(p, opt), character(1)), "their matrix")
  problems
}

# ---- running one narrative ---------------------------------------------------

# The pipeline command line for one narrative: this driver's own flags passed
# through unchanged, plus the narrative, plus the reference run added to --force
# where the plan found it belongs to somebody else.
ensemble_command <- function(opt, preset, plan) {
  args <- c("messageix/start/driver_pipeline.R",
            paste0("--preset=", preset), paste0("--csv=", opt$csv))
  for (flag in c("f56", "matrix-dir", "from", "until", "skip")) {
    if (!is.null(opt[[flag]])) args <- c(args, paste0("--", flag, "=", opt[[flag]]))
  }

  forced <- if (is.null(opt$force)) character(0) else {
    trimws(strsplit(opt$force, ",", fixed = TRUE)[[1L]])
  }
  if (any(plan$state == "re-solve")) forced <- c(forced, "stage1_tau")
  forced <- unique(forced[nzchar(forced)])
  if (length(forced)) args <- c(args, paste0("--force=", paste(forced, collapse = ",")))

  mode <- c("--validate", "--dry-run")[c(isTRUE(opt$validate), isTRUE(opt[["dry-run"]]))]
  c(args, mode)
}

# The flags this driver passes on to the copy of itself it submits to the
# cluster: everything the command line carried except --submit, which has
# already been acted on.
ensemble_flags_through <- function(opt) {
  flags_through(opt, c("presets", "csv", "f56", "matrix-dir", "from", "until", "skip", "force"),
                c("keep-going", "validate", "dry-run"))
}

# ---- command line ------------------------------------------------------------

.synopsis_ensemble <- paste(
  "usage: Rscript messageix/start/driver_ensemble.R [--presets=NAME[,NAME]|all]",
  "[--csv=PATH] [--f56=PATH] [--matrix-dir=DIR] [--from=STEP] [--until=STEP]",
  "[--skip=STEP[,STEP]] [--force=STEP[,STEP]] [--keep-going] [--submit] [--list]",
  "[--validate] [--dry-run] [--help]")

.usage_ensemble <- c(
  "Run the whole experiment: every narrative, one after another, each one the full",
  "MAgPIE -> MESSAGEix pipeline.",
  "",
  "  Rscript messageix/start/driver_ensemble.R [flags]   (from the MAgPIE model root)",
  "",
  "A narrative is a column of the narratives file. Adding one to the experiment means",
  "adding a column there -- nothing in the code lists them.",
  "",
  "Flags:",
  "  --presets=LIST      the narratives to run: names separated by commas, or 'all'",
  "                      for every column of the narratives file (default: all)",
  paste0("  --csv=PATH          narratives file (default: ", default_preset_csv(), ")"),
  "  --f56=PATH          the GHG price trajectories. Required whenever a narrative",
  "                      has to build its stage-3 inputs, and checked for every",
  "                      narrative before the first one starts.",
  paste0("  --matrix-dir=DIR    where the matrix CSVs are written (default: ",
         MATRIX_DIR_DEFAULT, ")"),
  "  --from=STEP         start each narrative at this step",
  "  --until=STEP        stop each narrative after this step",
  "  --skip=STEP[,STEP]  leave these steps out of every narrative",
  "  --force=STEP[,STEP] run these steps even though they are already finished",
  "  --keep-going        carry on with the next narrative when one fails, instead of",
  "                      ending the experiment there",
  "  --submit            hand the whole experiment to SLURM as one job and return, so",
  "                      the waiting survives a closed laptop. The job script and its",
  paste0("                      log are written to ", JOB_DIR, "."),
  "  --list              print the plan for every narrative, with anything that would",
  "                      stop the experiment, then stop",
  "  --validate          check the whole experiment and print each narrative's",
  "                      assembled configs, then stop",
  "  --dry-run           narrate every command and assemble the run configs;",
  "                      submit nothing",
  "  --help              this text",
  "",
  "Every option is accepted as --key=value and as --key value.",
  "",
  "Narratives run one after another. A narrative whose reference run has already been",
  "solved under the same settings reuses it; one whose settings have changed since that",
  "run was made solves it again, and the plan says so.",
  "",
  "A narrative that fails ends the experiment: the narratives after it are reported",
  "\"not reached\" in the closing summary and nothing of theirs is started. That is",
  "deliberate -- an unattended run through a broken cluster wastes days -- and",
  "--keep-going is the way to ask for the opposite. Either way, starting the",
  "experiment again picks up where it stopped: finished steps are skipped.")

parse_ensemble_args <- function(argv) {
  opt <- parse_flags(argv,
                     known   = c("presets", "csv", "f56", "matrix-dir",
                                 "from", "until", "skip", "force"),
                     flags   = c("keep-going", "submit", "list", "validate", "dry-run", "help"),
                     aliases = c("preset-csv" = "csv"),
                     usage   = .synopsis_ensemble)
  if (is.null(opt$csv)) opt$csv <- default_preset_csv()
  if (is.null(opt[["matrix-dir"]])) opt[["matrix-dir"]] <- MATRIX_DIR_DEFAULT
  chosen <- c("--list", "--validate", "--dry-run")[c(isTRUE(opt$list), isTRUE(opt$validate),
                                                     isTRUE(opt[["dry-run"]]))]
  if (length(chosen) > 1L) {
    log_die(paste(chosen, collapse = " and "), " do different things; pick one.")
  }
  if (isTRUE(opt$submit) && isTRUE(opt$list)) {
    log_die("--list prints the plan here and now; there is nothing to submit. Drop one of them.")
  }
  opt
}

# The plan of the whole experiment: one row per narrative and step.
print_ensemble_plan <- function(plans) {
  rows <- do.call(rbind, lapply(names(plans), function(name) {
    data.frame(narrative = name, plans[[name]][, c("step", "state", "action", "detail")],
               stringsAsFactors = FALSE)
  }))
  running <- sum(rows$action == "run")
  log_step("CONFIG", running, " of ", nrow(rows), " step(s) to run across ",
           length(plans), " narrative(s)")
  .print_table(rows)
  invisible(rows)
}

print_ensemble_summary <- function(presets, outcomes) {
  log_step("DONE", "experiment finished")
  .print_table(data.frame(narrative = presets, outcome = outcomes, stringsAsFactors = FALSE))
}

ensemble_main <- function(argv = commandArgs(trailingOnly = TRUE)) {
  opt <- parse_ensemble_args(argv)
  if (isTRUE(opt$help)) {
    cat(.usage_ensemble, sep = "\n")
    cat("\n")
    return(invisible(TRUE))
  }

  presets <- ensemble_presets(opt$presets, opt$csv)
  steps <- pipeline_steps()

  configs <- list()
  options <- list()
  for (preset in presets) {
    options[[preset]] <- narrative_options(opt, preset)
    configs[[preset]] <- resolve_config(preset = preset, csv = opt$csv)
  }

  # Which narratives cannot use the reference run sitting in their folder.
  resolving <- narratives_resolving_stage1(configs)

  plans <- list()
  for (preset in presets) {
    plans[[preset]] <- narrative_plan(steps, configs[[preset]], options[[preset]],
                                      resolves = preset %in% resolving)
  }

  log_banner("magpie -> messageix experiment", list(
    csv        = opt$csv,
    narratives = paste0(length(presets), ": ", paste(presets, collapse = ", ")),
    runs       = paste0(sum(vapply(configs, function(p) {
                          nrow(expected_run_folders(p, 2L)) + nrow(expected_run_folders(p, 3L))
                        }, numeric(1))), " across the experiment"),
    "matrix to" = opt[["matrix-dir"]],
    order      = "one narrative at a time, in the order listed"))

  print_ensemble_plan(plans)

  # Two narratives writing to one place cannot be fixed by running anything, so
  # it stops every mode including --list. Everything else is a readiness problem:
  # fatal on a real run, reported on a rehearsal, where seeing the whole list at
  # once is the point.
  collisions <- ensemble_collisions(configs, opt)
  if (length(collisions)) {
    log_die("narratives collide:\n  - ", paste(collisions, collapse = "\n  - "))
  }

  problems <- character(0)
  for (preset in presets) {
    plan <- plans[[preset]]
    if (identical(plan$state[match("stage1_tau", plan$step)], "skipped") &&
        preset %in% resolving) {
      problems <- c(problems, paste0(
        preset, ": its reference run is left out of this run, and the run in its folder was ",
        "solved under other settings. patch_step2 refuses to read it, so this narrative would ",
        "stop there. Let it solve its reference run again."))
    }
    # Everything one narrative needs, checked by the pipeline's own pre-flight so
    # that the two cannot disagree about what "ready" means.
    found <- preflight(steps, plan, configs[[preset]], options[[preset]])
    if (length(found)) problems <- c(problems, paste0(preset, ": ", found))
  }

  if (length(problems)) {
    if (isTRUE(opt$list) || isTRUE(opt$validate)) {
      for (problem in problems) log_warn(problem)
    } else {
      log_die("the experiment cannot run as asked:\n  - ", paste(problems, collapse = "\n  - "))
    }
  }

  if (isTRUE(opt$list)) return(invisible(plans))

  if (isTRUE(opt$submit)) {
    # The time limit is the whole experiment's: every stage every narrative will
    # wait for, since they run one after another in this one job.
    waited <- sum(vapply(presets, function(preset) {
      plan <- plans[[preset]]
      sum(plan$action == "run" & vapply(steps, `[[`, character(1), "kind") == "stage")
    }, numeric(1)))
    return(invisible(submit_driver(c("messageix/start/driver_ensemble.R",
                                     ensemble_flags_through(opt)),
                                   pcfg = configs[[presets[1L]]],
                                   name = "mm_experiment", stages = waited)))
  }

  outcomes <- rep("not reached", length(presets))
  on.exit(print_ensemble_summary(presets, outcomes), add = TRUE)

  for (i in seq_along(presets)) {
    preset <- presets[i]
    log_step("NARRATIVE", preset, " (", i, " of ", length(presets), "): ",
             sum(plans[[preset]]$action == "run"), " step(s) to run")
    # Marked failed while the narrative is in progress, so that the summary
    # printed on the way out of a stopped experiment names the one that stopped it.
    outcomes[i] <- "failed"
    args <- ensemble_command(opt, preset, plans[[preset]])
    log_step("EXEC", "Rscript ", paste(args, collapse = " "))

    # A failed narrative ends the experiment, because the next one may well fail
    # the same way and an unattended run that keeps going through a broken
    # cluster wastes days. --keep-going is for the case where the narratives are
    # genuinely independent and a whole night is worth the runs that do work: the
    # failure is recorded in the summary and the next narrative starts.
    if (isTRUE(opt[["keep-going"]])) {
      failed <- tryCatch({
        run_step_command(args, preset)
        FALSE
      }, error = function(e) {
        log_warn(preset, " failed and --keep-going is set, so the experiment continues with the ",
                 "next narrative. What failed: ", conditionMessage(e))
        TRUE
      })
      if (failed) next
    } else {
      run_step_command(args, preset)
    }
    outcomes[i] <- if (isTRUE(opt$validate)) "config checked" else
                   if (isTRUE(opt[["dry-run"]])) "assembled, nothing submitted" else "run"
  }

  invisible(TRUE)
}

if (invoked_directly("driver_ensemble.R")) ensemble_main()
