library(shiny)
library(paws.storage)

# ============================================================================
# IHC Image Viewer - Shiny + OpenSeadragon + S3
# ============================================================================

# ---- Configuration ---------------------------------------------------------
S3_BUCKET         <- Sys.getenv("IHC_S3_BUCKET", "loh-prd-onc")
S3_DEFAULT_PREFIX <- Sys.getenv("IHC_S3_PREFIX", "")
DEFAULT_IMAGE_DIR <- normalizePath("images", mustWork = FALSE)
DEFAULT_DZI_DIR   <- normalizePath("dzi_tiles", mustWork = FALSE)

SIMPLE_FORMATS <- c("png", "jpg", "jpeg", "gif", "bmp", "webp")
WSI_FORMATS    <- c("svs", "tiff", "tif", "ndpi", "mrxs", "scn", "bif")
ALL_IMAGE_EXT  <- c(SIMPLE_FORMATS, WSI_FORMATS)

VIPS_AVAILABLE <- nzchar(Sys.which("vips"))

# ---- Helpers ----------------------------------------------------------------
get_ext <- function(f) tolower(tools::file_ext(f))

format_size <- function(bytes) {
  if (is.null(bytes) || is.na(bytes)) return("?")
  if (bytes >= 1024^3) return(sprintf("%.1f GB", bytes / 1024^3))
  if (bytes >= 1024^2) return(sprintf("%.1f MB", bytes / 1024^2))
  if (bytes >= 1024)   return(sprintf("%.1f KB", bytes / 1024))
  paste0(bytes, " B")
}

safe_path <- function(base_dir, filename) {
  clean_name <- basename(filename)
  full_path <- normalizePath(file.path(base_dir, clean_name), mustWork = FALSE)
  if (!startsWith(full_path, normalizePath(base_dir, mustWork = FALSE))) {
    return(NULL)
  }
  full_path
}

is_image_key <- function(key) {
  get_ext(key) %in% ALL_IMAGE_EXT
}

# ---- S3 client (auto-detects IAM role) -------------------------------------
s3 <- tryCatch(paws.storage::s3(), error = function(e) {
  message("Warning: Could not initialize S3 client: ", e$message)
  NULL
})

# ---- UI ---------------------------------------------------------------------
ui <- htmlTemplate(
  "template.html",
  s3_prefix_input = textInput("s3_prefix", NULL, value = S3_DEFAULT_PREFIX,
                               width = "100%",
                               placeholder = "S3 prefix (folder path)"),
  s3_browse_btn   = actionButton("s3_browse", "\u21bb Browse",
                                  class = "btn-refresh"),
  s3_file_list_ui = uiOutput("s3_file_list_ui"),
  local_file_list_ui = uiOutput("local_file_list_ui"),
  metadata_ui     = uiOutput("metadata_ui")
)

