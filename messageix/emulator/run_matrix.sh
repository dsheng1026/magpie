#!/bin/bash
# =============================================================================
# run_matrix.sh -- build the emulator matrix for one narrative, or for several.
#
# Runs the two halves of the matrix step, in order, against a finished set of
# stage-3 runs:
#   1. createMatrix_MM.R         each run's results file -> one matrix CSV
#   2. add_woodfuel_to_matrix.R  woodfuel from each run's solver output, added
#                                to the matrix -> *_woodfuel.csv
# The *_woodfuel file is the one the MESSAGEix linkage reads.
#
# Run it, or submit it, from the MAgPIE model root:
#   bash    messageix/emulator/run_matrix.sh                 # here and now
#   bash    messageix/emulator/run_matrix.sh --submit        # as one SLURM job
#   bash    messageix/emulator/run_matrix.sh --submit --narratives all
#   sbatch  messageix/emulator/run_matrix.sh                 # straight to sbatch
#
# Options. Each is also read from an environment variable of the same name, so a
# job script can set them without touching a command line. Both --key value and
# --key=value are accepted by the two R scripts this one calls; this wrapper
# takes the --key value form.
#   --preset NAME        narrative column of the narratives file        PRESET=default
#   --csv PATH           narratives file                                PRESET_CSV=
#                        default: the one the R layer calls default
#   --run-dir DIR        directory holding the stage-3 run folders BASE_OUTPUT_DIR=
#                        default: the run directory the preset's names point at
#   --out FILE           matrix CSV to write                       MATRIX_OUT=
#                        default: $MATRIX_DIR/<the narrative's matrix name>.csv
#   --matrix-dir DIR     directory for that default name           MATRIX_DIR=output/emulator
#   --narratives LIST    comma-separated narratives, or "all"       NARRATIVES=
#                        one SLURM array task per narrative; needs --submit
#   --allow-unmapped     build even when the mapping asks for      ALLOW_UNMAPPED=1
#                        variables the runs did not report
#   --submit             submit this script to SLURM and exit      SUBMIT=1
#   --help               this text
#
# Cluster settings -- the SLURM queue, the environment modules, the notification
# address -- come from the preset through messageix/R/utils_env.R, which also
# applies the MAGPIE_MM_QOS, MAGPIE_MM_MODULES and MAGPIE_MM_MAIL_USER overrides.
# MAIL_USER here is a shell-side spelling of the last of those. Nothing about the
# environment is decided in this file.
#
# The #SBATCH block below is the fallback for a direct `sbatch run_matrix.sh`:
# the scheduler reads those lines before anything has had a chance to ask R what
# the preset says. `--submit` does not use them -- it passes the preset's own
# queue and mail settings on the sbatch command line instead.
# =============================================================================

#SBATCH --job-name=mm_matrix
#SBATCH --output=mm_matrix_%A_%a.log
#SBATCH --qos=priority              # fallback for a direct sbatch; --submit overrides it
#SBATCH --time=02:00:00             # both halves run one run at a time over the whole set
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1           # neither half uses more than one core
#SBATCH --mem=8G                    # peak is one run's results, or one gdx, plus the matrix

set -euo pipefail

# Absolute path to this file, resolved before any directory change so that both
# --help and the sbatch call below keep working from any working directory.
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# ---- configuration ----------------------------------------------------------

PRESET="${PRESET:-default}"
# Empty means "whichever CSV the R layer calls the default". The preset query
# below is told nothing and answers with the path it used, so this file states
# no path of its own and the two layers cannot drift apart.
PRESET_CSV="${PRESET_CSV:-}"
BASE_OUTPUT_DIR="${BASE_OUTPUT_DIR:-}"
MATRIX_OUT="${MATRIX_OUT:-}"
MATRIX_DIR="${MATRIX_DIR:-output/emulator}"
NARRATIVES="${NARRATIVES:-}"
ALLOW_UNMAPPED="${ALLOW_UNMAPPED:-}"
SUBMIT="${SUBMIT:-}"
MAIL_USER="${MAIL_USER:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --preset)         PRESET="$2"; shift 2 ;;
    --csv|--preset-csv) PRESET_CSV="$2"; shift 2 ;;
    --run-dir)        BASE_OUTPUT_DIR="$2"; shift 2 ;;
    --out)            MATRIX_OUT="$2"; shift 2 ;;
    --matrix-dir)     MATRIX_DIR="$2"; shift 2 ;;
    --narratives)     NARRATIVES="$2"; shift 2 ;;
    --allow-unmapped) ALLOW_UNMAPPED=1; shift ;;
    --submit)         SUBMIT=1; shift ;;
    # The comment block at the head of this file is the help text; printing it
    # straight from there keeps the two from drifting apart.
    -h|--help)        awk 'NR > 2 { if ($0 ~ /^# ={10,}/) exit; sub(/^# ?/, ""); print }' \
                          "${SCRIPT_PATH}"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

