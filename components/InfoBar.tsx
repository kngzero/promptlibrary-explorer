import React from 'react';

interface InfoBarProps {
    shownCount: number;
    hiddenCount: number;
    thumbnailSize: number;
    onThumbnailSizeChange: (size: number) => void;
    thumbnailsOnly: boolean;
    onThumbnailsOnlyChange: (checked: boolean) => void;
}

const InfoBar: React.FC<InfoBarProps> = ({
    shownCount,
    hiddenCount,
    thumbnailSize,
    onThumbnailSizeChange,
    thumbnailsOnly,
    onThumbnailsOnlyChange
}) => {
    return (
        <div className="flex-shrink-0 w-full bg-zinc-800/50 border-t border-zinc-700/50 px-4 py-2 flex items-center justify-between text-sm text-zinc-400 select-none">
            {/* Left: Item Count */}
            <div className="flex items-center gap-3">
                <span>{shownCount} shown</span>
                {hiddenCount > 0 && <span className="text-zinc-500">({hiddenCount} hidden)</span>}
            </div>

            {/* Middle: Thumbnail Size Slider */}
            <div className="flex items-center gap-3">
                <span className="text-xs">Size</span>
                 <input
                    type="range"
                    min="1"
                    max="10"
                    step="1"
                    value={thumbnailSize}
                    onChange={(e) => onThumbnailSizeChange(Number(e.target.value))}
                    className="custom-slider w-32 md:w-48"
                    title="Thumbnail Size"
                />
            </div>

            {/* Right: Thumbnails Only Toggle */}
            <div className="flex items-center gap-3">
                <label htmlFor="thumbnails-only-toggle" className="flex items-center gap-2 cursor-pointer hover:text-white transition-colors">
                    <input
                        id="thumbnails-only-toggle"
                        type="checkbox"
                        checked={thumbnailsOnly}
                        onChange={(e) => onThumbnailsOnlyChange(e.target.checked)}
                        className="h-4 w-4 rounded bg-zinc-700 border-zinc-600 text-fuchsia-500 focus:ring-fuchsia-600 focus:ring-offset-zinc-800"
                    />
                    Thumbnails Only
                </label>
            </div>
        </div>
    );
};

export default InfoBar;
