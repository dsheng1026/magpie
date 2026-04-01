# |  (C) 2008-2025 Potsdam Institute for Climate Impact Research (PIK)
# |  authors, and contributors see CITATION.cff file. This file is part
# |  of MAgPIE and licensed under AGPL-3.0-or-later. Under Section 7 of
# |  AGPL-3.0, you are granted additional permissions described in the
# |  MAgPIE License Exception, version 1.0 (see LICENSE file).
# |  Contact: magpie@pik-potsdam.de

# ----------------------------------------------------------
# description: GENIE project MESSAGE-MAgPIE Emulator Default script
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


cfg$input <- c(regional    = "rev4.119_26df900e_magpie.tgz",
               cellular    = "rev4.119_26df900e_1b5c3817_cellularmagpie_c200_MRI-ESM2-0-ssp245_lpjml-8e6c5eb1.tgz",
               validation  = "rev4.119_26df900e_validation.tgz",
               additional  = "additional_data_rev4.62.tgz",
               patch       = "SSP2_old.tgz")


cfg$output <- c("output_check", "rds_report")

# No GHG price
cfg$gms$c56_pollutant_prices <- "G0000exp2110" # def = R34M410-SSP2-NPi2025, "G0000"
cfg$gms$c56_pollutant_prices_noselect <- "G0000exp2110" # def = R34M410-SSP2-NPi2025, "G0000"


# ### Identifier and folder
# ###############################################
# identifierFlag <- "MESSAGEix"
# cfg$title <- "MESSAGE_default_rev4.119_without_GENIE_presets"
# ###############################################
# cfg$info$flag <- identifierFlag

# start_run(cfg, codeCheck = FALSE)

# #load GENIE config presets, write it before starting the run.
# # cfg <- setScenario(cfg, "SSP2")
# preset <-  "GENIE_SCP"
# cfg <- setScenario(cfg, c(preset), scenario_config = "config/projects/scenario_config_genie.csv")

# ### Folder
# ###############################################
# cfg$title <- "MESSAGE_default_rev4.119_with_GENIE_presets"
# ###############################################

# ##########################################################
# start_run(cfg, codeCheck = FALSE)

### Identifier and folder
###############################################
identifierFlag <- "MESSAGE_settings_test_SSP2"
cfg$title <- "MESSAGE_settings_test_SSP2"
###############################################
cfg$info$flag <- identifierFlag

# 
cfg <- setScenario(cfg, "SSP2")

start_run(cfg, codeCheck = FALSE)
