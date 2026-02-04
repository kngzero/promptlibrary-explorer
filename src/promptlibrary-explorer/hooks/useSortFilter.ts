import { useState, useMemo, useCallback, useEffect } from 'react';
import { FsFileEntry, SortConfig, FilterConfig } from '../types';

const CUSTOM_ORDER_STORAGE_KEY = 'promptlibrary.customSortOrder';

const loadCustomOrderMap = (): Record<string, string[]> => {
    if (typeof window === 'undefined') return {};
    try {
        const raw = window.localStorage.getItem(CUSTOM_ORDER_STORAGE_KEY);
        if (!raw) return {};
        const parsed = JSON.parse(raw);
        if (!parsed || typeof parsed !== 'object') return {};
        return parsed as Record<string, string[]>;
    } catch {
        return {};
    }
};

export function useSortFilter(folderContents: FsFileEntry[], folderPath: string | null) {
    const [sortConfig, setSortConfig] = useState<SortConfig>({ field: 'type', direction: 'asc' });
    const [filterConfig, setFilterConfig] = useState<FilterConfig>({
        hideOther: true,
        hideJpg: false,
        hidePng: false,
    });
    const [searchQuery, setSearchQuery] = useState('');
    const [customOrderByFolder, setCustomOrderByFolder] = useState<Record<string, string[]>>(loadCustomOrderMap);

    const getItemTypeRank = useCallback((item: FsFileEntry): number => {
        if (item.children) return 0; // Directory
        const name = item.name?.toLowerCase() || '';
        if (name.endsWith('.plib') || name.endsWith('.aoe')) return 1;
        if (/\.(png|jpe?g|webp|gif)$/i.test(name)) return 2; // Image
        return 3; // Other
    }, []);

    const currentCustomOrder = useMemo(
        () => (folderPath ? customOrderByFolder[folderPath] || [] : []),
        [customOrderByFolder, folderPath]
    );

    useEffect(() => {
        if (typeof window === 'undefined') return;
        window.localStorage.setItem(CUSTOM_ORDER_STORAGE_KEY, JSON.stringify(customOrderByFolder));
    }, [customOrderByFolder]);

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

        if (sortConfig.field === 'custom') {
            const orderIndex = new Map(currentCustomOrder.map((path, index) => [path, index]));
            items.sort((a, b) => {
                const idxA = orderIndex.get(a.path);
                const idxB = orderIndex.get(b.path);
                if (idxA !== undefined && idxB !== undefined) return idxA - idxB;
                if (idxA !== undefined) return -1;
                if (idxB !== undefined) return 1;
                const nameA = a.name?.toLowerCase() || '';
                const nameB = b.name?.toLowerCase() || '';
                return nameA.localeCompare(nameB);
            });
        } else {
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
        }

        return items;
    }, [folderContents, sortConfig, filterConfig, getItemTypeRank, searchQuery, currentCustomOrder]);

    const setCustomOrderForFolder = useCallback((path: string, order: string[]) => {
        setCustomOrderByFolder((prev) => ({
            ...prev,
            [path]: order,
        }));
    }, []);

    return {
        sortConfig,
        setSortConfig,
        filterConfig,
        setFilterConfig,
        searchQuery,
        setSearchQuery,
        processedFolderContents,
        currentCustomOrder,
        setCustomOrderForFolder,
    };
}
