import { cacheExists, clearDiskCache, getCacheStats } from './thumbnailCache';

export interface CacheInfo {
    exists: boolean;
    fileCount: number;
    sizeBytes: number;
}

/**
 * Get information about the thumbnail cache
 */
export const getThumbnailCacheInfo = async (): Promise<CacheInfo> => {
    const exists = await cacheExists();
    if (!exists) {
        return { exists: false, fileCount: 0, sizeBytes: 0 };
    }

    const stats = await getCacheStats();
    return {
        exists: true,
        fileCount: stats?.fileCount ?? 0,
        sizeBytes: stats?.sizeBytes ?? 0,
    };
};

/**
 * Clear the thumbnail cache
 */
export const clearThumbnailCacheFromDisk = async (): Promise<boolean> => {
    return await clearDiskCache();
};

/**
 * Format bytes to human readable string
 */
export const formatBytes = (bytes: number): string => {
    if (bytes === 0) return '0 Bytes';

    const k = 1024;
    const sizes = ['Bytes', 'KB', 'MB', 'GB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));

    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
};

/**
 * Application settings stored in localStorage
 */
interface AppSettings {
    thumbnailCacheEnabled: boolean;
    thumbnailSize: number;
    thumbnailsOnly: boolean;
}

const SETTINGS_KEY = 'promptlibrary.settings';

const defaultSettings: AppSettings = {
    thumbnailCacheEnabled: true,
    thumbnailSize: 5,
    thumbnailsOnly: false,
};

/**
 * Load app settings from localStorage
 */
export const loadSettings = (): AppSettings => {
    if (typeof window === 'undefined') return { ...defaultSettings };

    try {
        const raw = localStorage.getItem(SETTINGS_KEY);
        if (!raw) return { ...defaultSettings };

        const parsed = JSON.parse(raw);
        return { ...defaultSettings, ...parsed };
    } catch {
        return { ...defaultSettings };
    }
};

/**
 * Save app settings to localStorage
 */
export const saveSettings = (settings: Partial<AppSettings>): void => {
    if (typeof window === 'undefined') return;

    try {
        const current = loadSettings();
        const merged = { ...current, ...settings };
        localStorage.setItem(SETTINGS_KEY, JSON.stringify(merged));
    } catch (error) {
        console.error('Failed to save settings:', error);
    }
};
