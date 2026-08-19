# |  Stage 2 of the MAgPIE -> MESSAGEix emulator pipeline: the price-driven runs.
# |
# |  One MAgPIE run per bioenergy price level the narrative sweeps, seven by
# |  default. Each pays the same price for first- and second-generation
# |  bioenergy and holds everything else still: land-use intensity fixed at the
# |  stage-1 tau trajectory, and a GHG price scenario that is zero in every
# |  region and every period. The bioenergy price is therefore the only thing
# |  moving, and what the sweep produces is seven levels of second-generation
# |  bioenergy demand -- not seven scenarios.
# |
# |  It needs the patch tarball patch_step2 builds, which is what puts the fixed
# |  tau trajectory where MAgPIE reads it:
# |
# |      Rscript messageix/patches/build_step2_patch.R --preset=<name>
# |
# |  The driver finds that tarball by name. Pass --patch=NAME when more than one
# |  is on disk.
# |
# |  patch_step3 reads these runs: the bioenergy demand they settled on becomes
# |  the demand trajectories stage 3 is driven by.
# |
# |  Usage, from the MAgPIE model root:
# |    Rscript messageix/start/driver_step2_price.R                # run the sweep
# |    Rscript messageix/start/driver_step2_price.R --list         # print the run set
# |    Rscript messageix/start/driver_step2_price.R --validate     # print the assembled cfg
# |    Rscript messageix/start/driver_step2_price.R --dry-run
# |    Rscript messageix/start/driver_step2_price.R --patch=NAME
# |    Rscript messageix/start/driver_step2_price.R --preset=NAME --csv=PATH
# |
# |  Before this: Rscript messageix/patches/build_step2_patch.R
# |  After this:  Rscript messageix/patches/build_step3_patch.R

source("messageix/start/run_stage.R")

main <- function() {
  run_driver_main(
    stage    = 2,
    headline = "stage 2 - price-driven bioenergy sweep",
    notes    = c(
      "technological change" = "fixed (tc = exo) at the stage-1 tau trajectory",
      "swept"                = "s60_bioenergy_1st_price and s60_bioenergy_2nd_price, USD2005 per GJ x currency_2005_to_2017",
      "GHG price"            = "a scenario that is zero everywhere, so the bioenergy price is the only signal",
      "patch tarball"        = "carries f13_tau_scenario.csv; built by patch_step2 (messageix/patches/build_step2_patch.R)",
      "read by"              = "patch_step3 (messageix/patches/build_step3_patch.R) -> f60_bioenergy_dem.cs3 columns"
    )
  )
}

# Only when this file is the command being run, so that sourcing it for one of
# its functions does not start a sweep. Every entry point of the pipeline uses
# this same guard.
if (invoked_directly("driver_step2_price.R")) main()