# ---- Server -----------------------------------------------------------------
server <- function(input, output, session) {

  rv <- reactiveValues(
    # S3 state
    s3_objects  = data.frame(Key = character(), Size = numeric(),
                             stringsAsFactors = FALSE),
    s3_folders  = character(0),
    s3_prefix   = S3_DEFAULT_PREFIX,
    # Local state
    local_files = character(0),
    selected    = NULL,
    current_dir = DEFAULT_IMAGE_DIR,
    # Status
    busy        = FALSE
  )

  # Ensure dirs exist
  dir.create(DEFAULT_IMAGE_DIR, showWarnings = FALSE, recursive = TRUE)
  dir.create(DEFAULT_DZI_DIR,   showWarnings = FALSE, recursive = TRUE)
  addResourcePath("dzi", DEFAULT_DZI_DIR)

  # ========== S3 BROWSING ====================================================

  # Browse S3 on button click or prefix change
  observeEvent(input$s3_browse, {
    if (is.null(s3)) {
      session$sendCustomMessage("showToast",
        list(text = "S3 client not available. Check AWS credentials.",
             type = "", duration = 5000))
      return()
    }

    prefix <- input$s3_prefix
    if (is.null(prefix)) prefix <- ""
    # Ensure prefix ends with / if non-empty
    if (nzchar(prefix) && !endsWith(prefix, "/")) prefix <- paste0(prefix, "/")
    rv$s3_prefix <- prefix

    tryCatch({
      result <- s3$list_objects_v2(
        Bucket    = S3_BUCKET,
        Prefix    = prefix,
        Delimiter = "/",
        MaxKeys   = 500L
      )

      # Extract folders (CommonPrefixes)
      folders <- character(0)
      if (length(result$CommonPrefixes) > 0) {
        folders <- sapply(result$CommonPrefixes, function(x) x$Prefix)
      }
      rv$s3_folders <- folders

      # Extract files (Contents) — filter to image types only
      if (length(result$Contents) > 0) {
        keys  <- sapply(result$Contents, function(x) x$Key)
        sizes <- sapply(result$Contents, function(x) x$Size)
        df <- data.frame(Key = keys, Size = sizes, stringsAsFactors = FALSE)
        # Exclude the prefix itself (S3 returns it as a 0-byte object)
        df <- df[df$Key != prefix & df$Size > 0, , drop = FALSE]
        # Filter to image files
        df <- df[sapply(df$Key, is_image_key), , drop = FALSE]
        rv$s3_objects <- df
      } else {
        rv$s3_objects <- data.frame(Key = character(), Size = numeric(),
                                    stringsAsFactors = FALSE)
      }
    }, error = function(e) {
      session$sendCustomMessage("showToast",
        list(text = paste("S3 error:", e$message), type = "", duration = 5000))
      rv$s3_objects <- data.frame(Key = character(), Size = numeric(),
                                  stringsAsFactors = FALSE)
      rv$s3_folders <- character(0)
    })
  })

  # S3 file list UI
  output$s3_file_list_ui <- renderUI({
    folders <- rv$s3_folders
    objects <- rv$s3_objects
    prefix  <- rv$s3_prefix

    items <- list()

    # "Back" button if we're in a subfolder
    if (nzchar(prefix)) {
      parent <- sub("[^/]+/$", "", prefix)
      items <- c(items, list(
        tags$div(class = "img-item s3-folder",
                 `data-s3-prefix` = parent,
                 tags$span(class = "name", "\u2190 Back"),
                 tags$span(class = "badge badge-folder", ".."))
      ))
    }

    # Folders
    for (folder in folders) {
      display_name <- sub(paste0("^", gsub("([.+?^${}()|\\[\\]])", "\\\\\\1", prefix)), "", folder)
      items <- c(items, list(
        tags$div(class = "img-item s3-folder",
                 `data-s3-prefix` = folder,
                 tags$span(class = "name", paste0("\U0001F4C1 ", display_name)),
                 tags$span(class = "badge badge-folder", "DIR"))
      ))
    }

    # Image files
    if (nrow(objects) > 0) {
      for (i in seq_len(nrow(objects))) {
        key  <- objects$Key[i]
        size <- objects$Size[i]
        fname <- basename(key)
        ext   <- get_ext(fname)
        # Check if already downloaded locally
        local_exists <- file.exists(file.path(DEFAULT_IMAGE_DIR, fname))

        badge_class <- if (local_exists) "badge badge-dzi" else "badge badge-wsi"
        badge_text  <- if (local_exists) "\u2713 LOCAL" else format_size(size)

        items <- c(items, list(
          tags$div(class = paste0("img-item s3-file",
                                   if (local_exists) " s3-cached" else ""),
                   `data-s3-key` = key,
                   `data-s3-name` = fname,
                   tags$span(class = "name", fname),
                   tags$span(class = badge_class, badge_text))
        ))
      }
    }

    if (length(items) == 0) {
      return(div(style = "padding: 20px; text-align: center; color: #585b70;",
                 p("No images found at this prefix."),
                 p(style = "font-size: 12px;", "Try a different path.")))
    }

    tagList(items)
  })

  # S3 folder navigation
  observeEvent(input$s3_navigate, {
    updateTextInput(session, "s3_prefix", value = input$s3_navigate)
    # Trigger browse
    shinyjs_delay <- function() {
      session$sendCustomMessage("triggerS3Browse", list())
    }
    shinyjs_delay()
  })

  # S3 download + auto-convert + view
  observeEvent(input$s3_download, {
    if (rv$busy) {
      session$sendCustomMessage("showToast",
        list(text = "Download already in progress...", type = "warning", duration = 2000))
      return()
    }
    if (is.null(s3)) return()

    key   <- input$s3_download$key
    fname <- input$s3_download$name
    if (is.null(key) || is.null(fname)) return()

    # Sanitize filename
    fname <- basename(fname)
    if (grepl("[/\\\\]", fname)) return()

    local_path <- file.path(DEFAULT_IMAGE_DIR, fname)
    ext <- get_ext(fname)
    base_name <- tools::file_path_sans_ext(fname)
    dzi_path <- file.path(DEFAULT_DZI_DIR, paste0(base_name, ".dzi"))

    # Skip download if already cached
    if (file.exists(local_path)) {
      session$sendCustomMessage("showToast",
        list(text = paste0(fname, " already downloaded. Loading..."),
             type = "info", duration = 2000))
    } else {
      rv$busy <- TRUE
      session$sendCustomMessage("showToast",
        list(text = paste0("Downloading ", fname, " from S3..."),
             type = "info", duration = 15000))
      session$sendCustomMessage("showProgress", list(show = TRUE,
        text = paste0("Downloading ", fname, "...")))

      tryCatch({
        s3$download_file(
          Bucket   = S3_BUCKET,
          Key      = key,
          Filename = local_path
        )
        session$sendCustomMessage("showToast",
          list(text = paste0("Downloaded ", fname, " (",
                             format_size(file.info(local_path)$size), ")"),
               type = "info", duration = 3000))
      }, error = function(e) {
        session$sendCustomMessage("showToast",
          list(text = paste("Download failed:", e$message),
               type = "", duration = 5000))
        session$sendCustomMessage("showProgress", list(show = FALSE))
        rv$busy <- FALSE
        return()
      })
    }

    # Auto-convert WSI to DZI if vips is available
    if (ext %in% WSI_FORMATS && !file.exists(dzi_path)) {
      if (VIPS_AVAILABLE) {
        session$sendCustomMessage("showProgress",
          list(show = TRUE, text = paste0("Converting ", fname, " to DZI tiles...")))
        session$sendCustomMessage("showToast",
          list(text = paste0("Converting ", fname, " to DZI..."),
               type = "info", duration = 15000))

        result <- tryCatch({
          system2("vips", c("dzsave", shQuote(local_path), shQuote(
            file.path(DEFAULT_DZI_DIR, base_name)),
            "--tile-size", "254", "--overlap", "1",
            "--suffix", ".jpeg[Q=85]",
            "--depth", "onepixel", "--background", "255"),
            stdout = TRUE, stderr = TRUE)
        }, error = function(e) e$message)

        if (file.exists(dzi_path)) {
          session$sendCustomMessage("showToast",
            list(text = paste0("DZI conversion complete for ", fname),
                 type = "info", duration = 3000))
        } else {
          session$sendCustomMessage("showToast",
            list(text = paste0("DZI conversion failed for ", fname,
                               ". Viewing as simple image."),
                 type = "warning", duration = 5000))
        }
      } else {
        session$sendCustomMessage("showToast",
          list(text = "vips not installed — cannot convert WSI to DZI tiles.",
               type = "warning", duration = 5000))
      }
    }

    session$sendCustomMessage("showProgress", list(show = FALSE))
    rv$busy <- FALSE

    # Refresh local file list
    addResourcePath("images", DEFAULT_IMAGE_DIR)
    rv$local_files <- scan_local()

    # Auto-view the downloaded image
    rv$selected <- fname
    has_dzi <- file.exists(dzi_path)
    is_simple <- ext %in% SIMPLE_FORMATS

    if (has_dzi) {
      session$sendCustomMessage("loadImage", list(
        type = "dzi", url = paste0("dzi/", base_name, ".dzi"), name = fname))
    } else if (is_simple || ext %in% WSI_FORMATS) {
      # For WSI without DZI, try simple image mode (may fail for SVS)
      if (ext %in% WSI_FORMATS) {
        session$sendCustomMessage("showToast",
          list(text = "Viewing as simple image (no DZI). Zoom may be limited.",
               type = "warning", duration = 4000))
      }
      session$sendCustomMessage("loadImage", list(
        type = "simple", url = paste0("images/", fname), name = fname))
    }

    # Refresh S3 list to update cached badges
    rv$s3_objects <- rv$s3_objects  # force reactivity
  })

  # ========== LOCAL FILE BROWSING ============================================

  scan_local <- function() {
    dir <- DEFAULT_IMAGE_DIR
    if (!dir.exists(dir)) return(character(0))
    pattern <- paste0("\\.(", paste(ALL_IMAGE_EXT, collapse = "|"), ")$")
    sort(list.files(dir, pattern = pattern, ignore.case = TRUE,
                    full.names = FALSE, recursive = FALSE))
  }

  # Initial scan
  observe({
    addResourcePath("images", DEFAULT_IMAGE_DIR)
    rv$local_files <- scan_local()
  })

  observeEvent(input$local_refresh, {
    rv$local_files <- scan_local()
  })

  # Local file list UI
  output$local_file_list_ui <- renderUI({
    files <- rv$local_files

    if (length(files) == 0) {
      return(div(style = "padding: 20px; text-align: center; color: #585b70;",
                 p("No local images."),
                 p(style = "font-size: 12px;",
                   "Download from S3 or place files in images/")))
    }

    items <- lapply(files, function(f) {
      ext <- get_ext(f)
      base <- tools::file_path_sans_ext(f)
      has_dzi <- file.exists(file.path(DEFAULT_DZI_DIR, paste0(base, ".dzi")))

      badge_class <- if (has_dzi) {
        "badge badge-dzi"
      } else if (ext %in% SIMPLE_FORMATS) {
        "badge badge-simple"
      } else {
        "badge badge-wsi"
      }
      badge_text <- if (has_dzi) "DZI" else toupper(ext)

      sel <- if (!is.null(rv$selected) && rv$selected == f) " selected" else ""

      tags$div(class = paste0("img-item local-file", sel),
               `data-file` = f,
               tags$span(class = "name", f),
               tags$span(class = badge_class, badge_text))
    })

    tagList(items)
  })

  # Local file selection
  observeEvent(input$select_image, {
    f <- input$select_image
    if (grepl("[/\\\\]", f)) return()

    full_path <- safe_path(DEFAULT_IMAGE_DIR, f)
    if (is.null(full_path) || !file.exists(full_path)) {
      session$sendCustomMessage("showToast",
        list(text = "File not found", type = "", duration = 3000))
      return()
    }

    rv$selected <- f
    ext  <- get_ext(f)
    base <- tools::file_path_sans_ext(f)
    dzi_file <- file.path(DEFAULT_DZI_DIR, paste0(base, ".dzi"))
    has_dzi  <- file.exists(dzi_file)

    if (has_dzi) {
      session$sendCustomMessage("loadImage", list(
        type = "dzi", url = paste0("dzi/", base, ".dzi"), name = f))
    } else if (ext %in% SIMPLE_FORMATS) {
      fsize <- file.info(full_path)$size
      if (fsize > 100 * 1024^2) {
        session$sendCustomMessage("showToast", list(
          text = paste0("Large file (", format_size(fsize), ") — may be slow."),
          type = "warning", duration = 4000))
      }
      session$sendCustomMessage("loadImage", list(
        type = "simple", url = paste0("images/", f), name = f))
    } else {
      session$sendCustomMessage("clearViewer", list())
      session$sendCustomMessage("showToast", list(
        text = paste0(toupper(ext), " requires DZI conversion (vips not available)."),
        type = "warning", duration = 5000))
    }
  })

  # ========== METADATA =======================================================

  output$metadata_ui <- renderUI({
    f <- rv$selected
    if (is.null(f)) return(NULL)

    full_path <- safe_path(DEFAULT_IMAGE_DIR, f)
    if (is.null(full_path) || !file.exists(full_path)) return(NULL)

    info <- file.info(full_path)
    ext  <- get_ext(f)
    base <- tools::file_path_sans_ext(f)
    has_dzi <- file.exists(file.path(DEFAULT_DZI_DIR, paste0(base, ".dzi")))

    div(class = "meta-panel",
      div(class = "meta-row",
          span(class = "meta-label", "File:"), span(f)),
      div(class = "meta-row",
          span(class = "meta-label", "Size:"), span(format_size(info$size))),
      div(class = "meta-row",
          span(class = "meta-label", "Modified:"),
          span(format(info$mtime, "%Y-%m-%d %H:%M"))),
      div(class = "meta-row",
          span(class = "meta-label", "Format:"), span(toupper(ext))),
      div(class = "meta-row",
          span(class = "meta-label", "DZI:"),
          span(if (has_dzi) "\u2705 Available" else "\u274c No")),
      if (!VIPS_AVAILABLE && ext %in% WSI_FORMATS && !has_dzi)
        div(class = "meta-row",
            span(style = "color: #fab387; font-size: 11px;",
                 "\u26a0 vips not installed on server"))
    )
  })

  # Viewer errors
  observeEvent(input$viewer_error, {
    showNotification(paste("Viewer error:", input$viewer_error),
                     type = "error", duration = 5)
  })
}

# ---- Launch -----------------------------------------------------------------
shinyApp(ui, server)
