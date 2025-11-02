import type { FsFileEntry } from '../types';
import { renameFile } from '@tauri-apps/api/fs';
import { basename, join } from '@tauri-apps/api/path';


/**
 * Opens a native folder selection dialog.
 * @returns A promise that resolves to the selected folder path, or null if canceled.
 */
export const openFolderDialog = async (): Promise<string | null> => {
  try {
    // FIX: Import 'dialog' module from its specific sub-package.
    const dialog = await import('@tauri-apps/api/dialog');
    const selected = await dialog.open({
      directory: true,
      multiple: false,
      title: 'Select a Folder',
    });

    if (Array.isArray(selected)) {
      return selected[0] || null;
    }
    return selected;
  } catch (error) {
    console.error("Error opening folder dialog:", error);
    return null;
  }
};

/**
 * Reads the contents of a directory (non-recursively).
 * @param dirPath The path of the directory to read.
 * @returns A promise that resolves to an array of file and folder entries.
 */
export const readDirectory = async (dirPath: string): Promise<FsFileEntry[]> => {
  try {
    // FIX: Import 'fs' module from its specific sub-package.
    const fs = await import('@tauri-apps/api/fs');
    // readDir in Tauri returns an array of entries with a `children` property for directories.
    const entries = await fs.readDir(dirPath, { recursive: false });
    return entries;
  } catch (error) {
    console.error(`Failed to read directory: ${dirPath}`, error);
    return [];
  }
};

/**
 * Converts a local file path to a special URL format that the Tauri webview can use to display local assets.
 * @param filePath The local file path.
 * @returns A promise resolving to a URL string (e.g., 'tauri://localhost/path/to/file').
 */
export const convertFileSrc = async (filePath: string): Promise<string> => {
    const { convertFileSrc: tauriConvertFileSrc } = await import('@tauri-apps/api/tauri');
    return tauriConvertFileSrc(filePath);
};

/**
 * Gets the basename (filename with extension) from a file path.
 * @param filePath The path to the file.
 * @returns A promise that resolves to the basename of the file.
 */
export const getBasename = async (filePath: string): Promise<string> => {
  try {
    // FIX: Import 'path' module from its specific sub-package.
    const path = await import('@tauri-apps/api/path');
    return await path.basename(filePath);
  } catch (error) {
    console.error(`Failed to get basename for path: ${filePath}`, error);
    // Fallback for safety, though path.basename should be reliable.
    return filePath.split(/[\\/]/).pop() || '';
  }
};

/**
 * Gets the path to the user's desktop directory.
 */
export const getDesktopDir = async (): Promise<string> => {
  // FIX: Import 'path' module from its specific sub-package.
  const path = await import('@tauri-apps/api/path');
  return path.desktopDir();
};

/**
 * Gets the path to the user's documents directory.
 */
export const getDocumentsDir = async (): Promise<string> => {
  // FIX: Import 'path' module from its specific sub-package.
  const path = await import('@tauri-apps/api/path');
  return path.documentDir();
};

/**
 * Gets the path to the user's pictures directory.
 */
export const getPicturesDir = async (): Promise<string> => {
  // FIX: Import 'path' module from its specific sub-package.
  const path = await import('@tauri-apps/api/path');
  return path.pictureDir();
};

/**
 * Moves a file from a source path to a destination directory.
 * @param sourcePath The full path of the file to move.
 * @param destinationDir The full path of the directory to move the file into.
 */
export const moveFile = async (sourcePath: string, destinationDir: string): Promise<void> => {
  try {
    const fileName = await basename(sourcePath);
    const destinationPath = await join(destinationDir, fileName);
    
    // Prevent moving a file on top of itself if it's already in the directory
    if (sourcePath === destinationPath) {
      console.log("Source and destination are the same, skipping move.");
      return;
    }
    
    await renameFile(sourcePath, destinationPath);
  } catch (error) {
    console.error(`Failed to move file from ${sourcePath} to ${destinationDir}`, error);
    throw error; // Re-throw to be caught by the calling component
  }
};