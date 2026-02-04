import { FsFileEntry } from '../types';

// Image file extensions
const IMAGE_EXTENSIONS = /\.(png|jpe?g|webp|gif|bmp|tiff?)$/i;

// Prompt snapshot file extensions  
const PROMPT_EXTENSIONS = /\.(plib|aoe)$/i;

/**
 * Check if a filename represents an image file
 */
export const isImageFile = (name: string): boolean => IMAGE_EXTENSIONS.test(name);

/**
 * Check if a filename is a .plib file
 */
export const isPlibFile = (name: string): boolean => /\.plib$/i.test(name);

/**
 * Check if a filename is a .aoe file
 */
export const isAoeFile = (name: string): boolean => /\.aoe$/i.test(name);

/**
 * Check if a filename is any prompt snapshot format (.plib or .aoe)
 */
export const isPromptSnapshotFile = (name: string): boolean => PROMPT_EXTENSIONS.test(name);

/**
 * Check if a file system entry can be previewed (image or prompt snapshot)
 */
export const isPreviewableItem = (item: FsFileEntry): boolean => {
  if (item.children) return false;
  const name = item.name?.toLowerCase() || '';
  return isPromptSnapshotFile(name) || isImageFile(name);
};

/**
 * Check if a path represents a file that can be dropped/imported
 */
export const isDroppableFile = (path: string): boolean => {
  const lower = path.toLowerCase();
  return /\.(plib|aoe|png|jpe?g)$/i.test(lower);
};

/**
 * Get file extension from a path or filename
 */
export const getFileExtension = (path: string): string | null => {
  const match = path.match(/\.([^./\\]+)$/);
  return match ? match[1].toLowerCase() : null;
};

/**
 * Determine MIME type from file extension
 */
export const mimeFromExtension = (ext: string | null | undefined): string => {
  if (!ext) return 'application/octet-stream';
  const lower = ext.toLowerCase();

  const mimeMap: Record<string, string> = {
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'webp': 'image/webp',
    'gif': 'image/gif',
    'bmp': 'image/bmp',
    'tif': 'image/tiff',
    'tiff': 'image/tiff',
    'svg': 'image/svg+xml',
  };

  return mimeMap[lower] || 'application/octet-stream';
};

/**
 * Determine file extension from MIME type
 */
export const extensionFromMime = (mime: string | null | undefined): string | null => {
  if (!mime) return null;

  const extensionMap: Record<string, string> = {
    'image/png': 'png',
    'image/jpeg': 'jpg',
    'image/webp': 'webp',
    'image/gif': 'gif',
    'image/bmp': 'bmp',
    'image/tiff': 'tiff',
    'image/svg+xml': 'svg',
  };

  return extensionMap[mime] || null;
};

/**
 * Check if a string looks like base64 encoded data
 */
export const isLikelyBase64 = (value: string): boolean => {
  return /^[A-Za-z0-9+/=\s]+$/.test(value) && value.length > 100;
};

/**
 * Check if a string looks like an absolute file path
 */
export const isLikelyAbsolutePath = (value: string): boolean => {
  return /^[A-Za-z]:[\\/]/.test(value) || value.startsWith('/');
};

/**
 * Get a display name from a file path
 */
export const getDisplayName = (path: string): string => {
  return path.split(/[\\/]/).pop() || path;
};
