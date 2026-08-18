# |  Build the patch tarball stage 2 consumes (pipeline step 1.5).
# |
# |  Stage 2 runs technological change exogenously (cfg$gms$tc = "exo"), which
# |  means it reads the tau trajectory out of an input file instead of solving
# |  for it. That file is f13_tau_scenario.csv and it is produced from the
# |  stage-1 reference run:
# |
# |      stage 1 fulldata.gdx  ->  ov_tau (level)  ->  f13_tau_scenario.csv
# |                            ->  patch_input/<preset>_price_<hash>.tgz
# |
# |  modules/13_tc/exo/realization.gms:14-17 states the contract: the file is
# |  region and time specific and overwrites the dummy shipped in the base
# |  tarball. Six MAgPIE project start scripts in this repository export it with
# |  the same one-liner (scripts/start/projects/paper_peatlandTax.R:183,
# |  project_BEST.R:171, project_WetHorizons.R:142 and siblings); extract_tau()
# |  below is that line, unchanged, writing to a staging directory instead of
# |  straight into modules/13_tc/input/.
# |
# |  Why a tarball and not a file copy: MAgPIE's download_and_update() is what
# |  regenerates the module set files from the distributed inputs, so an input
# |  that arrives outside a tarball is invisible to that machinery. A patch is
# |  a plain .tgz in cfg$repositories holding bare file names at the archive
# |  root; download_distribute() extracts it flat and routes each file to the
# |  module input/ folder whose input/files manifest names it. A directory
# |  prefix inside the archive breaks that routing.
# |
# |  The tarball name carries an 8-hex digest of its contents
# |  (utils_paths.R::patch_tarball_name). MAgPIE decides whether to re-extract
# |  by comparing tarball *names* against input/info.txt, never checksums, so a
# |  regenerated tarball reusing its old name leaves the model running on stale
# |  inputs and stale generated sets.gms with nothing in any log to say so.
# |
# |  Usage
# |    Rscript messageix/patches/build_step2_patch.R [flags]     (from the model root)
# |
# |    --preset=NAME        narrative column of the preset CSV (default "default")
# |    --csv=PATH           preset CSV (default: default_preset_csv())
# |    --set=key=value      override one preset row; repeatable. Keys are bare
# |                         pipeline keys ("identifier") or fully qualified
# |                         ("pipeline$identifier", "gms$c_timesteps")
# |    --gdx=PATH           stage-1 fulldata.gdx, when it is not where the
# |                         preset's naming contract puts it
# |    --extra-files=DIR    bundle every file in DIR into the tarball alongside
# |                         f13_tau_scenario.csv. The seam for a hand-held
# |                         step-2 patch that carries base-input fixes beyond
# |                         tau, for files the pinned tarball is stale on; with
# |                         an up-to-date base tarball the flag is not needed.
# |                         Files land at the archive root, so DIR must be flat
# |                         and must not shadow the tau file.
# |    --help
# |
# |  The tarball name is narrated as ">> PACK: ..." and repeated bare on the
# |  last line of stdout, so a shell caller can read it with `tail -n 1`.
# |  In-process callers source this file and use the return value:
# |
# |      pcfg <- resolve_config("default")
# |      pcfg <- with_patch(pcfg, 2, build_step2_patch(pcfg))
# |
# |  Interface
# |    cli_args(argv)                       -> list(flags, sets); shared CLI parser
# |    cli_overrides(sets)                  -> named list for resolve_config(overrides=)
# |    invoked_directly(basename)           -> lgl(1); TRUE when Rscript was given this file
# |    timestep_years(timesteps)            -> chr; model years of a c_timesteps token
# |    configured_timesteps(pcfg)           -> chr(1); the preset's c_timesteps token
# |    pack_patch(files, pcfg, stage)       -> chr(1); tarball name, written to patch_repo
# |    extract_tau(gdx, out_csv)            -> magpie object; writes the csv
# |    validate_tau(tau, years)             -> invisible(TRUE)
# |    stage_extra_files(dir, stage_dir)    -> chr; staged copies of the extra files
# |    build_step2_patch(pcfg, ...)         -> chr(1); tarball name
# |
# |  Dependencies: gdx2, magclass, magpie4, messageix/R/utils_config.R (which
# |  pulls in utils_log, utils_paths and utils_env) and messageix/R/utils_runs.R
# |  (solvedness and the stage-1 fingerprint). Run from the MAgPIE model root.
# |  build_step3_patch.R sources this file for the shared helpers above
# |  (cli_args, timestep_years, pack_patch) -- the packing contract is one
# |  contract, not two.

