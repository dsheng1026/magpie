
# INSTRUCTION:
# before excute, update
# title
# dest_dir
# file.copy()

library(magpie4)
library(magpiesets)
library(stringr)

home.dir <- '/p/projects/magpie/users/dish/'
# setwd(home.dir)

# specify the price-driven run output folder
# title <- "magpie/output/MESSAGEix_5ff27be8"
# title <- "magpie/output/MESSAGEix_5ff27be8_LAND"
# title <- "magpie/output/MESSAGEix_5ff27be8_FOOD"
title <- "magpie/output/MESSAGEix_5ff27be8_ALL"
setwd(paste0(home.dir, title))

e_v <- c(0, 5, 7, 10, 15, 25, 45)
bi_v <- c(0) # 0, 70, 74, 78
mp_v <- c(0)

output_flag <- "step2"

beV <- c(0, 5, 7, 10, 15, 25, 45) # for folder naming, don't scale; for the value used in optimization, scale

### Biodiv
# blV <- c(0) # Options: 0, 0.7, 0.74, 0.78
blV <- c(0.78)

### Microbiol protein (MP) Food
mpV <- c(0) # Options: 0, 25, 50, 75

ofile <- paste(output_flag, "f60_bioenergy_dem.cs3", sep = "_")
# if (file.exists(ofile)) {
#   ofile_old <- paste0("old_", ofile)
#   file.remove(ofile)
# }

all_scen <- NULL

for (bl in blV) {
  for (mp in mpV) {
    preflag <- paste0("SSP2_BD", str_pad(bl * 100, 2, pad = "0"))
    setwd(preflag)
    # BE price incentive 0, 5, 7, 10, 15, 25, 45 2005USD/GJ, but in MAgPIE 2017 USD is used, so scale by 1.23  
    file.copy("/p/projects/magpie/users/dish/f60_bioenergy_dem_R12_orig.cs3", "step3_f60_bioenergy_dem.cs3")
    for (be in beV) {
      runflag <- "price"
      gdx_folder <- paste0(preflag, "_BE", str_pad(be, 2, pad = "0"), "_G0000", runflag)
      gdx <- paste(gdx_folder, "fulldata.gdx", sep = "/")
      
      BE <- reportProductionBioenergy(gdx, detail = FALSE, level = "reg")
      BE <- BE[, , "2nd generation|++", pmatch = TRUE]
      
      # o <- setNames(BE * 1000, paste0(preflag, "_BE", str_pad(be, 2, pad = "0"))) # EJ to PJ
      o <- setNames(BE * 1000, paste0(preflag, "_BE", be)) # EJ to PJ
      
      # fill data gaps
      n <- getYears(o)
      y <- 1995
      while (y <= 2150) {
        yy <- paste0("y", y)
        if (!(yy %in% n)) {
          o <- add_columns(o, addnm = yy, dim = 2, fill = NA)
          o[, yy, ] <- if (y < 2100) (
            (o[, paste0("y", y - 5), ] + o[, paste0("y", y + 5), ]) / 2 )
          else o[, "y2100", ]
        }
        y <- y + 5
      }
      
      # sort filled data
      o_sorted <- o[, "y1995", ]
      y <- 2000
      while (y <= 2150) {
        yy <- paste0("y", y)
        o_sorted <- add_columns(o_sorted, addnm = yy, dim = 2, fill = NA)
        o_sorted[, yy, ] <- o[, yy, ]
        y <- y + 5
      }

      # no 2nd-gen BE production for historical periods
      hist <- c("y1995", "y2000", "y2005", "y2010", "y2015")
      o_sorted[, hist, ] <- 0

      write.magpie(
        o_sorted,
        file_name = ofile,
        file_type = "cs3",
        append = TRUE
      )

      if (file.exists("step3_f60_bioenergy_dem.cs3")) {
        write.magpie(
          o_sorted,
          file_name = "step3_f60_bioenergy_dem.cs3",
          file_type = "cs3",
          append = TRUE
        )
        all_scen <- mbind(all_scen, o_sorted)
      }
    } # BE
  } # MP replacement
} # BII lower bound


# check the 2nd-gen BE level from price-driven run
glo <- dimSums(all_scen, dim = 1)   # sum over regions -> global, PJ/yr
tab <- t(as.array(glo)[1, "y2100", ])      # scenarios x years matrix
cat("\nprice-driven run output ")
cat("\nGlobal BE in EJ/yr:\n")
print(round(tab / 1000, 2))


# update the "f60_bioenergy_dem.cs3" in the patch_folder

## Reference
# dest_dir <- "/p/projects/magpie/users/dish/magpie/patch_folder/SSP2_demand_cap"
# dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)
# file.copy(
#   from = "/p/projects/magpie/users/dish/magpie/output/MESSAGEix_5ff27be8/SSP2_BD00/step3_f60_bioenergy_dem.cs3",
#   to   = file.path(dest_dir, "f60_bioenergy_dem.cs3"),
#   overwrite = TRUE
# )

## LAND
# dest_dir <- "/p/projects/magpie/users/dish/magpie/patch_folder/SSP2_demand_cap_LAND"
# dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)
# file.copy(
#   from = "/p/projects/magpie/users/dish/magpie/output/MESSAGEix_5ff27be8_LAND/SSP2_BD78/step3_f60_bioenergy_dem.cs3",
#   to   = file.path(dest_dir, "f60_bioenergy_dem.cs3"),
#   overwrite = TRUE
# )


## FOOD
# dest_dir <- "/p/projects/magpie/users/dish/magpie/patch_folder/SSP2_demand_cap_FOOD"
# dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)
# file.copy(
#   from = "/p/projects/magpie/users/dish/magpie/output/MESSAGEix_5ff27be8_FOOD/SSP2_BD00/step3_f60_bioenergy_dem.cs3",
#   to   = file.path(dest_dir, "f60_bioenergy_dem.cs3"),
#   overwrite = TRUE
# )

## ALL
dest_dir <- "/p/projects/magpie/users/dish/magpie/patch_folder/SSP2_demand_cap_ALL"
dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)
file.copy(
  from = "/p/projects/magpie/users/dish/magpie/output/MESSAGEix_5ff27be8_ALL/SSP2_BD78/step3_f60_bioenergy_dem.cs3",
  to   = file.path(dest_dir, "f60_bioenergy_dem.cs3"),
  overwrite = TRUE
)


# check the BE value used in patch
x <- read.magpie(file.path(dest_dir, "f60_bioenergy_dem.cs3"))
scen_pattern <- "_BE(0|5|7|10|15|25|45)$"
x <- x[, , grepl(scen_pattern, getNames(x))]
glo <- dimSums(x, dim = 1)
tab <- t(as.array(glo)[1, "y2100", ]) 
cat("\nfile in the patch")
cat("\nGlobal BE in EJ/yr:\n")
print(round(tab / 1000, 2))