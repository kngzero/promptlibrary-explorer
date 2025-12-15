import React, { useState, useEffect } from 'react';
import ImageDisplay from './ImageDisplay';
import { FolderIcon, FileIcon } from './icons';
import { getPlibData } from '../services/plibService';
import { convertFileSrc, getBasename } from '../services/tauriService';
import { getDemoPlibFile, getDemoImageEntry } from '../services/demoService';
import { extractDragSourcePath, setActiveDragSource } from '../utils/drag';
import type { FsFileEntry } from '../types';

interface ExplorerItemProps {
    item: FsFileEntry;
    onSelect: (event: React.MouseEvent<HTMLDivElement>) => void;
    onDoubleClick: (item: FsFileEntry) => void;
    onOpenLightbox: () => void;
    onMoveItem: (sourcePath: string, destinationDir: string) => void;
    isDemoMode: boolean;
    isFocused: boolean;
    isSelected: boolean;
    thumbnailsOnly: boolean;
    onContextMenu?: (event: React.MouseEvent<HTMLDivElement>) => void;
    isDragActive: boolean;
    onDragStartFile: (path: string) => void;
    onDragEndFile: () => void;
    selectedPaths: string[];
}

const isImageAsset = (filename: string) => /\.(png|jpe?g|webp|gif)$/i.test(filename);
const isPlibAsset = (filename: string) => /\.plib$/i.test(filename);

