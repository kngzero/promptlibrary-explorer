import React from 'react';
import type { PromptEntry } from '../types';
import { TerminalIcon, CopyIcon } from './icons';
import ImageDisplay from './ImageDisplay';

interface MetadataPanelProps {
    item: PromptEntry | null;
}

const MetadataPanel: React.FC<MetadataPanelProps> = ({ item }) => {
    
    const handleCopy = () => {
        if (item?.prompt) {
            navigator.clipboard.writeText(item.prompt);
            // Optionally, show a toast notification here
        }
    };

    if (!item) {
        return (
            <div className="p-6 h-full bg-zinc-800/50 flex items-center justify-center text-center">
                <p className="text-zinc-500">Select an item to view its details.</p>
            </div>
        );
    }

    const { prompt, generationInfo, referenceImages, images } = item;

    return (
        <div className="p-6 h-full bg-zinc-800/50 text-zinc-300 overflow-y-auto">
            <h3 className="text-xl font-bold text-white mb-6">Details</h3>
            
            {images && images.length > 0 && (
                <div className="mb-6">
                    <div className="aspect-square rounded-lg overflow-hidden bg-zinc-900/70 border border-zinc-700">
                        <ImageDisplay
                            src={images[0]}
                            alt="Preview of selected item"
                            containerClassName="w-full h-full"
                            className="w-full h-full object-contain"
                        />
                    </div>
                </div>
            )}
            
            <div className="space-y-6">
                {/* Prompt Section */}
                <div>
                    <h4 className="text-sm font-semibold text-zinc-400 mb-2 flex items-center gap-2">
                        <TerminalIcon className="w-4 h-4" />
                        Prompt
                    </h4>
                    <div className="relative bg-zinc-900/70 p-3 rounded-lg border border-zinc-700 text-base max-h-48 overflow-y-auto">
                        <p className="text-zinc-200 whitespace-pre-wrap text-sm">{prompt}</p>
                        <button
                            onClick={handleCopy}
                            className="absolute top-2 right-2 p-1.5 text-zinc-400 hover:text-white bg-zinc-700/50 hover:bg-zinc-700 rounded-md transition"
                            title={'Copy prompt'}
                        >
                            <CopyIcon className="w-4 h-4" />
                        </button>
                    </div>
                </div>

                {/* Info Section */}
                <div>
                    <h4 className="text-sm font-semibold text-zinc-400 mb-3">Generation Info</h4>
                    <div className="grid grid-cols-2 gap-3 text-zinc-300 text-sm">
                        <div className="bg-zinc-900/70 p-3 rounded-lg border border-zinc-700">
                            <div className="text-xs text-zinc-500">Model</div>
                            <div className="font-medium truncate">{generationInfo.model}</div>
                        </div>
                        <div className="bg-zinc-900/70 p-3 rounded-lg border border-zinc-700">
                            <div className="text-xs text-zinc-500">Aspect Ratio</div>
                            <div className="font-medium">{generationInfo.aspectRatio}</div>
                        </div>
                        <div className="col-span-2 bg-zinc-900/70 p-3 rounded-lg border border-zinc-700">
                            <div className="text-xs text-zinc-500">Timestamp</div>
                            <div className="font-medium">{new Date(generationInfo.timestamp).toLocaleString()}</div>
                        </div>
                    </div>
                </div>

                {/* Reference Images Section */}
                {referenceImages && referenceImages.length > 0 && (
                    <div>
                        <h4 className="text-sm font-semibold text-zinc-400 mb-2">Reference Images</h4>
                        <div className="flex flex-wrap gap-2">
                            {referenceImages.map((img, index) => (
                                <ImageDisplay
                                key={index}
                                src={img}
                                alt={`Reference ${index + 1}`}
                                containerClassName="w-16 h-16 rounded-md"
                                className="w-full h-full object-cover"
                                />
                            ))}
                        </div>
                    </div>
                )}
            </div>
        </div>
    );
};

export default MetadataPanel;