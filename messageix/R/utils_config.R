# |  Preset reading, validation, and MAgPIE cfg assembly.
# |
# |  One CSV holds the whole experiment design: rows are parameters, columns are
# |  narratives. A new narrative is a new column, never a new start script.
# |  Two row namespaces:
# |
# |    gms$<switch>     assigned verbatim onto cfg$gms; MAgPIE's own switches
# |    pipeline$<key>   this pipeline's own settings; the keys are declared in
# |                     pipeline_spec() and an unknown one is an error
# |
# |  Vector-valued settings are comma-joined inside one cell. The delimiter is
# |  ";" (a comma-delimited file is also accepted, in which case vector cells
# |  must be quoted). A UTF-8 BOM is tolerated; "#" lines are comments.
# |
# |  Config flows one way: CSV column -> resolve_config() -> pcfg -> stage_cfg().
# |  pcfg is validated once and then read-only; the single legal mutation is
# |  with_patch(), which records the tarball a generator just produced.
# |
# |  GOLDEN-MASTER INVARIANCE. The `default` column plus the stage logic below
# |  reproduce the runs behind magpie_input_SSP2_ref_woodfuel.csv exactly,
# |  including three asymmetries that look like oversights and are not:
# |
# |    1. Stage 1 runs c22_protect_scenario = "BH" while stages 2 and 3 run
# |       "none". Tau is calibrated under land protection and then applied
# |       exogenously without it.
# |    2. Stage 1 runs c44_bii_decrease = 0 while stages 2 and 3 run 1, and
# |       leaves s30_annual_max_growth, s44_cost_bii_missing, s60_* and every
# |       c56_* switch at their MAgPIE defaults. It is a reference run, not a
# |       member of the training set.
# |    3. The non-CO2 GHG price cap applies in stage 3 only. Stage 1 runs under
# |       an NPi price path with MAgPIE's default cap of 4920 USD17MER/tC;
# |       capping it there would move the tau trajectory the whole pipeline
# |       rests on. Stage 2 runs at zero GHG price, where the cap is inert.
# |
# |  Any change to these three lines changes the science. They are code, not
# |  preset values, so a new narrative column cannot disturb them by accident.
# |
# |  Interface
# |    default_preset_csv()                 -> chr(1); this repository's own preset CSV
# |    parse_flags(argv, known, flags, ...)  -> named list; the shared CLI flag parser
# |    pipeline_defaults()                  -> named list; every pipeline$ key, typed default
# |    pipeline_spec()                      -> named list of list(default, type, unit)
# |    preset_columns(csv)                  -> chr; narrative columns available in a preset CSV
# |    read_preset(csv_path, column)        -> named chr; raw "gms$x"/"pipeline$y" -> value
# |    resolve_config(preset, csv, overrides) -> pcfg, a validated list of class "mm_pcfg"
# |    with_patch(pcfg, stage, tarball)     -> pcfg; records a generated patch tarball name
# |    stage_gms_keys(pcfg, stage)          -> chr; preset gms switches applied at that stage
# |    stage_controlled_switches()          -> chr; gms switches stage_cfg owns; presets may not set
# |    stage_cfg(pcfg, stage, be, ghg)      -> list; a complete MAgPIE cfg for start_run()
# |
# |  Dependencies: base R, gms (setScenario), and messageix/R/{utils_log,utils_paths,utils_env}.R.
# |  Run from the MAgPIE model root.

if (!exists("log_die", mode = "function"))     source("messageix/R/utils_log.R")
if (!exists("run_title", mode = "function"))   source("messageix/R/utils_paths.R")
if (!exists("run_qos", mode = "function"))     source("messageix/R/utils_env.R")

# ---- where the presets live -------------------------------------------------

# The repository's own preset CSV. Every entry point defaults to it, and the
# shell wrapper can ask for it, so the path is written once.
default_preset_csv <- function() "messageix/presets/scenario_config.csv"

# ---- command line -----------------------------------------------------------

