import React, { useState } from 'react';
import { FolderIcon, DesktopIcon, DocumentsIcon, PicturesIcon } from './icons';
import { extractDragSourcePath } from '../utils/drag';
import type { FsFileEntry } from '../types';

interface FileTreeProps {
    rootPath: string;
    folderTree: FsFileEntry[];
    selectedPath: string | null;
    onSelect: (path: string) => void;
    onSelectFavorite: (favorite: 'desktop' | 'documents' | 'pictures') => void;
    onMoveItem: (sourcePath: string, destinationDir: string) => void;
    isDemoMode: boolean;
}

const NavItem: React.FC<{
    icon: React.ReactNode;
    label: string;
    onClick: () => void;
    isSelected: boolean;
    isDimmed?: boolean;
    path?: string;
    onMoveItem?: (sourcePath: string, destinationDir: string) => void;
}> = ({ icon, label, onClick, isSelected, isDimmed, path, onMoveItem }) => {
    const [isDraggingOver, setIsDraggingOver] = useState(false);

    const isDropTarget = !!(path && onMoveItem && !isDimmed);

    const handleDragOver = (e: React.DragEvent<HTMLButtonElement>) => {
        if (!isDropTarget) return;
        e.preventDefault();
        e.dataTransfer.dropEffect = 'move';
    };

    const handleDragEnter = (e: React.DragEvent<HTMLButtonElement>) => {
        if (!isDropTarget) return;
        e.preventDefault();
        setIsDraggingOver(true);
    };

    const handleDragLeave = (e: React.DragEvent<HTMLButtonElement>) => {
        if (!isDropTarget) return;
        e.preventDefault();
        setIsDraggingOver(false);
    };

    const handleDrop = (e: React.DragEvent<HTMLButtonElement>) => {
        if (!isDropTarget || !path || !onMoveItem) return;
        e.preventDefault();
        setIsDraggingOver(false);
        const sourcePath = extractDragSourcePath(e.dataTransfer);
        if (sourcePath && path !== sourcePath) {
            onMoveItem(sourcePath, path);
        }
    };

    return (
        <li>
            <button
                onClick={onClick}
                disabled={isDimmed}
                onDragOver={handleDragOver}
                onDragEnter={handleDragEnter}
                onDragLeave={handleDragLeave}
                onDrop={handleDrop}
                className={`w-full flex items-center gap-3 p-2 text-left rounded-md text-sm transition-all duration-200 ${
                    isSelected ? 'bg-fuchsia-600/20 text-fuchsia-300' : 'text-zinc-300 hover:bg-zinc-700/50'
                } ${isDimmed ? 'text-zinc-500 cursor-not-allowed' : ''} ${isDraggingOver ? 'is-drop-target' : ''}`}
            >
                <span className="flex-shrink-0 w-5 h-5">{icon}</span>
                <span className="truncate flex-grow">{label}</span>
            </button>
        </li>
    );
};


const FileTree: React.FC<FileTreeProps> = ({ rootPath, folderTree, selectedPath, onSelect, onSelectFavorite, onMoveItem, isDemoMode }) => {
    const rootName = rootPath.split(/[\/\\]/).pop() || 'Root';
    
    return (
        <div className="p-3 h-full bg-zinc-800/50 flex flex-col select-none">
            <nav className="flex flex-col space-y-4 h-full">
                <div>
                    <h3 className="px-2 text-xs font-semibold text-zinc-500 uppercase tracking-wider mb-2">Favorites</h3>
                    <ul className="space-y-1">
                        <NavItem icon={<DesktopIcon />} label="Desktop" onClick={() => onSelectFavorite('desktop')} isSelected={false} isDimmed={isDemoMode} />
                        <NavItem icon={<DocumentsIcon />} label="Documents" onClick={() => onSelectFavorite('documents')} isSelected={false} isDimmed={isDemoMode} />
                        <NavItem icon={<PicturesIcon />} label="Pictures" onClick={() => onSelectFavorite('pictures')} isSelected={false} isDimmed={isDemoMode} />
                    </ul>
                </div>
                <div className="flex-1 min-h-0 flex flex-col">
                    <h3 className="px-2 text-xs font-semibold text-zinc-500 uppercase tracking-wider mb-2">Folders</h3>
                    <div className="flex-1 min-h-0 overflow-y-auto pr-1">
                        <ul className="space-y-1">
                            <NavItem
                                icon={<FolderIcon />}
                                label={rootName}
                                onClick={() => onSelect(rootPath)}
                                isSelected={selectedPath === rootPath}
                                path={rootPath}
                                onMoveItem={onMoveItem}
                                isDimmed={isDemoMode}
                            />
                        </ul>
                        <div className="pl-4 border-l border-zinc-700 ml-2.5">
                            <ul className="space-y-1 mt-1">
                                {folderTree.map(dir => (
                                    <NavItem
                                        key={dir.path}
                                        icon={<FolderIcon />}
                                        label={dir.name || ''}
                                        onClick={() => onSelect(dir.path)}
                                        isSelected={selectedPath === dir.path}
                                        path={dir.path}
                                        onMoveItem={onMoveItem}
                                        isDimmed={isDemoMode}
                                    />
                                ))}
                            </ul>
                        </div>
                    </div>
                </div>
            </nav>
        </div>
    );
};

export default FileTree;
