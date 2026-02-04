import { useCallback } from 'react';
import { PromptEntry, FsFileEntry, FileMetadata } from '../types';
import { convertFileSrc, getFileMetadata } from '../services/tauriService';
import { getPlibData } from '../services/plibService';
import { getAoeData } from '../services/aoeService';
import { isImageFile, isPromptSnapshotFile, isPlibFile } from '../utils/fileHelpers';

const fileUrlCache = new Map<string, string>();

export function usePromptLoader() {
    const buildFallbackMetadata = useCallback((path: string): FileMetadata => {
        const fileName = path.split(/[\\/]/).pop() || 'File';
        const ext = fileName.includes('.') ? fileName.split('.').pop() || '' : '';
        const lowerExt = ext.toLowerCase();
        let fileType = 'File';

        if (lowerExt === 'plib') {
            fileType = 'Prompt Library File';
        } else if (lowerExt === 'aoe') {
            fileType = 'Art Official Elements File';
        } else if (lowerExt) {
            fileType = `${lowerExt.toUpperCase()} File`;
        }

        return {
            fileName,
            fileType,
            width: null,
            height: null,
            modifiedMs: null,
        };
    }, []);

    const loadPromptEntryForItem = useCallback(async (item: FsFileEntry): Promise<PromptEntry | null> => {
        if (item.children) return null;
        const name = (item.name || item.path).toLowerCase();
        const fallbackMetadata = buildFallbackMetadata(item.path);
        let entry: PromptEntry | null = null;

        const convertIfNeeded = async (img: string) => {
            if (!img) return img;
            if (img.startsWith('data:') || /^https?:\/\//i.test(img)) return img;
            if (/^[A-Za-z0-9+/=\s]+$/.test(img) && img.length > 100) {
                return `data:image/png;base64,${img.replace(/\s+/g, '')}`;
            }
            if (fileUrlCache.has(img)) return fileUrlCache.get(img) as string;
            const converted = await convertFileSrc(img);
            fileUrlCache.set(img, converted);
            return converted;
        };

        if (isPromptSnapshotFile(name)) {
            const data = isPlibFile(name) ? await getPlibData(item.path) : await getAoeData(item.path);
            if (!data) return null;

            const rawImages = data.rawImages ? [...data.rawImages] : data.images ? [...data.images] : undefined;
            const baseImages = data.images ? [...data.images] : undefined;
            const rawReferenceImages = data.rawReferenceImages ? [...data.rawReferenceImages] : data.referenceImages ? [...data.referenceImages] : undefined;
            const baseReferenceImages = data.referenceImages ? [...data.referenceImages] : undefined;

            const images = await Promise.all((baseImages ?? rawImages ?? []).map(convertIfNeeded));
            const referenceImages = await Promise.all((baseReferenceImages ?? rawReferenceImages ?? []).map(convertIfNeeded));
            entry = {
                ...data,
                images,
                referenceImages,
                rawImages: rawImages ?? baseImages,
                rawReferenceImages: rawReferenceImages ?? baseReferenceImages,
                sourcePath: item.path,
            };
        } else if (isImageFile(name)) {
            const imageUrl = await convertFileSrc(item.path);
            entry = {
                prompt: item.name || item.path.split(/[\\/]/).pop() || 'Image',
                images: [imageUrl],
                rawImages: [item.path],
                generationInfo: {
                    model: 'Image File',
                    aspectRatio: 'N/A',
                    timestamp: 'N/A',
                    numberOfImages: 1,
                },
                sourcePath: item.path,
            };
        }

        if (!entry) {
            return null;
        }

        const metadata = (await getFileMetadata(item.path)) ?? fallbackMetadata;

        return {
            ...entry,
            fileMetadata: metadata,
        };
    }, [buildFallbackMetadata]);

    return {
        loadPromptEntryForItem
    };
}
