import { invoke } from '@tauri-apps/api/tauri';
import { exists, createDir, readDir, removeDir } from '@tauri-apps/api/fs';
import { appCacheDir, join } from '@tauri-apps/api/path';

// In-memory cache for quick lookups during runtime
const memoryCache = new Map<string, string>();

// Thumbnail configuration
const THUMBNAIL_MAX_SIZE = 200; // Max dimension in pixels
const CACHE_FOLDER_NAME = 'thumbnails';

let cacheDir: string | null = null;
let cacheInitialized = false;

/**
 * Initialize the cache directory
 */
const initCacheDir = async (): Promise<string | null> => {
    if (cacheDir !== null) return cacheDir;

    try {
        const appCache = await appCacheDir();
        cacheDir = await join(appCache, CACHE_FOLDER_NAME);

        const dirExists = await exists(cacheDir);
        if (!dirExists) {
            await createDir(cacheDir, { recursive: true });
        }
        cacheInitialized = true;
        return cacheDir;
    } catch (error) {
        console.error('Failed to initialize thumbnail cache directory:', error);
        cacheDir = null;
        return null;
    }
};

/**
 * Generate a safe filename from a path hash
 */
const generateCacheKey = (path: string): string => {
    // Create a simple hash from the path
    let hash = 0;
    for (let i = 0; i < path.length; i++) {
        const char = path.charCodeAt(i);
        hash = ((hash << 5) - hash) + char;
        hash = hash & hash; // Convert to 32bit integer
    }
    // Use absolute value and add the original filename for uniqueness
    const absHash = Math.abs(hash).toString(36);
    const fileName = path.split(/[\\/]/).pop() || 'file';
    const safeFileName = fileName.replace(/[^a-zA-Z0-9.-]/g, '_').slice(0, 50);
    return `${absHash}_${safeFileName}.webp`;
};

/**
 * Get a cached thumbnail from memory or disk
 */
export const getCachedThumbnail = (path: string): string | null => {
    return memoryCache.get(path) ?? null;
};

/**
 * Set a thumbnail in the in-memory cache
 */
export const setCachedThumbnail = (path: string, value: string): void => {
    memoryCache.set(path, value);
};

/**
 * Clear the in-memory thumbnail cache
 */
export const clearThumbnailCache = (): void => {
    memoryCache.clear();
};

/**
 * Check if there's a cached thumbnail on disk
 */
export const getDiskCachedThumbnail = async (originalPath: string): Promise<string | null> => {
    try {
        const dir = await initCacheDir();
        if (!dir) return null;

        const cacheKey = generateCacheKey(originalPath);
        const cachePath = await join(dir, cacheKey);

        const fileExists = await exists(cachePath);
        if (fileExists) {
            // Return cache path that can be converted to file URL
            return cachePath;
        }
        return null;
    } catch (error) {
        console.error('Error checking disk thumbnail cache:', error);
        return null;
    }
};

/**
 * Generate a thumbnail for an image and cache it to disk
 * Note: This requires a Tauri command to resize images
 */
export const generateAndCacheThumbnail = async (
    originalPath: string
): Promise<string | null> => {
    try {
        const dir = await initCacheDir();
        if (!dir) return null;

        const cacheKey = generateCacheKey(originalPath);
        const cachePath = await join(dir, cacheKey);

        // Check if already cached
        const fileExists = await exists(cachePath);
        if (fileExists) {
            return cachePath;
        }

        // Call Tauri command to generate thumbnail
        // This command should resize the image and save to cache path
        const success = await invoke<boolean>('generate_thumbnail', {
            sourcePath: originalPath,
            destPath: cachePath,
            maxSize: THUMBNAIL_MAX_SIZE,
        });

        if (success) {
            return cachePath;
        }
        return null;
    } catch (error) {
        // If thumbnail generation fails (e.g., command not available),
        // fall back to using original image
        console.warn('Thumbnail generation not available, using original:', error);
        return null;
    }
};

/**
 * Get cache statistics
 */
export const getCacheStats = async (): Promise<{ fileCount: number; sizeBytes: number } | null> => {
    try {
        const dir = await initCacheDir();
        if (!dir) return null;

        const entries = await readDir(dir);
        let sizeBytes = 0;
        const fileCount = entries.length;

        // Note: We can't easily get file sizes without additional Tauri commands
        // This is a simplified version that just counts files
        return { fileCount, sizeBytes };
    } catch (error) {
        console.error('Error getting cache stats:', error);
        return null;
    }
};

/**
 * Check if cache exists and has files
 */
export const cacheExists = async (): Promise<boolean> => {
    try {
        const dir = await initCacheDir();
        if (!dir) return false;

        const dirExists = await exists(dir);
        if (!dirExists) return false;

        const entries = await readDir(dir);
        return entries.length > 0;
    } catch (error) {
        console.error('Error checking cache existence:', error);
        return false;
    }
};

/**
 * Clear the entire thumbnail cache from disk
 */
export const clearDiskCache = async (): Promise<boolean> => {
    try {
        const dir = await initCacheDir();
        if (!dir) return false;

        const dirExists = await exists(dir);
        if (!dirExists) return true;

        // Remove the directory and recreate it
        await removeDir(dir, { recursive: true });
        await createDir(dir, { recursive: true });

        // Also clear memory cache
        memoryCache.clear();

        return true;
    } catch (error) {
        console.error('Error clearing disk cache:', error);
        return false;
    }
};

/**
 * Check if cache is initialized
 */
export const isCacheInitialized = (): boolean => cacheInitialized;
