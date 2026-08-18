# =============================================================================
# Rscript createMatrix_MM.R <base_output_dir> <matrix_file>
#
# Transform MAgPIE report.mif outputs from a BE-price x GHG-price scenario grid
# into a single matrix that MESSAGEix can read.
#
#   - report.mif is the ONLY data source.
#   - Mapping (rename / factor / aggregate / unit-convert) is delegated to
#     iamc::write.reportProject(), isolated in apply_mapping().
#   - Single in-memory pass over the grid: map each run, read it, tag it,
#     combine, write. No intermediate _map.mif files are kept.
#
# Assumes all runs in the grid have finished before this is run.
# =============================================================================

suppressPackageStartupMessages({
  library(iamc)      # write.reportProject()
  library(stringr)
})

# ===== USER INPUT (adjust as needed) =========================================
# base_output_dir
# matrix_file

args <- commandArgs(trailingOnly = TRUE)

if (length(args) != 2) {
  stop(
    "Expected 2 arguments.\n",
    "Usage: Rscript createMatrix_MM.R <base_output_dir> <matrix_file>\n",
    "  e.g. Rscript createMatrix_MM.R ",
    "/p/projects/magpie/users/dish/magpie/output/MESSAGEix_5ff27be8_ALL/SSP2_BD78 ",
    "/p/projects/magpie/users/dish/emulator/magpie_input_SSP2_ALL.csv"
  )
}



# Base directory holding the run folders (one level above SSP2_BD..._BE.._G..).
# base_output_dir <- "/p/projects/magpie/users/dish/magpie/output/MESSAGEix_5ff27be8_ALL/SSP2_BD78"
base_output_dir <- args[1]

# Run folders are:  <scenario_prefix>_BE{bb}_G{gggg}<run_suffix>
scenario_prefix <- basename(base_output_dir)   # e.g. "SSP2_BD78"
run_suffix      <- "demand"                     # e.g. SSP2_BD78_BE45_G4000demand
mif_name        <- "report.mif"                 # the mif inside each run folder

# Scenario grid. Edit to run a reduced matrix (e.g. c(0, 45)).
be_price_values  <- c(0, 5, 7, 10, 15, 25, 45)
ghg_price_values <- c(0, 10, 20, 50, 100, 200, 400, 600, 1000, 2000, 3000, 4000)

# Fixed scenario-column values (constant across the whole grid).
ssp_scen <- "SSP2"
sdg_scen <- "noSDG_rcpref"

# Outputs.
matrix_output_dir <- "/p/projects/magpie/users/dish/emulator"
map_file          <- "/p/projects/magpie/users/dish/emulator/MM_linkage_mapping.csv"
# matrix_file       <- file.path(matrix_output_dir, "magpie_input_SSP2_ALL.csv")
matrix_file       <- file.path(matrix_output_dir, args[2])

# =============================================================================


# ----- Naming helpers --------------------------------------------------------
# Folder tokens and scenario tags use DIFFERENT zero-padding, both correct.
# Folder GHG token is 4-digit (G0000..G4000); the GHGscen tag is min-3-digit
# (GHG000..GHG4000). Deriving each from the integer value in one place prevents
# the two from being confused.
be_folder_token  <- function(be)  paste0("BE", str_pad(be,  2, pad = "0"))   # BE00..BE45
ghg_folder_token <- function(ghg) paste0("G",  str_pad(ghg, 4, pad = "0"))   # G0000..G4000
bio_scen_tag     <- function(be)  paste0("BIO", str_pad(be,  2, pad = "0"))   # BIO00..BIO45
ghg_scen_tag     <- function(ghg) paste0("GHG", str_pad(ghg, 3, pad = "0"))   # GHG000..GHG4000

run_folder_name <- function(be, ghg) {
  paste0(scenario_prefix, "_", be_folder_token(be), "_",
         ghg_folder_token(ghg), run_suffix)
}


# ----- Mapping step (the one iamc-dependent function) ------------------------
# Reads a run's report.mif, applies the mapping, writes a mapped mif to a temp
# path, and returns that path. If iamc is ever removed, replace ONLY this
# function body with the piamInterfaces equivalent.
apply_mapping <- function(mif_path, mapping_path, out_path, log_path) {
  write.reportProject(
    mif         = mif_path,
    mapping     = mapping_path,
    file        = out_path,
    missing_log = log_path
  )
  invisible(out_path)
}


# ----- Region rename (MAgPIE code -> MESSAGEix long name) --------------------
# "World" maps to itself; "GLO" is a safety net in case write.reportProject
# emits the magpie-style global code instead of the mif's "World".
region_rename <- c(
  AFR = "SubSaharanAfrica",  CHA = "ChinaReg",         CPA = "PlannedAsiaChina",
  EEU = "CentralEastEurope", FSU = "FormerSovietUnion", LAM = "LatinAmericaCarib",
  MEA = "MidEastNorthAfrica", NAM = "NorthAmerica",     PAO = "PacificOECD",
  PAS = "OtherPacificAsia",  SAS = "SouthAsia",         WEU = "WesternEurope",
  GLO = "World",             World = "World"
)


