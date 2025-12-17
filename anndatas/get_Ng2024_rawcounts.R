#install.packages("SeuratObject")
#install.packages("Seurat")

library(SeuratObject)
library(Seurat)
library(Matrix)

x <- readRDS("/nfs/turbo/umms-indikar/shared/projects/HSC/data/datasets/ng_2024/iHSC.rds")
#print(x)

str(x)
class(x)


View(x)


counts_matrix <- x[["RNA"]]@counts
#summary(counts_matrix)

#head(counts_matrix)


#counts <- as.matrix(counts_matrix)

#outpath <- "/scratch/indikar_root/indikar1/shared_data/hematokytos/new_processed/Ng_raw.csv"
#write.csv(counts, file=outpath)

outpath <- "/scratch/indikar_root/indikar1/shared_data/hematokytos/new_processed/Ng_raw_counts.mtx"
Matrix::writeMM(counts_matrix, file=outpath)

outpath_cells <- "/scratch/indikar_root/indikar1/shared_data/hematokytos/new_processed/Ng_cells.csv"
outpath_genes <- "/scratch/indikar_root/indikar1/shared_data/hematokytos/new_processed/Ng_genes.csv"

write.csv(colnames(counts_matrix), outpath_cells, row.names = FALSE)
write.csv(rownames(counts_matrix), outpath_genes, row.names = FALSE)

