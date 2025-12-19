import React, { useState, useEffect } from 'react';
import ImageDisplay from './ImageDisplay';
import { BrandLogo, FolderIcon, FileIcon, PicturesIcon } from './icons';
import { getPlibData } from '../services/plibService';
import { convertFileSrc, getBasename } from '../services/tauriService';
import { getDemoPlibFile, getDemoImageEntry } from '../services/demoService';
import { extractDragSourcePath, setActiveDragSource } from '../utils/drag';
import { getCachedThumbnail } from '../services/thumbnailCache';
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
    const itemLabel = item.name || item.path.split(/[\\/]/).pop() || '';
    const lowerName = itemLabel.toLowerCase();
    const itemType = isFolder ? 'folder' : isPlibAsset(lowerName) ? 'plib' : isImageAsset(lowerName) ? 'image' : 'file';

    useEffect(() => {
        let isCancelled = false;
        
        const loadItem = async () => {
            const itemName = item.name || (isDemoMode ? item.path.split('/').pop() : await getBasename(item.path));
            if (isCancelled) return;
            setTitle(itemName || '');
            const cached = getCachedThumbnail(item.path);
            if (cached) {
                setThumbnailSrc(cached);
                return;
            }

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

    const tryAttachFileBlob = async (dt: DataTransfer, path: string, name: string) => {
        // Attach an actual File object when possible so external drops (e.g., browser upload areas) receive real file data.
        try {
            const fileUrl = await convertFileSrc(path);
            const response = await fetch(fileUrl);
            if (!response.ok) return;
            const blob = await response.blob();
            const file = new File([blob], name, { type: blob.type || 'application/octet-stream' });
            dt.items.add(file);
        } catch (error) {
            console.error('Failed to attach file blob to drag payload', error);
        }
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
        dataTransfer.effectAllowed = 'copyMove';
        dataTransfer.setData('text/plain', primaryPath);
        dataTransfer.setData('text/uri-list', uriList);
        dataTransfer.setData('application/json', JSON.stringify({ path: primaryPath, paths: dragPaths }));
        dataTransfer.setData('application/x-plib-entry', primaryPath);
        const primaryName = item.name || primaryPath.split(/[\\/]/).pop() || 'file';
        dataTransfer.setData('DownloadURL', `application/octet-stream:${primaryName}:${toFileUri(primaryPath)}`);
        if (!isDemoMode && !isFolder && primaryPath) {
            void tryAttachFileBlob(dataTransfer, primaryPath, primaryName);
        }
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

    const renderTypeBadge = () => {
        switch (itemType) {
            case 'plib':
                return <BrandLogo className="w-4 h-4 text-fuchsia-200" />;
            case 'image':
                return <PicturesIcon className="w-4 h-4" />;
            default:
                return <FileIcon className="w-4 h-4" />;
        }
    };

    const showTypeBadge = itemType !== 'folder';

    const badgeColor =
        itemType === 'plib'
            ? 'bg-fuchsia-500/80 border-fuchsia-200/40 text-white'
            : itemType === 'image'
            ? 'bg-sky-500/80 border-sky-200/40 text-white'
            : 'bg-zinc-700/80 border-zinc-200/30 text-white';

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
            <div className={`relative aspect-square rounded-lg overflow-hidden bg-zinc-800 border border-zinc-700/50 group-hover:border-zinc-600 transition-all duration-200 ${dropHighlightClasses}`}>
                {renderThumbnail()}
                {showTypeBadge && (
                    <div className={`absolute bottom-1 right-1 inline-flex items-center justify-center rounded-md border shadow-sm backdrop-blur-sm px-1.5 py-1 ${badgeColor}`}>
                        {renderTypeBadge()}
                    </div>
                )}
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
