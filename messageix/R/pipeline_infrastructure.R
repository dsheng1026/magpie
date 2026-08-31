# |  Everything the pipeline needs that an experiment does not say. Who owns
# |  which setting is stated once, in the header of messageix/R/world_levers.R;
# |  this is the file two of those owners live in.
# |
# |  Three kinds of value:
# |
# |    region set     which input tarballs and which region-name table a region
# |                   set is made of. One entry per region set.
# |    infrastructure operational settings -- queue, modules, waiting, output
# |                   names -- plus a handful of science-adjacent constants that
# |                   are properties of the linkage rather than of an experiment.
# |                   Each has a built-in default, an environment variable that
# |                   overrides it per machine, and a "--set key=value" that
# |                   overrides it for one command.
# |    derivation     the rules that turn an experiment into the names its runs
# |                   and its matrix carry. Derived values are read-only: setting
# |                   one is an error, because two experiments could then land on
# |                   the same folder.
# |
# |  Values only. Which of these settings becomes a MAgPIE switch, and at which
# |  stages, is part of assembling a run configuration and sits with the rest of
# |  it in messageix/R/utils_config.R.
# |
# |  Interface
# |    region_sets()                        -> named list; every region set known
# |    region_set_inputs(set)               -> list(tarballs, region_names)
# |    infrastructure_spec()                -> named list of list(default, type, env, unit)
# |    infrastructure_defaults()            -> named list; defaults with environment overrides applied
# |    derived_keys()                       -> chr; keys nothing may set
# |    regionscode_of(tarball)              -> chr(1); the region set's code, out of the tarball name
# |    experiment_identifier(regionscode, experiment) -> chr(1); the output folder name
# |    experiment_matrix_basename(ssp, experiment)    -> chr(1); the matrix CSV name, no extension
# |
# |  Dependencies: base R and messageix/R/utils_log.R.

if (!exists("log_die", mode = "function")) source("messageix/R/utils_log.R")

# ---- region sets ------------------------------------------------------------

# A region set is the set of world regions MAgPIE solves for. Everything that
# has to agree with it travels together here: the four input tarballs carrying
# data cut to those regions, and the table translating MAgPIE's region codes
# into the names MESSAGEix uses. An experiment names the set; it never names the
# files.
#
# Adding a region set is one entry here plus its region-name table in
# messageix/data/. Nothing else in the pipeline knows region sets exist.
region_sets <- function() {
  list(
    R12 = list(
      # MESSAGE's twelve world regions, MAgPIE input revision 4.119.
      tarballs = c(
        # Everything MAgPIE reads at the level of its world regions.
        regional   = "rev4.119_5ff27be8_magpie.tgz",
        # Yields, water and land at cluster resolution. The name also records
        # the climate forcing (ssp245) and the vegetation run behind it, so a
        # different SSP needs a different cellular tarball, not just a different
        # ssp setting.
        cellular   = "rev4.119_5ff27be8_1b5c3817_cellularmagpie_c200_MRI-ESM2-0-ssp245_lpjml-8e6c5eb1.tgz",
        # Historical reference data MAgPIE validates its own output against.
        validation = "rev4.119_5ff27be8_validation.tgz",
        # Supplementary data. Revision 4.62, where MAgPIE v4.11.0 would default
        # to 4.63; the pinned runs were made against 4.62.
        additional = "additional_data_rev4.62.tgz"),
      region_names = "region_names_R12.csv")
  )
}

# The tarballs and region-name table of one region set.
region_set_inputs <- function(set) {
  known <- region_sets()
  set <- as.character(set)[1L]
  if (!set %in% names(known)) {
    log_die("region_set '", set, "' is not a region set this pipeline knows. It knows: ",
            paste(names(known), collapse = ", "),
            ". Adding one is a new entry in messageix/R/pipeline_infrastructure.R plus its ",
            "region-name table in messageix/data/.")
  }
  known[[set]]
}

# ---- infrastructure ---------------------------------------------------------

