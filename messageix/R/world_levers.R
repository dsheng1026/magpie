# |  The levers a narrative may pull, and how each one reaches the model.
# |
# |  One block per lever, and everything about that lever is in its block: what
# |  it means and in what unit, what values it may take, how it reaches MAgPIE,
# |  and what it defaults to. Adding a lever is adding a block; nothing else in
# |  the pipeline holds a list of them, and no document restates them: a lever's
# |  block is where it is documented. narrative() accepts exactly what is
# |  registered here.
# |
# |  A lever is a property of the world the runs are made in. The world here is
# |  the land system: what is eaten and grown, how land is protected, how
# |  productive it is, what it costs to change. Levers outside the land system --
# |  carbon capture, transport, buildings -- belong to MESSAGEix, which this
# |  pipeline supplies rather than models.
# |
# |  Three mechanism classes, which is the whole of how a lever can work. Four
# |  constructors below build the mapping that carries it there, because the
# |  switch class covers three of them:
# |
# |    switch      it becomes a value on cfg$gms. Most levers are this, and it is
# |                the one class with more than one constructor. to_switch() puts
# |                the value straight onto a named MAgPIE switch; by_phase_logic()
# |                hands it to the phase logic in utils_config.R, because the
# |                value differs by phase or is paired with a second switch; and
# |                by_scenario_config() selects one of MAgPIE's own stock scenario
# |                configurations. All three are declared here; the phase logic is
# |                not free to invent a switch of its own.
# |    data        it changes the input files the runs read, by contributing
# |                files to the tarball packed for one phase. The lever says
# |                which phase and supplies the function that writes the files;
# |                the packing scripts call it. No data lever is registered yet,
# |                and the class exists so that the first one is a block here
# |                rather than a change to the packing scripts.
# |    structural  it changes the shape of the world rather than a value in it --
# |                which regions the model solves for, and therefore which input
# |                tarballs and which region names travel with them. region_set
# |                is the one of these, and it resolves through the region-set
# |                lookup in pipeline_infrastructure.R.
# |
# |  What is NOT a lever. Every setting of this pipeline belongs to one of three
# |  owners, and this is where that split is written down:
# |
# |    the experiment    the world its runs are made in -- the levers below --
# |                      and the sampling plan, the price levels the two sweeps
# |                      visit. Written in messageix/experiments.R.
# |    infrastructure    everything operational: the queue, the modules, how long
# |                      the pipeline waits, and the constants that are properties
# |                      of the linkage rather than of one experiment. Declared in
# |                      messageix/R/pipeline_infrastructure.R, where each also
# |                      carries the environment variable and the "--set" that
# |                      override it.
# |    derived           what the pipeline works out for itself: the region code,
# |                      the output folder, the matrix name, the input tarballs.
# |                      Nothing may set these -- two experiments would then be
# |                      able to choose one another's folders.
# |
# |  Where the stage numbers come from: a stage is 1, 2 or 3 and the phase names
# |  are calibrate, price and demand. The two are paired in
# |  messageix/R/utils_paths.R, which builds every run folder and file name from
# |  them.
# |
# |  Interface
# |    world_levers()               -> named list of lever records
# |    lever_names()                -> chr; every registered lever
# |    lever_of(name)               -> the record, or a stop naming what exists
# |    levers_of_class(class)       -> named list; the levers of one mechanism class
# |    lever_defaults()             -> named list; each lever's default value
# |    lever_switch_map()           -> named chr; lever -> the switch it becomes
# |    lever_switch_scope()         -> named chr; switch -> the phases it applies at
# |    lever_stage_switches()       -> chr; switches the phase logic sets for a lever
# |    lever_check(name, value)     -> invisible(TRUE); the lever's own value check
# |    lever_patch_files(pcfg, stage, stage_dir) -> chr; files the data levers contribute
# |
# |  Dependencies: base R and messageix/R/utils_log.R.

if (!exists("log_die", mode = "function")) source("messageix/R/utils_log.R")

# ---- how a lever reaches the model ------------------------------------------

