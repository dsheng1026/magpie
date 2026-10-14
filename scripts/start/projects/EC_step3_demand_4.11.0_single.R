# |  (C) 2008-2025 Potsdam Institute for Climate Impact Research (PIK)
# |  authors, and contributors see CITATION.cff file. This file is part
# |  of MAgPIE and licensed under AGPL-3.0-or-later. Under Section 7 of
# |  AGPL-3.0, you are granted additional permissions described in the
# |  MAgPIE License Exception, version 1.0 (see LICENSE file).
# |  Contact: magpie@pik-potsdam.de

# ----------------------------------------------------------
# description: EarthCommission project MESSAGE-MAgPIE Emulator - Step 3 - ghg price sensitivity for step 2 biomass demands
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
# narratives_to_run <- c("EC-UF", "EC-OC", "EC-LM")
narratives_to_run <- c("EC-UF")

# BE demand levels from step 2 (2005USD/GJ). Must match the column names in
# f60_bioenergy_dem.cs3 in the patch, e.g. SSP2_EC-UF_BE45.
beV <- c(25)

# GHG price levels (used in the GHG price scenario names, e.g. G0100exp2110)
gV <- c(50)

# Narrative-specific patch files in ./patch_input
# (contain f60_bioenergy_dem.cs3 with the step-2 biomass demands per narrative).
# Names with "-" must be quoted in R.
patch_demand <- c(
  "EC-UF" = "MM_411_demand_EC-UF.tgz",
  "EC-OC" = "MM_411_demand_EC-OC.tgz",
  "EC-LM" = "MM_411_demand_EC-LM.tgz"
)

# ====================
# Scenario runs
# ====================


for (sus in narratives_to_run) {

  preflag <- paste0(run_flag, "_", sus)   # e.g. SSP2_EC-UF

  for (be in beV) {
    for (g in gV) {

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
                     patch       = patch_demand[[sus]])

      cfg$output <- c("output_check", "rds_report")

      # --- Scenario settings ---
      # SSP2 as the shared basis
      cfg <- setScenario(cfg, "SSP2")

      # Narrative settings from the project CSV (keep as the last setScenario call)
      cfg <- setScenario(cfg, sus, scenario_config = scenario_config_EC)

      # --- Settings shared by all runs ---
      # cap non-CO2 emission price in the AFOLU sector (USD17MER per tC, ~200 USD/tCO2)
      cfg$gms$s56_limit_ch4_n2o_price <- 734
      cfg$gms$s32_annual_aff_limit <- 0.03
      # settings for the MM linkage
      cfg$gms$s60_2ndgen_bioenergy_dem_min <- 0
      # cfg$gms$s60_bioenergy_1st_subsidy <- 0
      cfg$gms$s60_bioenergy_1st_subsidy <- 0.0000001

      # --- Step-3 specific settings ---
      # Biomass demand from step 2
      cfg$gms$c60_2ndgen_biodem <- paste0(preflag, "_BE", be)

      # GHG price scenario
      g_str <- str_pad(g, 4, pad = "0")
      cfg$gms$c56_pollutant_prices          <- paste0("G", g_str, "exp2110")
      cfg$gms$c56_pollutant_prices_noselect <- paste0("G", g_str, "exp2110")

      # --- Run identification and output folder ---
      cfg$title <- paste0(preflag, "_BE", str_pad(be, 2, pad = "0"), "_G", g_str, "demand")
      cfg$info$flag  <- identifierFlag
      cfg$info$flag2 <- preflag
      cfg$results_folder <- paste("output", identifierFlag, preflag, ":title:", sep = "/")

      # --- Start run ---
      start_run(cfg, codeCheck = FALSE)

    } # GHG
  } # BE
} # narrative