# --narratives turns into one SLURM array task per narrative, and that expansion
# happens in the submission block below. Without --submit the list would be read
# and then quietly ignored, building only $PRESET. The one exception is an array
# task, which re-enters this script with NARRATIVES set and SUBMIT unset.
if [[ -n "${NARRATIVES}" && -z "${SUBMIT}" && -z "${SLURM_ARRAY_TASK_ID:-}" ]]; then
  echo ">> FATAL: --narratives submits one SLURM array task per narrative, so it needs" >&2
  echo "          --submit as well. With no scheduler to submit to, run this script once" >&2
  echo "          per narrative instead: --preset NAME." >&2
  exit 1
fi

# ---- model root -------------------------------------------------------------

# Both R scripts load messageix/R/ by paths relative to the model root, which is
# the directory every MAgPIE start script is run from.
if [[ -n "${SLURM_SUBMIT_DIR:-}" ]]; then
  cd "${SLURM_SUBMIT_DIR}"
else
  cd "$(dirname "${SCRIPT_PATH}")/../.."
fi

if [[ ! -f config/default.cfg ]]; then
  echo ">> FATAL: run from the MAgPIE model root; $(pwd) holds no config/default.cfg" >&2
  exit 1
fi

# ---- preset query -----------------------------------------------------------

# Everything this file needs to know about a preset, asked in one go, one answer
# per line:
#   1  the narratives file that was read, so the path is stated in one layer only
#   2  the SLURM queue
#   3  the notification address, empty for none
#   4  the directory this narrative's stage-3 runs go to
#   5  the name the matrix CSV takes, without the extension
#   6  every narrative column the narratives file offers, comma-joined
#   7+ the shell commands that set up the R environment
# One call rather than one per question, because each call starts an R process
# and every answer comes out of the same resolved preset anyway. The answers are
# asked for rather than restated here, so a site that changes its modules changes
# them in one file.
#
# Resolving a preset can print a warning, and a warning arriving on the same
# stream as the answers would be read as one of them. The resolution therefore
# runs with its output diverted, and only the answers are printed.
preset_query() {
  Rscript --vanilla -e '
    a <- commandArgs(trailingOnly = TRUE)
    source("messageix/R/utils_config.R")
    csv <- if (nzchar(a[2])) a[2] else default_preset_csv()
    quiet <- tempfile()
    sink(quiet)
    p <- resolve_config(a[1], csv)
    columns <- preset_columns(csv)
    sink()
    unlink(quiet)
    mail <- mail_user(p)
    cat(paste(c(csv,
                run_qos(p),
                if (is.null(mail)) "" else mail,
                dirname(results_folder(p, 3)),
                p$matrix_basename,
                paste(columns, collapse = ","),
                slurm_module_lines(p)),
              collapse = "\n"), "\n", sep = "")
  ' "$1" "${PRESET_CSV}"
}

# The fixed answers above, before the module commands start.
PRESET_ANSWERS=6

# ---- this task's narrative --------------------------------------------------

# Before the environment query, so that an array task resolves the settings of
# the narrative it was given rather than of the submitting default.
if [[ -n "${NARRATIVES}" && -n "${SLURM_ARRAY_TASK_ID:-}" ]]; then
  IFS=',' read -r -a narrative_list <<< "${NARRATIVES}"
  PRESET="${narrative_list[${SLURM_ARRAY_TASK_ID}]}"
fi

# ---- execution environment --------------------------------------------------

