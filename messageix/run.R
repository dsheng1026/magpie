# |  Run the experiments. This is the command.
# |
# |  Two files are the whole surface of this pipeline: messageix/experiments.R
# |  says what the experiments are, and this one runs them.
# |
# |    Rscript messageix/run.R --f56=PATH          every experiment, in order
# |    Rscript messageix/run.R biodiversity        just this one
# |    Rscript messageix/run.R status              what is finished, what would run
# |    Rscript messageix/run.R matrix default      the reduce phase alone
# |
# |  An experiment goes through four phases, and this file runs them in order,
# |  waiting for the cluster between them and skipping whatever is already
# |  finished:
# |
# |    calibrate  one run, solving for the land-use intensity trajectory
# |    price      the bioenergy price sweep
# |    demand     the GHG price sweep -- the runs the emulator is fitted to
# |    reduce     the matrix MESSAGEix reads, woodfuel included
# |
# |  Between phases the pipeline packs what one produced into the inputs the next
# |  reads. That is not a phase and is never scheduled by hand; it is narrated as
# |  ">> PACK: ..." when it happens.
# |
# |  Experiments run one after another rather than together. The cluster is what
# |  actually runs the MAgPIE runs, so starting two experiments at once only
# |  queues the same work twice over. If one fails, the run stops there and the
# |  experiments after it are reported "not reached" -- an unattended run that
# |  carries on through a broken cluster wastes days. --keep-going asks for the
# |  opposite.
# |
# |  Before anything starts, every selected experiment is checked: its settings
# |  resolve, its GHG price file carries every column and year it asks of it, and
# |  its input tarballs are reachable. One file is passed to every experiment, and
# |  experiments may sweep different GHG price levels, so the file has to satisfy
# |  all of them -- a column missing for the last one would otherwise surface
# |  after the first has run in full.
# |
# |  Waiting out four phases of every experiment is measured in days, so --submit
# |  hands the whole thing to the cluster as one job and returns.
# |
# |  Interface
# |    chosen_experiments(opt)              -> chr; the experiments this command covers
# |    print_experiment_names(configs, opt)  -> invisible; where each experiment's work lands
# |    experiment_collisions(configs, opt)  -> chr; experiments writing to the same place
# |    run_flags_through(opt, verb, names)  -> chr; this command line, for the submitted copy
# |    run_main(argv)                       -> invisible; the whole command line
# |
# |  Dependencies: tibble/dplyr, messageix/R/pipeline.R and the messageix/R/ layer.
# |  Run from the MAgPIE model root.

source("messageix/R/pipeline.R")

# ---- which experiments ------------------------------------------------------

# The experiments this command covers: the ones named on the command line, in
# the order named, or every experiment of messageix/experiments.R.
chosen_experiments <- function(opt) {
  available <- experiment_names()
  wanted <- c(opt$positional, if (is.null(opt$experiment)) character(0) else opt$experiment)
  if (!length(wanted)) return(available)
  unknown <- setdiff(wanted, available)
  if (length(unknown)) {
    log_die(paste(unknown, collapse = ", "), " is not an experiment in ", experiments_file(),
            ". It declares: ", paste(available, collapse = ", "),
            ". Adding one is a new entry in that list.")
  }
  if (anyDuplicated(wanted)) {
    log_die(paste(unique(wanted[duplicated(wanted)]), collapse = ", "),
            " is named more than once; an experiment runs once")
  }
  wanted
}

# ---- what stops the whole command -------------------------------------------

# Two experiments writing to one path. Run folders and matrix names are both
# derived from the experiment's own name, so distinct experiments cannot land on
# the same path -- this asserts it rather than trusting it, because the cost of
# being wrong is one experiment's results silently replacing another's.
experiment_collisions <- function(configs, opt) {
  problems <- character(0)
  names <- names(configs)

  same <- function(paths, what) {
    for (path in unique(paths[duplicated(paths)])) {
      sharing <- names[paths == path]
      problems <<- c(problems, paste0(
        "experiments ", paste(sharing, collapse = " and "), " both write ", what, " to ", path,
        ". Experiment names must differ from each other."))
    }
  }

  run_paths <- character(0)
  matrix_paths <- character(0)
  for (name in names) {
    run_paths[name] <- dirname(results_folder(configs[[name]], 3L))
    matrix_paths[name] <- matrix_csv(configs[[name]], opt)
  }
  same(run_paths, "their runs")
  same(matrix_paths, "their matrix")
  problems
}

