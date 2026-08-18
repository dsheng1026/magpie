#!/bin/bash
# =============================================================================
# run_matrix.sh -- build the emulator matrix for one narrative, or for several.
#
# Runs the two matrix steps in sequence against a finished stage-3 run grid:
#   1. createMatrix_MM.R        report.mif x MM_linkage_mapping.csv -> matrix CSV
#   2. add_woodfuel_to_matrix.R fulldata.gdx woodfuel -> *_woodfuel.csv
# The *_woodfuel file is the one the MESSAGEix linkage consumes.
#
# Run it, or submit it, from the MAgPIE model root:
#   bash    messageix/emulator/run_matrix.sh                 # here and now
#   bash    messageix/emulator/run_matrix.sh --submit        # one SLURM job
#   bash    messageix/emulator/run_matrix.sh --submit --narratives all
#   sbatch  messageix/emulator/run_matrix.sh                 # direct sbatch
#
# Options (each has an environment variable of the same name):
#   --preset NAME        narrative column of the preset CSV        PRESET=default
#   --csv PATH           preset CSV                                PRESET_CSV=
#   --run-dir DIR        directory holding the stage-3 run folders BASE_OUTPUT_DIR=
#                        default: output/<identifier>/<preflag> from the preset
#   --out FILE           matrix CSV to write                       MATRIX_OUT=
#                        default: $MATRIX_DIR/<pipeline$matrix_basename>.csv
#   --matrix-dir DIR     directory for the default output name     MATRIX_DIR=output/emulator
#   --narratives LIST    comma-separated preset columns, or "all"  NARRATIVES=
#                        one SLURM array task per narrative; needs --submit
#   --allow-unmapped     build even when the mapping has misses    ALLOW_UNMAPPED=1
#   --submit             submit this script to SLURM and exit      SUBMIT=1
#
# Cluster settings -- the SLURM qos, the environment modules, the notification
# address -- come from the preset through messageix/R/utils_env.R, which applies
# the MAGPIE_MM_QOS, MAGPIE_MM_MODULES and MAGPIE_MM_MAIL_USER overrides itself.
# MAIL_USER is a shell-side alias for the last of those. Nothing about the
# environment is decided in this file.
#
# The #SBATCH block below is the fallback for a direct `sbatch run_matrix.sh`,
# which the scheduler reads before anything can ask R for the preset's values.
# `--submit` does not use it: it passes the preset's own qos and mail settings
# on the sbatch command line.
# =============================================================================

#SBATCH --job-name=mm_matrix
#SBATCH --output=mm_matrix_%A_%a.log
#SBATCH --qos=priority              # direct-sbatch fallback; --submit overrides it
#SBATCH --time=02:00:00             # serial map + matrix over the whole grid
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1           # both steps are single-threaded
#SBATCH --mem=8G                    # peak is one mif or one gdx plus the matrix

set -euo pipefail

# Absolute path to this file, resolved before any directory change so that both
# --help and the sbatch call below keep working from any working directory.
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# ---- configuration ----------------------------------------------------------

PRESET="${PRESET:-default}"
# The one path this file states for itself, because the R query that would
# answer it needs it as an argument. It is default_preset_csv() in R/utils_config.R.
PRESET_CSV="${PRESET_CSV:-messageix/presets/scenario_config.csv}"
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
    -h|--help)        sed -n '2,39p' "${SCRIPT_PATH}"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

# --narratives expands into a SLURM array, and the expansion lives in the
# submission block: without --submit the list would be read and then ignored,
# building only $PRESET and saying nothing. The exemption is the array task
# itself, which re-enters this script with NARRATIVES set and SUBMIT unset.
if [[ -n "${NARRATIVES}" && -z "${SUBMIT}" && -z "${SLURM_ARRAY_TASK_ID:-}" ]]; then
  echo ">> FATAL: --narratives submits one array task per narrative and needs --submit." >&2
  echo "          Without a scheduler, run the script once per narrative with --preset NAME." >&2
  exit 1
fi

# ---- model root -------------------------------------------------------------

# Both R scripts source messageix/R/ with paths relative to the model root, the
# same convention every MAgPIE start script follows.
if [[ -n "${SLURM_SUBMIT_DIR:-}" ]]; then
  cd "${SLURM_SUBMIT_DIR}"
else
  cd "$(dirname "${SCRIPT_PATH}")/../.."
fi

if [[ ! -f config/default.cfg ]]; then
  echo ">> FATAL: run from the MAgPIE model root; $(pwd) holds no config/default.cfg" >&2
  exit 1
fi

# ---- preset queries ---------------------------------------------------------