# Every operational setting, with the environment variable that overrides it on
# a machine that needs something else. Types are those an experiment uses:
# "chr", "num", "lgl", "chr_vec", "num_vec".
#
# Resolution order: the default here, then the environment variable, then a
# "--set key=value" on the command line. The environment variable is for a
# machine ("this cluster has no priority queue"); --set is for one command.
infrastructure_spec <- function() {
  list(
    # --- MAgPIE switches that are properties of the linkage ---
    timesteps = list(
      default = "coup2110", type = "chr", env = "MAGPIE_MM_TIMESTEPS",
      unit = "cfg$gms$c_timesteps: which years the model solves for. coup2110 rather than MAgPIE's coup2100 because MESSAGEix runs to 2110. The patch steps check their output against the model years of this token"),
    bioenergy_dem_min = list(
      default = 0, type = "num", env = "MAGPIE_MM_BIOENERGY_DEM_MIN",
      unit = "mio. GJ per yr, cfg$gms$s60_2ndgen_bioenergy_dem_min in the price and demand sweeps. Zero so the low end of the demand sweep is not truncated; MAgPIE's default of 1 would put a floor under it"),
    bioenergy_1st_subsidy = list(
      default = 0, type = "num", env = "MAGPIE_MM_BIOENERGY_1ST_SUBSIDY",
      unit = "USD17MER per GJ, cfg$gms$s60_bioenergy_1st_subsidy in the price and demand sweeps. Must be zero, or it acts as a price floor underneath the bioenergy price sweep; MAgPIE's default is 6.5"),

    # --- science-adjacent constants of the linkage ---
    currency_2005_to_2017 = list(
      default = 1.23, type = "num", env = "MAGPIE_MM_CURRENCY_2005_TO_2017",
      unit = "USD2005 -> USD2017 MER deflator. It multiplies the bioenergy price sweep on the way into MAgPIE, and its reciprocal (0.81300813) converts prices back out again in MM_linkage_mapping.csv. It moves when MAgPIE's base year moves, so revisit it at every MAgPIE version bump -- and move both numbers together"),
    biodem_scenario_step1 = list(
      default = "R34M410-SSP2-NPi2025", type = "chr", env = "MAGPIE_MM_BIODEM_SCENARIO_STEP1",
      unit = "cfg$gms$c60_2ndgen_biodem in the calibrate phase: the business-as-usual second-generation bioenergy demand path the reference land-use intensity trajectory is calibrated against"),
    ghg_price_scenario_step2 = list(
      default = "SSPDB-SSP2-Ref-MESSAGE-GLOBIOM", type = "chr", env = "MAGPIE_MM_GHG_PRICE_SCENARIO_STEP2",
      unit = "cfg$gms$c56_pollutant_prices in the price sweep. This one is zero in every region and every period, so the bioenergy price is the only signal that sweep varies"),
    ghg_price_scenario_suffix = list(
      default = "exp2110", type = "chr", env = "MAGPIE_MM_GHG_PRICE_SCENARIO_SUFFIX",
      unit = "suffix on the demand sweep's GHG price scenario names, recording how the trajectory is extended past the last reported year. exp2110: extended exponentially to 2110"),

    # --- inputs beyond the region set ---
    input_calibration = list(
      default = "", type = "chr", env = "MAGPIE_MM_INPUT_CALIBRATION",
      unit = "calibration tarball; empty means no calibration entry at all, which is what the pinned runs used"),

    # --- calibration reuse ---
    project = list(
      default = "", type = "chr", env = "MAGPIE_MM_PROJECT",
      unit = "when set, stage 1 (calibrate) writes to output/_calibration/<project> instead of the experiment's own folder, so experiments sharing this value and the same tau-determining settings reuse one calibration run. Empty keeps today's per-experiment folder"),

    # --- run control ---
    output_modules = list(
      default = c("output_check", "rds_report"), type = "chr_vec", env = "MAGPIE_MM_OUTPUT_MODULES",
      unit = "cfg$output, the post-processing scripts each run executes when it finishes"),
    force_replace = list(
      default = TRUE, type = "lgl", env = "MAGPIE_MM_FORCE_REPLACE",
      unit = "cfg$force_replace; TRUE lets a re-run overwrite a run folder of the same name, which the deterministic naming makes routine"),

    # --- waiting between stages ---
    poll_seconds = list(
      default = 300, type = "num", env = "MAGPIE_MM_POLL_SECONDS",
      unit = "seconds between checks while the pipeline waits for a phase's runs to finish. Each check reads the model status out of every finished run, so it is not free; runs take hours and five minutes resolves them finely enough"),
    timeout_hours = list(
      default = 48, type = "num", env = "MAGPIE_MM_TIMEOUT_HOURS",
      unit = "hours the pipeline waits for one phase of runs before giving up. 48 covers the 84-run demand sweep queued behind other work; a phase still unfinished after that needs a person, not more waiting"),

    # --- execution environment ---
    qos = list(
      default = "priority", type = "chr", env = "MAGPIE_MM_QOS",
      unit = "SLURM quality of service, which picks the submission script a run is handed to (scripts/run_submit/submit_<qos>.sh). priority is a PIK queue name; a site without it must override"),
    slurm_modules = list(
      default = c("defaults/piam/1.27", "R/4.3.2", "gcc/15.2.0"), type = "chr_vec", env = "MAGPIE_MM_MODULES",
      unit = "environment modules loaded before Rscript, in load order. gcc must come last: the compiled piam packages need a C++ runtime symbol that only this module's libstdc++ provides, and a module loaded after it puts an older one in front"),
    mail_user = list(
      default = "", type = "chr", env = "MAGPIE_MM_MAIL_USER",
      unit = "address SLURM mails job notifications to. Empty means job scripts carry no mail instructions at all"),
    patch_repo = list(
      default = "./patch_input", type = "chr", env = "MAGPIE_MM_PATCH_REPO",
      unit = "directory the patch steps write their tarballs into, and the first place MAgPIE looks for input tarballs"),
    magpie_public_repo = list(
      default = "https://rse.pik-potsdam.de/data/magpie/public", type = "chr", env = "MAGPIE_MM_PUBLIC_REPO",
      unit = "repository serving the base input tarballs"),

    # --- emulator matrix tagging ---
    matrix_sdg_scen = list(
      default = "noSDG_rcpref", type = "chr", env = "MAGPIE_MM_MATRIX_SDG_SCEN",
      unit = "value written into the SDGscen column of every matrix row")
  )
}

