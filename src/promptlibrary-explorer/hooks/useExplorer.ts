import { useState, useCallback, useEffect } from 'react';
import { openFolderDialog, readDirectory, moveFile, getDesktopDir, getDocumentsDir, getPicturesDir } from '../services/tauriService';
import { clearPlibCache } from '../services/plibService';
import { clearAoeCache } from '../services/aoeService';
import { FsFileEntry } from '../types';
import { isDroppableFile } from '../utils/fileHelpers';

export function useExplorer() {
    const [explorerRootPath, setExplorerRootPath] = useState<string | null>(null);
    const [folderTree, setFolderTree] = useState<FsFileEntry[]>([]);
    const [selectedFolderPath, setSelectedFolderPath] = useState<string | null>(null);
    const [folderContents, setFolderContents] = useState<FsFileEntry[]>([]);
    const [isLoadingFolder, setIsLoadingFolder] = useState(false);

    // We need a way to expose toast from the hook or accept a toast callback. 
    // For now, let's accept an onError or onToast callback?
    // Or just return the error state.
    // Simplifying: We'll accept a toast callback for now or just console.error if not provided.
    // Ideally hooks should be pure logic or use a global toast context. 
    // Given the scope, I will ignore toast for now and let the component handle errors if I return them, 
    // OR I will accept a `showToast` function.
    // Let's accept `showToast` in functions where it's needed or just return success/failure promises.

    const refreshFolderTree = useCallback(async () => {
        if (explorerRootPath) {
            const contents = await readDirectory(explorerRootPath);
            const dirs = contents.filter(item => item.children);
            dirs.sort((a, b) => (a.name || '').localeCompare(b.name || ''));
            setFolderTree(dirs);
        }
    }, [explorerRootPath]);

    useEffect(() => {
        refreshFolderTree();
    }, [refreshFolderTree]);

    const fetchFolderContents = useCallback(async (path: string | null) => {
        if (path) {
            setIsLoadingFolder(true);
            try {
                const contents = await readDirectory(path);
                setFolderContents(contents);
            } catch (e) {
                console.error("Failed to read directory", e);
                throw e; // Let caller handle UI feedback
            } finally {
                setIsLoadingFolder(false);
            }
        } else {
            setFolderContents([]);
        }
    }, []);

    useEffect(() => {
        fetchFolderContents(selectedFolderPath);
    }, [selectedFolderPath, fetchFolderContents]);

    const handleOpenFolder = useCallback(async () => {
        const folderPath = await openFolderDialog();
        if (folderPath) {
            clearPlibCache();
            clearAoeCache();
            setExplorerRootPath(folderPath);
            setSelectedFolderPath(folderPath);
            return folderPath;
        }
        return null;
    }, []);

    const handleSelectFolder = useCallback(async (path: string) => {
        setSelectedFolderPath(path);
    }, []);

    const handleSelectFavorite = useCallback(async (favorite: 'desktop' | 'documents' | 'pictures') => {
        try {
            let path: string | null = null;
            switch (favorite) {
                case 'desktop':
                    path = await getDesktopDir();
                    break;
                case 'documents':
                    path = await getDocumentsDir();
                    break;
                case 'pictures':
                    path = await getPicturesDir();
                    break;
            }
            if (path) {
                clearPlibCache();
                clearAoeCache();
                setExplorerRootPath(path);
                setSelectedFolderPath(path);
                return path;
            }
        } catch (e) {
            console.error("Could not access favorite directory", e);
            throw e;
        }
        return null;
    }, []);

    const handleRefreshFolder = useCallback(async () => {
        if (!selectedFolderPath) return;
        await fetchFolderContents(selectedFolderPath);
        await refreshFolderTree();
    }, [selectedFolderPath, fetchFolderContents, refreshFolderTree]);

    const handleMoveItem = useCallback(async (sourcePath: string, destinationDir: string) => {
        console.log('[useExplorer] handleMoveItem called:', { sourcePath, destinationDir });
        try {
            await moveFile(sourcePath, destinationDir);
            console.log('[useExplorer] moveFile succeeded, refreshing...');
            await handleRefreshFolder();
            console.log('[useExplorer] refresh complete');
        } catch (error) {
            console.error('[useExplorer] handleMoveItem failed:', error);
            throw error;
        }
    }, [handleRefreshFolder]);

    const handleImportExternalFiles = useCallback(async (paths: string[]) => {
        if (!selectedFolderPath) return { count: 0, skipped: 0 };

        const allowedFiles = paths.filter(isDroppableFile);
        if (allowedFiles.length === 0) {
            throw new Error('No valid files to import.');
        }

        for (const filePath of allowedFiles) {
            await moveFile(filePath, selectedFolderPath);
        }

        await handleRefreshFolder();
        return { count: allowedFiles.length };
    }, [selectedFolderPath, handleRefreshFolder]);

    return {
        explorerRootPath,
        setExplorerRootPath,
        folderTree,
        selectedFolderPath,
        folderContents,
        isLoadingFolder,
        handleOpenFolder,
        handleSelectFolder,
        handleSelectFavorite,
        handleRefreshFolder,
        handleMoveItem,
        handleImportExternalFiles,
        fetchFolderContents // Exposed if needed
    };
}
