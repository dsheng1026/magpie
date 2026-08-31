# |  Run MAgPIE on what MESSAGE asked for.
# |
# |  Takes the two files messageix/feedback_prep/ produced out of a MESSAGE run
# |  made with the emulator under test, packs them the way every other stage packs
# |  its inputs, and starts one MAgPIE run against them:
# |
# |    feedback_prep output/  f56_pollutant_prices.cs3  (MESSAGE's GHG prices)
# |                           f60_bioenergy_dem.cs3     (MESSAGE's bioenergy demand)
# |      ->  pack_patch()  ->  patch_input/<experiment>_demand_<hash>.tgz
# |      ->  stage_cfg(pcfg, 3)  with the two scenario columns replaced
# |      ->  start_run()
# |
# |  It is a demand-phase run in every respect except which two columns it selects,
# |  so it borrows the demand phase's own configuration rather than assembling a
# |  new one. That is deliberate: a feedback run configured differently from the
# |  runs it is checking would compare two things that were never comparable.
# |  Because stage_cfg() wants a point of the sweep grid, the run takes the first
# |  bioenergy and GHG price level of the experiment and then overwrites both
# |  scenario columns; neither level reaches the run.
# |
# |  Scope: this runs MAgPIE and leaves the comparison to compare_land_use.R and
# |  to a person. Nothing here decides whether the linkage is good enough.
# |
# |  Usage, from the MAgPIE model root:
# |    Rscript messageix/feedback_run/start_feedback_run.R --experiment default
# |
# |    --prep-dir DIR     directory holding the feedback_prep output; default
# |                       messageix/feedback_prep/output/<experiment>
# |    --column NAME      the scenario column feedback_prep wrote (default "feedback")
# |    --title NAME       run title (default "feedback_<column>")
# |    --experiment NAME  an experiment of messageix/experiments.R
# |    --set key=value    override one setting; repeatable
# |    --dry-run          assemble and narrate the cfg, stop short of start_run()
# |    --help
# |
# |  Every option is accepted as --key value and as --key=value.
# |
# |  Interface
# |    feedback_files(dir)                 -> named chr; the two cs3 files, checked
# |    pack_feedback(pcfg, files)          -> chr(1); patch tarball name
# |    feedback_cfg(pcfg, column, title)   -> list; a complete MAgPIE cfg
# |    start_feedback_run(pcfg, ...)       -> chr(1); the run folder
# |
# |  Dependencies: scripts/start_functions.R for start_run(), and
# |  messageix/R/pack_price.R for pack_patch(), which brings the messageix/R/
# |  layer with it. Run from the MAgPIE model root.

if (!exists("pack_patch", mode = "function")) source("messageix/R/pack_price.R")
if (!exists("start_run", mode = "function"))  source("scripts/start_functions.R")

# The two files feedback_prep wrote, under the names MAgPIE's module manifests
# claim. A patch tarball carries bare names at the archive root; a renamed file
# unpacks to nowhere and the run proceeds on the base tarball's data.
FEEDBACK_FILES <- c(f56 = "f56_pollutant_prices.cs3",
                    f60 = "f60_bioenergy_dem.cs3")

feedback_files <- function(dir) {
  if (!dir.exists(dir)) {
    log_die("--prep-dir: ", dir, " does not exist. Run ",
            "Rscript messageix/feedback_prep/feedback_prep.R first")
  }
  paths <- file.path(dir, FEEDBACK_FILES)
  names(paths) <- names(FEEDBACK_FILES)
  absent <- paths[!file.exists(paths)]
  if (length(absent)) {
    log_die("--prep-dir: ", dir, " holds no ", basename(absent),
            ". Run messageix/feedback_prep/feedback_prep.R to produce it")
  }
  paths
}

# Pack both files into one demand-stage patch tarball. Content-hashed, so a
# rebuilt file gets a new name and MAgPIE unpacks it instead of reusing the last
# run's data off the strength of a matching name in input/info.txt.
pack_feedback <- function(pcfg, files) {
  tarball <- pack_patch(unname(files), pcfg, 3)
  log_step("PACK", tarball)
  tarball
}

# The demand phase's own configuration with the two scenario columns replaced.
feedback_cfg <- function(pcfg, column, title) {
  be  <- pcfg$prices_bioenergy[1L]
  ghg <- pcfg$prices_ghg[1L]
  cfg <- stage_cfg(pcfg, 3, be = be, ghg = ghg)

  cfg$gms$c56_pollutant_prices          <- column
  # In lockstep with c56_pollutant_prices, for the reason stage_cfg() gives:
  # left on another scenario it is inert only while policy_countries56 is full.
  cfg$gms$c56_pollutant_prices_noselect <- column
  cfg$gms$c60_2ndgen_biodem             <- column

  cfg$title <- title
  cfg$results_folder <- file.path("output", pcfg$identifier, "feedback", ":title:")
  cfg
}

start_feedback_run <- function(pcfg, prep_dir = NULL, column = "feedback",
                               title = NULL, dry_run = FALSE) {
  assert_magpie_root()
  if (is.null(prep_dir)) {
    prep_dir <- file.path("messageix", "feedback_prep", "output", pcfg$experiment)
  }
  if (is.null(title)) title <- paste0("feedback_", column)

  files <- feedback_files(prep_dir)
  # Both columns have to be in the files before a run selects them; GAMS finds
  # out hours later and one run at a time.
  for (side in names(files)) {
    have <- magclass::getNames(magclass::read.magpie(files[[side]]))
    parts <- strsplit(have, ".", fixed = TRUE)
    scen <- unique(vapply(parts, function(p) p[length(p)], character(1)))
    if (!column %in% scen) {
      log_die(basename(files[[side]]), " carries no scenario column '", column,
              "'. It has: ", scen, ". Name the column with --column, or re-run ",
              "feedback_prep with --column=", column)
    }
  }

  pcfg <- with_patch(pcfg, 3, pack_feedback(pcfg, files))
  cfg <- feedback_cfg(pcfg, column, title)

  log_banner("feedback run", list(
    experiment = pcfg$experiment,
    title      = cfg$title,
    column     = column,
    patch      = cfg$input[["patch"]],
    folder     = cfg$results_folder))

  if (isTRUE(dry_run)) {
    log_step("SKIP", "start_run() not called for ", cfg$title, " (--dry-run)")
  } else {
    start_run(cfg, codeCheck = FALSE)
    log_step("SUBMIT", cfg$title)
  }
  sub(":title:", cfg$title, cfg$results_folder, fixed = TRUE)
}

# ---- command line -----------------------------------------------------------

if (invoked_directly("start_feedback_run.R")) {
  usage <- paste(sub("^# \\|", "", grep("^# \\|",
                 readLines("messageix/feedback_run/start_feedback_run.R"),
                 value = TRUE)), collapse = "\n")
  flags <- parse_flags(commandArgs(trailingOnly = TRUE),
                       known = c("prep-dir", "column", "title", "experiment"),
                       flags = c("help", "dry-run"), repeatable = c("set"),
                       usage = usage)
  if (isTRUE(flags$help)) { log_report(usage); quit(status = 0) }
  pcfg <- config_from_flags(flags, cli_overrides(flags$set))
  start_feedback_run(pcfg, prep_dir = flags[["prep-dir"]],
                     column = if (is.null(flags$column)) "feedback" else flags$column,
                     title = flags$title, dry_run = isTRUE(flags[["dry-run"]]))
}
