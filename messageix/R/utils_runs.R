# |  What the pipeline asserts about a finished MAgPIE run.
# |
# |  Two contracts that four scripts have to agree on, so both are defined here
# |  once and nowhere else.
# |
# |  Solvedness. A run counts as solved when every time step reports a GAMS model
# |  status in SOLVED_MODELSTAT. Existence of fulldata.gdx says nothing: an
# |  infeasible run writes one too. The patch generators and the matrix builders
# |  judge the same class of artefact, so they judge it by the same set.
# |
# |  The calibration record. An experiment's calibration run is found by name,
# |  and a re-run is allowed to overwrite a folder of its own name. So a folder
# |  can hold a trajectory solved under settings the experiment has since changed --
# |  the technological-change cost, the yield scenario, the model horizon, the
# |  stage-1 protection scenario, the stage-1 bioenergy demand path or the input
# |  tarballs -- and nothing in the folder's name would say so.
# |
# |  The record makes that checkable: the calibrate phase writes down the
# |  settings it ran under, and packing refuses to take the trajectory out of a
# |  run whose record disagrees with the experiment it was asked for. A stale
# |  trajectory becomes an error instead of a silent one.
# |
# |  Waiting. MAgPIE hands its runs to the cluster and returns at once, so a
# |  stage driver that has "finished" has only finished submitting. The pipeline
# |  driver therefore waits between stages, and a stage counts as finished when
# |  every run folder the experiment expects holds a solved fulldata.gdx -- the same
# |  solvedness contract, applied to a whole set of runs instead of one.
# |
# |  One MAgPIE job does two things in sequence: it solves, writing fulldata.gdx,
# |  and then it reports, writing report.mif out of that gdx. A run that has
# |  solved is therefore not yet a run the reduce phase can read, and reporting a
# |  gigabyte of results takes minutes. Waits and completeness checks accordingly
# |  take a list of extra files a finished run must also hold, and the demand
# |  sweep asks for report.mif.
# |
# |  Interface
# |    SOLVED_MODELSTAT                        num; GAMS model statuses that count as solved
# |    run_modelstat(gdx)                      -> num; per-timestep statuses, numeric(0) if unreadable
# |    assert_run_solved(gdx, label)           -> invisible(TRUE); stops on anything else
# |    RUN_GDX_FILE                            chr(1); the solver output in a run folder
# |    MIF_NAME                                chr(1); the results file the reporting writes
# |    run_solved(folder, extra)               -> lgl(1); one finished, solved, reported run
# |    stage_progress(pcfg, stage, extra)      -> data.frame; expected runs plus a solved column
# |    assert_runs_solved(runs, where, ...)    -> invisible(TRUE); a whole run set, reported at once
# |    queued_magpie_jobs()                    -> int(1) or NA; MAgPIE jobs in the SLURM queue
# |    wait_for_stage(pcfg, stage, poll_seconds, timeout_hours, extra) -> invisible(TRUE)
# |    STAGE1_FINGERPRINT_FILE                 chr(1); its file name inside the run folder
# |    stage1_fingerprint(pcfg)                -> chr; sorted "key=value" lines
# |    write_stage1_fingerprint(pcfg, folder)  -> invisible(chr(1)); the path written
# |    stage1_state(pcfg)                      -> chr(1); absent|unrecorded|matches|differs
# |    assert_stage1_fingerprint(pcfg, folder) -> invisible(TRUE)
# |
# |  Dependencies: base R, dplyr/purrr, messageix/R/utils_config.R, and -- at call time only,
# |  so that the CLIs still parse without them -- magpie4 and gdx2.

if (!exists("log_die", mode = "function"))        source("messageix/R/utils_log.R")
if (!exists("stage_gms_keys", mode = "function")) source("messageix/R/utils_config.R")

# ---- solvedness -------------------------------------------------------------

# GAMS records how each time step's solve ended. 1 means a proven optimum, 2 a
# local optimum, 7 a feasible answer with no proof of optimality. All three are
# results a person would use, so all three count as solved here. One set for the
# whole pipeline: a run good enough to go into the emulator matrix must not be
# refused when a patch tarball is built from it, or the other way round.
SOLVED_MODELSTAT <- c(1, 2, 7)

