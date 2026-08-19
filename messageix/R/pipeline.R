# |  The pipeline: what the four phases are, which of them still have to run,
# |  and what has to be true before any of them starts.
# |
# |  The phases, in order:
# |
# |    calibrate  one MAgPIE run producing the reference land-use intensity
# |               trajectory the rest of the pipeline rests on
# |    price      the bioenergy price sweep: one run per bioenergy price level
# |    demand     the emulator training set: one run per bioenergy price and GHG
# |               price pair
# |    reduce     turns that training set into the matrix MESSAGEix reads, with
# |               woodfuel added
# |
# |  Between the phases the pipeline packs what one produced into the inputs the
# |  next reads. Packing is not a phase and is never scheduled by hand: it
# |  happens on the way from calibrate to price, and on the way from price to
# |  demand, whenever the tarball it would write is not already on disk. It is
# |  narrated as ">> PACK: ..." so a log says when it happened.
# |
# |  Each phase runs as a fresh process running the command a person would type
# |  to run that phase alone. This file sequences those commands and nothing
# |  else, so running the pipeline and running one phase by hand cannot drift
# |  apart.
# |
# |  Why it has to wait. MAgPIE hands its runs to the cluster and returns
# |  immediately, so a phase that has finished has only finished submitting.
# |  Between phases the pipeline therefore waits until every run the experiment
# |  expects holds a solved result, narrating how many have landed. It stops
# |  early -- rather than waiting out the timeout -- when the queue reports no
# |  MAgPIE jobs left while runs are still missing, which means they died. After
# |  the demand sweep it waits for one thing more: each run's results file, which
# |  the job writes after the solve and which the reduce phase is built from.
# |
# |  What it skips. A phase that is already finished is skipped: a run phase when
# |  every run it expects has solved, the reduce phase when its output CSV
# |  exists. Restarting after a failure therefore picks up where the failure was,
# |  and --force runs a phase anyway.
# |
# |  What it checks before it starts. Everything the requested run needs, checked
# |  while it is still cheap: the experiment resolves, each phase's input either
# |  exists or is produced earlier in the same run, the GHG price file the demand
# |  sweep needs is supplied and holds every column, pollutant and model year the
# |  experiment asks of it, nothing is about to pack a second tarball beside one
# |  already on disk, and the input tarballs are reachable. A missing GHG price
# |  column discovered after two phases have run is hours of cluster time spent
# |  for nothing.
# |
# |  This file is a library. The command is messageix/run.R.
# |
# |  Interface
# |    pipeline_steps()                    -> list; the phases and the packing between them
# |    phase_names()                       -> chr; the four phases, in order
# |    step_status(step, pcfg, opt)        -> list(complete, detail); is it finished
# |    step_commands(step, pcfg, opt, patches) -> list of chr; the Rscript command lines
# |    plan_steps(steps, pcfg, opt)        -> data.frame(step, user, state, action, complete, detail)
# |    print_phase_plan(plan)              -> invisible; the plan as the reader sees it
# |    f56_content_problems(path, pcfg)    -> chr; what the GHG price file is missing
# |    preflight(steps, plan, pcfg, opt)   -> chr; the problems that stop the run
# |    run_step_command(args, label, stdout) -> invisible; one phase as its own process
# |    run_pipeline(steps, plan, pcfg, opt) -> chr; what became of each step
# |    submit_driver(args, pcfg, name, stages, wait_hours) -> invisible(TRUE); hand a command to SLURM
# |    matrix_csv(pcfg, opt) / woodfuel_csv(pcfg, opt) -> chr(1); the matrix files
# |
# |  Dependencies: tibble/dplyr and messageix/R/run_phase.R, for the naming
# |  contract, the solvedness contract and the packed-tarball lookup.

source("messageix/R/run_phase.R")

# Where the matrix CSV goes when --matrix-dir is not given.
MATRIX_DIR_DEFAULT <- "output/emulator"

# ---- the phases -------------------------------------------------------------