# ----- Derive scenario-column values from a mapped mif's Scenario field ------
# The Scenario string looks like "SSP2_BD78_BE45_G4000demand". Parsing tags from
# the data itself keeps the scenario columns self-documenting.
scenario_cols_from_tag <- function(scenario_string) {
  be  <- as.integer(str_match(scenario_string, "_BE(\\d+)_")[, 2])
  ghg <- as.integer(str_match(scenario_string, "_G(\\d+)")[, 2])
  list(
    SSPscen = ssp_scen,
    GHGscen = ghg_scen_tag(ghg),
    BIOscen = bio_scen_tag(be),
    SDGscen = sdg_scen
  )
}


# ===== BUILD MATRIX (single in-memory pass) ==================================
dir.create(matrix_output_dir, recursive = TRUE, showWarnings = FALSE)

id_cols <- c("Region", "Variable", "Unit",
             "SSPscen", "GHGscen", "BIOscen", "SDGscen")

grid <- expand.grid(be = be_price_values, ghg = ghg_price_values,
                    KEEP.OUT.ATTRS = FALSE)

message("=== BUILD MATRIX: ", nrow(grid), " runs expected ===")

pieces       <- list()
missing_runs <- character(0)

for (k in seq_len(nrow(grid))) {
  be  <- grid$be[k]
  ghg <- grid$ghg[k]
  folder   <- run_folder_name(be, ghg)
  mif_path <- file.path(base_output_dir, folder, mif_name)

  if (!file.exists(mif_path)) {
    message("  MISSING: ", folder, "/", mif_name, " -- skipped")
    missing_runs <- c(missing_runs, folder)
    next
  }

  message("  mapping ", folder)
  tmp_map <- tempfile(fileext = ".mif")
  tmp_log <- tempfile(fileext = ".log")
  apply_mapping(mif_path, map_file, tmp_map, tmp_log)

  # Surface any mapping variables not found in this run's mif.
   # if (file.exists(tmp_log) && file.info(tmp_log)$size > 0)
  #   message("    NOTE: some mapping variables were unmapped in ", folder)
  # write.reportProject always writes a "#--- ... ---#" banner, so size > 0 is
  # not evidence of a miss. Fire only on real (non-comment, non-blank) lines.
  unmapped <- if (file.exists(tmp_log))
    grep("^\\s*#|^\\s*$", readLines(tmp_log, warn = FALSE),
         value = TRUE, invert = TRUE) else character(0)
  if (length(unmapped))
    message("    NOTE: unmapped in ", folder, ":\n      ",
            paste(unmapped, collapse = "\n      "))
 

  df <- read.csv(tmp_map, sep = ";", check.names = FALSE,
                 stringsAsFactors = FALSE)
  unlink(c(tmp_map, tmp_log))                       # nothing kept on disk

  # drop trailing empty column that mif export leaves behind
  df <- df[, !grepl("^X?$", names(df)) & names(df) != "", drop = FALSE]

  # Add the four scenario columns, parsed from the Scenario field.
  tags <- scenario_cols_from_tag(df$Scenario[1])
  df$SSPscen <- tags$SSPscen; df$GHGscen <- tags$GHGscen
  df$BIOscen <- tags$BIOscen; df$SDGscen <- tags$SDGscen

  # Rename regions (unmatched regions left unchanged).
  hit <- df$Region %in% names(region_rename)
  df$Region[hit] <- region_rename[df$Region[hit]]

  # Drop Model and Scenario (not in target format).
  df$Model <- NULL; df$Scenario <- NULL

  pieces[[length(pieces) + 1]] <- df
}

if (length(pieces) == 0)
  stop("No runs mapped. Check base_output_dir, scenario_prefix, and the grid.")
if (length(missing_runs) > 0)
  message("  ", length(missing_runs), " run(s) missing; matrix built from ",
          length(pieces), " of ", nrow(grid), ".")

matrix_df <- do.call(rbind, pieces)

# Guard: no two rows may share a scenario coordinate.
dup_n <- sum(duplicated(matrix_df[id_cols]))
if (dup_n > 0)
  stop(dup_n, " rows share an id-column key. ",
       "Check the grid and Scenario-field parsing.")

# Reorder: id columns first, then year columns in ascending numeric order.
year_cols <- setdiff(names(matrix_df), id_cols)
year_cols <- year_cols[order(as.numeric(year_cols))]
matrix_df <- matrix_df[, c(id_cols, year_cols)]

write.csv(matrix_df, file = matrix_file, row.names = FALSE)
message("  written: ", matrix_file,
        "  (", nrow(matrix_df), " rows, ",
        length(unique(matrix_df$Variable)), " variables, ",
        length(pieces), " runs)")

message("Done.")

# =============================================================================
# VALIDATION CHECKPOINTS (run once after the first real execution):
#
# 1. INTENSIVE-VARIABLE GLOBAL AGGREGATION (most important).
#    Prices, Biodiversity|BII, and Food Demand are per-unit quantities that
#    must NOT be summed across regions. They are 1:1 renames, so
#    write.reportProject should pass the mif's World row through unchanged.
#    If World-level values look ~13x too large, those rows are being summed ->
#    change their "spatial" entry in the mapping from "reg+glo" to "reg".
#
# 2. Compare against the old matrix: region set and year columns should match;
#    Emissions|CO2|AFOLU = Land-use Change + crop-residue burning (no
#    agricultural-CO2 term, which is absent from the mif).
# =============================================================================