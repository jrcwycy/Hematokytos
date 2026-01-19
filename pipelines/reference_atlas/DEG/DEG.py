import os
import glob
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import seaborn as sns
import h5py
import sys
import scipy.sparse as sp
import yaml
from datetime import datetime
from pathlib import Path
from datetime import datetime

import anndata as an
import scanpy as sc

import argparse
import logging

sc.settings.verbosity = 3

def setup_logging():
    """Sets up logging to both console and file."""
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[
            logging.StreamHandler(sys.stdout),  # Log to console
        ]
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate samples from large sc corpus")

    parser.add_argument(
        "--inpath",
        dest="inpath",
        required=True,
        help="Name of the sample.",
    )

    parser.add_argument(
        "--outpath",
        dest="outpath",
        default='/scratch/indikar_root/indikar1/shared_data/hematokytos/',
        help="Path to the output file.",
    )

    args = parser.parse_args()

    inpath = args.inpath
    outpath = args.outpath

    setup_logging()
    logging.info(f"Reading data from: {inpath}")
    logging.info(f"Writing output to: {outpath}")

    basename = os.path.basename(inpath).replace(".h5ad", "")
    logging.info(f"Using basename: {basename}")

    """ LOAD THE DATA"""
    adata = sc.read_h5ad(inpath)
    logging.info(f"\t - {len(adata)} Cells")
    logging.info(f"\t - {adata.obs['basename'].nunique()} Datasets")
    logging.info(f"\t - {adata.obs['cell_type'].nunique()} Cell types")

    """ BASENAME DEG """
    logging.info(f"Starting differential gene expression analysis on `basename'...")

    sc.tl.rank_genes_groups(
        adata, 
        groupby='basename',
        use_raw=False,
        method='wilcoxon',
        pts=True,
    )

    logging.info(f"Finished differential gene expression analysis on `basename.'")
    logging.info(f"Extracting DEGs and saving...")
    
    deg = sc.get.rank_genes_groups_df(
        adata, 
        group=None,
    )

    deg_outpath = f"{outpath}{basename}_basename_deg.parquet"
    deg.to_parquet(deg_outpath, index=False)
    logging.info(f"Saved {deg.shape[0]} DEGs to: {deg_outpath}")

    """ Filter out rare cell types """
    # Count number of cells per cell_type
    cell_counts = adata.obs['cell_type'].value_counts()
    
    # Identify cell_types with at least 500 cells
    valid_cell_types = cell_counts[cell_counts >= 500].index
    
    # Filter the AnnData object
    adata = adata[adata.obs['cell_type'].isin(valid_cell_types)].copy()

    """ CELL TYPE DEG """
    logging.info(f"Starting differential gene expression analysis on `cell_type'...")

    sc.tl.rank_genes_groups(
        adata, 
        groupby='cell_type',
        use_raw=False,
        method='wilcoxon',
        pts=True,
    )

    logging.info(f"Finished differential gene expression analysis on `cell_type.'")
    logging.info(f"Extracting DEGs and saving...")
    
    deg = sc.get.rank_genes_groups_df(
        adata, 
        group=None,
    )

    deg_outpath = f"{outpath}{basename}_cell_type_deg.parquet"
    deg.to_parquet(deg_outpath, index=False)
    logging.info(f"Saved {deg.shape[0]} DEGs to: {deg_outpath}")

    logging.info(f"Script completed!")
    


    



    