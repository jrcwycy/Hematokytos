#!/usr/bin/env bash
# ============================================================================
# LR Stage 2 -- finalize the sublibrary. Runs after the genpairs array:
#   concat per-chunk pairs -> split-pipe --mode pre (barcode calling)
#   -> minimap2 spliced alignment -> patch pre_align_stats.csv + sam->bam
#   -> split-pipe --mode post (mol/dge/reports) -> stage to RESULTS_DIR.
#
# Only ONE Parse sublibrary exists per run, so there is no --mode comb step
# (combine is only needed to merge multiple sublibraries).
# ============================================================================
#SBATCH --job-name=parse-lr-final
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --output=final_%j.out

set -euo pipefail
: "${REPO_ROOT:?must be exported (run via bin/lr_submit.sh)}"
# shellcheck source=../lib/lr_common.sh
source "$REPO_ROOT/slurm/lib/lr_common.sh"

banner "LR Stage 2: finalize sublibrary '$LR_SUBLIB'"
setup_scratch
activate_env

NTHREADS="$(nthreads)"
OUT="$(lr_sublib_dir)"; mkdir -p "$OUT"
PROC="$OUT/process"
MANIFEST="$(lr_chunk_manifest)"
[[ -f "$MANIFEST" ]] || die "chunk manifest not found: $MANIFEST"
[[ -f "$MM2_INDEX" ]] || die "minimap2 index missing: $MM2_INDEX (did refs run?)"
[[ -f "$JUNC_BED"  ]] || die "junction BED missing: $JUNC_BED (did refs run?)"
[[ -d "$PARSE_GENOME_DIR" ]] || die "STAR reference missing: $PARSE_GENOME_DIR"

# --- 1. Concatenate per-chunk read pairs (stable manifest order) -----------
R1="$OUT/concat_split_R1.fastq.gz"; R2="$OUT/concat_split_R2.fastq.gz"
if [[ -f "$(done_marker "$OUT")_concat" ]]; then
    log "Concat already done; reusing $R1 / $R2"
else
    : > "$R1"; : > "$R2"
    n_ok=0; n_missing=0
    while IFS= read -r chunk; do
        [[ -n "$chunk" ]] || continue
        d="$(lr_chunk_dir "$(chunk_stem "$chunk")")"
        if [[ -f "$d/split_R1.fastq.gz" && -f "$d/split_R2.fastq.gz" ]]; then
            cat "$d/split_R1.fastq.gz" >> "$R1"
            cat "$d/split_R2.fastq.gz" >> "$R2"
            n_ok=$((n_ok + 1))
        else
            n_missing=$((n_missing + 1))
            warn "missing pairs for chunk $(chunk_stem "$chunk") -- skipped"
        fi
    done < "$MANIFEST"
    (( n_ok > 0 )) || die "no per-chunk pairs found to concatenate (did genpairs run?)"
    log "Concatenated $n_ok chunk(s) ($n_missing missing) -> $R1 / $R2"
    touch "$(done_marker "$OUT")_concat"
fi

# --- 2. parfile + split-pipe --mode pre (barcode calling) ------------------
parfile="$(lr_parfile)"
printf '%s\n' "$LR_PARFILE_LINES" > "$parfile"
log "parfile ($parfile):"; sed 's/^/    /' "$parfile" >&2

samp_args=()
if [[ -n "${SAMPLE_TABLE:-}" ]]; then
    [[ -f "$SAMPLE_TABLE" ]] || die "SAMPLE_TABLE set but not found: $SAMPLE_TABLE"
    samp_args=(--samp_sltab "$SAMPLE_TABLE")
fi

if [[ -f "$PROC/pre_align_stats.csv" && -f "$(done_marker "$OUT")_pre" ]]; then
    log "--mode pre already complete; skipping"