module_lines=()
PRESET_RUN_DIR=""
PRESET_MATRIX_BASE=""
PRESET_COLUMNS=""
if command -v Rscript >/dev/null 2>&1; then
  answers=()
  while IFS= read -r line; do answers+=("${line}"); done < <(preset_query "${PRESET}")
  if [[ ${#answers[@]} -lt ${PRESET_ANSWERS} ]]; then
    echo ">> FATAL: could not resolve preset '${PRESET}' from ${PRESET_CSV:-the default narratives file}" >&2
    exit 1
  fi
  PRESET_CSV="${answers[0]}"
  QOS="${answers[1]}"
  MAIL_USER="${MAIL_USER:-${answers[2]}}"
  PRESET_RUN_DIR="${answers[3]}"
  PRESET_MATRIX_BASE="${answers[4]}"
  PRESET_COLUMNS="${answers[5]}"
  if [[ ${#answers[@]} -gt ${PRESET_ANSWERS} ]]; then
    module_lines=("${answers[@]:${PRESET_ANSWERS}}")
  fi
else
  # On this machine R only becomes available once the environment modules are
  # loaded, so the preset cannot be read yet and the queue and module list have to
  # be given directly. The rest of the preset is read further down, once the
  # modules are in place.
  QOS="${MAGPIE_MM_QOS:-}"
  MAIL_USER="${MAIL_USER:-${MAGPIE_MM_MAIL_USER:-}}"
  if [[ -z "${QOS}" || -z "${MAGPIE_MM_MODULES:-}" ]]; then
    echo ">> FATAL: no Rscript on PATH, so the queue and module list cannot be read from the" >&2
    echo "          narratives file; set MAGPIE_MM_QOS and MAGPIE_MM_MODULES" >&2
    exit 1
  fi
  module_lines=("module purge")
  IFS=',' read -r -a module_names <<< "${MAGPIE_MM_MODULES}"
  for m in "${module_names[@]}"; do module_lines+=("module load ${m}"); done
fi

# ---- submission -------------------------------------------------------------

if [[ -n "${SUBMIT}" && -z "${SLURM_JOB_ID:-}" ]]; then
  sbatch_args=(--qos="${QOS}")
  if [[ -n "${MAIL_USER}" ]]; then
    sbatch_args+=(--mail-type=END,FAIL --mail-user="${MAIL_USER}")
  fi
  export PRESET PRESET_CSV MATRIX_DIR ALLOW_UNMAPPED
  if [[ -n "${NARRATIVES}" ]]; then
    if [[ "${NARRATIVES}" == "all" ]]; then
      if [[ -z "${PRESET_COLUMNS}" ]]; then
        echo ">> FATAL: --narratives all needs to read the narrative columns of the preset" >&2
        echo "          CSV, and there is no Rscript on PATH to read them with." >&2
        echo "          Name the narratives instead: --narratives one,two,three" >&2
        exit 1
      fi
      NARRATIVES="${PRESET_COLUMNS}"
    fi
    IFS=',' read -r -a narrative_list <<< "${NARRATIVES}"
    sbatch_args+=(--array=0-$(( ${#narrative_list[@]} - 1 )))
    export NARRATIVES
    echo ">> SUBMIT: ${#narrative_list[@]} narrative(s): ${NARRATIVES}"
    # Each array task works out its own run directory and output file from its
    # own narrative. One shared value would make the tasks write over each other,
    # so neither is passed on here, even if this command line supplied one.
  else
    if [[ -n "${BASE_OUTPUT_DIR}" ]]; then export BASE_OUTPUT_DIR; fi
    if [[ -n "${MATRIX_OUT}" ]]; then export MATRIX_OUT; fi
  fi
  exec sbatch "${sbatch_args[@]}" "${SCRIPT_PATH}"
fi

# ---- R environment ----------------------------------------------------------

# `module` is a shell function rather than a program, and a batch job does not
# start a login shell, so on some machines it has to be defined first.
if ! command -v module >/dev/null 2>&1; then
  for init in /etc/profile.d/modules.sh /usr/share/Modules/init/bash /usr/share/lmod/lmod/init/bash; do
    if [[ -r "${init}" ]]; then . "${init}"; break; fi
  done
fi

if command -v module >/dev/null 2>&1; then
  if [[ ${#module_lines[@]} -gt 0 ]]; then
    for line in "${module_lines[@]}"; do eval "${line}"; done
    module list
  fi
else
  echo ">> WARN: no environment modules on this machine; using the R on PATH"
fi

# ---- run directory and output name ------------------------------------------

# Where R only arrives with the modules, the preset could not be read until now.
# Everywhere else the query above already answered this.
if [[ -z "${PRESET_RUN_DIR}" ]]; then
  answers=()
  while IFS= read -r line; do answers+=("${line}"); done < <(preset_query "${PRESET}")
  if [[ ${#answers[@]} -lt ${PRESET_ANSWERS} ]]; then
    echo ">> FATAL: could not resolve preset '${PRESET}' from ${PRESET_CSV:-the default narratives file}" >&2
    exit 1
  fi
  PRESET_CSV="${answers[0]}"
  PRESET_RUN_DIR="${answers[3]}"
  PRESET_MATRIX_BASE="${answers[4]}"
fi
: "${BASE_OUTPUT_DIR:=${PRESET_RUN_DIR}}"
: "${MATRIX_OUT:=${MATRIX_DIR}/${PRESET_MATRIX_BASE}.csv}"

echo ">> RUN: preset ${PRESET}, runs in ${BASE_OUTPUT_DIR}, matrix ${MATRIX_OUT}"

# ---- the two steps ----------------------------------------------------------

create_args=(--run-dir "${BASE_OUTPUT_DIR}" --out "${MATRIX_OUT}"
             --preset "${PRESET}" --csv "${PRESET_CSV}")
if [[ -n "${ALLOW_UNMAPPED}" ]]; then create_args+=(--allow-unmapped); fi

Rscript messageix/emulator/createMatrix_MM.R "${create_args[@]}"

Rscript messageix/emulator/add_woodfuel_to_matrix.R \
  --run-dir "${BASE_OUTPUT_DIR}" \
  --matrix  "${MATRIX_OUT}" \
  --preset  "${PRESET}" \
  --csv     "${PRESET_CSV}"

echo ">> DONE: ${MATRIX_OUT%.csv}_woodfuel.csv"