# ---- command line -----------------------------------------------------------

.synopsis_run <- paste(
  "usage: Rscript messageix/run.R [status|matrix] [EXPERIMENT ...] [--phase=PHASE[,PHASE]]",
  "[--force[=PHASE[,PHASE]]] [--f56=PATH] [--matrix-dir=DIR] [--set=key=value]",
  "[--layout=legacy] [--keep-going] [--submit] [--validate] [--dry-run] [--help]")

.usage_run <- function() c(
  "Run the experiments declared in messageix/experiments.R: each one through the four",
  "phases of the MAgPIE -> MESSAGEix pipeline, in order, waiting for the cluster between",
  "them and skipping whatever is already finished.",
  "",
  "  Rscript messageix/run.R [verb] [experiment ...] [flags]   (from the MAgPIE model root)",
  "",
  "With no experiment named, every experiment in the file runs, in the order written.",
  "",
  "Verbs:",
  "  (none)              run the pipeline",
  "  status              print what is finished and what would run, then stop",
  "  matrix              build the matrix from runs that are already there",
  "                      (the same thing as --phase=reduce)",
  "",
  "Phases, in order:",
  "  calibrate           one run, solving for the land-use intensity trajectory the rest",
  "                      of the pipeline rests on",
  "  price               the bioenergy price sweep: one run per bioenergy price level",
  "  demand              the GHG price sweep: one run per pair, the emulator training set",
  "  reduce              the matrix MESSAGEix reads, woodfuel included",
  "",
  "Between phases the pipeline packs what one produced into the inputs the next reads.",
  "That is not a phase and cannot be scheduled; it happens when what it would write is",
  "not already there, and is narrated as '>> PACK: ...'.",
  "",
  "Flags:",
  "  --phase=PHASE[,...] run only these phases",
  "  --force[=PHASE,...] run these phases even though they are already finished; bare",
  "                      --force means every phase this command covers",
  "  --f56=PATH          the GHG price trajectories. Required whenever an experiment has",
  "                      to build the demand sweep's inputs, and checked for every",
  "                      experiment before the first one starts.",
  paste0("  --matrix-dir=DIR    where the matrix CSVs are written (default: ", MATRIX_DIR_DEFAULT, ")"),
  "  --set=key=value     override one setting for this command; repeatable. Any lever of",
  "                      the world (messageix/R/world_levers.R), the sampling plan, or an",
  "                      infrastructure setting (messageix/R/pipeline_infrastructure.R)",
  "  --layout=legacy     in the reduce phase, read run folders named the way an older set",
  "                      of runs on the cluster names them. For checking this pipeline's",
  "                      matrix against those runs; nothing produces runs in that layout.",
  "  --keep-going        carry on with the next experiment when one fails, instead of",
  "                      ending the run there",
  "  --submit            hand this whole command to SLURM as one job and return, so the",
  "                      waiting survives a closed laptop. The job script and its log are",
  paste0("                      written to ", JOB_DIR, "."),
  "  --validate          check everything and print each phase's assembled configs, then",
  "                      stop. This is the rehearsal for a tree where nothing has been",
  "                      built yet.",
  "  --dry-run           narrate every command and assemble the run configs; submit",
  "                      nothing. It needs each phase's packed inputs to be on disk",
  "                      already, because it assembles a real run config.",
  "  --help              this text",
  "",
  "Every option is accepted as --key=value and as --key value.",
  "",
  "Experiments run one after another, and one that fails ends the command: the ones after",
  "it are reported \"not reached\" and nothing of theirs is started. That is deliberate --",
  "an unattended run through a broken cluster wastes days -- and --keep-going is the way",
  "to ask for the opposite. Either way, starting again picks up where it stopped:",
  "finished phases are skipped.",
  "",
  "One phase on its own, to re-run or watch it:",
  "  Rscript messageix/R/run_phase.R --phase=price --experiment=NAME")

