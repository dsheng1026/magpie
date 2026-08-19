# |  What an experiment is, and how one becomes a MAgPIE run configuration.
# |
# |  An experiment has two halves, and both are written in R:
# |
# |    narrative()  the world the runs are made in -- which shared socioeconomic
# |                 pathway, which world regions, how strictly biodiversity is
# |                 protected, how costly yield improvements are. Everything that
# |                 would still be true if the sampling grid were finer.
# |    design()     the sampling plan -- which bioenergy price levels the price
# |                 sweep visits, and which GHG price levels the demand sweep
# |                 visits. Everything that decides how many runs there are.
# |
# |  experiment(narrative(), design()) puts the two together, and the experiments
# |  themselves live in messageix/experiments.R, which is the one file a
# |  researcher edits to add or change an experiment. Both constructors take
# |  overrides only: whatever is not named keeps the default declared here, so an
# |  experiment reads as the short list of what makes it different.
# |
# |  Which of the three owners a setting belongs to -- the experiment,
# |  infrastructure, or derived and settable by nobody -- is stated once, in the
# |  header of messageix/R/world_levers.R. The derived ones are worked out here.
# |
# |  Settings flow one way: experiments.R -> resolve_config() -> pcfg ->
# |  stage_cfg(). pcfg is validated once and then read-only; the single legal
# |  mutation is with_patch(), which records the tarball a generator just produced.
# |
# |  Every setting is documented where it is declared: the levers of the world in
# |  messageix/R/world_levers.R, the sampling plan in design_spec() below, and the
# |  infrastructure settings in messageix/R/pipeline_infrastructure.R.
# |
# |  The golden runs. "Golden runs" is the set of runs behind the reference
# |  matrix magpie_input_SSP2_ref_woodfuel.csv, the artefact this pipeline has to
# |  reproduce before it can be trusted with anything new. The `default`
# |  experiment plus the stage logic below reproduce them exactly, including three
# |  asymmetries that look like oversights and are not:
# |
# |    1. Stage 1 runs c22_protect_scenario = "BH" while stages 2 and 3 run
# |       "none". The reference land-use intensity trajectory is calibrated under
# |       land protection and then applied exogenously without it.
# |    2. Stage 1 runs c44_bii_decrease = 0 while stages 2 and 3 run 1, and
# |       leaves s30_annual_max_growth, s44_cost_bii_missing, s60_* and every
# |       c56_* switch at their MAgPIE defaults. It is a reference run, not a
# |       member of the training set.
# |    3. The non-CO2 GHG price cap applies in stage 3 only. Stage 1 runs under a
# |       near-term-policy price path with MAgPIE's default cap of 4920
# |       USD17MER/tC; capping it there would move the land-use intensity
# |       trajectory the whole pipeline rests on. Stage 2 runs at zero GHG price,
# |       where the cap is inert.
# |
# |  Any change to these three lines changes the science. They are code, not
# |  narrative settings, so a new experiment cannot disturb them by accident.
# |
# |  Interface
# |    data_dir()                        -> chr(1); the folder holding the region-name tables
# |    experiments_file()                   -> chr(1); the file the experiments are declared in
# |    read_pipeline_csv(path, what)        -> data.frame of characters; the CSV convention
# |    parse_flags(argv, known, flags, ...) -> named list; the shared CLI flag parser
# |    cli_overrides(sets)                  -> named list, from repeated "--set key=value"
# |    invoked_directly(basename)           -> lgl(1); TRUE when Rscript was given this file
# |    config_from_flags(flags, overrides)  -> pcfg; resolve_config() from parsed flags
# |    narrative(..., gms)                  -> mm_narrative; the world, as overrides
# |    design(...)                          -> mm_design; the sampling plan, as overrides
# |    experiment(narrative, design)        -> mm_experiment; the two together
# |    narrative_spec() / design_spec()     -> named list of list(default, type, unit)
# |    pipeline_defaults()                  -> named list; every settable key, typed default
# |    settable_keys()                      -> chr; narrative, design and infrastructure keys
# |    experiment_names(file)               -> chr; the experiments declared in that file
# |    resolve_config(experiment, overrides, file) -> pcfg, a validated list of class "mm_pcfg"
# |    with_patch(pcfg, stage, tarball)     -> pcfg; records a generated patch tarball name
# |    stage_gms_keys(pcfg, stage)          -> chr; gms switches applied at that stage
# |    stage_controlled_switches()          -> chr; gms switches stage_cfg owns
# |    pipeline_owned_switches()            -> chr; gms switches an experiment may not set
# |    stage_cfg(pcfg, stage, be, ghg)      -> list; a complete MAgPIE cfg for start_run()
# |
# |  Dependencies: base R, readr, gms (setScenario), and messageix/R/{utils_log,utils_paths,
# |  utils_env,pipeline_infrastructure}.R. Run from the MAgPIE model root.

if (!exists("log_die", mode = "function"))     source("messageix/R/utils_log.R")
if (!exists("run_title", mode = "function"))   source("messageix/R/utils_paths.R")
if (!exists("run_qos", mode = "function"))     source("messageix/R/utils_env.R")
if (!exists("region_sets", mode = "function")) source("messageix/R/pipeline_infrastructure.R")
if (!exists("world_levers", mode = "function")) source("messageix/R/world_levers.R")

