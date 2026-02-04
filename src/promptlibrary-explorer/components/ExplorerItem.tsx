import React, { useState, useEffect, useRef } from 'react';
import ImageDisplay from './ImageDisplay';
import { BrandLogo, FolderIcon, FileIcon, PicturesIcon } from './icons';
import { getAoeData } from '../services/aoeService';
import { getPlibData } from '../services/plibService';
import { convertFileSrc, getBasename } from '../services/tauriService';
import { extractDragSourcePath, extractDragSourcePaths, setActiveDragSource, toFileUri } from '../utils/drag';
import { getCachedThumbnail, setCachedThumbnail, generateAndCacheThumbnail } from '../services/thumbnailCache';
import { isImageFile, isPromptSnapshotFile, isAoeFile } from '../utils/fileHelpers';
import type { FsFileEntry } from '../types';

interface ExplorerItemProps {
    item: FsFileEntry;
    onSelect: (event: React.MouseEvent<HTMLDivElement>) => void;
    onDoubleClick: (item: FsFileEntry) => void;
    onOpenLightbox: () => void;
    onMoveItem: (sourcePath: string, destinationDir: string) => void;
    isFocused: boolean;
    isSelected: boolean;
    thumbnailsOnly: boolean;
    onContextMenu?: (event: React.MouseEvent<HTMLDivElement>) => void;
    isDragActive: boolean;
    dragSourcePath: string | null;
    onDragStartFile: (path: string) => void;
    onDragEndFile: () => void;
    selectedPaths: string[];
    onReorderItems?: (sourcePaths: string[], targetPath: string, position: 'before' | 'after') => void;
}

const fileSrcCache = new Map<string, string>();

