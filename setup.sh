#!/usr/bin/env bash
# ============================================================================
# IHC Image Viewer - Environment Setup Script
# ============================================================================
# Run this on a new machine to install all dependencies:
#   cd IHC_viewer && bash setup.sh
#
# Components installed:
#   1. R packages (shiny + all dependencies) via renv
#   2. System library libuv (needed by R 'fs' package)
#   3. libvips (optional, for WSI -> DZI conversion)
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }

# ---- 1. Check R is available ------------------------------------------------
echo ""
echo "========================================"
echo "  IHC Image Viewer - Setup"
echo "========================================"
echo ""

if ! command -v R &>/dev/null; then
    err "R is not installed. Please install R >= 4.0 first."
    echo "  Ubuntu/Debian: sudo apt install r-base r-base-dev"
    echo "  RHEL/CentOS:   sudo yum install R R-devel"
    echo "  Conda:         conda install -c conda-forge r-base"
    exit 1
fi

R_VERSION=$(R --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+')
log "R found: version $R_VERSION"

# ---- 2. Check/install system dependencies -----------------------------------
echo ""
echo "--- Checking system dependencies ---"

# Check if we can install system packages
CAN_SUDO=false
if command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
    CAN_SUDO=true
fi

# libuv (needed by R 'fs' package)
LIBUV_OK=false
if pkg-config --exists libuv 2>/dev/null; then
    LIBUV_OK=true
    log "libuv found (system)"
elif dpkg -l libuv1-dev 2>/dev/null | grep -q '^ii'; then
    LIBUV_OK=true
    log "libuv1-dev found"
fi

if [[ "$LIBUV_OK" == "false" ]]; then
    warn "libuv not found - will use bundled version for R 'fs' package"
    export USE_BUNDLED_LIBUV=1
    if [[ "$CAN_SUDO" == "true" ]]; then
        echo "  (Optional) Install system libuv for faster builds:"
        echo "    sudo apt install libuv1-dev    # Debian/Ubuntu"
        echo "    sudo yum install libuv-devel   # RHEL/CentOS"
    fi
fi

# libvips (optional, for WSI conversion)
if command -v vips &>/dev/null; then
    VIPS_VERSION=$(vips --version 2>/dev/null | head -1 || echo "unknown")
    log "vips found: $VIPS_VERSION"
else
    warn "vips not found (optional - needed only for SVS/TIFF -> DZI conversion)"
    echo "  Install with: conda install -c conda-forge libvips"
    echo "  Or:           sudo apt install libvips-tools"
fi

# ---- 3. Create directories --------------------------------------------------
echo ""
echo "--- Setting up directories ---"
mkdir -p images dzi_tiles
log "Created images/ and dzi_tiles/"

# ---- 4. Install R packages via renv -----------------------------------------
echo ""
echo "--- Installing R packages ---"

# Check if renv is installed
if ! R --no-save -e 'library(renv)' &>/dev/null 2>&1; then
    log "Installing renv..."
    R --no-save -e 'install.packages("renv", repos="https://cloud.r-project.org")' 2>&1 | tail -3
fi

# Restore from lockfile if it exists, otherwise install from scratch
if [[ -f "renv.lock" ]]; then
    log "Restoring R packages from renv.lock..."
    R --no-save -e '
        Sys.setenv(USE_BUNDLED_LIBUV = "1")
        renv::restore()
    ' 2>&1 | grep -E "^(✔|✖|-|The|#|Error|Warning)" | head -40
else
    warn "No renv.lock found - installing shiny from scratch..."
    R --no-save -e '
        Sys.setenv(USE_BUNDLED_LIBUV = "1")
        renv::init(bare = TRUE)
        renv::install("shiny")
        renv::snapshot()
    ' 2>&1 | grep -E "^(✔|✖|-|The|#|Error|Warning)" | head -40
fi

# Verify shiny loads
if R --no-save -e 'library(shiny); cat("shiny OK\n")' 2>/dev/null | grep -q "shiny OK"; then
    log "R shiny package verified"
else
    err "shiny package failed to load. Check errors above."
    exit 1
fi

# ---- 5. Summary -------------------------------------------------------------
echo ""
echo "========================================"
echo "  Setup complete!"
echo "========================================"
echo ""
echo "  To run the app:"
echo "    cd $SCRIPT_DIR"
echo "    Rscript -e 'shiny::runApp(\".\", port=3838, host=\"0.0.0.0\")'"
echo ""
echo "  To convert WSI images to DZI (requires vips):"
echo "    ./convert_to_dzi.sh images/"
echo ""
