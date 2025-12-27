#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")] // hide console window on Windows in release

use image::GenericImageView;
use serde::Serialize;
use std::{
  borrow::Cow,
  fs,
  path::{Path, PathBuf},
  time::{SystemTime, UNIX_EPOCH},
};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct FileMetadataResult {
  file_name: String,
  file_type: String,
  width: Option<u32>,
  height: Option<u32>,
  modified_ms: Option<u64>,
}

fn describe_file_type(extension: &str) -> String {
  match extension {
    "png" => "PNG Image".into(),
    "jpg" | "jpeg" => "JPEG Image".into(),
    "gif" => "GIF Image".into(),
    "bmp" => "Bitmap Image".into(),
    "webp" => "WebP Image".into(),
    "tiff" | "tif" => "TIFF Image".into(),
    "plib" => "Prompt Library File".into(),
    "aoe" => "Art Official Elements File".into(),
    "" => "File".into(),
    other => format!("{} File", other.to_uppercase()),
  }
}

#[tauri::command]
fn get_file_metadata(target_path: String) -> Result<FileMetadataResult, String> {
  let trimmed = target_path.trim();
  if trimmed.is_empty() {
    return Err("Target path was empty.".into());
  }

  let path = Path::new(trimmed);
  if !path.exists() {
    return Err(format!("Path does not exist: {trimmed}"));
  }

  let metadata = fs::metadata(path).map_err(|err| err.to_string())?;
  let file_name = path
    .file_name()
    .and_then(|name| name.to_str())
    .unwrap_or(trimmed)
    .to_string();
  let extension = path
    .extension()
    .and_then(|ext| ext.to_str())
    .unwrap_or("")
    .to_lowercase();
  let file_type = describe_file_type(&extension);

  let modified_ms = metadata
    .modified()
    .ok()
    .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
    .map(|duration| {
      let millis = duration.as_millis();
      if millis > u64::MAX as u128 {
        u64::MAX
      } else {
        millis as u64
      }
    });

  let (width, height) = match extension.as_str() {
    "png" | "jpg" | "jpeg" | "gif" | "bmp" | "webp" | "tiff" | "tif" => {
      match image::image_dimensions(path) {
        Ok((w, h)) => (Some(w), Some(h)),
        Err(_) => (None, None),
      }
    }
    _ => (None, None),
  };

  Ok(FileMetadataResult {
    file_name,
    file_type,
    width,
    height,
    modified_ms,
  })
}

#[tauri::command]
fn copy_image_to_clipboard(image_data: Vec<u8>) -> Result<(), String> {
  if image_data.is_empty() {
    return Err("Image data was empty.".into());
  }

  let image = image::load_from_memory(&image_data).map_err(|err| err.to_string())?;
  let rgba = image.to_rgba8();
  let (width, height) = image.dimensions();

  let mut clipboard = arboard::Clipboard::new().map_err(|err| err.to_string())?;
  clipboard
    .set_image(arboard::ImageData {
      width: width as usize,
      height: height as usize,
      bytes: Cow::Owned(rgba.into_raw()),
    })
    .map_err(|err| err.to_string())
}

#[tauri::command]
fn move_to_trash(target_path: String) -> Result<(), String> {
  let trimmed = target_path.trim();
  if trimmed.is_empty() {
    return Err("Target path was empty.".into());
  }

  let path = PathBuf::from(trimmed);
  if !path.exists() {
    return Err(format!("Path does not exist: {trimmed}"));
  }

  trash::delete(path).map_err(|err| err.to_string())
}

#[tauri::command]
fn reveal_in_file_manager(target_path: String) -> Result<(), String> {
  let trimmed = target_path.trim();
  if trimmed.is_empty() {
    return Err("Path was empty.".into());
  }

  let path = Path::new(trimmed);
  if !path.exists() {
    return Err(format!("Path does not exist: {trimmed}"));
  }

  #[cfg(target_os = "macos")]
  {
    return reveal_on_macos(path);
  }

  #[cfg(target_os = "windows")]
  {
    return reveal_on_windows(path);
  }

  #[cfg(all(unix, not(target_os = "macos")))]
  {
    return reveal_on_unix(path);
  }

  #[allow(unreachable_code)]
  Err("Reveal in file manager is not supported on this platform.".into())
}

#[cfg(target_os = "macos")]
fn reveal_on_macos(path: &Path) -> Result<(), String> {
  std::process::Command::new("open")
    .arg("-R")
    .arg(path)
    .status()
    .map_err(|err| err.to_string())
    .and_then(|status| {
      if status.success() {
        Ok(())
      } else {
        Err(format!("open -R exited with status: {status}"))
      }
    })
}

#[cfg(target_os = "windows")]
fn reveal_on_windows(path: &Path) -> Result<(), String> {
  use std::ffi::OsString;

  if path.is_dir() {
    return std::process::Command::new("explorer")
      .arg(path)
      .status()
      .map_err(|err| err.to_string())
      .and_then(|status| {
        if status.success() {
          Ok(())
        } else {
          Err(format!("explorer exited with status: {status}"))
        }
      });
  }

  let mut selector = OsString::from("/select,");
  selector.push(path);

  std::process::Command::new("explorer")
    .arg(selector)
    .status()
    .map_err(|err| err.to_string())
    .and_then(|status| {
      if status.success() {
        Ok(())
      } else {
        Err(format!("explorer exited with status: {status}"))
      }
    })
}

#[cfg(all(unix, not(target_os = "macos")))]
fn reveal_on_unix(path: &Path) -> Result<(), String> {
  let folder = if path.is_dir() {
    path.to_path_buf()
  } else {
    path
      .parent()
      .map(Path::to_path_buf)
      .unwrap_or_else(|| std::path::PathBuf::from("/"))
  };

  std::process::Command::new("xdg-open")
    .arg(folder)
    .status()
    .map_err(|err| err.to_string())
    .and_then(|status| {
      if status.success() {
        Ok(())
      } else {
        Err(format!("xdg-open exited with status: {status}"))
      }
    })
}

fn main() {
  tauri::Builder::default()
    .invoke_handler(tauri::generate_handler![
      reveal_in_file_manager,
      copy_image_to_clipboard,
      move_to_trash,
      get_file_metadata
    ])
    .run(tauri::generate_context!())
    .expect("error while running tauri application");
}
