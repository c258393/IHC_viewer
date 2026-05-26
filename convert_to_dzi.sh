#!/usr/bin/env bash
# ============================================================================
# Convert whole-slide images to Deep Zoom (DZI) format for OpenSeadragon
# ============================================================================
# Usage:
#   ./convert_to_dzi.sh <input_image>              # Single file
#   ./convert_to_dzi.sh images/                     # All images in directory
#   ./convert_to_dzi.sh images/*.svs                # Glob pattern
#
# Prerequisites:
#   conda install -c conda-forge libvips   # or: apt install libvips-tools
#
# Output goes to dzi_tiles/ directory
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DZI_DIR="${SCRIPT_DIR}/dzi_tiles"
TILE_SIZE=254
OVERLAP=1
FORMAT="jpeg"
QUALITY=85

# Check vips
if ! command -v vips &>/dev/null; then
    echo "ERROR: 'vips' command not found."
    echo ""
    echo "Install with one of:"
    echo "  conda install -c conda-forge libvips"
    echo "  apt install libvips-tools"
    echo "  brew install vips"
    exit 1
fi

mkdir -p "$DZI_DIR"

convert_file() {
    local input="$1"
    local basename
    basename="$(basename "${input%.*}")"
    local output="${DZI_DIR}/${basename}"

    if [[ -f "${output}.dzi" ]]; then
        echo "  SKIP  ${basename} (DZI already exists)"
        return
    fi

    echo "  CONV  ${input} -> ${output}.dzi"
    vips dzsave "$input" "$output" \
        --tile-size "$TILE_SIZE" \
        --overlap "$OVERLAP" \
        --suffix ".$FORMAT[Q=$QUALITY]" \
        --depth onepixel \
        --background 255

    if [[ -f "${output}.dzi" ]]; then
        echo "  DONE  ${basename} ✓"
    else
        echo "  FAIL  ${basename} ✗"
        return 1
    fi
}

# ---- Main -------------------------------------------------------------------
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <image_file_or_directory> [...]"
    echo ""
    echo "Supported formats: SVS, TIFF, TIF, NDPI, MRXS, SCN, PNG, JPG"
    exit 0
fi

count=0
errors=0

for arg in "$@"; do
    if [[ -d "$arg" ]]; then
        # Process all images in directory
        while IFS= read -r -d '' f; do
            convert_file "$f" && count=$((count + 1)) || errors=$((errors + 1))
        done < <(find "$arg" -maxdepth 1 -type f \( \
            -iname '*.svs' -o -iname '*.tiff' -o -iname '*.tif' -o \
            -iname '*.ndpi' -o -iname '*.mrxs' -o -iname '*.scn' -o \
            -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o \
            -iname '*.bif' \) -print0 2>/dev/null)
    elif [[ -f "$arg" ]]; then
        convert_file "$arg" && count=$((count + 1)) || errors=$((errors + 1))
    else
        echo "  WARN  Not found: $arg"
        errors=$((errors + 1))
    fi
done

echo ""
echo "Converted: ${count}  Errors: ${errors}"
echo "DZI output: ${DZI_DIR}/"
