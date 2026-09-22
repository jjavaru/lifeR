Code to generate personal maps of potential lifer birds using ebirdst and terra. See post here for overview: https://smsfrn.github.io/posts/2024/01/lifer-mapper/

## Usage notes

This script uses the eBird Status and Trends API, and requires an API key. This key is separate from other eBird API keys and can be requested here: https://ebird.org/st/request

The download step checks the local eBird Status and Trends files first and skips the slow remote status check when the required files are already present. Set `force_download_check <- TRUE` in the script if a previous download may have been interrupted.

Weekly JPG maps are also combined into a low-resolution GIF. The high-resolution animation is encoded as an MP4 using the R `av` package. On Debian or Ubuntu, install the FFmpeg development libraries before installing `av`:

```bash
sudo apt install libavfilter-dev libavcodec-dev libavformat-dev libavutil-dev libswscale-dev libavdevice-dev
Rscript -e 'install.packages("av", repos="https://cloud.r-project.org")'
```
