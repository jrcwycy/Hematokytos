#!/usr/bin/env bash
# ============================================================================
# lr_install_env.sh -- one-time setup of the conda env for the Parse
#                      LONG-READ (Nanopore/PacBio) split-pipe workflow.
#
# Creates env $CONDA_ENV (default: spipe) and installs:
#   * split-pipe + its deps (STAR, samtools, pigz, gcc) via Parse's own
#     install_dependencies_conda.sh, then `pip install .`
#   * long-read extras NOT covered by Parse's installer:
#       - minimap2, bedops   (conda: bioconda)   long-read aligner + GTF->BED
#       - biopython, edlib   (pip)               needed by LR_generate_pairs
#
# split-pipe itself is Parse Biosciences licensed software and is NOT part of
# this repo. Download it from your Parse customer portal, unpack it, and
# point PKG_DIR at it before running this script:
#
#   PKG_DIR=/path/to/ParseBiosciences-Pipeline.X.Y.Z bash bin/lr_install_env.sh \
#       2>&1 | tee install_lr.log
#
# Idempotent-ish: re-running re-installs into the same env.
# ============================================================================
set -euo pipefail

CONDA_BASE="${CONDA_BASE:-$HOME/miniconda3}"
CONDA_ENV="${CONDA_ENV:-spipe}"
: "${PKG_DIR:?set PKG_DIR to your unpacked, licensed split-pipe install (e.g. .../ParseBiosciences-Pipeline.1.7.3)}"
[[ -f "$PKG_DIR/setup.py" ]] || { echo "PKG_DIR does not look like a split-pipe source tree (no setup.py): $PKG_DIR" >&2; exit 1; }

echo ">>> conda base: $CONDA_BASE ; env: $CONDA_ENV ; pkg: $PKG_DIR"
# shellcheck source=/dev/null
source "$CONDA_BASE/etc/profile.d/conda.sh"

# 1. Create the env (python >=3.12.8 per split-pipe's setup.py) if needed.
if ! conda env list | awk '{print $1}' | grep -qx "$CONDA_ENV"; then
    # Pin python 3.12: split-pipe needs >=3.12.8, and Parse pins numba<=0.61.2
    # which has no build for 3.13/3.14. 3.12 is the tested/compatible line.
    echo ">>> creating env $CONDA_ENV (python=3.12)"
    conda create --yes -n "$CONDA_ENV" -c conda-forge "python=3.12" pip
else
    echo ">>> env $CONDA_ENV already exists; installing into it"
fi

conda activate "$CONDA_ENV"
echo ">>> active env: $CONDA_DEFAULT_ENV ; python $(python --version 2>&1)"

# 2. Parse's own dependency installer (STAR, samtools, pigz, gcc, numba ...).
echo ">>> running Parse install_dependencies_conda.sh -i -y"
( cd "$PKG_DIR" && bash ./install_dependencies_conda.sh -i -y )

# 3. The pipeline itself (compiles Cython extensions).
echo ">>> pip install split-pipe from $PKG_DIR"
( cd "$PKG_DIR" && pip install . --no-cache-dir )

# 4. Long-read extras.
echo ">>> installing long-read tools: minimap2, bedops (conda)"
conda install --yes -c bioconda -c conda-forge minimap2 bedops
echo ">>> installing LR_generate_pairs python deps: biopython, edlib (pip)"
pip install --no-cache-dir biopython edlib

# 5. Verify.
echo ">>> ===== VERIFICATION ====="
split-pipe --version 2>&1 | head -1 || { echo "FAIL: split-pipe"; exit 1; }
for t in STAR samtools minimap2 convert2bed pigz; do
    printf '  %-12s %s\n' "$t" "$(command -v "$t" || echo MISSING)"
done
python - <<'PY'
import importlib, sys
for m in ("Bio", "edlib"):
    try:
        importlib.import_module(m); print(f"  python import {m}: OK")
    except Exception as e:
        print(f"  python import {m}: FAIL {e}"); sys.exit(1)
PY
echo ">>> install complete."
