import React, { useEffect, useRef } from 'react';
import ExplorerItem from './ExplorerItem';
import type { FsFileEntry } from '../types';

interface ContentBrowserProps {
    items: FsFileEntry[];
    isLoading: boolean;
    onSelectItem: (item: FsFileEntry, index: number) => void;
    onSelectItemByIndex: (index: number) => void;
    selectedItemIndex: number;
    onNavigate: (path: string) => void;
    onOpenLightbox: (index: number) => void;
    onMoveItem: (sourcePath: string, destinationDir: string) => void;
    isDemoMode: boolean;
    thumbnailSize: number;
    thumbnailsOnly: boolean;
    onItemContextMenu: (event: React.MouseEvent, item: FsFileEntry, index: number) => void;
}

const ContentBrowser: React.FC<ContentBrowserProps> = ({ 
    items, 
    isLoading, 
    onSelectItem, 
    onNavigate, 
    onOpenLightbox, 
    onMoveItem,
    isDemoMode, 
    selectedItemIndex, 
    onSelectItemByIndex,
    thumbnailSize,
    thumbnailsOnly,
    onItemContextMenu
}) => {
    
    const gridRef = useRef<HTMLDivElement>(null);
    const itemRefs = useRef<(HTMLDivElement | null)[]>([]);
    
    // Effect to auto-focus the grid when a folder is opened
    useEffect(() => {
        if (!isLoading && items.length > 0 && gridRef.current && selectedItemIndex === -1) {
            gridRef.current.focus();
            onSelectItemByIndex(0);
        }
    }, [isLoading, items.length, selectedItemIndex, onSelectItemByIndex]);
    
    // Effect to scroll the focused item into view
    useEffect(() => {
        const focusedElement = itemRefs.current[selectedItemIndex];
        if (focusedElement) {
            focusedElement.scrollIntoView({
                behavior: 'smooth',
                block: 'nearest',
            });
        }
    }, [selectedItemIndex]);
    
    const handleDoubleClick = (item: FsFileEntry) => {
        if (item.children) { // isDir
            onNavigate(item.path);
        }
    };

    const handleGridKeyDown = (e: React.KeyboardEvent<HTMLDivElement>) => {
        if (items.length === 0 || !gridRef.current) return;

        // Calculate column count on the fly for accurate navigation
        const gridStyle = window.getComputedStyle(gridRef.current);
        const columnString = gridStyle.getPropertyValue('grid-template-columns');
        const columnCount = columnString.split(' ').length;
    
        let newIndex = selectedItemIndex;
        let shouldPreventDefault = true;
    
        switch (e.key) {
            case 'ArrowRight':
                newIndex = Math.min(selectedItemIndex + 1, items.length - 1);
                break;
            case 'ArrowLeft':
                newIndex = Math.max(selectedItemIndex - 1, 0);
                break;
            case 'ArrowDown':
                newIndex = Math.min(selectedItemIndex + columnCount, items.length - 1);
                break;
            case 'ArrowUp':
                newIndex = Math.max(selectedItemIndex - columnCount, 0);
                break;
            case 'Enter':
                if (selectedItemIndex >= 0 && selectedItemIndex < items.length) {
                    const item = items[selectedItemIndex];
                    if (item.children) {
                        handleDoubleClick(item);
                    } else {
                        // This relies on ExplorerItem's async logic to open the lightbox
                        itemRefs.current[selectedItemIndex]?.dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
                    }
                }
                break;
            default:
                shouldPreventDefault = false;
                break;
        }
    
        if (shouldPreventDefault) {
            e.preventDefault();
        }
    
        if (newIndex !== selectedItemIndex) {
            onSelectItemByIndex(newIndex);
        }
    };

    const getGridItemSize = () => {
        const minSize = 80; // for slider value 1
        const maxSize = 240; // for slider value 10
        const size = minSize + ((maxSize - minSize) / 9) * (thumbnailSize - 1);
        return size;
    };

    return (
        <div className="flex-grow p-4 overflow-y-auto" tabIndex={-1}>
            {isLoading ? (
                <div className="flex items-center justify-center h-full">
                    <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-fuchsia-500"></div>
                </div>
            ) : items.length === 0 ? (
                <div className="flex items-center justify-center h-full text-zinc-500">
                    <p>This folder is empty.</p>
                </div>
            ) : (
                <div
                    ref={gridRef}
                    tabIndex={0}
                    onKeyDown={handleGridKeyDown}
                    className="grid gap-4 outline-none"
                    style={{
                        gridTemplateColumns: `repeat(auto-fill, minmax(${getGridItemSize()}px, 1fr))`
                    }}
                >
                    {items.map((item, index) => (
                        <div key={item.path} ref={el => { itemRefs.current[index] = el; }}>
                            <ExplorerItem
                                item={item}
                                onSelect={() => onSelectItem(item, index)}
                                onDoubleClick={() => handleDoubleClick(item)}
                                onOpenLightbox={() => onOpenLightbox(index)}
                                onMoveItem={onMoveItem}
                                isDemoMode={isDemoMode}
                                isFocused={index === selectedItemIndex}
                                thumbnailsOnly={thumbnailsOnly}
                                onContextMenu={(event) => onItemContextMenu(event, item, index)}
                            />
                        </div>
                    ))}
                </div>
            )}
        </div>
    );
};

export default ContentBrowser;
