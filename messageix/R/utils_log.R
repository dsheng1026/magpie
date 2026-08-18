# |  Narration for the MAgPIE -> MESSAGEix pipeline.
# |
# |  Every line the pipeline prints goes through this file. The format is
# |  ">> VERB: message" so a cluster log can be filtered with a single grep,
# |  e.g. `grep '^>> SOLVE:' slurm-*.out`. Verbs are upper-case bare words;
# |  the vocabulary in use is CONFIG, EXTRACT, PACK, SUBMIT, RUN, CHECK,
# |  MATRIX, WOODFUEL, WRITE, SKIP, DONE.
# |
# |  Drivers and the runner narrate. Operation functions never print — they
# |  return values or stop with a message.
# |
# |  Interface
# |    log_step(verb, ...)        -> invisible(NULL); prints ">> VERB: <msg>"
# |    log_warn(...)              -> invisible(NULL); prints ">> WARN: <msg>"
# |    log_die(...)               -> never returns; stop() with ">> FATAL: <msg>"
# |    log_banner(title, entries) -> invisible(NULL); boxed run summary
# |    log_fmt(...)               -> character(1); the shared message formatter
# |
# |  Dependencies: base R only.

# Collapse the ... arguments into one message string.
# Character vectors of length > 1 are comma-joined so that
# log_step("RUN", "stages: ", c(1, 2, 3)) reads naturally.
log_fmt <- function(...) {
  parts <- lapply(list(...), function(x) {
    if (is.null(x)) {
      "NULL"
    } else if (length(x) > 1L) {
      paste(format(x, trim = TRUE), collapse = ", ")
    } else {
      as.character(x)
    }
  })
  paste0(unlist(parts, use.names = FALSE), collapse = "")
}

# Narrate one pipeline action. `verb` is upper-cased so callers may write
# log_step("solve", ...) without breaking the grep contract.
log_step <- function(verb, ...) {
  cat(sprintf(">> %s: %s\n", toupper(as.character(verb)[1L]), log_fmt(...)))
  utils::flush.console()
  invisible(NULL)
}

# A condition the run survives. Goes to stdout with the same prefix shape as
# log_step so ordering against the narration is preserved in a redirected log.
log_warn <- function(...) {
  cat(sprintf(">> WARN: %s\n", log_fmt(...)))
  utils::flush.console()
  invisible(NULL)
}

# A condition the run does not survive. call. = FALSE keeps the message legible
# in a SLURM log, where the R call stack adds noise and no context.
log_die <- function(...) {
  stop(sprintf(">> FATAL: %s", log_fmt(...)), call. = FALSE)
}

# Boxed key/value summary, printed once per driver invocation so a log file
# carries the full experiment design at its head.
# `entries` is a named list or named character vector; NULL prints title only.
log_banner <- function(title, entries = NULL) {
  rule <- strrep("=", 78L)
  cat(rule, "\n", sep = "")
  cat(">> ", toupper(as.character(title)[1L]), "\n", sep = "")
  if (length(entries)) {
    keys <- names(entries)
    width <- max(nchar(keys))
    for (i in seq_along(entries)) {
      cat(sprintf(">>   %-*s  %s\n", width, keys[i], log_fmt(entries[[i]])))
    }
  }
  cat(rule, "\n", sep = "")
  utils::flush.console()
  invisible(NULL)
}
