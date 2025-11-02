import type { PromptEntry } from '../types';
// FIX: Import directly from '@tauri-apps/api/fs' to ensure module is found.
import { readTextFile } from '@tauri-apps/api/fs';

const cache = new Map<string, PromptEntry>();

/**
 * Reads and parses a .plib JSON file, using a cache to avoid re-reading from disk.
 * @param filePath The path to the .plib file.
 * @returns A promise that resolves to the parsed PromptEntry, or null if an error occurs.
 */
export const getPlibData = async (filePath: string): Promise<PromptEntry | null> => {
    if (cache.has(filePath)) {
        return cache.get(filePath) || null;
    }
    
    try {
        const contents = await readTextFile(filePath);
        const data = JSON.parse(contents);
        if (data.prompt && data.images && data.generationInfo) {
            const entry = data as PromptEntry;
            cache.set(filePath, entry);
            return entry;
        }
        console.warn(`Invalid .plib file format: ${filePath}`);
        return null;
    } catch (error) {
        console.error(`Failed to read or parse .plib file: ${filePath}`, error);
        return null;
    }
};

/**
 * Clears the in-memory cache of .plib files.
 */
export const clearPlibCache = () => {
    console.log("Clearing .plib cache.");
    cache.clear();
};
