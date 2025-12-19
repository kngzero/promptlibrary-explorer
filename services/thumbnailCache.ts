const thumbnailCache = new Map<string, string>();

export const getCachedThumbnail = (path: string) => thumbnailCache.get(path) ?? null;

export const setCachedThumbnail = (path: string, value: string) => {
    thumbnailCache.set(path, value);
};

export const clearThumbnailCache = () => thumbnailCache.clear();

