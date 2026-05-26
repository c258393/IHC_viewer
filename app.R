library(shiny)

# ============================================================================
# IHC Image Viewer - Shiny Application with OpenSeadragon
# ============================================================================
# Supports:
#   - Standard images (PNG, JPG, GIF, BMP, WEBP) via Simple Image mode
#   - Pre-generated DZI tiles for whole-slide images (SVS, TIFF, NDPI)
#   - Configurable image directory
# ============================================================================

# ---- Configuration ---------------------------------------------------------
DEFAULT_IMAGE_DIR <- normalizePath("images", mustWork = FALSE)
DEFAULT_DZI_DIR   <- normalizePath("dzi_tiles", mustWork = FALSE)

SIMPLE_FORMATS <- c("png", "jpg", "jpeg", "gif", "bmp", "webp")
WSI_FORMATS    <- c("svs", "tiff", "tif", "ndpi", "mrxs", "scn", "bif")

get_ext <- function(f) tolower(tools::file_ext(f))

format_size <- function(bytes) {
  if (bytes >= 1024^3) return(sprintf("%.1f GB", bytes / 1024^3))
  if (bytes >= 1024^2) return(sprintf("%.1f MB", bytes / 1024^2))
  if (bytes >= 1024)   return(sprintf("%.1f KB", bytes / 1024))
  paste0(bytes, " B")
}

# Validate that a path is within the allowed directory (prevent traversal)
safe_path <- function(base_dir, filename) {
  clean_name <- basename(filename)
  full_path <- normalizePath(file.path(base_dir, clean_name), mustWork = FALSE)
  if (!startsWith(full_path, normalizePath(base_dir, mustWork = FALSE))) {
    return(NULL)
  }
  full_path
}

# ---- UI ---------------------------------------------------------------------
ui <- htmlTemplate(
  "template.html",
  dir_input = textInput("image_dir", NULL, value = DEFAULT_IMAGE_DIR,
                         width = "100%", placeholder = "Path to image directory"),
  refresh_btn = actionButton("refresh_btn", "\u21bb Refresh",
                              class = "btn-refresh"),
  file_list_ui = uiOutput("file_list_ui"),
  metadata_ui  = uiOutput("metadata_ui")
)

