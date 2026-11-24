# lifeR

Code to generate personal maps of potential lifer birds using ebirdst and terra. See post here for overview: https://smsfrn.github.io/posts/2024/01/lifer-mapper/

The main script is [Scripts/lifer_finder.R](Scripts/lifer_finder.R). It compares your eBird life list with eBird Status & Trends occurrence models and outputs weekly maps, a low-res animated GIF and a high-res MP4 of where you could find species you haven't seen.

## Setup

### 1. System libraries (Linux / WSL)

`sf`, `terra`, `magick` and `av` compile against system libraries. On Debian or Ubuntu:

```bash
sudo apt update
sudo apt install -y \
  libgdal-dev libgeos-dev libproj-dev libudunits2-dev libsqlite3-dev \
  libmagick++-dev \
  libavfilter-dev libavcodec-dev libavformat-dev libavutil-dev libswscale-dev libavdevice-dev \
  libcurl4-openssl-dev libssl-dev libxml2-dev \
  libfontconfig1-dev libfreetype6-dev libharfbuzz-dev libfribidi-dev \
  libpng-dev libtiff5-dev libjpeg-dev
```

On Windows and macOS, CRAN provides prebuilt binaries that already include these libraries, so you can skip this step.

### 2. R packages

You need R 4.3 or newer (the code was last run on R 4.6.1). From the repo root, run:

```bash
Rscript Scripts/install_packages.R
```

The script installs:

| Package | Source | Purpose |
| --- | --- | --- |
| tidyverse, here | CRAN | Data wrangling, paths |
| ebirdst | CRAN | eBird Status & Trends downloads and rasters |
| rebird | CRAN | eBird API (taxonomy, region species lists) |
| terra, sf, tidyterra | CRAN | Raster/vector processing and plotting |
| rnaturalearth | CRAN | Country and state boundaries |
| rnaturalearthhires | [rOpenSci r-universe](https://ropensci.r-universe.dev) | High-resolution boundaries (not on CRAN) |
| magick | CRAN | Low-res animated GIF |
| av | CRAN | High-res MP4 (needs the FFmpeg libraries above) |
| mapview, ggthemes, viridisLite | CRAN | Map preview, plot theme, colors |
| raster, ggsflabel | CRAN / GitHub (`yutannihilation/ggsflabel`) | Only needed when `annotate = TRUE` |

### 3. eBird API keys

The script calls two separate eBird APIs, and each needs its own key. Keep both keys in your user-level `~/.Renviron` (outside the repo) so they never get committed:

```
EBIRDST_KEY=your_status_and_trends_key
EBIRD_KEY=your_ebird_api_key
```

- `EBIRDST_KEY`: eBird Status & Trends access key, requested at https://ebird.org/st/request. You can also set it with `ebirdst::set_ebirdst_access_key("...")`.
- `EBIRD_KEY`: eBird API 2.0 key used by `rebird`, generated at https://ebird.org/api/keygen.

Restart R after editing `~/.Renviron`. `.Renviron` is also listed in `.gitignore` in case you create one in the project.

### 4. Your life list

Download your life list from eBird (My eBird → Life List → Download (CSV)) and save it in the repo root as `ebird_world_life_list.csv`, or point `your_ebird_dat` in the script at its location. The script uses the `Common Name` and `S/P` columns.

## Running

Edit the parameters at the top of [Scripts/lifer_finder.R](Scripts/lifer_finder.R) (`region`, `user`, `resolution`, `theme`, `n_weeks` and so on), then run it from the repo root (or open `lifeR.Rproj` in RStudio and source it):

```bash
Rscript Scripts/lifer_finder.R
```

`region` takes a single eBird country or state code (for example `"US"` or `"US-NY"`) or a vector of codes (for example `c("US-AZ", "US-NM", "US-TX")`). Outputs are written to `Results/<user>/<region>/<global|regional>/<resolution>/`.

Large regions at 3km or 9km resolution need a lot of memory. Set `n_weeks` to a small number for a quick test run.

## Caching and downloads

- Status & Trends rasters are downloaded to the directory reported by `ebirdst::ebirdst_data_dir()`, outside the repo. The download step checks for local files first and skips the slow remote status check when they're already present. Set `force_download_check <- TRUE` if a previous download may have been interrupted.
- eBird API responses are cached in `Data/api_cache/` and heavy intermediate results in `Results/.../checkpoints/`. Both are gitignored and rebuilt automatically on a new machine. Set `refresh_cache <- TRUE` to recompute everything.

## What's committed

Animated maps (`Results/**/Animated_map/*.gif` and `*.mp4`) are committed. Weekly JPG frames, checkpoints, the API cache and downloaded rasters are not. Regenerate them by running the script.
