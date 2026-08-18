# |  Stage 2 of the MAgPIE -> MESSAGEix emulator pipeline: the price-driven runs.
# |
# |  WHAT THESE RUNS ARE. One MAgPIE run per level of pipeline$be_prices, seven
# |  by default. Each imposes a bioenergy price on both first- and
# |  second-generation bioenergy (s60_bioenergy_1st_price, s60_bioenergy_2nd_price,
# |  the level in USD2005/GJ times pipeline$currency_2005_to_2017) and holds
# |  everything else still: technological change is exogenous from stage 1
# |  (cfg$gms$tc = "exo") and the GHG price scenario is one that is zero in every
# |  region and period. The bioenergy price is therefore the only signal moving,
# |  and what the sweep produces is a set of second-generation bioenergy demand
# |  levels, not a set of scenarios.
# |
# |  THE PATCH TARBALL THIS STAGE NEEDS. Exogenous tau is read from
# |  f13_tau_scenario.csv, which reaches modules/13_tc/input/ only through the
# |  patch tarball that step 1.5 builds from the stage-1 run:
# |
# |      Rscript messageix/patches/build_step2_patch.R --preset=<name>
# |
# |  The tarball name carries an 8-character hash of its contents, so this driver
# |  finds it rather than being told: MAgPIE decides whether to re-extract inputs
# |  by comparing tarball file names, never checksums, and a fixed name would let
# |  a regenerated tarball be silently ignored. Pass --patch=NAME when more than
# |  one generated tarball is on disk.
# |
# |  WHAT CONSUMES THE OUTPUT. Step 2.5,
# |  messageix/patches/build_step3_patch.R, reads the realised second-generation
# |  bioenergy demand out of the seven fulldata.gdx files and writes it as the
# |  <narrative>_BE<level> columns of f60_bioenergy_dem.cs3, which stage 3 then
# |  selects by name.
# |
# |  Usage, from the MAgPIE model root:
# |    Rscript messageix/start/driver_step2_price.R                # run the sweep
# |    Rscript messageix/start/driver_step2_price.R --list         # print the run set
# |    Rscript messageix/start/driver_step2_price.R --validate     # print the assembled cfg
# |    Rscript messageix/start/driver_step2_price.R --dry-run
# |    Rscript messageix/start/driver_step2_price.R --patch=NAME
# |    Rscript messageix/start/driver_step2_price.R --preset=NAME --csv=PATH
# |
# |  Previous: Rscript messageix/patches/build_step2_patch.R
# |  Next:     Rscript messageix/patches/build_step3_patch.R

source("messageix/start/run_stage.R")

main <- function() {
  run_driver_main(
    stage    = 2,
    headline = "stage 2 - price-driven bioenergy sweep",
    notes    = c(
      "technological change" = "exogenous (tc = exo) from the stage-1 tau trajectory",
      "swept"                = "s60_bioenergy_1st_price and s60_bioenergy_2nd_price, USD2005/GJ x currency_2005_to_2017",
      "GHG price"            = "a scenario that is zero everywhere, so the bioenergy price is the only signal",
      "patch tarball"        = "carries f13_tau_scenario.csv; built by messageix/patches/build_step2_patch.R",
      "consumed by"          = "messageix/patches/build_step3_patch.R -> f60_bioenergy_dem.cs3 columns"
    )
  )
}

if (!interactive()) main()