else
    log "split-pipe --mode pre --one_step (kit=$KIT chemistry=$CHEMISTRY)"
    split-pipe \
        --mode pre --one_step \
        --kit "$KIT" \
        --chemistry "$CHEMISTRY" \
        --fq1 "$R1" \
        --genome_dir "$PARSE_GENOME_DIR" \
        --parfile "$parfile" \
        --output_dir "$OUT" \
        --nthreads "$NTHREADS" \
        "${samp_args[@]}"
    touch "$(done_marker "$OUT")_pre"
fi

# barcode_head.fastq -> .gz for minimap2
bc_fq="$PROC/barcode_head.fastq.gz"
if [[ -f "$PROC/barcode_head.fastq" ]]; then
    pigz -f -p "$NTHREADS" "$PROC/barcode_head.fastq"
fi
[[ -f "$bc_fq" ]] || die "barcode_head.fastq(.gz) not produced by --mode pre"

# --- 3. minimap2 spliced alignment -----------------------------------------
sam="$PROC/aligned.sam"
log "minimap2 -x $MM2_XPRESET (long-read spliced alignment) -> $sam"
minimap2 --MD -a -u f -x "$MM2_XPRESET" -t "$NTHREADS" \
    --junc-bed "$JUNC_BED" "$MM2_INDEX" "$bc_fq" > "$sam"

# --- 4. patch pre_align_stats.csv (minimap2 doesn't write STAR's Log) ------
# split-pipe --mode post READS reads_align_input/unique/multimap from this file
# (align.py:have_postprocess_ins). In the STAR path parse_star_output() fills
# them; in the LR path we must add them ourselves.
stats="$PROC/pre_align_stats.csv"
[[ -f "$stats" ]] || die "pre_align_stats.csv missing: $stats"
valbc="$(awk -F, '$1=="reads_valid_barcode"{print $2; exit}' "$stats")"
[[ -n "$valbc" ]] || die "reads_valid_barcode not found in $stats"
uniq="$(samtools view -c -q 60 -F 0x904 "$sam")"   # primary, mapped, MAPQ>=60
mapped="$(samtools view -c -F 0x904 "$sam")"        # primary, mapped (any MAPQ)
multi=$(( mapped - uniq ))
log "alignment stats: input(valid_bc)=$valbc unique(MAPQ>=60)=$uniq multimap=$multi"
grep -vE '^(reads_align_input|reads_align_unique|reads_align_multimap),' "$stats" > "$stats.tmp"
{ echo "reads_align_input,$valbc"
  echo "reads_align_unique,$uniq"
  echo "reads_align_multimap,$multi"; } >> "$stats.tmp"
mv "$stats.tmp" "$stats"

# --- 5. sam -> bam (the name split-pipe --mode post expects: PF_BAM_RAW) ----
bam="$PROC/barcode_headAligned.out.bam"
log "samtools view -> $bam"
samtools view -@ "$NTHREADS" -b "$sam" > "$bam"
rm -f "$sam"   # large intermediate; the bam is what post consumes

# --- 6. split-pipe --mode post (postprocess -> mol -> dge -> reports) ------
log "split-pipe --mode post (run to completion)"
split-pipe \
    --mode post \
    --chemistry "$CHEMISTRY" \
    --genome_dir "$PARSE_GENOME_DIR" \
    --parfile "$parfile" \
    --output_dir "$OUT" \
    --nthreads "$NTHREADS"
touch "$(done_marker "$OUT")"

# --- 7. stage results to the shared scratch folder -------------------------
log "Staging results -> $RESULTS_DIR"
mkdir -p "$RESULTS_DIR"
rsync -a --human-readable \
    --exclude='concat_split_R1.fastq.gz' --exclude='concat_split_R2.fastq.gz' \
    --exclude='process/barcode_head.fastq.gz' --exclude='process/aligned.sam' \
    "$OUT/" "$RESULTS_DIR/$LR_SUBLIB/"
cp -f "$MANIFEST" "$RESULTS_DIR/" 2>/dev/null || true

log "Pipeline complete. Sublibrary '$LR_SUBLIB': $OUT  ->  $RESULTS_DIR/$LR_SUBLIB"
du -sh "$RESULTS_DIR" 2>/dev/null | while read -r s _; do log "  staged size: $s"; done || true