# The pipeline, in the order it runs. `stage` is the MAgPIE stage a step runs or
# packs inputs for; `user` says whether it is a phase a person schedules. The two
# packing steps are not: they happen between phases, when what they would write
# is not already there.
#
# `kind` decides how a step is started and how "already finished" is judged.
# There are three, and this is the whole of what each one means:
#
#   stage   a phase of MAgPIE runs. Started by running run_phase.R as its own
#           process, which submits the runs; finished when every run the
#           experiment expects has solved.
#   patch   packing what one phase produced into the inputs the next one reads.
#           Started by running that stage's packing script; finished when the
#           tarball it would write, whose name carries a digest of its contents,
#           is already in the patch directory.
#   matrix  the reduce phase. Started by running the two reduce scripts in turn;
#           finished when the woodfuel CSV they end with exists.
#
# Five places act on the kind, so a fourth kind is five edits: step_status() and
# step_commands() below; the lookup in plan_steps() that pairs a packing step
# with the phase reading what it packs; preflight(), which checks the packed
# tarballs a phase would face; and run_pipeline(), which narrates rather than
# runs the steps that write artefacts when the command is a rehearsal.
pipeline_steps <- function() {
  list(
    list(name = "calibrate", kind = "stage", stage = 1L, user = TRUE,
         label = "the calibrate phase",
         what = "the reference run whose land-use intensity trajectory the rest of the pipeline needs"),
    list(name = "pack_price", kind = "patch", stage = 2L, user = FALSE,
         label = "packing the price sweep's inputs",
         what = "packing that trajectory into the inputs the price sweep reads"),
    list(name = "price", kind = "stage", stage = 2L, user = TRUE,
         label = "the price phase",
         what = "the bioenergy price sweep"),
    list(name = "pack_demand", kind = "patch", stage = 3L, user = FALSE,
         label = "packing the demand sweep's inputs",
         what = "packing the realised bioenergy demand and the GHG price trajectories into the inputs the demand sweep reads"),
    list(name = "demand", kind = "stage", stage = 3L, user = TRUE,
         label = "the demand phase",
         what = "the emulator training set"),
    list(name = "reduce", kind = "matrix", stage = 3L, user = TRUE,
         label = "the reduce phase",
         what = "building the matrix MESSAGEix reads, woodfuel included")
  )
}

step_names <- function() vapply(pipeline_steps(), `[[`, character(1), "name")

# The phases a command line may name.
phase_names <- function() {
  steps <- pipeline_steps()
  vapply(Filter(function(s) isTRUE(s$user), steps), `[[`, character(1), "name")
}

# The directory holding the demand-sweep run folders: the reduce phase reads all
# of them, so it is addressed one level above a single run.
stage3_run_dir <- function(pcfg) dirname(results_folder(pcfg, 3L))

# The matrix CSV the first reduce script writes, and the woodfuel-augmented CSV
# the second one derives from it. The second is the file MESSAGEix consumes and
# therefore the one that says whether the reduce phase is finished.
matrix_csv <- function(pcfg, opt) {
  file.path(opt[["matrix-dir"]], paste0(pcfg$matrix_basename, ".csv"))
}
woodfuel_csv <- function(pcfg, opt) sub("\\.csv$", "_woodfuel.csv", matrix_csv(pcfg, opt))

# Files a finished run of this step must hold besides the solver output. Only
# the demand sweep has one: the reduce phase reads each run's results file, and
# the job writes that after the solve. Waiting only for the solver output would
# end the wait minutes before the reduce phase can read the runs.
step_extra_files <- function(step) {
  if (identical(step$kind, "stage") && step$stage == 3L) MIF_NAME else character(0)
}

# Is a step finished, and what is on disk to say so.
#
# A run phase is finished when every run the experiment expects has solved --
# the same judgement the wait between phases makes. A packing step is finished
# when its content-hashed tarball is in the patch directory. The reduce phase is
# finished when the woodfuel CSV exists.
#
# The calibration run carries one more condition. Its folder is addressed by
# name, so a re-run may have overwritten it, and the settings behind it may have
# moved since; the folder records what it was solved under, and a record that
# disagrees with this experiment means the run in it is not this experiment's.
step_status <- function(step, pcfg, opt) {
  if (identical(step$kind, "stage")) {
    progress <- stage_progress(pcfg, step$stage, extra = step_extra_files(step))
    detail <- paste0(sum(progress$solved), " of ", nrow(progress), " run(s) solved")
    if (step$stage == 1L && all(progress$solved)) {
      state <- stage1_state(pcfg)
      if (identical(state, "differs")) {
        return(list(complete = FALSE,
                    detail = paste0("the run in ", run_folder(pcfg, 1L),
                                    " was solved under other settings")))
      }
      if (identical(state, "unrecorded")) {
        detail <- paste0(detail, "; solved under settings it did not record")
      }
    }
    return(list(complete = all(progress$solved), detail = detail))
  }
  if (identical(step$kind, "patch")) {
    found <- discover_patch(pcfg, step$stage)
    return(list(complete = length(found) > 0L,
                detail = if (!length(found)) "nothing packed yet" else paste(found, collapse = ", ")))
  }
  out <- woodfuel_csv(pcfg, opt)
  list(complete = file.exists(out),
       detail = paste0(out, if (file.exists(out)) " written" else " not written"))
}

