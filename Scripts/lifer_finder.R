# Using eBird Status & Trends products to map cumulative potential lifers. Note that running this for a big region (like the whole US) or for many species requires *lots* of working memory.

# Load packages
library(tidyverse)
library(here)
library(ebirdst)
library(rebird)
library(terra)
library(sf)
library(rnaturalearth)
library(rnaturalearthhires)
library(tidyterra)
library(magick)

central_america <- c("MX", "BZ", "GT", "SV", "HN", "NI", "CR", "PA")
southwest_us <- c("US-AZ", "US-NM", "US-TX")

# Set parameters
region <- "US" # eBird country or state-level regional code(s), e.g. "US", "US-NY", or a vector such as central_america or southwest_us above. Note that "US" is by default modified to only include continental US.
user <- "Jon Javaruski" # e.g., "Sam Safran" - this is typically your full name or username. Controls how you are identified in the map caption and is used in output file structure, so can't be empty.
user_short <- "Jon" # e.g., "Sam" - optional to customize name in legend. Typically a first name. Leave this defined as NA and it will read "My potential lifers." Haven't figured out how to center name over legend for longer names, so this may not look great.
your_ebird_dat <- here("ebird_world_life_list.csv") # path to where your personal eBird data are stored
needs_list_to_use <- "global" # set to "global" if you want to map true lifers (species you haven't observed anywhere); set to "regional" if you'd like to map needs for the specified region.
resolution <- "9km" # "3km", "9km", or "27km"
annotate <- FALSE # If set to TRUE, needed species are labeled on the map at the location where they have the highest abundance each week. This makes the animated map look pretty bad (so it gets output at a much slower frame rate to compensate), but may be of interest to some. the "dark" color theme works best for this.
sp_annotation_threshold <- 0.01 # this controls how many species get annotated on the map if annotate is set to TRUE. A species will only be annotated if the grid cell where it is most abundant contains more than the set proportion of the total population. Lower values mean more species get annotated (though the marked locations will hold smaller and smaller percentages of the total population, which may make for some odd placements for widely dispersed species). Set to 0 to annotate all needed species. A value of 0.01 seems to keep things under control if there are many needed species. Note that this is different from the possible_occurrence_threshold, which sets the occurrence probability a species must exceed in a cell to be counted as a potential lifer.
theme <- "light_blue" # accepted values "light_blue", "dark", "light_green"
refresh_cache <- FALSE # set to TRUE to ignore any saved caches/checkpoints below and re-hit the eBird API / recompute everything from scratch.
n_weeks <- 52 # number of weeks (1-52, starting from week 1) to process. Set to 52 for the full year/animated map. Lower values drastically cut memory use since rasters are subset to these weeks before the expensive crop/mask/summarize steps.
force_download_check <- FALSE
download_abundance <- FALSE # set to TRUE only if abundance rasters are needed; this map uses occurrence rasters.

region_id <- paste(region, collapse = "_")

# Make directories to save outputs
user_file <- tolower(str_replace(user, " ", ""))
mainDir <- here("Results")
dir.create(file.path(mainDir, user_file, region_id, needs_list_to_use, resolution), recursive = TRUE, showWarnings = TRUE)
outputDir <- here("Results", user_file, region_id, needs_list_to_use, resolution)
subdirectories <- c("Weekly_maps", "Animated_map")
lapply(file.path(mainDir, user_file, region_id, needs_list_to_use, resolution, subdirectories), function(x) if (!dir.exists(x)) dir.create(x))

