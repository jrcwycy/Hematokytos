#!/bin/bash
set -euo pipefail

# Paths
GTF_PATH="/nfs/turbo/umms-indikar/shared/projects/reference_genome/prebuilt/refdata-gex-GRCh38-2024-A/genes/genes.gtf"
SUPPA_PATH="/home/cstansbu/git_repositories/SUPPA/suppa.py"
OUTPUT_PATH="/nfs/turbo/umms-indikar/shared/projects/HSC/data/resources/suppa_AS_events/as_events"

# Logging helper
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

log "Job starting"

log "Using GTF: $GTF_PATH"
log "Using SUPPA script: $SUPPA_PATH"
log "Output directory: $OUTPUT_PATH"

log "Generating alternative splicing events with SUPPA (ioi) mode"
python "$SUPPA_PATH" generateEvents \
    -i "$GTF_PATH" \
    -o "$OUTPUT_PATH" \
    --pool-genes \
    --f ioi

log "Generating alternative splicing events with SUPPA (ioe) mode"
python "$SUPPA_PATH" generateEvents \
    -i "$GTF_PATH" \
    -o "$OUTPUT_PATH" \
    -f ioe \
    --pool-genes \
    --event-type SE SS MX RI FL

log "SUPPA finished"