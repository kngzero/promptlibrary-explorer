import React, { useState, useEffect, useCallback, useMemo } from 'react';
import Header from './components/Header';
import Lightbox from './components/Lightbox';
import Toast from './components/Toast';
import Explorer from './components/Explorer';
import { openFolderDialog, readDirectory, convertFileSrc, getDesktopDir, getDocumentsDir, getPicturesDir, moveFile, renameEntry, revealInFileManager, deleteEntry, moveEntryToTrash, getFileMetadata } from './services/tauriService';
import { getDemoTree, getDemoFolderContents, getDemoPlibFile, getDemoImageEntry } from './services/demoService';
import { getPlibData, clearPlibCache } from './services/plibService';
import type { PromptEntry, FsFileEntry, SortConfig, FilterConfig, Breadcrumb, FileMetadata } from './types';

const isImageFile = (name: string) => /\.(png|jpe?g|webp|gif)$/i.test(name);
const isPlibFile = (name: string) => /\.plib$/i.test(name);
const isPreviewableItem = (item: FsFileEntry) => {
  if (item.children) return false;
  const name = item.name?.toLowerCase() || '';
  return isPlibFile(name) || isImageFile(name);
};
const isDroppableFile = (path: string) => /\.(plib|png|jpe?g)$/i.test(path.toLowerCase());