# The command lines a step runs, as arguments to Rscript. A list, because the
# reduce phase is two scripts: the matrix itself, then woodfuel added to it.
#
# Run phases are handed --validate or --dry-run so that a rehearsal of the
# pipeline rehearses the real config assembly. Packing and the reduce phase
# write artefacts, so in those modes they are narrated and not run.
#
#   patches  tarballs packed earlier in this same run, one entry per stage
#            token. A phase whose tarball was just packed is told which file to
#            read rather than left to find it: packing changed content leaves
#            the previous tarball on disk beside the new one, and a phase facing
#            two of them cannot know which is current.
step_commands <- function(step, pcfg, opt, patches = list()) {
  common <- c(paste0("--experiment=", pcfg$experiment),
              if (length(opt$set)) paste0("--set=", opt$set) else character(0))

  if (identical(step$kind, "stage")) {
    mode <- if (isTRUE(opt$validate)) "--validate" else if (isTRUE(opt[["dry-run"]])) "--dry-run" else character(0)
    built <- patches[[stage_token(step$stage)]]
    patch <- if (is.null(built)) character(0) else paste0("--patch=", built)
    return(list(c("messageix/R/run_phase.R", paste0("--phase=", phase_of_stage(step$stage)),
                  common, patch, mode)))
  }

  if (identical(step$kind, "patch")) {
    f56 <- if (step$stage == 3L && !is.null(opt$f56)) paste0("--f56=", opt$f56) else character(0)
    return(list(c(patch_generator_script(step$stage), common, f56)))
  }

  run_dir <- stage3_run_dir(pcfg)
  layout <- if (identical(opt$layout, "legacy")) "--layout=legacy" else character(0)
  list(
    c("messageix/R/createMatrix_MM.R",
      paste0("--run-dir=", run_dir), paste0("--out=", matrix_csv(pcfg, opt)), common, layout),
    c("messageix/R/add_woodfuel_to_matrix.R",
      paste0("--run-dir=", run_dir), paste0("--matrix=", matrix_csv(pcfg, opt)), common, layout)
  )
}

# ---- which phases run -------------------------------------------------------

# The phases a command line asked for, in pipeline order. No --phase means all
# of them.
selected_phases <- function(value, flag = "--phase") {
  phases <- phase_names()
  if (is.null(value) || isTRUE(value)) return(phases)
  wanted <- trimws(strsplit(as.character(value), ",", fixed = TRUE)[[1L]])
  wanted <- wanted[nzchar(wanted)]
  if (!length(wanted)) log_die(flag, " needs at least one phase name")
  unknown <- setdiff(wanted, phases)
  if (length(unknown)) {
    log_die(flag, "=", paste(unknown, collapse = ", "), " is not a phase. The phases, in order: ",
            paste(phases, collapse = ", "))
  }
  phases[phases %in% wanted]
}

# The phases to run even though they are already finished. Bare --force means
# every phase this command covers.
forced_phases <- function(value, selected) {
  if (is.null(value)) return(character(0))
  if (isTRUE(value)) return(selected)
  forced <- selected_phases(value, "--force")
  outside <- setdiff(forced, selected)
  if (length(outside)) {
    log_die("--force names ", paste(outside, collapse = ", "), ", which --phase=",
            paste(selected, collapse = ","), " leaves out of this run. A phase cannot be both ",
            "outside the run and run anyway; widen --phase or drop it from --force.")
  }
  forced
}

