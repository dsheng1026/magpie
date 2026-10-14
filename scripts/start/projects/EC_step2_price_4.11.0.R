# |  (C) 2008-2025 Potsdam Institute for Climate Impact Research (PIK)
# |  authors, and contributors see CITATION.cff file. This file is part
# |  of MAgPIE and licensed under AGPL-3.0-or-later. Under Section 7 of
# |  AGPL-3.0, you are granted additional permissions described in the
# |  MAgPIE License Exception, version 1.0 (see LICENSE file).
# |  Contact: magpie@pik-potsdam.de

# ----------------------------------------------------------
# description: EarthCommission project MESSAGE-MAgPIE Emulator - Step 2 - generate price-driven biomass demands per narrative
# ----------------------------------------------------------

library(lucode2)
library(magclass)
library(gms)
library(stringr)

# Load start_run(cfg) function which is needed to start MAgPIE runs
source("scripts/start_functions.R") #nolinter


# ====================
# Project settings
# ====================

identifierFlag <- "EC"
run_flag       <- "SSP2"

scenario_config_EC <- "config/projects/scenario_config_ec_ds.csv"

# Narratives to run. Names must match the column names in the CSV exactly
# (case-sensitive).
narratives_to_run <- c("EC-UF", "EC-OC")
# narratives_to_run <- c("EC-UF", "EC-OC", "EC-LM")

# BE price incentive in 2005USD/GJ (options: 0, 5, 7, 10, 15, 25, 45).
# Unscaled values are used in the run title; MAgPIE uses 2017USD, so the
# values passed to the model are scaled by 1.23.
# beV <- c(45)
beV <- c(0, 5, 7, 10, 15, 25)

# Narrative-specific patch files in ./patch_input (contain the step-1 tau per narrative,
# used with tc = "exo"). Only MM has a different label in the file name ("Ref").
# patch_price <- c(
#   MM     = "SUSCDR_411_price_Ref.tgz",
#   Biodiv = "SUSCDR_411_price_Biodiv.tgz",
#   Food   = "SUSCDR_411_price_Food.tgz",
#   Water  = "SUSCDR_411_price_Water.tgz",
#   Land   = "SUSCDR_411_price_Land.tgz",
#   All    = "SUSCDR_411_price_All.tgz"
# )


# ====================
# Scenario runs
# ====================

for (sus in narratives_to_run) {
  for (be in beV) {

    # Start every run from the default configuration.
    # This must come first: it creates a fresh cfg and overwrites everything set before it.
    source("config/default.cfg") #nolinter

    # --- Technical setup ---
    cfg$repositories <- append(list("https://rse.pik-potsdam.de/data/magpie/public" = NULL,
                                    "./patch_input" = NULL),
                               getOption("magpie_repos"))

    cfg$force_replace <- TRUE
    cfg$qos <- "priority"

    # Time horizon expected for MESSAGE: 2110
    cfg$gms$c_timesteps <- "coup2110"

    cfg$input <- c(regional    = "rev4.119_5ff27be8_magpie.tgz",
                   cellular    = "rev4.119_5ff27be8_1b5c3817_cellularmagpie_c200_MRI-ESM2-0-ssp245_lpjml-8e6c5eb1.tgz",
                   validation  = "rev4.119_5ff27be8_validation.tgz",
                   additional  = "additional_data_rev4.62.tgz",
                  patch       = "MM_411_price_0BE.tgz")

    cfg$output <- c("output_check", "rds_report")

    # --- Scenario settings ---
    # SSP2 as the shared basis
    cfg <- setScenario(cfg, "SSP2")

    # Narrative settings from the project CSV (keep as the last setScenario call)
    cfg <- setScenario(cfg, sus, scenario_config = scenario_config_EC)

    # --- Step-2 specific settings ---
    # cap non-co2 carbon price in AFOLU sector
    cfg$gms$s56_limit_ch4_n2o_price <- 734
    cfg$gms$s32_annual_aff_limit <- 0.03  
    # set carbon price to 0 for step2
    cfg$gms$c56_pollutant_prices <- "SSPDB-SSP2-Ref-MESSAGE-GLOBIOM" # def = R34M410-SSP2-NPi2025, here we need 0 across all regions and periods
    cfg$gms$c56_pollutant_prices_noselect <- "SSPDB-SSP2-Ref-MESSAGE-GLOBIOM" # def = R34M410-SSP2-NPi2025, here we need 0 across all regions and periods
    # settings for the MM linkage
    cfg$gms$s60_2ndgen_bioenergy_dem_min <- 0
    cfg$gms$s60_bioenergy_1st_subsidy <- 0

     # Exogenous tau from step 1
    cfg$gms$tc <- "exo"

    # BE price incentive (scaled from 2005USD to 2017USD)
    cfg$gms$s60_bioenergy_1st_price <- be * 1.23
    cfg$gms$s60_bioenergy_2nd_price <- be * 1.23

    # --- Run identification and output folder ---
    preflag <- paste0(run_flag, "_", sus)                        # e.g. SSP2_Biodiv
    cfg$title <- paste0(preflag, "_BE", str_pad(be, 2, pad = "0"), "_G0000", "price")
    cfg$info$flag  <- identifierFlag
    cfg$info$flag2 <- preflag
    cfg$results_folder <- paste("output", identifierFlag, preflag, ":title:", sep = "/")

    # --- Start run ---
    start_run(cfg, codeCheck = FALSE)

  } # BE price
} # narrative