# Parse "--key=value" and "--key value" into a named list. Both spellings are
# accepted everywhere so that a command copied from one script's usage line
# works in another.
#
#   known    options that take a value
#   flags    options that take none; they come back as TRUE
#   aliases  named vector of accepted spelling -> canonical name, for a flag
#            that has been renamed and whose old name must keep working
#   usage    appended to every failure message
#
# An unknown option stops the run rather than being ignored: a mistyped option
# that fell through would build the wrong thing and say nothing.
parse_flags <- function(argv, known, flags = character(0), aliases = character(0),
                        usage = NULL) {
  fail <- function(...) log_die(..., if (is.null(usage)) "" else paste0("\n", usage))
  out <- list()
  i <- 1L
  while (i <= length(argv)) {
    arg <- argv[i]
    if (!grepl("^--", arg)) fail("unexpected argument '", arg, "'")
    name <- sub("^--", "", sub("=.*$", "", arg))
    inline <- grepl("=", arg, fixed = TRUE)
    if (name %in% names(aliases)) name <- unname(aliases[[name]])
    if (!name %in% c(known, flags)) fail("unknown option: --", name)
    if (name %in% flags) {
      if (inline) fail("--", name, " takes no value")
      out[[name]] <- TRUE
      i <- i + 1L
    } else if (inline) {
      value <- sub("^--[^=]*=", "", arg)
      if (!nzchar(value)) fail("option --", name, " needs a value")
      out[[name]] <- value
      i <- i + 1L
    } else {
      if (i == length(argv)) fail("option --", name, " needs a value")
      out[[name]] <- argv[i + 1L]
      i <- i + 2L
    }
  }
  out
}

# ---- the pipeline$ namespace ------------------------------------------------

# Every pipeline$ key: its default, its type, and what the value means.
# Types: "chr", "num", "lgl", "chr_vec", "num_vec". A key absent from a preset
# column takes the default here; a key present in a column but absent here is
# an error, because a silently ignored setting is worse than a stopped run.
pipeline_spec <- function() {
  list(
    # --- narrative identity ---
    ssp = list(
      default = "SSP2", type = "chr",
      unit = "column of config/scenario_config.csv applied via gms::setScenario; also the first token of every run name"),
    identifier = list(
      default = "MESSAGEix_5ff27be8", type = "chr",
      unit = "top-level output folder; 5ff27be8 is the MESSAGE R12 regionscode carried by the input tarballs"),

    # --- input tarballs (see messageix/inputs/ for how to obtain them) ---
    input_regional = list(
      default = "rev4.119_5ff27be8_magpie.tgz", type = "chr",
      unit = "regional input tarball, rev4.119 at MESSAGE R12"),
    input_cellular = list(
      default = "rev4.119_5ff27be8_1b5c3817_cellularmagpie_c200_MRI-ESM2-0-ssp245_lpjml-8e6c5eb1.tgz", type = "chr",
      unit = "cellular input tarball; the climate forcing (ssp245) matches the SSP narrative"),
    input_validation = list(
      default = "rev4.119_5ff27be8_validation.tgz", type = "chr",
      unit = "validation tarball, same revision and regionscode"),
    input_additional = list(
      default = "additional_data_rev4.62.tgz", type = "chr",
      unit = "additional data tarball; the R12 set pins rev4.62 where MAgPIE v4.11.0 defaults to rev4.63"),
    input_calibration = list(
      default = "", type = "chr",
      unit = "calibration tarball; empty means no calibration entry, which is what the golden runs used"),

    # --- the two sweeps ---
    be_prices = list(
      default = c(0, 5, 7, 10, 15, 25, 45), type = "num_vec",
      unit = "USD2005 per GJ; multiplied by currency_2005_to_2017 into s60_bioenergy_{1st,2nd}_price in stage 2. Integer-valued: the values appear in folder tokens and scenario column names"),
    ghg_prices = list(
      default = c(0, 10, 20, 50, 100, 200, 400, 600, 1000, 2000, 3000, 4000), type = "num_vec",
      unit = "GHG price levels labelling the f56_pollutant_prices.cs3 columns the stage-3 patch supplies. The label is a level identifier; the trajectory it names is built by the patch generator. Integer-valued"),

    # --- conversions and caps ---
    currency_2005_to_2017 = list(
      default = 1.23, type = "num",
      unit = "USD2005 -> USD2017 MER deflator. Multiplies the bioenergy price sweep; its reciprocal (0.81300813) converts prices back in MM_linkage_mapping.csv. Moves whenever MAgPIE's base year moves -- revisit at every MAgPIE version bump"),
    nonco2_price_cap_usd17_tc = list(
      default = 200, type = "num",
      unit = "USD17MER per tC, cfg$gms$s56_limit_ch4_n2o_price in stage 3 (MAgPIE default 4920). Roughly 55 USD17 per tCO2. Empirical MAC curves show negligible non-CO2 abatement above this level, and it keeps food prices plausible under strong mitigation"),

    # --- narrative dials ---
    bii_target = list(
      default = 0, type = "num",
      unit = "cfg$gms$s44_bii_target, fraction of the biodiversity intactness index to maintain. Tested narratives 0 / 0.7 / 0.74 / 0.78. Must be a multiple of 0.01 below 1: it becomes the BD token of every run name"),
    mp_substitution = list(
      default = 0, type = "num",
      unit = "percent of ruminant and dairy demand met by microbial protein; divided by 100 into cfg$gms$s15_rumdairy_scp_substitution. Tested narratives 0 / 25 / 50 / 75"),
    protect_scenario_step1 = list(
      default = "BH", type = "chr",
      unit = "cfg$gms$c22_protect_scenario in stage 1: the land protection scenario the reference tau is calibrated under"),
    protect_scenario = list(
      default = "none", type = "chr",
      unit = "cfg$gms$c22_protect_scenario in stages 2 and 3"),
    biodem_scenario_step1 = list(
      default = "R34M410-SSP2-NPi2025", type = "chr",
      unit = "cfg$gms$c60_2ndgen_biodem in stage 1: the BAU second-generation bioenergy demand path tau is calibrated against"),
    ghg_price_scenario_step2 = list(
      default = "SSPDB-SSP2-Ref-MESSAGE-GLOBIOM", type = "chr",
      unit = "cfg$gms$c56_pollutant_prices in stage 2. Chosen because it is zero in every region and period: stage 2 isolates the bioenergy price signal"),
    ghg_price_scenario_suffix = list(
      default = "exp2110", type = "chr",
      unit = "suffix of the stage-3 GHG price scenario names, recording how the trajectory is extended past the last reported year"),

    # --- run control ---
    output_modules = list(
      default = c("output_check", "rds_report"), type = "chr_vec",
      unit = "cfg$output, the post-processing scripts each run executes"),
    force_replace = list(
      default = TRUE, type = "lgl",
      unit = "cfg$force_replace; TRUE lets a re-run overwrite a run folder of the same name, which the deterministic naming makes routine"),

    # --- execution environment (see utils_env.R for the env-var overrides) ---
    qos = list(
      default = "priority", type = "chr",
      unit = "cfg$qos, selecting scripts/run_submit/submit_<qos>.sh. A PIK queue name"),
    slurm_modules = list(
      default = c("defaults/piam/1.27", "R/4.3.2", "gcc/15.2.0"), type = "chr_vec",
      unit = "environment modules loaded before Rscript, in load order; gcc last (see utils_env.R)"),
    mail_user = list(
      default = "", type = "chr",
      unit = "job notification address; empty means job scripts carry no mail directives"),
    patch_repo = list(
      default = "./patch_input", type = "chr",
      unit = "directory the patch generators write into and cfg$repositories searches for patch tarballs"),
    magpie_public_repo = list(
      default = "https://rse.pik-potsdam.de/data/magpie/public", type = "chr",
      unit = "repository serving the base input tarballs"),

    # --- emulator matrix tagging ---
    matrix_ssp_scen = list(
      default = "SSP2", type = "chr",
      unit = "SSPscen column of the emulator matrix"),
    matrix_sdg_scen = list(
      default = "noSDG_rcpref", type = "chr",
      unit = "SDGscen column of the emulator matrix"),
    matrix_run_suffix = list(
      default = "demand", type = "chr",
      unit = "run-title suffix the matrix builder reads runs from; stage 3 produces the training set"),
    matrix_basename = list(
      default = "magpie_input_SSP2_ref", type = "chr",
      unit = "basename of the matrix CSV run_matrix.sh writes when --out is not given; the woodfuel step appends _woodfuel to it, which is how the golden artefact name magpie_input_SSP2_ref_woodfuel.csv is reproduced")
  )
}