# The lever's value goes straight onto a named MAgPIE switch.
#
#   phases  "all" applies it to every phase; "sweeps" applies it to the price
#           and demand sweeps only, leaving the calibration run at MAgPIE's own
#           default -- the calibration run is a reference run, not a member of
#           the training set, and several settings are deliberately absent there.
#
# What it records is the stage numbers the switch is set at, written as digits:
# "123" for every phase, "23" for the two sweeps. utils_config.R reads the digits
# apart again when it assembles one stage's config.
to_switch <- function(switch, phases = c("all", "sweeps")) {
  phases <- match.arg(phases)
  list(kind = "direct", switch = switch, scope = if (phases == "all") "123" else "23")
}

# The phase logic in utils_config.R reads the lever and decides what to do with
# it, because its value differs by phase or is paired with another switch.
# `where` says, in one line, what that logic does -- the logic itself stays in
# stage_cfg(), which is where the golden runs are reproduced.
by_phase_logic <- function(switch, where) {
  list(kind = "phase", switch = switch, where = where)
}

# The lever selects one of MAgPIE's own stock scenario configurations, applied
# before anything else this pipeline sets.
by_scenario_config <- function() list(kind = "scenario")

# The lever selects a region set: the input tarballs and the region-name table
# that travel together, listed in pipeline_infrastructure.R.
by_region_set <- function() list(kind = "region")

# The lever contributes files to the tarball packed for one phase.
#
#   phase       "price" or "demand": which phase's inputs the files go into
#   contribute  function(pcfg, stage_dir) -> chr; writes its files into
#               stage_dir and returns their paths. It is called on every build of
#               that phase's inputs, whatever the lever's value, so a lever
#               sitting at its default returns character(0) and changes nothing.
to_patch_files <- function(phase = c("price", "demand"), contribute) {
  phase <- match.arg(phase)
  if (!is.function(contribute)) log_die("to_patch_files: contribute must be a function")
  list(kind = "patch", stage = if (phase == "price") 2L else 3L, contribute = contribute)
}

# One lever.
#
#   meaning  one line: what it is, and in what unit
#   values   what it may be, in words -- the same sentence the reader gets
#   type     "chr", "num", "lgl", "chr_vec", "num_vec"
#   default  the value a narrative that does not name it takes
#   class    "switch", "data" or "structural"
#   mapping  one of the constructors above
#   check    optional function(value); stop with log_die when the value is out
#            of range. Types are checked for every lever already; this is for
#            the range or the set of allowed values.
lever <- function(meaning, values, type, default, class, mapping, check = NULL) {
  classes <- c("switch", "data", "structural")
  if (!class %in% classes) {
    log_die("a lever's class is one of ", paste(classes, collapse = ", "), ", got '", class, "'")
  }
  if (!is.list(mapping) || is.null(mapping$kind)) {
    log_die("a lever's mapping comes from to_switch(), by_phase_logic(), by_scenario_config(), ",
            "by_region_set() or to_patch_files()")
  }
  # Class and mapping have to agree, or a lever would be registered as one thing
  # and reach the model as another. The switch class is the one with a choice of
  # mapping; the other two have exactly one each.
  if (identical(class, "data") && !identical(mapping$kind, "patch")) {
    log_die("a data lever changes the files the runs read, so its mapping is to_patch_files()")
  }
  if (identical(class, "structural") && !identical(mapping$kind, "region")) {
    log_die("a structural lever changes which regions the model solves for, so its mapping is ",
            "by_region_set()")
  }
  list(meaning = meaning, values = values, type = type, default = default,
       class = class, mapping = mapping, check = check)
}

# ---- the levers -------------------------------------------------------------

