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

###############################################################
# We generate one default MAgPIE run for each SSP. First, SSP1.
# SSP1: "TAKING THE GREEN ROAD" = SUSTAINABILITY. 
###############################################################

cfg$input <- c(regional    = "rev4.119_5ff27be8_magpie.tgz",
               cellular    = "rev4.119_5ff27be8_6819938d_cellularmagpie_c200_MRI-ESM2-0-ssp126_lpjml-8e6c5eb1.tgz",
               validation  = "rev4.119_5ff27be8_validation.tgz",
               additional  = "additional_data_rev4.62.tgz")
               # patch       = "MMEmuR12_rev4.96.tgz")


cfg$output <- c("output_check", "rds_report")

### Identifier and folder
###############################################
identifierFlag <- "MESSAGEix_5ff27be8"
cfg$title <- "MESSAGE_R12_5ff27be8_SSP1_6819938d_default"
###############################################
cfg$info$flag <- identifierFlag

# Set the SSP scenario in the scenario_config.csv file to SSP1.
cfg <- setScenario(cfg, "SSP1")

# Start run.
start_run(cfg, codeCheck = FALSE)

###############################################################
# SSP2: "MIDDLE OF THE ROAD" = BUSINESS AS USUAL.
###############################################################

cfg$input <- c(regional    = "rev4.119_5ff27be8_magpie.tgz",
               cellular    = "rev4.119_5ff27be8_1b5c3817_cellularmagpie_c200_MRI-ESM2-0-ssp245_lpjml-8e6c5eb1.tgz",
               validation  = "rev4.119_5ff27be8_validation.tgz",
               additional  = "additional_data_rev4.62.tgz")
               # patch       = "MMEmuR12_rev4.96.tgz")


cfg$output <- c("output_check", "rds_report")

### Identifier and folder
###############################################
identifierFlag <- "MESSAGEix_5ff27be8"
cfg$title <- "MESSAGE_R12_5ff27be8_SSP2_1b5c3817_default"
###############################################
cfg$info$flag <- identifierFlag

# Set the SSP scenario in the scenario_config.csv file to SSP2.
cfg <- setScenario(cfg, "SSP2")

# Start run.
start_run(cfg, codeCheck = FALSE)

###############################################################
# SSP3: "A ROCKY ROAD" = REGIONAL RIVALRY.
###############################################################

cfg$input <- c(regional    = "rev4.119_5ff27be8_magpie.tgz",
               cellular    = "rev4.119_5ff27be8_fd712c0b_cellularmagpie_c200_MRI-ESM2-0-ssp370_lpjml-8e6c5eb1.tgz",
               validation  = "rev4.119_5ff27be8_validation.tgz",
               additional  = "additional_data_rev4.62.tgz")
               # patch       = "MMEmuR12_rev4.96.tgz")


cfg$output <- c("output_check", "rds_report")

### Identifier and folder
###############################################
identifierFlag <- "MESSAGEix_5ff27be8"
cfg$title <- "MESSAGE_R12_5ff27be8_SSP3_fd712c0b_default"
###############################################
cfg$info$flag <- identifierFlag

# Set the SSP scenario in the scenario_config.csv file to SSP3.
cfg <- setScenario(cfg, "SSP3")

# Start run.
start_run(cfg, codeCheck = FALSE)

###############################################################
# SSP4: "A ROAD DIVIDED" = INEQUALITY.
###############################################################

cfg$input <- c(regional    = "rev4.119_5ff27be8_magpie.tgz",
               cellular    = "rev4.119_5ff27be8_3c888fa5_cellularmagpie_c200_MRI-ESM2-0-ssp460_lpjml-8e6c5eb1.tgz",
               validation  = "rev4.119_5ff27be8_validation.tgz",
               additional  = "additional_data_rev4.62.tgz")
               # patch       = "MMEmuR12_rev4.96.tgz")


cfg$output <- c("output_check", "rds_report")

### Identifier and folder
###############################################
identifierFlag <- "MESSAGEix_5ff27be8"
cfg$title <- "MESSAGE_R12_5ff27be8_SSP4_3c888fa5_default"
###############################################
cfg$info$flag <- identifierFlag

# Set the SSP scenario in the scenario_config.csv file to SSP4.
cfg <- setScenario(cfg, "SSP4")

# Start run.
start_run(cfg, codeCheck = FALSE)

###############################################################
# SSP5: "TAKING THE HIGHWAY" = FOSSIL-FUELED DEVELOPMENT.
###############################################################

cfg$input <- c(regional    = "rev4.119_5ff27be8_magpie.tgz",
               cellular    = "rev4.119_5ff27be8_09a63995_cellularmagpie_c200_MRI-ESM2-0-ssp585_lpjml-8e6c5eb1.tgz",
               validation  = "rev4.119_5ff27be8_validation.tgz",
               additional  = "additional_data_rev4.62.tgz")
               # patch       = "MMEmuR12_rev4.96.tgz")


cfg$output <- c("output_check", "rds_report")

### Identifier and folder
###############################################
identifierFlag <- "MESSAGEix_5ff27be8"
cfg$title <- "MESSAGE_R12_5ff27be8_SSP5_09a63995_default"
###############################################
cfg$info$flag <- identifierFlag

# Set the SSP scenario in the scenario_config.csv file to SSP5.
cfg <- setScenario(cfg, "SSP5")

# Start run.
start_run(cfg, codeCheck = FALSE)