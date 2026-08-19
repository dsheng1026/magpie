# |  Build the patch tarball stage 2 reads. This is the pipeline step patch_step2.
# |
# |  Stage 2 runs technological change exogenously (cfg$gms$tc = "exo"), which
# |  means it reads the tau trajectory out of an input file instead of solving
# |  for it. That file is f13_tau_scenario.csv and it is produced from the
# |  stage-1 reference run:
# |
# |      stage 1 fulldata.gdx  ->  ov_tau (level)  ->  f13_tau_scenario.csv
# |                            ->  patch_input/<preset>_price_<hash>.tgz
# |
# |  MAgPIE's exogenous technological-change realization expects
# |  f13_tau_scenario.csv to be region- and time-specific and to replace the
# |  placeholder file shipped in the base input tarballs. Exporting ov_tau at its
# |  "level" slice produces exactly that shape, and extract_tau() below does
# |  nothing more than write it out -- into a staging directory rather than
# |  straight into modules/13_tc/input/, because the file has to travel in a
# |  tarball.
# |
# |  Why a tarball and not a file copy. Unpacking input tarballs is also what
# |  regenerates MAgPIE's GAMS set files from the data that just arrived. A file
# |  dropped in by hand never goes through that machinery, so the model would not
# |  know it was there. A patch tarball is a plain .tgz in one of the directories
# |  cfg$repositories lists, holding bare file names at the archive root. MAgPIE
# |  unpacks it flat and sends each file to the module input/ folder whose own
# |  file manifest claims it; a directory prefix inside the archive hides the
# |  file from every manifest and it goes nowhere.
# |
# |  Why the name carries a digest. The tarball name ends in an 8-character
# |  digest of its contents (patch_tarball_name() in utils_paths.R). MAgPIE
# |  decides whether to unpack again by comparing tarball names against the list
# |  in input/info.txt, and never looks inside the files, so a rebuilt tarball
# |  reusing its old name leaves the model on the previous run's data and on
# |  stale generated set files, with nothing in any log to say so.
# |
# |  Usage
# |    Rscript messageix/patches/build_step2_patch.R [flags]     (from the model root)
# |
# |    --preset=NAME        narrative column of the narratives file (default "default")
# |    --csv=PATH           narratives file (default: default_preset_csv())
# |    --set=key=value      override one setting; repeatable. Any narrative or
# |                         infrastructure key; see messageix/docs/parameters.md
# |    --gdx=PATH           stage-1 fulldata.gdx, when it is not where the
# |                         preset's naming contract puts it
# |    --extra-files=DIR    also pack every file in DIR into the patch tarball,
# |                         alongside f13_tau_scenario.csv. Use it to carry a
# |                         correction to some other input file, for cases where
# |                         the pinned base tarball is out of date; with a current
# |                         base tarball it is not needed. The files go in at the
# |                         archive root, so DIR must hold files only and must not
# |                         contain a file of its own named f13_tau_scenario.csv.
# |    --help
# |
# |  Every option is accepted as --key=value and as --key value.
# |
# |  The tarball name is narrated as ">> PACK: ..." and repeated bare on the
# |  last line of stdout, so a shell caller can read it with `tail -n 1`.
# |  In-process callers source this file and use the return value:
# |
# |      pcfg <- resolve_config("default")
# |      pcfg <- with_patch(pcfg, 2, build_step2_patch(pcfg))
# |
# |  Interface
# |    cli_overrides(sets)                  -> named list for resolve_config(overrides=)
# |    timestep_years(timesteps)            -> chr; model years of a c_timesteps token
# |    configured_timesteps(pcfg)           -> chr(1); the preset's c_timesteps token
# |    pack_patch(files, pcfg, stage)       -> chr(1); tarball name, written to patch_repo
# |    extract_tau(gdx, out_csv)            -> magpie object; writes the csv
# |    validate_tau(tau, years)             -> invisible(TRUE)
# |    stage_extra_files(dir, stage_dir)    -> chr; staged copies of the extra files
# |    build_step2_patch(pcfg, ...)         -> chr(1); tarball name
# |
# |  Dependencies: gdx2, magclass, magpie4 and the messageix/R/ layer (loaded
# |  through utils_runs.R, which carries the solvedness contract and the stage-1
# |  fingerprint). Run from the MAgPIE model root. build_step3_patch.R sources
# |  this file for the shared helpers above (cli_overrides, timestep_years,
# |  pack_patch) -- the packing contract is one contract, not two.

