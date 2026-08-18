# |  Stage 1 of the MAgPIE -> MESSAGEix emulator pipeline: the reference tau run.
# |
# |  WHAT THIS RUN IS. One MAgPIE run with technological change endogenous
# |  (cfg$gms$tc left at endo_jan22), calibrated against the BAU second-generation
# |  bioenergy demand path named by pipeline$biodem_scenario_step1 and under the
# |  land protection scenario pipeline$protect_scenario_step1. Its product is not
# |  a scenario result. It is the land-use intensity trajectory tau, which the
# |  seven stage-2 runs then impose exogenously so that they differ from one
# |  another only in the bioenergy price.
# |
# |  WHERE TAU LANDS. In the run folder's fulldata.gdx, as the variable ov_tau
# |  (t, h, tautype, type); the level of that variable is the trajectory.
# |
# |  WHAT CONSUMES IT. Step 1.5, messageix/patches/build_step2_patch.R, reads
# |  ov_tau out of this run's fulldata.gdx, writes it as f13_tau_scenario.csv,
# |  and packs it into the content-hashed tarball that stage 2 loads as its patch
# |  input. Nothing else in the pipeline reads this run.
# |
# |  NO PATCH TARBALL. Stage 1 needs none: the pinned R12 tarball set in
# |  messageix/inputs/ carries every input it reads.
# |
# |  ONE REFERENCE TAU PER SET OF STAGE-1 SETTINGS. The run folder is shared
# |  across narratives, so this run records the settings it solved under
# |  (messageix_stage1_fingerprint.txt) and the step-1.5 generator refuses to
# |  extract tau from a run another preset produced.
# |
# |  WHY THIS RUN'S SETTINGS DIFFER FROM STAGES 2 AND 3. It runs land protection
# |  "BH" against their "none", c44_bii_decrease 0 against their 1, and leaves
# |  s30_annual_max_growth, s44_cost_bii_missing, the s60_* bioenergy switches and
# |  every c56_* GHG price switch at MAgPIE's defaults -- so it runs under an NPi
# |  carbon price with the default non-CO2 cap of 4920 USD17MER/tC. That
# |  asymmetry is deliberate and is enforced in messageix/R/utils_config.R, not
# |  here: capping or re-scenarioing this run would move the tau trajectory that
# |  the whole pipeline rests on.
# |
# |  Usage, from the MAgPIE model root:
# |    Rscript messageix/start/driver_step1_tau.R                  # run it
# |    Rscript messageix/start/driver_step1_tau.R --list           # print the run set
# |    Rscript messageix/start/driver_step1_tau.R --validate       # print the assembled cfg
# |    Rscript messageix/start/driver_step1_tau.R --dry-run
# |    Rscript messageix/start/driver_step1_tau.R --preset=NAME --csv=PATH
# |
# |  Next: Rscript messageix/patches/build_step2_patch.R

source("messageix/start/run_stage.R")

main <- function() {
  run_driver_main(
    stage    = 1,
    headline = "stage 1 - reference tau",
    notes    = c(
      "technological change" = "endogenous (endo_jan22): exporting the tau trajectory is the point of the run",
      "artefact"             = "ov_tau (level) in fulldata.gdx",
      "consumed by"          = "messageix/patches/build_step2_patch.R -> f13_tau_scenario.csv",
      "patch tarball"        = "none: stage 1 runs on the base input tarballs alone"
    )
  )
}

if (!interactive()) main()
