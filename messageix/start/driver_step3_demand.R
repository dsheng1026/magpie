# |  Stage 3 of the MAgPIE -> MESSAGEix emulator pipeline: the demand-driven runs.
# |
# |  WHAT THESE RUNS ARE. The emulator training set: one MAgPIE run for every
# |  pair of pipeline$be_prices and pipeline$ghg_prices, 7 x 12 = 84 by default,
# |  bioenergy price outer and GHG price inner. Bioenergy no longer enters as a
# |  price. It enters as the demand trajectory stage 2 realised, selected by name
# |  through cfg$gms$c60_2ndgen_biodem out of the columns the step-2.5 generator
# |  appended to f60_bioenergy_dem.cs3; the bioenergy prices themselves stay at
# |  MAgPIE's default of zero. Technological change is endogenous again. What is
# |  swept is the GHG price trajectory, selected through cfg$gms$c56_pollutant_prices
# |  out of the columns the same generator appended to f56_pollutant_prices.cs3.
# |
# |  TWO ENCODINGS OF THE BIOENERGY PRICE LEVEL, both required. Run folders use a
# |  zero-padded token (BE05); the demand column name is unpadded
# |  (<narrative>_BE5) and must match byte for byte what the step-2.5 generator
# |  wrote. Both come from utils_paths.R, from the same integer.
# |
# |  THE NON-CO2 CAP IS A CONFIG VALUE. cfg$gms$s56_limit_ch4_n2o_price is set
# |  from pipeline$nonco2_price_cap_usd17_tc (default 200 USD17MER per tC, about
# |  55 USD17 per tCO2, against MAgPIE's default of 4920). GAMS applies it to
# |  whichever GHG price scenario is selected, so the patch tarball carries
# |  uncapped trajectories and changing the cap needs no file inside it touched.
# |
# |  BOTH GHG PRICE SWITCHES MOVE TOGETHER. c56_pollutant_prices and
# |  c56_pollutant_prices_noselect are set in lockstep, in stage_cfg()
# |  (messageix/R/utils_config.R). The second one governs the countries outside
# |  policy_countries56; left behind at a zero-price scenario it is inert only
# |  while that set covers every country, and becomes a silent bug the moment a
# |  narrative narrows it.
# |
# |  THE PATCH TARBALL THIS STAGE NEEDS. Both the bioenergy demand columns and
# |  the GHG price columns arrive through one content-hashed tarball:
# |
# |      Rscript messageix/patches/build_step3_patch.R --preset=<name>
# |
# |  This driver finds it by name pattern rather than assuming one; pass
# |  --patch=NAME when more than one generated tarball is on disk.
# |
# |  WHAT CONSUMES THE OUTPUT. Step 4, messageix/emulator/: report.mif from every
# |  one of the 84 runs through MM_linkage_mapping.csv into the emulator matrix,
# |  plus woodfuel read from the 84 fulldata.gdx files. The matrix build stops if
# |  any run is missing or unsolved, so let this stage finish before starting it.
# |
# |  Usage, from the MAgPIE model root:
# |    Rscript messageix/start/driver_step3_demand.R               # run the sweep
# |    Rscript messageix/start/driver_step3_demand.R --list        # print the run set
# |    Rscript messageix/start/driver_step3_demand.R --validate    # print the assembled cfg
# |    Rscript messageix/start/driver_step3_demand.R --dry-run
# |    Rscript messageix/start/driver_step3_demand.R --patch=NAME
# |    Rscript messageix/start/driver_step3_demand.R --preset=NAME --csv=PATH
# |
# |  Previous: Rscript messageix/patches/build_step3_patch.R

source("messageix/start/run_stage.R")

main <- function() {
  run_driver_main(
    stage    = 3,
    headline = "stage 3 - demand-driven GHG price sweep (emulator training set)",
    notes    = c(
      "technological change" = "endogenous (endo_jan22)",
      "bioenergy"            = "demand trajectory from stage 2 via c60_2ndgen_biodem; prices at their default of zero",
      "swept"                = "c56_pollutant_prices and c56_pollutant_prices_noselect, in lockstep",
      "non-CO2 price cap"    = "s56_limit_ch4_n2o_price from pipeline$nonco2_price_cap_usd17_tc, USD17MER per tC",
      "patch tarball"        = "carries f60_bioenergy_dem.cs3 and f56_pollutant_prices.cs3; built by messageix/patches/build_step3_patch.R",
      "consumed by"          = "messageix/emulator/ - report.mif and fulldata.gdx of every run"
    )
  )
}

if (!interactive()) main()