# ---- where things live ------------------------------------------------------

# The folder holding the data tables the pipeline ships: the region-name table
# each region set refers to, and the variable mapping the matrix is built with.
data_dir <- function() "messageix/data"

# The file the experiments are declared in. Every entry point resolves an
# experiment through it, so the path is written once.
experiments_file <- function() "messageix/experiments.R"

# ---- reading a delimited table ----------------------------------------------

# Every CSV this pipeline reads follows one convention, applied here: a UTF-8
# byte-order mark is tolerated, "#" lines and blank lines are comments, and the
# delimiter is whichever of ";" and "," the header row uses. ";" is what
# European exports write. `what` names the file in any failure message.
#
# The comment and blank lines are dropped before readr sees the text, rather
# than through readr's own `comment = "#"`, which would also cut a "#" out of
# the middle of a value. Every column comes back as text: this reads tables of
# names and codes, and a region called "1" is not a number.
read_pipeline_csv <- function(path, what = "CSV") {
  if (!file.exists(path)) log_die(what, " not found: ", path)
  lines <- readLines(path, warn = FALSE, encoding = "UTF-8")
  # A byte-order mark survives readLines as either the U+FEFF character or its
  # three raw bytes, depending on the locale; strip both forms.
  lines[1L] <- sub("^\ufeff", "", lines[1L])
  lines[1L] <- sub("^\xef\xbb\xbf", "", lines[1L], useBytes = TRUE)
  lines <- lines[!startsWith(trimws(lines), "#") & nzchar(trimws(lines))]
  if (!length(lines)) log_die(what, " holds no data rows: ", path)
  delim <- if (grepl(";", lines[1L], fixed = TRUE)) ";" else ","
  readr::read_delim(I(paste(lines, collapse = "\n")),
                    delim = delim,
                    col_types = readr::cols(.default = readr::col_character()),
                    name_repair = "minimal",
                    trim_ws = TRUE,
                    progress = FALSE)
}

# ---- command line -----------------------------------------------------------

# Parse "--key=value" and "--key value" into a named list. Both spellings are
# accepted everywhere so that a command copied from one script's usage line
# works in another. This is the pipeline's only command-line parser.
#
#   known       options that take a value
#   flags       options that take none; they come back as TRUE
#   repeatable  options that may be given more than once; they come back as a
#               character vector of every value given, in the order given
#   optional    flags that may be given bare or with a value; bare comes back
#               as TRUE, with a value as that value
#   positional  TRUE lets arguments without a leading "--" through; they come
#               back under the name "positional" as a character vector, in order
#   aliases     named vector of accepted spelling -> canonical name, for an
#               option that has been renamed and whose old name must keep working
#   usage       appended to every failure message
#
# Two things stop the run rather than being ignored: an unknown option, because
# a mistyped one that fell through would build the wrong thing and say nothing,
# and a repeated option that is not declared repeatable, because silently taking
# the last of two conflicting values is how a sweep gets run at the wrong price.
# "-h" is accepted for "--help" wherever a --help flag is declared.
parse_flags <- function(argv, known, flags = character(0), repeatable = character(0),
                        optional = character(0), positional = FALSE,
                        aliases = character(0), usage = NULL) {
  fail <- function(...) log_die(..., if (is.null(usage)) "" else paste0("\n", usage))
  out <- list()
  free <- character(0)
  seen <- character(0)
  i <- 1L
  while (i <= length(argv)) {
    arg <- argv[i]
    if (identical(arg, "-h") && "help" %in% flags) arg <- "--help"
    if (!grepl("^--", arg)) {
      if (!positional) fail("unexpected argument '", arg, "'")
      free <- c(free, arg)
      i <- i + 1L
      next
    }
    name <- sub("^--", "", sub("=.*$", "", arg))
    inline <- grepl("=", arg, fixed = TRUE)
    if (name %in% names(aliases)) name <- unname(aliases[[name]])
    if (!name %in% c(known, flags, repeatable, optional)) fail("unknown option: --", name)
    if (name %in% seen && !name %in% repeatable) fail("--", name, " given more than once")
    seen <- c(seen, name)
    if (name %in% flags || (name %in% optional && !inline)) {
      if (inline && name %in% flags) fail("--", name, " takes no value")
      out[[name]] <- TRUE
      i <- i + 1L
    } else {
      if (inline) {
        value <- sub("^--[^=]*=", "", arg)
        if (!nzchar(value)) fail("option --", name, " needs a value")
        i <- i + 1L
      } else {
        if (i == length(argv)) fail("option --", name, " needs a value")
        value <- argv[i + 1L]
        i <- i + 2L
      }
      out[[name]] <- if (name %in% repeatable) c(out[[name]], value) else value
    }
  }
  if (positional) out[["positional"]] <- free
  out
}

