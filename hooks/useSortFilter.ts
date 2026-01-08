import { useState, useMemo, useCallback } from 'react';
import { FsFileEntry, SortConfig, FilterConfig } from '../types';

export function useSortFilter(folderContents: FsFileEntry[]) {
    const [sortConfig, setSortConfig] = useState<SortConfig>({ field: 'type', direction: 'asc' });
    const [filterConfig, setFilterConfig] = useState<FilterConfig>({
        hideOther: true,
        hideJpg: false,
        hidePng: false,
    });
    const [searchQuery, setSearchQuery] = useState('');

    const getItemTypeRank = useCallback((item: FsFileEntry): number => {
        if (item.children) return 0; // Directory
        const name = item.name?.toLowerCase() || '';
        if (name.endsWith('.plib') || name.endsWith('.aoe')) return 1;
        if (/\.(png|jpe?g|webp|gif)$/i.test(name)) return 2; // Image
        return 3; // Other
    }, []);

    const processedFolderContents = useMemo(() => {
        let items = [...folderContents];

        items = items.filter(item => {
            const name = item.name?.toLowerCase() || '';
            if (searchQuery.trim()) {
                const query = searchQuery.toLowerCase();
                if (!name.includes(query)) return false;
            }
            if (filterConfig.hideJpg && (name.endsWith('.jpg') || name.endsWith('.jpeg'))) return false;
            if (filterConfig.hidePng && name.endsWith('.png')) return false;

            if (filterConfig.hideOther) {
                const isDir = !!item.children;
                const isAllowedType = isDir || /\.(plib|aoe|png|jpe?g|webp|gif)$/i.test(name);
                if (!isAllowedType) return false;
            }
            return true;
        });

        items.sort((a, b) => {
            const nameA = a.name?.toLowerCase() || '';
            const nameB = b.name?.toLowerCase() || '';
            let comparison = 0;

            if (sortConfig.field === 'type') {
                const typeA = getItemTypeRank(a);
                const typeB = getItemTypeRank(b);
                comparison = typeA - typeB;
                if (comparison === 0) {
                    comparison = nameA.localeCompare(nameB);
                }
            } else { // sort by name
                comparison = nameA.localeCompare(nameB);
            }
            return sortConfig.direction === 'asc' ? comparison : -comparison;
        });

        return items;
    }, [folderContents, sortConfig, filterConfig, getItemTypeRank, searchQuery]);

    return {
        sortConfig,
        setSortConfig,
        filterConfig,
        setFilterConfig,
        searchQuery,
        setSearchQuery,
        processedFolderContents,
    };
}
