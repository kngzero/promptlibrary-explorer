import React, { useState, useEffect, useRef } from 'react';
import { BrandLogo, ChevronRightIcon, SortIcon, FilterIcon, CheckIcon, OpenIcon, PowerIcon, RefreshIcon } from './icons';
import type { SortConfig, FilterConfig, Breadcrumb } from '../types';

// Custom hook to detect clicks outside of a component
function useOnClickOutside<T extends HTMLElement>(ref: React.RefObject<T | null>, handler: (event: MouseEvent | TouchEvent) => void) {
  useEffect(() => {
    const listener = (event: MouseEvent | TouchEvent) => {
      if (!ref.current || ref.current.contains(event.target as Node)) {
        return;
      }
      handler(event);
    };
    document.addEventListener("mousedown", listener);
    document.addEventListener("touchstart", listener);
    return () => {
      document.removeEventListener("mousedown", listener);
      document.removeEventListener("touchstart", listener);
    };
  }, [ref, handler]);
}

interface HeaderProps {
    breadcrumbs: Breadcrumb[];
    onNavigate: (path: string) => void;
    sortConfig: SortConfig;
    onSortChange: (config: SortConfig) => void;
    filterConfig: FilterConfig;
    onFilterChange: (config: FilterConfig) => void;
    isFolderOpen: boolean;
    isDemoMode: boolean;
    onChangeFolder: () => void;
    onExitDemo: () => void;
    onRefreshFolder: () => void;
}

