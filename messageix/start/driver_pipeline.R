# |  The whole MAgPIE -> MESSAGEix pipeline in one command.
# |
# |  What it does. Six steps, in order, each one a fresh Rscript process running
# |  exactly the command a person would type to run that step alone:
# |
# |    stage1_tau     one MAgPIE run producing the reference land-use intensity
# |                   trajectory the rest of the pipeline rests on
# |    patch_step2    packs that trajectory into the inputs stage 2 reads
# |    stage2_price   the bioenergy price sweep: one run per price level
# |    patch_step3    packs the bioenergy demand the sweep realised, and the GHG
# |                   price trajectories, into the inputs stage 3 reads
# |    stage3_demand  the emulator training set: one run per bioenergy price and
# |                   GHG price pair
# |    matrix         turns that training set into the matrix MESSAGEix reads,
# |                   with woodfuel added
# |
# |  This file sequences those commands and nothing else. Every decision about
# |  what a step does stays in the step's own script, so running the pipeline and
# |  running one step by hand cannot drift apart.
# |
# |  Why it has to wait. MAgPIE hands its runs to the cluster and returns
# |  immediately, so a stage driver that has finished has only finished
# |  submitting. Between stages the pipeline therefore waits until every run the
# |  preset expects holds a solved result, narrating how many have landed. It
# |  stops early -- rather than waiting out the timeout -- when the queue reports
# |  no MAgPIE jobs left while runs are still missing, which means they died.
# |  After stage 3 it waits for one thing more: each run's results file, which
# |  the job writes after the solve and which the matrix step is built from.
# |
# |  Waiting out three stages of runs takes days, so --submit hands the whole
# |  command to the cluster as one job and returns.
# |
# |  What it skips. A step that is already finished is skipped: a stage when
# |  every run it expects has solved, a patch step when its tarball is on disk,
# |  the matrix step when its output CSV exists. Restarting after a failure
# |  therefore picks up where the failure was, and --force re-runs a step anyway.
# |
# |  What it checks before it starts. Everything the whole requested span needs,
# |  checked while it is still cheap: the preset resolves, each step's input
# |  either exists or is produced earlier in the same run, the GHG price file
# |  stage 3 needs is supplied and holds every column, pollutant and model year
# |  this narrative asks of it, no patch step is about to build a second tarball
# |  beside one already on disk, and stage 1's input tarballs are reachable. A
# |  missing GHG price column discovered after two stages have run is hours of
# |  cluster time spent for nothing. --list reports the same problems as
# |  warnings alongside the plan.
# |
# |  Usage, from the MAgPIE model root:
# |    Rscript messageix/start/driver_pipeline.R --f56=PATH        # the whole thing
# |    Rscript messageix/start/driver_pipeline.R --f56=PATH --submit   # as one cluster job
# |    Rscript messageix/start/driver_pipeline.R --list            # the step plan and what is finished
# |    Rscript messageix/start/driver_pipeline.R --from=stage2_price --until=stage3_demand
# |    Rscript messageix/start/driver_pipeline.R --force=matrix
# |
# |  Interface
# |    pipeline_steps()                    -> list; the six steps, in order
# |    step_extra_files(step)              -> chr; files a finished run must also hold
# |    step_status(step, pcfg, opt)        -> list(complete, detail); is it finished
# |    step_commands(step, pcfg, opt, patches) -> list of chr; the Rscript command lines
# |    plan_steps(steps, pcfg, opt)        -> data.frame(step, state, action, complete, detail)
# |    f56_content_problems(path, pcfg)    -> chr; what the GHG price file is missing
# |    preflight(steps, plan, pcfg, opt)   -> chr; the problems that stop the run
# |    run_step_command(args, label, stdout) -> invisible; one step as its own process
# |    submit_driver(args, pcfg, name, stages) -> invisible(TRUE); hand a driver to SLURM
# |    flags_through(opt, keys, switches)  -> chr; a command line passed on unchanged
# |    pipeline_main(argv)                 -> invisible; the whole command line
# |
# |  This file is both a command and a library: messageix/start/driver_ensemble.R,
# |  which runs a whole set of narratives, sources it for the step definitions and
# |  the plan rather than restating them, and then runs it as a command once per
# |  narrative.
# |
# |  Dependencies: the messageix/R/ layer and messageix/start/run_stage.R, for
# |  the naming contract, the solvedness contract and the patch-tarball lookup.
# |  The steps themselves bring their own.

