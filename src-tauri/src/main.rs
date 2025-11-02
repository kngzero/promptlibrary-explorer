#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")] // hide console window on Windows in release

fn main() {
  tauri::Builder::default()
    // .invoke_handler(tauri::generate_handler![/* your Rust commands here */])
    .run(tauri::generate_context!())
    .expect("error while running tauri application");
}
