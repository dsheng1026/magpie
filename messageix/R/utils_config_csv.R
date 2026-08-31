# |  Narratives and sampling plans written as CSV, layered.
# |
# |  A thin importer over the constructors in messageix/R/utils_config.R. It
# |  reads a table, coerces each cell to the type the setting declares, and calls
# |  narrative() / design() with the result -- so the lever registry in
# |  messageix/R/world_levers.R and its checks are the only authority on what a
# |  setting may be, and nothing below experiments.R knows a CSV was involved.
# |
# |  The table follows MAgPIE's own scenario_config.csv convention: the first
# |  column names the setting, one further column per narrative, and the header
# |  cell of the first column is ignored. An empty cell sets nothing -- it leaves
# |  the setting at whatever an earlier file, or the default, gave it. "#" lines
# |  are comments and the delimiter is whichever of ";" and "," the header uses,
# |  both by read_pipeline_csv().
# |
# |    ;ssp2;biodiversity
# |    bii_target;0;0.78
# |    yields_scenario;nocc;cc
# |
# |  Row names. A narrative CSV takes any lever registered in world_levers.R,
# |  plus "gms$<switch>" for a MAgPIE switch this pipeline does not expose, plus
# |  "base" (below). A design CSV takes the sampling-plan settings declared in
# |  design_spec(): prices_bioenergy and prices_ghg. Anything else stops the
# |  read, naming the file and the row.
# |
# |  Vector cells. A cell holding more than one value separates them with "|",
# |  and a numeric one may use spaces instead: "0|5|7|10" and "0 5 7 10" are the
# |  same seven-level grid. Commas work too where the file is ";"-delimited.
# |
# |  Layering. The loaders take several files and read them in order. A narrative
# |  named in two files keeps the settings only the earlier one gave it and takes
# |  the later one's for the rest, so a project file can override one lever of a
# |  shared defaults file and touch nothing else. A narrative appearing for the
# |  first time in a later file starts from the defaults, unless its "base" row
# |  names a narrative already read, in which case it starts from that one.
# |
# |  Interface
# |    read_narrative_csv(...)              -> named list of mm_narrative
# |    read_design_csv(...)                 -> named list of mm_design
# |    experiments_from_csv(narratives, designs) -> named list of mm_experiment
# |
# |  Dependencies: base R, readr (through read_pipeline_csv) and
# |  messageix/R/{utils_config,world_levers,utils_log}.R.

if (!exists("narrative", mode = "function")) source("messageix/R/utils_config.R")

# The row that names the narrative a column inherits from. It is not a setting,
# so it is stripped before the constructors are called.
.CSV_BASE_ROW <- "base"

# ---- reading one file -------------------------------------------------------

# One CSV as a named list: column name -> named list of raw text cells. Only the
# cells that hold something are returned; an empty one is not a setting.
.read_config_csv <- function(path, what, valid, allow_gms) {
  tbl <- read_pipeline_csv(path, what)
  delim <- attr(tbl, "mm_delim")
  if (ncol(tbl) < 2L) {
    log_die(what, " ", path, " names no columns: the first column holds the setting names ",
            "and every further column is one narrative, so a usable file has at least two. ",
            "Read with '", delim, "' as the delimiter, sniffed from the header row -- if this ",
            "file uses the other one, that is the most likely cause.")
  }
  columns <- names(tbl)[-1L]
  .check_column_names(columns, path, what, delim)
  keys <- trimws(as.character(tbl[[1L]]))
  keys[is.na(keys)] <- ""
  rows <- which(nzchar(keys))
  .check_row_names(keys[rows], path, what, valid, allow_gms)
  out <- stats::setNames(vector("list", length(columns)), columns)
  for (j in seq_along(columns)) {
    cells <- trimws(as.character(tbl[[j + 1L]])[rows])
    held <- !is.na(cells) & nzchar(cells)
    # Single-bracket assignment: "out[[j]] <- list()" would delete the element.
    out[j] <- list(stats::setNames(as.list(cells[held]), keys[rows][held]))
  }
  out
}