if (!exists("resolve_config", mode = "function")) source("messageix/R/utils_config.R")
if (!exists("run_modelstat", mode = "function"))  source("messageix/R/utils_runs.R")

# ---- CLI --------------------------------------------------------------------

# Parse "--key=value" arguments into a named list, collecting the repeatable
# "--set key=value" form separately. Unknown *shapes* stop here; unknown *keys*
# are the calling script's business, because the two generators take different
# flags and a typo must not be swallowed.
cli_args <- function(argv) {
  out <- list(flags = list(), sets = character(0))
  for (arg in argv) {
    if (arg %in% c("--help", "-h")) {
      out$flags$help <- "TRUE"
      next
    }
    if (!grepl("^--[A-Za-z0-9][A-Za-z0-9-]*=", arg)) {
      log_die("unrecognised argument '", arg, "'; arguments take the form --key=value. Try --help")
    }
    key <- sub("^--([^=]+)=.*$", "\\1", arg)
    value <- sub("^--[^=]+=", "", arg)
    if (identical(key, "set")) {
      if (!grepl("=", value, fixed = TRUE)) {
        log_die("--set takes key=value, got '", value, "'")
      }
      out$sets <- c(out$sets, value)
    } else {
      out$flags[[key]] <- value
    }
  }
  out
}

# The --set values as the named list resolve_config() takes. Values stay
# character: resolve_config coerces them through the same path as a CSV cell,
# so a command-line vector is comma-joined exactly like one.
cli_overrides <- function(sets) {
  if (!length(sets)) return(list())
  keys <- sub("=.*$", "", sets)
  values <- sub("^[^=]+=", "", sets)
  if (any(!nzchar(keys))) log_die("--set: empty key")
  stats::setNames(as.list(values), keys)
}

# TRUE when Rscript was handed this very file, FALSE when another script
# sourced it. Guards the CLI block at the foot of the file.
invoked_directly <- function(basename_expected) {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- sub("^--file=", "", args[grepl("^--file=", args)])
  length(file_arg) == 1L && identical(basename(file_arg), basename_expected)
}

# Flags a generator accepts; anything else is a typo and stops the run before
# a long extraction. `known` excludes "set", which cli_args() removes.
assert_known_flags <- function(flags, known, usage) {
  unknown <- setdiff(names(flags), c(known, "help"))
  if (length(unknown)) {
    cat(usage, sep = "\n")
    log_die("unknown flag(s): --", paste(unknown, collapse = ", --"))
  }
  invisible(TRUE)
}

# ---- model years ------------------------------------------------------------

# Model years of a c_timesteps token, read from the set definition of `t` in
# core/sets.gms. Parsed rather than tabulated here: the timestep sets are part
# of upstream MAgPIE, and a second copy would drift at the next version bump.
# (The spatial sets in the same file are machine-generated per input tarball;
# the timestep sets are not.)
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
# and only from the preset: resolve_config() requires the row, because the
# $setglobal in main.gms is rewritten by apply_cfg() on every run and would tie
# this patch to whichever run last touched the working tree.
configured_timesteps <- function(pcfg) {
  timesteps <- pcfg$gms[["c_timesteps"]]
  if (is.null(timesteps) || !nzchar(as.character(timesteps))) {
    log_die("configured_timesteps: preset '", pcfg$preset, "' sets no gms$c_timesteps")
  }
  as.character(timesteps)
}

# ---- packing ----------------------------------------------------------------

