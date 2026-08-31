# |  Pre-run checks for the MAgPIE -> MESSAGEix pipeline.
# |
# |  Everything here is knowable before a single run is submitted, and every one
# |  of these failures otherwise surfaces hours later: inside GAMS, once per run,
# |  after a queue wait, on a cluster. The checks are cheap and the runs are not.
# |
# |  This is the gate before a run. It is not the check after one: whether the
# |  emulator's answers agree with MESSAGE's is what messageix/feedback_prep/ and
# |  messageix/feedback_run/ are for, and no check here has an opinion about it.
# |
# |  A check returns one of four statuses:
# |
# |    PASS  the condition holds
# |    WARN  worth reading before submitting; does not stop anything
# |    FAIL  a run started now would fail, or would silently run on wrong data
# |    SKIP  the check does not apply at this stage
# |
# |  vet_pre_run() stops on any FAIL. Nothing here writes, moves or fixes
# |  anything; a check that repaired what it found would hide the thing worth
# |  knowing.
# |
# |  Usage, from the MAgPIE model root:
# |    Rscript messageix/vetting/vet_pre_run.R --experiment default --stage 3 \
# |      --f56 messageix/feedback_prep/output/default/f56_pollutant_prices.cs3
# |
# |    --experiment NAME  an experiment of messageix/experiments.R
# |    --stage N          1, 2 or 3; the stage about to run (default 3)
# |    --f56 PATH         the GHG price file the demand phase will be packed with
# |    --seed PATH        f60_bioenergy_dem.cs3 the demand phase will append to
# |    --set key=value    override one setting; repeatable
# |    --warn-only        report FAILs and exit 0 instead of stopping
# |    --help
# |
# |  Every option is accepted as --key value and as --key=value.
# |
# |  Interface
# |    vet_checks()                  -> named list of list(stages, describe, fn)
# |    vet_pre_run(pcfg, stage, ...) -> data.frame(check, status, detail); stops on FAIL
# |
# |  Dependencies: messageix/R/pack_demand.R for validate_f56(), assert_seed() and
# |  the year helpers, which brings the whole messageix/R/ layer with it. Run from
# |  the MAgPIE model root.

if (!exists("validate_f56", mode = "function")) source("messageix/R/pack_demand.R")

# A check's result. `detail` is what someone reads when it is not PASS.
vet_result <- function(status, detail = "") list(status = status, detail = detail)

# Run a check body and turn any stop() into a FAIL. A check that dies takes the
# report down with it otherwise, and the remaining checks are the ones that would
# have explained why.
vet_try <- function(expr, on_error = "FAIL") {
  tryCatch(expr, error = function(e) vet_result(on_error, conditionMessage(e)))
}

# ---- the checks -------------------------------------------------------------