# The plan: one row per step, what state it is in, and whether it will run.
#
#   skipped   left out by --phase
#   done      already finished, so it is skipped
#   forced    named in --force, so it runs whether or not it is finished
#   pending   not finished, and part of this run: it runs
#   re-solve  the calibration run on disk was solved under settings this
#             experiment has since changed, so it is solved again
#
# The packing steps are planned here too, so that the pre-flight checks can see
# them, but they carry user = FALSE and stay out of the printed plan.
plan_steps <- function(steps, pcfg, opt) {
  names <- vapply(steps, `[[`, character(1), "name")
  user <- vapply(steps, function(s) isTRUE(s$user), logical(1))
  selected <- selected_phases(opt$phase)
  forced <- forced_phases(opt$force, selected)

  state <- character(length(steps))
  detail <- character(length(steps))
  complete <- logical(length(steps))
  for (i in seq_along(steps)) {
    status <- step_status(steps[[i]], pcfg, opt)
    detail[i] <- status$detail
    complete[i] <- isTRUE(status$complete)
  }

  for (i in which(user)) {
    state[i] <- if (!names[i] %in% selected) {
      "skipped"
    } else if (names[i] %in% forced) {
      "forced"
    } else if (complete[i]) {
      "done"
    } else if (identical(names[i], "calibrate") && identical(stage1_state(pcfg), "differs")) {
      "re-solve"
    } else {
      "pending"
    }
  }

  # A packing step runs when the phase that reads what it packs is going to run
  # and nothing is packed yet. Rebuilding beside an existing tarball would leave
  # the phase after it with two candidates and no way to choose.
  for (i in which(!user)) {
    consumer <- match(TRUE, vapply(steps, function(s) {
      identical(s$kind, "stage") && s$stage == steps[[i]]$stage
    }, logical(1)))
    consumer_runs <- state[consumer] %in% c("pending", "forced", "re-solve")
    state[i] <- if (complete[i]) "done" else if (consumer_runs) "pending" else "skipped"
  }

  tibble::tibble(step = names, user = user, state = state,
                 action = dplyr::if_else(state %in% c("pending", "forced", "re-solve"),
                                         "run", "skip"),
                 complete = complete, detail = detail)
}

# The plan as the reader sees it: the four phases. Packing is not in the table
# because nobody schedules it; what it is waiting on comes out as a warning.
print_phase_plan <- function(plan) {
  rows <- dplyr::filter(plan, user)
  log_step("CONFIG", sum(rows$action == "run"), " of ", nrow(rows), " phase(s) to run")
  .print_table(dplyr::select(rows, step, state, action, detail))
}

# ---- checks that run before anything else -----------------------------------

# Most experiments read the same input tarballs, and each is checked in turn, so
# the identical report would otherwise be printed once per experiment and bury
# everything else in the log. Each distinct set of tarball names is therefore
# narrated the first time it is seen and checked in silence after that. What the
# check finds is unaffected -- the caller is told about every experiment either way.
.TARBALLS_NARRATED <- new.env(parent = emptyenv())

.first_look_at_tarballs <- function(wanted) {
  key <- paste(sort(paste0(names(wanted), "=", unname(wanted))), collapse = "\n")
  if (!is.null(.TARBALLS_NARRATED[[key]])) return(FALSE)
  assign(key, TRUE, envir = .TARBALLS_NARRATED)
  TRUE
}

