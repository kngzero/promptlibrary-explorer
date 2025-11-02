import React, { useState, useEffect, useCallback, useMemo } from 'react';
import Header from './components/Header';
import Lightbox from './components/Lightbox';
import Toast from './components/Toast';
import Explorer from './components/Explorer';
import { openFolderDialog, readDirectory, convertFileSrc, getDesktopDir, getDocumentsDir, getPicturesDir, moveFile } from './services/tauriService';
import { getDemoTree, getDemoFolderContents, getDemoPlibFile, getDemoImageEntry } from './services/demoService';
import { getPlibData, clearPlibCache } from './services/plibService';
import type { PromptEntry, FsFileEntry, SortConfig, FilterConfig, Breadcrumb } from './types';

const App: React.FC = () => {
  const [toast, setToast] = useState<{ message: string; type: 'success' | 'error' | 'info' } | null>(null);

  // Explorer State
  const [explorerRootPath, setExplorerRootPath] = useState<string | null>(null);
  const [folderTree, setFolderTree] = useState<FsFileEntry[]>([]);
  const [selectedFolderPath, setSelectedFolderPath] = useState<string | null>(null);
  const [folderContents, setFolderContents] = useState<FsFileEntry[]>([]);
  const [selectedExplorerItem, setSelectedExplorerItem] = useState<PromptEntry | null>(null);
  const [selectedItemIndex, setSelectedItemIndex] = useState<number>(-1);
  const [isLoadingFolder, setIsLoadingFolder] = useState(false);

  // Sort & Filter State
  const [sortConfig, setSortConfig] = useState<SortConfig>({ field: 'type', direction: 'asc' });
  const [filterConfig, setFilterConfig] = useState<FilterConfig>({
    hideOther: false,
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
  
  const isDemoMode = useMemo(() => explorerRootPath?.startsWith('/demo'), [explorerRootPath]);

  const handleOpenFolder = useCallback(async () => {
    const folderPath = await openFolderDialog();
    if (folderPath) {
      clearPlibCache();
      setExplorerRootPath(folderPath);
      setSelectedFolderPath(folderPath);
    }
  }, []);

  const handleStartDemoMode = () => {
      clearPlibCache();
      setExplorerRootPath('/demo');
      const demoTree = getDemoTree();
      // Sort the demo folders alphabetically
      demoTree.sort((a, b) => (a.name || '').localeCompare(b.name || ''));
      setFolderTree(demoTree);
      setSelectedFolderPath('/demo');
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
    setToast({ message: "Exited demo mode.", type: 'info' });
  };

  const handleSelectFolder = useCallback(async (path: string) => {
      setSelectedFolderPath(path);
      setSelectedExplorerItem(null);
      setSelectedItemIndex(-1);
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
    const rootName = explorerRootPath.split(/[\\/]/).pop();

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

  useEffect(() => {
      const buildTree = async () => {
          if (explorerRootPath && !isDemoMode) {
              const contents = await readDirectory(explorerRootPath);
              const dirs = contents.filter(item => item.children);
              // Sort directories alphabetically by name
              dirs.sort((a, b) => (a.name || '').localeCompare(b.name || ''));
              setFolderTree(dirs);
          }
      };
      buildTree();
  }, [explorerRootPath, isDemoMode]);
  
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
        // Refresh the current folder view
        await fetchFolderContents(selectedFolderPath);
        setToast({ message: 'Item moved successfully.', type: 'success' });
    } catch (e) {
        console.error("Failed to move item:", e);
        setToast({ message: "Failed to move item.", type: 'error' });
    }
  }, [isDemoMode, selectedFolderPath, fetchFolderContents]);


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

    if (isDemoMode) {
        if (item.path.endsWith('.plib')) {
            setSelectedExplorerItem(getDemoPlibFile(item.path));
        } else if (/\.(png|jpe?g|webp|gif)$/i.test(item.name || item.path)) {
            setSelectedExplorerItem(getDemoImageEntry(item.path));
        } else {
            setSelectedExplorerItem(null);
        }
        return;
    }

    // Real file system logic
    if (item.path.endsWith('.plib')) {
        const entry = await getPlibData(item.path);
        setSelectedExplorerItem(entry);
    } else if (/\.(png|jpe?g|webp|gif)$/i.test(item.name || item.path)) {
        const imageUrl = await convertFileSrc(item.path);
        const mockEntry: PromptEntry = {
            prompt: item.name || item.path.split(/[\\/]/).pop() || 'Image',
            images: [imageUrl],
            generationInfo: {
                model: 'Image File',
                aspectRatio: 'N/A',
                timestamp: 'N/A', // Could use file modified date here later
                numberOfImages: 1,
            }
        };
        setSelectedExplorerItem(mockEntry);
    } else {
        setSelectedExplorerItem(null);
    }
  }, [isDemoMode]);

  const handleSelectItemByIndex = useCallback((index: number) => {
    // FIX: Check against the length of the processed (filtered and sorted) list.
    if (index >= 0 && index < processedFolderContents.length) {
      setSelectedItemIndex(index);
      const item = processedFolderContents[index];
      if (item) {
        handleSelectItem(item);
      }
    }
  }, [processedFolderContents, handleSelectItem]);

  const handleSelectItemAndSetIndex = useCallback((item: FsFileEntry, index: number) => {
    setSelectedItemIndex(index);
    handleSelectItem(item);
  }, [handleSelectItem]);
  
  const openLightbox = (entry: PromptEntry, index: number) => {
    setLightboxEntry(entry);
    setLightboxIndex(index);
    setLightboxOpen(true);
  };

  const closeLightbox = () => setLightboxOpen(false);
  const nextImage = () => {
    if (lightboxEntry && lightboxIndex < lightboxEntry.images.length - 1) {
      setLightboxIndex(lightboxIndex + 1);
    }
  };
  const prevImage = () => {
    if (lightboxIndex > 0) {
      setLightboxIndex(lightboxIndex - 1);
    }
  };
  
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
            isLoading={isLoadingFolder}
            thumbnailSize={thumbnailSize}
            onThumbnailSizeChange={setThumbnailSize}
            thumbnailsOnly={thumbnailsOnly}
            onThumbnailsOnlyChange={setThumbnailsOnly}
            onOpenFolder={handleOpenFolder}
            onSelectFolder={handleSelectFolder}
            onSelectItem={handleSelectItemAndSetIndex}
            onSelectItemByIndex={handleSelectItemByIndex}
            onOpenLightbox={(item, index) => openLightbox(item, index)}
            onStartDemo={handleStartDemoMode}
            onSelectFavorite={handleSelectFavorite}
            onMoveItem={handleMoveItem}
            isDemoMode={isDemoMode}
        />
      </main>

      {lightboxEntry && (
        <Lightbox
          isOpen={lightboxOpen}
          entry={lightboxEntry}
          currentIndex={lightboxIndex}
          onClose={closeLightbox}
          onNext={nextImage}
          onPrev={prevImage}
        />
      )}
    </div>
  );
};

export default App;