# Named list of typed defaults, one entry per pipeline$ key.
pipeline_defaults <- function() {
  lapply(pipeline_spec(), `[[`, "default")
}

# gms switches stage_cfg assigns itself. A preset may not carry them: their
# value is stage logic, and a preset row would either be ignored (confusing) or
# break golden-master invariance (worse).
stage_controlled_switches <- function() {
  c("tc",
    "c44_bii_decrease", "s44_bii_target", "c22_protect_scenario",
    "s15_rumdairy_scp_substitution",
    "c60_2ndgen_biodem",
    "c56_pollutant_prices", "c56_pollutant_prices_noselect",
    "s56_limit_ch4_n2o_price",
    "s60_bioenergy_1st_price", "s60_bioenergy_2nd_price")
}

# Stage scope of the preset's gms rows. Switches absent from this table apply to
# every stage. The listed ones apply to stages 2 and 3 only, because stage 1 --
# the reference tau run -- left them at MAgPIE's defaults.
.GMS_STAGE_SCOPE <- c(
  s30_annual_max_growth        = "23",
  s44_cost_bii_missing         = "23",
  s60_2ndgen_bioenergy_dem_min = "23",
  s60_bioenergy_1st_subsidy    = "23"
)

# ---- reading a preset -------------------------------------------------------