# The repeatable "--set key=value" values as the named list resolve_config()
# takes. Values stay character: resolve_config coerces them to the type the key
# declares, so a vector given on a command line is comma-joined like any other.
cli_overrides <- function(sets) {
  if (!length(sets)) return(list())
  shapeless <- sets[!grepl("=", sets, fixed = TRUE)]
  if (length(shapeless)) log_die("--set takes key=value, got '", shapeless[1L], "'")
  keys <- sub("=.*$", "", sets)
  values <- sub("^[^=]+=", "", sets)
  if (any(!nzchar(keys))) log_die("--set: no key before the '=' in '", sets[!nzchar(keys)][1L], "'")
  stats::setNames(as.list(values), keys)
}

# TRUE when Rscript was handed this very file, FALSE when another script sourced
# it. It guards the command-line block at the foot of a script which is both a
# command and a library, so that sourcing it for its functions does not set it
# running.
invoked_directly <- function(basename_expected) {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- sub("^--file=", "", args[grepl("^--file=", args)])
  length(file_arg) == 1L && identical(basename(file_arg), basename_expected)
}

# The experiment a command line asked for, resolved. Every entry point defaults
# the same way -- the experiment named `default` -- and that default is decided
# here rather than in each of them.
config_from_flags <- function(flags, overrides = list()) {
  resolve_config(experiment = if (is.null(flags$experiment)) "default" else flags$experiment,
                 overrides  = overrides)
}

# ---- the settings an experiment varies --------------------------------------

# The world a narrative describes, in the shape the rest of this file wants it:
# one entry per lever, with its default, its type and what it means. The levers
# themselves are registered in messageix/R/world_levers.R, which is the only
# place they are listed -- a lever a narrative names but nothing registers is an
# error, because a silently ignored setting is worse than a stopped run.
narrative_spec <- function() {
  lapply(world_levers(), function(x) {
    list(default = x$default, type = x$type,
         unit = paste0(x$meaning, ". ", x$values))
  })
}

# The sampling plan: which price levels the two sweeps visit. It decides how
# many runs an experiment is made of -- one price run per bioenergy price level,
# one demand run per pair -- so it is the half to change when the question is
# "how finely is the response surface sampled", not "what world is it sampled in".
design_spec <- function() {
  list(
    prices_bioenergy = list(
      default = c(0, 5, 7, 10, 15, 25, 45), type = "num_vec",
      unit = "bioenergy price levels the price sweep visits, USD2005 per GJ. Chosen where land-use models change behaviour, with enough coverage around the turning points that interpolating between them lands on a sensible surface. Whole numbers only: each becomes a run name and a scenario column name (BE05)"),
    prices_ghg = list(
      default = c(0, 10, 20, 50, 100, 200, 400, 600, 1000, 2000, 3000, 4000), type = "num_vec",
      unit = "GHG price levels the demand sweep visits. Each is a label, not a price: it names one column of the supplied f56_pollutant_prices.cs3 file, and that file carries the trajectory the label stands for. Whole numbers only; they appear in run names (G0400) and scenario names (G0400exp2110)")
  )
}

# The declared type and meaning of any settable key: world, sampling plan or
# infrastructure.
settable_spec <- function() c(narrative_spec(), design_spec(), infrastructure_spec())

# Every key an experiment or a --set may carry.
settable_keys <- function() names(settable_spec())

# Named list of typed defaults, one entry per settable key. Infrastructure
# defaults arrive with their environment-variable overrides already applied.
pipeline_defaults <- function() {
  c(lapply(narrative_spec(), `[[`, "default"),
    lapply(design_spec(), `[[`, "default"),
    infrastructure_defaults())
}

# ---- the constructors -------------------------------------------------------

.empty_narrative <- function() {
  structure(list(pipeline = list(), gms = list()), class = c("mm_narrative", "list"))
}

.empty_design <- function() {
  structure(list(pipeline = list()), class = c("mm_design", "list"))
}

# The world an experiment is run in, as the settings that differ from the
# defaults above. Named arguments only, and only the narrative settings; a
# misspelled one stops here rather than being carried silently into 84 runs.
#
#   gms  a named list assigning MAgPIE switches this pipeline does not otherwise
#        expose, e.g. gms = list(food = "anthro_iso_jun22"). A switch the
#        pipeline already decides is refused, and the message names the setting
#        to use instead.
#
# Values are checked as they are written: the type each setting declares, and
# the range it has to lie in.
narrative <- function(..., gms = list()) {
  values <- .named_arguments(list(...), "narrative")
  spec <- narrative_spec()
  unknown <- setdiff(names(values), names(spec))
  if (length(unknown)) {
    log_die("narrative() was given ", paste(unknown, collapse = ", "),
            ", which is not a lever of the world. The levers registered in ",
            "messageix/R/world_levers.R are: ", paste(lever_names(), collapse = ", "),
            ". The price levels are the sampling plan, so they belong in design(); ",
            "everything operational is an infrastructure setting; and a lever the world ",
            "should have but does not is a new block in that registry, which is also ",
            "where each lever is documented.")
  }
  for (key in names(values)) {
    values[[key]] <- .coerce(values[[key]], spec[[key]]$type, key)
    .check_setting(key, values[[key]])
  }
  if (!is.list(gms) || (length(gms) && is.null(names(gms)))) {
    log_die("narrative(gms = ) takes a named list of MAgPIE switches, ",
            "e.g. gms = list(food = \"anthro_iso_jun22\")")
  }
  .refuse_owned_switches(names(gms), "narrative()")
  structure(list(pipeline = values, gms = lapply(gms, .coerce_gms)),
            class = c("mm_narrative", "list"))
}