# Where MAgPIE would find each of the calibration run's input tarballs.
# Repository entries that are directories can be looked in; the rest are
# addresses on the network, which cannot be checked without reaching for it. A
# tarball that has already been unpacked into the model's input folder is
# recorded there by name and counts as present.
#
# Returns the problems that make the calibration run impossible. A tarball that
# is merely missing locally, where a repository to download from is named, is a
# warning rather than a problem: the run will fetch it.
input_tarball_problems <- function(pcfg) {
  wanted <- .stage_input(pcfg, 1L)
  narrate <- .first_look_at_tarballs(wanted)
  repos <- names(magpie_repositories(pcfg))
  dirs <- repos[!grepl("^[a-z][a-z0-9+.-]*://", repos)]
  remote <- setdiff(repos, dirs)

  info <- "input/info.txt"
  installed <- character(0)
  if (file.exists(info) && exists(".get_info", mode = "function")) {
    installed <- .get_info(info, "^Used data set:", ": ")
  }

  absent <- character(0)
  for (key in names(wanted)) {
    file <- wanted[[key]]
    found <- dirs[file.exists(file.path(dirs, file))]
    if (length(found)) {
      if (narrate) log_step("CHECK", key, " tarball ", file, " is in ", found[1L])
    } else if (file %in% installed) {
      if (narrate) log_step("CHECK", key, " tarball ", file, " is already unpacked into input/")
    } else {
      absent <- c(absent, paste0(key, " (", file, ")"))
    }
  }
  if (!length(absent)) return(character(0))

  if (length(remote)) {
    if (narrate) {
      log_warn("the calibrate phase will have to download ", length(absent),
               " input tarball(s): ", paste(absent, collapse = "; "),
               ". They are in no local repository directory and are not unpacked yet, so ",
               paste(remote, collapse = ", "), " has to be reachable and has to hold them.")
    }
    return(character(0))
  }
  paste0("the calibrate phase cannot reach ", length(absent), " input tarball(s): ",
         paste(absent, collapse = "; "),
         ". No repository directory holds them, none is unpacked into input/, and no repository ",
         "to download from is named. Put the tarballs in ", paste(dirs, collapse = " or "),
         ", or name a repository that has them (magpie_public_repo, or MAGPIE_MM_PUBLIC_REPO).")
}

# Whether the supplied GHG price file is the file this experiment needs, not just
# a file that exists. The check itself belongs to the step that packs the file,
# so it is borrowed from there rather than written twice: the generator is a
# command and a library both, and reading it defines validate_f56() without
# packing anything.
#
# What it looks at is the structure: the pollutants GAMS taxes, the order of the
# two sub-dimensions, one column per GHG price level this experiment sweeps,
# every model year, and no gaps. The prices in the file are not checked and
# cannot be -- a plausible trajectory under the right column name passes. A
# missing column is worth catching here: found while packing instead, it costs
# the two phases of cluster time that come before it, and one file has to satisfy
# every experiment, not only the first.
#
# Returned as text rather than raised, so that one run reports every problem it
# has at once.
f56_content_problems <- function(path, pcfg) {
  # Reading the file needs magclass. Where it is missing the file cannot be
  # judged at all, which is a limit of the check and not a verdict on the file;
  # the packing step will say the same thing when it gets there.
  if (!requireNamespace("magclass", quietly = TRUE)) {
    log_warn("magclass is not installed, so --f56=", path, " was checked for existence only. ",
             "Whether it carries the columns experiment '", pcfg$experiment,
             "' needs will not be known until the demand sweep's inputs are packed.")
    return(character(0))
  }
  if (!exists("validate_f56", mode = "function")) {
    source(patch_generator_script(3L))
  }
  outcome <- tryCatch({
    validate_f56(path, pcfg)
    character(0)
  }, error = function(e) sub("^>> FATAL: ", "", conditionMessage(e)))
  if (!length(outcome)) return(character(0))
  paste0("--f56=", path, " is not the GHG price file experiment '", pcfg$experiment, "' needs: ",
         sub("^--f56: ", "", outcome))
}

