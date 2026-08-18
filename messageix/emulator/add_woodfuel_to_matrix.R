# =============================================================================
# Rscript add_woodfuel_to_matrix.R <base_output_dir> <matrix_in>
#
# Standalone post-processor. Run AFTER createMatrix_MAgPIE_MESSAGE.R has written
# the matrix. Two steps:
#   (1) loop over the 84 runs and extract regional woodfuel (EJ/yr) from each
#       run's fulldata.gdx (woodfuel is not in report.mif);
#   (2) read the matrix the main script produced and ADD the woodfuel to the
#       Primary Energy|Biomass rows, matched by scenario + region + year.
#
# The main matrix is left untouched; the result is written to a new *_woodfuel
# file. Based on woodfuel extraction code from Kristine Karstens.
#
# NOTE: verify with Florian that woodfuel is not already captured by the
# "Traditional Burning" component of Primary Energy|Biomass, or this
# double-counts.
# =============================================================================

suppressPackageStartupMessages({
  library(gdx2)      # readGDX()
  library(magclass)  # getYears(), as.data.frame() on the magpie object
  library(openxlsx)  # read/write the matrix xlsx
  library(stringr)
})

args <- commandArgs(trailingOnly = TRUE)

if (length(args) != 2) {
  stop(
    "Expected 2 arguments.\n",
    "Usage: Rscript add_woodfuel_to_matrix.R <base_output_dir> <matrix_in>\n",
    "  e.g. Rscript add_woodfuel_to_matrix.R ",
    "/p/projects/magpie/users/dish/magpie/output/MESSAGEix_5ff27be8_ALL/SSP2_BD78 ",
    "/p/projects/magpie/users/dish/emulator/magpie_input_SSP2_ALL.csv"
  )
}


# ===== USER INPUT (match the main script) ====================================

# base_output_dir
# matrix_in

# Base directory holding the run folders (same as the main script).
# base_output_dir <- "/p/projects/magpie/users/dish/magpie/output/MESSAGEix_5ff27be8/SSP2_BD00"
# base_output_dir <- "/p/projects/magpie/users/dish/magpie/output/MESSAGEix_5ff27be8_LAND/SSP2_BD78"
# base_output_dir <- "/p/projects/magpie/users/dish/magpie/output/MESSAGEix_5ff27be8_FOOD/SSP2_BD00"
# base_output_dir <- "/p/projects/magpie/users/dish/magpie/output/MESSAGEix_5ff27be8_ALL/SSP2_BD78"
base_output_dir <- args[1]

# scenario_prefix <- "SSP2_BD00"
scenario_prefix <- basename(base_output_dir)
run_suffix      <- "demand"
gdx_name        <- "fulldata.gdx"

# Scenario grid (same values used by the main script).
be_price_values  <- c(0, 5, 7, 10, 15, 25, 45)
ghg_price_values <- c(0, 10, 20, 50, 100, 200, 400, 600, 1000, 2000, 3000, 4000)

# Matrix produced by the main script (input), and the woodfuel-augmented output.
# matrix_in  <- "/p/projects/magpie/users/dish/emulator/magpie_input_SSP2_ref.xlsx"
# matrix_in  <- "/p/projects/magpie/users/dish/emulator/magpie_input_SSP2_LAND.xlsx"
# matrix_in  <- "/p/projects/magpie/users/dish/emulator/magpie_input_SSP2_FOOD.xlsx"
# matrix_in  <- "/p/projects/magpie/users/dish/emulator/magpie_input_SSP2_ALL.csv"
matrix_in  <- args[2]

# matrix_out <- sub("\\.xlsx$", "_woodfuel.xlsx", matrix_in)
matrix_out <- sub("\\.csv$", "_woodfuel.csv", matrix_in)

# Woodfuel energy content. Overrides the gdx fm_attributes value (Florian's fix).
woodfuel_ge_GJ_per_tDM <- 18

# Target variable to augment, exactly as it appears in the matrix.
target_var <- "Primary Energy|Biomass"
target_unit <- "EJ/yr"     # used only for a safety check, not for matching

# =============================================================================


# ----- Helpers (self-contained; mirror the main script) ----------------------
bio_tag <- function(be)  paste0("BIO", str_pad(be,  2, pad = "0"))   # BIO00..BIO45
ghg_tag <- function(ghg) paste0("GHG", str_pad(ghg, 3, pad = "0"))   # GHG000..GHG4000

run_folder_name <- function(be, ghg) {
  paste0(scenario_prefix, "_BE", str_pad(be, 2, pad = "0"),
         "_G", str_pad(ghg, 4, pad = "0"), run_suffix)
}

# MAgPIE region code -> MESSAGEix long name (matches the matrix). World stays.
region_rename <- c(
  AFR = "SubSaharanAfrica",  CHA = "ChinaReg",         CPA = "PlannedAsiaChina",
  EEU = "CentralEastEurope", FSU = "FormerSovietUnion", LAM = "LatinAmericaCarib",
  MEA = "MidEastNorthAfrica", NAM = "NorthAmerica",     PAO = "PacificOECD",
  PAS = "OtherPacificAsia",  SAS = "SouthAsia",         WEU = "WesternEurope",
  GLO = "World",             World = "World"
)