# The sampling plan: which price levels the two sweeps visit. Whatever is not
# named keeps the grid the pipeline was tested on.
design <- function(...) {
  values <- .named_arguments(list(...), "design")
  spec <- design_spec()
  unknown <- setdiff(names(values), names(spec))
  if (length(unknown)) {
    log_die("design() was given ", paste(unknown, collapse = ", "),
            ", which is not part of the sampling plan. It takes: ",
            paste(names(spec), collapse = ", "),
            ". Everything about the world the runs are made in belongs in narrative().")
  }
  for (key in names(values)) {
    values[[key]] <- .coerce(values[[key]], spec[[key]]$type, key)
    .check_setting(key, values[[key]])
  }
  structure(list(pipeline = values), class = c("mm_design", "list"))
}

# One experiment: a world, and the plan for sampling it. Either half may be left
# out, in which case it is the default one.
experiment <- function(narrative = NULL, design = NULL) {
  if (is.null(narrative)) narrative <- .empty_narrative()
  if (is.null(design)) design <- .empty_design()
  if (!inherits(narrative, "mm_narrative")) {
    log_die("experiment() takes a narrative() first: experiment(narrative(bii_target = 0.78))")
  }
  if (!inherits(design, "mm_design")) {
    log_die("experiment() takes a design() second: ",
            "experiment(narrative(), design(prices_ghg = c(0, 100, 1000)))")
  }
  structure(list(narrative = narrative, design = design),
            class = c("mm_experiment", "list"))
}

# Every argument of a constructor has to be named: a bare value carries no
# indication of which setting it is meant to be.
.named_arguments <- function(values, what) {
  if (!length(values)) return(list())
  keys <- names(values)
  if (is.null(keys) || any(!nzchar(keys))) {
    log_die(what, "() takes named settings only, e.g. ", what,
            "(bii_target = 0.78); one argument was given without a name")
  }
  if (anyDuplicated(keys)) {
    log_die(what, "() was given ", paste(unique(keys[duplicated(keys)]), collapse = ", "),
            " more than once")
  }
  values
}

# ---- gms switches this pipeline owns ----------------------------------------

# Infrastructure settings that become a MAgPIE switch directly: the switch each
# one becomes, and the stages it applies at, in one entry each -- the same shape
# a lever's block gives the world's own switches. The world's switches are not
# here: they are declared with their levers in messageix/R/world_levers.R, and
# the two lists are put together by .gms_from_key() and .gms_stage_scope().
#
# `stages` is the stage numbers the switch is set at, written as digits. The two
# bioenergy ones are absent from the calibration run, which leaves them at
# MAgPIE's own defaults; a switch that applies everywhere carries "123".
.INFRASTRUCTURE_SWITCHES <- list(
  timesteps             = list(switch = "c_timesteps",                  stages = "123"),
  bioenergy_dem_min     = list(switch = "s60_2ndgen_bioenergy_dem_min", stages = "23"),
  bioenergy_1st_subsidy = list(switch = "s60_bioenergy_1st_subsidy",    stages = "23")
)

# Setting -> switch, and switch -> the stages it applies at, both read out of the
# one table above.
.GMS_FROM_INFRASTRUCTURE <- vapply(.INFRASTRUCTURE_SWITCHES, `[[`, character(1), "switch")
.GMS_SCOPE_INFRASTRUCTURE <- stats::setNames(
  vapply(.INFRASTRUCTURE_SWITCHES, `[[`, character(1), "stages"),
  unname(.GMS_FROM_INFRASTRUCTURE))

# Every setting the researcher names in this pipeline's own terms, and the
# MAgPIE switch it becomes. Both spellings would otherwise be settable, and an
# experiment carrying each with a different value would silently pick one.
.gms_from_key <- function() c(lever_switch_map(), .GMS_FROM_INFRASTRUCTURE)

# gms switches stage_cfg assigns itself and nothing else may carry: their value
# is phase logic, and a value written into an experiment would either be ignored
# (confusing) or stop reproducing the golden runs (worse). Two sources: the
# switches a lever asks the phase logic to set on its behalf, and the ones no
# lever names at all, which the phases decide entirely for themselves.
.PHASE_ONLY_SWITCHES <- c(
  "tc", "c44_bii_decrease", "c60_2ndgen_biodem",
  "c56_pollutant_prices", "c56_pollutant_prices_noselect",
  "s60_bioenergy_1st_price", "s60_bioenergy_2nd_price")

stage_controlled_switches <- function() {
  unique(c(lever_stage_switches(), .PHASE_ONLY_SWITCHES))
}

# Every gms switch whose value this pipeline decides, whether from a setting or
# from the stage. A gms entry naming one of these stops the run and says which
# setting to use instead.
pipeline_owned_switches <- function() {
  c(stage_controlled_switches(), unname(.gms_from_key()))
}