# Every infrastructure key with its default, and the environment variable in
# place of it where one is set. Values stay as they are written in the
# environment; resolving an experiment coerces them to the declared type.
infrastructure_defaults <- function() {
  spec <- infrastructure_spec()
  values <- lapply(names(spec), function(key) {
    from_env <- Sys.getenv(spec[[key]]$env, unset = "")
    if (nzchar(from_env)) from_env else spec[[key]]$default
  })
  stats::setNames(values, names(spec))
}

# ---- derived values ---------------------------------------------------------

# Keys the pipeline works out for itself. Nothing may set them: they are what
# keeps two experiments out of each other's folders, and an experiment that
# could choose its own would be able to choose another's.
derived_keys <- function() {
  c("regionscode", "identifier", "matrix_basename", "region_names",
    "input_regional", "input_cellular", "input_validation", "input_additional")
}

# The region set's code, read out of the regional tarball's name. MAgPIE stamps
# the code into the name when it builds the tarball, so the tarball an experiment
# runs on is the one thing that always knows which regions it holds.
regionscode_of <- function(tarball) {
  code <- sub("^rev[0-9.]+_([0-9a-z]+)_magpie\\.tgz$", "\\1", basename(tarball))
  if (identical(code, basename(tarball)) || !nzchar(code)) {
    log_die("cannot read a region code out of the regional tarball name '", tarball,
            "'. The name is expected to look like rev4.119_5ff27be8_magpie.tgz, and the ",
            "middle token is the code every output folder of this region set is named after.")
  }
  code
}

# The top-level output folder of one experiment. The region code is in it
# because runs at different region resolutions are different runs; the
# experiment's name is in it because the run folder names below carry only the
# position in the sweep, so two experiments would otherwise overwrite each
# other. The experiment named `golden` carries no name token, which is what
# keeps the pinned runs where they have always been.
experiment_identifier <- function(regionscode, experiment) {
  if (identical(experiment, "golden")) paste0("MESSAGEix_", regionscode)
  else paste0("MESSAGEix_", regionscode, "_", experiment)
}

# The matrix CSV one experiment writes, without the extension. The woodfuel half
# of the reduce phase appends _woodfuel to it.
experiment_matrix_basename <- function(ssp, experiment) {
  paste0("magpie_input_", ssp, "_", if (identical(experiment, "golden")) "ref" else experiment)
}