source("messageix/start/run_stage.R")

# Where the matrix CSV goes when --matrix-dir is not given. The same directory
# the matrix wrapper writes into by default, so both entry points produce the
# same file rather than two copies under different names.
MATRIX_DIR_DEFAULT <- "output/emulator"

# ---- the six steps ----------------------------------------------------------

# The pipeline, in the order it runs. `kind` decides how a step is started and
# how "already finished" is judged; `stage` is the MAgPIE stage a step runs or
# prepares inputs for.
pipeline_steps <- function() {
  list(
    list(name = "stage1_tau", kind = "stage", stage = 1L,
         what = "the reference run whose land-use intensity trajectory the rest of the pipeline needs"),
    list(name = "patch_step2", kind = "patch", stage = 2L,
         what = "packs that trajectory into the inputs stage 2 reads"),
    list(name = "stage2_price", kind = "stage", stage = 2L,
         what = "the bioenergy price sweep"),
    list(name = "patch_step3", kind = "patch", stage = 3L,
         what = "packs the realised bioenergy demand and the GHG price trajectories into the inputs stage 3 reads"),
    list(name = "stage3_demand", kind = "stage", stage = 3L,
         what = "the emulator training set"),
    list(name = "matrix", kind = "matrix", stage = 3L,
         what = "builds the matrix MESSAGEix reads, woodfuel included")
  )
}

step_names <- function() vapply(pipeline_steps(), `[[`, character(1), "name")

# The driver that runs one MAgPIE stage.
stage_driver <- function(stage) {
  c("messageix/start/driver_step1_tau.R",
    "messageix/start/driver_step2_price.R",
    "messageix/start/driver_step3_demand.R")[.as_stage(stage)]
}

# The directory holding the stage-3 run folders: the matrix step reads all of
# them, so it is addressed one level above a single run.
stage3_run_dir <- function(pcfg) dirname(results_folder(pcfg, 3L))

# The matrix CSV the first matrix script writes, and the woodfuel-augmented CSV
# the second one derives from it. The second is the file MESSAGEix consumes and
# therefore the one that says whether the matrix step is finished.
matrix_csv <- function(pcfg, opt) {
  file.path(opt[["matrix-dir"]], paste0(pcfg$matrix_basename, ".csv"))
}
woodfuel_csv <- function(pcfg, opt) sub("\\.csv$", "_woodfuel.csv", matrix_csv(pcfg, opt))

# Files a finished run of this step must hold besides the solver output. Only
# the last stage has one: the matrix step reads each run's results file, and the
# job writes that after the solve. Waiting only for the solver output would end
# the wait minutes before the matrix step can read the runs.
step_extra_files <- function(step) {
  if (identical(step$kind, "stage") && step$stage == 3L) MIF_NAME else character(0)
}

# Is a step finished, and what is on disk to say so.
#
# A stage is finished when every run the preset expects has solved -- the same
# judgement the wait between stages makes. A patch step is finished when its
# content-hashed tarball is in the patch directory. The matrix step is finished
# when the woodfuel CSV exists.
#
# Stage 1 carries one more condition. Its run folder is shared across
# narratives, so a solved run there may belong to another one; the folder
# records the settings it was solved under, and a record that disagrees with
# this preset means the run is finished for somebody else and not for us.
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
                detail = if (!length(found)) "no tarball built yet" else paste(found, collapse = ", ")))
  }
  out <- woodfuel_csv(pcfg, opt)
  list(complete = file.exists(out),
       detail = paste0(out, if (file.exists(out)) " written" else " not written"))
}