# One entry per check: which stages it applies to, one line saying what it is
# for, and the body. `ctx` carries pcfg, stage, f56 and seed.
vet_checks <- function() {
  list(
    magpie_root = list(
      stages = 1:3,
      describe = "the working directory is a MAgPIE model root",
      fn = function(ctx) {
        if (magpie_root_ok()) return(vet_result("PASS"))
        vet_result("FAIL", paste0("current directory is ", getwd(),
                                  "; run from the directory holding config/default.cfg"))
      }),

    default_cfg = list(
      stages = 1:3,
      describe = "config/default.cfg reads and takes the narrative's SSP",
      fn = function(ctx) vet_try({
        if (!file.exists("config/default.cfg")) {
          return(vet_result("FAIL", "config/default.cfg not found"))
        }
        cfg <- NULL
        source("config/default.cfg", local = TRUE)
        if (is.null(cfg)) return(vet_result("FAIL", "config/default.cfg defined no cfg"))
        # setScenario() stops on an SSP its own scenario config does not carry.
        # Unchecked, that surfaces when the first run assembles its cfg.
        gms::setScenario(cfg, ctx$pcfg$ssp)
        vet_result("PASS", paste0("ssp ", ctx$pcfg$ssp))
      })),

    region_set = list(
      stages = 1:3,
      describe = "the region set is known and its region-name table reads",
      fn = function(ctx) vet_try({
        # An unknown region set never reaches vetting: input_regional and the rest
        # are derived keys, and resolve_config() dies on them first. What is live
        # here is the table itself, which nothing upstream reads.
        file <- region_names_file(ctx$pcfg)
        if (!file.exists(file)) {
          return(vet_result("FAIL", paste0("region-name table not found: ", file)))
        }
        rename <- region_rename(ctx$pcfg)
        if (!length(rename)) {
          return(vet_result("FAIL", paste0(file, " names no region")))
        }
        # GLO and World both map onto World by design; the table says so in its
        # own header. The duplicate test is about the world regions.
        regional <- rename[!names(rename) %in% c("GLO", "World")]
        dup <- unique(regional[duplicated(regional)])
        if (length(dup)) {
          return(vet_result("FAIL", paste0(file, " maps more than one MAgPIE region code onto ",
                                           paste(dup, collapse = ", "),
                                           "; the emulator matrix and the woodfuel table ",
                                           "would disagree about what a region is")))
        }
        vet_result("PASS", paste0(length(regional), " regions in ", basename(file)))
      })),

    input_tarballs = list(
      stages = 1:3,
      describe = "the region set's input tarballs are present locally",
      fn = function(ctx) vet_try({
        inputs <- region_set_inputs(ctx$pcfg$region_set)$tarballs
        dirs <- c("input", patch_repo_dir(ctx$pcfg),
                  names(Filter(function(x) is.null(x), getOption("magpie_repos"))))
        dirs <- unique(dirs[dir.exists(dirs)])
        absent <- inputs[!vapply(inputs, function(f) {
          any(file.exists(file.path(dirs, f)))
        }, logical(1))]
        if (!length(absent)) return(vet_result("PASS", paste0(length(inputs), " tarballs local")))
        # Not a failure: MAgPIE downloads what it cannot find. It is worth
        # knowing before a cluster job spends its wall time doing it.
        where <- if (length(dirs)) paste0("in ", paste(dirs, collapse = ", ")) else "on this machine"
        vet_result("WARN", paste0(length(absent), " of ", length(inputs),
                                  " tarballs are not ", where, " and will be downloaded: ",
                                  paste(basename(absent), collapse = ", ")))
      })),

    patch_repo = list(
      stages = 2:3,
      describe = "the patch directory can be written to",
      fn = function(ctx) vet_try({
        repo <- patch_repo_dir(ctx$pcfg)
        # The directory is not created here. pack_patch() makes it when it packs;
        # a check that made it would be reporting on its own side effect.
        target <- if (dir.exists(repo)) repo else dirname(repo)
        if (!dir.exists(target)) {
          return(vet_result("FAIL", paste0("neither ", repo, " nor its parent exists, so the ",
                                           "patch directory cannot be created")))
        }
        if (file.access(target, mode = 2L) != 0L) {
          return(vet_result("FAIL", paste0(target, " is not writable")))
        }
        vet_result("PASS", if (identical(target, repo)) repo else paste0(repo, " (to be created)"))
      })),

    timesteps = list(
      stages = 1:3,
      describe = "the timesteps token resolves to model years",
      fn = function(ctx) vet_try({
        years <- timestep_years(configured_timesteps(ctx$pcfg))
        if (!length(years)) {
          return(vet_result("FAIL", paste0("timesteps '", configured_timesteps(ctx$pcfg),
                                           "' resolves to no year")))
        }
        vet_result("PASS", paste0(length(years), " years, ", min(years), " to ", max(years)))
      })),

    bioenergy_floors = list(
      stages = 2:3,
      describe = "nothing puts a floor under the bioenergy price sweep",
      fn = function(ctx) {
        bad <- character(0)
        if (ctx$pcfg$bioenergy_dem_min != 0) {
          bad <- c(bad, paste0("bioenergy_dem_min = ", ctx$pcfg$bioenergy_dem_min))
        }
        if (ctx$pcfg$bioenergy_1st_subsidy != 0) {
          bad <- c(bad, paste0("bioenergy_1st_subsidy = ", ctx$pcfg$bioenergy_1st_subsidy))
        }
        if (!length(bad)) return(vet_result("PASS"))
        vet_result("FAIL", paste0(paste(bad, collapse = "; "),
                                  ". Both act as a floor under the sweep and truncate its low ",
                                  "end; the runs solve and the matrix is wrong"))
      }),

    nonco2_cap = list(
      stages = 3,
      describe = "the non-CO2 price cap reads as a per-tC number",
      fn = function(ctx) {
        # Type and positivity are not checked here: the lever's own check() in
        # world_levers.R rejects them, so resolve_config() dies before vetting runs.
        cap <- ctx$pcfg$nonco2_price_cap_usd17_tc
        # The lever is per tonne of carbon, and the target it is usually set from
        # is quoted per tonne of CO2. 200 is exactly the value the two readings
        # collide on, so it is worth a second look rather than a silent pass.
        # The golden experiment pins 200 on purpose, so it is not asked there.
        if (abs(cap - 200) < 1e-9 && !identical(ctx$pcfg$experiment, "golden")) {
          return(vet_result("WARN", paste0(
            "nonco2_price_cap_usd17_tc = 200. In this lever's unit that is 200 USD17MER per ",
            "tC, about 55 USD per tCO2. A cap quoted as 200 USD per tCO2 is 734 here ",
            "(200 x 44/12). Confirm which was meant")))
        }
        vet_result("PASS", paste0(cap, " USD17MER per tC (", signif(cap * 12 / 44, 4),
                                  " USD17MER per tCO2)"))
      }),

    calibration_reuse = list(
      stages = 2:3,
      describe = "the calibration this run reads from exists",
      fn = function(ctx) vet_try({
        folder <- run_folder(ctx$pcfg, 1)
        if (dir.exists(folder)) return(vet_result("PASS", folder))
        scope <- if (nzchar(ctx$pcfg$project)) {
          paste0("shared by project '", ctx$pcfg$project, "'")
        } else "this experiment's own"
        vet_result("WARN", paste0("no calibration run at ", folder, " (", scope,
                                  "). Stage 1 has to run before this stage can read tau"))
      })),

    f56_file = list(
      stages = 3,
      describe = "the GHG price file matches the experiment's sweep",
      fn = function(ctx) vet_try({
        if (is.null(ctx$f56)) {
          return(vet_result("FAIL", paste0(
            "no --f56 given. The demand phase cannot be packed without it. Build one from a ",
            "MESSAGE run with messageix/feedback_prep/feedback_prep.R, or obtain the file; ",
            "Rscript messageix/R/pack_demand.R --experiment=", ctx$pcfg$experiment,
            " prints what it has to contain")))
        }
        validate_f56(ctx$f56, ctx$pcfg)
        vet_result("PASS", ctx$f56)
      })),

    f60_seed = list(
      stages = 3,
      describe = "the bioenergy demand file is the unpatched base file",
      fn = function(ctx) vet_try({
        seed <- if (is.null(ctx$seed)) {
          "modules/60_bioenergy/input/f60_bioenergy_dem.cs3"
        } else ctx$seed
        if (!file.exists(seed)) {
          return(vet_result("WARN", paste0(
            seed, " is not there yet. It arrives when the base input tarballs are unpacked, ",
            "which the first run of an earlier stage does")))
        }
        assert_seed(seed, ctx$pcfg)
        vet_result("PASS", seed)
      }))
  )
}

