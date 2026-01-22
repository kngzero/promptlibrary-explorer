import React from 'react';
import FileTree from './FileTree';
import ContentBrowser from './ContentBrowser';
import MetadataPanel from './MetadataPanel';
import InfoBar from './InfoBar';
// FIX: Import FolderIcon to be used when no folder is open.
import { OpenIcon, FolderIcon, ChevronLeftIcon, ChevronRightIcon } from './icons';
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
    onSelectFavorite: (favorite: 'desktop' | 'documents' | 'pictures') => void;
    onMoveItem: (sourcePath: string, destinationDir: string) => void;
    onItemContextMenu: (event: React.MouseEvent, item: FsFileEntry, index: number) => void;
    dragSourcePath: string | null;
    onDragStartItem: (path: string) => void;
    onDragEndItem: () => void;
    onReorderItems?: (sourcePaths: string[], targetPath: string) => void;
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
    onSelectFavorite,
    onMoveItem,
    onItemContextMenu,
    dragSourcePath,
    onDragStartItem,
    onDragEndItem,
    onReorderItems,
}) => {
    const [isFoldersCollapsed, setIsFoldersCollapsed] = React.useState(false);
    const [isDetailsCollapsed, setIsDetailsCollapsed] = React.useState(false);
    
    if (!rootPath) {
        return (
            <div className="flex-grow flex flex-col items-center justify-center text-center p-8">
                <div className="w-24 h-24 flex items-center justify-center bg-zinc-800 rounded-full mb-6">
                    <FolderIcon className="w-12 h-12 text-zinc-500" />
                </div>
                <h2 className="text-2xl font-bold text-white">Open a Folder to Begin</h2>
                <p className="mt-2 text-zinc-400 max-w-sm">
                    Select a folder on your computer containing your `.plib` or `.aoe` files and images to start browsing your creative library.
                </p>
                <button
                    onClick={onOpenFolder}
                    className="mt-8 inline-flex items-center justify-center px-6 py-3 border border-transparent text-base font-medium rounded-md shadow-sm text-white bg-fuchsia-600 hover:bg-fuchsia-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-offset-zinc-900 focus:ring-fuchsia-500"
                >
                    <OpenIcon className="h-5 w-5 mr-3" />
                    Open Folder
                </button>
            </div>
        );
    }

    return (
        <div className="flex-grow flex h-full overflow-hidden">
            <div
                className={`relative h-full border-r border-zinc-700/50 flex-shrink-0 overflow-hidden transition-[width] duration-300 ease-in-out ${
                    isFoldersCollapsed ? 'w-12' : 'w-64'
                }`}
            >
                <button
                    type="button"
                    onClick={() => setIsFoldersCollapsed((prev) => !prev)}
                    className="absolute top-4 -right-3 z-20 h-6 w-6 rounded-full border border-zinc-700 bg-zinc-900 text-zinc-300 shadow-sm transition hover:bg-zinc-800 hover:text-white"
                    aria-label={isFoldersCollapsed ? 'Expand folders panel' : 'Collapse folders panel'}
                    title={isFoldersCollapsed ? 'Expand folders panel' : 'Collapse folders panel'}
                >
                    {isFoldersCollapsed ? (
                        <ChevronRightIcon className="h-4 w-4 mx-auto" />
                    ) : (
                        <ChevronLeftIcon className="h-4 w-4 mx-auto" />
                    )}
                </button>
                <div
                    className={`h-full transition-opacity duration-200 ${
                        isFoldersCollapsed ? 'pointer-events-none opacity-0' : 'opacity-100'
                    }`}
                >
                    <FileTree
                        rootPath={rootPath}
                        folderTree={folderTree}
                        selectedPath={selectedFolderPath}
                        onSelect={onSelectFolder}
                        onSelectFavorite={onSelectFavorite}
                        onMoveItem={onMoveItem}
                        isDragActive={!!dragSourcePath}
                    />
                </div>
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
                    selectedItemIndex={selectedItemIndex}
                    selectedIndices={selectedIndices}
                    onSelectItemByIndex={onSelectItemByIndex}
                    thumbnailSize={thumbnailSize}
                    thumbnailsOnly={thumbnailsOnly}
                    onItemContextMenu={onItemContextMenu}
                    dragSourcePath={dragSourcePath}
                    onDragStartItem={onDragStartItem}
                    onDragEndItem={onDragEndItem}
                    onReorderItems={onReorderItems}
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
            <div
                className={`relative h-full border-l border-zinc-700/50 flex-shrink-0 overflow-hidden transition-[width] duration-300 ease-in-out ${
                    isDetailsCollapsed ? 'w-12' : 'w-96'
                }`}
            >
                <button
                    type="button"
                    onClick={() => setIsDetailsCollapsed((prev) => !prev)}
                    className="absolute top-4 -left-3 z-20 h-6 w-6 rounded-full border border-zinc-700 bg-zinc-900 text-zinc-300 shadow-sm transition hover:bg-zinc-800 hover:text-white"
                    aria-label={isDetailsCollapsed ? 'Expand details panel' : 'Collapse details panel'}
                    title={isDetailsCollapsed ? 'Expand details panel' : 'Collapse details panel'}
                >
                    {isDetailsCollapsed ? (
                        <ChevronLeftIcon className="h-4 w-4 mx-auto" />
                    ) : (
                        <ChevronRightIcon className="h-4 w-4 mx-auto" />
                    )}
                </button>
                <div
                    className={`h-full transition-opacity duration-200 ${
                        isDetailsCollapsed ? 'pointer-events-none opacity-0' : 'opacity-100'
                    }`}
                >
                    <MetadataPanel item={selectedItem} />
                </div>
            </div>
        </div>
    );
};

export default Explorer;
