/**
 * Attempts to extract a file path that was attached to a drag event.
 * Uses multiple MIME types so the operation remains reliable across browsers.
 */
let activeDragSource: string | null = null;

const normalizeDraggedPath = (raw: string): string => {
    if (!raw) return '';
    const firstLine = raw.split('\n')[0] || raw;
    if (firstLine.startsWith('file://')) {
        try {
            const url = new URL(firstLine);
            return url.pathname || '';
        } catch {
            // fallback: strip scheme manually
            return firstLine.replace(/^file:\/\//, '');
        }
    }
    return firstLine;
};

export const setActiveDragSource = (path: string | null) => {
    activeDragSource = path ? normalizeDraggedPath(path) : null;
};

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
