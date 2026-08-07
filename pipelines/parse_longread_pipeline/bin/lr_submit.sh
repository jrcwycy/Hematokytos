#!/usr/bin/env bash
# ============================================================================
# lr_submit.sh -- orchestrate the Parse LONG-READ split-pipe pipeline as a
#                 Slurm dependency DAG:
#
#     refs ──▶ genpairs[0..N-1]  (job array, one task per fastq chunk)
#                    │
#                    ▼
#                 finalize  (concat ▸ pre ▸ minimap2 ▸ post ▸ stage)
#
#   * refs builds the STAR ref + minimap2 index + junction BED (skipped if
#     already built into the shared folder).
#   * genpairs is a Slurm JOB ARRAY -- LR_generate_pairs per chunk, in parallel.
#   * finalize waits for the whole array (afterok), then runs the single
#     sublibrary through barcode-calling, spliced alignment, and reporting,
#     and stages the deliverables to RESULTS_DIR.
#
# Usage:
#   bin/lr_submit.sh                 # discover + submit the full DAG
#   bin/lr_submit.sh --dry-run       # show the plan; submit nothing
#   RUN_ID=my_run bin/lr_submit.sh   # name the run (default: timestamp)
# ============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

DRY_RUN=0; DO_FINAL=1; DO_PREP=1
for arg in "$@"; do
    case "$arg" in
        -n|--dry-run)   DRY_RUN=1 ;;
        --no-finalize)  DO_FINAL=0 ;;                 # submit refs + genpairs only
        --finalize-only) DO_PREP=0 ;;                 # submit only finalize (refs+genpairs already done)
        -h|--help)      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)              echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
    esac
done

: "${RUN_ID:=parse_lr_$(date +%Y%m%d_%H%M%S)}"
export RUN_ID
# shellcheck source=../slurm/lib/lr_common.sh
source "$REPO_ROOT/slurm/lib/lr_common.sh"
set -a; source "$REPO_ROOT/config/pipeline.config"; set +a

banner "Submitting Parse LONG-READ split-pipe pipeline"
setup_scratch

# --- 1. Discover chunks -> manifest on scratch -----------------------------
MANIFEST="$(lr_chunk_manifest)"
export LR_CHUNK_MANIFEST="$MANIFEST"
"$REPO_ROOT/bin/lr_discover_chunks.sh" > "$MANIFEST"
N="$(grep -c . "$MANIFEST" || true)"
(( N >= 1 )) || die "no fastq chunks discovered (check FASTQ_DIR)"
log "Discovered $N fastq chunk(s) for sublibrary '$LR_SUBLIB'"

# --- Reference: build, or reuse a prebuilt one -----------------------------
SKIP_REFS=0
[[ -f "$(lr_refs_done)" ]] && { SKIP_REFS=1; log "References present ($(lr_refs_done)); refs stage skipped"; }

common_sbatch=(
    --account="$SLURM_ACCOUNT"
    --partition="$SLURM_PARTITION"
    --mail-user="$SLURM_MAIL_USER"
    --mail-type="$SLURM_MAIL_TYPE"
    --export=ALL
)

if (( DRY_RUN )); then
    cat <<EOF

DRY RUN -- nothing submitted.

  Run id .......... $RUN_ID
  Account/part .... $SLURM_ACCOUNT / $SLURM_PARTITION
  Sublibrary ...... $LR_SUBLIB
  Kit / chem ...... $KIT / $CHEMISTRY   (long-read: LR_generate_pairs + minimap2 -x $MM2_XPRESET)
  Sample table .... ${SAMPLE_TABLE:-<none: all wells>}
  Reference ....... $([[ $SKIP_REFS == 1 ]] && echo "prebuilt (reuse)" || echo "build: STAR=$PARSE_GENOME_DIR, mmi=$MM2_INDEX, bed=$JUNC_BED")
  Chunks .......... $N  (array 0-$((N-1)), up to ${LR_ARRAY_THROTTLE} at once)
  Scratch work .... $WORK_DIR
  Results (shared)  $RESULTS_DIR
  Manifest ........ $MANIFEST

DAG: $([[ $SKIP_REFS == 1 ]] || echo 'refs -> ')genpairs[0-$((N-1))] -> finalize -> stage_out
EOF
    exit 0
fi

# --- 2+3. refs + genpairs (runs CONCURRENTLY -- genpairs does not use the
#          genome; only finalize needs the reference). Skipped with
#          --finalize-only. -------------------------------------------------
jid_refs="(skipped)"; jid_gp="(skipped)"
fin_deps=()
if (( DO_PREP )); then
    if (( ! SKIP_REFS )); then
        jid_refs="$(sbatch --parsable "${common_sbatch[@]}" \
            --job-name="parse-lr-refs-$RUN_ID" \
            --cpus-per-task="$REFS_CPUS" --mem="$REFS_MEM" --time="$REFS_TIME" \
            --output="$WORK_DIR/logs/refs_%j.out" \
            "$REPO_ROOT/slurm/lr/00_refs.sbatch")"
        log "Submitted refs        : job $jid_refs  (parallel with genpairs)"
        fin_deps+=("$jid_refs")
    fi
    jid_gp="$(sbatch --parsable "${common_sbatch[@]}" \
        --job-name="parse-lr-genpairs-$RUN_ID" \
        --array="0-$((N-1))%${LR_ARRAY_THROTTLE}" \
        --cpus-per-task="$GENPAIRS_CPUS" --mem="$GENPAIRS_MEM" --time="$GENPAIRS_TIME" \
        --output="$WORK_DIR/logs/genpairs_%A_%a.out" \
        "$REPO_ROOT/slurm/lr/10_genpairs.sbatch")"
    log "Submitted genpairs    : job $jid_gp  ($N tasks, up to $LR_ARRAY_THROTTLE at once)"
    fin_deps+=("$jid_gp")
fi

# --- 4. finalize -- waits on refs + genpairs (or env FIN_DEP for a manual
#        re-run). Skipped with --no-finalize. --------------------------------
jid_fin="(not submitted)"
if (( DO_FINAL )); then
    if (( ${#fin_deps[@]} > 0 )); then
        fin_dep_arg=(--dependency="$(IFS=:; echo "afterok:${fin_deps[*]}")")
    elif [[ -n "${FIN_DEP:-}" ]]; then
        fin_dep_arg=(--dependency="afterok:$FIN_DEP")
    else
        fin_dep_arg=()   # finalize-only with no dep: refs+genpairs already complete
    fi
    jid_fin="$(sbatch --parsable "${common_sbatch[@]}" "${fin_dep_arg[@]}" \
        --job-name="parse-lr-final-$RUN_ID" \
        --cpus-per-task="$FINAL_CPUS" --mem="$FINAL_MEM" --time="$FINAL_TIME" \
        --output="$WORK_DIR/logs/final_%j.out" \
        "$REPO_ROOT/slurm/lr/20_process.sbatch")"
    log "Submitted finalize    : job $jid_fin  (dependency: ${fin_dep_arg[*]:-none})"
fi

cat <<EOF

Submitted. Run id: $RUN_ID
  refs($jid_refs) ─┐
  genpairs($jid_gp) ─┴─> finalize($jid_fin)

  Scratch work dir : $WORK_DIR
  Results land in  : $RESULTS_DIR
  Logs             : $WORK_DIR/logs/

Watch progress:
  squeue --me
  tail -f $WORK_DIR/logs/*.out
EOF