const ExplorerItem: React.FC<ExplorerItemProps> = ({ item, onSelect, onDoubleClick, onOpenLightbox, onMoveItem, isDemoMode, isFocused, isSelected, thumbnailsOnly, onContextMenu, isDragActive, onDragStartFile, onDragEndFile, selectedPaths }) => {
    const [thumbnailSrc, setThumbnailSrc] = useState<string | null>(null);
    const [title, setTitle] = useState(item.name || 'Loading...');
    const [isDragging, setIsDragging] = useState(false);
    const [isDraggingOver, setIsDraggingOver] = useState(false);
    
    const isFolder = !!item.children;
    const canDrag = !isFolder && !isDemoMode;

    useEffect(() => {
        let isCancelled = false;
        
        const loadItem = async () => {
            const itemName = item.name || (isDemoMode ? item.path.split('/').pop() : await getBasename(item.path));
            if (isCancelled) return;
            setTitle(itemName || '');
            
            if (isFolder) { // Is directory
                setThumbnailSrc('dir');
                return;
            }

            if (isDemoMode) {
                if (isPlibAsset(itemName || '')) {
                    const data = getDemoPlibFile(item.path);
                    if (data?.images?.[0]) setThumbnailSrc(data.images[0]);
                    else setThumbnailSrc('file');
                } else if (isImageAsset(itemName || '')) {
                    const data = getDemoImageEntry(item.path);
                    setThumbnailSrc(data.images[0]);
                } else {
                    setThumbnailSrc('file');
                }
                return;
            }

            // --- Real filesystem logic ---
            if (isPlibAsset(itemName || '')) {
                const data = await getPlibData(item.path);
                if (!isCancelled && data?.images?.[0]) {
                    const first = data.images[0];
                    // NEW: convert local file paths for Tauri
                    const src =
                        typeof first === 'string' && !first.startsWith('data:') && !/^https?:\/\//i.test(first)
                        ? await convertFileSrc(first)
                        : first;
                    setThumbnailSrc(src);
                } else {
                    setThumbnailSrc('file');
                }
            } else if (isImageAsset(itemName || '')) {
                const src = await convertFileSrc(item.path); // already correct
                if (!isCancelled) setThumbnailSrc(src);
            } else {
                setThumbnailSrc('file');
            }
        };

        loadItem();
        
        return () => { isCancelled = true; };
    }, [item, isDemoMode, isFolder]);
    
    const handleDoubleClick = () => {
        if (item.children) {
            onDoubleClick(item);
            return;
        }

        const itemName = (item.name || item.path).toLowerCase();
        if (isPlibAsset(itemName) || isImageAsset(itemName)) {
            onOpenLightbox();
        }
    };
    
    // --- Drag and Drop Handlers ---
    const toFileUri = (path: string) => {
        const normalized = path.replace(/\\/g, '/');
        return `file://${encodeURI(normalized)}`;
    };

    const handleDragStart = (e: React.DragEvent<HTMLDivElement>) => {
        if (!canDrag) {
            e.preventDefault();
            return;
        }
        const dragPaths =
            selectedPaths.includes(item.path) && selectedPaths.length > 0
                ? selectedPaths
                : [item.path];
        const primaryPath = dragPaths[0];
        setIsDragging(true);
        setActiveDragSource(primaryPath);
        onDragStartFile(primaryPath);
        const { dataTransfer } = e;
        const uriList = dragPaths.map(toFileUri).join('\n');
        dataTransfer.setData('text/plain', primaryPath);
        dataTransfer.setData('text/uri-list', uriList);
        dataTransfer.setData('application/json', JSON.stringify({ path: primaryPath, paths: dragPaths }));
        dataTransfer.setData('application/x-plib-entry', primaryPath);
        const primaryName = item.name || primaryPath.split(/[\\/]/).pop() || 'file';
        dataTransfer.setData('DownloadURL', `application/octet-stream:${primaryName}:${toFileUri(primaryPath)}`);
        dataTransfer.effectAllowed = 'copyMove';
    };

    const handleDragEnd = () => {
        setIsDragging(false);
        setActiveDragSource(null);
        onDragEndFile();
    };
    
    const handleDragOver = (e: React.DragEvent<HTMLDivElement>) => {
        if (!isFolder || isDemoMode) return;
        e.preventDefault();
        e.dataTransfer.dropEffect = 'move';
    };

    const handleDragEnter = (e: React.DragEvent<HTMLDivElement>) => {
        if (!isFolder || isDemoMode) return;
        e.preventDefault();
        setIsDraggingOver(true);
    };

    const handleDragLeave = (e: React.DragEvent<HTMLDivElement>) => {
        if (!isFolder || isDemoMode) return;
        e.preventDefault();
        setIsDraggingOver(false);
    };

    const handleDrop = (e: React.DragEvent<HTMLDivElement>) => {
        if (!isFolder || isDemoMode) return;
        e.preventDefault();
        setIsDraggingOver(false);
        const sourcePath = extractDragSourcePath(e.dataTransfer);
        if (sourcePath && item.path !== sourcePath) {
            onMoveItem(sourcePath, item.path);
        }
        setActiveDragSource(null);
        setIsDragging(false);
        onDragEndFile();
    };

    const renderThumbnail = () => {
        if (thumbnailSrc === 'dir') {
            return (
                <div className="w-full h-full flex items-center justify-center bg-zinc-800 text-fuchsia-400/50">
                    <FolderIcon className="w-1/2 h-1/2" />
                </div>
            );
        }
        if (thumbnailSrc === 'file') {
             return (
                <div className="w-full h-full flex items-center justify-center bg-zinc-800 text-zinc-500">
                    <FileIcon className="w-1/2 h-1/2" />
                </div>
            );
        }
        if (thumbnailSrc) {
            return (
                <ImageDisplay
                    src={thumbnailSrc}
                    alt={title}
                    containerClassName="w-full h-full"
                    className="w-full h-full object-cover group-hover:scale-105 transition-transform duration-200"
                />
            );
        }
        // Loading state
        return <div className="w-full h-full bg-zinc-800 animate-pulse"></div>;
    };

    const selectionClasses = isSelected ? 'ring-2 ring-fuchsia-500 ring-offset-2 ring-offset-zinc-900 bg-zinc-800/70' : '';
    const focusClasses = !isSelected && isFocused ? 'ring-2 ring-fuchsia-400 ring-offset-2 ring-offset-zinc-900' : '';
    const draggingClasses = isDragging ? 'ring-2 ring-fuchsia-400 ring-offset-2 ring-offset-zinc-900 opacity-80 scale-[0.98]' : '';
    const dropReady = isDragActive && isFolder;
    const dropHighlightClasses = isDraggingOver
        ? 'border-fuchsia-400 bg-fuchsia-500/10 shadow-inner shadow-fuchsia-500/40'
        : dropReady
        ? 'border-dashed border-zinc-600 bg-zinc-800/60'
        : '';
    const labelColor = isSelected ? 'text-white' : 'text-zinc-300';

    return (
        <div
            data-draggable-item={canDrag ? 'true' : undefined}
            draggable={canDrag}
            onDragStart={handleDragStart}
            onDragEnd={handleDragEnd}
            onDragOver={handleDragOver}
            onDragEnter={handleDragEnter}
            onDragLeave={handleDragLeave}
            onDrop={handleDrop}
            onClick={onSelect}
            onDoubleClick={handleDoubleClick}
            onContextMenu={(event) => {
                if (onContextMenu) {
                    onContextMenu(event);
                }
            }}
            className={`text-left group cursor-pointer focus:outline-none rounded-lg transition-all duration-200 select-none ${selectionClasses} ${focusClasses} ${draggingClasses}`}
            tabIndex={-1}
        >
            <div className={`aspect-square rounded-lg overflow-hidden bg-zinc-800 border border-zinc-700/50 group-hover:border-zinc-600 transition-all duration-200 ${dropHighlightClasses}`}>
                {renderThumbnail()}
            </div>
            {!thumbnailsOnly && (
                 <p className={`text-sm mt-2 truncate group-hover:text-white ${labelColor}`} title={title}>
                    {title}
                </p>
            )}
        </div>
    );
};

export default ExplorerItem;