# Narrative columns a preset CSV offers, one per line.
preset_columns() {
  Rscript --vanilla -e '
    a <- commandArgs(trailingOnly = TRUE)
    source("messageix/R/utils_config.R")
    cat(preset_columns(a[1]), sep = "\n")
  ' "${PRESET_CSV}"
}

# The execution environment of one preset: the qos on the first line, the
# notification address (empty for none) on the second, and the module commands
# from the third on. Asked of the R layer rather than restated here, so that a
# site that changes its modules changes them in one file.
preset_env() {
  Rscript --vanilla -e '
    a <- commandArgs(trailingOnly = TRUE)
    source("messageix/R/utils_config.R")
    p <- resolve_config(a[1], a[2])
    mail <- mail_user(p)
    cat(paste(c(run_qos(p), if (is.null(mail)) "" else mail, slurm_module_lines(p)),
              collapse = "\n"), "\n", sep = "")
  ' "$1" "${PRESET_CSV}"
}

# Default run directory and default matrix basename, one per line, for a preset.
preset_paths() {
  Rscript --vanilla -e '
    a <- commandArgs(trailingOnly = TRUE)
    source("messageix/R/utils_config.R")
    p <- resolve_config(a[1], a[2])
    cat(dirname(results_folder(p, 3)), p$matrix_basename, sep = "\n")
  ' "$1" "${PRESET_CSV}"
}

# ---- this task's narrative --------------------------------------------------

# Before the environment query, so that an array task resolves the settings of
# the narrative it was given rather than of the submitting default.
if [[ -n "${NARRATIVES}" && -n "${SLURM_ARRAY_TASK_ID:-}" ]]; then
  IFS=',' read -r -a narrative_list <<< "${NARRATIVES}"
  PRESET="${narrative_list[${SLURM_ARRAY_TASK_ID}]}"
fi

# ---- execution environment --------------------------------------------------

module_lines=()
if command -v Rscript >/dev/null 2>&1; then
  env_lines=()
  while IFS= read -r line; do env_lines+=("${line}"); done < <(preset_env "${PRESET}")
  if [[ ${#env_lines[@]} -lt 2 ]]; then
    echo ">> FATAL: could not read the cluster settings of preset '${PRESET}' from ${PRESET_CSV}" >&2
    exit 1
  fi
  QOS="${env_lines[0]}"
  MAIL_USER="${MAIL_USER:-${env_lines[1]}}"
  if [[ ${#env_lines[@]} -gt 2 ]]; then module_lines=("${env_lines[@]:2}"); fi
else
  # This site's R lives inside a module, so the preset cannot be read yet and
  # the environment has to be given directly.
  QOS="${MAGPIE_MM_QOS:-}"
  MAIL_USER="${MAIL_USER:-${MAGPIE_MM_MAIL_USER:-}}"
  if [[ -z "${QOS}" || -z "${MAGPIE_MM_MODULES:-}" ]]; then
    echo ">> FATAL: no Rscript on PATH, so the qos and module list cannot be read from" >&2
    echo "          ${PRESET_CSV}; set MAGPIE_MM_QOS and MAGPIE_MM_MODULES" >&2
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
      NARRATIVES="$(preset_columns | paste -sd, -)"
    fi
    IFS=',' read -r -a narrative_list <<< "${NARRATIVES}"
    sbatch_args+=(--array=0-$(( ${#narrative_list[@]} - 1 )))
    export NARRATIVES
    echo ">> SUBMIT: ${#narrative_list[@]} narrative(s): ${NARRATIVES}"
    # In array mode each task derives its run directory and its output file from
    # its own narrative; one shared value would make the tasks collide, so
    # neither is exported here even when this invocation was given one.
  else
    if [[ -n "${BASE_OUTPUT_DIR}" ]]; then export BASE_OUTPUT_DIR; fi
    if [[ -n "${MATRIX_OUT}" ]]; then export MATRIX_OUT; fi
  fi
  exec sbatch "${sbatch_args[@]}" "${SCRIPT_PATH}"
fi

# ---- R environment ----------------------------------------------------------

# `module` is a shell function, and a batch script is not a login shell, so on
# some sites it has to be defined first.
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

preset_path=()
while IFS= read -r line; do preset_path+=("${line}"); done < <(preset_paths "${PRESET}")
if [[ ${#preset_path[@]} -lt 2 ]]; then
  echo ">> FATAL: could not resolve preset '${PRESET}' from ${PRESET_CSV}" >&2
  exit 1
fi
: "${BASE_OUTPUT_DIR:=${preset_path[0]}}"
: "${MATRIX_OUT:=${MATRIX_DIR}/${preset_path[1]}.csv}"

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
