#install.packages("SeuratObject")
#install.packages("Seurat")

library(SeuratObject)
library(Seurat)
library(Matrix)

x <- readRDS("/nfs/turbo/umms-indikar/shared/projects/HSC/data/datasets/ng_2024/iHSC.rds")

str(x)
class(x)


View(x)


counts_matrix <- x[["RNA"]]@counts


outpath <- "/scratch/indikar_root/indikar1/shared_data/hematokytos/new_processed/Ng_raw_counts.mtx"
Matrix::writeMM(counts_matrix, file=outpath)

outpath_cells <- "/scratch/indikar_root/indikar1/shared_data/hematokytos/new_processed/Ng_cells.csv"
outpath_genes <- "/scratch/indikar_root/indikar1/shared_data/hematokytos/new_processed/Ng_genes.csv"

write.csv(colnames(counts_matrix), outpath_cells, row.names = FALSE)
write.csv(rownames(counts_matrix), outpath_genes, row.names = FALSE)