# The command lines a step runs, as arguments to Rscript. A list, because the
# matrix step is two scripts: the matrix itself, then woodfuel added to it.
#
# Stage drivers are handed --validate or --dry-run so that a rehearsal of the
# pipeline rehearses the real config assembly. Patch and matrix steps write
# artefacts, so in those modes they are narrated and not run.
#
#   patches  patch tarballs built earlier in this same run, one entry per stage
#            token. A stage whose tarball was just built is told which file to
#            read rather than left to find it: a rebuild whose contents changed
#            leaves the previous tarball on disk beside the new one, and a stage
#            facing two of them cannot know which is current.
step_commands <- function(step, pcfg, opt, patches = list()) {
  common <- c(paste0("--preset=", opt$preset), paste0("--csv=", opt$csv))

  if (identical(step$kind, "stage")) {
    mode <- if (isTRUE(opt$validate)) "--validate" else if (isTRUE(opt[["dry-run"]])) "--dry-run" else character(0)
    built <- patches[[stage_token(step$stage)]]
    patch <- if (is.null(built)) character(0) else paste0("--patch=", built)
    return(list(c(stage_driver(step$stage), common, patch, mode)))
  }

  if (identical(step$kind, "patch")) {
    f56 <- if (step$stage == 3L && !is.null(opt$f56)) paste0("--f56=", opt$f56) else character(0)
    return(list(c(patch_generator(step$stage), common, f56)))
  }

  run_dir <- stage3_run_dir(pcfg)
  list(
    c("messageix/emulator/createMatrix_MM.R",
      paste0("--run-dir=", run_dir), paste0("--out=", matrix_csv(pcfg, opt)), common),
    c("messageix/emulator/add_woodfuel_to_matrix.R",
      paste0("--run-dir=", run_dir), paste0("--matrix=", matrix_csv(pcfg, opt)), common)
  )
}

# ---- which steps run --------------------------------------------------------

# Position of a named step, or a stop naming the steps that exist.
.step_index <- function(value, flag) {
  names <- step_names()
  hit <- match(trimws(value), names)
  if (is.na(hit)) {
    log_die(flag, "=", value, " is not a pipeline step. The steps, in order: ",
            paste(names, collapse = ", "))
  }
  hit
}

.step_indices <- function(value, flag) {
  if (is.null(value)) return(integer(0))
  parts <- trimws(strsplit(value, ",", fixed = TRUE)[[1L]])
  parts <- parts[nzchar(parts)]
  if (!length(parts)) log_die(flag, " needs at least one step name")
  vapply(parts, .step_index, integer(1), flag = flag, USE.NAMES = FALSE)
}

# The plan: one row per step, what state it is in, and whether it will run.
#
#   skipped   left out by --from, --until or --skip
#   done      already finished, so it is skipped
#   forced    named in --force, so it runs whether or not it is finished
#   pending   not finished, and in the requested span: it runs
#   re-solve  set by the ensemble driver alone, on a reference run that has
#             solved but under another narrative's settings: finished for
#             somebody else, so this narrative solves its own
plan_steps <- function(steps, pcfg, opt) {
  names <- vapply(steps, `[[`, character(1), "name")
  from <- if (is.null(opt$from)) 1L else .step_index(opt$from, "--from")
  until <- if (is.null(opt$until)) length(steps) else .step_index(opt$until, "--until")
  if (from > until) {
    log_die("--from=", names[from], " comes after --until=", names[until],
            " in the pipeline, so the span is empty. The steps run in this order: ",
            paste(names, collapse = ", "))
  }
  skip <- .step_indices(opt$skip, "--skip")
  force <- .step_indices(opt$force, "--force")
  both <- intersect(skip, force)
  if (length(both)) {
    log_die("--skip and --force both name ", paste(names[both], collapse = ", "),
            "; a step cannot be left out and run anyway")
  }
  # Forcing a step the span does not reach asks for two different things at
  # once, exactly as --skip and --force on one step do. Ignoring it silently is
  # how somebody waits out a stage to find the step they meant to re-run was
  # never in the plan.
  outside <- force[force < from | force > until]
  if (length(outside)) {
    log_die("--force names ", paste(names[outside], collapse = ", "),
            ", which --from=", names[from], " / --until=", names[until],
            " leaves out of this run. A step cannot be both outside the span and run anyway; ",
            "widen the span or drop it from --force.")
  }

  state <- character(length(steps))
  detail <- character(length(steps))
  complete <- logical(length(steps))
  for (i in seq_along(steps)) {
    status <- step_status(steps[[i]], pcfg, opt)
    detail[i] <- status$detail
    complete[i] <- isTRUE(status$complete)
    state[i] <- if (i < from || i > until || i %in% skip) {
      "skipped"
    } else if (i %in% force) {
      "forced"
    } else if (isTRUE(status$complete)) {
      "done"
    } else {
      "pending"
    }
  }

  data.frame(step = names, state = state,
             action = ifelse(state %in% c("pending", "forced"), "run", "skip"),
             complete = complete, detail = detail, stringsAsFactors = FALSE)
}

