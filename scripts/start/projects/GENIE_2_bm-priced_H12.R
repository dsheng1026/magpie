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

# cfg$input <- c(regional    = "rev4.96_26df900e_magpie.tgz",
#                cellular    = "rev4.96_26df900e_fd712c0b_cellularmagpie_c200_MRI-ESM2-0-ssp370_lpjml-8e6c5eb1.tgz",
#                validation  = "rev4.96_26df900e_validation.tgz",
#                additional  = "additional_data_rev4.47.tgz",
#                patch       = "MMEmuR12_rev4.96.tgz")

# which input data sets should be used?
cfg$input <- c(regional    = "rev4.118_h12_magpie.tgz",
               cellular    = "rev4.118_h12_1b5c3817_cellularmagpie_c200_MRI-ESM2-0-ssp245_lpjml-8e6c5eb1.tgz",
               validation  = "rev4.118_h12_validation.tgz",
               additional  = "additional_data_rev4.62.tgz",
               calibration = "calibration_H12_FAO_13Mar25.tgz",
               patch       = "default_settings.tgz")

cfg$output <- c("output_check", "rds_report")

#load config presetswrite it before starting the run.
# preset <-  "GENIE_SCP"
cfg <- setScenario(cfg, "SSP2")

cfg$force_replace <- TRUE
cfg$qos <- "priority"
cfg$partition <- "priority"

### Identifier and folder
###############################################
identifierFlag <- "Default_MAgPIE_regions_test"
###############################################
cfg$info$flag <- identifierFlag
cfg$results_folder <- paste0("output/", identifierFlag, "/:title:")

# No GHG policy
cfg$gms$c56_pollutant_prices <- "none"     # def = R34M410-SSP2-NPi2025
cfg$gms$c56_pollutant_prices_noselect <- "none"     # def = R34M410-SSP2-NPi2025

### BE
cfg$gms$s60_2ndgen_bioenergy_dem_min <- 0
cfg$gms$s60_bioenergy_1st_subsidy <- 0
beV <- c(45)

### Tau / Yield
cfg$gms$tc <- "exo"

### Biodiv
blV <- c(0.78) #BII lower bound (0-1), default 0

### Food
mpV <- c(0)


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
    preflag <- paste0("BD", str_pad(bl * 100, 2, pad = "0"))
    cfg$results_folder <- paste("output", identifierFlag, preflag, ":title:", sep = "/")
    cfg$info$flag2 <- preflag

    cfg$gms$s15_rumdairy_scp_substitution <- mp / 100

    for (be in beV) {
      cfg$gms$s60_bioenergy_1st_price <- be
      cfg$gms$s60_bioenergy_2nd_price <- be

      ##############################################
      runflag <- "price"
      cfg$title <- paste0(preflag, "BE", str_pad(be, 2, pad = "0"), "G0000", runflag)

      start_run(cfg, codeCheck = FALSE)

    } # BE
  } # MP replacement
} # BII lower bound