const ExplorerItem: React.FC<ExplorerItemProps> = ({ item, onSelect, onDoubleClick, onOpenLightbox, onMoveItem, isFocused, isSelected, thumbnailsOnly, onContextMenu, isDragActive, dragSourcePath, onDragStartFile, onDragEndFile, selectedPaths, onReorderItems }) => {
    const [thumbnailSrc, setThumbnailSrc] = useState<string | null>(null);
    const [title, setTitle] = useState(item.name || 'Loading...');
    const [isDragging, setIsDragging] = useState(false);
    const [isDraggingOver, setIsDraggingOver] = useState(false);
    const [dropPosition, setDropPosition] = useState<'before' | 'after' | null>(null);
    const dragDepthRef = useRef(0);

    const isFolder = !!item.children;
    const canDrag = !isFolder;
    const canReorder = !!onReorderItems;
    const itemLabel = item.name || item.path.split(/[\\/]/).pop() || '';
    const lowerName = itemLabel.toLowerCase();
    const itemType = isFolder ? 'folder' : isPromptSnapshotFile(lowerName) ? 'prompt' : isImageFile(lowerName) ? 'image' : 'file';
    const promptVariant = !isFolder && isPromptSnapshotFile(lowerName) ? (isAoeFile(lowerName) ? 'aoe' : 'plib') : null;

    useEffect(() => {
        let isCancelled = false;

        const loadItem = async () => {
            const itemName = item.name || (await getBasename(item.path));
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

            // --- Real filesystem logic ---
            if (isPromptSnapshotFile(itemName || '')) {
                const data = isAoeFile(itemName || '') ? await getAoeData(item.path) : await getPlibData(item.path);
                if (!isCancelled && data?.images?.[0]) {
                    const first = data.images[0];
                    const isBase64 = typeof first === 'string' && /^[A-Za-z0-9+/=\s]+$/.test(first) && first.length > 100;
                    let src = first;
                    if (typeof first === 'string' && !first.startsWith('data:') && !/^https?:\/\//i.test(first)) {
                        if (isBase64) {
                            src = `data:image/png;base64,${first.replace(/\s+/g, '')}`;
                        } else {
                            // For prompt snapshots, we usually don't cache the thumbnail on disk 
                            // because they are often base64 or small embedded images
                            if (fileSrcCache.has(first)) {
                                src = fileSrcCache.get(first) as string;
                            } else {
                                src = await convertFileSrc(first);
                                fileSrcCache.set(first, src);
                            }
                        }
                    }
                    setThumbnailSrc(src);
                    setCachedThumbnail(item.path, src);
                } else {
                    setThumbnailSrc('file');
                }
            } else if (isImageFile(itemName || '')) {
                // Try disk cache for images
                const cachePath = await generateAndCacheThumbnail(item.path);
                if (!isCancelled && cachePath) {
                    const src = await convertFileSrc(cachePath);
                    if (!isCancelled) {
                        setThumbnailSrc(src);
                        setCachedThumbnail(item.path, src);
                    }
                } else if (!isCancelled) {
                    // Fallback to original image if cache fails
                    let src: string;
                    if (fileSrcCache.has(item.path)) {
                        src = fileSrcCache.get(item.path) as string;
                    } else {
                        src = await convertFileSrc(item.path);
                        fileSrcCache.set(item.path, src);
                    }
                    if (!isCancelled) {
                        setThumbnailSrc(src);
                        setCachedThumbnail(item.path, src);
                    }
                }
            } else {
                setThumbnailSrc('file');
            }
        };

        loadItem();

        return () => { isCancelled = true; };
    }, [item, isFolder]);

    useEffect(() => {
        if (isDragActive) return;
        dragDepthRef.current = 0;
        setIsDraggingOver(false);
        setDropPosition(null);
    }, [isDragActive]);

    const handleDoubleClick = () => {
        if (item.children) {
            onDoubleClick(item);
            return;
        }

        const itemName = (item.name || item.path).toLowerCase();
        if (isPromptSnapshotFile(itemName) || isImageFile(itemName)) {
            onOpenLightbox();
        }
    };

    // --- Drag and Drop Handlers ---

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
        console.log('[ExplorerItem] dragStart:', { canDrag, itemName: item.name, itemPath: item.path });
        if (!canDrag) {
            e.preventDefault();
            return;
        }
        const safeSetDragData = (type: string, value: string) => {
            try {
                e.dataTransfer.setData(type, value);
            } catch (error) {
                // WebView engines differ in which custom mime types they accept.
                console.debug('[ExplorerItem] Unsupported drag payload type:', type, error);
            }
        };
        const dragPaths =
            selectedPaths.includes(item.path) && selectedPaths.length > 0
                ? selectedPaths
                : [item.path];
        const primaryPath = dragPaths[0];
        setIsDragging(true);
        setActiveDragSource(primaryPath);
        onDragStartFile(primaryPath);
        const { dataTransfer } = e;
        dataTransfer.effectAllowed = 'copyMove';
        try {
            // Keep the drag preview consistent no matter which child was the pointer-down target.
            dataTransfer.setDragImage(e.currentTarget, 24, 24);
        } catch {
            // Ignore WebView engines that don't support setDragImage consistently.
        }
        const uriList = dragPaths.map(toFileUri).join('\n');
        safeSetDragData('text/plain', primaryPath);
        safeSetDragData('text/uri-list', uriList);
        safeSetDragData('application/json', JSON.stringify({ path: primaryPath, paths: dragPaths }));
        safeSetDragData('application/x-plib-entry', primaryPath);
        const primaryName = item.name || primaryPath.split(/[\\/]/).pop() || 'file';
        safeSetDragData('DownloadURL', `application/octet-stream:${primaryName}:${toFileUri(primaryPath)}`);
        if (!isFolder && primaryPath) {
            void tryAttachFileBlob(dataTransfer, primaryPath, primaryName);
        }
    };

    const handleDragEnd = () => {
        setIsDragging(false);
        window.setTimeout(() => {
            setActiveDragSource(null);
            onDragEndFile();
        }, 120);
    };

    const handleDragOver = (e: React.DragEvent<HTMLDivElement>) => {
        if (!isFolder && !canReorder) return;
        e.preventDefault();
        e.stopPropagation();
        e.dataTransfer.dropEffect = 'move';
        setIsDraggingOver(true);

        // Calculate drop position for reordering
        if (canReorder && !isFolder) {
            const rect = e.currentTarget.getBoundingClientRect();
            const midY = rect.top + rect.height / 2;
            setDropPosition(e.clientY < midY ? 'before' : 'after');
        }

        if (isFolder && Math.random() < 0.05) {
            console.log('[ExplorerItem] dragOver on folder:', item.name);
        }
    };

    const handleDragEnter = (e: React.DragEvent<HTMLDivElement>) => {
        if (!isFolder && !canReorder) return;
        e.preventDefault();
        e.stopPropagation();
        dragDepthRef.current += 1;
        if (isFolder) {
            console.log('[ExplorerItem] dragEnter on folder:', item.name);
        }
        setIsDraggingOver(true);
    };

    const handleDragLeave = (e: React.DragEvent<HTMLDivElement>) => {
        if (!isFolder && !canReorder) return;
        e.preventDefault();
        e.stopPropagation();
        dragDepthRef.current = Math.max(0, dragDepthRef.current - 1);
        if (dragDepthRef.current > 0) {
            return;
        }
        if (isFolder) {
            console.log('[ExplorerItem] dragLeave on folder:', item.name);
        }
        setIsDraggingOver(false);
        setDropPosition(null);
    };

    const handleDrop = (e: React.DragEvent<HTMLDivElement>) => {
        console.log('[ExplorerItem] handleDrop called', { isFolder, itemPath: item.path, itemName: item.name });
        e.preventDefault();
        e.stopPropagation();
        dragDepthRef.current = 0;
        setIsDraggingOver(false);
        const dropPlacement = dropPosition ?? 'before';
        if (isFolder) {
            const sourcePath = extractDragSourcePath(e.dataTransfer) || dragSourcePath || '';
            console.log('[ExplorerItem] Extracted source path:', sourcePath);
            if (sourcePath && item.path !== sourcePath) {
                console.log('[ExplorerItem] Calling onMoveItem:', { from: sourcePath, to: item.path });
                onMoveItem(sourcePath, item.path);
            } else {
                console.log('[ExplorerItem] Skipping move:', { sourcePath, targetPath: item.path, same: sourcePath === item.path });
            }
        } else {
            if (canReorder) {
                const sourcePaths = extractDragSourcePaths(e.dataTransfer);
                const fallbackSourcePaths = sourcePaths.length > 0 ? sourcePaths : dragSourcePath ? [dragSourcePath] : [];
                if (fallbackSourcePaths.length > 0) {
                    onReorderItems(fallbackSourcePaths, item.path, dropPlacement);
                }
            } else {
                console.log('[ExplorerItem] Not a folder, ignoring drop');
            }
        }
        setDropPosition(null);
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
                    draggable={false}
                />
            );
        }
        // Loading state
        return <div className="w-full h-full bg-zinc-800 animate-pulse"></div>;
    };

    const renderTypeBadge = () => {
        switch (itemType) {
            case 'prompt':
                if (promptVariant === 'aoe') {
                    return (
                        <div className="w-6 h-6 rounded-md bg-emerald-500/90 border border-emerald-100/50 text-[10px] font-black flex items-center justify-center text-white">
                            AOE
                        </div>
                    );
                }
                return <BrandLogo className="w-4 h-4 text-fuchsia-200" />;
            case 'image':
                return <PicturesIcon className="w-4 h-4" />;
            default:
                return <FileIcon className="w-4 h-4" />;
        }
    };

    const showTypeBadge = itemType !== 'folder';

    const badgeColor =
        itemType === 'prompt'
            ? promptVariant === 'aoe'
                ? 'bg-emerald-500/80 border-emerald-200/40 text-white'
                : 'bg-fuchsia-500/80 border-fuchsia-200/40 text-white'
            : itemType === 'image'
                ? 'bg-sky-500/80 border-sky-200/40 text-white'
                : 'bg-zinc-700/80 border-zinc-200/30 text-white';

    const selectionClasses = isSelected ? 'ring-2 ring-fuchsia-500 ring-offset-2 ring-offset-zinc-900 bg-zinc-800/70' : '';
    const focusClasses = !isSelected && isFocused ? 'ring-2 ring-fuchsia-400 ring-offset-2 ring-offset-zinc-900' : '';
    const draggingClasses = isDragging ? 'ring-2 ring-fuchsia-400 ring-offset-2 ring-offset-zinc-900 opacity-80 scale-[0.98]' : '';
    const dropReady = isDragActive && (isFolder || (canReorder && !isFolder));
    const dropHighlightClasses = isDraggingOver && isFolder
        ? 'border-2 border-fuchsia-400 bg-fuchsia-500/10'
        : dropReady && isFolder
            ? 'border-2 border-dashed border-zinc-600 bg-zinc-800/60'
            : 'border border-zinc-700/50';
    const labelColor = isSelected ? 'text-white' : 'text-zinc-300';

    // Show drop indicator line for reordering (only for non-folder items when dragging)
    const showDropIndicator = isDragActive && canReorder && !isFolder && dropPosition !== null;

    return (
        <div
            data-draggable-item={canDrag ? 'true' : undefined}
            draggable={canDrag}
            onDragStart={handleDragStart}
            onDragEnd={handleDragEnd}
            onDragOverCapture={handleDragOver}
            onDragOver={handleDragOver}
            onDragEnter={handleDragEnter}
            onDragLeave={handleDragLeave}
            onDropCapture={handleDrop}
            onClick={onSelect}
            onDoubleClick={handleDoubleClick}
            onContextMenu={(event) => {
                if (onContextMenu) {
                    onContextMenu(event);
                }
            }}
            className={`relative text-left group cursor-pointer focus:outline-none rounded-lg transition-all duration-200 select-none ${selectionClasses} ${focusClasses} ${draggingClasses}`}
            tabIndex={-1}
        >
            <div className="relative">
                {showDropIndicator && dropPosition === 'before' && (
                    <div className="absolute -top-2 left-2 h-0.5 w-8 bg-fuchsia-500 rounded-full z-10 pointer-events-none" />
                )}
                <div className={`relative aspect-square rounded-lg overflow-hidden bg-zinc-800 group-hover:border-zinc-600 transition-all duration-200 ${dropHighlightClasses}`}>
                    {renderThumbnail()}
                    {showTypeBadge && (
                        <div className={`absolute bottom-1 right-1 inline-flex items-center justify-center rounded-md border backdrop-blur-sm px-1.5 py-1 ${badgeColor}`}>
                            {renderTypeBadge()}
                        </div>
                    )}
                </div>
                {showDropIndicator && dropPosition === 'after' && (
                    <div className="absolute -bottom-2 left-2 h-0.5 w-8 bg-fuchsia-500 rounded-full z-10 pointer-events-none" />
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
