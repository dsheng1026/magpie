# |  (C) 2008-2025 Potsdam Institute for Climate Impact Research (PIK)
# |  authors, and contributors see CITATION.cff file. This file is part
# |  of MAgPIE and licensed under AGPL-3.0-or-later. Under Section 7 of
# |  AGPL-3.0, you are granted additional permissions described in the
# |  MAgPIE License Exception, version 1.0 (see LICENSE file).
# |  Contact: magpie@pik-potsdam.de

# ----------------------------------------------------------
# description: GENIE project MESSAGE-MAgPIE Emulator - Step 3 - ghg price sensitivity for step 2 biomass demands
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
identifierFlag <- "<desired_output_folder_name>"
cfg$title <- "BE_test"
###############################################

# Set the identifier flag for shiny app, and output folder.
cfg$info$flag <- identifierFlag
cfg$results_folder <- paste0("output/", identifierFlag, "/:title:")

# Set the SSP scenario in the scenario_config.csv file to SSP1.
cfg <- setScenario(cfg, "SSP2")

# # Recalculate NPI/NDC switch
# cfg$recalc_npi_ndc <- TRUE

# # Recalculate land conversion cost
# cfg$recalibrate_landconversion_cost <- TRUE

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

# ### Cost of missing BII set to 10 million USD rather than 1 million as in default.cfg
# cfg$gms$s44_cost_bii_missing <- 10000000

# No GHG price
cfg$gms$c56_pollutant_prices <- "G0000exp2110" # def = R34M410-SSP2-NPi2025, "G0000"
cfg$gms$c56_pollutant_prices_noselect <- "G0000exp2110" # def = R34M410-SSP2-NPi2025, "G0000"

### BE
cfg$gms$s60_2ndgen_bioenergy_dem_min <- 0
cfg$gms$s60_bioenergy_1st_subsidy <- 0
beV <- c(0, 45) #0, 5, 7, 10, 15, 25, 45

### GHG
gV <- c(0, 4000) #0, 10, 20, 50, 100, 200, 400, 600, 1000, 2000, 3000, 4000

### Biodiv
blV <- c(0) #BII lower bound (0, 0.7, 0.74, 0.78), default 0

### Food
mpV <- c(0)

### Forest
cfg$gms$s32_max_aff_cell_2025 <- 0.005


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
    cfg$gms$s15_rumdairy_scp_substitution <- mp / 100

    preflag <- paste0("SSP2_BD", str_pad(bl * 100, 2, pad = "0"))
    
    cfg$results_folder <- paste(
      "output", identifierFlag, "SSP2_BD00", ":title:", sep = "/"
    )
    cfg$info$flag2 <- preflag

    for (be in beV) {

      be_str <- str_pad(be, 2, pad = "0")
      cfg$gms$c60_2ndgen_biodem <- paste0("SSP2_BD00_BE", be_str, "_G0000price_rev1")

      for (g in gV){

        g_str <- str_pad(g, 4, pad = "0")
        g_formatted <- paste0("G", g_str)

        cfg$gms$c56_pollutant_prices <- paste0(g_formatted, "exp2110")

        ##############################################
        cfg$title <- paste0("SSP2_BD00_BE", be_str, "_G", g_str, "demand_rev1")

        start_run(cfg, codeCheck = FALSE)

      } # GHG
    } # BE
  } # MP replacement
} # BII lower bound