# ---- Server -----------------------------------------------------------------
server <- function(input, output, session) {

  rv <- reactiveValues(
    files       = character(0),
    selected    = NULL,
    current_dir = DEFAULT_IMAGE_DIR
  )

  # Ensure default dirs exist
  dir.create(DEFAULT_IMAGE_DIR, showWarnings = FALSE, recursive = TRUE)
  dir.create(DEFAULT_DZI_DIR,   showWarnings = FALSE, recursive = TRUE)

  # Serve DZI tiles directory
  addResourcePath("dzi", DEFAULT_DZI_DIR)

  # ---------- Scan images ----------
  scan_images <- function(dir) {
    if (is.null(dir) || !dir.exists(dir)) return(character(0))
    all_ext <- c(SIMPLE_FORMATS, WSI_FORMATS)
    pattern <- paste0("\\.(", paste(all_ext, collapse = "|"), ")$")
    files <- list.files(dir, pattern = pattern, ignore.case = TRUE,
                        full.names = FALSE, recursive = FALSE)
    sort(files)
  }

  # ---------- Refresh file list ----------
  observeEvent(c(input$refresh_btn, input$image_dir), {
    dir <- input$image_dir
    if (!is.null(dir) && nzchar(dir) && dir.exists(dir)) {
      rv$current_dir <- normalizePath(dir)
      addResourcePath("images", rv$current_dir)
      rv$files <- scan_images(rv$current_dir)
      rv$selected <- NULL
    } else {
      rv$files <- character(0)
    }
  }, ignoreInit = FALSE, ignoreNULL = TRUE)

  # ---------- File list UI ----------
  output$file_list_ui <- renderUI({
    files <- rv$files

    if (length(files) == 0) {
      return(div(style = "padding: 30px; text-align: center; color: #585b70;",
                 p("No images found"),
                 p(style = "font-size: 12px;",
                   "Place image files in the directory above,",
                   "then click Refresh.")))
    }

    items <- lapply(files, function(f) {
      ext <- get_ext(f)
      is_simple <- ext %in% SIMPLE_FORMATS
      is_wsi    <- ext %in% WSI_FORMATS
      base      <- tools::file_path_sans_ext(f)
      has_dzi   <- file.exists(file.path(DEFAULT_DZI_DIR, paste0(base, ".dzi")))

      badge_class <- if (has_dzi) {
        "badge badge-dzi"
      } else if (is_simple) {
        "badge badge-simple"
      } else {
        "badge badge-wsi"
      }
      badge_text <- if (has_dzi) "DZI" else toupper(ext)

      sel <- if (!is.null(rv$selected) && rv$selected == f) " selected" else ""

      tags$div(class = paste0("img-item", sel),
               `data-file` = f,
               tags$span(class = "name", f),
               tags$span(class = badge_class, badge_text))
    })

    tagList(items)
  })

  # Update file count
  observe({
    n <- length(rv$files)
    session$sendCustomMessage("updateFileCount",
      list(text = sprintf("%d image(s)", n)))
  })

  # ---------- Image selection ----------
  observeEvent(input$select_image, {
    f <- input$select_image
    # Validate filename (security: no path separators)
    if (grepl("[/\\\\]", f)) {
      session$sendCustomMessage("showToast",
        list(text = "Invalid filename", type = "", duration = 3000))
      return()
    }

    full_path <- safe_path(rv$current_dir, f)
    if (is.null(full_path) || !file.exists(full_path)) {
      session$sendCustomMessage("showToast",
        list(text = "File not found", type = "", duration = 3000))
      return()
    }

    rv$selected <- f
    ext  <- get_ext(f)
    base <- tools::file_path_sans_ext(f)
    is_simple <- ext %in% SIMPLE_FORMATS
    dzi_file  <- file.path(DEFAULT_DZI_DIR, paste0(base, ".dzi"))
    has_dzi   <- file.exists(dzi_file)

    if (has_dzi) {
      session$sendCustomMessage("loadImage", list(
        type = "dzi",
        url  = paste0("dzi/", base, ".dzi"),
        name = f
      ))
    } else if (is_simple) {
      fsize <- file.info(full_path)$size
      if (fsize > 100 * 1024^2) {
        session$sendCustomMessage("showToast", list(
          text = paste0("Large file (", format_size(fsize),
                        ") - loading may be slow. Consider DZI conversion."),
          type = "warning", duration = 5000
        ))
      }
      session$sendCustomMessage("loadImage", list(
        type = "simple",
        url  = paste0("images/", f),
        name = f
      ))
    } else {
      # WSI without DZI conversion
      session$sendCustomMessage("clearViewer", list())
      session$sendCustomMessage("showToast", list(
        text = paste0(toupper(ext), " files require DZI conversion. ",
                      "Run: vips dzsave \"", f, "\" \"dzi_tiles/", base, "\""),
        type = "warning", duration = 8000
      ))
    }
  })

  # ---------- Metadata panel ----------
  output$metadata_ui <- renderUI({
    f <- rv$selected
    if (is.null(f)) return(NULL)

    full_path <- safe_path(rv$current_dir, f)
    if (is.null(full_path) || !file.exists(full_path)) return(NULL)

    info <- file.info(full_path)
    ext  <- get_ext(f)
    base <- tools::file_path_sans_ext(f)
    has_dzi <- file.exists(file.path(DEFAULT_DZI_DIR, paste0(base, ".dzi")))

    div(class = "meta-panel",
      div(class = "meta-row",
          span(class = "meta-label", "File:"),
          span(f)),
      div(class = "meta-row",
          span(class = "meta-label", "Size:"),
          span(format_size(info$size))),
      div(class = "meta-row",
          span(class = "meta-label", "Modified:"),
          span(format(info$mtime, "%Y-%m-%d %H:%M"))),
      div(class = "meta-row",
          span(class = "meta-label", "Format:"),
          span(toupper(ext))),
      div(class = "meta-row",
          span(class = "meta-label", "DZI Tiles:"),
          span(if (has_dzi) "\u2705 Available" else "\u274c Not converted"))
    )
  })

  # ---------- Viewer errors ----------
  observeEvent(input$viewer_error, {
    showNotification(paste("Viewer error:", input$viewer_error),
                     type = "error", duration = 5)
  })
}

# ---- Launch -----------------------------------------------------------------
shinyApp(ui, server)
