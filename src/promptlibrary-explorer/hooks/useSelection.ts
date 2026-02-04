import { useState, useCallback, useRef, useEffect } from 'react';
import { FsFileEntry, PromptEntry } from '../types';
import { usePromptLoader } from './usePromptLoader';

export function useSelection(processedFolderContents: FsFileEntry[]) {
    const [selectedExplorerItem, setSelectedExplorerItem] = useState<PromptEntry | null>(null);
    const [selectedItemIndex, setSelectedItemIndex] = useState<number>(-1);
    const [selectedIndices, setSelectedIndices] = useState<number[]>([]);
    const [selectionAnchorIndex, setSelectionAnchorIndex] = useState<number | null>(null);

    const { loadPromptEntryForItem } = usePromptLoader();
    const selectionQueueRef = useRef<number | null>(null);
    const selectionTimeoutRef = useRef<number | undefined>(undefined);

    const handleSelectItem = useCallback(async (item: FsFileEntry | null) => {
        if (!item) {
            setSelectedExplorerItem(null);
            return;
        }

        if (item.children) {
            // It's a directory, clear selection
            setSelectedExplorerItem(null);
            return;
        }

        const entry = await loadPromptEntryForItem(item);
        setSelectedExplorerItem(entry);
    }, [loadPromptEntryForItem]);

    const flushSelection = useCallback(
        (indices: number[], primaryIndex?: number | null, anchorIndex?: number | null) => {
            const normalized = Array.from(
                new Set(indices.filter((idx) => idx >= 0 && idx < processedFolderContents.length))
            ).sort((a, b) => a - b);

            if (anchorIndex !== undefined) {
                setSelectionAnchorIndex(anchorIndex);
            }

            const nextPrimary =
                primaryIndex !== undefined && primaryIndex !== null
                    ? primaryIndex
                    : normalized.length
                        ? normalized[normalized.length - 1]
                        : -1;

            setSelectedIndices(normalized);

            if (nextPrimary >= 0 && nextPrimary < processedFolderContents.length) {
                setSelectedItemIndex(nextPrimary);
                const item = processedFolderContents[nextPrimary];
                if (item) {
                    handleSelectItem(item);
                }
            } else {
                setSelectedItemIndex(-1);
                setSelectedExplorerItem(null);
            }
        },
        [processedFolderContents, handleSelectItem]
    );

    const updateSelection = useCallback(
        (indices: number[], primaryIndex?: number | null, anchorIndex?: number | null) => {
            // throttle selection to avoid spamming preview loads while arrowing
            window.clearTimeout(selectionTimeoutRef.current);
            selectionTimeoutRef.current = window.setTimeout(() => {
                flushSelection(indices, primaryIndex, anchorIndex);
            }, 50);
            selectionQueueRef.current = primaryIndex ?? null;
        },
        [flushSelection]
    );

    const handleSelectItemByIndex = useCallback(
        (index: number) => {
            if (index >= 0 && index < processedFolderContents.length) {
                updateSelection([index], index, index);
            }
        },
        [processedFolderContents, updateSelection]
    );

    const handleItemClick = useCallback(
        (_item: FsFileEntry, index: number, event?: React.MouseEvent) => {
            const isShift = !!event?.shiftKey;
            const isMeta = !!event?.metaKey || !!event?.ctrlKey;

            if (isShift && selectionAnchorIndex !== null) {
                const start = selectionAnchorIndex;
                const end = index;
                const step = start <= end ? 1 : -1;
                const range: number[] = [];
                for (let i = start; step === 1 ? i <= end : i >= end; i += step) {
                    range.push(i);
                }
                const combined = isMeta ? Array.from(new Set([...selectedIndices, ...range])) : range;
                updateSelection(combined, index, selectionAnchorIndex);
                return;
            }

            if (isMeta) {
                const alreadySelected = selectedIndices.includes(index);
                const nextSelection = alreadySelected
                    ? selectedIndices.filter((idx) => idx !== index)
                    : [...selectedIndices, index];
                const nextPrimary = alreadySelected
                    ? nextSelection[nextSelection.length - 1] ?? -1
                    : index;
                const fallbackAnchor = selectionAnchorIndex ?? index;
                const anchorInSelection = nextSelection.includes(fallbackAnchor);
                const nextAnchor =
                    nextSelection.length === 0
                        ? null
                        : anchorInSelection
                            ? fallbackAnchor
                            : nextPrimary !== -1
                                ? nextPrimary
                                : nextSelection[0];
                updateSelection(nextSelection, nextPrimary === -1 ? null : nextPrimary, nextAnchor);
                if (nextSelection.length === 0) {
                    setSelectionAnchorIndex(null);
                }
                return;
            }

            updateSelection([index], index, index);
        },
        [selectionAnchorIndex, selectedIndices, updateSelection]
    );

    useEffect(() => {
        setSelectedIndices((prev) =>
            prev.filter((idx) => idx >= 0 && idx < processedFolderContents.length)
        );

        if (
            selectionAnchorIndex !== null &&
            (selectionAnchorIndex < 0 || selectionAnchorIndex >= processedFolderContents.length)
        ) {
            setSelectionAnchorIndex(null);
        }
    }, [processedFolderContents.length, selectionAnchorIndex]);

    useEffect(() => {
        if (selectedIndices.length === 0) {
            if (selectedItemIndex !== -1) {
                setSelectedItemIndex(-1);
                setSelectedExplorerItem(null);
            }
            return;
        }

        if (!selectedIndices.includes(selectedItemIndex)) {
            const fallbackIndex = selectedIndices[selectedIndices.length - 1];
            if (fallbackIndex !== undefined && fallbackIndex < processedFolderContents.length) {
                setSelectedItemIndex(fallbackIndex);
                const item = processedFolderContents[fallbackIndex];
                if (item) {
                    handleSelectItem(item);
                }
            }
        }
    }, [selectedIndices, selectedItemIndex, processedFolderContents, handleSelectItem]);

    return {
        selectedExplorerItem,
        setSelectedExplorerItem,
        selectedItemIndex,
        setSelectedItemIndex,
        selectedIndices,
        setSelectedIndices,
        selectionAnchorIndex,
        setSelectionAnchorIndex,
        handleSelectItem,
        handleItemClick,
        handleSelectItemByIndex
    };
}