# Solve status of one run, as the vector of per-timestep GAMS model statuses.
# Returns numeric(0) when the gdx carries no status symbol, which is a limit of
# the check rather than a failed run -- callers report those separately.
run_modelstat <- function(gdx_path) {
  status <- try(magpie4::modelstat(gdx_path), silent = TRUE)
  if (inherits(status, "try-error")) {
    status <- gdx2::readGDX(gdx_path, "p80_modelstat", "o_modelstat",
                            format = "first_found", react = "silent")
  }
  if (is.null(status) || !length(status)) return(numeric(0))
  as.numeric(status)
}

# The strict form, for the steps that produce an artefact from one named run:
# an unreadable status is a failure there, because nothing downstream will look
# at that run again.
assert_run_solved <- function(gdx, label = gdx) {
  status <- run_modelstat(gdx)
  if (!length(status)) {
    log_die(label, ": cannot read a model status from ", gdx,
            " -- the run did not finish, the file is truncated, or it carries no modelstat symbol")
  }
  bad <- sort(unique(status[!status %in% SOLVED_MODELSTAT]))
  if (length(bad)) {
    log_die(label, ": modelstat ", bad, " in ", gdx, "; every time step must be one of ",
            SOLVED_MODELSTAT, " (optimal, locally optimal, feasible)")
  }
  invisible(TRUE)
}

# ---- the stage-1 fingerprint ------------------------------------------------

STAGE1_FINGERPRINT_FILE <- "messageix_stage1_fingerprint.txt"

# One value as the fingerprint writes it: no scientific notation, so that 1e6
# and 1000000 do not read as two different settings.
.fingerprint_value <- function(x) {
  if (is.null(x) || !length(x)) return("<unset>")
  paste(format(x, trim = TRUE, scientific = FALSE), collapse = ",")
}

# Every setting the calibration run depends on, as sorted "key=value" lines.
# The gms$ entries are taken from stage_gms_keys(pcfg, 1) rather than listed, so
# a switch an experiment adds is covered without touching this function.
stage1_fingerprint <- function(pcfg) {
  gms_keys <- stage_gms_keys(pcfg, 1L)
  entries <- c(
    stats::setNames(
      vapply(gms_keys, function(key) .fingerprint_value(pcfg$gms[[key]]), character(1)),
      paste0("gms$", gms_keys)),
    c(`ssp`                    = .fingerprint_value(pcfg$ssp),
      `protect_scenario_step1` = .fingerprint_value(pcfg$protect_scenario_step1),
      `biodem_scenario_step1`  = .fingerprint_value(pcfg$biodem_scenario_step1),
      `input_regional`         = .fingerprint_value(pcfg$input_regional),
      `input_cellular`         = .fingerprint_value(pcfg$input_cellular),
      `input_validation`       = .fingerprint_value(pcfg$input_validation),
      `input_additional`       = .fingerprint_value(pcfg$input_additional),
      `input_calibration`      = .fingerprint_value(pcfg$input_calibration)))
  sort(paste0(names(entries), "=", unname(entries)))
}

write_stage1_fingerprint <- function(pcfg, folder) {
  path <- file.path(folder, STAGE1_FINGERPRINT_FILE)
  writeLines(stage1_fingerprint(pcfg), path)
  invisible(path)
}

# What the calibration run folder of this experiment currently holds:
#
#   absent      no folder yet; the experiment calibrates its own
#   unrecorded  a run is there but does not say which settings it was solved
#               under, so it cannot be checked -- it predates the record, or was
#               copied in from elsewhere
#   matches     a run solved under this experiment's settings; it is used as is
#   differs     a run solved under other settings; this experiment cannot use it
#               and has to calibrate again
#
# The plan asks this before calling the calibrate phase finished, and packing
# asks it before reading the run. Both have to reach the same verdict, so both
# ask here.
stage1_state <- function(pcfg) {
  folder <- run_folder(pcfg, 1L)
  if (!dir.exists(folder)) return("absent")
  record <- file.path(folder, STAGE1_FINGERPRINT_FILE)
  if (!file.exists(record)) return("unrecorded")
  found <- readLines(record, warn = FALSE)
  found <- found[nzchar(trimws(found))]
  if (identical(found, stage1_fingerprint(pcfg))) "matches" else "differs"
}

