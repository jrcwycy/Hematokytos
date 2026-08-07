#!/usr/bin/env bash
# ============================================================================
# LR Stage 0.5 -- empirically determine the kit from the data. Runs a quick
# `split-pipe --mode pre` on a SUBSET of the generated barcode reads; split-pipe
# scores the observed round-1 barcodes against every kit whitelist
# (kits.guess_kit_from_bc) and writes process/kit_bc_scores.csv. We read the
# winner to choose WT vs WT_mini (etc.) before committing the full finalize.
#
# Depends on refs + genpairs (needs the STAR ref and the per-chunk pairs).
# ============================================================================
#SBATCH --job-name=parse-lr-guesskit
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --output=guesskit_%j.out

set -euo pipefail
: "${REPO_ROOT:?must be exported (run via bin/lr_submit.sh)}"
# shellcheck source=../lib/lr_common.sh
source "$REPO_ROOT/slurm/lib/lr_common.sh"

banner "LR Stage 0.5: empirical kit determination"
setup_scratch
activate_env

NTHREADS="$(nthreads)"
N_SAMPLE="${LR_KIT_SAMPLE_CHUNKS:-30}"   # how many completed chunks to sample
PROBE_KIT="${LR_KIT_PROBE:-WT}"          # any valid kit; scoring evaluates ALL kits
KC="$WORK_DIR/kitcheck"
rm -rf "$KC"; mkdir -p "$KC"
[[ -d "$PARSE_GENOME_DIR" ]] || die "STAR reference missing: $PARSE_GENOME_DIR"

# --- build a small subset concat from completed chunks ---------------------
sub_r1="$KC/sub_R1.fastq.gz"; sub_r2="$KC/sub_R2.fastq.gz"
: > "$sub_r1"; : > "$sub_r2"
n=0
while IFS= read -r d; do
    cd="$(dirname "$d")"
    [[ -f "$cd/split_R1.fastq.gz" && -f "$cd/split_R2.fastq.gz" ]] || continue
    cat "$cd/split_R1.fastq.gz" >> "$sub_r1"
    cat "$cd/split_R2.fastq.gz" >> "$sub_r2"
    n=$((n + 1)); (( n >= N_SAMPLE )) && break
done < <(find "$(lr_pairs_root)" -name PARSE_DONE 2>/dev/null | LC_ALL=C sort)
(( n > 0 )) || die "no completed chunk pairs found under $(lr_pairs_root)"
log "Built kit-check subset from $n chunks ($(zcat "$sub_r1" | wc -l | awk '{print $1/4}') reads)"

# --- run pre (kit scoring happens automatically) ---------------------------
printf '%s\n' "$LR_PARFILE_LINES" > "$KC/parfile.txt"
log "split-pipe --mode pre --one_step --kit $PROBE_KIT (scores ALL kits)"
split-pipe \
    --mode pre --one_step \
    --kit "$PROBE_KIT" \
    --chemistry "$CHEMISTRY" \
    --fq1 "$sub_r1" \
    --genome_dir "$PARSE_GENOME_DIR" \
    --parfile "$KC/parfile.txt" \
    --output_dir "$KC" \
    --nthreads "$NTHREADS"

echo "=================== KIT SCORES ===================" >&2
scores="$KC/process/kit_bc_scores.csv"
if [[ -f "$scores" ]]; then
    cat "$scores" >&2
    cp -f "$scores" "$WORK_DIR/kit_bc_scores.csv"
    log "kit scores copied to $WORK_DIR/kit_bc_scores.csv"
else
    warn "kit_bc_scores.csv not found; check the log above for 'scoring kit' lines"
    grep -aiE "scoring kit|kit .*=|Best scoring" "$WORK_DIR/logs/guesskit_${SLURM_JOB_ID}.out" >&2 || true
fi
log "Kit determination complete."