const Header: React.FC<HeaderProps> = ({
    breadcrumbs,
    onNavigate,
    sortConfig,
    onSortChange,
    filterConfig,
    onFilterChange,
    isFolderOpen,
    isDemoMode,
    onChangeFolder,
    onExitDemo,
    onRefreshFolder
}) => {
  const [sortOpen, setSortOpen] = useState(false);
  const [filterOpen, setFilterOpen] = useState(false);

  const sortRef = useRef<HTMLDivElement | null>(null);
  const filterRef = useRef<HTMLDivElement | null>(null);

  useOnClickOutside(sortRef, () => setSortOpen(false));
  useOnClickOutside(filterRef, () => setFilterOpen(false));

  // Keyboard shortcuts for menus
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
        if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) {
            return;
        }

        if (isFolderOpen && (e.metaKey || e.ctrlKey)) {
            if (e.key.toLowerCase() === 's') {
                e.preventDefault();
                setSortOpen(prev => !prev);
                setFilterOpen(false); // Close other menu
            }
            if (e.key.toLowerCase() === 'f') {
                e.preventDefault();
                setFilterOpen(prev => !prev);
                setSortOpen(false); // Close other menu
            }
        }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => {
        window.removeEventListener('keydown', handleKeyDown);
    };
  }, [isFolderOpen]);

  const sortOptions: { label: string, config: SortConfig }[] = [
    { label: 'Sort by Type (Asc)', config: { field: 'type', direction: 'asc' } },
    { label: 'Sort by Type (Desc)', config: { field: 'type', direction: 'desc' } },
    { label: 'Sort by Name (Asc)', config: { field: 'name', direction: 'asc' } },
    { label: 'Sort by Name (Desc)', config: { field: 'name', direction: 'desc' } },
  ];

  const handleSortSelect = (config: SortConfig) => {
    onSortChange(config);
    setSortOpen(false);
  };
  
  const handleFilterToggle = (key: keyof FilterConfig) => {
    onFilterChange({ ...filterConfig, [key]: !filterConfig[key] });
  };

  return (
    <header className="relative w-full p-3 flex justify-between items-center border-b border-zinc-700/50 flex-shrink-0 z-20 select-none">
      <div className="flex items-center gap-2 flex-1 min-w-0">
        <BrandLogo className="w-8 h-auto text-white flex-shrink-0" />
        {isFolderOpen && (
            isDemoMode ? (
              <button 
                onClick={onExitDemo} 
                className="flex items-center gap-1.5 text-sm text-zinc-400 hover:text-white px-2 py-1 rounded-md hover:bg-zinc-700 transition-colors"
                title="Exit Demo Mode"
              >
                <PowerIcon className="w-4 h-4" />
                Exit Demo
              </button>
            ) : (
              <button 
                onClick={onChangeFolder} 
                className="flex items-center gap-1.5 text-sm text-zinc-400 hover:text-white px-2 py-1 rounded-md hover:bg-zinc-700 transition-colors"
                title="Open a different folder (Ctrl+O)"
              >
                <OpenIcon className="w-4 h-4" />
                Change Folder
              </button>
            )
        )}
        <div className="flex items-center text-sm text-zinc-400 flex-shrink min-w-0 border-l border-zinc-700/50 ml-2 pl-4">
          {breadcrumbs.map((crumb, index) => (
            <React.Fragment key={crumb.path}>
              <button
                onClick={() => onNavigate(crumb.path)}
                className="hover:text-white px-2 py-1 rounded-md hover:bg-zinc-700 transition-colors truncate"
                title={crumb.name}
              >
                {crumb.name}
              </button>
              {index < breadcrumbs.length - 1 && <ChevronRightIcon className="h-4 w-4 text-zinc-600 flex-shrink-0" />}
            </React.Fragment>
          ))}
        </div>
      </div>
      <div className="flex items-center gap-2">
        {isFolderOpen && (
          <>
            <button
              onClick={onRefreshFolder}
              className="flex items-center gap-2 px-3 py-1.5 text-sm font-medium text-zinc-300 bg-zinc-800 border border-zinc-700 rounded-md hover:bg-zinc-700 hover:border-zinc-600 transition-colors"
              title="Refresh folder"
            >
              <RefreshIcon className="w-4 h-4" />
              Refresh
            </button>
            {/* Sort Dropdown */}
            <div ref={sortRef} className="relative">
              <button 
                onClick={() => setSortOpen(!sortOpen)} 
                className="flex items-center gap-2 px-3 py-1.5 text-sm font-medium text-zinc-300 bg-zinc-800 border border-zinc-700 rounded-md hover:bg-zinc-700 hover:border-zinc-600 transition-colors"
                title="Sort files (Ctrl+S)"
              >
                <SortIcon className="w-4 h-4" />
                Sort
              </button>
              {sortOpen && (
                <div className="absolute top-full right-0 mt-2 w-48 bg-zinc-800 border border-zinc-700 rounded-md shadow-lg z-30">
                  {sortOptions.map(opt => (
                    <button key={opt.label} onClick={() => handleSortSelect(opt.config)} className="w-full text-left px-3 py-2 text-sm text-zinc-200 hover:bg-zinc-700 flex items-center justify-between">
                      {opt.label}
                      {sortConfig.field === opt.config.field && sortConfig.direction === opt.config.direction && (
                        <CheckIcon className="w-4 h-4 text-fuchsia-400" />
                      )}
                    </button>
                  ))}
                </div>
              )}
            </div>

            {/* Filter Dropdown */}
            <div ref={filterRef} className="relative">
              <button 
                onClick={() => setFilterOpen(!filterOpen)} 
                className="flex items-center gap-2 px-3 py-1.5 text-sm font-medium text-zinc-300 bg-zinc-800 border border-zinc-700 rounded-md hover:bg-zinc-700 hover:border-zinc-600 transition-colors"
                title="Filter files (Ctrl+F)"
              >
                <FilterIcon className="w-4 h-4" />
                Filter
              </button>
               {filterOpen && (
                <div className="absolute top-full right-0 mt-2 w-48 bg-zinc-800 border border-zinc-700 rounded-md shadow-lg z-30 p-2 space-y-1">
                  <label className="flex items-center gap-2 w-full text-left px-2 py-1.5 text-sm text-zinc-200 hover:bg-zinc-700 rounded-md cursor-pointer">
                    <input type="checkbox" checked={filterConfig.hideJpg} onChange={() => handleFilterToggle('hideJpg')} className="h-4 w-4 rounded bg-zinc-700 border-zinc-600 text-fuchsia-500 focus:ring-fuchsia-600" />
                    Hide JPG
                  </label>
                  <label className="flex items-center gap-2 w-full text-left px-2 py-1.5 text-sm text-zinc-200 hover:bg-zinc-700 rounded-md cursor-pointer">
                    <input type="checkbox" checked={filterConfig.hidePng} onChange={() => handleFilterToggle('hidePng')} className="h-4 w-4 rounded bg-zinc-700 border-zinc-600 text-fuchsia-500 focus:ring-fuchsia-600" />
                    Hide PNG
                  </label>
                   <label className="flex items-center gap-2 w-full text-left px-2 py-1.5 text-sm text-zinc-200 hover:bg-zinc-700 rounded-md cursor-pointer">
                    <input type="checkbox" checked={filterConfig.hideOther} onChange={() => handleFilterToggle('hideOther')} className="h-4 w-4 rounded bg-zinc-700 border-zinc-600 text-fuchsia-500 focus:ring-fuchsia-600" />
                    Hide Other Files
                  </label>
                </div>
              )}
            </div>
          </>
        )}
      </div>
    </header>
  );
};

export default Header;