# The settings that own a gms switch, for the message that refuses it. A lever
# knows its own switch, including the ones the phase logic sets for it. Two
# settings can own one switch, each at a different phase, and both are returned:
# a reader sent to one of the two would change the wrong phase.
.key_owning_switch <- function(switch) {
  hit <- names(.GMS_FROM_INFRASTRUCTURE)[.GMS_FROM_INFRASTRUCTURE == switch]
  if (length(hit)) return(hit)
  lever_owning_switch(switch)
}

# Stop when a gms escape hatch names a switch the pipeline decides for itself.
.refuse_owned_switches <- function(switches, where) {
  clash <- intersect(switches, pipeline_owned_switches())
  if (!length(clash)) return(invisible(TRUE))
  instead <- vapply(clash, function(switch) {
    keys <- .key_owning_switch(switch)
    if (!length(keys)) paste0(switch, " (the stage decides it)")
    else paste0(switch, " -> set ", paste(keys, collapse = " or "))
  }, character(1))
  log_die(where, " sets gms switches this pipeline decides: ",
          paste(instead, collapse = "; "), ".")
}

# Which stages each settled switch applies at: the world's own switches as their
# levers declare them, the infrastructure ones as the table above declares them.
# A switch in neither list applies at every stage.
.gms_stage_scope <- function() c(lever_switch_scope(), .GMS_SCOPE_INFRASTRUCTURE)

# ---- type coercion and value checks -----------------------------------------

.coerce <- function(value, type, key) {
  if (!is.character(value)) return(.check_type(value, type, key))
  num <- function(x) {
    out <- suppressWarnings(as.numeric(x))
    if (any(is.na(out))) log_die(key, ": '", x, "' is not numeric")
    out
  }
  switch(type,
    chr     = value[1L],
    num     = { v <- num(value[1L]); if (length(v) != 1L) log_die(key, " takes one number"); v },
    lgl     = { v <- toupper(value[1L])
                if (!v %in% c("TRUE", "FALSE", "T", "F", "YES", "NO", "1", "0")) {
                  log_die(key, ": '", value[1L], "' is not a truth value")
                }
                v %in% c("TRUE", "T", "YES", "1") },
    # A vector written in R arrives as a vector; one written on a command line
    # or in an environment variable arrives as one comma-joined string.
    chr_vec = if (length(value) > 1L) trimws(value) else trimws(strsplit(value[1L], ",", fixed = TRUE)[[1L]]),
    num_vec = num(trimws(strsplit(value[1L], ",", fixed = TRUE)[[1L]])),
    log_die(key, ": unknown type '", type, "' in the key's declaration")
  )
}

# A value written in R already carries a type, and the wrong one is caught here
# rather than several steps later: bii_target = "high" is a mistake worth
# stopping on at the line it was written.
.check_type <- function(value, type, key) {
  wrong <- function(wanted) {
    log_die(key, " takes ", wanted, ", got ", class(value)[1L],
            if (length(value) != 1L) paste0(" of length ", length(value)) else "")
  }
  switch(type,
    chr     = if (!is.character(value) || length(value) != 1L) wrong("one piece of text"),
    num     = if (!is.numeric(value) || length(value) != 1L) wrong("one number"),
    lgl     = if (!is.logical(value) || length(value) != 1L) wrong("TRUE or FALSE"),
    chr_vec = if (!is.character(value)) wrong("text"),
    num_vec = if (!is.numeric(value) || !length(value)) wrong("one or more numbers"),
    log_die(key, ": unknown type '", type, "' in the key's declaration"))
  value
}

# What one setting has to be true of, whether it was written in an experiment or
# handed over on a command line. Both paths run through here, so a value that a
# --set would refuse cannot slip in through experiments.R either.
#
# A lever carries its own check, in its block in messageix/R/world_levers.R; the
# checks written out here are the ones for the sampling plan and for the
# infrastructure settings, which have no registry of their own.
.check_setting <- function(key, value) {
  if (key %in% lever_names()) return(lever_check(key, value))

  if (key %in% c("prices_bioenergy", "prices_ghg")) {
    if (!length(value))   log_die(key, " must not be empty")
    if (any(value < 0))   log_die(key, " must be non-negative")
    if (anyDuplicated(value)) log_die(key, " has duplicate levels")
    if (any(abs(value - round(value)) > 1e-9)) {
      log_die(key, " must be integer-valued: the levels appear in folder tokens and scenario column names")
    }
  }
  if (identical(key, "currency_2005_to_2017") && value <= 0) {
    log_die("currency_2005_to_2017 must be positive")
  }
  if (identical(key, "poll_seconds") && value <= 0)  log_die("poll_seconds must be positive (seconds)")
  if (identical(key, "timeout_hours") && value <= 0) log_die("timeout_hours must be positive (hours)")
  if (identical(key, "output_modules") && !length(value)) {
    log_die("output_modules must name at least one output script")
  }
  if (identical(key, "slurm_modules") && !length(value)) {
    log_die("slurm_modules must name at least one module")
  }
  invisible(TRUE)
}

# gms values reach MAgPIE as they are declared in GAMS: scalars numeric,
# switches character. "Inf" is a legitimate numeric scalar (s30_annual_max_growth).
.coerce_gms <- function(value) {
  if (!is.character(value)) return(value)
  num <- suppressWarnings(as.numeric(value))
  if (!is.na(num)) num else value
}

