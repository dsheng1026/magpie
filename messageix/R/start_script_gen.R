# |  Auto-generated Peaks-cluster start scripts for MAgPIE's "projects" menu.
# |
# |  Gap this closes (spec B3, 2026-08-25 meeting, owner Dominik, due
# |  2026-09-01): MAgPIE's interactive start flow (`scripts/start/`, menu
# |  option 8 "projects") lists any script dropped into
# |  `scripts/start/projects/`, but the MAgPIE -> MESSAGEix pipeline has no
# |  step that writes one. A user who wants to submit a resolved experiment
# |  stage to the Peaks cluster the ordinary MAgPIE way has to hand-write a
# |  script first. This file writes that script instead, from the same `cfg`
# |  list `stage_cfg()` (messageix/R/utils_config.R) already builds for
# |  `start_run()` -- nothing here recomputes settings, it only serialises
# |  them.
# |
# |  The generated script bakes in every field of `cfg` as a literal R
# |  assignment rather than sourcing config/default.cfg and layering the
# |  experiment on top. That is deliberate: `config/default.cfg` and
# |  `messageix/R/world_levers.R` are both free to change after the script is
# |  written, and the point of a retained copy is that it still reproduces
# |  the exact run it was generated for.
# |
# |  Two copies are written, both from `write_project_start_script()`:
# |    1. `scripts/start/projects/<name>.R` -- so MAgPIE's own menu finds it.
# |    2. `messageix/generated/start_scripts/<name>.R` -- a retained copy for
# |       reproducibility, independent of what happens to copy 1.
# |
# |  IMPORTANT, found while building this file and not yet acted on: the spec
# |  for this item assumed `scripts/start/projects/` is git-ignored, "matching
# |  the existing MAgPIE wrapper convention". It is not -- `git ls-files
# |  scripts/start/projects` lists 44 tracked scripts, and `.gitignore` has no
# |  rule for that directory. Every script this generator drops into
# |  `scripts/start/projects/` will therefore show up as an untracked file in
# |  `git status`, and if it is ever `git add`-ed it becomes a permanent,
# |  run-specific commit. Whoever wires the integration hook below should
# |  decide (a) add a `.gitignore` rule for generated scripts specifically
# |  (e.g. a `mm_*.R` glob, so hand-written project scripts stay tracked), or
# |  (b) accept that copy 1 is scratch and rely only on the retained copy for
# |  reproducibility. This file takes no position and does not touch
# |  `.gitignore` -- that is a repo-wide decision for Dominik/team, not
# |  something a standalone generator should decide unilaterally.
# |
# |  Interface
# |    start_script_name(pcfg, stage, be, ghg)      -> chr(1); shared basename for both copies
# |    deparse_cfg_field(name, value)                -> chr; one or more "cfg$<name> <- ..." lines,
# |                                                      or a skip-comment when deparse() fails or
# |                                                      does not round-trip identical() to `value`
# |    render_start_script(cfg, pcfg, stage, be, ghg, qos, extra_header)
# |                                                   -> chr(1); full script text
# |    write_project_start_script(cfg, pcfg, stage, be, ghg, qos, label, overwrite, retain_dir)
# |                                                   -> list(project_script=, retained_copy=);
# |                                                      refuses (log_die) if either target file
# |                                                      already exists, unless overwrite = TRUE
# |
# |  Dependencies: base R only. Does not source utils_config.R/utils_paths.R
# |  itself (avoids re-defining functions those files own); callers pass in
# |  an already-resolved `pcfg` and `cfg` (e.g. from `resolve_config()` and
# |  `stage_cfg()`).

if (!exists("log_step", mode = "function")) source("messageix/R/utils_log.R")

# ---- naming -----------------------------------------------------------------

# Filesystem-safe basename (no extension) shared by both copies, so the
# retained copy and the menu copy can always be matched up by name alone.
# Deliberately independent of utils_paths.R's run_title()/run_folder() (this
# file must stand alone); callers that also have run_title() available may
# pass its value in as `label` for an exact match instead.
start_script_name <- function(pcfg, stage, be = NULL, ghg = NULL, label = NULL) {
  if (!is.null(label) && nzchar(label)) {
    token <- label
  } else {
    ident <- if (!is.null(pcfg$identifier) && nzchar(pcfg$identifier)) pcfg$identifier else "experiment"
    parts <- c(ident, paste0("stage", as.integer(stage)))
    if (!is.null(be))  parts <- c(parts, paste0("BE",  formatC(as.numeric(be),  width = 2, flag = "0")))
    if (!is.null(ghg)) parts <- c(parts, paste0("GHG", formatC(as.numeric(ghg), width = 4, flag = "0")))
    token <- paste(parts, collapse = "_")
  }
  token <- gsub("[^A-Za-z0-9_.-]", "_", token)
  paste0("mm_", token)
}

# ---- serialisation ------------------------------------------------------

