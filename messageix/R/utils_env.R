# |  Execution environment for the MAgPIE -> MESSAGEix pipeline.
# |
# |  Everything that depends on *which machine* the pipeline runs on lives here:
# |  input repositories, the SLURM quality-of-service queue, the module set that
# |  provides the R environment, and the optional job-notification address.
# |  Nothing here depends on the science; nothing outside here names a cluster.
# |
# |  Resolution order for every setting: environment variable, then the preset
# |  column, then the built-in default. The environment variable exists so one
# |  researcher can run an unmodified preset on a different cluster without
# |  touching a tracked file.
# |
# |    MAGPIE_MM_QOS          SLURM quality of service            e.g. standby
# |    MAGPIE_MM_MODULES      comma-separated module list         e.g. R/4.4.1,gcc/15.2.0
# |    MAGPIE_MM_MAIL_USER    job notification address            empty = no mail
# |    MAGPIE_MM_PATCH_REPO   directory holding generated patches default ./patch_input
# |    MAGPIE_MM_PUBLIC_REPO  base tarball repository URL
# |
# |  Interface
# |    env_or(var, fallback)          -> chr(1) or NULL; environment variable else fallback
# |    magpie_root_ok()               -> lgl(1); TRUE when the cwd is a MAgPIE model root
# |    assert_magpie_root()           -> invisible(TRUE); stops when it is not
# |    patch_repo_dir(pcfg)           -> chr(1); directory generated patch tarballs live in
# |    magpie_repositories(pcfg)      -> named list; value for cfg$repositories
# |    run_qos(pcfg)                  -> chr(1); value for cfg$qos
# |    slurm_modules(pcfg)            -> chr; module names in load order
# |    slurm_module_lines(pcfg)       -> chr; "module purge" plus one "module load" per module
# |    mail_user(pcfg)                -> chr(1) or NULL
# |
# |  The R layer is the only place these settings are decided. The shell wrapper
# |  messageix/emulator/run_matrix.sh asks this file for them rather than
# |  carrying its own copies.
# |
# |  Dependencies: base R and messageix/R/utils_log.R.

if (!exists("log_die", mode = "function")) source("messageix/R/utils_log.R")

# Environment variable if set and non-empty, otherwise the fallback.
env_or <- function(var, fallback) {
  value <- Sys.getenv(var, unset = "")
  if (nzchar(value)) value else fallback
}

# ---- model root -------------------------------------------------------------

# MAgPIE start scripts run from the model root and source paths relative to it.
# These two files exist in every MAgPIE checkout and nowhere else.
magpie_root_ok <- function() {
  file.exists("config/default.cfg") && file.exists("scripts/start_functions.R")
}

assert_magpie_root <- function() {
  if (!magpie_root_ok()) {
    log_die("run from the MAgPIE model root (the directory holding config/default.cfg); ",
            "current directory is ", getwd())
  }
  invisible(TRUE)
}

# ---- repositories -----------------------------------------------------------

# Directory the patch generators write into and MAgPIE reads patch tarballs
# from. It does not exist in a fresh clone; generators create it.
patch_repo_dir <- function(pcfg) {
  env_or("MAGPIE_MM_PATCH_REPO", pcfg$patch_repo)
}

# cfg$repositories: the public MAgPIE tarball server, then the local patch
# directory, then whatever the site configured through the magpie_repos option
# (PIK's cluster sets it in .Rprofile; other sites may not set it at all).
# Order is search order -- the patch directory must come before any repository
# that could hold a same-named tarball.
magpie_repositories <- function(pcfg) {
  repos <- list(NULL, NULL)
  names(repos) <- c(env_or("MAGPIE_MM_PUBLIC_REPO", pcfg$magpie_public_repo),
                    patch_repo_dir(pcfg))
  append(repos, getOption("magpie_repos"))
}

# ---- SLURM ------------------------------------------------------------------

# cfg$qos selects scripts/run_submit/submit_<qos>.sh. "priority" is a PIK queue
# name; a site without it must override, or start_run() fails on a missing file.
run_qos <- function(pcfg) {
  env_or("MAGPIE_MM_QOS", pcfg$qos)
}

# Modules to load before Rscript, in load order. gcc must come last: the piam
# compiled packages (gdx2 via Rcpp) resolve CXXABI_1.3.15 out of the libstdc++
# that the gcc module puts first on the library path, and an R module loaded
# afterwards puts its own older libstdc++ ahead of it.
slurm_modules <- function(pcfg) {
  modules <- env_or("MAGPIE_MM_MODULES", NULL)
  if (is.null(modules)) return(pcfg$slurm_modules)
  trimws(strsplit(modules, ",", fixed = TRUE)[[1L]])
}

# Shell lines that establish the R environment, for a job script or for the
# matrix wrapper to evaluate. Emitted as commands rather than as a module list
# so that the "purge first, gcc last" rule above is stated in exactly one place.
slurm_module_lines <- function(pcfg) {
  modules <- slurm_modules(pcfg)
  if (!length(modules)) return(character(0))
  c("module purge", paste("module load", modules))
}

# Job notification address. NULL means the job script carries no mail
# directives at all -- a shared repository has no business defaulting to
# somebody's inbox.
mail_user <- function(pcfg) {
  address <- env_or("MAGPIE_MM_MAIL_USER", pcfg$mail_user)
  if (is.null(address) || !nzchar(address)) NULL else address
}
