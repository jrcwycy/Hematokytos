# Parse Long-Read Single-Cell RNA-seq Pipeline — Summary

> **Note on availability:** This repository wraps Parse Biosciences' `split-pipe`
> software (v1.7.3), which is licensed to Parse customers only and is **not**
> redistributed here. This document describes what the pipeline does and how it
> is built, for readers who do not have access to the underlying repo or to
> `split-pipe` itself. It contains no proprietary Parse code or data.

## What it does

Converts Oxford Nanopore **long-read** scRNA-seq data, generated from a Parse
Biosciences Evercode combinatorial-barcoding library prep, into per-cell gene
expression count matrices and a QC report — the long-read analog of Parse's
standard (short-read, Illumina) `split-pipe` workflow.

Parse's commercial pipeline is built for short paired-end Illumina reads (R1 =
barcode, R2 = cDNA), aligned with STAR. Long reads don't have that structure:
each read is a single sequence containing the cDNA *and* the cell
barcode/UMI together, flanked by two known linker sequences, and needs a
splice-aware long-read aligner rather than STAR. This pipeline reformats each
long read into a synthetic short-read-style pair and drives `split-pipe`
through it, substituting `minimap2` for STAR at the alignment step. It follows
Parse's published long-read procedure, adapted from `split-pipe` v1.7.3.

## Input data (this run)

| Property | Value |
|---|---|
| Platform | Oxford Nanopore (MinKNOW) |
| Basecall model | `dna_r10.4.1_e8.2_400bps_hac` |
| Sample | Cells collected on days 0, 7, 14, and 21 of reprogramming — one Parse sublibrary |
| Raw data | 543 MinKNOW fastq chunks, ~218 GB total |
| Read length | ~200–4,600 bp |
| Kit | Evercode **WT Mini** (12-well) |
| Chemistry | **v3** |
| Reference genome | Human GRCh38, 10x Genomics `refdata-gex-GRCh38-2024-A` bundle (FASTA + GTF) |

## Software stack and versions

| Component | Version | Role |
|---|---|---|
| Parse `split-pipe` | **1.7.3** | Barcode calling, postprocessing, DGE/report generation (licensed, not included in this repo) |
| `LR_generate_pairs` | **1.0.0** | Parse's official script that splits a raw long read into a synthetic transcript read + barcode read, using linker detection (ships with Parse's long-read documentation, version-independent of `split-pipe` itself) |
| STAR | **2.7.11b** | Builds the reference index used by `split-pipe --mode pre/post` (alignment itself is done by minimap2, not STAR, in this workflow) |
| minimap2 | **2.31** | Spliced long-read alignment (`-x splice`), replacing STAR for the actual mapping step |
| samtools | **1.23** | SAM→BAM conversion |
| bedops (`convert2bed`) | latest via bioconda | GTF → BED conversion for minimap2's splice-junction hints |
| Python | **3.12** (pinned; required by `split-pipe`'s `numba<=0.61.2` constraint) | Runtime for `split-pipe` and `LR_generate_pairs` |
| Biopython, edlib | latest via pip | Sequence handling and fuzzy linker matching inside `LR_generate_pairs` |
| pigz | system | Parallel gzip compression of intermediate fastqs |

Orchestration is plain Bash + Slurm batch scripts (no workflow-manager
framework), run on a university HPC cluster (SLURM scheduler).

## Pipeline stages

The workflow is a four-stage Slurm job DAG:

```
   refs (1 job)                       genpairs[0..542]  (job ARRAY)
   ┌───────────────────┐               ┌───────────────────────────┐
   │ split-pipe mkref  │               │ one task per fastq chunk  │
   │ minimap2 index    │  concurrent   │ LR_generate_pairs (edlib) │
   │ GTF -> junction BED│  (no dep)    │ -> synthetic R1 + R2      │
   └────────┬──────────┘               └─────────────┬─────────────┘
            └───────────────────┬─────────────────────┘
                                │  (both must finish)
                                ▼
                          finalize (1 job)
     concat -> barcode calling -> minimap2 align -> stats patch ->
              SAM->BAM -> postprocess/DGE/report -> stage results
```

1. **refs** — builds three reference artifacts once and reuses them across
   runs: a STAR-format reference (used by `split-pipe` for barcode
   calling/postprocessing, even though STAR doesn't do the alignment here), a
   minimap2 index, and a splice-junction BED derived from the GTF. Chromosome
   names are prefixed consistently across all three so coordinates agree.
2. **genpairs** — a parallel job array, one task per raw fastq chunk. Each
   task runs `LR_generate_pairs`, which uses fuzzy (edit-distance) matching to
   locate Parse's two linker sequences in each long read and splits it into a
   synthetic short-read pair: a transcript/cDNA read and a barcode-bearing
   read. This step is independent of the reference genome, so it runs
   concurrently with the refs stage.
3. **guesskit** *(optional, off-DAG)* — empirically determines which Parse
   kit (e.g., WT vs. WT Mini) the library actually used, by running a quick
   barcode-calling pass on a subset of reads and scoring the observed
   barcodes against every kit's whitelist. Used once to pick the kit
   confidently rather than trusting a label.
4. **finalize** — the single-sublibrary "combine" of everything above:
   concatenates all synthetic read pairs, runs Parse's barcode-calling step,
   aligns the transcript reads with minimap2 in spliced mode, patches an
   alignment-statistics file (long-read alignment doesn't produce the STAR
   log that `split-pipe`'s postprocessing step expects, so equivalent counts
   are computed from the BAM), converts to BAM, runs Parse's postprocessing
   (cell calling, digital gene expression matrix, QC report), and stages the
   results to persistent storage.

Every stage is checkpointed (marker files), so failed array tasks or
interrupted finalize runs resume from the last completed step rather than
restarting from scratch.

## Outputs

* **Digital gene expression (DGE) matrices** — cells × genes sparse count
  matrices (MatrixMarket format), both a cell-called ("filtered") and raw
  ("unfiltered") version, each with per-cell and per-gene metadata tables.
* **HTML QC report** — interactive summary of cell calling, sequencing
  saturation, per-well statistics, and clustering (UMAP).
* **Annotated alignment BAM** — read-level alignments with cell
  barcode/UMI/gene annotations.
* Supporting CSVs (cluster assignments, marker genes, per-well counts) and
  run provenance (environment info, the exact chunk manifest processed).



## What's *not* included

* `split-pipe` v1.7.3 itself (Parse Biosciences proprietary software).
* `LR_generate_pairs_1.0.0.py` (ships attached to Parse's long-read
  documentation for customers).

Everything else described above — the Slurm orchestration, the reference-prep
and read-splitting logic around `split-pipe`, the minimap2 substitution for
STAR, and the alignment-statistics patch — is original wrapper code specific
to this repository.