# ---- the report -------------------------------------------------------------

# Run every check that applies to this stage and return the report. Stops on any
# FAIL unless warn_only, in which case the caller reads the returned frame.
vet_pre_run <- function(pcfg, stage = 3, f56 = NULL, seed = NULL, warn_only = FALSE) {
  stage <- as.integer(stage)
  if (!stage %in% 1:3) log_die("--stage: ", stage, " is not 1, 2 or 3")
  ctx <- list(pcfg = pcfg, stage = stage, f56 = f56, seed = seed)
  checks <- vet_checks()

  log_banner("pre-run vetting", list(
    experiment = pcfg$experiment,
    stage      = paste0(stage, " (", phase_of_stage(stage), ")"),
    checks     = length(checks)))

  rows <- lapply(names(checks), function(id) {
    spec <- checks[[id]]
    # Two layers of vet_try on purpose: a check body wraps its own so a failure
    # inside it becomes that check's FAIL, and this one catches a body that dies
    # before its own wrapper. The inner one reports first when both could.
    res <- if (!stage %in% spec$stages) {
      vet_result("SKIP", paste0("applies at stage(s) ", paste(spec$stages, collapse = ", ")))
    } else {
      vet_try(spec$fn(ctx))
    }
    log_step("CHECK", sprintf("%-18s %-4s %s", id, res$status,
                              if (nzchar(res$detail)) res$detail else spec$describe))
    data.frame(check = id, status = res$status, describe = spec$describe,
               detail = res$detail, stringsAsFactors = FALSE)
  })
  report <- do.call(rbind, rows)

  failed <- report$check[report$status == "FAIL"]
  warned <- report$check[report$status == "WARN"]
  if (length(warned)) log_warn(length(warned), " check(s) to read: ", warned)
  if (length(failed)) {
    if (isTRUE(warn_only)) {
      log_warn(length(failed), " check(s) failed: ", failed, " (--warn-only)")
    } else {
      log_die(length(failed), " pre-run check(s) failed: ", paste(failed, collapse = ", "),
              ". Each one costs a queue wait and a GAMS run to discover otherwise")
    }
  } else {
    log_step("DONE", "pre-run vetting passed for stage ", stage)
  }
  invisible(report)
}

# ---- command line -----------------------------------------------------------

if (invoked_directly("vet_pre_run.R")) {
  usage <- paste(sub("^# \\|", "", grep("^# \\|",
                 readLines("messageix/vetting/vet_pre_run.R"), value = TRUE)), collapse = "\n")
  flags <- parse_flags(commandArgs(trailingOnly = TRUE),
                       known = c("experiment", "stage", "f56", "seed"),
                       flags = c("help", "warn-only"), repeatable = c("set"), usage = usage)
  if (isTRUE(flags$help)) { log_report(usage); quit(status = 0) }
  pcfg <- config_from_flags(flags, cli_overrides(flags$set))
  vet_pre_run(pcfg, stage = if (is.null(flags$stage)) 3L else as.integer(flags$stage),
              f56 = flags$f56, seed = flags$seed,
              warn_only = isTRUE(flags[["warn-only"]]))
}