# Woodfuel EJ from one run's gdx, as a tidy data frame (Region, year, woodfuel_EJ).
# Regions are MAgPIE-native short codes; years are matrix-style ("1995").
woodfuel_ej_from_gdx <- function(gdx_path) {
  demand <- gdx2::readGDX(gdx_path, "pm_demand_forestry")[, , "woodfuel"]  # Mt DM
  ej <- demand * 1e6 * woodfuel_ge_GJ_per_tDM / 1e9        # Mt DM -> t -> GJ -> EJ
  ej <- ej[, getYears(ej) <= "y2110", ]
  d  <- as.data.frame(ej)
  data.frame(Region      = as.character(d$Region),
             year        = sub("^y", "", as.character(d$Year)),
             woodfuel_EJ = as.numeric(d$Value),
             stringsAsFactors = FALSE)
}


# ===== STEP 1: extract regional woodfuel for all 84 runs =====================
grid <- expand.grid(be = be_price_values, ghg = ghg_price_values,
                    KEEP.OUT.ATTRS = FALSE)

message("=== STEP 1: extracting woodfuel from ", nrow(grid), " runs ===")
wf_all <- list()
for (k in seq_len(nrow(grid))) {
  be  <- grid$be[k]; ghg <- grid$ghg[k]
  gdx_path <- file.path(base_output_dir, run_folder_name(be, ghg), gdx_name)
  if (!file.exists(gdx_path)) {
    message("  MISSING gdx, skipped: ", gdx_path)
    next
  }
  wf <- woodfuel_ej_from_gdx(gdx_path)

  # region-match sanity check (guards against H12/R12-style mismatches)
  if (length(intersect(wf$Region, names(region_rename))) == 0)
    warning("run BE", be, " G", ghg,
            ": gdx regions do not match expected codes: ",
            paste(unique(wf$Region), collapse = ", "))

  # add a World row = sum over regions, per year
  world <- aggregate(woodfuel_EJ ~ year, data = wf, FUN = sum, na.rm = TRUE)
  world$Region <- "World"
  wf <- rbind(wf, world[, c("Region", "year", "woodfuel_EJ")])

  # rename regions to the matrix's long names; tag with this run's scenario
  wf$Region  <- ifelse(wf$Region %in% names(region_rename),
                       region_rename[wf$Region], wf$Region)
  wf$BIOscen <- bio_tag(be)
  wf$GHGscen <- ghg_tag(ghg)
  wf_all[[k]] <- wf
}
wf_all <- do.call(rbind, wf_all)
message("  collected ", nrow(wf_all), " woodfuel values")


# ===== STEP 2: read the matrix and add woodfuel to Primary Energy|Biomass ====
message("=== STEP 2: adding woodfuel to '", target_var, "' ===")
# mat <- read.xlsx(matrix_in, sheet = 1, colNames = TRUE, check.names = FALSE)
mat <- read.csv(matrix_in, header = TRUE, check.names = FALSE, stringsAsFactors = FALSE)

# Identify year columns (headers may come back as "1995" or "X1995").
year_cols <- grep("^X?[0-9]{4}$", names(mat), value = TRUE)
year_of   <- setNames(sub("^X", "", year_cols), year_cols)   # column -> "1995"

# Build a fast lookup key on the woodfuel table: BIOscen|GHGscen|Region|year
wf_all$key <- with(wf_all, paste(BIOscen, GHGscen, Region, year, sep = "|"))
wf_lookup  <- setNames(wf_all$woodfuel_EJ, wf_all$key)

is_pe <- mat$Variable == target_var
if (!any(is_pe)) stop("target variable not found in matrix: ", target_var)

# sanity: confirm the matched rows carry the expected unit
if ("Unit" %in% names(mat)) {
  units_seen <- unique(mat$Unit[is_pe])
  if (!all(units_seen == target_unit))
    warning("unexpected unit(s) for ", target_var, ": ",
            paste(units_seen, collapse = ", "), " (expected ", target_unit, ")")
}

added <- 0L
for (r in which(is_pe)) {
  for (yc in year_cols) {
    key <- paste(mat$BIOscen[r], mat$GHGscen[r], mat$Region[r], year_of[[yc]], sep = "|")
    add <- wf_lookup[key]
    if (!is.na(add)) {
      mat[r, yc] <- as.numeric(mat[r, yc]) + as.numeric(add)
      added <- added + 1L
    }
  }
}
message("  updated ", added, " cells across ", sum(is_pe), " Primary Energy|Biomass rows")


# ===== write result ==========================================================
# write.xlsx(mat, file = matrix_out, sheetName = "matrix", overwrite = TRUE)
write.csv(mat, file = matrix_out, row.names = FALSE)
message("  written: ", matrix_out)
message("Done.")

# =============================================================================
# CHECKS after first run:
#  - "updated N cells" should be (#Primary Energy|Biomass rows) x (#years that
#    exist in both the gdx and the matrix). If far fewer, suspect a region-name
#    or scenario-tag mismatch between the matrix and the woodfuel table.
#  - Spot-check one cell: matrix Primary Energy|Biomass at (BIO00, GHG000, World,
#    2050) in *_woodfuel.csv should exceed the original matrix by the summed
#    regional woodfuel EJ for that run/year.
# =============================================================================