# Everything this run needs, checked before the first phase starts. Returns the
# problems as text; the caller decides whether they stop the run.
preflight <- function(steps, plan, pcfg, opt) {
  problems <- character(0)
  runs <- function(name) plan$action[plan$step == name] == "run"
  # Ready means the input will be there: the step runs earlier in this run, or
  # its output is already on disk -- including when the step itself was left out.
  ready <- function(name) runs(name) || plan$complete[plan$step == name]
  label <- function(name) Filter(function(s) identical(s$name, name), steps)[[1L]]$label

  # Each step reads what the step before it wrote, so a step that runs needs its
  # predecessor either finished already or running earlier in this same command.
  for (i in seq_along(steps)[-1L]) {
    if (plan$action[i] != "run" || ready(plan$step[i - 1L])) next
    problems <- c(problems, paste0(
      label(plan$step[i]), " is set to run but ", label(plan$step[i - 1L]),
      ", which produces what it reads, is neither finished nor part of this run (",
      plan$detail[i - 1L], "). Run it first, or widen --phase so that this command covers it."))
  }

  # A calibration run left out of this command, whose folder holds a run solved
  # under other settings, stops the packing step that reads it -- after the wait.
  if (!runs("calibrate") && identical(stage1_state(pcfg), "differs") && any(plan$action == "run")) {
    problems <- c(problems, paste0(
      "the calibrate phase is left out of this run, and the run in ", run_folder(pcfg, 1L),
      " was solved under other settings. Packing refuses to read it, so this experiment would ",
      "stop there. Let it calibrate again."))
  }

  # Nothing in this repository generates the GHG price trajectories, so the file
  # carrying them has to be supplied. Checking it now rather than when the demand
  # sweep's inputs are packed saves the two phases of cluster time in between.
  if (runs("pack_demand")) {
    if (is.null(opt$f56)) {
      problems <- c(problems, paste0(
        "the demand sweep needs --f56=PATH: f56_pollutant_prices.cs3, the file of GHG price ",
        "trajectories for this experiment, one column per GHG price level it sweeps. Nothing ",
        "in this repository generates it, and without it there are no prices to sweep. Ask ",
        "Di Sheng for the file; running Rscript ",
        patch_generator_script(3L), " on its own prints the full description of what it has ",
        "to contain."))
    } else if (!file.exists(opt$f56)) {
      problems <- c(problems, paste0("--f56=", opt$f56, " does not exist."))
    } else {
      problems <- c(problems, f56_content_problems(opt$f56, pcfg))
    }
  } else if (!is.null(opt$f56)) {
    log_warn("--f56=", opt$f56, " is not used by this run: nothing here packs the demand ",
             "sweep's inputs.")
  }

  # A phase picks its inputs by finding the one tarball named for this
  # experiment and phase. Two of them differ in content, so the phase cannot know
  # which is current and will refuse to start.
  for (step in steps) {
    if (!identical(step$kind, "stage") || step$stage == 1L || !runs(step$name)) next
    found <- discover_patch(pcfg, step$stage)
    packer <- steps[[match(TRUE, vapply(steps, function(s) {
      identical(s$kind, "patch") && s$stage == step$stage
    }, logical(1)))]]
    if (length(found) > 1L && !runs(packer$name)) {
      problems <- c(problems, paste0(
        "the ", step$name, " phase has ", length(found), " packed tarballs to choose from (",
        paste(found, collapse = ", "), "). They hold different inputs. Remove the stale one, or ",
        "run the phase on its own with --patch=NAME."))
    }
    # Packing content that changed leaves the old tarball beside the new one,
    # because the name carries a digest of the contents and nothing deletes
    # anything. This run would then reach the phase with two candidates and stop
    # -- after the wait for the phase before it. Cheaper to say so now, while
    # nothing has been submitted.
    if (length(found) >= 1L && runs(packer$name)) {
      problems <- c(problems, paste0(
        "this run would pack the ", step$name, " phase's inputs while ",
        paste(found, collapse = " and "), " is already in ", patch_repo_dir(pcfg),
        ". Packing changed content leaves both on disk and the phase then cannot tell which is ",
        "current. Remove ", paste(found, collapse = " and "), " first, or run the phase against ",
        "a named tarball: Rscript messageix/R/run_phase.R --phase=", step$name,
        " --experiment=", pcfg$experiment, " --patch=NAME."))
    }
    # Under --dry-run nothing is packed, so a tarball this run would have written
    # is not there when the phase asks for it, and the rehearsal stops part way.
    # --validate is the rehearsal that completes on a tree where nothing has been
    # built.
    if (isTRUE(opt[["dry-run"]]) && !length(found)) {
      problems <- c(problems, paste0(
        "--dry-run cannot reach the ", step$name, " phase: it assembles a real run config, which ",
        "names the packed inputs the phase reads, and none is in ", patch_repo_dir(pcfg),
        ". A rehearsal narrates the packing instead of doing it. Use --validate to check the ",
        "whole run on a tree where nothing has been built yet, or pack first: Rscript ",
        patch_generator_script(step$stage), " --experiment=", pcfg$experiment,
        if (step$stage == 3L) " --f56=PATH" else "", "."))
    }
  }

  if (runs("calibrate")) problems <- c(problems, input_tarball_problems(pcfg))

  problems
}

# ---- running a step ---------------------------------------------------------

# The R that is running this file, so that a phase runs under the same R as the
# pipeline rather than whatever a search path turns up first.
.rscript <- function() file.path(R.home("bin"), "Rscript")

