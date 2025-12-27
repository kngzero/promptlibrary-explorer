import React, { useState, useEffect, useRef } from 'react';
import { BrandLogo, ChevronRightIcon, ChevronLeftIcon, SortIcon, FilterIcon, CheckIcon, OpenIcon, RefreshIcon, SearchIcon } from './icons';
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
    parentCrumb: Breadcrumb | null;
    onNavigate: (path: string) => void;
    sortConfig: SortConfig;
    onSortChange: (config: SortConfig) => void;
    searchQuery: string;
    onSearchChange: (value: string) => void;
    filterConfig: FilterConfig;
    onFilterChange: (config: FilterConfig) => void;
    isFolderOpen: boolean;
    onChangeFolder: () => void;
    onRefreshFolder: () => void;
    isLoadingFolder: boolean;
}

const Header: React.FC<HeaderProps> = ({
    breadcrumbs,
    parentCrumb,
    onNavigate,
    sortConfig,
    onSortChange,
    searchQuery,
    onSearchChange,
    filterConfig,
    onFilterChange,
    isFolderOpen,
    onChangeFolder,
    onRefreshFolder,
    isLoadingFolder,
}) => {
  const [sortOpen, setSortOpen] = useState(false);
  const [filterOpen, setFilterOpen] = useState(false);
  const searchInputRef = useRef<HTMLInputElement | null>(null);

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
            const key = e.key.toLowerCase();
            if (key === 's') {
                e.preventDefault();
                setSortOpen(prev => !prev);
                setFilterOpen(false); // Close other menu
                return;
            }
            if (key === 'f' && e.shiftKey) {
                e.preventDefault();
                setFilterOpen(prev => !prev);
                setSortOpen(false); // Close other menu
                return;
            }
            if (key === 'f') {
                e.preventDefault();
                searchInputRef.current?.focus();
                setFilterOpen(false);
                setSortOpen(false);
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

  const clearFiltersAndSearch = () => {
    onSearchChange('');
    onFilterChange({ hideJpg: false, hidePng: false, hideOther: true });
  };

  const activeFilters =
    (filterConfig.hideJpg ? 1 : 0) +
    (filterConfig.hidePng ? 1 : 0) +
    (!filterConfig.hideOther ? 1 : 0) +
    (searchQuery.trim() ? 1 : 0);

  return (
    <header className="relative w-full p-3 flex justify-between items-center border-b border-zinc-700/50 flex-shrink-0 z-20 select-none">
      <div className="flex items-center gap-2 flex-1 min-w-0">
        <BrandLogo className="w-8 h-auto text-white flex-shrink-0" />
        {isFolderOpen && (
          <button 
            onClick={onChangeFolder} 
            className="flex items-center gap-1.5 text-sm text-zinc-400 hover:text-white px-2 py-1 rounded-md hover:bg-zinc-700 transition-colors"
            title="Open a different folder (Ctrl+O)"
          >
            <OpenIcon className="w-4 h-4" />
            Change Folder
          </button>
        )}
        <div className="flex items-center text-sm text-zinc-400 flex-shrink min-w-0 border-l border-zinc-700/50 ml-2 pl-4 gap-2">
          {parentCrumb && (
            <button
              onClick={() => onNavigate(parentCrumb.path)}
              className="flex items-center gap-1 px-2 py-1 rounded-md text-zinc-200 bg-zinc-800 border border-zinc-700 hover:bg-zinc-700 hover:border-zinc-600 transition-colors"
              title={`Up to ${parentCrumb.name}`}
            >
              <ChevronLeftIcon className="w-4 h-4" />
              <span className="hidden sm:inline">Up</span>
            </button>
          )}
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
          {isLoadingFolder && (
            <div className="flex items-center gap-1 text-xs text-zinc-400 pl-1">
              <span className="h-2 w-2 rounded-full bg-fuchsia-400 animate-pulse" />
              Loading…
            </div>
          )}
        </div>
      </div>
      <div className="flex items-center gap-2">
        {isFolderOpen && (
          <>
            <div className="hidden md:block">
              <label className="sr-only" htmlFor="file-search-input">Search files</label>
              <div className="relative">
                <SearchIcon className="w-4 h-4 text-zinc-500 absolute left-3 top-1/2 -translate-y-1/2 pointer-events-none" />
                <input
                  id="file-search-input"
                  type="text"
                  value={searchQuery}
                  onChange={(e) => onSearchChange(e.target.value)}
                  ref={searchInputRef}
                  placeholder="Search files"
                  className="pl-9 pr-3 py-1.5 text-sm rounded-md bg-zinc-800 border border-zinc-700 text-zinc-200 placeholder:text-zinc-500 focus:outline-none focus:ring-2 focus:ring-fuchsia-500 focus:border-fuchsia-500 w-48"
                />
              </div>
            </div>
            <div className="md:hidden">
              <label className="sr-only" htmlFor="file-search-input-mobile">Search files</label>
              <div className="relative w-40">
                <SearchIcon className="w-4 h-4 text-zinc-500 absolute left-3 top-1/2 -translate-y-1/2 pointer-events-none" />
                <input
                  id="file-search-input-mobile"
                  type="text"
                  value={searchQuery}
                  onChange={(e) => onSearchChange(e.target.value)}
                  ref={searchInputRef}
                  placeholder="Search files"
                  className="pl-9 pr-3 py-1.5 text-sm rounded-md bg-zinc-800 border border-zinc-700 text-zinc-200 placeholder:text-zinc-500 focus:outline-none focus:ring-2 focus:ring-fuchsia-500 focus:border-fuchsia-500 w-full"
                />
              </div>
            </div>
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
                title="Filter files (Ctrl+Shift+F)"
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
            {activeFilters > 0 && (
              <div className="flex items-center gap-2 px-3 py-1.5 text-xs font-medium rounded-md bg-zinc-800 border border-zinc-700 text-zinc-200">
                <span>{activeFilters} active</span>
                <button
                  onClick={clearFiltersAndSearch}
                  className="text-fuchsia-300 hover:text-white hover:underline"
                  title="Clear search and filters"
                >
                  Clear
                </button>
              </div>
            )}
          </>
        )}
      </div>
    </header>
  );
};

export default Header;