# One field of `cfg`, deparsed into `cfg$<name> <- <literal>`, wrapped over
# several lines when long. Falls back to a skip-comment (rather than dying)
# for a field deparse cannot represent literally, or cannot represent
# losslessly -- e.g. a function or environment slipped into cfg by some
# upstream default, or an attribute-bearing value (matrix, factor, Date,
# data.frame, S3/S4 object) that would otherwise deparse to its bare data
# with the attributes silently dropped -- so one unserialisable or
# lossy field never blocks writing the rest of the script, and never
# writes a value quietly wrong instead of failing loud.
deparse_cfg_field <- function(name, value) {
  if (is.function(value) || is.environment(value)) {
    return(paste0("# skipped cfg$", name, ": ", class(value)[1], " is not serialisable, not set by this script"))
  }
  lit <- tryCatch(
    deparse(value, control = c("keepNA", "keepInteger", "niceNames", "showAttributes")),
    error = function(e) NA_character_
  )
  if (length(lit) == 1L && is.na(lit)) {
    return(paste0("# skipped cfg$", name, ": deparse() failed (", class(value)[1], "), not set by this script"))
  }
  # Round-trip check: the deparsed literal must eval back to something
  # identical() to the original, not merely to something that deparses
  # without error. config/default.cfg is upstream code free to change, and an
  # attribute-bearing field (matrix, factor, Date, data.frame, classed object)
  # is exactly how a silent, undetected loss could arrive.
  round_trip_ok <- tryCatch(
    identical(eval(parse(text = paste(lit, collapse = "\n"))), value),
    error = function(e) FALSE
  )
  if (!isTRUE(round_trip_ok)) {
    return(paste0("# skipped cfg$", name, ": deparse() did not round-trip (", class(value)[1], "), not set by this script"))
  }
  lit[1] <- paste0("cfg$", name, " <- ", lit[1])
  paste(lit, collapse = "\n")
}

# ---- rendering ------------------------------------------------------------

# Full script text. `qos` overrides cfg$qos when the caller wants to pin a
# Peaks QoS tier explicitly (standard|priority|standby, scripts/slurmStart.yml)
# rather than let start_run()'s own load-based heuristic choose one.
render_start_script <- function(cfg, pcfg, stage, be = NULL, ghg = NULL,
                                 qos = NULL, extra_header = NULL) {
  if (!is.null(qos)) cfg$qos <- qos

  desc <- paste0(
    "MESSAGEix pipeline, auto-generated -- experiment '",
    if (!is.null(pcfg$experiment)) pcfg$experiment else pcfg$identifier,
    "', stage ", as.integer(stage),
    if (!is.null(be))  paste0(", BE=", be)  else "",
    if (!is.null(ghg)) paste0(", GHG=", ghg) else ""
  )

  field_lines <- vapply(names(cfg), function(nm) deparse_cfg_field(nm, cfg[[nm]]), character(1))

  header <- c(
    "# |  (C) 2008-2025 Potsdam Institute for Climate Impact Research (PIK)",
    "# |  authors, and contributors see CITATION.cff file. This file is part",
    "# |  of MAgPIE and licensed under AGPL-3.0-or-later. Under Section 7 of",
    "# |  AGPL-3.0, you are granted additional permissions described in the",
    "# |  MAgPIE License Exception, version 1.0 (see LICENSE file).",
    "# |  Contact: magpie@pik-potsdam.de",
    "",
    "# ----------------------------------------------------------",
    paste0("# description: ", desc),
    "# ----------------------------------------------------------",
    "",
    "# Auto-generated by messageix/R/start_script_gen.R -- do not hand-edit.",
    paste0("# Generated: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z")),
    "# Regenerate from the pipeline (stage_cfg() + write_project_start_script())",
    "# instead of editing this file; every setting below is a literal value,",
    "# not a reference to config/default.cfg, so this script reproduces the",
    "# run it was written for even if repo defaults change later.",
    if (!is.null(extra_header)) paste0("# ", extra_header) else NULL,
    ""
  )

  body <- c(
    "library(lucode2)",
    "library(magclass)",
    "library(gms)",
    "",
    "# Load start_run(cfg) function which is needed to start MAgPIE runs",
    'source("scripts/start_functions.R")',
    "",
    "cfg <- list()",
    field_lines,
    "",
    "start_run(cfg)",
    ""
  )

  paste(c(header, body), collapse = "\n")
}

# ---- writing ----------------------------------------------------------------

# Writes both copies and returns their paths. `retain_dir` defaults to a new
# directory under messageix/ (not output/<identifier>/...) so this generator
# never creates a run's results folder ahead of start_run() itself -- MAgPIE's
# own folder-collision/renaming logic for output/ stays untouched.
#
# Refuses to overwrite either an existing project script or an existing
# retained copy unless `overwrite = TRUE`: `scripts/start/projects/` holds 44
# tracked, hand-written scripts (see this file's header), and a second
# generation for the same experiment/stage/be/ghg would otherwise silently
# replace either copy with no trace of the collision.
write_project_start_script <- function(cfg, pcfg, stage, be = NULL, ghg = NULL,
                                        qos = NULL, label = NULL, overwrite = FALSE,
                                        retain_dir = "messageix/generated/start_scripts") {
  name <- start_script_name(pcfg, stage, be = be, ghg = ghg, label = label)
  text <- render_start_script(cfg, pcfg, stage, be = be, ghg = ghg, qos = qos)

  project_dir <- file.path("scripts", "start", "projects")
  if (!dir.exists(project_dir)) log_die("write_project_start_script: ", project_dir, " not found -- run from the MAgPIE model root")
  project_script <- file.path(project_dir, paste0(name, ".R"))
  if (file.exists(project_script) && !overwrite) {
    log_die("write_project_start_script: ", project_script,
            " already exists -- pass overwrite = TRUE, or change the experiment identifier/stage/label so the name differs")
  }
  writeLines(text, project_script)

  if (!dir.exists(retain_dir)) dir.create(retain_dir, recursive = TRUE)
  retained_copy <- file.path(retain_dir, paste0(name, ".R"))
  if (file.exists(retained_copy) && !overwrite) {
    log_die("write_project_start_script: ", retained_copy,
            " already exists -- pass overwrite = TRUE, or change the experiment identifier/stage/label so the name differs")
  }
  writeLines(text, retained_copy)

  log_step("WRITE", "start script: ", project_script, " (retained copy: ", retained_copy, ")")
  list(project_script = project_script, retained_copy = retained_copy)
}
