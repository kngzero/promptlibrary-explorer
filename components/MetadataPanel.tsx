import React, { useState } from 'react';
import type { PromptEntry } from '../types';
import { TerminalIcon, CopyIcon, Bars3BottomLeftIcon, UserIcon, BoltIcon, MapPinIcon, PaintBrushIcon, SunIcon, CameraIcon, SwatchIcon, FaceSmileIcon } from './icons';
import ImageDisplay from './ImageDisplay';

interface MetadataPanelProps {
    item: PromptEntry | null;
}

const MetadataPanel: React.FC<MetadataPanelProps> = ({ item }) => {
    
    const handleCopy = () => {
        if (!item) return;
        const resolvedPrompt = item.prompt?.trim() ? item.prompt : item.blindPrompt || '';
        if (!resolvedPrompt) return;
        navigator.clipboard.writeText(resolvedPrompt);
        // Optionally, show a toast notification here
    };

    if (!item) {
        return (
            <div className="p-6 h-full bg-zinc-800/50 flex items-center justify-center text-center">
                <p className="text-zinc-500">Select an item to view its details.</p>
            </div>
        );
    }

    const { generationInfo, referenceImages, images } = item;
    const primaryPrompt = item.prompt?.trim() ?? '';
    const fallbackPrompt = item.blindPrompt?.trim() ?? '';
    const displayPrompt = primaryPrompt || fallbackPrompt || 'No prompt provided.';
    const isPromptEntry = item.sourcePath ? /\.(plib|aoe)$/i.test(item.sourcePath) : false;
    const isAoeEntry = item.sourcePath ? /\.aoe$/i.test(item.sourcePath) : false;
    const fileName = item.fileMetadata?.fileName || item.sourcePath?.split(/[\\/]/).pop() || 'Unknown file';
    const fileType = item.fileMetadata?.fileType || (isPromptEntry ? 'Prompt Snapshot' : 'Unknown type');
    const metadataWidth = item.fileMetadata?.width ?? null;
    const metadataHeight = item.fileMetadata?.height ?? null;
    const hasDimensions = typeof metadataWidth === 'number' && typeof metadataHeight === 'number';
    const dimensionLabel = hasDimensions ? `${metadataWidth}px × ${metadataHeight}px` : 'Unknown';
    const modifiedLabel = typeof item.fileMetadata?.modifiedMs === 'number'
        ? new Date(item.fileMetadata.modifiedMs).toLocaleString()
        : 'Unknown';
    const [isAnalysisOpen, setIsAnalysisOpen] = useState(true);
    const analysisDetails = (() => {
        const analysis = item.analysis || {};
        const config: Record<string, { label: string; color: string; Icon?: React.FC<React.SVGProps<SVGSVGElement>> }> = {
            full_prompt: { label: 'Full Prompt', color: 'text-white', Icon: Bars3BottomLeftIcon },
            short_description: { label: 'Brief', color: 'text-zinc-400', Icon: Bars3BottomLeftIcon },
            subject: { label: 'Subject', color: 'text-fuchsia-400', Icon: UserIcon },
            subject_pose: { label: 'Action', color: 'text-blue-400', Icon: BoltIcon },
            composition: { label: 'Place', color: 'text-emerald-400', Icon: MapPinIcon },
            art_style: { label: 'Style', color: 'text-purple-400', Icon: PaintBrushIcon },
            lighting: { label: 'Lighting', color: 'text-amber-400', Icon: SunIcon },
            camera_settings: { label: 'Camera', color: 'text-orange-400', Icon: CameraIcon },
            color_palette: { label: 'Palette', color: 'text-pink-400', Icon: SwatchIcon },
            mood: { label: 'Mood', color: 'text-rose-400', Icon: FaceSmileIcon },
        };
        const order = [
            'full_prompt',
            'short_description',
            'subject',
            'subject_pose',
            'composition',
            'art_style',
            'lighting',
            'camera_settings',
            'color_palette',
            'mood',
        ];
        const pairs: { label: string; value: string; color: string; Icon?: React.FC<React.SVGProps<SVGSVGElement>> }[] = [];
        for (const key of order) {
            const raw = (analysis as Record<string, unknown>)[key];
            if (typeof raw === 'string' && raw.trim()) {
                pairs.push({
                    label: config[key]?.label || key,
                    color: config[key]?.color || 'text-neutral-300',
                    Icon: config[key]?.Icon,
                    value: raw.trim(),
                });
            }
        }
        return pairs;
    })();

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
                {/* File Name Section */}
                <div>
                    <h4 className="text-sm font-semibold text-zinc-400 mb-2">File Name</h4>
                    <div className="bg-zinc-900/70 p-3 rounded-lg border border-zinc-700 text-sm">
                        <p className="text-zinc-200 break-words">{fileName}</p>
                    </div>
                </div>

                {/* Prompt Section */}
                {isPromptEntry && (
                    <div>
                        <h4 className="text-sm font-semibold text-zinc-400 mb-2 flex items-center gap-2">
                            <TerminalIcon className="w-4 h-4" />
                            Prompt
                        </h4>
                        <div className="relative bg-zinc-900/70 p-3 rounded-lg border border-zinc-700 text-base max-h-48 overflow-y-auto">
                            <p className="text-zinc-200 whitespace-pre-wrap text-sm">{displayPrompt}</p>
                            <button
                                onClick={handleCopy}
                                className="absolute top-2 right-2 p-1.5 text-zinc-400 hover:text-white bg-zinc-700/50 hover:bg-zinc-700 rounded-md transition"
                                title={'Copy prompt'}
                            >
                                <CopyIcon className="w-4 h-4" />
                            </button>
                        </div>
                    </div>
                )}

                {/* Info Section */}
                {isPromptEntry ? (
                    <>
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

                        {isAoeEntry && analysisDetails.length > 0 && (
                            <div className="bg-zinc-900/70 rounded-lg border border-zinc-700">
                                <button
                                    className="w-full flex items-center justify-between px-3 py-2 text-sm font-semibold text-zinc-200 hover:bg-zinc-800 rounded-t-lg"
                                    onClick={() => setIsAnalysisOpen(prev => !prev)}
                                >
                                    <span>Analysis</span>
                                    <svg
                                        className={`w-4 h-4 transition-transform ${isAnalysisOpen ? 'rotate-180' : 'rotate-0'}`}
                                        fill="none"
                                        stroke="currentColor"
                                        strokeWidth="2"
                                        viewBox="0 0 24 24"
                                    >
                                        <path strokeLinecap="round" strokeLinejoin="round" d="M19 9l-7 7-7-7" />
                                    </svg>
                                </button>
                                {isAnalysisOpen && (
                                    <div className="p-3 space-y-2">
                                        {analysisDetails.map(({ label, value, color, Icon }) => (
                                            <div key={label} className="bg-zinc-950/50 p-3 rounded-md border border-zinc-800 text-sm relative">
                                                <div className={`text-xs font-semibold pr-10 flex items-center gap-2 ${color}`}>
                                                    {Icon && <Icon className="w-4 h-4" />}
                                                    <span>{label}</span>
                                                </div>
                                                <button
                                                    className="absolute top-2 right-2 p-1 text-zinc-400 hover:text-white hover:bg-zinc-800 rounded"
                                                    onClick={() => navigator.clipboard.writeText(value)}
                                                    title="Copy"
                                                >
                                                    <CopyIcon className="w-4 h-4" />
                                                </button>
                                                <div className="font-medium text-zinc-200 whitespace-pre-wrap">{value}</div>
                                            </div>
                                        ))}
                                    </div>
                                )}
                            </div>
                        )}
                    </>
                ) : (
                    <div>
                        <h4 className="text-sm font-semibold text-zinc-400 mb-3">File Details</h4>
                        <div className="grid grid-cols-2 gap-3 text-zinc-300 text-sm">
                            <div className="bg-zinc-900/70 p-3 rounded-lg border border-zinc-700 col-span-2">
                                <div className="text-xs text-zinc-500">File Type</div>
                                <div className="font-medium">{fileType}</div>
                            </div>
                            <div className="bg-zinc-900/70 p-3 rounded-lg border border-zinc-700">
                                <div className="text-xs text-zinc-500">Dimensions</div>
                                <div className="font-medium">{dimensionLabel}</div>
                            </div>
                            <div className="bg-zinc-900/70 p-3 rounded-lg border border-zinc-700">
                                <div className="text-xs text-zinc-500">Date</div>
                                <div className="font-medium">{modifiedLabel}</div>
                            </div>
                        </div>
                    </div>
                )}

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
