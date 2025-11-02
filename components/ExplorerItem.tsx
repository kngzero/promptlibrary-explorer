import React, { useState, useEffect } from 'react';
import ImageDisplay from './ImageDisplay';
import { FolderIcon, FileIcon } from './icons';
import { getPlibData } from '../services/plibService';
import { convertFileSrc, getBasename } from '../services/tauriService';
import { getDemoPlibFile, getDemoImageEntry } from '../services/demoService';
import type { PromptEntry, FsFileEntry } from '../types';

interface ExplorerItemProps {
    item: FsFileEntry;
    onSelect: () => void;
    onDoubleClick: (item: FsFileEntry) => void;
    onOpenLightbox: (item: PromptEntry, index: number) => void;
    onMoveItem: (sourcePath: string, destinationDir: string) => void;
    isDemoMode: boolean;
    isFocused: boolean;
    thumbnailsOnly: boolean;
}

const isImageAsset = (filename: string) => /\.(png|jpe?g|webp|gif)$/i.test(filename);
const isPlibAsset = (filename: string) => /\.plib$/i.test(filename);

const ExplorerItem: React.FC<ExplorerItemProps> = ({ item, onSelect, onDoubleClick, onOpenLightbox, onMoveItem, isDemoMode, isFocused, thumbnailsOnly }) => {
    const [thumbnailSrc, setThumbnailSrc] = useState<string | null>(null);
    const [title, setTitle] = useState(item.name || 'Loading...');
    const [isDragging, setIsDragging] = useState(false);
    const [isDraggingOver, setIsDraggingOver] = useState(false);
    
    const isFolder = !!item.children;

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
    
    const handleDoubleClick = async () => {
        if (item.children) {
            onDoubleClick(item);
            return;
        }

        const itemName = title;
        if (isDemoMode) {
            if (isPlibAsset(itemName)) {
                const data = getDemoPlibFile(item.path);
                if (data) onOpenLightbox(data, 0);
            } else if (isImageAsset(itemName)) {
                const data = getDemoImageEntry(item.path);
                onOpenLightbox(data, 0);
            }
            return;
        }

        if (isPlibAsset(itemName)) {
            const data = await getPlibData(item.path);
            if (data) {
                // NEW: convert each image path for Tauri before opening lightbox
                const convertedImages = await Promise.all(
                    (data.images ?? []).map(async (img: string) =>
                        !img.startsWith('data:') && !/^https?:\/\//i.test(img) ? await convertFileSrc(img) : img
                    )
                );
                const convertedReferenceImages = await Promise.all(
                    (data.referenceImages ?? []).map(async (img: string) =>
                        !img.startsWith('data:') && !/^https?:\/\//i.test(img) ? await convertFileSrc(img) : img
                    )
                );
                onOpenLightbox({ ...data, images: convertedImages, referenceImages: convertedReferenceImages }, 0);
            }
        } else if (isImageAsset(itemName)) {
            const imageUrl = await convertFileSrc(item.path);
            const mockEntry: PromptEntry = {
                prompt: title,
                images: [imageUrl],
                generationInfo: {
                    model: 'Image File',
                    aspectRatio: 'N/A',
                    timestamp: 'N/A',
                    numberOfImages: 1,
                },
            };
            onOpenLightbox(mockEntry, 0);
        }
    };
    
    // --- Drag and Drop Handlers ---
    const handleDragStart = (e: React.DragEvent<HTMLDivElement>) => {
        if (isFolder || isDemoMode) {
            e.preventDefault();
            return;
        }
        setIsDragging(true);
        e.dataTransfer.setData('text/plain', item.path);
        e.dataTransfer.effectAllowed = 'move';
    };

    const handleDragEnd = () => setIsDragging(false);
    
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
        const sourcePath = e.dataTransfer.getData('text/plain');
        if (sourcePath && item.path !== sourcePath) {
            onMoveItem(sourcePath, item.path);
        }
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

    const focusClasses = isFocused ? 'ring-2 ring-fuchsia-500 ring-offset-2 ring-offset-zinc-900' : '';

    return (
        <div
            draggable={!isFolder && !isDemoMode}
            onDragStart={handleDragStart}
            onDragEnd={handleDragEnd}
            onDragOver={handleDragOver}
            onDragEnter={handleDragEnter}
            onDragLeave={handleDragLeave}
            onDrop={handleDrop}
            onClick={onSelect}
            onDoubleClick={handleDoubleClick}
            className={`text-left group cursor-pointer focus:outline-none rounded-lg transition-opacity duration-200 ${focusClasses} ${isDragging ? 'is-dragging' : ''}`}
            tabIndex={-1}
        >
            <div className={`aspect-square rounded-lg overflow-hidden bg-zinc-800 border border-zinc-700/50 group-hover:border-zinc-600 transition-all duration-200 ${isDraggingOver ? 'is-drop-target' : ''}`}>
                {renderThumbnail()}
            </div>
            {!thumbnailsOnly && (
                 <p className="text-sm mt-2 text-zinc-300 truncate group-hover:text-white" title={title}>
                    {title}
                </p>
            )}
        </div>
    );
};

export default ExplorerItem;