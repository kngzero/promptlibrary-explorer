/**
 * Attempts to extract a file path that was attached to a drag event.
 * Uses multiple MIME types so the operation remains reliable across browsers.
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
                    return parsed.path;
                }
            } catch {
                // Ignore malformed JSON payloads
            }
        } else {
            return data;
        }
    }

    return '';
};
