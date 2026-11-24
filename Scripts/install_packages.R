# Installs the R packages needed by Scripts/lifer_finder.R.
# Run from the repo root with:  Rscript Scripts/install_packages.R
# On Linux, install the system libraries listed in README.md first (sf, terra, magick and av compile against them).

cran <- "https://cloud.r-project.org"

cran_pkgs <- c(
  "tidyverse", "here", "ebirdst", "rebird", "terra", "sf", "rnaturalearth",
  "tidyterra", "magick", "av", "mapview", "ggthemes", "viridisLite",
  "raster", # only used when annotate = TRUE / view_sp()
  "remotes"
)

missing <- setdiff(cran_pkgs, rownames(installed.packages()))
if (length(missing) > 0) {
  install.packages(missing, repos = cran)
}

# rnaturalearthhires is not on CRAN; it is published on the rOpenSci r-universe.
if (!requireNamespace("rnaturalearthhires", quietly = TRUE)) {
  install.packages("rnaturalearthhires", repos = c("https://ropensci.r-universe.dev", cran))
}

# ggsflabel (GitHub only) is used for species labels when annotate = TRUE.
if (!requireNamespace("ggsflabel", quietly = TRUE)) {
  remotes::install_github("yutannihilation/ggsflabel")
}

all_pkgs <- c(cran_pkgs, "rnaturalearthhires", "ggsflabel")
still_missing <- all_pkgs[!vapply(all_pkgs, requireNamespace, logical(1), quietly = TRUE)]
if (length(still_missing) > 0) {
  stop("These packages failed to install: ", paste(still_missing, collapse = ", "))
}
message("All lifeR packages installed.")