# Pack staged files into patch_repo_dir() under a content-hashed name and
# return that name.
#
# Members carry bare file names because download_distribute() extracts a patch
# flat and routes each file by the module input/files manifest that claims it;
# a directory prefix hides the file from every manifest. Hence the single
# staging directory and the tar -C.
#
# The archive bytes are not reproducible (gzip stores a timestamp) but the
# *name* is: patch_tarball_name() hashes the staged file contents, so
# regenerating identical inputs yields the identical name and MAgPIE correctly
# skips the re-extraction.
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

# Export the stage-1 tau trajectory. This is the export idiom of
# scripts/start/projects/paper_peatlandTax.R:183 verbatim, except that the
# destination is a staging directory rather than modules/13_tc/input/:
# ov_tau(t,h,tautype,type) selected at type="level" has exactly the shape of
# f13_tau_scenario(t_all,h,tautype) declared at modules/13_tc/exo/input.gms:31.
# No file_type is passed -- write.magpie derives the layout from the .csv
# extension, and that layout is what the $include in input.gms parses.
extract_tau <- function(gdx, out_csv) {
  tau <- gdx2::readGDX(gdx, "ov_tau", select = list(type = "level"))
  if (is.null(tau)) log_die("extract_tau: no ov_tau in ", gdx)
  magclass::write.magpie(tau, out_csv)
  if (!file.exists(out_csv)) log_die("extract_tau: write.magpie produced no ", out_csv)
  tau
}

# Two failure modes that GAMS reports far from their cause, caught here where
# the message can name the file that has to change.
#   - a non-positive tau makes modules/13_tc/exo/presolve.gms:11-13 abort with
#     "tau value of 0 detected in at least one region!"
#   - a missing model year leaves f13_tau_scenario at its GAMS default of zero
#     for that year, which is the same abort one step later
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
    gdx <- file.path(folder, "fulldata.gdx")
  } else {
    folder <- dirname(gdx)
  }
  if (!file.exists(gdx)) {
    log_die("stage-1 fulldata.gdx not found: ", gdx,
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

.usage_step2 <- c(
  "Build the patch tarball stage 2 consumes: the stage-1 tau trajectory as",
  "f13_tau_scenario.csv, packed into <patch_repo>/<preset>_price_<hash>.tgz.",
  "",
  "  Rscript messageix/patches/build_step2_patch.R [flags]   (from the MAgPIE model root)",
  "",
  "  --preset=NAME       narrative column of the preset CSV (default: default)",
  paste0("  --csv=PATH          preset CSV (default: ", default_preset_csv(), ")"),
  "  --set=key=value     override one preset row; repeatable",
  "  --gdx=PATH          stage-1 fulldata.gdx, if not at the preset's run folder",
  "  --extra-files=DIR   also bundle every file in DIR (flat) into the tarball.",
  "                      The seam for a hand-held step-2 patch that carries base-input",
  "                      fixes beyond tau; unnecessary with an up-to-date base tarball.",
  "  --help              this text",
  "",
  "The tarball name is the last line of stdout.")

if (invoked_directly("build_step2_patch.R")) {
  .argv <- cli_args(commandArgs(trailingOnly = TRUE))
  if (!is.null(.argv$flags$help)) {
    cat(.usage_step2, sep = "\n")
  } else {
    assert_known_flags(.argv$flags, c("preset", "csv", "gdx", "extra-files"), .usage_step2)
    .preset <- if (is.null(.argv$flags$preset)) "default" else .argv$flags$preset
    .csv <- if (is.null(.argv$flags$csv)) default_preset_csv() else .argv$flags$csv
    log_step("CONFIG", "preset '", .preset, "' from ", .csv)
    .pcfg <- resolve_config(.preset, .csv, cli_overrides(.argv$sets))
    .name <- build_step2_patch(.pcfg,
                               extra_dir = .argv$flags[["extra-files"]],
                               gdx = .argv$flags$gdx)
    cat(.name, "\n", sep = "")
  }
}
