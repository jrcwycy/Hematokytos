#!/usr/bin/env bash
# ============================================================================
# LR Stage 1 -- generate paired-end reads from long reads. JOB ARRAY: one task
# per fastq chunk. Each task runs LR_generate_pairs (edlib linker detection),
# emitting split_R1 (transcript) + split_R2 (barcode) for its chunk.
#
# Each task writes to its OWN dir ($WORK_DIR/pairs/<stem>/) because
# LR_generate_pairs also emits fixed-name unmatched.fastq / empty_cDNA.fastq
# that would otherwise collide across concurrent tasks. Idempotent via a
# PARSE_DONE marker so failed indices can be re-run with --array=<ids>.
#
# $SLURM_ARRAY_TASK_ID selects line (id+1) of the chunk manifest.
# ============================================================================
#SBATCH --job-name=parse-lr-genpairs
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --output=genpairs_%A_%a.out

set -euo pipefail
: "${REPO_ROOT:?must be exported (run via bin/lr_submit.sh)}"
# shellcheck source=../lib/lr_common.sh
source "$REPO_ROOT/slurm/lib/lr_common.sh"

: "${SLURM_ARRAY_TASK_ID:?this script must run as a job array (use bin/lr_submit.sh)}"
MANIFEST="$(lr_chunk_manifest)"
[[ -f "$MANIFEST" ]] || die "chunk manifest not found: $MANIFEST"

chunk="$(sed -n "$((SLURM_ARRAY_TASK_ID + 1))p" "$MANIFEST")"
[[ -n "$chunk" ]] || die "no manifest row for array index $SLURM_ARRAY_TASK_ID"
[[ -f "$chunk" ]] || die "chunk fastq missing: $chunk"
stem="$(chunk_stem "$chunk")"
out="$(lr_chunk_dir "$stem")"

banner "LR Stage 1: genpairs chunk '$stem' (idx $SLURM_ARRAY_TASK_ID)"
setup_scratch
activate_env

if [[ -f "$(done_marker "$out")" ]]; then
    log "Chunk '$stem' already done -- skipping."
    exit 0
fi
rm -rf "$out"; mkdir -p "$out"

log "LR_generate_pairs: chemistry=$CHEMISTRY l1dist=$LR_L1DIST l2dist=$LR_L2DIST"
python "$LR_PAIRS_SCRIPT" \
    --fastq "$chunk" \
    --new_fname split \
    --out_dir "$out" \
    --chemistry "$CHEMISTRY" \
    --l1dist "$LR_L1DIST" \
    --l2dist "$LR_L2DIST"

# LR_generate_pairs writes UNCOMPRESSED fastq; compress the pair we keep.
# Note: chemistry is validated up front, so a chunk with no pairs means an
# empty/odd chunk -- warn and keep an empty (valid) gz so the array still
# completes (afterok) and the concat step just contributes nothing from it.
r1="$out/split_R1.fastq"; r2="$out/split_R2.fastq"
[[ -f "$r1" && -f "$r2" ]] || die "LR_generate_pairs did not emit R1/R2 for '$stem' (script error?)"
[[ -s "$r1" ]] || warn "chunk '$stem' produced ZERO read pairs (empty/odd chunk)"
pigz -f -p "$(nthreads)" "$r1" "$r2"
# unmatched/empty are diagnostics only; drop them to save scratch.
rm -f "$out/unmatched.fastq" "$out/empty_cDNA.fastq"

touch "$(done_marker "$out")"
log "Chunk '$stem' complete: $out (R1=$(basename "$r1").gz R2=$(basename "$r2").gz)"