# Strip a BOM, drop comment and blank lines, return the remaining lines.
.preset_lines <- function(csv_path) {
  if (!file.exists(csv_path)) log_die("preset CSV not found: ", csv_path)
  lines <- readLines(csv_path, warn = FALSE, encoding = "UTF-8")
  # A UTF-8 BOM survives readLines as either the U+FEFF character or its three
  # raw bytes, depending on the locale; strip both forms.
  lines[1L] <- sub("^\ufeff", "", lines[1L])
  lines[1L] <- sub("^\xef\xbb\xbf", "", lines[1L], useBytes = TRUE)
  lines <- lines[!grepl("^\\s*#", lines) & nzchar(trimws(lines))]
  if (!length(lines)) log_die("preset CSV holds no data rows: ", csv_path)
  lines
}

# Parse a preset CSV into a data frame of character columns. The delimiter is
# whichever of ";" and "," appears in the header row; European exports use ";",
# and ";" also lets a cell hold a comma-joined vector unquoted.
.preset_table <- function(csv_path) {
  lines <- .preset_lines(csv_path)
  sep <- if (grepl(";", lines[1L], fixed = TRUE)) ";" else ","
  tab <- utils::read.table(text = paste(lines, collapse = "\n"), sep = sep,
                           header = TRUE, quote = "\"", comment.char = "",
                           colClasses = "character", check.names = FALSE,
                           stringsAsFactors = FALSE)
  if (ncol(tab) < 2L) {
    log_die("preset CSV ", csv_path, " parsed to ", ncol(tab),
            " column(s) with delimiter '", sep, "'; expected a key column plus at least one narrative")
  }
  tab
}

