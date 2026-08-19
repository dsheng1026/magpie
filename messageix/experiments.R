# |  The experiments this pipeline runs. This is the file you edit.
# |
# |  An experiment has two halves:
# |
# |    narrative()  the world the runs are made in -- the SSP, the region set,
# |                 how strictly biodiversity is protected, how costly yield
# |                 improvements are.
# |    design()     the sampling plan -- which bioenergy price levels the price
# |                 sweep visits, and which GHG price levels the demand sweep
# |                 visits. Leaving it out uses the grid the pipeline was tested
# |                 on: seven bioenergy prices and twelve GHG prices, which is 84
# |                 demand runs. One experiment is 92 MAgPIE runs in all -- one
# |                 calibration run, seven price runs, 84 demand runs.
# |
# |  Write only what differs from the defaults. Every lever of the world, what it
# |  means and what it may be, is registered in messageix/R/world_levers.R; the
# |  sampling plan's two settings are declared in messageix/R/utils_config.R.
# |
# |  The name on the left of each entry is the experiment's name. It becomes the
# |  output folder, the matrix file name and the bioenergy demand columns the
# |  runs hand to each other, so it takes letters, digits, dash and underscore
# |  only. `default` is the reference experiment and is named on purpose: it is
# |  the one that reproduces the runs behind magpie_input_SSP2_ref_woodfuel.csv,
# |  and its name is what keeps those files where they have always been.
# |
# |  Run them:
# |    Rscript messageix/run.R                    # every experiment, in order
# |    Rscript messageix/run.R biodiversity       # just this one
# |    Rscript messageix/run.R status             # what is finished, what would run

# The constructors, so this file can be read on its own.
if (!exists("narrative", mode = "function")) source("messageix/R/utils_config.R")

EXPERIMENTS <- list(

  # The reference experiment: MAgPIE's SSP2 world at R12, no biodiversity
  # target, yields without climate impacts. It reproduces the golden runs -- the
  # validated reference runs behind magpie_input_SSP2_ref_woodfuel.csv, which is
  # the matrix this pipeline has to be able to rebuild before it is trusted with
  # anything new (messageix/docs/pipeline.md, section 10).
  default = experiment(narrative(), design()),

  # High biodiversity protection under climate-impacted yields: 78 percent of
  # the biodiversity intactness index maintained, and crop yields that carry
  # climate change impacts.
  biodiversity = experiment(narrative(bii_target = 0.78, yields_scenario = "cc"))

  # The shared socioeconomic pathway and the set of world regions are levers of
  # the same kind, left at SSP2 and R12 by the two entries above. Written out
  # they look like this:
  #
  #   ssp5 = experiment(narrative(ssp = "SSP5")),
  #   r10  = experiment(narrative(region_set = "R10"))
  #
  # Both need more than the line, because both change which input data the runs
  # read. The cellular input tarball carries the climate forcing of one pathway,
  # so another SSP needs its own tarballs; and a region set is one entry in
  # messageix/R/pipeline_infrastructure.R pairing its tarballs with a
  # region-name table. R12 is the only region set the pipeline knows so far.

)

# A sweep over one setting is a loop, because the experiments are a list.
# Uncomment to run three biodiversity targets on a coarser GHG price grid:
#
# for (target in c(0.70, 0.74, 0.78)) {
#   name <- paste0("bii", target * 100)
#   EXPERIMENTS[[name]] <- experiment(
#     narrative(bii_target = target),
#     design(prices_ghg = c(0, 100, 500, 1000, 4000)))
# }
#
# Each entry gets its own output folder and its own matrix, so the runs of one
# cannot land on another's. A coarser grid is fewer runs: five GHG price levels
# across seven bioenergy price levels is 35 runs instead of 84.