# One line loads the whole messageix/R/ layer: each file there loads the files it
# needs itself, and utils_runs.R sits at the bottom of that chain.
if (!exists("run_modelstat", mode = "function")) source("messageix/R/utils_runs.R")

# ---- CLI --------------------------------------------------------------------

# The repeatable "--set key=value" values as the named list resolve_config()
# takes. Values stay character: resolve_config coerces them through the same
# path as a CSV cell, so a command-line vector is comma-joined exactly like one.
cli_overrides <- function(sets) {
  if (!length(sets)) return(list())
  shapeless <- sets[!grepl("=", sets, fixed = TRUE)]
  if (length(shapeless)) log_die("--set takes key=value, got '", shapeless[1L], "'")
  keys <- sub("=.*$", "", sets)
  values <- sub("^[^=]+=", "", sets)
  if (any(!nzchar(keys))) log_die("--set: no key before the '=' in '", sets[!nzchar(keys)][1L], "'")
  stats::setNames(as.list(values), keys)
}

# ---- model years ------------------------------------------------------------

# The model years a c_timesteps token stands for -- "coup2110" and its siblings
# each name a list of years. The list is read out of MAgPIE's own set definitions
# rather than copied here, because a second copy would quietly go out of date at
# the next MAgPIE version. (The region sets in the same file are rebuilt from
# each input tarball; the year sets are not.)
timestep_years <- function(timesteps, sets_file = "core/sets.gms") {
  if (!file.exists(sets_file)) {
    log_die("timestep_years: ", sets_file, " not found; run from the MAgPIE model root")
  }
  lines <- readLines(sets_file, warn = FALSE)
  pattern <- paste0("c_timesteps%\"[[:space:]]*==[[:space:]]*\"", timesteps, "\"")
  hits <- grep(pattern, lines, fixed = FALSE)
  hits <- hits[grepl("/", lines[hits], fixed = TRUE)]
  if (!length(hits)) {
    log_die("timestep_years: no year list for c_timesteps '", timesteps, "' in ", sets_file)
  }
  spec <- sub("^[^/]*/", "", lines[hits[1L]])
  spec <- sub("/[^/]*$", "", spec)
  years <- trimws(strsplit(spec, ",", fixed = TRUE)[[1L]])
  years <- years[nzchar(years)]
  if (!length(years)) log_die("timestep_years: empty year list for '", timesteps, "'")
  years
}

# The c_timesteps token the patch is validated against. It comes from the preset
# and only from the preset, which is why resolving a preset already refuses a
# column that leaves the row out: the model horizon written into the working
# tree is rewritten by every run, so reading it from there would validate a
# patch against whichever run happened to be last.
configured_timesteps <- function(pcfg) as.character(pcfg$gms[["c_timesteps"]])

# ---- packing ----------------------------------------------------------------

# Pack the staged files into patch_repo_dir() under a name that carries a digest
# of their contents, and return that name.
#
# The files go in under bare names, with no directory above them, because MAgPIE
# unpacks a patch tarball flat and then sends each file to the module folder
# whose own file manifest claims it. A directory prefix hides the file from every
# manifest. That is why everything is staged into one directory first and tar is
# pointed at it with -C.
#
# The bytes of the archive are not reproducible -- gzip records the time of
# writing -- but the name is, because the digest is taken over the staged file
# contents rather than the archive. Rebuilding from identical inputs therefore
# yields an identical name, and MAgPIE rightly skips unpacking it again.
pack_patch <- function(files, pcfg, stage) {
  if (!length(files)) log_die("pack_patch: nothing to pack")
  absent <- files[!file.exists(files)]
  if (length(absent)) log_die("pack_patch: staged file not found: ", absent)
  dirs <- unique(dirname(normalizePath(files, mustWork = TRUE)))
  if (length(dirs) != 1L) {
    log_die("pack_patch: stage every file into one directory, got ", dirs)
  }
  if (anyDuplicated(basename(files))) {
    log_die("pack_patch: duplicate file name in the archive: ",
            basename(files)[duplicated(basename(files))])
  }
  if (!nzchar(Sys.which("tar"))) log_die("pack_patch: tar is not on PATH")

  repo <- patch_repo_dir(pcfg)
  dir.create(repo, recursive = TRUE, showWarnings = FALSE)
  if (!dir.exists(repo)) log_die("pack_patch: cannot create patch directory ", repo)

  name <- patch_tarball_name(pcfg$preset, stage, files)
  tarball <- file.path(normalizePath(repo, mustWork = TRUE), name)
  status <- system2("tar", c("czf", shQuote(tarball), "-C", shQuote(dirs),
                             shQuote(basename(files))))
  if (!identical(as.integer(status), 0L)) {
    log_die("pack_patch: tar exited with status ", status)
  }
  name
}

