# IHC Image Viewer

R Shiny application for viewing IHC (immunohistochemistry) images using [OpenSeadragon](https://openseadragon.github.io/).

## Quick Start

```bash
cd /fsx/home/c258393/Project/IHC

# Place images in the images/ directory
cp /path/to/your/images/*.{png,jpg,svs,tiff} images/

# Run the app
Rscript -e 'shiny::runApp(".", port = 3838, host = "0.0.0.0")'
```

Then open `http://localhost:3838` in your browser.

## Supported Image Formats

| Format | Type | Direct View | Notes |
|--------|------|-------------|-------|
| PNG, JPG, GIF, BMP, WEBP | Standard | ✅ Yes | Loaded directly via Simple Image mode |
| SVS (Aperio) | WSI | ❌ Needs DZI | Convert first with `vips` |
| TIFF / TIF | WSI | ❌ Needs DZI | Convert first with `vips` |
| NDPI (Hamamatsu) | WSI | ❌ Needs DZI | Convert first with `vips` |
| MRXS (3DHistech) | WSI | ❌ Needs DZI | Convert first with `vips` |

## Converting Whole-Slide Images to DZI

Large WSI files (.svs, .tiff, .ndpi) must be converted to Deep Zoom Image (DZI) format before viewing. DZI creates a pyramid of tiled images that OpenSeadragon can load efficiently.

### Install vips

```bash
# Option 1: Conda (recommended)
conda install -c conda-forge libvips

# Option 2: System package
sudo apt install libvips-tools    # Debian/Ubuntu
brew install vips                  # macOS
```

### Convert images

```bash
# Single file
./convert_to_dzi.sh images/slide001.svs

# All images in directory
./convert_to_dzi.sh images/

# Or manually with vips
vips dzsave images/slide001.svs dzi_tiles/slide001 --tile-size 254 --overlap 1
```

Converted tiles are saved to `dzi_tiles/`. The app auto-detects DZI availability.

## Directory Structure

```
Project/IHC/
├── app.R                # Shiny application
├── convert_to_dzi.sh    # DZI conversion helper
├── README.md            # This file
├── images/              # Place source images here
└── dzi_tiles/           # Auto-generated DZI tiles
    ├── slide001.dzi
    └── slide001_files/
        ├── 0/
        ├── 1/
        └── .../
```

## Features

- **OpenSeadragon viewer**: Smooth zoom/pan with mouse wheel, click, touch gestures
- **Multi-format support**: Standard images viewed directly; WSI via DZI tiles
- **File browser sidebar**: Lists images with format badges (DZI, PNG, SVS, etc.)
- **Image metadata**: File size, format, modification date, DZI status
- **Navigator mini-map**: Bottom-right overview for spatial orientation
- **Rotation control**: Rotate the view for different orientations
- **Zoom up to 40x**: Deep zoom into cellular details
- **Large file warning**: Alerts when loading images >100 MB directly

## Deployment on Posit Connect

```bash
# Install rsconnect if needed
R -e 'install.packages("rsconnect")'

# Deploy
R -e 'rsconnect::deployApp(".", appTitle = "IHC Image Viewer")'
```

Ensure the image directory path is accessible from the Posit Connect server.

## Requirements

- R ≥ 4.0
- `shiny` package
- Modern web browser (Chrome, Firefox, Edge)
- `vips` command-line tool (for WSI → DZI conversion)