# Cache directories: api_cache holds API responses shared across runs (taxonomy/region species lists);
# checkpoint_dir holds heavier, run-specific intermediate results (species-to-process list, cropped rasters,
# weekly summaries) so that a re-run can resume instead of re-downloading/re-computing everything.
api_cache_dir <- here("Data", "api_cache")
checkpoint_dir <- file.path(outputDir, "checkpoints")
dir.create(api_cache_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(checkpoint_dir, recursive = TRUE, showWarnings = FALSE)

# Generic on-disk cache: runs `compute()` only if the cache file doesn't exist yet (or refresh_cache is TRUE),
# otherwise loads the previously saved result. Used to avoid re-hitting the eBird API / redoing heavy work on rerun.
with_cache <- function(path, compute, refresh = refresh_cache) {
  if (!refresh && file.exists(path)) {
    message("Using cached result: ", path)
    return(readRDS(path))
  }
  result <- compute()
  saveRDS(result, path)
  result
}

# Same idea as with_cache(), but for lists of terra SpatRasters, which need wrap()/unwrap() to serialize.
with_raster_cache <- function(path, compute, refresh = refresh_cache) {
  if (!refresh && file.exists(path)) {
    message("Using cached rasters: ", path)
    return(lapply(readRDS(path), terra::unwrap))
  }
  result <- compute()
  saveRDS(lapply(result, terra::wrap), path)
  result
}

# Save region info in df for later use
region_info <- tibble(
  region = region,
  country = sub("-.*$", "", region),
  state = if_else(str_detect(region, "-"), sub("^[^-]*-", "", region), NA_character_)
)

# Get full eBird taxonomy (cached globally since it doesn't depend on region/user)
sp_all <- with_cache(file.path(api_cache_dir, "ebird_taxonomy.rds"), function() {
  rebird::ebirdtaxonomy("species") %>%
    rename(Common.Name = comName)
})

# User global life list
sp_user_all <- read.csv(your_ebird_dat) %>%
  select(Common.Name) %>%
  unique() %>%
  left_join(sp_all) %>%
  filter(category == "species")

# User regional list
sp_user_region <- read.csv(your_ebird_dat) %>%
  separate(S.P, into = c("country", "state"), sep = "-", remove = FALSE) %>%
  filter(country %in% region_info$country)

if (any(!is.na(region_info$state))) {
  sp_user_region <- filter(sp_user_region, S.P %in% region)
}

sp_user_region <- sp_user_region %>%
  select(Common.Name) %>%
  unique() %>%
  left_join(sp_all) %>%
  filter(category == "species")

# All species observed in region (by anyone) - cached per region
sp_region <- with_cache(file.path(api_cache_dir, paste0("region_species_", region_id, ".rds")), function() {
  map_dfr(region, ebirdregionspecies) %>%
    distinct(speciesCode) %>%
    left_join(sp_all, by = c("speciesCode" = "speciesCode")) %>%
    drop_na(Common.Name)
})

# User needs in region
if (needs_list_to_use == "global") {
  sp_needed <- setdiff(sp_region$Common.Name, sp_user_all$Common.Name) %>%
    as.data.frame() %>%
    rename(Common.Name = ".") %>%
    left_join(sp_all)
}

if (needs_list_to_use == "regional") {
  sp_needed <- setdiff(sp_region$Common.Name, sp_user_region$Common.Name) %>%
    as.data.frame() %>%
    rename(Common.Name = ".") %>%
    left_join(sp_all)
}

# All species with ebst data
sp_ebst <- ebirdst_runs %>%
  rename(Common.Name = common_name)

# All needed species with ebst data (checkpointed - depends on user's life list/region/needs settings)
sp_ebst_for_run <- with_cache(file.path(checkpoint_dir, "sp_ebst_for_run.rds"), function() {
  inner_join(sp_ebst, sp_needed) %>%
    filter(!species_code %in% c("laugul", "yebsap-example")) # not sure why Laughing Gull is tossing an error
})

# Download occurrence data for needed sp. If annotating we also need species population proportion rasters.
# ebirdst_download_status() itself skips files that are already on disk, but it still makes a slow remote
# API call per species just to check - with hundreds of species this check alone can take a long time.
# force_download_check <- TRUE bypasses the local-file shortcut below and always hits the API, e.g. if a
# previous download was interrupted and you're not sure what's actually complete on disk.
ebirdst_version_year <- ebirdst_version()[["status_version_year"]]

# TRUE if the files needed for sp_code at `resolution` (and, if annotating, the proportion-population
# layer too) already exist locally, so the slow API check can be skipped for that species.
species_files_present <- function(sp_code) {
  sp_dir <- file.path(ebirdst_data_dir(), ebirdst_version_year, sp_code, "weekly")
  occ_file <- file.path(sp_dir, paste0(sp_code, "_occurrence_median_", resolution, "_", ebirdst_version_year, ".tif"))
  if (!file.exists(occ_file)) {
    return(FALSE)
  }
  if (annotate == TRUE) {
    prop_file <- file.path(sp_dir, paste0(sp_code, "_proportion-population_median_", resolution, "_", ebirdst_version_year, ".tif"))
    if (!file.exists(prop_file)) {
      return(FALSE)
    }
  }
  if (download_abundance) {
    abundance_file <- file.path(sp_dir, paste0(sp_code, "_abundance_median_", resolution, "_", ebirdst_version_year, ".tif"))
    if (!file.exists(abundance_file)) {
      return(FALSE)
    }
  }
  TRUE
}

n_species_to_download <- nrow(sp_ebst_for_run)
for (i in seq_len(n_species_to_download)) {
  sp_code <- sp_ebst_for_run$species_code[i]
  if (!force_download_check && species_files_present(sp_code)) {
    message(sprintf("[%d/%d] Already downloaded, skipping check for %s", i, n_species_to_download, sp_code))
    next
  }
  message(sprintf("[%d/%d] Ensuring data downloaded for %s", i, n_species_to_download, sp_code))
  ebirdst_download_status(sp_code,
    download_abundance = download_abundance, download_occurrence = TRUE,
    pattern =
      if (annotate == TRUE) {
        paste0("occurrence_median_", resolution, "|", "proportion-population_median_", resolution)
      } else {
        paste0("occurrence_median_", resolution)
      }
  )
}

# Define occurrence threshold for when a species is "possible"
possible_occurrence_threshold <- 0.01 # minimum occurrence probability for a species to be considered "possible" at a given time/location.
# Everything below turns the downloaded per-species rasters into weekly counts of possible lifers per cell.
# Species are processed one at a time: each species' raster is read, cropped to the study area, thresholded and
# added into a running per-cell, per-week count, then discarded. Peak memory is one species plus the count grid,
# however many species are needed (holding every species at once took >10 GB for the continental US at 27km).
# The result is checkpointed so reruns skip this loop.

# Study area polygons (country/state outlines) used for masking and for the map borders
if (length(region) > 1) {
  country_regions <- region_info %>% filter(is.na(state))
  state_regions <- region_info %>% filter(!is.na(state))
  study_area <- list()
  if (nrow(country_regions) > 0) {
    # iso_a2_eh rather than iso_a2: Natural Earth sets iso_a2 to "-99" for a few countries (e.g. France, Norway)
    # scale = "large" (1:10m, from rnaturalearthhires) matches the detail of ne_states(); the default 1:110m
    # outlines drop small islands and straighten coastlines, which also changes which cells get masked.
    countries <- ne_countries(scale = "large", returnclass = "sf") %>%
      filter(iso_a2_eh %in% country_regions$country) %>%
      # A code can also match small dependencies (e.g. FR matches Clipperton I. in the Pacific), which would
      # stretch the crop extent; use them only when the code has no main country row (e.g. PR, Puerto Rico).
      group_by(iso_a2_eh) %>%
      filter(type != "Dependency" | all(type == "Dependency")) %>%
      ungroup()
    missing_countries <- setdiff(country_regions$country, countries$iso_a2_eh)
    if (length(missing_countries) > 0) {
      stop("No Natural Earth country outline found for: ", paste(missing_countries, collapse = ", "))
    }
    study_area[["countries"]] <- st_sf(geometry = st_geometry(countries))
  }
  if (nrow(state_regions) > 0) {
    states <- ne_states(iso_a2 = unique(state_regions$country), returnclass = "sf") %>%
      filter(iso_3166_2 %in% state_regions$region)
    study_area[["states"]] <- st_sf(geometry = st_geometry(states))
  }
  study_area <- do.call(rbind, unname(study_area))
} else {
  study_area <- ne_states(iso_a2 = region_info$country, returnclass = "sf")
  if (!is.na(region_info$state)) {
    study_area <- study_area %>% filter(iso_3166_2 == .env$region)
  }
  if (!region %in% c("US-HI", "US-AK")) {
    study_area <- filter(study_area, !iso_3166_2 %in% c("US-HI", "US-AK"))
  } # if region is US only mapping continental US
}

# Loads a species' weekly raster, keeping only the first n_weeks layers
load_weekly <- function(sp_code, product = "occurrence") {
  r <- load_raster(sp_code, product = product, period = "weekly", metric = "median", resolution = resolution)
  terra::subset(r, 1:n_weeks)
}

lifer_counts_path <- file.path(checkpoint_dir, paste0("lifer_counts_", n_weeks, "wk.rds"))
if (!refresh_cache && file.exists(lifer_counts_path)) {
  message("Using cached lifer counts: ", lifer_counts_path)
  cached <- readRDS(lifer_counts_path)
  lifer_counts <- terra::unwrap(cached$lifer_counts)
  sp_ebst_for_run_in_region <- cached$sp_ebst_for_run_in_region
  study_area <- cached$study_area
  week_names <- cached$week_names
  if (annotate == TRUE) polys <- cached$polys
} else {
  sp_codes <- sp_ebst_for_run$species_code

  # The first species defines the cropped grid that every other species is checked against
  first_sp <- load_weekly(sp_codes[1])
  study_area <- st_transform(study_area, st_crs(first_sp))
  mapview::mapview(study_area)
  study_vect <- terra::vect(study_area)
  template <- terra::crop(first_sp, study_vect)
  week_names <- names(template)
  rm(first_sp)

  # Cells of the cropped grid inside the study area polygons (the same cells terra::mask keeps). Only these
  # cells are counted; everything outside ends up NA, as masking each species did before.
  in_area <- which(!is.na(terra::values(terra::mask(terra::init(template[[1]], 1), study_vect), mat = FALSE)))

  # counts: number of species above the occurrence threshold per cell and week.
  # has_data: whether any counted species had a non-NA value there, so cells with no data at all stay NA
  # (transparent on the map) instead of showing as 0.
  counts <- matrix(0L, nrow = length(in_area), ncol = n_weeks)
  has_data <- matrix(FALSE, nrow = length(in_area), ncol = n_weeks)
  sp_max <- setNames(rep(NA_real_, length(sp_codes)), sp_codes)
  polys <- list()

  for (s in seq_along(sp_codes)) {
    sp_code <- sp_codes[s]
    if (s %% 25 == 0 || s == length(sp_codes)) message(sprintf("Counting species %d/%d", s, length(sp_codes)))
    occ <- if (s == 1) template else terra::crop(load_weekly(sp_code), study_vect)
    if (!terra::compareGeom(occ, template, lyrs = TRUE, stopOnError = FALSE)) {
      stop("Raster grid for ", sp_code, " does not match the other species")
    }
    vals <- terra::values(occ, mat = TRUE)[in_area, , drop = FALSE]
    sp_max[s] <- suppressWarnings(max(vals, na.rm = TRUE))

    # Species that never reach the threshold anywhere in the study area are skipped, as before
    if (!is.finite(sp_max[s]) || sp_max[s] <= possible_occurrence_threshold) next
    known <- !is.na(vals)
    has_data <- has_data | known
    counts <- counts + (known & vals > possible_occurrence_threshold)

    # For annotations: the cell with the highest share of the population, for each week
    if (annotate == TRUE) {
      prop <- terra::mask(terra::crop(load_weekly(sp_code, "proportion-population"), study_vect), study_vect)
      if (isTRUE(max(terra::values(prop), na.rm = TRUE) > possible_occurrence_threshold)) {
        max_val_cells <- where.max(prop, values = TRUE, list = FALSE) %>%
          as.data.frame() %>%
          filter(value > 0)
        max_val_coords <- xyFromCell(prop, max_val_cells[, 2])
        polys[[sp_code]] <- st_as_sf(max_val_coords %>% as.data.frame(), coords = c(1, 2), crs = crs(prop)) %>%
          mutate(
            week = max_val_cells[, 1],
            sp = sp_code,
            max_weekly_proportion = max_val_cells[, 3]
          )
      }
      rm(prop)
    }
    rm(occ, vals, known)
    if (s %% 25 == 0) gc()
  }

  # Turn the count matrix back into a raster on the cropped grid
  counts[!has_data] <- NA
  count_vals <- matrix(NA_integer_, nrow = terra::ncell(template), ncol = n_weeks)
  count_vals[in_area, ] <- counts
  lifer_counts <- terra::rast(template, nlyrs = n_weeks)
  terra::values(lifer_counts) <- count_vals
  names(lifer_counts) <- week_names
  rm(counts, has_data, count_vals, template)
  gc()

  # Species meeting the occurrence threshold somewhere in the study area
  sp_ebst_for_run_in_region <- tibble(species_code = names(sp_max), max_val = unname(sp_max)) %>%
    filter(is.finite(max_val), max_val > possible_occurrence_threshold) %>%
    left_join(sp_ebst_for_run, by = "species_code")

  if (annotate == TRUE) {
    polys <- do.call("rbind", unname(polys)) %>%
      left_join(sp_ebst_for_run_in_region, by = c("sp" = "species_code"))
    polys <- st_filter(polys, study_area)
  }

  saveRDS(
    list(
      lifer_counts = terra::wrap(lifer_counts),
      sp_ebst_for_run_in_region = sp_ebst_for_run_in_region,
      study_area = study_area,
      week_names = week_names,
      polys = if (annotate == TRUE) polys else NULL
    ),
    lifer_counts_path
  )
}
message(sprintf("%d of %d needed species reach the occurrence threshold in the study area", nrow(sp_ebst_for_run_in_region), nrow(sp_ebst_for_run)))

# Function for viewing a species' maximum occurrence across the year (not run)
view_sp <- function(x) {
  sp_max_occ <- max(terra::crop(load_weekly(x), terra::vect(study_area)))
  mapview::mapview(raster::raster(sp_max_occ))
}
# view_sp("casspa")

# Reproject, mask, and trim each week's lifer count raster for plotting. Checkpointed separately.
possible_lifers <- with_raster_cache(file.path(checkpoint_dir, paste0("possible_lifers_", n_weeks, "wk.rds")), function() {
  study_vect_5070 <- project(vect(study_area), y = "epsg:5070")
  lapply(seq_len(n_weeks), function(i) {
    week <- terra::project(lifer_counts[[i]], y = "epsg:5070", method = "near")
    week <- terra::mask(week, mask = study_vect_5070)
    trim(week)
  })
})

# Generate weekly maps
# Set theme colors
if (theme == "light_blue") {
  bg_color <- "azure2"
  font_color_light <- "grey50"
  font_color_dark <- "grey20"
}
if (theme == "light_green") {
  bg_color <- "#EBF5DF"
  font_color_light <- "#9CC185"
  font_color_dark <- "#141B0E"
}
if (theme == "dark") {
  bg_color <- viridisLite::turbo(1)
  font_color_light <- "white"
  font_color_dark <- "grey90"
}

# Get maximum lifer count (across all cells and weeks). Needed for legend.
max_val_possible <- lapply(possible_lifers, minmax) %>%
  sapply(max) %>%
  max()

# Get legend breaks/labels/range based on maximum count.
legend_breaks <- c(pretty(1:max_val_possible))
labels <- function(x) {
  lab <- " species"
  chars <- nchar(paste0(tail(x, n = 1), lab))
  x_last <- as.character(paste0(tail(x, n = 1), lab))
  x_last_pad <- str_pad(x_last, nchar(x_last) * 2 + nchar(tail(x, n = 1)) + 1, side = "left")
  c(x[1:(length(x) - 1)], x_last_pad)
}
legend_labels <- labels(legend_breaks)
legend_breaks_last <- last(legend_breaks)

# Generate and save map for each week.
for (i in 1:length(possible_lifers)) {
  date <- week_names[i]
  if (needs_list_to_use == "global") {
    legend_lab <- paste0(ifelse(is.na(user_short), paste0("My"), paste0(user_short, "'s")), " potential lifers")
  }
  if (needs_list_to_use == "regional") {
    legend_lab <- paste0(ifelse(is.na(user_short), paste0("My"), paste0(user_short, "'s")), " regional needs")
  }
  week_plot <- ggplot() +
    geom_spatraster(data = possible_lifers[[i]]) +
    geom_sf(data = study_area, fill = NA, color = alpha("white", .3)) +

    # Add annotation if option is turned on
    {
      if (annotate == TRUE) {
        ggsflabel::geom_sf_text_repel(
          data = polys %>% filter(week == i & max_weekly_proportion > sp_annotation_threshold),
          aes(label = Common.Name),
          nudge_x = 4, nudge_y = 8, seed = 10,
          color = "white", size = 2.5, alpha = .8)
      }
    } +
    {
      if (annotate == TRUE) {
        geom_sf(
          data = polys %>% filter(week == i & max_weekly_proportion > sp_annotation_threshold),
          color = "white", shape = 1, size = 1.5)
      }
    } +
    scale_fill_viridis_c(
      limits = c(0, legend_breaks_last), na.value = "transparent", option = "turbo",
      guide = guide_colorbar(title.position = "top", title.hjust = .5),
      breaks = legend_breaks,
      labels = legend_labels
    ) +
    labs(
      title = "Lifer finder: mapping the birds you've yet to meet",
      tag = paste0(format(ymd(date), format = "%b-%d")),
      # subtitle = "Mapping the birds you've yet to meet",
      fill = legend_lab,
      caption = paste0("Lifers mapped for: ", user, ". \nLifer analysis and map by Sam Safran.\nA candidate lifer is considered `possible` if the species has a >", round(possible_occurrence_threshold * 100, 0), "% modeled occurrence probability at the location and date.\n
Data from 2023 eBird Status & Trends products (https://ebird.org/science/status-and-trends): Fink, D., T. Auer, A. Johnston, M. Strimas-Mackey, S. Ligocki, O. Robinson,\n W. Hochachka, L. Jaromczyk, C. Crowley, K. Dunham, A. Stillman, C. Davis, M. Stokowski, P. Sharma, V. Pantoja, D. Burgin, P. Crowe, M. Bell, S. Ray, I. Davies,\nV. Ruiz-Gutierrez, C. Wood, A. Rodewald. 2024. eBird Status and Trends, Data Version: 2023; Released: 2025. Cornell Lab of Ornithology, Ithaca, New York.\nhttps://doi.org/10.2173/WZTW8903. This material uses data from the eBird Status and Trends Project at the Cornell Lab of Ornithology, eBird.org.\nAny opinions, findings, and conclusions or recommendations expressed in this material are those of the author(s) and do not necessarily reflect the views of the\nCornell Lab of Ornithology.")
    ) +
    ggthemes::theme_fivethirtyeight() +
    theme(
      rect = element_rect(linetype = 1, colour = NA),
      plot.title = element_text(
        size = 10, hjust = 0, face = "plain", color = font_color_light,
        margin = margin(0, 0, 15, 0)
      ),
      plot.tag = element_text(size = 10, face = "bold", color = font_color_dark),
      axis.title.y = element_blank(),
      axis.title.x = element_blank(),
      axis.text.x = element_blank(),
      axis.text.y = element_blank(),
      plot.caption = element_text(size = 5, hjust = 0, color = font_color_light),
      plot.background = element_rect(fill = bg_color),
      panel.background = element_rect(fill = bg_color),
      panel.grid.major = element_blank(),
      panel.grid.minor = element_blank(),
      panel.border = element_blank(),
      legend.title = element_text(size = 10, face = "bold", color = font_color_dark),
      legend.text = element_text(color = font_color_dark),
      legend.title.align = 1,
      legend.direction = "horizontal",
      legend.key.width = unit(.32, "inch"),
      legend.key.height = unit(.06, "inch"),
      legend.position = c(.768, 1.03),
      plot.tag.position = c(0.05, .94),
      legend.background = element_rect(colour = NA, fill = NA, linetype = "solid"),
      legend.text.align = 0.5
    )
  week_plot
  ggsave(filename = here(outputDir, "Weekly_maps", paste0(region_id, "_", date, ".jpg")), plot = week_plot, bg = "white", height = 5.35, width = 6.6)
}

# Generate a low-resolution GIF and a high-resolution MP4.
# The MP4 is encoded directly from the JPG sequence so frames do not all need to live in magick memory.
imgs <- list.files(here(outputDir, "Weekly_maps"), full.names = T)

lores_frames <- image_join(lapply(imgs, function(f) image_scale(image_read(f), geometry_size_percent(width = 38, height = NULL))))
if (annotate == TRUE) {img_animated_lores <- image_animate(lores_frames, fps = .5)}
if (annotate == FALSE) {img_animated_lores <- image_animate(lores_frames, fps = 5)}
if (annotate == TRUE) {image_path_lores <- here(outputDir, "Animated_map", paste0(region_id, "_Animated_map_annual_", theme, "_lores_annotated_", user_file, ".gif"))}
if (annotate == FALSE) {image_path_lores <- here(outputDir, "Animated_map", paste0(region_id, "_Animated_map_annual_", theme, "_lores_", user_file, ".gif"))}
image_write(image = img_animated_lores, path = image_path_lores)
rm(lores_frames, img_animated_lores)
gc()

if (!requireNamespace("av", quietly = TRUE)) {
  stop("The av package is required to create the hi-res MP4. On Debian/Ubuntu install libavfilter-dev, libavcodec-dev, libavformat-dev, libavutil-dev, libswscale-dev, and libavdevice-dev, then run install.packages('av').")
}
if (annotate == TRUE) {image_path <- here(outputDir, "Animated_map", paste0(region_id, "_Animated_map_annual_", theme, "_hires_annotated_", user_file, ".mp4"))}
if (annotate == FALSE) {image_path <- here(outputDir, "Animated_map", paste0(region_id, "_Animated_map_annual_", theme, "_hires_", user_file, ".mp4"))}
if (annotate == TRUE) {fps <- .5}
if (annotate == FALSE) {fps <- 5}
av::av_encode_video(
  input = imgs, output = image_path, framerate = fps,
  vfilter = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
)