# ---- tau --------------------------------------------------------------------

# Write the stage-1 tau trajectory out as a csv. ov_tau(t, h, tautype, type)
# taken at type = "level" has exactly the shape MAgPIE declares for
# f13_tau_scenario(t_all, h, tautype), so no reshaping is needed. No file_type is
# given: write.magpie picks the layout from the .csv extension, and that layout
# is the one GAMS reads back in.
extract_tau <- function(gdx, out_csv) {
  tau <- gdx2::readGDX(gdx, "ov_tau", select = list(type = "level"))
  if (is.null(tau)) log_die("extract_tau: no ov_tau in ", gdx)
  magclass::write.magpie(tau, out_csv)
  if (!file.exists(out_csv)) log_die("extract_tau: write.magpie produced no ", out_csv)
  tau
}

# Two ways this file can be wrong that GAMS only reports much later, and far
# from the cause. Catching them here means the message can name the file that
# has to change.
#   - a tau value of zero or below stops the stage-2 runs outright: MAgPIE
#     aborts with "tau value of 0 detected in at least one region!"
#   - a model year missing from the file is read by GAMS as zero for that year,
#     which is the same abort one step later
validate_tau <- function(tau, years) {
  values <- as.vector(tau)
  if (any(is.na(values))) log_die("validate_tau: tau contains NA")
  if (min(values) <= 0) {
    log_die("validate_tau: tau <= 0 (minimum ", signif(min(values), 4), ") in the stage-1 export; ",
            "modules/13_tc/exo/presolve.gms aborts the stage-2 runs on this")
  }
  missing <- setdiff(years, magclass::getYears(tau))
  if (length(missing)) {
    log_die("validate_tau: tau covers no value for ", missing,
            "; every model year of the run horizon must be present")
  }
  invisible(TRUE)
}

# ---- extra override files ---------------------------------------------------

# Copy the files of a caller-supplied directory into the staging directory.
# Flat only: the archive root is the only place a patched input can sit.
stage_extra_files <- function(dir, stage_dir, reserved = character(0)) {
  if (!dir.exists(dir)) log_die("--extra-files: directory not found: ", dir)
  entries <- list.files(dir, full.names = TRUE, all.files = FALSE, no.. = TRUE)
  if (!length(entries)) log_die("--extra-files: ", dir, " is empty")
  subdirs <- entries[dir.exists(entries)]
  if (length(subdirs)) {
    log_die("--extra-files: ", dir, " holds subdirectories (", basename(subdirs),
            "); a patch archive is flat, so every override file must sit directly in it")
  }
  clash <- intersect(basename(entries), reserved)
  if (length(clash)) {
    log_die("--extra-files: ", dir, " holds ", clash,
            ", which this generator writes itself; remove it or supply the run it comes from")
  }
  staged <- file.path(stage_dir, basename(entries))
  if (!all(file.copy(entries, staged, overwrite = TRUE))) {
    log_die("--extra-files: failed to stage files from ", dir)
  }
  staged
}

# ---- generator --------------------------------------------------------------