# The value of one key in a fingerprint, or "<absent>" when the key is not in it
# -- an experiment that gained a gms switch since the run was made.
.fingerprint_lookup <- function(lines, key) {
  hit <- lines[startsWith(lines, paste0(key, "="))]
  if (!length(hit)) "<absent>" else sub("^[^=]*=", "", hit[1L])
}

# Refuse to pack a trajectory solved under other settings. A missing record is a
# warning, not a failure: a run made before the record
# existed, or one copied in from elsewhere, may well be the right one -- but
# nobody can check it here, so the person running the pipeline has to.
assert_stage1_fingerprint <- function(pcfg, folder) {
  path <- file.path(folder, STAGE1_FINGERPRINT_FILE)
  if (!file.exists(path)) {
    log_warn(folder, " carries no ", STAGE1_FINGERPRINT_FILE,
             ", so the settings this trajectory was solved under cannot be checked against ",
             "experiment '", pcfg$experiment, "'. Run the calibrate phase again to make the ",
             "check possible, or confirm by hand that the settings match.")
    return(invisible(TRUE))
  }
  found <- readLines(path, warn = FALSE)
  found <- found[nzchar(trimws(found))]
  wanted <- stage1_fingerprint(pcfg)
  if (identical(found, wanted)) return(invisible(TRUE))

  keys <- sort(union(sub("=.*$", "", found), sub("=.*$", "", wanted)))
  differing <- vapply(keys, function(key) {
    ran <- .fingerprint_lookup(found, key)
    asked <- .fingerprint_lookup(wanted, key)
    if (identical(ran, asked)) NA_character_ else {
      paste0("    ", key, ": the run used '", ran, "', experiment '", pcfg$experiment,
             "' asks for '", asked, "'")
    }
  }, character(1))
  differing <- differing[!is.na(differing)]

  # Reported rather than raised: R cuts a stop() message off after about a
  # thousand characters, and with several settings differing the instruction at
  # the end is the first thing to be lost.
  log_report(c(
    paste0(">> FATAL: the calibration run in ", folder, " was solved under different settings:"),
    differing,
    paste0("  Its trajectory is therefore not the one experiment '", pcfg$experiment,
           "' asks for. The folder is addressed by name, so a run made before one of these ",
           "settings changed is still sitting in it."),
    paste0("  Calibrate again for this experiment first: Rscript messageix/run.R ",
           pcfg$experiment, " --phase=calibrate --force")))
  log_die("the calibration run in ", folder, " was solved for other settings; the settings that ",
          "differ, and the command that fixes it, are printed in full above")
}

# ---- waiting for a stage to finish ------------------------------------------

# The file MAgPIE writes into a run folder when the run has been through the
# solver. It is the artefact every solvedness check reads.
RUN_GDX_FILE <- "fulldata.gdx"

# The results file a run writes once it has solved: every reported variable, in
# the IAMC format the reduce phase reads. It appears later than the solver
# output, because the job reports only after the solve has finished.
MIF_NAME <- "report.mif"

# The SLURM job name every MAgPIE run is submitted under, whichever queue it
# goes to. It says that a job is a MAgPIE run; it does not say which run, so a
# count of these jobs answers "is anything still going" and nothing finer.
MAGPIE_JOB_NAME <- "mag-run"

# TRUE when one run folder holds a finished run that solved. A missing gdx means
# the run has not finished yet, which is not an error: a stage is waited on
# exactly while some of its folders are still empty. Reading the model status
# needs magpie4 or gdx2, and the file-existence test comes first so that a
# machine without those packages can still ask about a grid that has not run.
#
#   extra  files the run folder must hold besides the solver output. Pass
#          MIF_NAME where the step after this one reads the results file: the
#          job writes it after the solve, so a run can be solved and not yet
#          readable.
run_solved <- function(folder, extra = character(0)) {
  gdx <- file.path(folder, RUN_GDX_FILE)
  if (!file.exists(gdx)) return(FALSE)
  if (length(extra) && !all(file.exists(file.path(folder, extra)))) return(FALSE)
  status <- run_modelstat(gdx)
  length(status) > 0L && all(status %in% SOLVED_MODELSTAT)
}