# A column name becomes an experiment name, an output folder and a scenario
# column, so it takes what an experiment name takes.
.check_column_names <- function(columns, path, what, delim = NULL) {
  blank <- !nzchar(trimws(columns))
  if (any(blank)) {
    log_die(what, " ", path, " has an unnamed column (number ", which(blank)[1L] + 1L,
            "). Every column after the first is one narrative and carries its name in the header.")
  }
  bad <- columns[!grepl("^[A-Za-z0-9][A-Za-z0-9_-]*$", columns)]
  if (length(bad)) {
    log_die(what, " ", path, ": the column name '", bad[1L], "' becomes a folder and a scenario ",
            "column, so it takes letters, digits, dash and underscore only, starting with a ",
            "letter or a digit. Read with '", if (is.null(delim)) "?" else delim,
            "' as the delimiter, sniffed from the header row -- a quoted character of the other ",
            "delimiter there would produce a name that looks like this.")
  }
  if (anyDuplicated(columns)) {
    log_die(what, " ", path, " names the column '", columns[duplicated(columns)][1L],
            "' twice. Layering an override is a second file, not a second column.")
  }
}

# The settings a file may name. The registry is asked for them; nothing here
# holds a list of its own.
.check_row_names <- function(keys, path, what, valid, allow_gms) {
  if (anyDuplicated(keys)) {
    log_die(what, " ", path, " sets '", keys[duplicated(keys)][1L], "' on two rows")
  }
  known <- c(valid, .CSV_BASE_ROW)
  unknown <- keys[!keys %in% known & !(allow_gms & startsWith(keys, "gms$"))]
  if (length(unknown)) {
    log_die(what, " ", path, ", row '", unknown[1L], "': not a setting this file may carry. It ",
            "takes ", paste(valid, collapse = ", "), ", '", .CSV_BASE_ROW, "'",
            if (allow_gms) ", and 'gms$<switch>' for a MAgPIE switch this pipeline does not expose"
            else "", ".")
  }
}

# ---- layering ---------------------------------------------------------------

# Several files read in order, merged per column. Returns a named list of
# columns, each a named list of raw text cells, and remembers which file each
# cell came from so a bad value can say where it was written.
.layer_config_csvs <- function(paths, what, valid, allow_gms) {
  if (!length(paths)) log_die(what, ": no file given")
  merged <- list()
  origin <- list()
  for (path in paths) {
    file <- .read_config_csv(path, what, valid, allow_gms)
    for (name in names(file)) {
      cells <- file[[name]]
      base <- cells[[.CSV_BASE_ROW]]
      cells[[.CSV_BASE_ROW]] <- NULL
      if (is.null(merged[[name]])) {
        if (!is.null(base) && is.null(merged[[base]])) {
          log_die(what, " ", path, ", column '", name, "': its base '", base, "' is not a ",
                  "narrative read so far. A base names one declared in this file above it or in ",
                  "an earlier file; the files read so far declare ",
                  if (length(merged)) paste(names(merged), collapse = ", ") else "none", ".")
        }
        # Single-bracket assignment: "merged[[name]] <- list()" would delete the entry.
        merged[name] <- list(if (is.null(base)) list() else merged[[base]])
        origin[name] <- list(if (is.null(base)) list() else origin[[base]])
      } else if (!is.null(base)) {
        log_die(what, " ", path, ", column '", name, "': it already exists from an earlier file, ",
                "which is what layering an override is, so it may not also name a base.")
      }
      for (key in names(cells)) {
        merged[[name]][[key]] <- cells[[key]]
        origin[[name]][[key]] <- path
      }
    }
  }
  list(values = merged, origin = origin)
}

# ---- cells to values --------------------------------------------------------

# A nested failure's own message, without the prefix log_die() will add again.
.csv_reason <- function(e) sub("^>> FATAL: ", "", conditionMessage(e))

# A cell in the shape .coerce() reads: "|" is the vector separator everywhere,
# and whitespace is one too where the values are numbers.
.csv_cell <- function(text, type) {
  if (!type %in% c("num_vec", "chr_vec")) return(text)
  text <- gsub("|", ",", text, fixed = TRUE)
  if (identical(type, "num_vec")) text <- gsub("[[:space:]]+", ",", text)
  text <- gsub(",+", ",", text)
  sub(",$", "", sub("^,", "", text))
}

