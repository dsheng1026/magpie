library(lucode2)
library(magclass)
library(gms)
library(stringr)

# Load start_run(cfg) function which is needed to start MAgPIE runs
source("scripts/start_functions.R") #nolinter
# Source the default config and then over-write it before starting the run.
source("config/default.cfg") #nolinter

cfg$repositories <- append(list("https://rse.pik-potsdam.de/data/magpie/public" = NULL,
                                "./patch_input" = NULL),
                           getOption("magpie_repos"))

# Folder creation and SLURM queue settings.
cfg$force_replace <- TRUE # over write the output, otherwise, stop if same output name exist
cfg$qos <- "priority"

# Setting the time horizon to what we expect for MESSAGE: 2110.
cfg$gms$c_timesteps <- "coup2110"

###############################################################
# SSP2: "MIDDLE OF THE ROAD" = BUSINESS AS USUAL.
###############################################################

ssp_flag <- "SSP2"

cfg$input <- c(regional    = "rev4.119_5ff27be8_magpie.tgz",
               cellular    = "rev4.119_5ff27be8_1b5c3817_cellularmagpie_c200_MRI-ESM2-0-ssp245_lpjml-8e6c5eb1.tgz",
            #    cellular    = "rev4.119_5ff27be8_fd712c0b_cellularmagpie_c200_MRI-ESM2-0-ssp370_lpjml-8e6c5eb1.tgz",
               validation  = "rev4.119_5ff27be8_validation.tgz",
               additional  = "additional_data_rev4.62.tgz",
              #  patch       = "SSP2.tgz"
               patch       = "SSP2_old.tgz")

# # which input data sets should be used?
# cfg$input <- c(regional    = "rev4.87_26df900e_magpie.tgz",
#                cellular    = "rev4.87_26df900e_fd712c0b_cellularmagpie_c200_MRI-ESM2-0-ssp370_lpjml-8e6c5eb1.tgz",
#                validation  = "rev4.87_26df900e_validation.tgz",
#                additional  = "additional_data_rev4.62.tgz",
#            patch = "SSP2_old.tgz")


cfg$output <- c("output_check", "rds_report")

### Identifier and folder
###############################################
identifierFlag <- "Matrix_test_rev1" # name of output folder, you name it, use the same name for price and demand driven run
cfg$title <- "MESSAGE_historical_2-gen_BE_data" # this is required for shiny only, keep it as it is
###############################################

# Set the identifier flag for shiny app, and output folder.
cfg$info$flag <- identifierFlag
cfg$results_folder <- paste0("output/", identifierFlag, "/:title:")

# Set the SSP scenario in the scenario_config.csv file to SSP1.
cfg <- setScenario(cfg, "SSP2")

# # Recalculate NPI/NDC switch
# cfg$recalc_npi_ndc <- TRUE
cfg$recalc_npi_ndc <- FALSE

# # Recalculate land conversion cost
# cfg$recalibrate_landconversion_cost <- TRUE

# settings needed for M-M linkage --------

# Cost of technological change
cfg$gms$c13_tccost <- "high"

# Yields scenario should not reflect climate change
cfg$gms$c14_yields_scenario  <- "nocc"

# # Year at which land conservation is reached
# cfg$gms$s22_conservation_target <- 2035

# # Updating SNV policy parameters: decreasing start year from 2050 to 2035
# cfg$gms$s29_snv_scenario_target <- 2035

# # Forestry and pasture are also added to SNV policy land types
# cfg$gms$land_snv <- "secdforest, forestry, past, other"

# Capping the annual max cropland growth per year per region, relative to current level
cfg$gms$s30_annual_max_growth <- 0.02

# # No harvesting or establishment of new plantations
# cfg$gms$s32_hvarea <- 0

# # No timber production from natveg
# cfg$gms$s35_hvarea <- 0

### Cost of missing BII set to 10 million USD rather than 1 million as in default.cfg
# cfg$gms$s44_cost_bii_missing <- 10000000

# end of the M-M specific changed --------

# No GHG price

# G0000exp2110: exponential carbon price trejactory determined by Jan.S JPD and Keywan
cfg$gms$c56_pollutant_prices <- "G0000exp2110" # def = R34M410-SSP2-NPi2025, "G0000"
cfg$gms$c56_pollutant_prices_noselect <- "G0000exp2110" # def = R34M410-SSP2-NPi2025, "G0000"

# # Bioenergy production settings:
# cfg$gms$c60_1stgen_biodem <- "phaseout2020"


# price-driven step: mute these two for price-driven run

# cfg$gms$c60_2ndgen_biodem <- "MESSAGE_SSP2_historical_BE" # def = R34M410-SSP2-NPi2025
# in selected iso, there is biomass price, nonselect muted for biomass price, details in config.
# cfg$gms$c60_2ndgen_biodem_noselect <- "MESSAGE_SSP2_historical_BE" # def = R34M410-SSP2-NPi2025


# ### BE
cfg$gms$s60_2ndgen_bioenergy_dem_min <- 0
cfg$gms$s60_bioenergy_1st_subsidy <- 0

beV <- c(0, 5, 7, 10, 15, 25, 45) # Options: 0, 5, 7, 10, 15, 25, 45

### Tau / Yield
cfg$gms$tc <- "exo"

### Biodiv
blV <- c(0) # Options: 0, 0.7, 0.74, 0.78

### Food
mpV <- c(0) # Options: 0, 25, 50, 75


for (bl in blV) {
  bd <- 0
  pa <- "none" # "BH"
  if (bl == 0) {
    bd <- 1
    pa <- "none"
  }

  cfg$gms$c44_bii_decrease <- bd
  cfg$gms$s44_bii_target <- bl
  cfg$gms$c22_protect_scenario <- pa

  for (mp in mpV) {
    preflag <- paste0("SSP2_BD", str_pad(bl * 100, 2, pad = "0"))
    cfg$results_folder <- paste("output", identifierFlag, preflag, ":title:", sep = "/")
    cfg$info$flag2 <- preflag

    cfg$gms$s15_rumdairy_scp_substitution <- mp / 100

    for (be in beV) {
      cfg$gms$s60_bioenergy_1st_price <- be
      cfg$gms$s60_bioenergy_2nd_price <- be

      ##############################################
      runflag <- "price"
      cfg$title <- paste0(preflag, "_BE", str_pad(be, 2, pad = "0"), "_G0000", runflag, "_rev1")

      start_run(cfg, codeCheck = FALSE)

    } # BE
  } # MP replacement
} # BII lower bound