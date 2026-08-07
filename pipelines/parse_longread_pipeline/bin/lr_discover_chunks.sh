#!/usr/bin/env bash
# ============================================================================
# lr_discover_chunks.sh -- list the long-read fastq "chunks" to process.
#
# The long-read input is a flat set of basecalled MinKNOW/PacBio fastq chunks
# that all belong to ONE Parse sublibrary ($LR_SUBLIB) -- unlike short-read
# input, there is no R1/R2 pairing to discover. This emits one chunk path per
# line (sorted, deterministic) -> the genpairs job array indexes it.
#
#   bin/lr_discover_chunks.sh | wc -l     # how many array tasks
# ============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
# shellcheck source=../slurm/lib/lr_common.sh
source "$REPO_ROOT/slurm/lib/lr_common.sh"

[[ -d "$FASTQ_DIR" ]] || die "FASTQ_DIR not found: $FASTQ_DIR"
log "Scanning for long-read fastq chunks under $FASTQ_DIR"

found="$(
    find -L "$FASTQ_DIR" -type f \( -name '*.fastq.gz' -o -name '*.fq.gz' \) 2>/dev/null \
    | grep -viE '(^|/)Undetermined' || true
)"
[[ -n "$found" ]] || die "no .fastq.gz chunks found under $FASTQ_DIR"

# Sort for a stable array index -> chunk mapping across re-submits.
printf '%s\n' "$found" | LC_ALL=C sort