const buildFallbackMetadata = (path: string): FileMetadata => {
  const fileName = path.split(/[\\/]/).pop() || 'File';
  const ext = fileName.includes('.') ? fileName.split('.').pop() || '' : '';
  const lowerExt = ext.toLowerCase();
  let fileType = 'File';

  if (lowerExt === 'plib') {
    fileType = 'Prompt Library File';
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
};

const App: React.FC = () => {
  const [toast, setToast] = useState<{ message: string; type: 'success' | 'error' | 'info' } | null>(null);

  // Explorer State
  const [explorerRootPath, setExplorerRootPath] = useState<string | null>(null);
  const [folderTree, setFolderTree] = useState<FsFileEntry[]>([]);
  const [selectedFolderPath, setSelectedFolderPath] = useState<string | null>(null);
  const [folderContents, setFolderContents] = useState<FsFileEntry[]>([]);
  const [selectedExplorerItem, setSelectedExplorerItem] = useState<PromptEntry | null>(null);
  const [selectedItemIndex, setSelectedItemIndex] = useState<number>(-1);
  const [selectedIndices, setSelectedIndices] = useState<number[]>([]);
  const [selectionAnchorIndex, setSelectionAnchorIndex] = useState<number | null>(null);
  const [isLoadingFolder, setIsLoadingFolder] = useState(false);

  // Sort & Filter State
  const [sortConfig, setSortConfig] = useState<SortConfig>({ field: 'type', direction: 'asc' });
  const [filterConfig, setFilterConfig] = useState<FilterConfig>({
    hideOther: true,
    hideJpg: false,
    hidePng: false,
  });

  // Display State
  const [thumbnailSize, setThumbnailSize] = useState(5); // Range 1-10
  const [thumbnailsOnly, setThumbnailsOnly] = useState(false);

  // Lightbox state
  const [lightboxOpen, setLightboxOpen] = useState(false);
  const [lightboxEntry, setLightboxEntry] = useState<PromptEntry | null>(null);
  const [lightboxIndex, setLightboxIndex] = useState(0);
  const [lightboxPreviewIndex, setLightboxPreviewIndex] = useState<number>(-1);
  const [contextMenu, setContextMenu] = useState<{ x: number; y: number; item: FsFileEntry } | null>(null);
  const [renameState, setRenameState] = useState<{ item: FsFileEntry; value: string; originalName: string } | null>(null);
  const [deleteState, setDeleteState] = useState<{ item: FsFileEntry; mode: 'trash' | 'permanent' } | null>(null);
  const [dragSourcePath, setDragSourcePath] = useState<string | null>(null);

  useEffect(() => {
    const handleDragStart = (event: DragEvent) => {
      const target = event.target as HTMLElement | null;
      if (!target) return;
      const isTextInput = target.closest('input, textarea, [contenteditable="true"], [role="textbox"]');
      const isCustomDraggable = target.closest('[data-draggable-item="true"]');
      if (!isCustomDraggable && !isTextInput) {
        event.preventDefault();
      }
    };

    window.addEventListener('dragstart', handleDragStart, true);
    return () => window.removeEventListener('dragstart', handleDragStart, true);
  }, []);
  const isDemoMode = useMemo(() => !!(explorerRootPath && explorerRootPath.startsWith('/demo')), [explorerRootPath]);

  const handleOpenFolder = useCallback(async () => {
    const folderPath = await openFolderDialog();
    if (folderPath) {
      clearPlibCache();
      setExplorerRootPath(folderPath);
      setSelectedFolderPath(folderPath);
      setSelectedExplorerItem(null);
      setSelectedIndices([]);
      setSelectionAnchorIndex(null);
      setSelectedItemIndex(-1);
    }
  }, []);

  const handleDragStartItem = useCallback((path: string) => {
    setDragSourcePath(path);
  }, []);

  const handleDragEndItem = useCallback(() => {
    setDragSourcePath(null);
  }, []);

  const handleStartDemoMode = () => {
      clearPlibCache();
      setExplorerRootPath('/demo');
      const demoTree = getDemoTree();
      // Sort the demo folders alphabetically
      demoTree.sort((a, b) => (a.name || '').localeCompare(b.name || ''));
      setFolderTree(demoTree);
      setSelectedFolderPath('/demo');
      setSelectedExplorerItem(null);
      setSelectedItemIndex(-1);
      setSelectedIndices([]);
      setSelectionAnchorIndex(null);
      setToast({ message: 'Demo mode started.', type: 'info' });
  };

  const handleExitDemo = () => {
    clearPlibCache();
    setExplorerRootPath(null);
    setFolderTree([]);
    setSelectedFolderPath(null);
    setFolderContents([]);
    setSelectedExplorerItem(null);
    setSelectedItemIndex(-1);
    setSelectedIndices([]);
    setSelectionAnchorIndex(null);
    setToast({ message: "Exited demo mode.", type: 'info' });
  };

  const handleSelectFolder = useCallback(async (path: string) => {
      setSelectedFolderPath(path);
      setSelectedExplorerItem(null);
      setSelectedItemIndex(-1);
      setSelectedIndices([]);
      setSelectionAnchorIndex(null);
  }, []);

  const handleSelectFavorite = useCallback(async (favorite: 'desktop' | 'documents' | 'pictures') => {
    if (isDemoMode) {
        setToast({ message: "Favorites are disabled in demo mode.", type: 'info' });
        return;
    }
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
            setExplorerRootPath(path);
            setSelectedFolderPath(path);
            setSelectedExplorerItem(null);
            setSelectedIndices([]);
            setSelectionAnchorIndex(null);
            setSelectedItemIndex(-1);
        }
    } catch (e) {
        console.error("Could not access favorite directory", e);
        setToast({ message: "Could not access that directory.", type: 'error' });
    }
  }, [isDemoMode]);

  const breadcrumbs = useMemo<Breadcrumb[]>(() => {
    if (!selectedFolderPath || !explorerRootPath) return [];

    if (isDemoMode) {
        const parts = selectedFolderPath.split('/').filter(p => p);
        const crumbs: Breadcrumb[] = [{ name: 'Demo', path: '/demo' }];
        let currentPath = '/demo';
        for (let i = 1; i < parts.length; i++) {
            currentPath += `/${parts[i]}`;
            crumbs.push({ name: parts[i], path: currentPath });
        }
        return crumbs;
    }

    const relativePath = selectedFolderPath.substring(explorerRootPath.length).replace(/^[\\/]/, '');
    const rootName = explorerRootPath.split(/[\\/]/).pop() || explorerRootPath;

    const crumbs: Breadcrumb[] = [{ name: rootName, path: explorerRootPath }];
    if (!relativePath) return crumbs;

    const parts = relativePath.split(/[\\/]/);
    let currentCrumbPath = explorerRootPath;
    for (const part of parts) {
        if (!part) continue;
        currentCrumbPath = `${currentCrumbPath}/${part}`;
        crumbs.push({ name: part, path: currentCrumbPath });
    }
    return crumbs;
  }, [selectedFolderPath, explorerRootPath, isDemoMode]);

  // Global Keyboard Shortcuts
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      // Don't interfere with text inputs or open modals
      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement || lightboxOpen) {
          return;
      }

      // Ctrl/Cmd + O to Open Folder
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'o') {
          e.preventDefault();
          handleOpenFolder();
      }

      // Backspace to go up one directory level
      const parentCrumb = breadcrumbs.length > 1 ? breadcrumbs[breadcrumbs.length - 2] : null;
      if (e.key === 'Backspace' && parentCrumb) {
          e.preventDefault();
          handleSelectFolder(parentCrumb.path);
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => {
        window.removeEventListener('keydown', handleKeyDown);
    };
  }, [handleOpenFolder, handleSelectFolder, breadcrumbs, lightboxOpen]);

  const refreshFolderTree = useCallback(async () => {
      if (explorerRootPath && !isDemoMode) {
          const contents = await readDirectory(explorerRootPath);
          const dirs = contents.filter(item => item.children);
          dirs.sort((a, b) => (a.name || '').localeCompare(b.name || ''));
          setFolderTree(dirs);
      }
  }, [explorerRootPath, isDemoMode]);

  useEffect(() => {
      refreshFolderTree();
  }, [refreshFolderTree]);
  
  const fetchFolderContents = useCallback(async (path: string | null) => {
    if (path) {
      setIsLoadingFolder(true);
      try {
        const contents = isDemoMode
          ? getDemoFolderContents(path)
          : await readDirectory(path);
        setFolderContents(contents);
      } catch (e) {
        console.error("Failed to read directory", e);
        setToast({ message: 'Could not read folder contents.', type: 'error' });
        setFolderContents([]);
      } finally {
        setIsLoadingFolder(false);
      }
    } else {
      setFolderContents([]);
    }
  }, [isDemoMode]);

  useEffect(() => {
    fetchFolderContents(selectedFolderPath);
  }, [selectedFolderPath, fetchFolderContents]);

  const handleRefreshFolder = useCallback(async () => {
    if (!selectedFolderPath) {
        return;
    }
    await fetchFolderContents(selectedFolderPath);
    await refreshFolderTree();
  }, [selectedFolderPath, fetchFolderContents, refreshFolderTree]);

  const handleMoveItem = useCallback(async (sourcePath: string, destinationDir: string) => {
    if (isDemoMode) {
        setToast({ message: 'Drag and drop is disabled in demo mode.', type: 'info' });
        return;
    }
    try {
        await moveFile(sourcePath, destinationDir);
        // Deselect item to avoid confusion after move
        setSelectedExplorerItem(null);
        setSelectedItemIndex(-1);
        setSelectedIndices([]);
        setSelectionAnchorIndex(null);
        // Refresh the current folder view
        await fetchFolderContents(selectedFolderPath);
        await refreshFolderTree();
        setToast({ message: 'Item moved successfully.', type: 'success' });
    } catch (e) {
        console.error("Failed to move item:", e);
        setToast({ message: "Failed to move item.", type: 'error' });
    }
  }, [isDemoMode, selectedFolderPath, fetchFolderContents, refreshFolderTree]);

  const handleImportExternalFiles = useCallback(async (paths: string[]) => {
    if (!selectedFolderPath || isDemoMode) {
        return;
    }

    const allowedFiles = paths.filter(isDroppableFile);
    if (allowedFiles.length === 0) {
        setToast({ message: 'Only .plib, .png, or .jpg files can be dropped here.', type: 'info' });
        return;
    }

    try {
        for (const filePath of allowedFiles) {
            await moveFile(filePath, selectedFolderPath);
        }

        await fetchFolderContents(selectedFolderPath);
        await refreshFolderTree();
        setToast({
            message: `Moved ${allowedFiles.length} file${allowedFiles.length === 1 ? '' : 's'} into the current folder.`,
            type: 'success',
        });
    } catch (error) {
        console.error('Failed to import dropped files', error);
        setToast({ message: 'Failed to import dropped files.', type: 'error' });
    }
  }, [selectedFolderPath, isDemoMode, fetchFolderContents, refreshFolderTree]);

  useEffect(() => {
      let unlisten: (() => void) | null = null;
      let disposed = false;

      const setupListener = async () => {
          if (typeof window === 'undefined' || !(window as unknown as { __TAURI_IPC__?: unknown }).__TAURI_IPC__) {
              return;
          }

          try {
              const { appWindow } = await import('@tauri-apps/api/window');
              const listener = await appWindow.onFileDropEvent((event) => {
                  if (event.payload?.type === 'drop' && Array.isArray(event.payload.paths) && event.payload.paths.length > 0) {
                      handleImportExternalFiles(event.payload.paths);
                  }
              });

              if (disposed) {
                  listener();
              } else {
                  unlisten = listener;
              }
          } catch (error) {
              console.error('Failed to register file drop listener', error);
          }
      };

      setupListener();

      return () => {
          disposed = true;
          if (unlisten) {
              unlisten();
          }
      };
  }, [handleImportExternalFiles]);

  const handleItemContextMenu = useCallback((event: React.MouseEvent, item: FsFileEntry, _index?: number) => {
    event.preventDefault();
    if (isDemoMode) {
        setToast({ message: 'Context menu actions are disabled in demo mode.', type: 'info' });
        return;
    }
    setContextMenu({ x: event.clientX, y: event.clientY, item });
  }, [isDemoMode]);

  const handleRenameChange = useCallback((value: string) => {
    setRenameState(prev => (prev ? { ...prev, value } : prev));
  }, []);

  const handleRenameCancel = useCallback(() => {
    setRenameState(null);
  }, []);

  const handleRenameConfirm = useCallback(async () => {
    if (!renameState) return;
    if (isDemoMode) {
        setToast({ message: 'Renaming is disabled in demo mode.', type: 'info' });
        setRenameState(null);
        return;
    }

    const newName = renameState.value.trim();
    if (!newName) {
        setToast({ message: 'Name cannot be empty.', type: 'error' });
        return;
    }

    if (/[\\/]/.test(newName)) {
        setToast({ message: 'Name cannot contain path separators.', type: 'error' });
        return;
    }

    if (newName === renameState.originalName) {
        setRenameState(null);
        return;
    }

    try {
        await renameEntry(renameState.item.path, newName);
        setToast({ message: 'Item renamed successfully.', type: 'success' });
        setRenameState(null);
        setSelectedExplorerItem(null);
        setSelectedItemIndex(-1);
        setSelectedIndices([]);
        setSelectionAnchorIndex(null);
        setLightboxOpen(false);
        setLightboxEntry(null);
        setLightboxPreviewIndex(-1);
        setLightboxIndex(0);
        await fetchFolderContents(selectedFolderPath);
        await refreshFolderTree();
    } catch (error) {
        console.error('Failed to rename item', error);
        setToast({ message: 'Failed to rename item.', type: 'error' });
    }
  }, [renameState, isDemoMode, fetchFolderContents, selectedFolderPath, refreshFolderTree]);

  const handleDeleteCancel = useCallback(() => {
    setDeleteState(null);
  }, []);

  const handleDeleteConfirm = useCallback(async () => {
    if (!deleteState) return;

    if (isDemoMode) {
      setToast({ message: 'Deleting is disabled in demo mode.', type: 'info' });
      setDeleteState(null);
      return;
    }

    try {
      if (deleteState.mode === 'trash') {
        await moveEntryToTrash(deleteState.item.path);
        setToast({ message: 'Item moved to trash.', type: 'success' });
      } else {
        await deleteEntry(deleteState.item.path, !!deleteState.item.children);
        setToast({ message: 'Item deleted permanently.', type: 'success' });
      }
      setSelectedExplorerItem(null);
      setSelectedItemIndex(-1);
      setSelectedIndices([]);
      setSelectionAnchorIndex(null);
      setLightboxOpen(false);
      setLightboxEntry(null);
      setLightboxPreviewIndex(-1);
      setLightboxIndex(0);
      await fetchFolderContents(selectedFolderPath);
      await refreshFolderTree();
    } catch (error) {
      console.error('Failed to delete item', error);
      setToast({ message: 'Failed to delete item.', type: 'error' });
    } finally {
      setDeleteState(null);
    }
  }, [
    deleteState,
    isDemoMode,
    fetchFolderContents,
    selectedFolderPath,
    refreshFolderTree,
    moveEntryToTrash,
    deleteEntry,
  ]);

  useEffect(() => {
    setContextMenu(null);
    setRenameState(null);
    setDeleteState(null);
  }, [selectedFolderPath, isDemoMode]);


  // FIX: Moved getItemTypeRank and processedFolderContents before their usage in other hooks to prevent "used before declaration" errors.
  const getItemTypeRank = useCallback((item: FsFileEntry): number => {
    if (item.children) return 0; // Directory
    const name = item.name?.toLowerCase() || '';
    if (name.endsWith('.plib')) return 1;
    if (/\.(png|jpe?g|webp|gif)$/i.test(name)) return 2; // Image
    return 3; // Other
  }, []);

  const processedFolderContents = useMemo(() => {
      let items = [...folderContents];

      items = items.filter(item => {
        const name = item.name?.toLowerCase() || '';
        if (filterConfig.hideJpg && (name.endsWith('.jpg') || name.endsWith('.jpeg'))) return false;
        if (filterConfig.hidePng && name.endsWith('.png')) return false;

        if (filterConfig.hideOther) {
            const isDir = !!item.children;
            const isAllowedType = isDir || /\.(plib|png|jpe?g|webp|gif)$/i.test(name);
            if (!isAllowedType) return false;
        }
        return true;
      });

      items.sort((a, b) => {
        const nameA = a.name?.toLowerCase() || '';
        const nameB = b.name?.toLowerCase() || '';
        let comparison = 0;

        if (sortConfig.field === 'type') {
            const typeA = getItemTypeRank(a);
            const typeB = getItemTypeRank(b);
            comparison = typeA - typeB;
            if (comparison === 0) {
                comparison = nameA.localeCompare(nameB);
            }
        } else { // sort by name
            comparison = nameA.localeCompare(nameB);
        }
        return sortConfig.direction === 'asc' ? comparison : -comparison;
      });
      
      return items;
  }, [folderContents, sortConfig, filterConfig, getItemTypeRank]);

  const hiddenItemCount = useMemo(() => folderContents.length - processedFolderContents.length, [folderContents, processedFolderContents]);

  const previewableItems = useMemo(
    () => processedFolderContents
      .map((item, index) => ({ item, index }))
      .filter(({ item }) => isPreviewableItem(item)),
    [processedFolderContents]
  );

  const previewIndexByFolderIndex = useMemo(() => {
    const map = new Map<number, number>();
    previewableItems.forEach(({ index }, previewIdx) => {
      map.set(index, previewIdx);
    });
    return map;
  }, [previewableItems]);
  
  const loadPromptEntryForItem = useCallback(async (item: FsFileEntry): Promise<PromptEntry | null> => {
    if (item.children) return null;
    const name = (item.name || item.path).toLowerCase();
    const fallbackMetadata = buildFallbackMetadata(item.path);
    let entry: PromptEntry | null = null;

    if (isDemoMode) {
        if (isPlibFile(name)) {
            const data = getDemoPlibFile(item.path);
            if (!data) return null;
            entry = {
                ...data,
                sourcePath: item.path,
                rawImages: data.images ? [...data.images] : undefined,
                rawReferenceImages: data.referenceImages ? [...data.referenceImages] : undefined,
            };
        } else if (isImageFile(name)) {
            const data = getDemoImageEntry(item.path);
            entry = {
                ...data,
                sourcePath: item.path,
                rawImages: data.images ? [...data.images] : undefined,
                rawReferenceImages: data.referenceImages ? [...data.referenceImages] : undefined,
            };
        }
    } else if (isPlibFile(name)) {
        const data = await getPlibData(item.path);
        if (!data) return null;

        const convertIfNeeded = async (img: string) =>
            !img.startsWith('data:') && !/^https?:\/\//i.test(img) ? await convertFileSrc(img) : img;

        const rawImages = data.images ? [...data.images] : undefined;
        const rawReferenceImages = data.referenceImages ? [...data.referenceImages] : undefined;
        const images = await Promise.all((rawImages ?? []).map(convertIfNeeded));
        const referenceImages = await Promise.all((rawReferenceImages ?? []).map(convertIfNeeded));
        entry = {
            ...data,
            images,
            referenceImages,
            rawImages,
            rawReferenceImages,
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

    const metadata = isDemoMode
        ? fallbackMetadata
        : (await getFileMetadata(item.path)) ?? fallbackMetadata;

    return {
        ...entry,
        fileMetadata: metadata,
    };
  }, [isDemoMode]);

  const handleSelectItem = useCallback(async (item: FsFileEntry | null) => {
    if (!item) {
      setSelectedExplorerItem(null);
      return;
    }

    if (item.children) {
      // It's a directory, clear selection
      setSelectedExplorerItem(null);
      return;
    }

    const entry = await loadPromptEntryForItem(item);
    setSelectedExplorerItem(entry);
  }, [loadPromptEntryForItem]);

  const updateSelection = useCallback(
    (indices: number[], primaryIndex?: number | null, anchorIndex?: number | null) => {
      const normalized = Array.from(
        new Set(indices.filter((idx) => idx >= 0 && idx < processedFolderContents.length))
      ).sort((a, b) => a - b);

      if (anchorIndex !== undefined) {
        setSelectionAnchorIndex(anchorIndex);
      }

      const nextPrimary =
        primaryIndex !== undefined && primaryIndex !== null
          ? primaryIndex
          : normalized.length
          ? normalized[normalized.length - 1]
          : -1;

      setSelectedIndices(normalized);

      if (nextPrimary >= 0 && nextPrimary < processedFolderContents.length) {
        setSelectedItemIndex(nextPrimary);
        const item = processedFolderContents[nextPrimary];
        if (item) {
          handleSelectItem(item);
        }
      } else {
        setSelectedItemIndex(-1);
        setSelectedExplorerItem(null);
      }
    },
    [processedFolderContents, handleSelectItem]
  );

  const handleSelectItemByIndex = useCallback(
    (index: number) => {
      if (index >= 0 && index < processedFolderContents.length) {
        updateSelection([index], index, index);
      }
    },
    [processedFolderContents, updateSelection]
  );

  const handleItemClick = useCallback(
    (_item: FsFileEntry, index: number, event?: React.MouseEvent) => {
      const isShift = !!event?.shiftKey;
      const isMeta = !!event?.metaKey || !!event?.ctrlKey;

      if (isShift && selectionAnchorIndex !== null) {
        const start = selectionAnchorIndex;
        const end = index;
        const step = start <= end ? 1 : -1;
        const range: number[] = [];
        for (let i = start; step === 1 ? i <= end : i >= end; i += step) {
          range.push(i);
        }
        const combined = isMeta ? Array.from(new Set([...selectedIndices, ...range])) : range;
        updateSelection(combined, index, selectionAnchorIndex);
        return;
      }

      if (isMeta) {
        const alreadySelected = selectedIndices.includes(index);
        const nextSelection = alreadySelected
          ? selectedIndices.filter((idx) => idx !== index)
          : [...selectedIndices, index];
        const nextPrimary = alreadySelected
          ? nextSelection[nextSelection.length - 1] ?? -1
          : index;
        const fallbackAnchor = selectionAnchorIndex ?? index;
        const anchorInSelection = nextSelection.includes(fallbackAnchor);
        const nextAnchor =
          nextSelection.length === 0
            ? null
            : anchorInSelection
            ? fallbackAnchor
            : nextPrimary !== -1
            ? nextPrimary
            : nextSelection[0];
        updateSelection(nextSelection, nextPrimary === -1 ? null : nextPrimary, nextAnchor);
        if (nextSelection.length === 0) {
          setSelectionAnchorIndex(null);
        }
        return;
      }

      updateSelection([index], index, index);
    },
    [selectionAnchorIndex, selectedIndices, updateSelection]
  );

  useEffect(() => {
    setSelectedIndices((prev) =>
      prev.filter((idx) => idx >= 0 && idx < processedFolderContents.length)
    );

    if (
      selectionAnchorIndex !== null &&
      (selectionAnchorIndex < 0 || selectionAnchorIndex >= processedFolderContents.length)
    ) {
      setSelectionAnchorIndex(null);
    }
  }, [processedFolderContents.length, selectionAnchorIndex]);

  useEffect(() => {
    if (selectedIndices.length === 0) {
      if (selectedItemIndex !== -1) {
        setSelectedItemIndex(-1);
        setSelectedExplorerItem(null);
      }
      return;
    }

    if (!selectedIndices.includes(selectedItemIndex)) {
      const fallbackIndex = selectedIndices[selectedIndices.length - 1];
      if (fallbackIndex !== undefined && fallbackIndex < processedFolderContents.length) {
        setSelectedItemIndex(fallbackIndex);
        const item = processedFolderContents[fallbackIndex];
        if (item) {
          handleSelectItem(item);
        }
      }
    }
  }, [selectedIndices, selectedItemIndex, processedFolderContents, handleSelectItem]);
  
  const openLightboxAtPreviewIndex = useCallback(async (previewIndex: number) => {
    const target = previewableItems[previewIndex];
    if (!target) return;

    try {
        const entry = await loadPromptEntryForItem(target.item);
        if (!entry || !entry.images || entry.images.length === 0) {
            setToast({ message: 'Unable to preview this item.', type: 'error' });
            return;
        }

        setLightboxEntry(entry);
        setLightboxIndex(0);
        setLightboxPreviewIndex(previewIndex);
        setLightboxOpen(true);
        setSelectedExplorerItem(entry);
        setSelectedIndices([target.index]);
        setSelectionAnchorIndex(target.index);
        setSelectedItemIndex(target.index);
        setContextMenu(null);
    } catch (error) {
        console.error('Failed to open item in lightbox', error);
        setToast({ message: 'Failed to open item.', type: 'error' });
    }
  }, [loadPromptEntryForItem, previewableItems]);

  const openLightboxAtFolderIndex = useCallback((folderIndex: number) => {
    const previewIndex = previewIndexByFolderIndex.get(folderIndex);
    if (previewIndex === undefined) return;
    openLightboxAtPreviewIndex(previewIndex);
  }, [previewIndexByFolderIndex, openLightboxAtPreviewIndex]);

  const closeLightbox = useCallback(() => {
    setLightboxOpen(false);
    setLightboxEntry(null);
    setLightboxPreviewIndex(-1);
    setLightboxIndex(0);
  }, []);

  const goToAdjacentPreview = useCallback((direction: 1 | -1) => {
    if (lightboxPreviewIndex === -1) return;
    const targetIndex = lightboxPreviewIndex + direction;
    if (targetIndex < 0 || targetIndex >= previewableItems.length) return;
    openLightboxAtPreviewIndex(targetIndex);
  }, [lightboxPreviewIndex, previewableItems, openLightboxAtPreviewIndex]);

  const nextFile = useCallback(() => goToAdjacentPreview(1), [goToAdjacentPreview]);
  const prevFile = useCallback(() => goToAdjacentPreview(-1), [goToAdjacentPreview]);

  const handleLightboxImageChange = useCallback((index: number) => {
    if (!lightboxEntry) return;
    const maxIndex = Math.max(0, (lightboxEntry.images?.length ?? 1) - 1);
    const clamped = Math.min(Math.max(index, 0), maxIndex);
    setLightboxIndex(clamped);
  }, [lightboxEntry]);

  const canNavigatePrev = lightboxPreviewIndex > 0;
  const canNavigateNext = lightboxPreviewIndex >= 0 && lightboxPreviewIndex < previewableItems.length - 1;
  
  return (
    <div className="bg-zinc-900 text-white h-screen flex flex-col font-sans">
      {toast && (
        <Toast
          message={toast.message}
          type={toast.type}
          onClose={() => setToast(null)}
        />
      )}
      <Header
        breadcrumbs={breadcrumbs}
        onNavigate={handleSelectFolder}
        sortConfig={sortConfig}
        onSortChange={setSortConfig}
        filterConfig={filterConfig}
        onFilterChange={setFilterConfig}
        isFolderOpen={!!explorerRootPath}
        isDemoMode={isDemoMode}
        onChangeFolder={handleOpenFolder}
        onExitDemo={handleExitDemo}
        onRefreshFolder={handleRefreshFolder}
      />
      
      <main className="flex-grow flex flex-col overflow-hidden">
        <Explorer
            rootPath={explorerRootPath}
            folderTree={folderTree}
            selectedFolderPath={selectedFolderPath}
            folderContents={processedFolderContents}
            hiddenItemCount={hiddenItemCount}
            selectedItem={selectedExplorerItem}
            selectedItemIndex={selectedItemIndex}
            selectedIndices={selectedIndices}
            isLoading={isLoadingFolder}
            thumbnailSize={thumbnailSize}
            onThumbnailSizeChange={setThumbnailSize}
            thumbnailsOnly={thumbnailsOnly}
            onThumbnailsOnlyChange={setThumbnailsOnly}
            onOpenFolder={handleOpenFolder}
            onSelectFolder={handleSelectFolder}
            onSelectItem={handleItemClick}
            onSelectItemByIndex={handleSelectItemByIndex}
            onOpenLightbox={openLightboxAtFolderIndex}
            onStartDemo={handleStartDemoMode}
            onSelectFavorite={handleSelectFavorite}
            onMoveItem={handleMoveItem}
            isDemoMode={isDemoMode}
            onItemContextMenu={handleItemContextMenu}
            dragSourcePath={dragSourcePath}
            onDragStartItem={handleDragStartItem}
            onDragEndItem={handleDragEndItem}
        />
      </main>

      {lightboxEntry && (
        <Lightbox
          isOpen={lightboxOpen}
          entry={lightboxEntry}
          currentImageIndex={lightboxIndex}
          onClose={closeLightbox}
          onNextFile={nextFile}
          onPrevFile={prevFile}
          onSelectImage={handleLightboxImageChange}
          canGoNext={canNavigateNext}
          canGoPrev={canNavigatePrev}
          onShowToast={(message, type) => setToast({ message, type })}
        />
      )}

      {contextMenu && (
        <div
          className="fixed inset-0 z-40"
          onClick={() => setContextMenu(null)}
          onContextMenu={(e) => {
            e.preventDefault();
            setContextMenu(null);
          }}
        >
          <div
            className="absolute bg-neutral-800 border border-neutral-700 rounded-md shadow-lg py-1 min-w-[160px] text-sm"
            style={{ top: contextMenu.y, left: contextMenu.x }}
            onClick={(e) => e.stopPropagation()}
          >
            <button
              onClick={async () => {
                if (!contextMenu) return;
                const targetPath = contextMenu.item.path;
                setContextMenu(null);
                const revealed = await revealInFileManager(targetPath);
                if (!revealed) {
                  setToast({ message: 'Unable to show item in Finder.', type: 'error' });
                }
              }}
              className="w-full text-left px-3 py-2 hover:bg-neutral-700 text-neutral-200"
            >
              Show in Finder
            </button>
            <button
              onClick={() => {
                const fallbackName = contextMenu.item.name || contextMenu.item.path.split(/[\\/]/).pop() || '';
                setRenameState({ item: contextMenu.item, value: fallbackName, originalName: fallbackName });
                setContextMenu(null);
              }}
              className="w-full text-left px-3 py-2 hover:bg-neutral-700 text-neutral-200"
            >
              Rename
            </button>
            <button
              onClick={() => {
                if (!contextMenu) return;
                setDeleteState({ item: contextMenu.item, mode: 'trash' });
                setContextMenu(null);
              }}
              className="w-full text-left px-3 py-2 hover:bg-red-900/40 text-red-400"
            >
              Delete
            </button>
          </div>
        </div>
      )}

      {renameState && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 px-4"
          onClick={handleRenameCancel}
        >
          <div
            className="bg-neutral-900 border border-neutral-700 rounded-xl p-6 w-full max-w-md shadow-2xl"
            onClick={(e) => e.stopPropagation()}
          >
            <h2 className="text-lg font-semibold mb-4">Rename Item</h2>
            <input
              type="text"
              value={renameState.value}
              onChange={(e) => handleRenameChange(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') handleRenameConfirm();
                if (e.key === 'Escape') handleRenameCancel();
              }}
              autoFocus
              className="w-full px-3 py-2 rounded-md bg-neutral-800 border border-neutral-700 text-white focus:outline-none focus:ring-2 focus:ring-fuchsia-500"
              placeholder="Enter a new name"
            />
            <div className="flex justify-end gap-3 mt-6">
              <button
                onClick={handleRenameCancel}
                className="px-4 py-2 rounded-md border border-neutral-600 text-neutral-300 hover:bg-neutral-700"
              >
                Cancel
              </button>
              <button
                onClick={handleRenameConfirm}
                className="px-4 py-2 rounded-md bg-fuchsia-600 hover:bg-fuchsia-700 text-white"
              >
                Rename
              </button>
            </div>
          </div>
        </div>
      )}

      {deleteState && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 px-4"
          onClick={handleDeleteCancel}
        >
          <div
            className="bg-neutral-900 border border-neutral-700 rounded-xl p-6 w-full max-w-md shadow-2xl"
            onClick={(e) => e.stopPropagation()}
          >
            <h2 className="text-lg font-semibold mb-3">Delete Item</h2>
            <p className="text-sm text-neutral-300">
              Choose how you want to remove{' '}
              <span className="text-white font-semibold">
                {deleteState.item.name || deleteState.item.path.split(/[\\/]/).pop() || deleteState.item.path}
              </span>
              .
            </p>
            {deleteState.item.children && deleteState.mode === 'permanent' && (
              <p className="text-xs text-red-300 mt-2">
                The folder and all of its contents will be permanently removed.
              </p>
            )}
            <div className="flex gap-3 mt-6">
              <button
                onClick={() =>
                  setDeleteState((prev) => (prev ? { ...prev, mode: 'trash' } : prev))
                }
                className={`flex-1 px-4 py-3 rounded-md border text-sm font-semibold transition ${
                  deleteState.mode === 'trash'
                    ? 'bg-neutral-100 text-neutral-900 border-neutral-100'
                    : 'border-neutral-600 text-neutral-300 hover:bg-neutral-800'
                }`}
              >
                Move to Trash
              </button>
              <button
                onClick={() =>
                  setDeleteState((prev) => (prev ? { ...prev, mode: 'permanent' } : prev))
                }
                className={`flex-1 px-4 py-3 rounded-md border text-sm font-semibold transition ${
                  deleteState.mode === 'permanent'
                    ? 'bg-red-600 text-white border-red-600'
                    : 'border-red-500 text-red-400 hover:bg-red-500/10'
                }`}
              >
                Delete Permanently
              </button>
            </div>
            <p className="text-xs text-neutral-400 mt-3">
              {deleteState.mode === 'trash'
                ? 'The item can be restored later from your system trash.'
                : 'This will permanently remove the item from disk.'}
            </p>
            <div className="flex justify-end gap-3 mt-6">
              <button
                onClick={handleDeleteCancel}
                className="px-4 py-2 rounded-md border border-neutral-600 text-neutral-300 hover:bg-neutral-700"
              >
                Cancel
              </button>
              <button
                onClick={handleDeleteConfirm}
                className={`px-4 py-2 rounded-md ${
                  deleteState.mode === 'trash'
                    ? 'bg-neutral-100 text-neutral-900 hover:bg-white'
                    : 'bg-red-600 text-white hover:bg-red-700'
                }`}
              >
                {deleteState.mode === 'trash' ? 'Move to Trash' : 'Delete'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};

export default App;