parse_run_args <- function(argv) {
  opt <- parse_flags(argv,
                     known      = c("phase", "f56", "matrix-dir", "layout", "experiment"),
                     flags      = c("keep-going", "submit", "validate", "dry-run", "help"),
                     repeatable = "set",
                     optional   = "force",
                     positional = TRUE,
                     usage      = .synopsis_run)

  verbs <- c("status", "matrix")
  free <- opt$positional
  opt$verb <- ""
  if (length(free) && free[1L] %in% verbs) {
    opt$verb <- free[1L]
    free <- free[-1L]
  }
  stray <- intersect(free, verbs)
  if (length(stray)) {
    log_die("'", stray[1L], "' is a verb and comes first: Rscript messageix/run.R ", stray[1L],
            " [experiment ...]")
  }
  opt$positional <- free

  if (identical(opt$verb, "matrix")) {
    if (!is.null(opt$phase) && !identical(opt$phase, "reduce")) {
      log_die("the matrix verb is the reduce phase, so --phase=", opt$phase,
              " asks for two different things. Drop one of them.")
    }
    opt$phase <- "reduce"
  }
  if (is.null(opt[["matrix-dir"]])) opt[["matrix-dir"]] <- MATRIX_DIR_DEFAULT
  if (!is.null(opt$layout) && !opt$layout %in% c("current", "legacy")) {
    log_die("--layout takes 'current' or 'legacy', got '", opt$layout, "'")
  }
  chosen <- c("--validate", "--dry-run")[c(isTRUE(opt$validate), isTRUE(opt[["dry-run"]]))]
  if (length(chosen) > 1L) {
    log_die(paste(chosen, collapse = " and "), " do different things; pick one.")
  }
  if (isTRUE(opt$submit) && identical(opt$verb, "status")) {
    log_die("status prints here and now; there is nothing to submit. Drop one of them.")
  }
  opt
}

# The command line this one passes on to the copy of itself it submits:
# everything it carried except --submit, which has already been acted on, and
# with the experiments named explicitly so the job runs the same set.
run_flags_through <- function(opt, verb, experiments) {
  args <- c("messageix/run.R", if (nzchar(verb)) verb, experiments)
  for (key in c("phase", "f56", "matrix-dir", "layout")) {
    if (!is.null(opt[[key]])) args <- c(args, paste0("--", key, "=", opt[[key]]))
  }
  if (!is.null(opt$force)) {
    args <- c(args, if (isTRUE(opt$force)) "--force" else paste0("--force=", opt$force))
  }
  for (one in opt$set) args <- c(args, paste0("--set=", one))
  for (switch in c("keep-going", "validate", "dry-run")) {
    if (isTRUE(opt[[switch]])) args <- c(args, paste0("--", switch))
  }
  args
}

# How many MAgPIE runs the two sweeps of these experiments come to, for the
# banner. The calibration run is left out: it is one run per experiment and the
# sweeps are what the number is about.
sweep_runs <- function(configs) {
  total <- 0
  for (pcfg in configs) {
    total <- total + nrow(expected_run_folders(pcfg, 2L)) + nrow(expected_run_folders(pcfg, 3L))
  }
  total
}

# ---- reporting --------------------------------------------------------------

# The plan of the whole command: one row per experiment and phase.
print_run_plan <- function(plans) {
  per_experiment <- list()
  for (name in names(plans)) {
    phases <- dplyr::filter(plans[[name]], user)
    per_experiment[[name]] <- tibble::tibble(
      experiment = name,
      phase      = phases$step,
      state      = phases$state,
      action     = phases$action,
      detail     = phases$detail)
  }
  rows <- dplyr::bind_rows(per_experiment)
  running <- sum(rows$action == "run")
  log_step("CONFIG", running, " of ", nrow(rows), " phase(s) to run across ",
           length(plans), " experiment(s)")
  .print_table(rows)
  invisible(rows)
}

# Where each experiment's work lands. The folder and the matrix name are worked
# out from the experiment's own name, so this is where a reader checks that the
# experiment they meant is the one about to be run.
print_experiment_names <- function(configs, opt) {
  for (name in names(configs)) {
    pcfg <- configs[[name]]
    log_step("CONFIG", name, ": runs in ", dirname(results_folder(pcfg, 3L)),
             " (identifier ", pcfg$identifier, "), matrix ", woodfuel_csv(pcfg, opt))
  }
  invisible(NULL)
}

# What is waiting to be packed, said once per experiment. Packing is not in the
# plan table, so this is where a reader learns that it is about to happen.
narrate_packing <- function(name, steps, plan) {
  for (i in which(!plan$user)) {
    if (plan$action[i] != "run") next
    log_step("CONFIG", name, ": ", steps[[i]]$label, " on the way")
  }
}

print_run_summary <- function(experiments, outcomes) {
  log_step("DONE", "finished")
  .print_table(data.frame(experiment = experiments, outcome = outcomes,
                          stringsAsFactors = FALSE))
}

