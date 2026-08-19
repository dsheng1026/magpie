# |  Reading a narrative, and assembling the MAgPIE cfg for one run.
# |
# |  Three tiers, and why. The pipeline has far more settings than a researcher
# |  should have to look at, so they are split by who owns them:
# |
# |    narrative       messageix/presets/narratives.csv. Rows are the settings a
# |                    narrative varies, columns are narratives. This is the only
# |                    file the experiment design lives in.
# |    infrastructure  messageix/R/pipeline_infrastructure.R. Operational
# |                    settings and constants of the linkage, each with an
# |                    environment variable and a "--set key=value" override.
# |    derived         worked out here, never set: the region code, the output
# |                    folder name, the matrix name, the input tarballs.
# |
# |  A narrative row is written bare ("bii_target;0.78"). "pipeline$bii_target"
# |  is accepted as the same thing, and a "gms$<switch>" row assigns a MAgPIE
# |  switch this pipeline does not otherwise expose. Vector-valued settings are
# |  comma-joined inside one cell. The delimiter is ";" (a comma-delimited file
# |  is also accepted, in which case vector cells must be quoted). A UTF-8 BOM is
# |  tolerated; "#" lines are comments.
# |
# |  Config flows one way: CSV column -> resolve_config() -> pcfg -> stage_cfg().
# |  pcfg is validated once and then read-only; the single legal mutation is
# |  with_patch(), which records the tarball a generator just produced.
# |
# |  Every setting, what it means and what it may be: messageix/docs/parameters.md.
# |
# |  The golden runs. "Golden runs" is the set of runs behind the reference
# |  matrix magpie_input_SSP2_ref_woodfuel.csv, the artefact this pipeline has to
# |  reproduce before it can be trusted with anything new. The `default` column
# |  plus the stage logic below reproduce them exactly, including three
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
# |  narrative settings, so a new narrative column cannot disturb them by
# |  accident.
# |
# |  Interface
# |    presets_dir()                        -> chr(1); the folder holding the preset files
# |    default_preset_csv()                 -> chr(1); this repository's narratives file
# |    read_pipeline_csv(path, what)        -> data.frame of characters; the CSV convention
# |    parse_flags(argv, known, flags, ...)  -> named list; the shared CLI flag parser
# |    invoked_directly(basename)           -> lgl(1); TRUE when Rscript was given this file
# |    config_from_flags(flags, overrides)  -> pcfg; resolve_config() from parsed flags
# |    narrative_spec()                     -> named list of list(default, type, unit)
# |    pipeline_defaults()                  -> named list; every settable key, typed default
# |    settable_keys()                      -> chr; narrative plus infrastructure keys
# |    preset_columns(csv)                  -> chr; narrative columns available in a narratives file
# |    read_preset(csv_path, column)        -> named chr; raw row key -> value
# |    resolve_config(preset, csv, overrides) -> pcfg, a validated list of class "mm_pcfg"
# |    with_patch(pcfg, stage, tarball)     -> pcfg; records a generated patch tarball name
# |    stage_gms_keys(pcfg, stage)          -> chr; gms switches applied at that stage
# |    stage_controlled_switches()          -> chr; gms switches stage_cfg owns
# |    pipeline_owned_switches()            -> chr; gms switches a preset row may not set
# |    stage_cfg(pcfg, stage, be, ghg)      -> list; a complete MAgPIE cfg for start_run()
# |
# |  Dependencies: base R, gms (setScenario), and messageix/R/{utils_log,utils_paths,
# |  utils_env,pipeline_infrastructure}.R. Run from the MAgPIE model root.

if (!exists("log_die", mode = "function"))     source("messageix/R/utils_log.R")
if (!exists("run_title", mode = "function"))   source("messageix/R/utils_paths.R")
if (!exists("run_qos", mode = "function"))     source("messageix/R/utils_env.R")
if (!exists("region_sets", mode = "function")) source("messageix/R/pipeline_infrastructure.R")

# ---- where the presets live -------------------------------------------------

