import React, { useState, useEffect, useCallback, useMemo } from 'react';
import Header from './components/Header';
import Lightbox from './components/Lightbox';
import Toast from './components/Toast';
import Explorer from './components/Explorer';
import AoeComparisonModal from './components/AoeComparisonModal';
import { renameEntry, deleteEntry, moveEntryToTrash, revealInFileManager } from './services/tauriService';
import { FsFileEntry, Breadcrumb } from './types';
import { useExplorer } from './hooks/useExplorer';
import { useSortFilter } from './hooks/useSortFilter';
import { useSelection } from './hooks/useSelection';
import { usePromptLoader } from './hooks/usePromptLoader';
import { isAoeFile, isPreviewableItem } from './utils/fileHelpers';
import { CompareIcon } from './components/icons';

const App: React.FC = () => {
  const [toast, setToast] = useState<{ message: string; type: 'success' | 'error' | 'info' } | null>(null);

  // Custom Hooks
  const {
    explorerRootPath,
    folderTree,
    selectedFolderPath,
    folderContents,
    isLoadingFolder,
    handleOpenFolder,
    handleSelectFolder,
    handleSelectFavorite,
    handleRefreshFolder,
    handleMoveItem,
    handleImportExternalFiles
  } = useExplorer();

  const {
    sortConfig,
    setSortConfig,
    filterConfig,
    setFilterConfig,
    searchQuery,
    setSearchQuery,
    processedFolderContents
  } = useSortFilter(folderContents);

  const {
    selectedExplorerItem,
    setSelectedExplorerItem,
    selectedItemIndex,
    setSelectedItemIndex,
    selectedIndices,
    setSelectedIndices,
    setSelectionAnchorIndex,
    handleItemClick,
    handleSelectItemByIndex
  } = useSelection(processedFolderContents);

  const { loadPromptEntryForItem } = usePromptLoader();

  // Local UI State
  const [thumbnailSize, setThumbnailSize] = useState(5);
  const [thumbnailsOnly, setThumbnailsOnly] = useState(false);
  const [lightboxOpen, setLightboxOpen] = useState(false);
  const [lightboxEntry, setLightboxEntry] = useState<any | null>(null);
  const [lightboxIndex, setLightboxIndex] = useState(0);
  const [lightboxPreviewIndex, setLightboxPreviewIndex] = useState<number>(-1);
  const [contextMenu, setContextMenu] = useState<{ x: number; y: number; item: FsFileEntry } | null>(null);
  const [renameState, setRenameState] = useState<{ item: FsFileEntry; value: string; originalName: string } | null>(null);
  const [deleteState, setDeleteState] = useState<{ item: FsFileEntry; mode: 'trash' | 'permanent' } | null>(null);
  const [dragSourcePath, setDragSourcePath] = useState<string | null>(null);
  const [comparisonSources, setComparisonSources] = useState<{ a: any; b: any } | null>(null);
  const [isComparisonOpen, setIsComparisonOpen] = useState(false);
  const [isComparisonLoading, setIsComparisonLoading] = useState(false);


  // --- Derived State ---
  const breadcrumbs = useMemo<Breadcrumb[]>(() => {
    if (!selectedFolderPath || !explorerRootPath) return [];

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
  }, [selectedFolderPath, explorerRootPath]);

  const parentBreadcrumb = useMemo(
    () => (breadcrumbs.length > 1 ? breadcrumbs[breadcrumbs.length - 2] : null),
    [breadcrumbs]
  );

  const selectedAoeItems = useMemo(
    () =>
      selectedIndices
        .map((idx) => processedFolderContents[idx])
        .filter(
          (item): item is FsFileEntry =>
            !!item && !item.children && isAoeFile((item.name || item.path).toLowerCase())
        ),
    [processedFolderContents, selectedIndices]
  );

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

  const hiddenItemCount = useMemo(() => folderContents.length - processedFolderContents.length, [folderContents, processedFolderContents]);

  // --- Global Event Listeners ---
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

  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement || lightboxOpen) {
        return;
      }
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'o') {
        e.preventDefault();
        handleOpenFolder();
      }
      const parentCrumb = breadcrumbs.length > 1 ? breadcrumbs[breadcrumbs.length - 2] : null;
      if (e.key === 'Backspace' && parentCrumb) {
        e.preventDefault();
        handleSelectFolder(parentCrumb.path);
      }
      if ((e.altKey && e.key === 'ArrowUp') && parentBreadcrumb) {
        e.preventDefault();
        handleSelectFolder(parentBreadcrumb.path); // Fix: use parentBreadcrumb derived state correctly
      }
      if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key.toLowerCase() === 'l') {
        e.preventDefault();
        setSearchQuery('');
        setFilterConfig({ hideJpg: false, hidePng: false, hideOther: true });
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [handleOpenFolder, handleSelectFolder, breadcrumbs, parentBreadcrumb, lightboxOpen, setSearchQuery, setFilterConfig]);

  useEffect(() => {
    let unlisten: (() => void) | null = null;
    const setupListener = async () => {
      if (typeof window === 'undefined' || !(window as unknown as { __TAURI_IPC__?: unknown }).__TAURI_IPC__) return;
      try {
        const { appWindow } = await import('@tauri-apps/api/window');
        unlisten = await appWindow.onFileDropEvent(async (event) => {
          if (event.payload?.type === 'drop' && Array.isArray(event.payload.paths) && event.payload.paths.length > 0) {
            try {
              const result = await handleImportExternalFiles(event.payload.paths);
              setToast({ message: `Imported ${result.count} files.`, type: 'success' });
            } catch (e) {
              setToast({ message: "Failed to import files.", type: 'error' });
            }
          }
        });
      } catch (error) {
        console.error('Failed to register file drop listener', error);
      }
    };
    setupListener();
    return () => { if (unlisten) unlisten(); };
  }, [handleImportExternalFiles]);

  const handleDragStartItem = useCallback((path: string) => setDragSourcePath(path), []);
  const handleDragEndItem = useCallback(() => setDragSourcePath(null), []);

  // Wrap handleMoveItem with toast feedback and selection clearing
  const handleMoveItemWithFeedback = useCallback(async (sourcePath: string, destinationDir: string) => {
    console.log('[App] handleMoveItemWithFeedback called:', { sourcePath, destinationDir });
    try {
      await handleMoveItem(sourcePath, destinationDir);
      // Clear selection after successful move
      setSelectedExplorerItem(null);
      setSelectedItemIndex(-1);
      setSelectedIndices([]);
      setSelectionAnchorIndex(null);
      setToast({ message: 'Item moved successfully.', type: 'success' });
    } catch (error) {
      console.error('[App] Move failed:', error);
      setToast({ message: 'Failed to move item.', type: 'error' });
    }
  }, [handleMoveItem, setSelectedExplorerItem, setSelectedItemIndex, setSelectedIndices, setSelectionAnchorIndex]);

  const handleItemContextMenu = useCallback((event: React.MouseEvent, item: FsFileEntry, _index?: number) => {
    event.preventDefault();
    setContextMenu({ x: event.clientX, y: event.clientY, item });
  }, []);

  useEffect(() => {
    setContextMenu(null);
    setRenameState(null);
    setDeleteState(null);
  }, [selectedFolderPath]);

  const handleRenameCancel = useCallback(() => {
    setRenameState(null);
  }, []);

  const handleRenameChange = useCallback((value: string) => {
    setRenameState(prev => (prev ? { ...prev, value } : prev));
  }, []);

  const handleRenameConfirm = useCallback(async () => {
    if (!renameState) return;
    const newName = renameState.value.trim();
    if (!newName) { setToast({ message: 'Name cannot be empty.', type: 'error' }); return; }
    if (/[\\/]/.test(newName)) { setToast({ message: 'Name cannot contain path separators.', type: 'error' }); return; }
    if (newName === renameState.originalName) { setRenameState(null); return; }

    try {
      await renameEntry(renameState.item.path, newName);
      setToast({ message: 'Item renamed successfully.', type: 'success' });
      setRenameState(null);
      setSelectedExplorerItem(null);
      setSelectedItemIndex(-1);
      setSelectedIndices([]);
      setSelectionAnchorIndex(null);
      await handleRefreshFolder();
    } catch (error) {
      console.error('Failed to rename item', error);
      setToast({ message: 'Failed to rename item.', type: 'error' });
    }
  }, [renameState, handleRefreshFolder, setSelectedExplorerItem, setSelectedItemIndex, setSelectedIndices, setSelectionAnchorIndex]);

  const handleDeleteCancel = useCallback(() => {
    setDeleteState(null);
  }, []);

  const handleDeleteConfirm = useCallback(async () => {
    if (!deleteState) return;
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
      await handleRefreshFolder();
    } catch (error) {
      setToast({ message: 'Failed to delete item.', type: 'error' });
    } finally {
      setDeleteState(null);
    }
  }, [deleteState, handleRefreshFolder, setSelectedExplorerItem, setSelectedItemIndex, setSelectedIndices, setSelectionAnchorIndex]);

  const handleOpenComparison = useCallback(async () => {
    if (selectedAoeItems.length < 2) {
      setToast({ message: 'Select two .aoe files to compare.', type: 'info' });
      return;
    }
    setIsComparisonLoading(true);
    try {
      const [first, second] = selectedAoeItems.slice(0, 2);
      const [entryA, entryB] = await Promise.all([loadPromptEntryForItem(first), loadPromptEntryForItem(second)]);
      if (!entryA || !entryB) {
        setToast({ message: 'Unable to load both .aoe files.', type: 'error' });
        return;
      }
      setComparisonSources({ a: entryA, b: entryB });
      setIsComparisonOpen(true);
    } catch (error) {
      setToast({ message: 'Failed to open comparison.', type: 'error' });
    } finally {
      setIsComparisonLoading(false);
    }
  }, [selectedAoeItems, loadPromptEntryForItem]);

  const handleCloseComparison = useCallback(() => {
    setIsComparisonOpen(false);
    setComparisonSources(null);
  }, []);

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
  }, [previewableItems, loadPromptEntryForItem, setSelectedExplorerItem, setSelectedIndices, setSelectionAnchorIndex, setSelectedItemIndex]);

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
        parentCrumb={parentBreadcrumb}
        onNavigate={handleSelectFolder}
        sortConfig={sortConfig}
        onSortChange={setSortConfig}
        searchQuery={searchQuery}
        onSearchChange={setSearchQuery}
        filterConfig={filterConfig}
        onFilterChange={setFilterConfig}
        isFolderOpen={!!explorerRootPath}
        onChangeFolder={handleOpenFolder}
        onRefreshFolder={handleRefreshFolder}
        isLoadingFolder={isLoadingFolder}
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
          onSelectFavorite={handleSelectFavorite}
          onMoveItem={handleMoveItemWithFeedback}
          onItemContextMenu={handleItemContextMenu}
          dragSourcePath={dragSourcePath}
          onDragStartItem={handleDragStartItem}
          onDragEndItem={handleDragEndItem}
        />
      </main>

      {selectedAoeItems.length >= 2 && (
        <div className="fixed bottom-6 right-6 z-30">
          <div className="flex items-center gap-3 px-4 py-3 rounded-xl border border-fuchsia-500/40 bg-zinc-900/90 shadow-xl shadow-fuchsia-500/20 backdrop-blur">
            <div className="flex items-center justify-center w-10 h-10 rounded-lg bg-fuchsia-500/15 border border-fuchsia-500/30">
              <CompareIcon className="w-5 h-5 text-fuchsia-300" />
            </div>
            <div className="text-sm">
              <div className="font-semibold text-white">Compare .aoe snapshots</div>
              <div className="text-zinc-400 text-xs">Uses the first two selected files.</div>
            </div>
            <button
              onClick={handleOpenComparison}
              disabled={isComparisonLoading}
              className="px-3 py-2 rounded-md bg-fuchsia-600 hover:bg-fuchsia-500 disabled:opacity-60 disabled:cursor-not-allowed text-sm font-semibold text-white transition-colors"
            >
              {isComparisonLoading ? 'Loading…' : 'Open'}
            </button>
          </div>
        </div>
      )}

      {comparisonSources && isComparisonOpen && (
        <AoeComparisonModal
          sourceA={comparisonSources.a}
          sourceB={comparisonSources.b}
          onClose={handleCloseComparison}
        />
      )}

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
                className={`flex-1 px-4 py-3 rounded-md border text-sm font-semibold transition ${deleteState.mode === 'trash'
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
                className={`flex-1 px-4 py-3 rounded-md border text-sm font-semibold transition ${deleteState.mode === 'permanent'
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
                className={`px-4 py-2 rounded-md ${deleteState.mode === 'trash'
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