# ---- reading the experiments file -------------------------------------------

# The experiments declared in messageix/experiments.R, as a named list. The file
# only defines things, so it is read in an environment of its own and nothing it
# does reaches the caller.
load_experiments <- function(file = experiments_file()) {
  if (!file.exists(file)) {
    log_die("the experiments file ", file, " was not found. It is where the experiments are ",
            "declared, and every command resolves an experiment through it; run from the ",
            "MAgPIE model root.")
  }
  env <- new.env(parent = globalenv())
  source(file, local = env)
  if (!exists("EXPERIMENTS", envir = env, inherits = FALSE)) {
    log_die(file, " defines no EXPERIMENTS. It is a named list, one entry per experiment: ",
            "EXPERIMENTS <- list(default = experiment(narrative(), design()))")
  }
  found <- get("EXPERIMENTS", envir = env)
  if (!is.list(found) || !length(found) || is.null(names(found)) || any(!nzchar(names(found)))) {
    log_die("EXPERIMENTS in ", file, " must be a named list with at least one entry")
  }
  # A bare narrative() is accepted where an experiment() was meant: it is the
  # same thing with the default sampling plan, and refusing it would be pedantry.
  lapply(stats::setNames(names(found), names(found)), function(name) {
    entry <- found[[name]]
    if (inherits(entry, "mm_experiment")) return(entry)
    if (inherits(entry, "mm_narrative")) return(experiment(entry))
    log_die("experiment '", name, "' in ", file, " is not built with experiment(). Write it as ",
            name, " = experiment(narrative(...), design(...)), or leave either half out.")
  })
}

# The experiments a file declares, in the order they are written.
experiment_names <- function(file = experiments_file()) names(load_experiments(file))

# ---- resolve ----------------------------------------------------------------

# Read one experiment, apply overrides, derive, validate, freeze.
#
#   experiment  the name of an entry in EXPERIMENTS
#   overrides   named list, keys bare ("bii_target", "qos") or fully qualified
#               ("pipeline$bii_target", "gms$c_timesteps"). Values may be strings
#               (coerced as if from a command line) or already typed.
#   file        the experiments file; defaults to the repository's own
#
# Returns a list of class "mm_pcfg". Read it; do not edit it. The one supported
# mutation is with_patch().
resolve_config <- function(experiment = "default",
                           overrides = list(),
                           file = experiments_file()) {
  experiments <- load_experiments(file)
  if (!experiment %in% names(experiments)) {
    log_die("'", experiment, "' is not an experiment in ", file, ". It declares: ",
            paste(names(experiments), collapse = ", "),
            ". Adding one is a new entry in that list.")
  }
  chosen <- experiments[[experiment]]

  spec <- settable_spec()
  pipe <- pipeline_defaults()

  # The world first, then the sampling plan, then whatever the command line
  # overrides -- each of them already checked, one setting at a time.
  for (key in names(chosen$narrative$pipeline)) pipe[[key]] <- chosen$narrative$pipeline[[key]]
  for (key in names(chosen$design$pipeline))    pipe[[key]] <- chosen$design$pipeline[[key]]

  gms_raw <- chosen$narrative$gms

  for (key in names(overrides)) {
    qualified <- .qualify(key)
    if (grepl("^gms\\$", qualified)) {
      switch <- sub("^gms\\$", "", qualified)
      .refuse_owned_switches(switch, "--set")
      gms_raw[[switch]] <- overrides[[key]]
      next
    }
    bare <- sub("^pipeline\\$", "", qualified)
    if (bare %in% derived_keys()) {
      log_die("--set names ", bare, ", which the pipeline works out for itself. Names are ",
              "derived so that two experiments cannot land in one folder; the rules are in ",
              "messageix/R/pipeline_infrastructure.R.")
    }
    if (!bare %in% names(spec)) {
      log_die("--set names the unknown setting ", bare, ". It takes a lever of the world ",
              "(messageix/R/world_levers.R), a sampling-plan setting (prices_bioenergy, ",
              "prices_ghg), or an infrastructure setting ",
              "(messageix/R/pipeline_infrastructure.R).")
    }
    pipe[[bare]] <- .coerce(overrides[[key]], spec[[bare]]$type, bare)
    .check_setting(bare, pipe[[bare]])
  }

  # Infrastructure defaults arrive as they are written in the environment, so
  # they are coerced and checked here rather than at the point they were set.
  for (key in names(infrastructure_spec())) {
    pipe[[key]] <- .coerce(pipe[[key]], spec[[key]]$type, key)
    .check_setting(key, pipe[[key]])
  }

  # Derived: the region set decides the inputs, the regional tarball carries the
  # region code, and the region code plus the experiment's name make the names.
  inputs <- region_set_inputs(pipe$region_set)
  pipe$input_regional    <- unname(inputs$tarballs[["regional"]])
  pipe$input_cellular    <- unname(inputs$tarballs[["cellular"]])
  pipe$input_validation  <- unname(inputs$tarballs[["validation"]])
  pipe$input_additional  <- unname(inputs$tarballs[["additional"]])
  pipe$region_names      <- inputs$region_names
  pipe$regionscode       <- regionscode_of(pipe$input_regional)
  pipe$identifier        <- experiment_identifier(pipe$regionscode, experiment)
  pipe$matrix_basename   <- experiment_matrix_basename(pipe$ssp, experiment)

  # gms switches: the ones this pipeline names in its own terms, then any extra
  # switch the experiment carries for MAgPIE directly.
  .refuse_owned_switches(names(gms_raw), paste0("experiment '", experiment, "'"))
  gms <- c(.gms_from_keys(pipe), lapply(gms_raw, .coerce_gms))

  pcfg <- c(pipe, list(
    experiment  = experiment,
    experiments = file,
    gms         = gms,
    patch       = list(price = NULL, demand = NULL)
  ))
  class(pcfg) <- c("mm_pcfg", "list")
  .validate_pcfg(pcfg)
  pcfg
}

