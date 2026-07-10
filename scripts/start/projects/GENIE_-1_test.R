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

cfg$input <- c(regional    = "rev4.119_26df900e_magpie.tgz",
               cellular    = "rev4.119_26df900e_1b5c3817_cellularmagpie_c200_MRI-ESM2-0-ssp245_lpjml-8e6c5eb1.tgz",
               validation  = "rev4.119_26df900e_validation.tgz",
               additional  = "additional_data_rev4.62.tgz")
               # patch       = "MMEmuR12_rev4.96.tgz")


cfg$output <- c("output_check", "rds_report")

# ### Identifier and folder
# ###############################################
# identifierFlag <- "MESSAGEix"
# cfg$title <- "MESSAGE_default_rev4.119_with_default.cfg"
# ###############################################
# cfg$info$flag <- identifierFlag
# start_run(cfg, codeCheck = FALSE)

### Folder
###############################################
cfg$title <- "13tccost"
###############################################
cfg$gms$c13_tccost <- "high"
start_run(cfg, codeCheck = FALSE)

### Folder
###############################################
cfg$title <- "13tccost+14yields"
###############################################
# source("config/default.cfg") #nolinter
cfg$gms$c14_yields_scenario  <- "nocc"
start_run(cfg, codeCheck = FALSE)

### Folder
###############################################
cfg$title <- "13tccost+14yields+30growth"
###############################################
# source("config/default.cfg") #nolinter
cfg$gms$s30_annual_max_growth <- 0.02
start_run(cfg, codeCheck = FALSE)

### Folder
###############################################
cfg$title <- "13tccost+14yields+30growth+32hvarea"
###############################################
# source("config/default.cfg") #nolinter
cfg$gms$s32_hvarea <- 0
start_run(cfg, codeCheck = FALSE)

### Folder
###############################################
cfg$title <- "13tccost+14yields+30growth+32hvarea+35hvarea"
###############################################
# source("config/default.cfg") #nolinter
cfg$gms$s35_hvarea <- 0
start_run(cfg, codeCheck = FALSE)

### Folder
###############################################
cfg$title <- "13tccost+14yields+30growth+32hvarea+35hvarea+73timber"
###############################################
# source("config/default.cfg") #nolinter
cfg$gms$s73_timber_demand_switch <- 0
start_run(cfg, codeCheck = FALSE)

# # Template to add new settings:
# ### Folder
# ###############################################
# cfg$title <- "MESSAGE_default_rev4.119_with_"
# ###############################################

# start_run(cfg, codeCheck = FALSE)