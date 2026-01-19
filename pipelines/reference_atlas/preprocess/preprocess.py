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

import rmm
import cupy as cp
from rmm.allocators.cupy import rmm_cupy_allocator

import psutil
import torch
from datetime import datetime

import anndata as an
import scanpy as sc
import rapids_singlecell as rsc
import scvi

import argparse
import logging

sc.settings.verbosity = 3

# Enable `managed_memory`
rmm.reinitialize(
    managed_memory=True,
    pool_allocator=False,
)
cp.cuda.set_allocator(rmm_cupy_allocator)


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
        "--sample_name",
        dest="sample_name",
        required=True,
        help="Name of the sample.",
    )

    parser.add_argument(
        "--output",
        dest="outpath",
        default='/scratch/indikar_root/indikar1/shared_data/hematokytos/',
        help="Path to the output file.",
    )

    parser.add_argument(
        "--sample_size",
        dest="sample_size",
        default=200000,
        help="Maximum number of cells to sample from each file.",
    )

    parser.add_argument(
        "--test",
        action="store_true",
        help="Enable test mode",
    )

    args = parser.parse_args()

    sample_name = args.sample_name
    sample_size = args.sample_size
    outpath = args.outpath
    test = args.test

    setup_logging()

    logging.info(f"Writing output to: {outpath}")
    logging.info(f"Sample name: {sample_name}")
    logging.info(f"Sampling {sample_size} cells per file")

    """ LOAD THE DATA PATHS """
    logging.info(f" ######## DATA LOADING ######## ")
    dpath = "/nfs/turbo/umms-indikar/shared/projects/czi_projects/data/"
    file_list = glob.glob(f"{dpath}hsc_anndata/*.h5ad")
    adata_list = []

    if test:
        sample_size=1000
        logging.info(f"RUNNING IN TEST MODE.")
        file_list = file_list[1:2]
    
    for fpath in file_list:
        basename = os.path.basename(fpath).replace(".h5ad", "")
        logging.info(f"Working {basename}...")
        logging.info(f"\t - File path: {fpath}")
        adata = sc.read_h5ad(fpath)
        logging.info(f"\t - {len(adata)} Cells")
        logging.info(f"\t - {adata.obs['dataset_id'].nunique()} Datasets")
        logging.info(f"\t - {adata.obs['cell_type'].nunique()} Cell types")
        adata.obs['basename'] = basename
        adata.var_names = adata.var['feature_name']
    
        if not sample_size is None:
            if sample_size >= len(adata):
                logging.info(f"\t - Taking all cells")
            else:
                logging.info(f"\t - Sampled {sample_size} ({(sample_size / len(adata)) * 100:.2f}%)")
                adata = sc.pp.sample(adata, n=sample_size, copy=True)
        
        adata_list.append(adata)
    
    adata = an.concat(adata_list)
    adata.obs['dataset_id_int'] = adata.obs['dataset_id'].astype('category').cat.codes

    """ FILTERING """ 
    logging.info(f" ######## FILTERING ######## ")
    initial_cells, initial_genes = adata.shape
    logging.info(f"Loaded raw AnnData with {initial_cells} cells and {initial_genes} genes.")
    
    rsc.get.anndata_to_GPU(adata)
    rsc.pp.filter_cells(adata, min_counts=200)
    cells_after_count_filter, genes_after_count_filter = adata.shape
    logging.info(
        f"Filtered cells (min_counts=200). Removed {initial_cells - cells_after_count_filter} cells. "
    )
    
    rsc.pp.filter_genes(adata, min_cells=3)
    final_cells, final_genes = adata.shape
    logging.info(
        f"Filtered genes (min_cells=3). Removed {genes_after_count_filter - final_genes} genes. "
    )

    initial_cells, initial_genes = adata.shape
    logging.info(f"Filtered AnnData with {initial_cells} cells and {initial_genes} genes.")

    """ PREPROCESSING """
    logging.info(f" ######## PREPROCESSING ######## ")
    adata.raw = adata  # keep full dimension safe
    adata.layers['counts'] = adata.X.get()
    rsc.pp.normalize_total(adata, target_sum=1e4)
    rsc.pp.log1p(adata)
    
    """ FEATURE SELECTION """
    logging.info(f" ######## HIGHLY VARIABLE GENE SELECTION ######## ")
    logging.info(f"Number of genes before HVG selection: {adata.n_vars}")
    
    rsc.get.anndata_to_GPU(adata)
    rsc.pp.highly_variable_genes(
        adata, 
        batch_key="basename",
    )

    logging.info(f"Number of genes after HVG selection: {adata.var['highly_variable'].sum()}")

    """ PREPROCESSING """
    logging.info(f" ######## PREPROCESSING ######## ")

    rsc.pp.pca(adata)
    rsc.pp.neighbors(adata)
    rsc.tl.umap(adata, key_added='X_umap_raw_data')

    """ SCVI MODEL """
    logging.info(f" ######## BUILDING SCVI MODEL ######## ")
    rsc.get.anndata_to_CPU(adata)
    scvi.model.SCVI.setup_anndata(
        adata, 
        batch_key="dataset_id_int",
        labels_key='cell_type',
    )
    
    model = scvi.model.SCVI(
        adata,
        n_layers=2,
        n_latent=24,
        gene_likelihood="nb",
    )
    
    model.train(
        max_epochs=100,
        accelerator="gpu",
        devices="auto",
        enable_model_summary=True,
        batch_size=1000,
        early_stopping=True,
        early_stopping_patience=5,
        early_stopping_monitor='validation_loss',
    )
    
    adata.obsm["X_scVI"] = model.get_latent_representation()
    rsc.pp.neighbors(adata, use_rep="X_scVI", n_neighbors=150)
    rsc.tl.leiden(adata)
    rsc.tl.umap(adata, key_added='X_umap_scVI')

    """ SCVI MODEL """
    logging.info(f" ######## BUILDING SCANVI MODEL ######## ")

    scanvi_model = scvi.model.SCANVI.from_scvi_model(
        model,
        adata=adata,
        labels_key="cell_type",
        unlabeled_category="Unknown",
    )

    scanvi_model.train(
        max_epochs=20, 
        n_samples_per_label=100,
        accelerator="gpu",
        devices="auto",
        enable_model_summary=True,
        batch_size=1000,
        early_stopping=True,
        early_stopping_patience=5,
        early_stopping_monitor='validation_loss',
    )

    adata.obsm['X_scANVI'] = scanvi_model.get_latent_representation(adata)
    rsc.pp.neighbors(adata, use_rep="X_scANVI", n_neighbors=150)
    rsc.tl.leiden(adata)
    rsc.tl.umap(adata, key_added='X_umap_X_scANVI')

    logging.info(f" ######## SAVING ANNDATA ######## ")
    output_path = f"{outpath}{sample_name}_adata.h5ad"
    adata.write(output_path)
    logging.info(adata)
    
    logging.info(f" ######## SAVING SCANVI MODEL ######## ")

    # store the model
    outpath = f"{outpath}{sample_name}"
    scanvi_model.save(
        outpath, 
        overwrite=True, 
        save_anndata=True,
        prefix=f"scanvi_"
    ) 

    flag_file = Path(f"{outpath}{sample_name}.done")
    flag_file.touch()

    logging.info(f"Script completed!")
    


    



    