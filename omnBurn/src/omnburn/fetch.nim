## Downloading images (with curl) along with their checksum and signature
## files, including "latest" presets for popular distributions.
##
## This module only re-exports the public API. The code lives in `fetch/`:
##
## - `presets`:   the distributions known by name, and finding their current image
## - `latest`:    finding the newest release in a listing or page
## - `microsoft`: Microsoft's checksums for Windows ISOs
## - `download`:  downloading an image and its checksum and signature files
## - `web`:       curl helpers (internal)

import fetch/[download, latest, microsoft, presets, web]

export download, microsoft
export latest except listed, found
export presets except ArchUrl
export web except curl, fetchText, finalUrl, fetchJson, dirOf