# The plan as the reader sees it. The `complete` column is machinery for the
# checks below, not news: the detail column already says what is on disk.
print_step_plan <- function(plan) {
  log_step("CONFIG", sum(plan$action == "run"), " of ", nrow(plan), " step(s) to run")
  .print_table(plan[, c("step", "state", "action", "detail")])
}

# ---- checks that run before anything else -----------------------------------

# Most narratives of one experiment read the same input tarballs, and the
# ensemble driver checks every narrative in turn, so the identical report would
# otherwise be printed once per narrative and bury everything else in the log.
# Each distinct set of tarball names is therefore narrated the first time it is
# seen and checked in silence after that. What the check finds is unaffected --
# the caller is told about every narrative either way.
.TARBALLS_NARRATED <- new.env(parent = emptyenv())

.first_look_at_tarballs <- function(wanted) {
  key <- paste(sort(paste0(names(wanted), "=", unname(wanted))), collapse = "\n")
  if (!is.null(.TARBALLS_NARRATED[[key]])) return(FALSE)
  assign(key, TRUE, envir = .TARBALLS_NARRATED)
  TRUE
}

# Where MAgPIE would find each of stage 1's input tarballs. Repository entries
# that are directories can be looked in; the rest are addresses on the network,
# which cannot be checked without reaching for it. A tarball that has already
# been unpacked into the model's input folder is recorded there by name and
# counts as present.
#
# Returns the problems that make stage 1 impossible. A tarball that is merely
# missing locally, where the preset names a repository to download from, is a
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
      log_warn("stage 1 will have to download ", length(absent), " input tarball(s): ",
               paste(absent, collapse = "; "), ". They are in no local repository directory ",
               "and are not unpacked yet, so ", paste(remote, collapse = ", "),
               " has to be reachable and has to hold them.")
    }
    return(character(0))
  }
  paste0("stage 1 cannot reach ", length(absent), " input tarball(s): ",
         paste(absent, collapse = "; "),
         ". No repository directory holds them, none is unpacked into input/, and the preset ",
         "names no repository to download from. Put the tarballs in ",
         paste(dirs, collapse = " or "), ", or name a repository that has them ",
         "(magpie_public_repo, or MAGPIE_MM_PUBLIC_REPO).")
}

# Whether the supplied GHG price file is the file this narrative needs, not just
# a file that exists. The check itself belongs to the step that packs the file,
# so it is borrowed from there rather than written twice: the generator is a
# command and a library both, and reading it defines validate_f56() without
# building anything.
#
# What it looks at: the pollutants GAMS taxes, the order of the two
# sub-dimensions, one column per GHG price level this narrative sweeps, every
# model year of the preset, and no gaps. A missing column is worth catching
# here: found at patch_step3 instead, it costs the two stages of cluster time
# that come before it, and in an experiment the file has to satisfy every
# narrative, not only the first.
#
# Returned as text rather than raised, so that one run reports every problem it
# has at once.
f56_content_problems <- function(path, pcfg) {
  # Reading the file needs magclass. Where it is missing the file cannot be
  # judged at all, which is a limit of the check and not a verdict on the file;
  # patch_step3 will say the same thing when it gets there.
  if (!requireNamespace("magclass", quietly = TRUE)) {
    log_warn("magclass is not installed, so --f56=", path, " was checked for existence only. ",
             "Whether it carries the columns preset '", pcfg$preset,
             "' needs will not be known until patch_step3 runs.")
    return(character(0))
  }
  if (!exists("validate_f56", mode = "function")) {
    source(patch_generator(3L))
  }
  outcome <- tryCatch({
    validate_f56(path, pcfg)
    character(0)
  }, error = function(e) sub("^>> FATAL: ", "", conditionMessage(e)))
  if (!length(outcome)) return(character(0))
  paste0("--f56=", path, " is not the GHG price file preset '", pcfg$preset, "' needs: ",
         sub("^--f56: ", "", outcome))
}