# ---- main -------------------------------------------------------------------

run_main <- function(argv = commandArgs(trailingOnly = TRUE)) {
  opt <- parse_run_args(argv)
  if (isTRUE(opt$help)) {
    cat(.usage_run(), sep = "\n")
    cat("\n")
    return(invisible(TRUE))
  }

  experiments <- chosen_experiments(opt)
  steps <- pipeline_steps()
  overrides <- cli_overrides(opt$set)

  configs <- list()
  plans <- list()
  for (name in experiments) {
    configs[[name]] <- resolve_config(experiment = name, overrides = overrides)
    plans[[name]] <- plan_steps(steps, configs[[name]], opt)
  }

  log_banner("magpie -> messageix", list(
    experiments = paste0(length(experiments), ": ", paste(experiments, collapse = ", ")),
    phases      = paste(selected_phases(opt$phase), collapse = ", "),
    runs        = paste0(sweep_runs(configs), " across the experiments"),
    "matrix to" = opt[["matrix-dir"]],
    order       = "one experiment at a time, in the order listed"))

  print_experiment_names(configs, opt)
  print_run_plan(plans)
  for (name in experiments) narrate_packing(name, steps, plans[[name]])

  # Two experiments writing to one place cannot be fixed by running anything, so
  # it stops every mode including status. Everything else is a readiness problem:
  # fatal on a real run, reported on a rehearsal, where seeing the whole list at
  # once is the point.
  collisions <- experiment_collisions(configs, opt)
  if (length(collisions)) {
    log_die("experiments collide:\n  - ", paste(collisions, collapse = "\n  - "))
  }

  problems <- character(0)
  for (name in experiments) {
    found <- preflight(steps, plans[[name]], configs[[name]], opt)
    if (length(found)) problems <- c(problems, paste0(name, ": ", found))
  }
  if (length(problems)) {
    if (identical(opt$verb, "status") || isTRUE(opt$validate)) {
      for (problem in problems) log_warn(problem)
    } else {
      log_die("this cannot run as asked:\n  - ", paste(problems, collapse = "\n  - "))
    }
  }

  if (identical(opt$verb, "status")) return(invisible(plans))

  if (isTRUE(opt$submit)) {
    # The time limit is the whole command's: every phase of runs every experiment
    # will wait for, since they run one after another in this one job.
    is_stage <- rep(FALSE, length(steps))
    for (i in seq_along(steps)) is_stage[i] <- identical(steps[[i]]$kind, "stage")
    waited <- 0
    for (name in experiments) {
      plan <- plans[[name]]
      waited <- waited + sum(plan$action == "run" & is_stage)
    }
    return(invisible(submit_driver(run_flags_through(opt, opt$verb, experiments),
                                   pcfg = configs[[experiments[1L]]],
                                   name = "mm_pipeline", stages = waited)))
  }

  outcomes <- rep("not reached", length(experiments))
  on.exit(print_run_summary(experiments, outcomes), add = TRUE)

  for (i in seq_along(experiments)) {
    name <- experiments[i]
    plan <- plans[[name]]
    log_step("EXPERIMENT", name, " (", i, " of ", length(experiments), "): ",
             sum(plan$action == "run" & plan$user), " phase(s) to run")
    # Marked failed while the experiment is in progress, so that the summary
    # printed on the way out of a stopped run names the one that stopped it.
    outcomes[i] <- "failed"

    # A failed experiment ends the command, because the next one may well fail
    # the same way and an unattended run that keeps going through a broken
    # cluster wastes days. --keep-going is for the case where the experiments are
    # genuinely independent and a whole night is worth the runs that do work.
    if (isTRUE(opt[["keep-going"]])) {
      failed <- tryCatch({
        run_pipeline(steps, plan, configs[[name]], opt)
        FALSE
      }, error = function(e) {
        log_warn(name, " failed and --keep-going is set, so the next experiment starts. ",
                 "What failed: ", conditionMessage(e))
        TRUE
      })
      if (failed) next
    } else {
      run_pipeline(steps, plan, configs[[name]], opt)
    }
    outcomes[i] <- if (isTRUE(opt$validate)) "config checked" else
                   if (isTRUE(opt[["dry-run"]])) "assembled, nothing submitted" else "run"
  }

  invisible(TRUE)
}

if (invoked_directly("run.R")) run_main()