# Run one command line as its own process. Its output goes straight to this
# one's, so a cluster log holds the whole pipeline in order. A failure stops
# everything after it: those phases would read a half-made artefact.
#
# `label` names what failed in the message -- a phase here, an experiment when
# a whole pipeline is being run.
#
#   stdout  TRUE returns the command's last output line. The packing scripts
#           write the name of the tarball they built there, which is how the
#           phase after one of them is told exactly which file to read. The
#           output is held until the command finishes and then printed, so the
#           log reads the same either way.
run_step_command <- function(args, label, stdout = FALSE) {
  quoted <- vapply(args, shQuote, character(1), USE.NAMES = FALSE)
  died <- function(status) {
    log_die(label, " failed: ", basename(args[1L]), " exited with status ", status,
            ". Its own output above says why. Nothing after it has been run; fix the cause ",
            "and start again -- finished phases are skipped.")
  }
  if (!isTRUE(stdout)) {
    status <- system2(.rscript(), quoted)
    if (!identical(as.integer(status), 0L)) died(status)
    return(invisible(TRUE))
  }
  out <- suppressWarnings(system2(.rscript(), quoted, stdout = TRUE))
  if (length(out)) cat(out, sep = "\n")
  utils::flush.console()
  status <- attr(out, "status")
  if (!is.null(status) && !identical(as.integer(status), 0L)) died(status)
  invisible(if (length(out)) trimws(out[length(out)]) else "")
}

# The tarball just packed, read from the last line the packing script printed --
# the name is what those scripts write there. It is checked against the naming
# contract before it is used: a script that ends by printing something else would
# otherwise send the phase after it looking for a file that does not exist, and
# the phase can find its own tarball perfectly well.
.patch_just_built <- function(line, pcfg, stage) {
  if (length(line) == 1L && nzchar(line) && grepl(.patch_pattern(pcfg, stage), line)) {
    log_step("CONFIG", "the ", phase_of_stage(stage),
             " phase will read what was just packed: ", line)
    return(line)
  }
  log_warn("packing the ", phase_of_stage(stage), " phase's inputs did not end by printing a ",
           "tarball name, so the phase will look for it by name instead. If a previous tarball ",
           "is still in ", patch_repo_dir(pcfg), ", the phase will stop rather than guess ",
           "between them.")
  NULL
}

# ---- running the whole pipeline ---------------------------------------------

# Run one experiment's phases in order, waiting for the cluster between them.
# Returns what became of each step, in plan order.
run_pipeline <- function(steps, plan, pcfg, opt) {
  outcomes <- rep("not reached", nrow(plan))
  rehearsal <- isTRUE(opt$validate) || isTRUE(opt[["dry-run"]])
  # Tarballs packed by this run, by phase token. A phase is handed the file just
  # packed for it rather than left to discover it.
  patches <- list()

  for (i in seq_len(nrow(plan))) {
    step <- steps[[i]]
    if (plan$action[i] != "run") {
      if (isTRUE(step$user)) {
        log_step("SKIP", plan$step[i], ": ",
                 if (identical(plan$state[i], "done")) paste0("already finished -- ", plan$detail[i])
                 else "not part of this run")
      }
      outcomes[i] <- if (identical(plan$state[i], "done")) "skipped, already finished" else "skipped"
      next
    }

    log_step(if (isTRUE(step$user)) "PHASE" else "PACK", plan$step[i], ": ", step$what)
    # Marked failed for as long as the step is in progress, so that the summary
    # printed on the way out of a stopped run names the step that stopped it.
    outcomes[i] <- "failed"
    # Packing and the reduce phase write artefacts, so a rehearsal shows their
    # command lines instead of running them. Run phases do run: they have
    # rehearsal modes of their own and assemble the real configs without
    # submitting.
    narrate_only <- rehearsal && !identical(step$kind, "stage")
    built <- identical(step$kind, "patch") && !narrate_only
    for (args in step_commands(step, pcfg, opt, patches)) {
      log_step("EXEC", "Rscript ", paste(args, collapse = " "))
      if (narrate_only) next
      last <- run_step_command(args, plan$step[i], stdout = built)
      if (built) patches[[stage_token(step$stage)]] <- .patch_just_built(last, pcfg, step$stage)
    }

    if (identical(step$kind, "stage") && !rehearsal) {
      wait_for_stage(pcfg, step$stage, poll_seconds = pcfg$poll_seconds,
                     timeout_hours = pcfg$timeout_hours, extra = step_extra_files(step))
    }

    outcomes[i] <- if (narrate_only) "narrated only" else if (isTRUE(opt$validate)) "config checked"
                   else if (isTRUE(opt[["dry-run"]])) "assembled, nothing submitted" else "run"
  }

  outcomes
}