# Everything the requested span needs, checked before the first step starts.
# Returns the problems as text; the caller decides whether they stop the run.
preflight <- function(steps, plan, pcfg, opt) {
  problems <- character(0)
  runs <- function(name) plan$action[plan$step == name] == "run"
  # Ready means the input will be there: the step runs earlier in this span, or
  # its output is already on disk -- including when the step itself was left out.
  ready <- function(name) runs(name) || plan$complete[plan$step == name]

  # Each step reads what the step before it wrote, so a step that runs needs its
  # predecessor either finished already or running earlier in this same span.
  for (i in seq_along(steps)[-1L]) {
    if (plan$action[i] != "run" || ready(plan$step[i - 1L])) next
    problems <- c(problems, paste0(
      plan$step[i], " is set to run but ", plan$step[i - 1L],
      ", which produces what it reads, is neither finished nor part of this run (",
      plan$detail[i - 1L], "). Run it first, or drop --from/--skip so that this run covers it."))
  }

  # Nothing in this repository generates the GHG price trajectories, so the file
  # carrying them has to be supplied. Checking it now rather than when stage 3's
  # patch tarball is built saves the two stages of cluster time in between.
  if (runs("patch_step3")) {
    if (is.null(opt$f56)) {
      problems <- c(problems, paste0(
        "patch_step3 needs --f56=PATH: the file of GHG price trajectories for this narrative. ",
        "Nothing in this repository generates it, and without it stage 3 has no prices to sweep. ",
        "Ask Di Sheng for the file; running patch_step3 on its own prints the full description ",
        "of what it has to contain."))
    } else if (!file.exists(opt$f56)) {
      problems <- c(problems, paste0("--f56=", opt$f56, " does not exist."))
    } else {
      problems <- c(problems, f56_content_problems(opt$f56, pcfg))
    }
  } else if (!is.null(opt$f56)) {
    log_warn("--f56=", opt$f56, " is not used by this run: patch_step3 is not among the steps to run.")
  }

  # A stage picks its inputs by finding the one tarball its preset and stage
  # name. Two of them differ in content, so the stage cannot know which is
  # current and will refuse to start.
  for (step in steps) {
    if (!identical(step$kind, "stage") || step$stage == 1L || !runs(step$name)) next
    found <- discover_patch(pcfg, step$stage)
    generator <- steps[[match(TRUE, vapply(steps, function(s) {
      identical(s$kind, "patch") && s$stage == step$stage
    }, logical(1)))]]
    if (length(found) > 1L && !runs(generator$name)) {
      problems <- c(problems, paste0(
        step$name, " has ", length(found), " patch tarballs to choose from (",
        paste(found, collapse = ", "), "). They hold different inputs. Remove the stale one, ",
        "or run this stage on its own with --patch=NAME."))
    }
    # Rebuilding a tarball whose contents changed leaves the old one beside the
    # new one, because the name carries a digest of the contents and neither
    # generator deletes anything. This run would then reach the stage with two
    # candidates and stop -- after the wait for the stage before it. Cheaper to
    # say so now, while nothing has been submitted.
    if (length(found) >= 1L && runs(generator$name)) {
      problems <- c(problems, paste0(
        generator$name, " is set to run while ", paste(found, collapse = " and "),
        " is already in ", patch_repo_dir(pcfg), ". A rebuild whose contents differ leaves both ",
        "on disk and ", step$name, " then cannot tell which is current. Remove ",
        paste(found, collapse = " and "), " first, or run ", step$name,
        " against a named tarball with --patch=NAME and leave ", generator$name, " out."))
    }
    # Under --dry-run the generators are narrated rather than run, so a tarball
    # that this run would have built is not there when the stage driver asks for
    # it, and the rehearsal stops part way. --validate is the rehearsal that
    # completes on a tree where nothing has been built.
    if (isTRUE(opt[["dry-run"]]) && !length(found)) {
      problems <- c(problems, paste0(
        "--dry-run cannot reach ", step$name, ": it assembles a real run config, which names the ",
        "patch tarball this stage reads, and none is in ", patch_repo_dir(pcfg),
        ". ", generator$name, " would build it, but a rehearsal narrates the generators instead of ",
        "running them. Use --validate to check the whole span on a tree where nothing has been ",
        "built yet, or build the tarball first: Rscript ", patch_generator(step$stage),
        " --preset=", pcfg$preset, if (step$stage == 3L) " --f56=PATH" else "", "."))
    }
  }

  if (runs("stage1_tau")) problems <- c(problems, input_tarball_problems(pcfg))

  problems
}