world_levers <- function() {
  list(

    ssp = lever(
      meaning = "which shared socioeconomic pathway the runs follow -- population, income and demand growth, and the first token of every matrix name",
      values  = "SSP1 to SSP5: a column of MAgPIE's own config/scenario_config.csv",
      type    = "chr",
      default = "SSP2",
      class   = "switch",
      mapping = by_scenario_config()),

    region_set = lever(
      meaning = "the set of world regions the model solves for",
      values  = "a region set the pipeline knows; R12 is the only one so far",
      type    = "chr",
      default = "R12",
      class   = "structural",
      mapping = by_region_set()),

    bii_target = lever(
      meaning = "share of the biodiversity intactness index to maintain, as a fraction of 1",
      values  = "in [0, 1). Experiments tested so far 0 / 0.7 / 0.74 / 0.78",
      type    = "num",
      default = 0,
      class   = "switch",
      mapping = by_phase_logic("s44_bii_target",
                               "set in the calibrate phase and the price and demand sweeps, paired with c44_bii_decrease, which permits BII loss exactly when no target is imposed"),
      check   = function(value) {
        if (is.na(value) || value < 0 || value >= 1) {
          log_die("bii_target is a share of the biodiversity intactness index and lies in ",
                  "[0, 1), got ", value)
        }
      }),

    mp_substitution = lever(
      meaning = "percent of ruminant meat and dairy demand met by microbial protein instead",
      values  = "0 to 100 percent. Experiments tested so far 0 / 25 / 50 / 75",
      type    = "num",
      default = 0,
      class   = "switch",
      mapping = by_phase_logic("s15_rumdairy_scp_substitution",
                               "set in the price and demand sweeps, divided by 100 on the way in because MAgPIE takes a share"),
      check   = function(value) {
        if (value < 0 || value > 100) {
          log_die("mp_substitution is a percent in [0, 100], got ", value)
        }
      }),

    protect_scenario = lever(
      meaning = "which land protection scenario applies in the two sweeps",
      values  = "a MAgPIE protection scenario, e.g. none, BH, WDPA",
      type    = "chr",
      default = "none",
      class   = "switch",
      mapping = by_phase_logic("c22_protect_scenario", "set in the price and demand sweeps")),

    protect_scenario_step1 = lever(
      meaning = "which land protection scenario the reference land-use intensity trajectory is calibrated under",
      values  = "a MAgPIE protection scenario, e.g. none, BH, WDPA. MAgPIE's own default is none, per the sibling protect_scenario lever",
      type    = "chr",
      default = "none",
      class   = "switch",
      mapping = by_phase_logic("c22_protect_scenario", "set in the calibrate phase")),

    yields_scenario = lever(
      meaning = "whether crop yields carry climate change impacts",
      values  = "nocc excludes them, which is defensible at 1-1.5 degC of warming; cc includes them, and scenarios approaching 2 degC should use it",
      type    = "chr",
      default = "nocc",
      class   = "switch",
      mapping = to_switch("c14_yields_scenario")),

    tc_cost = lever(
      meaning = "how costly yield-increasing technological change is",
      values  = "high / medium / low. high makes intensifying existing cropland expensive, so the model leans more on expanding it; MAgPIE's default is medium",
      type    = "chr",
      default = "medium",
      class   = "switch",
      mapping = to_switch("c13_tccost")),

    cropland_max_growth = lever(
      meaning = "ceiling on how fast cropland may expand in a region, as a fraction per year",
      values  = "positive; 0.02 caps it at 2 percent per year, and Inf lifts the brake entirely as MAgPIE's own default does",
      type    = "num",
      default = 0.02,
      class   = "switch",
      mapping = to_switch("s30_annual_max_growth", phases = "sweeps"),
      check   = function(value) {
        if (value <= 0) {
          log_die("cropland_max_growth is a fraction per year and must be positive; ",
                  "Inf lifts the brake entirely")
        }
      }),

    bii_missing_cost = lever(
      meaning = "cost charged where the biodiversity intactness index has no data, USD17MER",
      values  = "non-negative; 1e7 is ten times MAgPIE's default, so the gaps in that data are not the cheapest place for the model to put land-use pressure",
      type    = "num",
      default = 10000000,
      class   = "switch",
      mapping = to_switch("s44_cost_bii_missing", phases = "sweeps"),
      check   = function(value) {
        if (value < 0) log_die("bii_missing_cost must be non-negative (USD17MER)")
      }),

    nonco2_price_cap_usd17_tc = lever(
      meaning = "cap on the price applied to CH4 and N2O, USD17MER per tC",
      values  = "positive; 200 is roughly 55 USD17 per tCO2, above which empirical abatement-cost curves show very little non-CO2 abatement, and it keeps food prices plausible under strong mitigation. MAgPIE's default is 4920. 734 is the Earth Commission target of 200 USD2017 per tCO2 (734 = 200 * 3.67)",
      type    = "num",
      default = 734,
      class   = "switch",
      mapping = by_phase_logic("s56_limit_ch4_n2o_price",
                               "set in the demand sweep only: the calibration run is made under a near-term-policy price path and the price sweep runs at zero GHG price, where a cap is inert"),
      check   = function(value) {
        if (value <= 0) log_die("nonco2_price_cap_usd17_tc must be positive (USD17MER per tC)")
      })

    # ---- registering a new lever ---------------------------------------------
    #
    # A switch lever whose value is the same at every phase is one block like the
    # ones above and nothing else: a meaning, what it may be, its default, and
    # the switch it becomes. Everything that reads this registry reads it whole,
    # so nothing else has to change. A share of food thrown away would look like
    # this:
    #
    # ,
    # food_waste_share = lever(
    #   meaning = "share of the food bought that is thrown away, as a fraction of 1",
    #   values  = "in [0, 1); MAgPIE's own default is the one this replaces",
    #   type    = "num",
    #   default = 0.2,
    #   class   = "switch",
    #   mapping = to_switch("s15_food_waste_share"),
    #   check   = function(value) {
    #     if (value < 0 || value >= 1) {
    #       log_die("food_waste_share is a share of the food bought and lies in [0, 1)")
    #     }
    #   })
    #
    # A switch whose value differs by phase, or which has to move a second switch
    # with it, is a by_phase_logic() lever -- and that one is not one block. The
    # block declares the switch and says in a line what the phase logic does with
    # it; the logic itself is an edit to stage_cfg() in
    # messageix/R/utils_config.R. That edit is one line inside the block for the
    # phase concerned, assigning cfg$gms$<switch> from the lever's value beside
    # the assignments already there. bii_target above is the example to copy: its
    # block names s44_bii_target, and stage_cfg() sets that switch and
    # c44_bii_decrease together in the two sweeps. Read the note on the golden
    # runs at the top of utils_config.R before changing anything in that
    # function -- those assignments are what reproduces them.
    #
    # A data lever changes the files the runs read rather than a value in the
    # config, so it also supplies the function that writes those files into the
    # tarball packed for one phase. A ceiling on food prices would look like
    # this -- the block is complete; only the file writing is missing:
    #
    # ,
    # food_price_cap_usd17 = lever(
    #   meaning = "ceiling on the regional food price index the model may reach, USD17MER per tDM",
    #   values  = "positive, or Inf for no ceiling",
    #   type    = "num",
    #   default = Inf,
    #   class   = "data",
    #   mapping = to_patch_files("demand", function(pcfg, stage_dir) {
    #     # No ceiling asked for: contribute nothing, and the packed tarball is
    #     # byte-for-byte what it would have been.
    #     if (!is.finite(pcfg$food_price_cap_usd17)) return(character(0))
    #     # Write the file MAgPIE reads for this ceiling into stage_dir under its
    #     # bare name -- a patch tarball is flat -- and return the path.
    #     stop("food_price_cap_usd17: not implemented; write the price-cap file here")
    #   }),
    #   check = function(value) {
    #     if (value <= 0) log_die("food_price_cap_usd17 must be positive (USD17MER per tDM)")
    #   })
    #
    # A different region composition is not a lever at all: it is one entry in
    # region_sets() in messageix/R/pipeline_infrastructure.R pairing the input
    # tarballs with a region-name table, and then region_set = "<name>".

  )
}

