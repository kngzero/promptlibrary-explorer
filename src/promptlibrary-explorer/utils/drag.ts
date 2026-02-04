/**
 * Drag and Drop Utilities
 * Handles extraction of paths from drag events and drag state management
 */

let activeDragSource: string | null = null;

/**
 * Normalizes a dragged path from various formats to a clean file path
 */
const normalizeDraggedPath = (raw: string): string => {
    if (!raw) return '';
    const firstLine = raw.split('\n')[0] || raw;
    if (firstLine.startsWith('file://')) {
        try {
            const url = new URL(firstLine);
            return decodeURIComponent(url.pathname) || '';
        } catch {
            // fallback: strip scheme manually
            return decodeURIComponent(firstLine.replace(/^file:\/\//, ''));
        }
    }
    return firstLine;
};

/**
 * Set the active drag source path (used as fallback when dataTransfer is empty)
 */
export const setActiveDragSource = (path: string | null): void => {
    activeDragSource = path ? normalizeDraggedPath(path) : null;
};

/**
 * Get the currently active drag source (if any)
 */
export const getActiveDragSource = (): string | null => activeDragSource;

/**
 * Extract a single file path from a drag event's dataTransfer
 */
export const extractDragSourcePath = (dataTransfer: DataTransfer): string => {
    const formats = [
        'text/plain',
        'application/x-plib-entry',
        'text/uri-list',
        'application/json',
    ];

    for (const format of formats) {
        const data = dataTransfer.getData(format);
        if (!data) {
            continue;
        }

        if (format === 'application/json') {
            try {
                const parsed = JSON.parse(data);
                if (parsed && typeof parsed.path === 'string' && parsed.path) {
                    return normalizeDraggedPath(parsed.path);
                }
                if (parsed && Array.isArray(parsed.paths) && parsed.paths[0]) {
                    return normalizeDraggedPath(parsed.paths[0]);
                }
            } catch {
                // Ignore malformed JSON payloads
            }
        } else {
            const normalized = normalizeDraggedPath(data);
            if (normalized) return normalized;
        }
    }

    return activeDragSource || '';
};

/**
 * Extract multiple file paths from a drag event's dataTransfer
 */
export const extractDragSourcePaths = (dataTransfer: DataTransfer): string[] => {
    const jsonData = dataTransfer.getData('application/json');
    if (jsonData) {
        try {
            const parsed = JSON.parse(jsonData);
            if (parsed && Array.isArray(parsed.paths) && parsed.paths.length > 0) {
                return parsed.paths.map((path: string) => normalizeDraggedPath(path)).filter(Boolean);
            }
            if (parsed && typeof parsed.path === 'string' && parsed.path) {
                return [normalizeDraggedPath(parsed.path)];
            }
        } catch {
            // Ignore malformed JSON payloads
        }
    }

    const uriList = dataTransfer.getData('text/uri-list');
    if (uriList) {
        const paths = uriList
            .split('\n')
            .map((line) => normalizeDraggedPath(line.trim()))
            .filter(Boolean);
        if (paths.length > 0) return paths;
    }

    const plain = dataTransfer.getData('text/plain');
    if (plain) {
        const normalized = normalizeDraggedPath(plain);
        if (normalized) return [normalized];
    }

    return activeDragSource ? [activeDragSource] : [];
};

/**
 * Convert a file path to a file:// URI
 */
export const toFileUri = (path: string): string => {
    const normalized = path.replace(/\\/g, '/');
    return `file://${encodeURI(normalized)}`;
};

/**
 * Create drag payload for file(s)
 */
export const createDragPayload = (
    dataTransfer: DataTransfer,
    primaryPath: string,
    allPaths: string[]
): void => {
    const safeSetData = (format: string, value: string) => {
        try {
            dataTransfer.setData(format, value);
        } catch {
            // Some WebView engines reject specific custom formats.
        }
    };
    dataTransfer.effectAllowed = 'copyMove';
    const uriList = allPaths.map(toFileUri).join('\n');
    safeSetData('text/plain', primaryPath);
    safeSetData('text/uri-list', uriList);
    safeSetData('application/json', JSON.stringify({ path: primaryPath, paths: allPaths }));
    safeSetData('application/x-plib-entry', primaryPath);

    const primaryName = primaryPath.split(/[\\/]/).pop() || 'file';
    safeSetData('DownloadURL', `application/octet-stream:${primaryName}:${toFileUri(primaryPath)}`);
};

/**
 * Determine drop position (before/after) based on mouse position
 */
export const calculateDropPosition = (
    event: React.DragEvent,
    element: HTMLElement
): 'before' | 'after' => {
    const rect = element.getBoundingClientRect();
    const midY = rect.top + rect.height / 2;
    return event.clientY < midY ? 'before' : 'after';
};