# A bare key names a pipeline setting; "gms$" and "pipeline$" say so explicitly.
.qualify <- function(key) {
  if (grepl("^(gms|pipeline)\\$", key)) key else paste0("pipeline$", key)
}

# The MAgPIE switches whose value comes from a settled key, in the types GAMS
# declares them in: scalars numeric, switches character.
.gms_from_keys <- function(pipe) {
  map <- .gms_from_key()
  stats::setNames(lapply(names(map), function(key) .coerce_gms(pipe[[key]])), unname(map))
}

.validate_pcfg <- function(pcfg) {
  need_chr <- c("ssp", "region_set", "identifier", "regionscode", "region_names",
                "input_regional", "input_cellular",
                "input_validation", "input_additional", "protect_scenario",
                "protect_scenario_step1", "yields_scenario", "tc_cost",
                "biodem_scenario_step1",
                "ghg_price_scenario_step2", "ghg_price_scenario_suffix",
                "qos", "patch_repo", "magpie_public_repo",
                "matrix_sdg_scen", "matrix_basename", "timesteps")
  for (key in need_chr) {
    if (!nzchar(pcfg[[key]])) log_die("", key, " must not be empty")
  }

  # The experiment's own name becomes a folder name and a GAMS set element, so
  # it takes only what both accept. A dot would be read by GAMS as a separator.
  if (!grepl("^[A-Za-z0-9][A-Za-z0-9_-]*$", pcfg$experiment)) {
    log_die("experiment name '", pcfg$experiment, "' becomes an output folder name and a GAMS ",
            "set element, so it takes letters, digits, dash and underscore only, starting with ",
            "a letter or digit.")
  }

  for (key in intersect(names(settable_spec()), names(pcfg))) .check_setting(key, pcfg[[key]])
  invisible(TRUE)
}

# Record the patch tarball a generator produced, for the stage that consumes it.
# The price sweep consumes the trajectory packed out of the reference run; the
# demand sweep consumes the bioenergy demand and GHG prices packed out of the
# price sweep.
with_patch <- function(pcfg, stage, tarball) {
  stage <- .as_stage(stage)
  if (stage == 1L) log_die("with_patch: the reference run needs no patch tarball")
  if (!is.character(tarball) || length(tarball) != 1L || !nzchar(tarball)) {
    log_die("with_patch: tarball must be a single non-empty file name")
  }
  pcfg$patch[[stage_token(stage)]] <- tarball
  pcfg
}

# An experiment's gms switches that apply at this stage. A switch's stages are
# written as digits ("123", "23"), so the digits are read apart and this stage
# looked for among them -- a switch applies at a stage or it does not, and asking
# whether the text contains the digit would be a different question.
stage_gms_keys <- function(pcfg, stage) {
  stage <- .as_stage(stage)
  scopes <- .gms_stage_scope()
  keys <- names(pcfg$gms)
  scope <- ifelse(keys %in% names(scopes), scopes[keys], "123")
  applies <- vapply(scope, function(stages) {
    as.character(stage) %in% strsplit(stages, "", fixed = TRUE)[[1L]]
  }, logical(1), USE.NAMES = FALSE)
  keys[applies]
}

# ---- stage cfg assembly -----------------------------------------------------

# cfg$input for one stage. Order is override order: later entries win, so the
# generated patch tarball must come last.
.stage_input <- function(pcfg, stage) {
  stage <- .as_stage(stage)
  input <- c(regional   = pcfg$input_regional,
             cellular   = pcfg$input_cellular,
             validation = pcfg$input_validation,
             additional = pcfg$input_additional)
  if (nzchar(pcfg$input_calibration)) {
    input <- c(input, calibration = pcfg$input_calibration)
  }
  if (stage > 1L) {
    patch <- pcfg$patch[[stage_token(stage)]]
    if (is.null(patch)) {
      log_die("the ", phase_of_stage(stage), " phase needs its packed inputs, and none has been ",
              "chosen for this run. The pipeline packs them itself; to build them on their own: ",
              "Rscript ", patch_generator_script(stage), " --experiment=", pcfg$experiment,
              if (stage == 3L) " --f56=PATH" else "", ".")
    }
    input <- c(input, patch = patch)
  }
  input
}

