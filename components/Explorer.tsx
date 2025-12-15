import React from 'react';
import FileTree from './FileTree';
import ContentBrowser from './ContentBrowser';
import MetadataPanel from './MetadataPanel';
import InfoBar from './InfoBar';
// FIX: Import FolderIcon to be used when no folder is open.
import { OpenIcon, FolderIcon } from './icons';
import type { PromptEntry, FsFileEntry } from '../types';

interface ExplorerProps {
    rootPath: string | null;
    folderTree: FsFileEntry[];
    selectedFolderPath: string | null;
    folderContents: FsFileEntry[];
    hiddenItemCount: number;
    selectedItem: PromptEntry | null;
    selectedItemIndex: number;
    selectedIndices: number[];
    isLoading: boolean;
    thumbnailSize: number;
    onThumbnailSizeChange: (size: number) => void;
    thumbnailsOnly: boolean;
    onThumbnailsOnlyChange: (checked: boolean) => void;
    onOpenFolder: () => void;
    onSelectFolder: (path: string) => void;
    onSelectItem: (item: FsFileEntry, index: number, event?: React.MouseEvent) => void;
    onSelectItemByIndex: (index: number) => void;
    onOpenLightbox: (folderIndex: number) => void;
    onStartDemo: () => void;
    onSelectFavorite: (favorite: 'desktop' | 'documents' | 'pictures') => void;
    onMoveItem: (sourcePath: string, destinationDir: string) => void;
    isDemoMode: boolean;
    onItemContextMenu: (event: React.MouseEvent, item: FsFileEntry, index: number) => void;
    dragSourcePath: string | null;
    onDragStartItem: (path: string) => void;
    onDragEndItem: () => void;
}

const Explorer: React.FC<ExplorerProps> = ({
    rootPath,
    folderTree,
    selectedFolderPath,
    folderContents,
    hiddenItemCount,
    selectedItem,
    selectedItemIndex,
    selectedIndices,
    isLoading,
    thumbnailSize,
    onThumbnailSizeChange,
    thumbnailsOnly,
    onThumbnailsOnlyChange,
    onOpenFolder,
    onSelectFolder,
    onSelectItem,
    onSelectItemByIndex,
    onOpenLightbox,
    onStartDemo,
    onSelectFavorite,
    onMoveItem,
    isDemoMode,
    onItemContextMenu,
    dragSourcePath,
    onDragStartItem,
    onDragEndItem,
}) => {
    
    if (!rootPath) {
        return (
            <div className="flex-grow flex flex-col items-center justify-center text-center p-8">
                <div className="w-24 h-24 flex items-center justify-center bg-zinc-800 rounded-full mb-6">
                    <FolderIcon className="w-12 h-12 text-zinc-500" />
                </div>
                <h2 className="text-2xl font-bold text-white">Open a Folder to Begin</h2>
                <p className="mt-2 text-zinc-400 max-w-sm">
                    Select a folder on your computer containing your `.plib` files and images to start browsing your creative library.
                </p>
                <div className="flex flex-col items-center mt-8 space-y-4">
                    <button
                        onClick={onOpenFolder}
                        className="inline-flex items-center justify-center px-6 py-3 border border-transparent text-base font-medium rounded-md shadow-sm text-white bg-fuchsia-600 hover:bg-fuchsia-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-offset-zinc-900 focus:ring-fuchsia-500"
                    >
                        <OpenIcon className="h-5 w-5 mr-3" />
                        Open Folder
                    </button>
                    <div className="text-center">
                        <button
                            onClick={onStartDemo}
                            className="text-sm text-fuchsia-400 hover:text-fuchsia-300 hover:underline"
                        >
                            Or, try a demo
                        </button>
                        <p className="text-xs text-zinc-500 mt-1">No files on your computer will be used.</p>
                    </div>
                </div>
            </div>
        );
    }

    return (
        <div className="flex-grow flex h-full overflow-hidden">
            <div className="w-64 h-full border-r border-zinc-700/50 flex-shrink-0">
                <FileTree
                    rootPath={rootPath}
                    folderTree={folderTree}
                    selectedPath={selectedFolderPath}
                    onSelect={onSelectFolder}
                    onSelectFavorite={onSelectFavorite}
                    onMoveItem={onMoveItem}
                    isDemoMode={isDemoMode}
                    isDragActive={!!dragSourcePath}
                />
            </div>
            <div className="flex-grow h-full flex flex-col bg-zinc-900">
                <ContentBrowser
                    key={selectedFolderPath} // Force re-render on path change
                    items={folderContents}
                    isLoading={isLoading}
                    onSelectItem={onSelectItem}
                    onNavigate={onSelectFolder}
                    onOpenLightbox={onOpenLightbox}
                    onMoveItem={onMoveItem}
                    isDemoMode={isDemoMode}
                    selectedItemIndex={selectedItemIndex}
                    selectedIndices={selectedIndices}
                    onSelectItemByIndex={onSelectItemByIndex}
                    thumbnailSize={thumbnailSize}
                    thumbnailsOnly={thumbnailsOnly}
                    onItemContextMenu={onItemContextMenu}
                    dragSourcePath={dragSourcePath}
                    onDragStartItem={onDragStartItem}
                    onDragEndItem={onDragEndItem}
                />
                <InfoBar
                    shownCount={folderContents.length}
                    hiddenCount={hiddenItemCount}
                    thumbnailSize={thumbnailSize}
                    onThumbnailSizeChange={onThumbnailSizeChange}
                    thumbnailsOnly={thumbnailsOnly}
                    onThumbnailsOnlyChange={onThumbnailsOnlyChange}
                />
            </div>
            <div className="w-96 h-full border-l border-zinc-700/50 flex-shrink-0">
                <MetadataPanel item={selectedItem} />
            </div>
        </div>
    );
};

export default Explorer;