# ---- running a step ---------------------------------------------------------

# The R that is running this file, so that a step runs under the same R as the
# pipeline rather than whatever a search path turns up first.
.rscript <- function() file.path(R.home("bin"), "Rscript")

# Run one command line as its own process. Its output goes straight to this
# one's, so a cluster log holds the whole pipeline in order. A failure stops
# everything after it: those steps would read a half-made artefact.
#
# `label` names what failed in the message -- a step here, a narrative when the
# ensemble driver uses this to run a whole pipeline.
#
#   stdout  TRUE returns the command's last output line. The patch generators
#           write the name of the tarball they built there, which is how the
#           stage after one of them is told exactly which file to read. The
#           output is held until the command finishes and then printed, so the
#           log reads the same either way.
run_step_command <- function(args, label, stdout = FALSE) {
  quoted <- vapply(args, shQuote, character(1), USE.NAMES = FALSE)
  died <- function(status) {
    log_die(label, " failed: ", basename(args[1L]), " exited with status ", status,
            ". Its own output above says why. Nothing after it has been run; fix the cause ",
            "and start again -- finished steps are skipped.")
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

# The tarball a generator has just built, read from the last line it printed --
# the name is what these scripts write there. It is checked against the naming
# contract before it is used: a generator that ends by printing something else
# would otherwise send the stage after it looking for a file that does not
# exist, and the stage can find its own tarball perfectly well.
.patch_just_built <- function(line, pcfg, stage) {
  if (length(line) == 1L && nzchar(line) && grepl(.patch_pattern(pcfg, stage), line)) {
    log_step("CONFIG", "stage ", .as_stage(stage), " will read the tarball just built: ", line)
    return(line)
  }
  log_warn("the ", stage_token(stage), " patch generator did not end by printing a tarball name, ",
           "so stage ", .as_stage(stage), " will look for its tarball by name instead. ",
           "If a previous tarball is still in ", patch_repo_dir(pcfg),
           ", the stage will stop rather than guess between them.")
  NULL
}

# ---- leaving it running on the cluster --------------------------------------

# Where submitted job scripts and their logs go. Under output/ because that is
# the directory a MAgPIE checkout already treats as scratch, and one directory
# keeps a week of experiment logs together.
JOB_DIR <- "output/messageix_jobs"

# Hours to ask SLURM for: the wait limit once per stage that will be waited on,
# plus two hours for everything that is not waiting -- the patch steps, the
# matrix build, and the model's own start-up.
SUBMIT_MARGIN_HOURS <- 2L

# Submit a driver to SLURM and return, so that the orchestration itself survives
# a closed laptop or a dropped connection. A pipeline waits out three stages of
# runs, and an experiment does that once per narrative, so the process lives for
# days -- which is exactly the process a login node kills.
#
#   args    the command line to run, as arguments to Rscript, without --submit
#   pcfg    resolved preset, for the queue, the modules and the mail address
#   name    SLURM job name. Deliberately not the name MAgPIE's own runs carry:
#           the wait counts queued MAgPIE jobs, and an orchestrator job answering
#           to the same name would count itself and never stop waiting.
#   stages  how many stages this run will wait for, which is what its time limit
#           is made of
submit_driver <- function(args, pcfg, name, stages) {
  if (!nzchar(Sys.which("sbatch"))) {
    log_die("--submit needs sbatch, and there is none on PATH. On a machine without a queue, ",
            "run the driver in the background instead: ",
            "nohup Rscript ", paste(args, collapse = " "), " > pipeline.log 2>&1 &")
  }
  hours <- as.integer(max(stages, 1L) * as.numeric(pcfg$timeout_hours)) + SUBMIT_MARGIN_HOURS
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
    # The orchestrator only starts other processes and waits for files to
    # appear; the runs it starts get their own jobs and their own resources.
    "#SBATCH --cpus-per-task=1",
    "#SBATCH --mem=4G",
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
           " stage(s) at ", pcfg$timeout_hours, " h plus ", SUBMIT_MARGIN_HOURS, " h)")
  status <- system2("sbatch", shQuote(script))
  if (!identical(as.integer(status), 0L)) {
    log_die("sbatch refused ", script, " (status ", status, "). The script is left in place; ",
            "submit it by hand, or fix what it complains about and try again.")
  }
  log_step("DONE", "submitted; the log will be ", file.path(JOB_DIR, paste0(name, "_<jobid>.log")))
  invisible(TRUE)
}

# The flags a driver passes on to the copy of itself it submits: everything the
# command line carried except --submit, which has already been acted on.
flags_through <- function(opt, keys, switches) {
  args <- character(0)
  for (key in keys) {
    if (!is.null(opt[[key]])) args <- c(args, paste0("--", key, "=", opt[[key]]))
  }
  # paste0() over an empty selection returns "--" rather than nothing, so the
  # empty case is handled rather than pasted.
  set <- switches[vapply(switches, function(s) isTRUE(opt[[s]]), logical(1))]
  c(args, if (length(set)) paste0("--", set) else character(0))
}

pipeline_flags_through <- function(opt) {
  flags_through(opt, c("preset", "csv", "f56", "matrix-dir", "from", "until", "skip", "force"),
                c("validate", "dry-run"))
}

# ---- command line -----------------------------------------------------------

.synopsis_pipeline <- paste(
  "usage: Rscript messageix/start/driver_pipeline.R [--preset=NAME] [--csv=PATH]",
  "[--f56=PATH] [--matrix-dir=DIR] [--from=STEP] [--until=STEP] [--skip=STEP[,STEP]]",
  "[--force=STEP[,STEP]] [--submit] [--list] [--validate] [--dry-run] [--help]")

.usage_pipeline <- c(
  "Run the MAgPIE -> MESSAGEix pipeline end to end: six steps in order, waiting for the",
  "cluster between them, skipping whatever is already finished.",
  "",
  "  Rscript messageix/start/driver_pipeline.R [flags]   (from the MAgPIE model root)",
  "",
  "The steps, in order:",
  "  stage1_tau      the reference run whose land-use intensity trajectory the rest needs",
  "  patch_step2     packs that trajectory into the inputs stage 2 reads",
  "  stage2_price    the bioenergy price sweep",
  "  patch_step3     packs the realised bioenergy demand and the GHG price trajectories",
  "  stage3_demand   the emulator training set",
  "  matrix          builds the matrix MESSAGEix reads, woodfuel included",
  "",
  "Each step is run as the command a person would type to run it alone; those commands",
  "stay the interface for running, debugging or re-running any single step.",
  "",
  "Flags:",
  "  --preset=NAME       narrative column of the narratives file (default: default)",
  paste0("  --csv=PATH          narratives file (default: ", default_preset_csv(), ")"),
  "  --f56=PATH          the GHG price trajectories for this narrative. Required whenever",
  "                      patch_step3 runs, and checked before any step starts.",
  paste0("  --matrix-dir=DIR    where the matrix CSV is written (default: ", MATRIX_DIR_DEFAULT, ")"),
  "  --from=STEP         start at this step",
  "  --until=STEP        stop after this step",
  "  --skip=STEP[,STEP]  leave these steps out",
  "  --force=STEP[,STEP] run these steps even though they are already finished",
  "  --submit            hand this whole command to SLURM as one job and return, so the",
  "                      waiting survives a closed laptop. The job script and its log are",
  paste0("                      written to ", JOB_DIR, "."),
  "  --list              print the step plan, what is already finished and anything that",
  "                      would stop the run, then stop",
  "  --validate          check the whole span and print each stage's assembled config, then stop",
  "  --dry-run           narrate every command and assemble the run configs; submit nothing.",
  "                      It needs each stage's patch tarball to be on disk already, because",
  "                      it assembles a real run config; --validate is the rehearsal for a",
  "                      tree where nothing has been built yet.",
  "  --help              this text",
  "",
  "Every option is accepted as --key=value and as --key value.",
  "",
  "A finished step is skipped: a stage when every run it expects has solved, a patch step",
  "when its tarball is on disk, the matrix step when its output CSV exists. --force runs one",
  "anyway, and naming a step --from/--until leaves out is an error rather than a no-op.",
  "Waiting between stages is governed by poll_seconds and timeout_hours in",
  "the preset; stage 3 is waited on until each run has written its report.mif as well as its",
  "solver output, because that file is what the matrix step reads.",
  "",
  "A step that fails stops the run. Nothing after it is started, the summary table names it,",
  "and starting again picks up where it stopped.")

parse_pipeline_args <- function(argv) {
  opt <- parse_flags(argv,
                     known   = c("preset", "csv", "f56", "matrix-dir",
                                 "from", "until", "skip", "force"),
                     flags   = c("submit", "list", "validate", "dry-run", "help"),
                     aliases = c("preset-csv" = "csv"),
                     usage   = .synopsis_pipeline)
  if (is.null(opt$preset)) opt$preset <- "default"
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

# What became of each step, for the table printed at the end.
print_pipeline_summary <- function(plan, outcomes) {
  log_step("DONE", "pipeline finished")
  .print_table(data.frame(step = plan$step, planned = plan$state, outcome = outcomes,
                          stringsAsFactors = FALSE))
}

pipeline_main <- function(argv = commandArgs(trailingOnly = TRUE)) {
  opt <- parse_pipeline_args(argv)
  if (isTRUE(opt$help)) {
    cat(.usage_pipeline, sep = "\n")
    cat("\n")
    return(invisible(TRUE))
  }

  pcfg <- resolve_config(preset = opt$preset, csv = opt$csv)
  steps <- pipeline_steps()
  plan <- plan_steps(steps, pcfg, opt)

  log_banner("magpie -> messageix pipeline", list(
    narrative = pcfg$preset, csv = opt$csv, identifier = pcfg$identifier,
    runs = paste0(nrow(expected_run_folders(pcfg, 2L)), " price + ",
                  nrow(expected_run_folders(pcfg, 3L)), " demand"),
    matrix = woodfuel_csv(pcfg, opt),
    waiting = paste0("every ", pcfg$poll_seconds, " s, up to ", pcfg$timeout_hours, " h per stage")))

  print_step_plan(plan)

  # --list reports readiness as well as the plan: what is finished and what
  # would stop the run are the same question asked twice, and the answer is
  # cheapest before anything has been submitted.
  problems <- preflight(steps, plan, pcfg, opt)
  if (length(problems)) {
    # Under --list and --validate the point is to see everything that is not
    # ready, so the problems are reported rather than raised. A real run stops
    # on the lot at once: fixing them one stop at a time is what wastes the
    # cluster time these checks exist to save.
    if (isTRUE(opt$list) || isTRUE(opt$validate)) {
      for (problem in problems) log_warn(problem)
    } else {
      log_die("the pipeline cannot run as asked:\n  - ", paste(problems, collapse = "\n  - "))
    }
  }
  if (isTRUE(opt$list)) return(invisible(plan))

  if (isTRUE(opt$submit)) {
    return(invisible(submit_driver(c("messageix/start/driver_pipeline.R",
                                     pipeline_flags_through(opt)),
                                   pcfg = pcfg,
                                   name = paste0("mm_pipe_", pcfg$preset),
                                   stages = sum(plan$action == "run" &
                                                vapply(steps, `[[`, character(1), "kind") == "stage"))))
  }

  outcomes <- rep("not reached", nrow(plan))
  on.exit(print_pipeline_summary(plan, outcomes), add = TRUE)
  rehearsal <- isTRUE(opt$validate) || isTRUE(opt[["dry-run"]])
  # Patch tarballs built by this run, by stage token. A stage is handed the file
  # the generator before it just wrote rather than left to discover it.
  patches <- list()

  for (i in seq_len(nrow(plan))) {
    step <- steps[[i]]
    if (plan$action[i] != "run") {
      log_step("SKIP", plan$step[i], ": ",
               if (identical(plan$state[i], "done")) paste0("already finished -- ", plan$detail[i])
               else "not part of this run")
      outcomes[i] <- if (identical(plan$state[i], "done")) "skipped, already finished" else "skipped"
      next
    }

    log_step("STEP", plan$step[i], ": ", step$what)
    # Marked failed for as long as the step is in progress, so that the summary
    # printed on the way out of a stopped run names the step that stopped it.
    outcomes[i] <- "failed"
    # Patch and matrix steps write artefacts, so a rehearsal shows their command
    # lines instead of running them. Stage drivers do run: they have rehearsal
    # modes of their own and assemble the real configs without submitting.
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

  invisible(TRUE)
}

# Only when this file is the command being run. driver_ensemble.R sources it for
# the step definitions and the plan, and must not set a pipeline going by doing so.
if (invoked_directly("driver_pipeline.R")) pipeline_main()
