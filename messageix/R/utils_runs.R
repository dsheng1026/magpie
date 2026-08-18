# |  What the pipeline asserts about a finished MAgPIE run.
# |
# |  Two contracts that four scripts have to agree on, so both are defined here
# |  once and nowhere else.
# |
# |  SOLVEDNESS. A run counts as solved when every time step reports a GAMS model
# |  status in SOLVED_MODELSTAT. Existence of fulldata.gdx says nothing: an
# |  infeasible run writes one too. The patch generators and the matrix builders
# |  judge the same class of artefact, so they judge it by the same set.
# |
# |  THE STAGE-1 FINGERPRINT. The stage-1 run title is "<ssp>_tau" and its folder
# |  sits one level above the narrative folders, because the reference tau is
# |  reusable across narratives. It is reusable exactly when the narratives agree
# |  on every stage-1-relevant setting, and several of those are preset-driven:
# |  c13_tccost, c14_yields_scenario and c_timesteps reach stage 1 through the
# |  preset's gms$ rows, and the step-1 protection scenario, the step-1 bioenergy
# |  demand path and the input tarball names through its pipeline$ rows. Two
# |  presets differing in any of them write to the same folder, and
# |  cfg$force_replace is TRUE by default, so the second overwrites the first
# |  in silence.
# |
# |  The fingerprint is that reuse condition written down and made checkable:
# |  stage 1 records the settings it ran under, and the step-1.5 generator
# |  refuses to extract tau from a run whose record disagrees with the preset it
# |  was invoked with. The run folder names stay as they are -- they are part of
# |  the golden-master artefact -- and the collision becomes an error instead of
# |  a silent swap.
# |
# |  Interface
# |    SOLVED_MODELSTAT                        num; GAMS model statuses that count as solved
# |    run_modelstat(gdx)                      -> num; per-timestep statuses, numeric(0) if unreadable
# |    assert_run_solved(gdx, label)           -> invisible(TRUE); stops on anything else
# |    STAGE1_FINGERPRINT_FILE                 chr(1); its file name inside the run folder
# |    stage1_fingerprint(pcfg)                -> chr; sorted "key=value" lines
# |    write_stage1_fingerprint(pcfg, folder)  -> invisible(chr(1)); the path written
# |    assert_stage1_fingerprint(pcfg, folder) -> invisible(TRUE)
# |
# |  Dependencies: base R, messageix/R/utils_config.R, and -- at call time only,
# |  so that the CLIs still parse without them -- magpie4 and gdx2.

if (!exists("log_die", mode = "function"))        source("messageix/R/utils_log.R")
if (!exists("stage_gms_keys", mode = "function")) source("messageix/R/utils_config.R")

# ---- solvedness -------------------------------------------------------------

# 1 optimal, 2 locally optimal, 7 feasible without a proof of optimality.
# MAgPIE's own calibration check accepts these three
# (scripts/calibration/calc_calib.R:85); scripts/output/extra/highres.R:48 is
# stricter and drops 1. The looser set is the right one here because a run that
# reached a proven optimum is not a failure, and the pipeline must not accept a
# run for the matrix that it would refuse for the patch.
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

# Every stage-1-relevant preset-driven setting, as sorted "key=value" lines.
# The gms$ rows are taken from stage_gms_keys(pcfg, 1) rather than listed, so a
# switch added to a preset is covered without touching this function.
stage1_fingerprint <- function(pcfg) {
  gms_keys <- stage_gms_keys(pcfg, 1L)
  entries <- c(
    stats::setNames(
      vapply(gms_keys, function(key) .fingerprint_value(pcfg$gms[[key]]), character(1)),
      paste0("gms$", gms_keys)),
    c(`pipeline$ssp`                    = .fingerprint_value(pcfg$ssp),
      `pipeline$protect_scenario_step1` = .fingerprint_value(pcfg$protect_scenario_step1),
      `pipeline$biodem_scenario_step1`  = .fingerprint_value(pcfg$biodem_scenario_step1),
      `pipeline$input_regional`         = .fingerprint_value(pcfg$input_regional),
      `pipeline$input_cellular`         = .fingerprint_value(pcfg$input_cellular),
      `pipeline$input_validation`       = .fingerprint_value(pcfg$input_validation),
      `pipeline$input_additional`       = .fingerprint_value(pcfg$input_additional),
      `pipeline$input_calibration`      = .fingerprint_value(pcfg$input_calibration)))
  sort(paste0(names(entries), "=", unname(entries)))
}

write_stage1_fingerprint <- function(pcfg, folder) {
  path <- file.path(folder, STAGE1_FINGERPRINT_FILE)
  writeLines(stage1_fingerprint(pcfg), path)
  invisible(path)
}

# The value of one key in a fingerprint, or "<absent>" when the key is not in it
# -- a preset that gained a gms$ row since the run was made.
.fingerprint_lookup <- function(lines, key) {
  hit <- lines[startsWith(lines, paste0(key, "="))]
  if (!length(hit)) "<absent>" else sub("^[^=]*=", "", hit[1L])
}

# Refuse to reuse a stage-1 run that another preset produced. Absence of the
# file is a warning, not a failure: a run made before the fingerprint existed,
# or one copied in from elsewhere, is still usable -- the reader just has to
# confirm the settings themselves.
assert_stage1_fingerprint <- function(pcfg, folder) {
  path <- file.path(folder, STAGE1_FINGERPRINT_FILE)
  if (!file.exists(path)) {
    log_warn(folder, " carries no ", STAGE1_FINGERPRINT_FILE,
             ", so the settings this reference tau was solved under cannot be checked against ",
             "preset '", pcfg$preset, "'. Re-run stage 1 for this preset to make the check ",
             "possible, or confirm by hand that the stage-1 settings match.")
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
      paste0("    ", key, ": the run used '", ran, "', preset '", pcfg$preset, "' asks for '", asked, "'")
    }
  }, character(1))
  differing <- differing[!is.na(differing)]

  log_die("the stage-1 run in ", folder, " was solved under different settings:\n",
          paste(differing, collapse = "\n"),
          "\n  Its tau is therefore not this preset's reference tau. The stage-1 run folder is ",
          "shared across narratives (title '", run_title(pcfg, 1L),
          "'), so a later stage-1 run of another preset overwrote it. Re-run stage 1 for this ",
          "preset first: Rscript messageix/start/driver_step1_tau.R --preset=", pcfg$preset)
}