# ---- reading the registry ---------------------------------------------------

lever_names <- function() names(world_levers())

lever_of <- function(name) {
  levers <- world_levers()
  if (!name %in% names(levers)) {
    log_die("'", name, "' is not a lever of the world. The levers are: ",
            paste(names(levers), collapse = ", "),
            ". Adding one is a block in messageix/R/world_levers.R.")
  }
  levers[[name]]
}

# Every lever working through one mechanism.
levers_of_class <- function(class) {
  levers <- world_levers()
  levers[vapply(levers, function(x) identical(x$class, class), logical(1))]
}

# Each lever's default value, for the settings a narrative does not name.
lever_defaults <- function() lapply(world_levers(), `[[`, "default")

# The levers that become a named MAgPIE switch directly, and the switch each
# one becomes. The phase-logic levers are not here: their switch is assigned by
# stage_cfg(), which knows what to do with the value.
lever_switch_map <- function() {
  direct <- Filter(function(x) identical(x$mapping$kind, "direct"), world_levers())
  vapply(direct, function(x) x$mapping$switch, character(1))
}

# Which phases each of those switches applies at: "123" everywhere, "23" in the
# two sweeps only.
lever_switch_scope <- function() {
  direct <- Filter(function(x) identical(x$mapping$kind, "direct"), world_levers())
  stats::setNames(vapply(direct, function(x) x$mapping$scope, character(1)),
                  vapply(direct, function(x) x$mapping$switch, character(1)))
}

