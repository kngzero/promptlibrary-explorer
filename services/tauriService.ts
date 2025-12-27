import type { FsFileEntry, FileMetadata } from '../types';
import { renameFile, readDir as readDirFs, removeDir, removeFile } from '@tauri-apps/api/fs';
import { basename, join, dirname, desktopDir, documentDir, pictureDir } from '@tauri-apps/api/path';
import { convertFileSrc as tauriConvertFileSrc, invoke } from '@tauri-apps/api/tauri';
import { open as dialogOpen } from '@tauri-apps/api/dialog';


/**
 * Opens a native folder selection dialog.
 * @returns A promise that resolves to the selected folder path, or null if canceled.
 */
export const openFolderDialog = async (): Promise<string | null> => {
  try {
    const selected = await dialogOpen({
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
    const entries = await readDirFs(dirPath, { recursive: false });
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
    return tauriConvertFileSrc(filePath);
};

/**
 * Gets the basename (filename with extension) from a file path.
 * @param filePath The path to the file.
 * @returns A promise that resolves to the basename of the file.
 */
export const getBasename = async (filePath: string): Promise<string> => {
  try {
    return await basename(filePath);
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
  return desktopDir();
};

/**
 * Gets the path to the user's documents directory.
 */
export const getDocumentsDir = async (): Promise<string> => {
  return documentDir();
};

/**
 * Gets the path to the user's pictures directory.
 */
export const getPicturesDir = async (): Promise<string> => {
  return pictureDir();
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

/**
 * Renames a file or folder within its current directory.
 * @param sourcePath Full path to the item to rename.
 * @param newName New filename (without directory path).
 */
export const renameEntry = async (sourcePath: string, newName: string): Promise<void> => {
  try {
    const directory = await dirname(sourcePath);
    const destinationPath = await join(directory, newName);

    if (destinationPath === sourcePath) {
      console.log("Source and destination are the same, skipping rename.");
      return;
    }

    await renameFile(sourcePath, destinationPath);
  } catch (error) {
    console.error(`Failed to rename ${sourcePath} to ${newName}`, error);
    throw error;
  }
};

/**
 * Deletes a file or directory at the specified path.
 * Directories are removed recursively.
 */
export const deleteEntry = async (targetPath: string, isDirectory: boolean): Promise<void> => {
  try {
    if (isDirectory) {
      await removeDir(targetPath, { recursive: true });
    } else {
      await removeFile(targetPath);
    }
  } catch (error) {
    console.error(`Failed to delete ${targetPath}`, error);
    throw error;
  }
};

/**
 * Moves the given file or directory to the operating system's trash.
 */
export const moveEntryToTrash = async (targetPath: string): Promise<void> => {
  if (!targetPath) return;
  try {
    await invoke('move_to_trash', { targetPath });
  } catch (error) {
    console.error(`Failed to move ${targetPath} to trash`, error);
    throw error;
  }
};

/**
 * Reveals a file or folder in the native file manager.
 * On macOS this opens Finder, on Windows Explorer, and on Linux the containing folder.
 */
export const revealInFileManager = async (targetPath: string): Promise<boolean> => {
  if (!targetPath) {
    return false;
  }

  try {
    await invoke('reveal_in_file_manager', { targetPath });
    return true;
  } catch (error) {
    console.error(`Failed to reveal item in file manager: ${targetPath}`, error);
    return false;
  }
};

/**
 * Retrieves metadata for a given file path such as name, type, dimensions and timestamps.
 */
export const getFileMetadata = async (targetPath: string): Promise<FileMetadata | null> => {
  if (!targetPath) {
    return null;
  }

  try {
    const metadata = await invoke<FileMetadata>('get_file_metadata', { targetPath });
    return metadata;
  } catch (error) {
    console.warn(`Failed to fetch metadata for ${targetPath}`, error);
    return null;
  }
};
