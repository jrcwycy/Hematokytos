# ============================================================================
# common.sh  --  shared helpers sourced by every bin/ and slurm/ script.
#
# Requires REPO_ROOT to be set/exported by the caller before sourcing:
#   - bin/* scripts derive it from their own location.
#   - slurm/*.sbatch jobs receive it via `sbatch --export=...,REPO_ROOT=...`
#     (an sbatch job runs from a Slurm spool copy, so $0/BASH_SOURCE inside a
#      job does NOT point at the repo -- it must come from the environment).
# ============================================================================
# shellcheck shell=bash

set -euo pipefail

if [[ -z "${REPO_ROOT:-}" ]]; then
    echo "common.sh: REPO_ROOT is not set. Run via bin/lr_submit.sh, or export" \
         "REPO_ROOT=/path/to/repo before sourcing." >&2
    exit 1
fi

# Load the central configuration.
# shellcheck source=/dev/null
source "$REPO_ROOT/config/pipeline.config"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2; }
warn() { log "WARNING: $*"; }
die()  { log "ERROR: $*"; exit 1; }

# Pretty banner for the top of each job's log.
banner() {
    log "============================================================"
    log "$*"
    log "  host=$(hostname)  job=${SLURM_JOB_ID:-NA}  task=${SLURM_ARRAY_TASK_ID:-NA}"
    log "  run_id=$RUN_ID"
    log "  work_dir=$WORK_DIR"
    log "============================================================"
}

# ---------------------------------------------------------------------------
# Software environment: make `split-pipe` available on this node.
# ---------------------------------------------------------------------------
activate_env() {
    if [[ -n "$LOAD_MODULES" ]]; then
        # shellcheck disable=SC2086  # intentional word-splitting of module list
        module load $LOAD_MODULES || die "module load failed: $LOAD_MODULES"
    fi
    if [[ -f "$CONDA_BASE/etc/profile.d/conda.sh" ]]; then
        # shellcheck source=/dev/null
        source "$CONDA_BASE/etc/profile.d/conda.sh"
    else
        die "conda not found at CONDA_BASE=$CONDA_BASE (edit config/pipeline.config)"
    fi
    conda activate "$CONDA_ENV" || die "could not 'conda activate $CONDA_ENV'"
    command -v split-pipe >/dev/null 2>&1 \
        || die "'split-pipe' not on PATH after activating '$CONDA_ENV'"
    log "Using $(split-pipe --version 2>&1 | head -1) from env '$CONDA_ENV'"
}

# ---------------------------------------------------------------------------
# Scratch: every job computes on fast scratch; TMPDIR goes there too.
# ---------------------------------------------------------------------------
setup_scratch() {
    mkdir -p "$WORK_DIR" "$WORK_DIR/logs" \
        || die "cannot create WORK_DIR=$WORK_DIR (is SCRATCH_BASE correct?)"
    export TMPDIR="$WORK_DIR/tmp"
    mkdir -p "$TMPDIR"
    log "Scratch ready: $WORK_DIR  (TMPDIR=$TMPDIR)"
}

# Threads available to a step == CPUs Slurm gave this task.
nthreads() { echo "${SLURM_CPUS_PER_TASK:-${SLURM_CPUS_ON_NODE:-4}}"; }

# Path helpers (keep layout in one place).
genome_dir()      { echo "${PARSE_GENOME_DIR:-$WORK_DIR/genome}"; }
done_marker()     { echo "$1/PARSE_DONE"; }
