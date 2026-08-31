# |  The experiments this pipeline runs. Declared as CSV: messageix/config/
# |  holds the three the pipeline ships (default, golden, biodiversity), which
# |  is the surface to read and edit first -- a project with many settings, a
# |  layered override, or a config file from a collaborator all read the same
# |  way. This file loads them. The constructors the loader calls are also
# |  available directly, for a one-off experiment or a generated sweep; see
# |  "Writing an experiment in R instead" below.
# |
# |  An experiment has two halves:
# |
# |    narrative()  the world the runs are made in -- the SSP, the region set,
# |                 how strictly biodiversity is protected, how costly yield
# |                 improvements are.
# |    design()     the sampling plan -- which bioenergy price levels the price
# |                 sweep visits, and which GHG price levels the demand sweep
# |                 visits. Leaving it out uses the grid the pipeline was tested
# |                 on: seven bioenergy prices and twelve GHG prices, which is 84
# |                 demand runs. One experiment is 92 MAgPIE runs in all -- one
# |                 calibration run, seven price runs, 84 demand runs.
# |
# |  Every lever of the world, what it means and what it may be, is registered
# |  in messageix/R/world_levers.R; the sampling plan's two settings are
# |  declared in messageix/R/utils_config.R. Both are documented there, not
# |  here or in the CSVs.
# |
# |  The name on the left of each CSV column is the experiment's name. It
# |  becomes the output folder, the matrix file name and the bioenergy demand
# |  columns the runs hand to each other, so it takes letters, digits, dash and
# |  underscore only. `default` follows the registry defaults, which carry the
# |  Earth Commission values since 2026-08-31. `golden` pins the values the
# |  golden runs were made with; run it when the pipeline has to prove it still
# |  reproduces magpie_input_SSP2_ref_woodfuel.csv. Both are documented where
# |  they are declared, messageix/config/narratives_base.csv.
# |
# |  Run them:
# |    Rscript messageix/run.R                    # every experiment except golden, in order
# |    Rscript messageix/run.R biodiversity       # just this one
# |    Rscript messageix/run.R golden             # the golden reproduction check -- opt-in only
# |    Rscript messageix/run.R status             # what is finished, what would run

# The constructors, so this file can be read on its own, and the CSV loaders
# that call them.
if (!exists("narrative", mode = "function")) source("messageix/R/utils_config.R")
if (!exists("experiments_from_csv", mode = "function")) source("messageix/R/utils_config_csv.R")

# The shipped experiments. Files are read in order and the later ones override
# only the settings they name -- narratives_base.csv declares `default` and
# `golden`, and narratives_biodiversity.csv layers `biodiversity` over
# `default`'s `base` row, changing only the two biodiversity-scenario levers.
# designs.csv ships all three at the grid the pipeline was tested on. The
# columns of both files are documented in messageix/README.md, and the
# per-experiment rationale is written where each is declared, in the CSVs
# themselves.
EXPERIMENTS <- experiments_from_csv(
  narratives = c("messageix/config/narratives_base.csv",
                 "messageix/config/narratives_biodiversity.csv"),
  designs    = "messageix/config/designs.csv")

# ---- Writing an experiment in R instead -------------------------------------
#
# The CSV loader above is an importer over narrative(), design() and
# experiment() -- nothing else in the pipeline knows a CSV was involved, so an
# experiment can be added here just as well, for a one-off run, a generated
# sweep, or a project that would rather keep its settings in this file. The
# two surfaces coexist: c(EXPERIMENTS, list(...)) adds an R-declared
# experiment to the ones read from CSV above. Give it a name the CSVs do not
# use -- a name declared on both surfaces is an error (load_experiments()
# dies on it), not a silent override.
#
# EXPERIMENTS$biodiversity_r <- experiment(
#   narrative(bii_target = 0.78, yields_scenario = "cc"))
#
# A sweep over one setting is a loop, because the experiments are a list.
# Uncomment to run three biodiversity targets on a coarser GHG price grid:
#
# for (target in c(0.70, 0.74, 0.78)) {
#   name <- paste0("bii", target * 100)
#   EXPERIMENTS[[name]] <- experiment(
#     narrative(bii_target = target),
#     design(prices_ghg = c(0, 100, 500, 1000, 4000)))
# }
#
# Each entry gets its own output folder and its own matrix, so the runs of one
# cannot land on another's. A coarser grid is fewer runs: five GHG price levels
# across seven bioenergy price levels is 35 runs instead of 84.
#
# The shared socioeconomic pathway and the set of world regions are levers of
# the same kind as any other, left at SSP2 and R12 by the shipped CSVs.
# Written in R they look like this:
#
#   ssp5 = experiment(narrative(ssp = "SSP5")),
#   r10  = experiment(narrative(region_set = "R10"))
#
# Both need more than the line, because both change which input data the runs
# read. The cellular input tarball carries the climate forcing of one pathway,
# so another SSP needs its own tarballs; and a region set is one entry in
# messageix/R/pipeline_infrastructure.R pairing its tarballs with a
# region-name table. R12 is the only region set the pipeline knows so far.
#
# The CSV loaders also take several layered files directly, without going
# through this file at all -- a shared defaults file, then a project file that
# overrides one lever and touches nothing else, which is the pattern
# narratives_biodiversity.csv demonstrates over narratives_base.csv:
#
# EXPERIMENTS <- experiments_from_csv(
#   narratives = c("messageix/config/narratives_base.csv",
#                  "path/to/a_project_file.csv"),
#   designs    = "messageix/config/designs.csv")
