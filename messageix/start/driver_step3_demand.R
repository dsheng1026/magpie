# |  Stage 3 of the MAgPIE -> MESSAGEix emulator pipeline: the demand-driven runs.
# |
# |  The emulator training set -- the runs the emulator is fitted to. One MAgPIE
# |  run for every pairing of a bioenergy price level with a GHG price level,
# |  7 x 12 = 84 by default, bioenergy price outer and GHG price inner.
# |
# |  Bioenergy no longer enters as a price here. It enters as the demand
# |  trajectory stage 2 settled on, selected by name, with the bioenergy prices
# |  themselves at MAgPIE's default of zero. Land-use intensity is solved for
# |  again. What is swept is the GHG price trajectory, also selected by name.
# |  Both sets of trajectories arrive in the patch tarball patch_step3 builds:
# |
# |      Rscript messageix/patches/build_step3_patch.R --preset=<name> --f56=PATH
# |
# |  The driver finds that tarball by name. Pass --patch=NAME when more than one
# |  is on disk.
# |
# |  The matrix step reads these runs -- every one of the 84 report.mif files and
# |  every fulldata.gdx -- and stops if one is missing or unsolved, so let this
# |  stage finish before starting it.
# |
# |  Usage, from the MAgPIE model root:
# |    Rscript messageix/start/driver_step3_demand.R               # run the sweep
# |    Rscript messageix/start/driver_step3_demand.R --list        # print the run set
# |    Rscript messageix/start/driver_step3_demand.R --validate    # print the assembled cfg
# |    Rscript messageix/start/driver_step3_demand.R --dry-run
# |    Rscript messageix/start/driver_step3_demand.R --patch=NAME
# |    Rscript messageix/start/driver_step3_demand.R --preset=NAME --csv=PATH
# |
# |  Before this: Rscript messageix/patches/build_step3_patch.R

source("messageix/start/run_stage.R")

main <- function() {
  run_driver_main(
    stage    = 3,
    headline = "stage 3 - demand-driven GHG price sweep (the emulator training set)",
    notes    = c(
      "technological change" = "solved for, not imposed (endo_jan22)",
      "bioenergy"            = "demand trajectory from stage 2 via c60_2ndgen_biodem; prices at their default of zero",
      "swept"                = "c56_pollutant_prices and c56_pollutant_prices_noselect, in lockstep",
      "non-CO2 price cap"    = "s56_limit_ch4_n2o_price from nonco2_price_cap_usd17_tc, USD17MER per tC",
      "patch tarball"        = "carries f60_bioenergy_dem.cs3 and f56_pollutant_prices.cs3; built by patch_step3 (messageix/patches/build_step3_patch.R)",
      "read by"              = "the matrix step, messageix/emulator/ - report.mif and fulldata.gdx of every run"
    )
  )
}

# Only when this file is the command being run, so that sourcing it for one of
# its functions does not start a sweep. Every entry point of the pipeline uses
# this same guard.
if (invoked_directly("driver_step3_demand.R")) main()