# ---- leaving it running on the cluster --------------------------------------

# Where submitted job scripts and their logs go. Under output/ because that is
# the directory a MAgPIE checkout already treats as scratch, and one directory
# keeps a week of logs together.
JOB_DIR <- "output/messageix_jobs"

# Hours to ask SLURM for on top of the waiting: the packing, the matrix build,
# and the model's own start-up.
SUBMIT_MARGIN_HOURS <- 2L

# Submit a command to SLURM and return, so that the orchestration itself
# survives a closed laptop or a dropped connection. A pipeline waits out three
# phases of runs, and several experiments do that once each, so the process
# lives for days -- which is exactly the process a login node kills.
#
#   args        the command line to run, as arguments to Rscript, without --submit
#   pcfg        a resolved experiment, for the queue, the modules and the mail address
#   name        SLURM job name. Deliberately not the name MAgPIE's own runs carry:
#               the wait counts queued MAgPIE jobs, and a job answering to the
#               same name would count itself and never stop waiting.
#   stages      how many phases of runs this command will wait for, for the log line
#   wait_hours  the waiting those phases add up to, in hours: each phase counted
#               at the waiting time its own experiment allows. The caller sums it
#               per experiment, because two experiments in one command may allow
#               different waiting times.
submit_driver <- function(args, pcfg, name, stages, wait_hours) {
  if (!nzchar(Sys.which("sbatch"))) {
    log_die("--submit needs sbatch, and there is none on PATH. On a machine without a queue, ",
            "run it in the background instead: ",
            "nohup Rscript ", paste(args, collapse = " "), " > pipeline.log 2>&1 &")
  }
  hours <- as.integer(ceiling(as.numeric(wait_hours))) + SUBMIT_MARGIN_HOURS
  dir.create(JOB_DIR, recursive = TRUE, showWarnings = FALSE)
  script <- file.path(JOB_DIR, paste0(name, ".sh"))
  mail <- mail_user(pcfg)

  writeLines(c(
    "#!/bin/bash",
    paste0("#SBATCH --job-name=", name),
    paste0("#SBATCH --output=", file.path(JOB_DIR, paste0(name, "_%j.log"))),
    paste0("#SBATCH --qos=", run_qos(pcfg)),
    paste0("#SBATCH --time=", hours, ":00:00"),
    "#SBATCH --nodes=1",
    "#SBATCH --ntasks=1",
    # This job only starts other processes and waits for files to appear; the
    # runs it starts get their own jobs and their own resources.
    "#SBATCH --cpus-per-task=1",
    "#SBATCH --mem=8G",
    if (is.null(mail)) NULL else c(paste0("#SBATCH --mail-type=END,FAIL"),
                                   paste0("#SBATCH --mail-user=", mail)),
    "",
    "set -euo pipefail",
    "cd \"${SLURM_SUBMIT_DIR}\"",
    slurm_module_lines(pcfg),
    "",
    paste(c("Rscript", vapply(args, shQuote, character(1), USE.NAMES = FALSE)), collapse = " ")
  ), script)

  log_step("SUBMIT", "job script ", script, ", ", hours, " h limit (", stages,
           " phase(s) of runs, ", signif(as.numeric(wait_hours), 4), " h of waiting plus ",
           SUBMIT_MARGIN_HOURS, " h)")
  status <- system2("sbatch", shQuote(script))
  if (!identical(as.integer(status), 0L)) {
    log_die("sbatch refused ", script, " (status ", status, "). The script is left in place; ",
            "submit it by hand, or fix what it complains about and try again.")
  }
  log_step("DONE", "submitted; the log will be ", file.path(JOB_DIR, paste0(name, "_<jobid>.log")))
  invisible(TRUE)
}