# Build the stage-2 patch tarball and return its name.
#
#   pcfg        resolved preset
#   extra_dir   optional directory of additional override files (see --extra-files)
#   gdx         optional explicit stage-1 fulldata.gdx; by default the run
#               folder the naming contract assigns to stage 1
build_step2_patch <- function(pcfg, extra_dir = NULL, gdx = NULL) {
  assert_magpie_root()

  if (is.null(gdx)) {
    folder <- locate_run_folder(pcfg, 1L)
    if (is.na(folder)) {
      log_die("stage-1 run folder not found: ", run_folder(pcfg, 1L),
              ". Run the stage-1 driver first, or pass --gdx=PATH")
    }
    gdx <- file.path(folder, RUN_GDX_FILE)
  } else {
    folder <- dirname(gdx)
  }
  if (!file.exists(gdx)) {
    log_die("stage-1 ", RUN_GDX_FILE, " not found: ", gdx,
            ". The run folder exists but holds no solved run")
  }
  log_step("EXTRACT", "tau from ", gdx)
  assert_run_solved(gdx, run_title(pcfg, 1L))

  # Reusing a reference tau across presets is valid exactly when every
  # stage-1-relevant setting matches, and the stage-1 run folder carries no
  # narrative token, so the run itself has to say which preset solved it.
  assert_stage1_fingerprint(pcfg, folder)

  stage_dir <- tempfile("mm_patch_price_")
  dir.create(stage_dir, recursive = TRUE)
  on.exit(unlink(stage_dir, recursive = TRUE), add = TRUE)

  tau_csv <- file.path(stage_dir, "f13_tau_scenario.csv")
  tau <- extract_tau(gdx, tau_csv)
  years <- timestep_years(configured_timesteps(pcfg))
  validate_tau(tau, years)
  log_step("CHECK", "tau covers ", length(years), " model years x ",
           length(magclass::getItems(tau, dim = 1)), " regions, minimum ",
           signif(min(as.vector(tau)), 4))

  files <- tau_csv
  if (!is.null(extra_dir)) {
    extra <- stage_extra_files(extra_dir, stage_dir, reserved = basename(tau_csv))
    log_step("EXTRACT", "bundling ", length(extra), " extra override file(s) from ", extra_dir,
             ": ", basename(extra))
    files <- c(files, extra)
  }

  name <- pack_patch(files, pcfg, 2L)
  log_step("PACK", file.path(patch_repo_dir(pcfg), name), " (", length(files), " file(s))")
  name
}

# ---- CLI entry point --------------------------------------------------------

.synopsis_step2 <- paste(
  "usage: Rscript messageix/patches/build_step2_patch.R [--preset=NAME] [--csv=PATH]",
  "[--set=key=value] [--gdx=PATH] [--extra-files=DIR] [--help]")

.usage_step2 <- c(
  "Pack the land-use intensity trajectory (tau) of the stage-1 run into the patch",
  "tarball stage 2 reads. Stage 2 holds that trajectory fixed instead of solving for",
  "it, and reads it as f13_tau_scenario.csv out of",
  "<patch_repo>/<preset>_price_<digest>.tgz.",
  "",
  "  Rscript messageix/patches/build_step2_patch.R [flags]   (from the MAgPIE model root)",
  "",
  "Flags:",
  "  --preset=NAME       narrative column of the narratives file (default: default)",
  paste0("  --csv=PATH          narratives file (default: ", default_preset_csv(), ")"),
  "  --set=key=value     override one setting for this build; repeatable. Any narrative",
  "                      or infrastructure key (bii_target, qos) -- the full list is in",
  "                      messageix/docs/parameters.md",
  paste0("  --gdx=PATH          the stage-1 ", RUN_GDX_FILE,
         ", when it is not in the run folder the"),
  "                      preset's names point at",
  "  --extra-files=DIR   also pack every file in DIR into the patch tarball, alongside",
  "                      the trajectory. This is the way to carry a correction to some",
  "                      other input file; not needed when the base input tarballs are",
  "                      current. The directory must hold files only, no sub-directories.",
  "  --help              this text",
  "",
  "Every option is accepted as --key=value and as --key value.",
  "The tarball name is written as the last line of output, so a script can read it",
  "with `tail -n 1`. The name carries a digest of the contents: rebuilding the same",
  "inputs gives the same name, and changed inputs give a new one.")

if (invoked_directly("build_step2_patch.R")) {
  .opt <- parse_flags(commandArgs(trailingOnly = TRUE),
                      known      = c("preset", "csv", "gdx", "extra-files"),
                      flags      = "help",
                      repeatable = "set",
                      aliases    = c("preset-csv" = "csv"),
                      usage      = .synopsis_step2)
  if (isTRUE(.opt$help)) {
    cat(.usage_step2, sep = "\n")
    cat("\n")
  } else {
    .pcfg <- config_from_flags(.opt, cli_overrides(.opt$set))
    log_step("CONFIG", "preset '", .pcfg$preset, "' from ", .pcfg$csv)
    .name <- build_step2_patch(.pcfg,
                               extra_dir = .opt[["extra-files"]],
                               gdx = .opt$gdx)
    cat(.name, "\n", sep = "")
  }
}