# The runs a phase is expected to produce, each marked solved or not.
# Columns: be, ghg, title, folder, solved. `extra` is passed to run_solved().
stage_progress <- function(pcfg, stage, extra = character(0)) {
  expected_run_folders(pcfg, stage) |>
    dplyr::mutate(solved = purrr::map_lgl(folder, run_solved, extra = extra))
}

# Check a whole set of runs before any of them is read, and stop with one report
# naming every unusable run. Being told about them one at a time turns a single
# resubmission into a series of them, and half a set is worse than none: a patch
# built from six of seven runs, or a matrix built from 80 of 84, is
# indistinguishable downstream from a complete one.
#
#   runs     data.frame with title and folder columns
#   where    the directory the runs are expected under, named in the report
#   extra    files each run folder must hold besides the solver output; the
#            reduce phase also needs each run's report.mif
#   strict   what to do about a run whose solve status cannot be read at all.
#            TRUE stops -- the steps that build one artefact out of named runs
#            cannot afford to include a run they cannot judge. FALSE warns and
#            carries on, checking those runs for existence only.
#   closing  the sentence that ends the report, saying what was not written
assert_runs_solved <- function(runs, where, extra = character(0),
                               strict = FALSE, closing = "Nothing was written.") {
  no_folder <- character(0)
  no_extra  <- list()
  no_gdx    <- character(0)
  unsolved  <- character(0)   # titles
  bad_state <- character(0)   # the same titles with the model status shown
  unreadable <- character(0)

  for (i in seq_len(nrow(runs))) {
    folder <- runs$folder[i]
    title  <- runs$title[i]
    if (!dir.exists(folder)) {
      no_folder <- c(no_folder, title)
      next
    }
    for (file in extra) {
      if (!file.exists(file.path(folder, file))) no_extra[[file]] <- c(no_extra[[file]], title)
    }
    gdx <- file.path(folder, RUN_GDX_FILE)
    if (!file.exists(gdx)) {
      no_gdx <- c(no_gdx, title)
      next
    }
    status <- run_modelstat(gdx)
    if (!length(status)) {
      unreadable <- c(unreadable, title)
    } else if (!all(status %in% SOLVED_MODELSTAT)) {
      unsolved <- c(unsolved, title)
      bad_state <- c(bad_state, paste0(title, " (modelstat ",
                                       paste(sort(unique(setdiff(status, SOLVED_MODELSTAT))),
                                             collapse = "/"), ")"))
    }
  }

  broken <- c(no_folder, unlist(no_extra, use.names = FALSE), no_gdx, unsolved,
              if (strict) unreadable)
  if (length(broken)) {
    block <- function(label, titles) {
      if (!length(titles)) return(NULL)
      paste0("  ", label, " (", length(titles), "):\n    ", paste(titles, collapse = "\n    "))
    }
    log_report(c(
      paste0(nrow(runs), " run(s) expected under ", where, "; the set is incomplete."),
      block("no run folder", no_folder),
      unlist(lapply(names(no_extra), function(f) block(paste0("no ", f), no_extra[[f]])),
             use.names = FALSE),
      block(paste0("no ", RUN_GDX_FILE), no_gdx),
      block("did not solve", bad_state),
      if (strict) block(paste0("no model status in ", RUN_GDX_FILE), unreadable),
      closing))
    log_die(length(unique(broken)), " of ", nrow(runs),
            " run(s) are unusable; every one of them is listed above")
  }

  if (length(unreadable)) {
    log_warn("the solve status of ", length(unreadable), " run(s) cannot be read: ", RUN_GDX_FILE,
             " is there but carries no model status, so those runs are checked for existence ",
             "only:\n    ", paste(unreadable, collapse = "\n    "))
  }
  invisible(TRUE)
}