# Narrative columns a preset CSV offers. Column 1 holds the keys.
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
    if (any(is.na(out))) log_die("pipeline$", key, ": '", x, "' is not numeric")
    out
  }
  switch(type,
    chr     = value[1L],
    num     = { v <- num(value[1L]); if (length(v) != 1L) log_die("pipeline$", key, " takes one number"); v },
    lgl     = { v <- toupper(value[1L])
                if (!v %in% c("TRUE", "FALSE", "T", "F", "YES", "NO", "1", "0")) {
                  log_die("pipeline$", key, ": '", value[1L], "' is not a truth value")
                }
                v %in% c("TRUE", "T", "YES", "1") },
    chr_vec = trimws(strsplit(value[1L], ",", fixed = TRUE)[[1L]]),
    num_vec = num(trimws(strsplit(value[1L], ",", fixed = TRUE)[[1L]])),
    log_die("pipeline$", key, ": unknown type '", type, "' in pipeline_spec()")
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

# Read a preset column, apply overrides, coerce, validate, and freeze.
#
#   preset    narrative column name
#   csv       preset CSV; defaults to the repository's own presets file
#   overrides named list, keys either fully qualified ("pipeline$bii_target",
#             "gms$c14_yields_scenario") or a bare pipeline key ("bii_target").
#             Values may be strings (coerced as if from the CSV) or already typed.
#
# Returns a list of class "mm_pcfg". Read it; do not edit it. The one supported
# mutation is with_patch().
resolve_config <- function(preset = "default",
                           csv = default_preset_csv(),
                           overrides = list()) {
  # A list, not a character vector: an override may already carry its final
  # type, and assigning one into a character vector would coerce it back.
  raw <- as.list(read_preset(csv, preset))

  # Overrides are merged as raw rows so that a CSV value and a command-line
  # value travel the same validation path.
  spec <- pipeline_spec()
  for (key in names(overrides)) {
    full <- if (grepl("^(gms|pipeline)\\$", key)) key else paste0("pipeline$", key)
    if (!grepl("^gms\\$", full) && !sub("^pipeline\\$", "", full) %in% names(spec)) {
      log_die("override '", key, "': unknown pipeline key. Known keys: ",
              paste(names(spec), collapse = ", "))
    }
    raw[[full]] <- overrides[[key]]
  }

  bad <- names(raw)[!grepl("^(gms|pipeline)\\$", names(raw))]
  if (length(bad)) {
    log_die("preset '", preset, "' in ", csv, " has rows outside the gms$/pipeline$ namespaces: ",
            paste(bad, collapse = ", "))
  }

  # pipeline$ rows
  pipe_raw <- raw[grepl("^pipeline\\$", names(raw))]
  names(pipe_raw) <- sub("^pipeline\\$", "", names(pipe_raw))
  unknown <- setdiff(names(pipe_raw), names(spec))
  if (length(unknown)) {
    log_die("preset '", preset, "' sets unknown pipeline keys: ", paste(unknown, collapse = ", "),
            ". Declare them in pipeline_spec() or remove them.")
  }
  pipe <- pipeline_defaults()
  for (key in names(pipe_raw)) {
    pipe[[key]] <- .coerce(pipe_raw[[key]], spec[[key]]$type, key)
  }

  # gms$ rows
  gms_raw <- raw[grepl("^gms\\$", names(raw))]
  names(gms_raw) <- sub("^gms\\$", "", names(gms_raw))
  clash <- intersect(names(gms_raw), stage_controlled_switches())
  if (length(clash)) {
    log_die("preset '", preset, "' sets gms switches that stage_cfg() owns: ",
            paste(clash, collapse = ", "),
            ". Their value is stage logic; set the corresponding pipeline$ key instead.")
  }
  gms <- lapply(gms_raw, .coerce_gms)

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

.validate_pcfg <- function(pcfg) {
  need_chr <- c("ssp", "identifier", "input_regional", "input_cellular",
                "input_validation", "input_additional", "protect_scenario",
                "protect_scenario_step1", "biodem_scenario_step1",
                "ghg_price_scenario_step2", "ghg_price_scenario_suffix",
                "qos", "patch_repo", "magpie_public_repo",
                "matrix_ssp_scen", "matrix_sdg_scen", "matrix_run_suffix",
                "matrix_basename")
  for (key in need_chr) {
    if (!nzchar(pcfg[[key]])) log_die("pipeline$", key, " must not be empty")
  }

  # Required, not defaulted: the patch generators validate tau and the f56
  # trajectories against the model years of this token. A preset that omitted it
  # would have to fall back on the $setglobal currently in main.gms, which
  # apply_cfg() rewrites on every run -- so the horizon a patch is checked
  # against would be whatever the last run left behind, possibly another
  # preset's.
  if (is.null(pcfg$gms[["c_timesteps"]]) || !nzchar(as.character(pcfg$gms[["c_timesteps"]]))) {
    log_die("preset '", pcfg$preset, "' in ", pcfg$csv, " sets no gms$c_timesteps. ",
            "It is a required row: the patch generators validate their output against the ",
            "model years of this token, and inferring it from the working tree would tie a ",
            "patch to whichever run last rewrote main.gms.")
  }

  for (key in c("be_prices", "ghg_prices")) {
    v <- pcfg[[key]]
    if (!length(v))            log_die("pipeline$", key, " must not be empty")
    if (any(v < 0))            log_die("pipeline$", key, " must be non-negative")
    if (anyDuplicated(v))      log_die("pipeline$", key, " has duplicate levels")
    if (any(abs(v - round(v)) > 1e-9)) {
      log_die("pipeline$", key, " must be integer-valued: the levels appear in folder tokens and scenario column names")
    }
  }

  if (pcfg$currency_2005_to_2017 <= 0) log_die("pipeline$currency_2005_to_2017 must be positive")
  if (pcfg$nonco2_price_cap_usd17_tc <= 0) log_die("pipeline$nonco2_price_cap_usd17_tc must be positive (USD17MER per tC)")
  if (pcfg$mp_substitution < 0 || pcfg$mp_substitution > 100) {
    log_die("pipeline$mp_substitution is a percent in [0, 100], got ", pcfg$mp_substitution)
  }
  if (!length(pcfg$output_modules)) log_die("pipeline$output_modules must name at least one output script")
  if (!length(pcfg$slurm_modules))  log_die("pipeline$slurm_modules must name at least one module")

  preflag(pcfg)   # validates bii_target against the naming contract
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
      log_die("stage ", stage, " needs its patch tarball. Build it with the stage-",
              stage - 1L, ".5 generator and register it with with_patch(pcfg, ", stage, ", <name>).")
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
      log_die("stage_cfg: bioenergy price ", be, " is not in pipeline$be_prices (",
              paste(pcfg$be_prices, collapse = ", "), ")")
    }
  }
  if (stage == 3L) {
    if (is.null(ghg)) log_die("stage_cfg: stage 3 needs a GHG price level")
    if (!any(abs(pcfg$ghg_prices - as.numeric(ghg)) < 1e-9)) {
      log_die("stage_cfg: GHG price ", ghg, " is not in pipeline$ghg_prices (",
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

  # Stage logic. Read the golden-master note in this file's header before
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
    cfg$info$flag2 <- preflag(pcfg)
  }

  cfg$results_folder <- results_folder(pcfg, stage)
  cfg
}
