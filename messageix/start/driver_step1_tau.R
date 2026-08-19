# |  Stage 1 of the MAgPIE -> MESSAGEix emulator pipeline: the reference tau run.
# |
# |  One MAgPIE run, and what it is for is not its scenario result. It is tau,
# |  the trajectory of land-use intensity -- roughly, how much yield each region
# |  gets per hectare over time. Technological change is solved for here rather
# |  than imposed, which is what makes the trajectory meaningful; the seven
# |  stage-2 runs then hold tau fixed at it, so they differ from one another only
# |  in the bioenergy price. The run is made under the narrative's stage-1
# |  protection scenario and against its business-as-usual second-generation
# |  bioenergy demand path.
# |
# |  Tau lands in the run folder's fulldata.gdx, in the variable ov_tau
# |  (t, h, tautype, type); the "level" slice is the trajectory. patch_step2 is
# |  the only thing that reads this run.
# |
# |  It needs no patch tarball: the input tarballs described in messageix/inputs/
# |  carry every input it reads.
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
      "technological change" = "solved for, not imposed (endo_jan22): the tau trajectory is what this run is for",
      "what it produces"     = "ov_tau (level) in fulldata.gdx",
      "read by"              = "patch_step2 (messageix/patches/build_step2_patch.R) -> f13_tau_scenario.csv",
      "patch tarball"        = "none: stage 1 runs on the base input tarballs alone"
    )
  )
}

# Only when this file is the command being run, so that sourcing it for one of
# its functions does not start a sweep. Every entry point of the pipeline uses
# this same guard.
if (invoked_directly("driver_step1_tau.R")) main()
