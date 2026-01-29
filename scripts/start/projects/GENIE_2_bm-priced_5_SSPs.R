# |  (C) 2008-2025 Potsdam Institute for Climate Impact Research (PIK)
# |  authors, and contributors see CITATION.cff file. This file is part
# |  of MAgPIE and licensed under AGPL-3.0-or-later. Under Section 7 of
# |  AGPL-3.0, you are granted additional permissions described in the
# |  MAgPIE License Exception, version 1.0 (see LICENSE file).
# |  Contact: magpie@pik-potsdam.de

# ----------------------------------------------------------
# description: GENIE project MESSAGE-MAgPIE Emulator - Step 2 - price-based biomass potential
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
cfg$force_replace <- FALSE
cfg$qos <- "priority"

# Setting the time horizon to what we expect for MESSAGE: 2110.
cfg$gms$c_timesteps <- "coup2110"

# Capping the annual max cropland growth per year per region, relative to current level
cfg$gms$s30_annual_max_growth <- 0.02

# ###############################################################
# # Generating tau trajectories for each SSP. First, SSP1.
# # SSP1: "TAKING THE GREEN ROAD" = SUSTAINABILITY. 
# ###############################################################

# ssp_flag <- "SSP1"

# cfg$input <- c(regional    = "rev4.119_5ff27be8_magpie.tgz",
#                cellular    = "rev4.119_5ff27be8_6819938d_cellularmagpie_c200_MRI-ESM2-0-ssp126_lpjml-8e6c5eb1.tgz",
#                validation  = "rev4.119_5ff27be8_validation.tgz",
#                additional  = "additional_data_rev4.62.tgz",
#                patch       = "SSP1.tgz")

# cfg$output <- c("output_check", "rds_report")

# ### Identifier and folder
# ###############################################
# identifierFlag <- "MESSAGEix_5ff27be8"
# cfg$title <- "MESSAGE_R12_5ff27be8_SSP1_6819938d_BE_price"
# ###############################################

# # Set the identifier flag for shiny app, and output folder.
# cfg$info$flag <- identifierFlag
# cfg$results_folder <- paste0("output/", identifierFlag, "/:title:")

# # Set the SSP scenario in the scenario_config.csv file to SSP1.
# cfg <- setScenario(cfg, "SSP1")

# ### BE
# cfg$gms$s60_2ndgen_bioenergy_dem_min <- 0
# cfg$gms$s60_bioenergy_1st_subsidy <- 0
# beV <- c(0, 5, 7, 10, 15, 25, 45)

# ### Tau / Yield
# cfg$gms$tc <- "exo"

# ### Biodiv
# blV <- c(0, 0.78) # Options: 0, 0.7, 0.74, 0.78

# ### Food
# mpV <- c(0) # Options: 0, 25, 50, 75


# for (bl in blV) {
#   bd <- 0
#   pa <- "BH"
#   if (bl == 0) {
#     bd <- 1
#     pa <- "none"
#   }

#   cfg$gms$c44_bii_decrease <- bd
#   cfg$gms$s44_bii_target <- bl
#   cfg$gms$c22_protect_scenario <- pa

#   for (mp in mpV) {
#     preflag <- paste0(ssp_flag, "MP", str_pad(mp, 2, pad = "0"), "BD", str_pad(bl * 100, 2, pad = "0"))
#     cfg$results_folder <- paste("output", identifierFlag, preflag, ":title:", sep = "/")
#     cfg$info$flag2 <- preflag

#     cfg$gms$s15_rumdairy_scp_substitution <- mp / 100

#     for (be in beV) {
#       cfg$gms$s60_bioenergy_1st_price <- be
#       cfg$gms$s60_bioenergy_2nd_price <- be

#       ##############################################
#       runflag <- "price"
#       cfg$title <- paste0(preflag, "BE", str_pad(be, 2, pad = "0"), "G0000", runflag)

#       start_run(cfg, codeCheck = FALSE)

#     } # BE
#   } # MP replacement
# } # BII lower bound

###############################################################
# SSP2: "MIDDLE OF THE ROAD" = BUSINESS AS USUAL.
###############################################################

ssp_flag <- "SSP2"

cfg$input <- c(regional    = "rev4.119_5ff27be8_magpie.tgz",
               cellular    = "rev4.119_5ff27be8_1b5c3817_cellularmagpie_c200_MRI-ESM2-0-ssp245_lpjml-8e6c5eb1.tgz",
               validation  = "rev4.119_5ff27be8_validation.tgz",
               additional  = "additional_data_rev4.62.tgz",
               patch       = "SSP2.tgz")

cfg$output <- c("output_check", "rds_report")

### Identifier and folder
###############################################
identifierFlag <- "MESSAGEix_5ff27be8"
cfg$title <- "MESSAGE_R12_5ff27be8_SSP2_1b5c3817_BE_price"
###############################################

# Set the identifier flag for shiny app, and output folder.
cfg$info$flag <- identifierFlag
cfg$results_folder <- paste0("output/", identifierFlag, "/:title:")

# Set the SSP scenario in the scenario_config.csv file to SSP1.
cfg <- setScenario(cfg, "SSP2")

### Cost of missing BII set to 10 million USD rather than 1 million as in default.cfg
cfg$gms$s44_cost_bii_missing <- 10000000

### BE
cfg$gms$s60_2ndgen_bioenergy_dem_min <- 0
cfg$gms$s60_bioenergy_1st_subsidy <- 0
beV <- c(45) # Options: 0, 5, 7, 10, 15, 25, 45

### Tau / Yield
cfg$gms$tc <- "exo"

### Biodiv
blV <- c(0, 0.78) # Options: 0, 0.7, 0.74, 0.78

### Food
mpV <- c(0) # Options: 0, 25, 50, 75


for (bl in blV) {
  bd <- 0
  pa <- "BH"
  if (bl == 0) {
    bd <- 1
    pa <- "none"
  }

  cfg$gms$c44_bii_decrease <- bd
  cfg$gms$s44_bii_target <- bl
  cfg$gms$c22_protect_scenario <- pa

  for (mp in mpV) {
    preflag <- paste0(ssp_flag, "MP", str_pad(mp, 2, pad = "0"), "BD", str_pad(bl * 100, 2, pad = "0"))
    cfg$results_folder <- paste("output", identifierFlag, preflag, ":title:", sep = "/")
    cfg$info$flag2 <- preflag

    cfg$gms$s15_rumdairy_scp_substitution <- mp / 100

    for (be in beV) {
      cfg$gms$s60_bioenergy_1st_price <- be
      cfg$gms$s60_bioenergy_2nd_price <- be

      ##############################################
      runflag <- "price"
      cfg$title <- paste0(preflag, "BE", str_pad(be, 2, pad = "0"), "G0000", runflag, "_rev4")

      start_run(cfg, codeCheck = FALSE)

    } # BE
  } # MP replacement
} # BII lower bound