# The folder holding this repository's preset files: the narratives file and the
# region-name tables the region sets refer to.
presets_dir <- function() "messageix/presets"

# The repository's own narratives file. Every entry point defaults to it, and
# the shell wrapper can ask for it, so the path is written once.
default_preset_csv <- function() file.path(presets_dir(), "narratives.csv")

# ---- reading a delimited table ----------------------------------------------

# Every CSV this pipeline reads follows one convention, applied here: a UTF-8
# byte-order mark is tolerated, "#" lines and blank lines are comments, and the
# delimiter is whichever of ";" and "," the header row uses. ";" is what
# European exports write and what lets a cell hold a comma-joined vector without
# quoting. `what` names the file in any failure message.
read_pipeline_csv <- function(path, what = "CSV") {
  if (!file.exists(path)) log_die(what, " not found: ", path)
  lines <- readLines(path, warn = FALSE, encoding = "UTF-8")
  # A byte-order mark survives readLines as either the U+FEFF character or its
  # three raw bytes, depending on the locale; strip both forms.
  lines[1L] <- sub("^\ufeff", "", lines[1L])
  lines[1L] <- sub("^\xef\xbb\xbf", "", lines[1L], useBytes = TRUE)
  lines <- lines[!grepl("^\\s*#", lines) & nzchar(trimws(lines))]
  if (!length(lines)) log_die(what, " holds no data rows: ", path)
  sep <- if (grepl(";", lines[1L], fixed = TRUE)) ";" else ","
  utils::read.table(text = paste(lines, collapse = "\n"), sep = sep,
                    header = TRUE, quote = "\"", comment.char = "",
                    colClasses = "character", check.names = FALSE,
                    stringsAsFactors = FALSE)
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
#   aliases     named vector of accepted spelling -> canonical name, for a flag
#               that has been renamed and whose old name must keep working
#   usage       appended to every failure message
#
# Two things stop the run rather than being ignored: an unknown option, because
# a mistyped one that fell through would build the wrong thing and say nothing,
# and a repeated option that is not declared repeatable, because silently taking
# the last of two conflicting values is how a sweep gets run at the wrong price.
# "-h" is accepted for "--help" wherever a --help flag is declared.
parse_flags <- function(argv, known, flags = character(0), repeatable = character(0),
                        aliases = character(0), usage = NULL) {
  fail <- function(...) log_die(..., if (is.null(usage)) "" else paste0("\n", usage))
  out <- list()
  seen <- character(0)
  i <- 1L
  while (i <= length(argv)) {
    arg <- argv[i]
    if (identical(arg, "-h") && "help" %in% flags) arg <- "--help"
    if (!grepl("^--", arg)) fail("unexpected argument '", arg, "'")
    name <- sub("^--", "", sub("=.*$", "", arg))
    inline <- grepl("=", arg, fixed = TRUE)
    if (name %in% names(aliases)) name <- unname(aliases[[name]])
    if (!name %in% c(known, flags, repeatable)) fail("unknown option: --", name)
    if (name %in% seen && !name %in% repeatable) fail("--", name, " given more than once")
    seen <- c(seen, name)
    if (name %in% flags) {
      if (inline) fail("--", name, " takes no value")
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
  out
}

# TRUE when Rscript was handed this very file, FALSE when another script sourced
# it. It guards the command-line block at the foot of an entry point, so that a
# script which is both a command and a library -- the pipeline driver, which the
# ensemble driver sources for its step definitions -- does not run itself when
# it is only being read.
invoked_directly <- function(basename_expected) {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- sub("^--file=", "", args[grepl("^--file=", args)])
  length(file_arg) == 1L && identical(basename(file_arg), basename_expected)
}

# The preset a command line asked for, resolved. Every entry point defaults the
# same way -- column "default" of this repository's narratives file -- and that
# default is decided here rather than in each of them.
config_from_flags <- function(flags, overrides = list()) {
  resolve_config(preset    = if (is.null(flags$preset)) "default" else flags$preset,
                 csv       = if (is.null(flags$csv)) default_preset_csv() else flags$csv,
                 overrides = overrides)
}

# ---- the settings a narrative varies ----------------------------------------

# Every narrative row: its default, its type, and what the value means.
# Types: "chr", "num", "lgl", "chr_vec", "num_vec". A row absent from a column
# takes the default here; a row present in a column but absent here is an error,
# because a silently ignored setting is worse than a stopped run.
#
# These are the settings a researcher varies. Everything operational lives in
# messageix/R/pipeline_infrastructure.R, and everything about names is derived.
narrative_spec <- function() {
  list(
    ssp = list(
      default = "SSP2", type = "chr",
      unit = "which shared socioeconomic pathway the run follows: a column of MAgPIE's own config/scenario_config.csv, applied before anything else. Also the first token of every run name"),
    region_set = list(
      default = "R12", type = "chr",
      unit = "the set of world regions the run solves for. It selects the input tarballs and the region-name table together, so the runs and the emulator matrix cannot end up at different resolutions"),
    bii_target = list(
      default = 0, type = "num",
      unit = "share of the biodiversity intactness index to maintain, as a fraction of 1 (cfg$gms$s44_bii_target). Narratives tested so far 0 / 0.7 / 0.74 / 0.78"),
    mp_substitution = list(
      default = 0, type = "num",
      unit = "percent of ruminant meat and dairy demand met by microbial protein instead; divided by 100 into cfg$gms$s15_rumdairy_scp_substitution. Narratives tested so far 0 / 25 / 50 / 75"),
    protect_scenario = list(
      default = "none", type = "chr",
      unit = "land protection scenario in stages 2 and 3 (cfg$gms$c22_protect_scenario)"),
    protect_scenario_step1 = list(
      default = "BH", type = "chr",
      unit = "land protection scenario the reference land-use intensity trajectory is calibrated under, in stage 1 (cfg$gms$c22_protect_scenario)"),
    yields_scenario = list(
      default = "nocc", type = "chr",
      unit = "whether crop yields carry climate change impacts (cfg$gms$c14_yields_scenario). nocc excludes them, which is defensible at 1-1.5 degC of warming; scenarios approaching 2 degC should use cc, where impacts are material"),
    tc_cost = list(
      default = "high", type = "chr",
      unit = "how costly yield-increasing technological change is (cfg$gms$c13_tccost). high makes intensifying existing cropland expensive, so the model leans more on expanding it. MAgPIE default medium"),
    cropland_max_growth = list(
      default = 0.02, type = "num",
      unit = "ceiling on how fast cropland may expand in a region, as a fraction per year (cfg$gms$s30_annual_max_growth). 0.02 caps it at 2 percent per year, a deliberate brake on how fast the sweep is allowed to reallocate land. MAgPIE default Inf, i.e. no brake at all"),
    bii_missing_cost = list(
      default = 10000000, type = "num",
      unit = "cost charged where the biodiversity intactness index has no data, USD17MER (cfg$gms$s44_cost_bii_missing). Ten times MAgPIE's default of 1e6, so the gaps in that data are not the cheapest place for the model to put land-use pressure"),
    nonco2_price_cap_usd17_tc = list(
      default = 200, type = "num",
      unit = "cap on the price applied to CH4 and N2O in stage 3, USD17MER per tC (cfg$gms$s56_limit_ch4_n2o_price, MAgPIE default 4920). Roughly 55 USD17 per tCO2: empirical abatement-cost curves show very little non-CO2 abatement above this price, and it keeps food prices plausible under strong mitigation"),
    be_prices = list(
      default = c(0, 5, 7, 10, 15, 25, 45), type = "num_vec",
      unit = "bioenergy price levels stage 2 sweeps, USD2005 per GJ. Chosen where land-use models change behaviour, with enough coverage around the turning points that interpolating between them lands on a sensible surface. Whole numbers only: each becomes a run name and a scenario column name (BE05)"),
    ghg_prices = list(
      default = c(0, 10, 20, 50, 100, 200, 400, 600, 1000, 2000, 3000, 4000), type = "num_vec",
      unit = "GHG price levels stage 3 sweeps. Each is a label, not a price: it names one column of the supplied f56_pollutant_prices.cs3 file, and that file carries the trajectory the label stands for. Whole numbers only; they appear in run names (G0400) and scenario names (G0400exp2110)")
  )
}

# The declared type and meaning of any settable key, narrative or infrastructure.
settable_spec <- function() c(narrative_spec(), infrastructure_spec())

# Every key a narrative column or a --set may carry.
settable_keys <- function() names(settable_spec())

# Named list of typed defaults, one entry per settable key. Infrastructure
# defaults arrive with their environment-variable overrides already applied.
pipeline_defaults <- function() {
  c(lapply(narrative_spec(), `[[`, "default"), infrastructure_defaults())
}

# ---- gms switches this pipeline owns ----------------------------------------

# Settings the researcher names in this pipeline's own terms, and the MAgPIE
# switch each one becomes. Both spellings would otherwise be settable, and a
# column carrying each with a different value would silently pick one.
.GMS_FROM_KEY <- c(
  timesteps             = "c_timesteps",
  tc_cost               = "c13_tccost",
  yields_scenario       = "c14_yields_scenario",
  cropland_max_growth   = "s30_annual_max_growth",
  bii_missing_cost      = "s44_cost_bii_missing",
  bioenergy_dem_min     = "s60_2ndgen_bioenergy_dem_min",
  bioenergy_1st_subsidy = "s60_bioenergy_1st_subsidy"
)

# gms switches stage_cfg assigns itself. A preset may not carry them: their
# value is stage logic, and a preset row would either be ignored (confusing) or
# stop reproducing the golden runs (worse).
stage_controlled_switches <- function() {
  c("tc",
    "c44_bii_decrease", "s44_bii_target", "c22_protect_scenario",
    "s15_rumdairy_scp_substitution",
    "c60_2ndgen_biodem",
    "c56_pollutant_prices", "c56_pollutant_prices_noselect",
    "s56_limit_ch4_n2o_price",
    "s60_bioenergy_1st_price", "s60_bioenergy_2nd_price")
}

# Every gms switch whose value this pipeline decides, whether from a narrative
# row or from the stage. A "gms$" row naming one of these stops the run and says
# which key to set instead.
pipeline_owned_switches <- function() {
  c(stage_controlled_switches(), unname(.GMS_FROM_KEY))
}

# The key that owns a gms switch, for the message that refuses it.
.key_owning_switch <- function(switch) {
  hit <- names(.GMS_FROM_KEY)[.GMS_FROM_KEY == switch]
  if (length(hit)) hit[1L] else NA_character_
}

# Which stages a preset's gms rows apply at. A switch absent from this table
# applies at every stage. The ones listed here apply at stages 2 and 3 only,
# because stage 1 -- the reference tau run -- leaves them at MAgPIE's defaults.
.GMS_STAGE_SCOPE <- c(
  s30_annual_max_growth        = "23",
  s44_cost_bii_missing         = "23",
  s60_2ndgen_bioenergy_dem_min = "23",
  s60_bioenergy_1st_subsidy    = "23"
)

# ---- reading a preset -------------------------------------------------------

# A narratives file as a data frame of character columns: column 1 holds the row
# keys, every other column is one narrative.
.preset_table <- function(csv_path) {
  tab <- read_pipeline_csv(csv_path, "narratives file")
  if (ncol(tab) < 2L) {
    log_die("narratives file ", csv_path, " parsed to ", ncol(tab),
            " column(s); it takes a key column plus at least one narrative column")
  }
  tab
}

# Narrative columns a narratives file offers. Column 1 holds the keys.
preset_columns <- function(csv) {
  names(.preset_table(csv))[-1L]
}

# Raw values of one narrative column, as a named character vector keyed by the
# full row key ("gms$c13_tccost", "pipeline$be_prices"). Empty cells drop out,
# so a column may leave any row to its default.
read_preset <- function(csv_path, column) {
  tab <- .preset_table(csv_path)
  if (!column %in% names(tab)[-1L]) {
    log_die("preset column '", column, "' not in ", csv_path,
            "; available: ", paste(names(tab)[-1L], collapse = ", "))
  }
  keys <- trimws(tab[[1L]])
  values <- trimws(tab[[column]])
  keep <- nzchar(keys) & nzchar(values)
  stats::setNames(values[keep], keys[keep])
}

# ---- type coercion ----------------------------------------------------------

.coerce <- function(value, type, key) {
  if (!is.character(value)) return(value)   # an override may already be typed
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
    chr_vec = trimws(strsplit(value[1L], ",", fixed = TRUE)[[1L]]),
    num_vec = num(trimws(strsplit(value[1L], ",", fixed = TRUE)[[1L]])),
    log_die(key, ": unknown type '", type, "' in the key's declaration")
  )
}

# gms values reach MAgPIE as they are declared in GAMS: scalars numeric,
# switches character. "Inf" is a legitimate numeric scalar (s30_annual_max_growth).
.coerce_gms <- function(value) {
  if (!is.character(value)) return(value)
  num <- suppressWarnings(as.numeric(value))
  if (!is.na(num)) num else value
}

# ---- resolve ----------------------------------------------------------------

# Read a narrative column, apply overrides, coerce, derive, validate, freeze.
#
#   preset    narrative column name
#   csv       narratives file; defaults to the repository's own
#   overrides named list, keys bare ("bii_target", "qos") or fully qualified
#             ("pipeline$bii_target", "gms$c_timesteps"). Values may be strings
#             (coerced as if from the CSV) or already typed.
#
# Returns a list of class "mm_pcfg". Read it; do not edit it. The one supported
# mutation is with_patch().
resolve_config <- function(preset = "default",
                           csv = default_preset_csv(),
                           overrides = list()) {
  # A list, not a character vector: an override may already carry its final
  # type, and assigning one into a character vector would coerce it back.
  raw <- as.list(read_preset(csv, preset))

  # Row keys are written bare in the file; the namespace is spelled out here so
  # that a row and an override of the same setting are the same entry.
  names(raw) <- vapply(names(raw), .qualify, character(1))

  # Overrides are merged as raw rows so that a file value and a command-line
  # value travel the same validation path.
  for (key in names(overrides)) raw[[.qualify(key)]] <- overrides[[key]]

  spec <- settable_spec()

  # pipeline rows
  pipe_raw <- raw[grepl("^pipeline\\$", names(raw))]
  names(pipe_raw) <- sub("^pipeline\\$", "", names(pipe_raw))
  derived <- intersect(names(pipe_raw), derived_keys())
  if (length(derived)) {
    log_die("'", preset, "' sets ", paste(derived, collapse = ", "),
            ", which the pipeline works out for itself. Names are derived so that two ",
            "narratives cannot land in one folder; see messageix/docs/parameters.md.")
  }
  unknown <- setdiff(names(pipe_raw), names(spec))
  if (length(unknown)) {
    log_die("'", preset, "' in ", csv, " sets unknown key(s): ", paste(unknown, collapse = ", "),
            ". The settings a narrative may carry are listed in messageix/docs/parameters.md.")
  }
  pipe <- pipeline_defaults()
  for (key in names(pipe_raw)) {
    pipe[[key]] <- .coerce(pipe_raw[[key]], spec[[key]]$type, key)
  }

  # Derived: the region set decides the inputs, the regional tarball carries the
  # region code, and the region code plus the column name make the names.
  inputs <- region_set_inputs(pipe$region_set)
  pipe$input_regional    <- unname(inputs$tarballs[["regional"]])
  pipe$input_cellular    <- unname(inputs$tarballs[["cellular"]])
  pipe$input_validation  <- unname(inputs$tarballs[["validation"]])
  pipe$input_additional  <- unname(inputs$tarballs[["additional"]])
  pipe$region_names      <- inputs$region_names
  pipe$regionscode       <- regionscode_of(pipe$input_regional)
  pipe$identifier        <- narrative_identifier(pipe$regionscode, preset)
  pipe$matrix_basename   <- narrative_matrix_basename(pipe$ssp, preset)

  # gms switches: the ones this pipeline names in its own terms, then any extra
  # switch a column carries for MAgPIE directly.
  gms_raw <- raw[grepl("^gms\\$", names(raw))]
  names(gms_raw) <- sub("^gms\\$", "", names(gms_raw))
  clash <- intersect(names(gms_raw), pipeline_owned_switches())
  if (length(clash)) {
    instead <- vapply(clash, function(switch) {
      key <- .key_owning_switch(switch)
      if (is.na(key)) paste0(switch, " (the stage decides it)") else paste0(switch, " -> set ", key)
    }, character(1))
    log_die("'", preset, "' sets gms switches this pipeline decides: ",
            paste(instead, collapse = "; "), ".")
  }
  gms <- c(.gms_from_keys(pipe), lapply(gms_raw, .coerce_gms))

  pcfg <- c(pipe, list(
    preset = preset,
    csv    = csv,
    gms    = gms,
    patch  = list(price = NULL, demand = NULL)
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
  stats::setNames(lapply(names(.GMS_FROM_KEY), function(key) .coerce_gms(pipe[[key]])),
                  unname(.GMS_FROM_KEY))
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

  # The narrative's own name becomes a folder name and a GAMS set element, so it
  # takes only what both accept. A dot would be read by GAMS as a separator.
  if (!grepl("^[A-Za-z0-9][A-Za-z0-9_-]*$", pcfg$preset)) {
    log_die("narrative name '", pcfg$preset, "' becomes an output folder name and a GAMS set ",
            "element, so it takes letters, digits, dash and underscore only, starting with a ",
            "letter or digit.")
  }

  for (key in c("be_prices", "ghg_prices")) {
    v <- pcfg[[key]]
    if (!length(v))            log_die(key, " must not be empty")
    if (any(v < 0))            log_die(key, " must be non-negative")
    if (anyDuplicated(v))      log_die(key, " has duplicate levels")
    if (any(abs(v - round(v)) > 1e-9)) {
      log_die(key, " must be integer-valued: the levels appear in folder tokens and scenario column names")
    }
  }

  if (pcfg$poll_seconds <= 0)  log_die("poll_seconds must be positive (seconds)")
  if (pcfg$timeout_hours <= 0) log_die("timeout_hours must be positive (hours)")

  if (pcfg$currency_2005_to_2017 <= 0) log_die("currency_2005_to_2017 must be positive")
  if (pcfg$nonco2_price_cap_usd17_tc <= 0) {
    log_die("nonco2_price_cap_usd17_tc must be positive (USD17MER per tC)")
  }
  if (pcfg$mp_substitution < 0 || pcfg$mp_substitution > 100) {
    log_die("mp_substitution is a percent in [0, 100], got ", pcfg$mp_substitution)
  }
  if (pcfg$cropland_max_growth <= 0) {
    log_die("cropland_max_growth is a fraction per year and must be positive; Inf lifts the brake entirely")
  }
  if (pcfg$bii_missing_cost < 0) log_die("bii_missing_cost must be non-negative (USD17MER)")
  if (!length(pcfg$output_modules)) log_die("output_modules must name at least one output script")
  if (!length(pcfg$slurm_modules))  log_die("slurm_modules must name at least one module")

  bl <- as.numeric(pcfg$bii_target)
  if (is.na(bl) || bl < 0 || bl >= 1) {
    log_die("bii_target is a share of the biodiversity intactness index and lies in [0, 1), got ",
            pcfg$bii_target)
  }
  invisible(TRUE)
}

# Record the patch tarball a generator produced, for the stage that consumes it.
# Stage 2 consumes the tau patch built from stage-1 output; stage 3 consumes the
# bioenergy-demand and GHG-price patch built from stage-2 output.
with_patch <- function(pcfg, stage, tarball) {
  stage <- .as_stage(stage)
  if (stage == 1L) log_die("with_patch: stage 1 runs without a patch tarball")
  if (!is.character(tarball) || length(tarball) != 1L || !nzchar(tarball)) {
    log_die("with_patch: tarball must be a single non-empty file name")
  }
  pcfg$patch[[stage_token(stage)]] <- tarball
  pcfg
}

# Preset gms switches that apply at this stage.
stage_gms_keys <- function(pcfg, stage) {
  stage <- .as_stage(stage)
  keys <- names(pcfg$gms)
  scope <- ifelse(keys %in% names(.GMS_STAGE_SCOPE), .GMS_STAGE_SCOPE[keys], "123")
  keys[grepl(as.character(stage), scope, fixed = TRUE)]
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
      log_die("stage ", stage, " needs its patch tarball, and none has been chosen for this ",
              "run. Build it with: Rscript messageix/patches/build_step", stage,
              "_patch.R --preset=", pcfg$preset,
              if (stage == 3L) " --f56=PATH" else "",
              ". The stage drivers and the pipeline driver then find it by name.")
    }
    input <- c(input, patch = patch)
  }
  input
}

# Assemble a complete MAgPIE cfg for one run, ready to hand to start_run().
#
#   pcfg   resolved preset
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
    if (!any(abs(pcfg$be_prices - as.numeric(be)) < 1e-9)) {
      log_die("stage_cfg: bioenergy price ", be, " is not in be_prices (",
              paste(pcfg$be_prices, collapse = ", "), ")")
    }
  }
  if (stage == 3L) {
    if (is.null(ghg)) log_die("stage_cfg: stage 3 needs a GHG price level")
    if (!any(abs(pcfg$ghg_prices - as.numeric(ghg)) < 1e-9)) {
      log_die("stage_cfg: GHG price ", ghg, " is not in ghg_prices (",
              paste(pcfg$ghg_prices, collapse = ", "), ")")
    }
  }

  cfg <- NULL
  source("config/default.cfg", local = TRUE)   # defines cfg
  if (is.null(cfg)) log_die("config/default.cfg did not define cfg")

  # SSP narrative from MAgPIE's own stock scenario config. Applied before the
  # preset so that anything the preset or the stage sets wins over it.
  cfg <- gms::setScenario(cfg, pcfg$ssp)

  # Run control.
  cfg$repositories  <- magpie_repositories(pcfg)
  cfg$force_replace <- pcfg$force_replace
  cfg$qos           <- run_qos(pcfg)
  cfg$output        <- pcfg$output_modules
  cfg$input         <- .stage_input(pcfg, stage)
  cfg$info$flag     <- pcfg$identifier

  # Preset gms switches in scope for this stage.
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
      # Price-driven: tau exogenous from stage 1, GHG price flat zero, the
      # bioenergy price is the only signal being swept.
      cfg$gms$tc <- "exo"
      cfg$gms$c56_pollutant_prices          <- pcfg$ghg_price_scenario_step2
      cfg$gms$c56_pollutant_prices_noselect <- pcfg$ghg_price_scenario_step2
      cfg$gms$s60_bioenergy_1st_price <- be * pcfg$currency_2005_to_2017
      cfg$gms$s60_bioenergy_2nd_price <- be * pcfg$currency_2005_to_2017
      cfg$title <- run_title(pcfg, stage, be = be)
    } else {
      # Demand-driven: tau endogenous again, bioenergy enters as the demand
      # trajectory stage 2 produced (prices stay at their default of zero), and
      # the GHG price is swept.
      scenario <- ghg_scenario(pcfg, ghg)
      cfg$gms$c56_pollutant_prices          <- scenario
      # Set in lockstep with c56_pollutant_prices. Left at a zero-price scenario
      # it is inert only while policy_countries56 covers every country, and
      # becomes a silent bug the moment a preset narrows that set.
      cfg$gms$c56_pollutant_prices_noselect <- scenario
      cfg$gms$s56_limit_ch4_n2o_price       <- pcfg$nonco2_price_cap_usd17_tc
      cfg$gms$c60_2ndgen_biodem             <- scen_column(pcfg, be)
      cfg$title <- run_title(pcfg, stage, be = be, ghg = ghg)
    }
    cfg$info$flag2 <- pcfg$preset
  }

  cfg$results_folder <- results_folder(pcfg, stage)
  cfg
}