# One column's cells, coerced to the types their settings declare. A value the
# registry refuses stops here, naming the file it was written in.
.csv_values <- function(cells, origins, spec, what, name) {
  values <- list()
  for (key in names(cells)) {
    values[[key]] <- tryCatch(
      .coerce(.csv_cell(cells[[key]], spec[[key]]$type), spec[[key]]$type, key),
      error = function(e) {
        log_die(what, " ", origins[[key]], ", column '", name, "', row '", key, "': ",
                .csv_reason(e))
      })
  }
  values
}

# ---- the loaders ------------------------------------------------------------

# The narratives declared across one or more CSVs, layered in the order given.
# Each is an mm_narrative, built by narrative() and checked by it.
read_narrative_csv <- function(...) {
  paths <- unlist(list(...), use.names = FALSE)
  what <- "narrative CSV"
  layered <- .layer_config_csvs(paths, what, lever_names(), allow_gms = TRUE)
  spec <- narrative_spec()
  lapply(stats::setNames(names(layered$values), names(layered$values)), function(name) {
    cells <- layered$values[[name]]
    keys <- if (is.null(names(cells))) character(0) else names(cells)
    if (!length(keys)) {
      log_die(what, " ", paste(paths, collapse = ", "), ", narrative '", name, "': every cell is ",
              "empty and it names no '", .CSV_BASE_ROW, "' to inherit from, so it would resolve ",
              "to every lever at its registry default -- SSP2 world, no biodiversity target, at ",
              "whatever design it is paired with. Give it at least one setting, or a '",
              .CSV_BASE_ROW, "' row naming a narrative to inherit from.")
    }
    is_gms <- startsWith(keys, "gms$")
    gms_keys <- sub("^gms\\$", "", keys[is_gms])
    gms_cells <- cells[is_gms]
    piped <- grepl("|", gms_cells, fixed = TRUE)
    if (any(piped)) {
      bad <- which(piped)[1L]
      log_die(what, " ", layered$origin[[name]][[keys[is_gms][bad]]], ", narrative '", name,
              "', column 'gms$", gms_keys[bad], "': '", gms_cells[[bad]], "' contains '|'. gms ",
              "switches are scalars here, not levels to split -- '|' splits lever and design ",
              "cells only.")
    }
    gms <- stats::setNames(gms_cells, gms_keys)
    values <- .csv_values(cells[!is_gms], layered$origin[[name]], spec, what, name)
    tryCatch(do.call(narrative, c(values, list(gms = as.list(gms)))),
             error = function(e) {
               log_die(what, ", narrative '", name, "' from ",
                       paste(unique(unlist(layered$origin[[name]])), collapse = ", "), ": ",
                       .csv_reason(e))
             })
  })
}

# The sampling plans declared across one or more CSVs, layered the same way.
# Each is an mm_design, and prices_bioenergy and prices_ghg are its two rows.
read_design_csv <- function(...) {
  paths <- unlist(list(...), use.names = FALSE)
  what <- "design CSV"
  spec <- design_spec()
  layered <- .layer_config_csvs(paths, what, names(spec), allow_gms = FALSE)
  lapply(stats::setNames(names(layered$values), names(layered$values)), function(name) {
    values <- .csv_values(layered$values[[name]], layered$origin[[name]], spec, what, name)
    tryCatch(do.call(design, values),
             error = function(e) {
               log_die(what, ", design '", name, "' from ",
                       paste(unique(unlist(layered$origin[[name]])), collapse = ", "), ": ",
                       .csv_reason(e))
             })
  })
}

# The experiments a narrative CSV and an optional design CSV declare, in the
# shape EXPERIMENTS takes. The narratives decide which experiments exist; a
# design column of the same name is that experiment's sampling plan, and one
# without a narrative is refused rather than silently dropped.
experiments_from_csv <- function(narratives, designs = NULL) {
  worlds <- read_narrative_csv(narratives)
  plans <- if (is.null(designs)) list() else read_design_csv(designs)
  orphan <- setdiff(names(plans), names(worlds))
  if (length(orphan)) {
    log_die("design CSV: the column '", orphan[1L], "' names no narrative. The narrative CSVs ",
            "declare ", paste(names(worlds), collapse = ", "),
            "; a sampling plan belongs to one of them.")
  }
  lapply(stats::setNames(names(worlds), names(worlds)),
         function(name) experiment(worlds[[name]], plans[[name]]))
}
