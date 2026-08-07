#!/usr/bin/env bash
# ============================================================================
# LR Stage 0 -- references for the long-read workflow. Builds, ONCE, into the
# shared scratch folder (then reused via markers):
#   1. split-pipe --mode mkref  : STAR reference used by --mode pre/post
#   2. minimap2 -d              : long-read alignment index (map-ont)
#   3. GTF -> junction BED      : minimap2 --junc-bed input
#
# CRITICAL: split-pipe mkref prefixes chromosome names with the genome name
# (mkref_chr_geno_prefix=True). The minimap2 fasta/bed chrom names MUST carry
# the SAME prefix or alignment coordinates won't match. We derive the exact
# prefix from the built reference's chrName.txt rather than assume.
# ============================================================================
#SBATCH --job-name=parse-lr-refs
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --output=refs_%j.out

set -euo pipefail
: "${REPO_ROOT:?must be exported (run via bin/lr_submit.sh)}"
# shellcheck source=../lib/lr_common.sh
source "$REPO_ROOT/slurm/lib/lr_common.sh"

banner "LR Stage 0: references ($GENOME_NAME)"
setup_scratch
activate_env

if [[ -f "$(lr_refs_done)" ]]; then
    log "References already built ($(lr_refs_done)) -- nothing to do."
    exit 0
fi

[[ -f "$FASTA_PATH" ]] || die "FASTA not found: $FASTA_PATH"
[[ -f "$GTF_PATH"   ]] || die "GTF not found: $GTF_PATH"
NTHREADS="$(nthreads)"
mm2_dir="$(dirname "$MM2_INDEX")"
mkdir -p "$PARSE_GENOME_DIR" "$mm2_dir"

# --- 1. split-pipe STAR reference -----------------------------------------
if [[ -f "$PARSE_GENOME_DIR/genome.bin" || -f "$(done_marker "$PARSE_GENOME_DIR")" ]]; then
    log "STAR reference already present at $PARSE_GENOME_DIR"
else
    log "Building split-pipe STAR reference into $PARSE_GENOME_DIR ($NTHREADS threads)"
    split-pipe \
        --mode mkref \
        --genome_name "$GENOME_NAME" \
        --fasta "$FASTA_PATH" \
        --genes "$GTF_PATH" \
        --output_dir "$PARSE_GENOME_DIR" \
        --nthreads "$NTHREADS"
    touch "$(done_marker "$PARSE_GENOME_DIR")"
fi

# --- derive the chromosome-name prefix mkref actually used ------------------
chrname="$(find -L "$PARSE_GENOME_DIR" -name chrName.txt -print -quit 2>/dev/null || true)"
[[ -n "$chrname" ]] || die "chrName.txt not found under $PARSE_GENOME_DIR (mkref incomplete?)"
first_chr="$(head -1 "$chrname")"
if [[ "$first_chr" == "${GENOME_NAME}_"* ]]; then
    PREF="${GENOME_NAME}_"
else
    PREF=""
fi
log "Reference chrom prefix: '${PREF}' (first chrName entry: $first_chr)"

# --- 2. minimap2 index (prefix fasta chrom names to match the STAR ref) ----
if [[ -f "$MM2_INDEX" ]]; then
    log "minimap2 index already present: $MM2_INDEX"
else
    pre_fa="$mm2_dir/${GENOME_NAME}.pre.fa"
    log "Prefixing FASTA chrom names with '${PREF}' -> $pre_fa"
    if [[ "$FASTA_PATH" == *.gz ]]; then zcat "$FASTA_PATH"; else cat "$FASTA_PATH"; fi \
        | sed "s/^>/>${PREF}/" > "$pre_fa"
    log "Building minimap2 $MM2_INDEX_PRESET index -> $MM2_INDEX"
    minimap2 -t "$NTHREADS" -x "$MM2_INDEX_PRESET" -d "$MM2_INDEX" "$pre_fa"
    rm -f "$pre_fa"
fi

# --- 3. junction BED from GTF (add transcript_id, convert, prefix) ---------
if [[ -f "$JUNC_BED" ]]; then
    log "Junction BED already present: $JUNC_BED"
else
    log "Building junction BED -> $JUNC_BED"
    awk '{ if ($0 ~ /transcript_id/) print $0; else print $0 " transcript_id \"" NR "\";"; }' "$GTF_PATH" \
        | convert2bed --input=gtf --output=bed \
        | sed "s/^/${PREF}/" > "$JUNC_BED"
fi

mkdir -p "$(dirname "$(lr_refs_done)")"
touch "$(lr_refs_done)"
log "References complete: STAR=$PARSE_GENOME_DIR  mmi=$MM2_INDEX  bed=$JUNC_BED"