# The script that packs the inputs one stage reads. Named here as well as in the
# pipeline module so that a message from this layer can point at it.
patch_generator_script <- function(stage) {
  c(NA_character_, "messageix/R/pack_price.R", "messageix/R/pack_demand.R")[.as_stage(stage)]
}

# Assemble a complete MAgPIE cfg for one run, ready to hand to start_run().
#
#   pcfg   resolved experiment
#   stage  1, 2 or 3 (or "tau"/"price"/"demand")
#   be     bioenergy price level, required for stages 2 and 3
#   ghg    GHG price level, required for stage 3
#
# Must run from the MAgPIE model root: it sources config/default.cfg.
stage_cfg <- function(pcfg, stage, be = NULL, ghg = NULL) {
  assert_magpie_root()
  stage <- .as_stage(stage)

  if (stage > 1L) {
    if (is.null(be)) log_die("stage_cfg: stage ", stage, " needs a bioenergy price level")
    if (!any(abs(pcfg$prices_bioenergy - as.numeric(be)) < 1e-9)) {
      log_die("stage_cfg: bioenergy price ", be, " is not in prices_bioenergy (",
              paste(pcfg$prices_bioenergy, collapse = ", "), ")")
    }
  }
  if (stage == 3L) {
    if (is.null(ghg)) log_die("stage_cfg: the demand sweep needs a GHG price level")
    if (!any(abs(pcfg$prices_ghg - as.numeric(ghg)) < 1e-9)) {
      log_die("stage_cfg: GHG price ", ghg, " is not in prices_ghg (",
              paste(pcfg$prices_ghg, collapse = ", "), ")")
    }
  }

  cfg <- NULL
  source("config/default.cfg", local = TRUE)   # defines cfg
  if (is.null(cfg)) log_die("config/default.cfg did not define cfg")

  # SSP narrative from MAgPIE's own stock scenario config. Applied before the
  # experiment so that anything the experiment or the stage sets wins over it.
  cfg <- gms::setScenario(cfg, pcfg$ssp)

  # Run control.
  cfg$repositories  <- magpie_repositories(pcfg)
  cfg$force_replace <- pcfg$force_replace
  cfg$qos           <- run_qos(pcfg)
  cfg$output        <- pcfg$output_modules
  cfg$input         <- .stage_input(pcfg, stage)
  cfg$info$flag     <- pcfg$identifier

  # The experiment's own gms switches, in scope for this stage.
  for (key in stage_gms_keys(pcfg, stage)) {
    cfg$gms[[key]] <- pcfg$gms[[key]]
  }

  # Stage logic. Read the note on the golden runs in this file's header before
  # changing anything below.
  bl <- pcfg$bii_target
  if (stage == 1L) {
    # Reference tau: technological change stays endogenous (cfg$gms$tc untouched,
    # i.e. endo_jan22) because exporting that trajectory is the point of the run.
    cfg$gms$c44_bii_decrease     <- 0
    cfg$gms$c22_protect_scenario <- pcfg$protect_scenario_step1
    cfg$gms$c60_2ndgen_biodem    <- pcfg$biodem_scenario_step1
    cfg$title <- run_title(pcfg, stage)
  } else {
    # BII loss is permitted exactly when no BII target is imposed; with a target
    # in force the two settings would contradict each other.
    cfg$gms$c44_bii_decrease     <- if (bl == 0) 1 else 0
    cfg$gms$s44_bii_target       <- bl
    cfg$gms$c22_protect_scenario <- pcfg$protect_scenario
    cfg$gms$s15_rumdairy_scp_substitution <- pcfg$mp_substitution / 100

    if (stage == 2L) {
      # Price-driven: tau exogenous from the reference run, GHG price flat zero,
      # the bioenergy price is the only signal being swept.
      cfg$gms$tc <- "exo"
      cfg$gms$c56_pollutant_prices          <- pcfg$ghg_price_scenario_step2
      cfg$gms$c56_pollutant_prices_noselect <- pcfg$ghg_price_scenario_step2
      cfg$gms$s60_bioenergy_1st_price <- be * pcfg$currency_2005_to_2017
      cfg$gms$s60_bioenergy_2nd_price <- be * pcfg$currency_2005_to_2017
      cfg$title <- run_title(pcfg, stage, be = be)
    } else {
      # Demand-driven: tau endogenous again, bioenergy enters as the demand
      # trajectory the price sweep produced (prices stay at their default of
      # zero), and the GHG price is swept.
      scenario <- ghg_scenario(pcfg, ghg)
      cfg$gms$c56_pollutant_prices          <- scenario
      # Set in lockstep with c56_pollutant_prices. Left at a zero-price scenario
      # it is inert only while policy_countries56 covers every country, and
      # becomes a silent bug the moment an experiment narrows that set.
      cfg$gms$c56_pollutant_prices_noselect <- scenario
      cfg$gms$s56_limit_ch4_n2o_price       <- pcfg$nonco2_price_cap_usd17_tc
      cfg$gms$c60_2ndgen_biodem             <- scen_column(pcfg, be)
      cfg$title <- run_title(pcfg, stage, be = be, ghg = ghg)
    }
    cfg$info$flag2 <- pcfg$experiment
  }

  cfg$results_folder <- results_folder(pcfg, stage)
  cfg
}
