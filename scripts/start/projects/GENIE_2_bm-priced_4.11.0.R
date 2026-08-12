# |  (C) 2008-2025 Potsdam Institute for Climate Impact Research (PIK)
# |  authors, and contributors see CITATION.cff file. This file is part
# |  of MAgPIE and licensed under AGPL-3.0-or-later. Under Section 7 of
# |  AGPL-3.0, you are granted additional permissions described in the
# |  MAgPIE License Exception, version 1.0 (see LICENSE file).
# |  Contact: magpie@pik-potsdam.de

# ----------------------------------------------------------
# description: GENIE project MESSAGE-MAgPIE Emulator - Step 2 - generate price-driven biomass demands
# ----------------------------------------------------------

######################################
#### Script to start a MAgPIE run ####
######################################

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
cfg$force_replace <- TRUE
cfg$qos <- "priority"

# Setting the time horizon to what we expect for MESSAGE: 2110.
cfg$gms$c_timesteps <- "coup2110"

###############################################################
# SSP2: "MIDDLE OF THE ROAD" = BUSINESS AS USUAL.
###############################################################

ssp_flag <- "SSP2"

cfg$input <- c(regional    = "rev4.119_5ff27be8_magpie.tgz",
               cellular    = "rev4.119_5ff27be8_1b5c3817_cellularmagpie_c200_MRI-ESM2-0-ssp245_lpjml-8e6c5eb1.tgz",
               validation  = "rev4.119_5ff27be8_validation.tgz",
               additional  = "additional_data_rev4.62.tgz",
               patch       = "SSP2_price.tgz")


cfg$output <- c("output_check", "rds_report")

### Identifier and folder
###############################################
identifierFlag <- "MESSAGEix_5ff27be8"
cfg$title <- "SSP2_price"
###############################################

# Set the identifier flag for shiny app, and output folder.
cfg$info$flag <- identifierFlag
cfg$results_folder <- paste0("output/", identifierFlag, "/:title:")

# Set the SSP scenario in the scenario_config.csv file to SSP1.
cfg <- setScenario(cfg, "SSP2")

# Cost of technological change
cfg$gms$c13_tccost <- "high"

# Yields scenario should not reflect climate change
cfg$gms$c14_yields_scenario  <- "nocc"


# Capping the annual max cropland growth per year per region, relative to current level
cfg$gms$s30_annual_max_growth <- 0.02


### Cost of missing BII set to 10 million USD rather than 1 million as in default.cfg
cfg$gms$s44_cost_bii_missing <- 10000000

# No GHG price
cfg$gms$c56_pollutant_prices <- "SSPDB-SSP2-Ref-MESSAGE-GLOBIOM" # def = R34M410-SSP2-NPi2025, here we need 0 across all regions and periods
cfg$gms$c56_pollutant_prices_noselect <- "SSPDB-SSP2-Ref-MESSAGE-GLOBIOM" # def = R34M410-SSP2-NPi2025, here we need 0 across all regions and periods


# ### BE
cfg$gms$s60_2ndgen_bioenergy_dem_min <- 0
cfg$gms$s60_bioenergy_1st_subsidy <- 0
# BE price incentive 0, 5, 7, 10, 15, 25, 45 2005USD/GJ, but in MAgPIE 2017 USD is used, so scale by 1.23  
beV <- c(0, 5, 7, 10, 15, 25, 45) # for folder naming, don't scale; for the value used in optimization, scale

### Tau / Yield
cfg$gms$tc <- "exo"

### Biodiv
blV <- c(0) # Options: 0, 0.7, 0.74, 0.78

### Microbiol protein (MP) Food
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
# BE price incentive 0, 5, 7, 10, 15, 25, 45 2005USD/GJ, but in MAgPIE 2017 USD is used, so scale by 1.23  
    for (be in beV) {
      cfg$gms$s60_bioenergy_1st_price <- be * 1.23
      cfg$gms$s60_bioenergy_2nd_price <- be * 1.23

      ##############################################
      cfg$title <- paste0(preflag, "_BE", str_pad(be, 2, pad = "0"), "_G0000", "price")

      start_run(cfg, codeCheck = FALSE)

    } # BE
  } # MP replacement
} # BII lower bound