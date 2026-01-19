suppressPackageStartupMessages(library("Capybara"))
suppressPackageStartupMessages(library("zellkonverter"))
suppressPackageStartupMessages(library("SingleCellExperiment"))
suppressPackageStartupMessages(library("readr"))
suppressPackageStartupMessages(library("reshape2"))
suppressPackageStartupMessages(library("ggplot2"))


# structure the command-line args
args <- commandArgs(trailingOnly = TRUE)

# Expecting --ref_path=... --data_path=... --output_dir=... --prefix=...
args_list <- list()
for (arg in args) {
  keyval <- strsplit(sub("^--", "", arg), "=")[[1]]
  args_list[[keyval[1]]] <- keyval[2]
}

ref_path   <- args_list$ref_path
data_path  <- args_list$data_path
output_dir <- args_list$output_dir
prefix     <- args_list$prefix

# Basic validation
if (any(sapply(list(ref_path, data_path, output_dir, prefix), is.null))) {
  stop("Missing one or more required arguments: --ref_path, --data_path, --output_dir, --prefix")
}

#' Load a SingleCellExperiment object from H5AD and extract key components
#'
#' @param path Path to the .h5ad file.
#' @param assay_name Name of the assay to extract (default: "X").
#' @return A list with the loaded object, counts matrix, and cell metadata.
load_data <- function(path, assay_name = "X") {
  start_time <- Sys.time()
  cat("\n=== Loading H5AD ===\n")
  cat("Input path: ", path, "\n")
  obj <- readH5AD(path)
  cat("✓ File successfully loaded.\n")

  cat("Extracting assay: '", assay_name, "'...\n", sep = "")
  counts <- assay(obj, assay_name)
  cat("✓ Assay matrix dimensions: ", nrow(counts), " genes x ", ncol(counts), " cells\n")

  cat("Extracting cell metadata (obs)...\n")
  obs <- as.data.frame(colData(obj))
  cat("✓ Metadata dimensions: ", nrow(obs), " cells x ", ncol(obs), " fields\n")

  end_time <- Sys.time()
  cat("✓ Data loading complete. Time taken: ", round(difftime(end_time, start_time, units = "secs"), 2), " seconds\n")
  return(list(obj = obj, counts = counts, obs = obs))
}

# Load reference dataset
cat("\n=== Loading Reference Dataset ===\n")
ref_data <- load_data(ref_path)

# Load query dataset
cat("\n=== Loading Query Dataset ===\n")
data <- load_data(data_path)

# Handle gene intersection
cat("\n=== Matching Genes Between Datasets ===\n")
cat("Original dimensions:\n")
cat("- Reference: ", dim(ref_data$counts)[1], " genes x ", dim(ref_data$counts)[2], " cells\n")
cat("- Query:     ", dim(data$counts)[1], " genes x ", dim(data$counts)[2], " cells\n")

common_genes <- intersect(rownames(ref_data$counts), rownames(data$counts))
cat("✓ Common genes identified: ", length(common_genes), "\n")

ref_data$counts <- ref_data$counts[common_genes, , drop = FALSE]
data$counts     <- data$counts[common_genes, , drop = FALSE]

cat("Filtered dimensions:\n")
cat("- Reference: ", dim(ref_data$counts)[1], " genes x ", dim(ref_data$counts)[2], " cells\n")
cat("- Query:     ", dim(data$counts)[1], " genes x ", dim(data$counts)[2], " cells\n")

# Save ref_data$obs to CSV
ref_obs_path <- file.path(output_dir, paste0(prefix, "_ref_obs.csv"))
write.csv(ref_data$obs, ref_obs_path, row.names = TRUE)
cat("✓ Saved reference metadata to:\n", ref_obs_path, "\n")

# Save data$obs to CSV
data_obs_path <- file.path(output_dir, paste0(prefix, "_query_obs.csv"))
write.csv(data$obs, data_obs_path, row.names = TRUE)
cat("✓ Saved query metadata to:\n", data_obs_path, "\n")

# Run CAPYBARA analysis
cat("\n=== Running CAPYBARA QP Analysis ===\n")
start_time_analysis <- Sys.time()

single.round.QP.analysis(
  ref = ref_data$counts,
  sc.data = data$counts,
  scale.bulk.sc = "scale",
  unix.par = TRUE,
  force.eq = 0,
  n.cores = 24,
  save.to.path = output_dir,
  save.to.filename = prefix,
  bulk.norm = TRUE,
  norm.sc = TRUE,
  log.bulk = TRUE,
  log.sc = TRUE
)

end_time_analysis <- Sys.time()
cat("✓ QP analysis complete. Time taken: ", round(difftime(end_time_analysis, start_time_analysis, units = "secs"), 2), " seconds\n")
cat("Results saved to: ", file.path(output_dir, paste0(prefix, "_qp_scores.csv")), "\n")
