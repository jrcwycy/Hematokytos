# ============================================================================
# lr_common.sh -- helpers for the LONG-READ split-pipe pipeline.
# Sources the shared common.sh (env/scratch/logging) and adds path helpers
# for the long-read layout. Requires REPO_ROOT to be exported by the caller.
# ============================================================================
# shellcheck shell=bash
# shellcheck source=common.sh
source "$REPO_ROOT/slurm/lib/common.sh"

# --- Long-read layout under WORK_DIR (per-user scratch) ---------------------
lr_chunk_manifest() { echo "${LR_CHUNK_MANIFEST:-$WORK_DIR/chunks.txt}"; }   # 1 fastq chunk per line
lr_pairs_root()     { echo "$WORK_DIR/pairs"; }                              # per-chunk subdirs live here
lr_chunk_dir()      { echo "$WORK_DIR/pairs/$1"; }                           # $1 = chunk stem
lr_sublib_dir()     { echo "$WORK_DIR/sublib/$LR_SUBLIB"; }                  # concat + split-pipe output_dir
lr_parfile()        { echo "$(lr_sublib_dir)/parfile.txt"; }

# Reference markers (refs are built once into SHARED_BASE, then reused).
lr_refs_done()      { echo "$SHARED_BASE/refs/$GENOME_NAME/REFS_DONE"; }

# Strip a fastq basename to a unique per-chunk stem (drops .fastq.gz / .fq.gz).
chunk_stem() { local b="${1##*/}"; b="${b%.gz}"; b="${b%.fastq}"; b="${b%.fq}"; echo "$b"; }
