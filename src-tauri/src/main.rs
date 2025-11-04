#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")] // hide console window on Windows in release

use std::path::Path;

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
    .invoke_handler(tauri::generate_handler![reveal_in_file_manager])
    .run(tauri::generate_context!())
    .expect("error while running tauri application");
}
