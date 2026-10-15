# |  (C) 2008-2025 Potsdam Institute for Climate Impact Research (PIK)
# |  authors, and contributors see CITATION.cff file. This file is part
# |  of MAgPIE and licensed under AGPL-3.0-or-later. Under Section 7 of
# |  AGPL-3.0, you are granted additional permissions described in the
# |  MAgPIE License Exception, version 1.0 (see LICENSE file).
# |  Contact: magpie@pik-potsdam.de

# ----------------------------------------------------------
# description: EarthCommission project MESSAGE-MAgPIE Emulator - feedback runs (tau + GHG + BE from feedback patch)
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

identifierFlag <- "EC_feedback"
run_flag       <- "SSP2"

scenario_config_EC <- "config/projects/scenario_config_ec_ds.csv"

# Feedback scenarios from MESSAGE. Each entry maps the feedback tag to
#   patch     = feedback patch in ./patch_input (exo tau in f13_tau_scenario.csv,
#               BE demand in f60_bioenergy_dem.cs3, GHG price in f56_pollutant_prices.cs3,
#               all in column "Feedback_EC_<tag>")
#   narrative = EC narrative column in scenario_config_EC, i.e. the same narrative
#               as used in the step-2 price and step-3 demand runs.
#               NA = no EC narrative: SUSCDR "ref" settings instead
#               (same as ref_* in SUSCDR_feedback_4.11.0.R).
feedback_scen <- list(
  "UF"          = list(patch = "SSP2_feedback_EC_UF.tgz",          narrative = "EC-UF"),
  "OC"          = list(patch = "SSP2_feedback_EC_OC.tgz",          narrative = "EC-OC"),
  "OC_ECPC"     = list(patch = "SSP2_feedback_EC_OC_ECPC.tgz",     narrative = "EC-OC"),
  "LM"          = list(patch = "SSP2_feedback_EC_LM.tgz",          narrative = "EC-LM"),
  "LM_RI2_ECPC" = list(patch = "SSP2_feedback_EC_LM_RI2_ECPC.tgz", narrative = "EC-LM"),
  "BAU"         = list(patch = "SSP2_feedback_EC_BAU.tgz",         narrative = NA)
)

# Feedback scenarios to run (names of feedback_scen)
feedback_to_run <- names(feedback_scen)


# ====================
# Scenario runs
# ====================

for (fb in feedback_to_run) {

  sus          <- feedback_scen[[fb]]$narrative
  feedback_col <- paste0("Feedback_EC_", fb)        # column name in the feedback patch

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
                 patch       = feedback_scen[[fb]]$patch)

  cfg$output <- c("output_check", "rds_report")

  # --- Scenario settings ---
  # SSP2 as the shared basis
  cfg <- setScenario(cfg, "SSP2")

  if (!is.na(sus)) {
    # Narrative settings from the project CSV (keep as the last setScenario call)
    cfg <- setScenario(cfg, sus, scenario_config = scenario_config_EC)

    # --- Settings shared with EC step 2 (price) and step 3 (demand) ---
    # cap non-CO2 emission price in the AFOLU sector (USD17MER per tC, ~200 USD/tCO2)
    cfg$gms$s56_limit_ch4_n2o_price <- 734
    cfg$gms$s32_annual_aff_limit <- 0.03
    # settings for the MM linkage
    cfg$gms$s60_2ndgen_bioenergy_dem_min <- 0
    cfg$gms$s60_bioenergy_1st_subsidy <- 0
  } else {
    # --- BAU: SUSCDR "ref" settings (as ref_* in SUSCDR_feedback_4.11.0.R) ---
    cfg$gms$c13_tccost            <- "high"     # (unused under tc = "exo", kept for consistency)
    cfg$gms$c14_yields_scenario   <- "nocc"     # yields do not reflect climate change
    cfg$gms$s30_annual_max_growth <- 0.02       # cap annual cropland growth per region
    cfg$gms$s44_cost_bii_missing  <- 10000000   # 10 million USD (vs 1 million in default.cfg)
    cfg$gms$s60_2ndgen_bioenergy_dem_min <- 0   # 2nd-gen demand comes from the feedback f60 column
    cfg$gms$s60_bioenergy_1st_subsidy    <- 0
    cfg$gms$s15_rumdairy_scp_substitution <- 0
    cfg$gms$s56_limit_ch4_n2o_price <- 734      # cap non-CO2 AFOLU price (~$200/tCO2, 2017 USD)
  }

  # --- Feedback-run specific settings ---
  # tau is EXOGENOUS: it comes from the feedback f13_tau_scenario.csv in the patch
  cfg$gms$tc <- "exo"

  # GHG price and 2nd-gen bioenergy demand both read the feedback column
  cfg$gms$c56_pollutant_prices          <- feedback_col
  cfg$gms$c56_pollutant_prices_noselect <- feedback_col
  cfg$gms$c60_2ndgen_biodem             <- feedback_col

  # --- Run identification and output folder ---
  cfg$title <- paste0(run_flag, "_", fb, "_feedback")            # e.g. SSP2_OC_ECPC_feedback
  cfg$info$flag  <- identifierFlag
  cfg$info$flag2 <- if (is.na(sus)) run_flag else paste0(run_flag, "_", sus)
  cfg$results_folder <- paste("output", identifierFlag, ":title:", sep = "/")

  # --- Start run ---
  start_run(cfg, codeCheck = FALSE)

} # feedback scenario