# How many MAgPIE runs this user has sitting in the SLURM queue, or NA where
# there is no queue to ask -- a laptop, or a cluster login without squeue. NA
# means "cannot tell", and a caller must read it as "possibly still running"
# rather than as zero.
queued_magpie_jobs <- function() {
  if (!nzchar(Sys.which("squeue"))) return(NA_integer_)
  user <- Sys.getenv("USER", unset = Sys.info()[["user"]])
  if (!nzchar(user)) return(NA_integer_)
  out <- suppressWarnings(try(
    system2("squeue", c("-h", "-u", shQuote(user), "-o", shQuote("%j")),
            stdout = TRUE, stderr = FALSE),
    silent = TRUE))
  if (inherits(out, "try-error") || !is.null(attr(out, "status"))) return(NA_integer_)
  sum(trimws(out) == MAGPIE_JOB_NAME)
}

# Which runs of a phase are still unsolved, as a report to put in front of the
# reader when the wait ends badly. Long grids are truncated: 84 folder names
# bury the sentence that says what went wrong.
.unfinished_report <- function(folders, solved, stage, reason, show = 10L,
                               extra = character(0)) {
  bad <- folders[!solved]
  shown <- utils::head(bad, show)
  paste0("stage ", stage, ": ", reason, ". ", length(bad), " of ", length(folders),
         " run(s) hold no solved ", RUN_GDX_FILE,
         if (length(extra)) paste0(" with ", paste(extra, collapse = " and ")) else "",
         ":\n  ",
         paste(shown, collapse = "\n  "),
         if (length(bad) > show) paste0("\n  ... and ", length(bad) - show, " more"),
         "\n  Each run folder holds the log of its own job; read one of those to find out ",
         "whether the run failed, was cancelled, or ran out of time.")
}

# Wait until every run of a phase has solved, narrating progress as it goes.
#
#   poll_seconds   seconds between checks. Each check reads the model status out
#                  of every gdx that has appeared, so checking the demand grid is
#                  not free; runs take hours, and a five-minute cadence resolves
#                  them finely enough.
#   timeout_hours  hours to wait before giving up.
#   extra          files a finished run must also hold. The wait ends when the
#                  step after this one can actually read the runs, which for the
#                  reduce phase means each run's results file and not only its
#                  solver output -- a job writes the two minutes apart.
#
# Three ways out. Every run solved: return. The queue reports no MAgPIE jobs on
# two checks in a row while folders are still missing: the runs died, and
# waiting 48 hours to be told that helps nobody. The timeout expires: stop with
# the same report. Two consecutive empty checks rather than one, because a job
# that has just been handed to sbatch takes a moment to appear in the queue.
wait_for_stage <- function(pcfg, stage, poll_seconds = 300, timeout_hours = 48,
                           extra = character(0)) {
  stage <- .as_stage(stage)
  runs <- expected_run_folders(pcfg, stage)
  total <- nrow(runs)
  # Solvedness never goes back to FALSE, so a run once seen solved is not read
  # again -- otherwise every check would re-read the whole grid.
  solved <- rep(FALSE, total)
  deadline <- Sys.time() + timeout_hours * 3600
  empty_queue <- 0L

  repeat {
    solved[!solved] <- vapply(runs$folder[!solved], run_solved, logical(1),
                              extra = extra, USE.NAMES = FALSE)
    if (all(solved)) {
      log_step("DONE", "stage ", stage, ": all ", total, " run(s) solved",
               if (length(extra)) paste0(" and reported (", paste(extra, collapse = ", "), ")") else "")
      return(invisible(TRUE))
    }

    queued <- queued_magpie_jobs()
    empty_queue <- if (!is.na(queued) && queued == 0L) empty_queue + 1L else 0L
    if (empty_queue >= 2L) {
      log_die(.unfinished_report(runs$folder, solved, stage,
                                 "no MAgPIE jobs are left in the queue but runs are still missing",
                                 extra = extra))
    }
    if (Sys.time() > deadline) {
      log_die(.unfinished_report(runs$folder, solved, stage,
                                 paste0("still unfinished after the ", timeout_hours,
                                        " hour limit"),
                                 extra = extra))
    }

    log_step("WAIT", "stage ", stage, ": ", sum(solved), " of ", total, " run(s) solved",
             if (is.na(queued)) "" else paste0(", ", queued, " MAgPIE job(s) in the queue"),
             "; next check in ", poll_seconds, " s")
    Sys.sleep(poll_seconds)
  }
}