# The switches the phase logic sets on a lever's behalf. A narrative may not set
# these itself: their value is phase logic, and one written into an experiment
# would either be ignored or stop reproducing the golden runs.
lever_stage_switches <- function() {
  by_phase <- Filter(function(x) identical(x$mapping$kind, "phase"), world_levers())
  unique(vapply(by_phase, function(x) x$mapping$switch, character(1)))
}

# The levers a switch belongs to, for the message that refuses it, or an empty
# vector where no lever names it.
#
# Every owner is returned, not the first one found: one MAgPIE switch can be
# owned by two levers, one per phase. c22_protect_scenario is the case --
# protect_scenario sets it in the two sweeps, protect_scenario_step1 in the
# calibrate phase -- and a message naming only one of them would send a reader to
# the wrong lever half the time.
lever_owning_switch <- function(switch) {
  levers <- world_levers()
  owners <- character(0)
  for (name in names(levers)) {
    mapping <- levers[[name]]$mapping
    if (mapping$kind %in% c("direct", "phase") && identical(mapping$switch, switch)) {
      owners <- c(owners, name)
    }
  }
  owners
}

# The lever's own check on a value, where it has one. Types are checked before
# this is reached, so a check may assume the declared type.
lever_check <- function(name, value) {
  check <- lever_of(name)$check
  if (is.function(check)) check(value)
  invisible(TRUE)
}

# ---- what the data levers contribute ----------------------------------------

# The files the data levers add to the tarball being packed for one phase.
# Called by the packing scripts with the directory the tarball is staged in;
# every lever registered for that phase is asked, whatever its value, and one
# sitting at its default returns nothing.
#
# The files have to land in the staging directory under bare names: MAgPIE
# unpacks a patch tarball flat and sends each file to the module folder whose
# own manifest claims it, so a file written anywhere else would not travel.
lever_patch_files <- function(pcfg, stage, stage_dir) {
  contributors <- Filter(function(x) identical(x$mapping$kind, "patch") &&
                                     identical(x$mapping$stage, as.integer(stage)),
                         world_levers())
  files <- character(0)
  for (name in names(contributors)) {
    produced <- contributors[[name]]$mapping$contribute(pcfg, stage_dir)
    if (!length(produced)) next
    if (!is.character(produced)) {
      log_die("lever '", name, "' returned something other than file paths for the packed inputs")
    }
    absent <- produced[!file.exists(produced)]
    if (length(absent)) {
      log_die("lever '", name, "' says it wrote ", paste(absent, collapse = ", "),
              " into the packed inputs, and those files are not there")
    }
    in_dir <- normalizePath(dirname(produced), mustWork = FALSE) ==
              normalizePath(stage_dir, mustWork = FALSE)
    outside <- produced[!in_dir]
    if (length(outside)) {
      log_die("lever '", name, "' wrote ", paste(outside, collapse = ", "),
              " outside the staging directory ", stage_dir,
              "; a packed tarball is flat, so every file has to be written into it")
    }
    log_step("PACK", "lever '", name, "' adds ", paste(basename(produced), collapse = ", "))
    files <- c(files, produced)
  }
  files
}
