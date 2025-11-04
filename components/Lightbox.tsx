import React, { useEffect, useCallback, useState } from 'react';
import type { PromptEntry } from '../types';
import { CloseIcon, ChevronLeftIcon, ChevronRightIcon, DownloadIcon, CopyIcon, TerminalIcon, SaveIcon } from './icons';
import ImageDisplay from './ImageDisplay';

interface LightboxProps {
  isOpen: boolean;
  entry: PromptEntry;
  currentImageIndex: number;
  onClose: () => void;
  onNextFile: () => void;
  onPrevFile: () => void;
  onSelectImage: (index: number) => void;
  canGoNext: boolean;
  canGoPrev: boolean;
}

const Lightbox: React.FC<LightboxProps> = ({ isOpen, entry, currentImageIndex, onClose, onNextFile, onPrevFile, onSelectImage, canGoNext, canGoPrev }) => {
  const [isCopied, setIsCopied] = useState(false);

  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
      if (e.key === 'ArrowRight') onNextFile();
      if (e.key === 'ArrowLeft') onPrevFile();
    };
    if (isOpen) {
      window.addEventListener('keydown', handleKeyDown);
    }
    return () => {
      window.removeEventListener('keydown', handleKeyDown);
    };
  }, [isOpen, onClose, onNextFile, onPrevFile]);

  const handleDownload = useCallback((e: React.MouseEvent<HTMLButtonElement>) => {
    e.stopPropagation(); // Prevent the lightbox from closing
    if (entry && entry.images[currentImageIndex]) {
      const link = document.createElement("a");
      link.href = entry.images[currentImageIndex];
      link.download = `generated_image_${currentImageIndex + 1}_${Date.now()}.png`;
      document.body.appendChild(link);
      link.click();
      document.body.removeChild(link);
    }
  }, [entry, currentImageIndex]);

  const handleSavePlib = useCallback((e: React.MouseEvent<HTMLButtonElement>) => {
    e.stopPropagation();
    if (!entry) return;

    const jsonString = JSON.stringify(entry, null, 2);
    const blob = new Blob([jsonString], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    
    const a = document.createElement('a');
    a.href = url;

    const timestamp = new Date(entry.generationInfo.timestamp).getTime();
    const type = entry.referenceImages && entry.referenceImages.length > 0 ? 'image' : 'text';
    const aspectRatio = entry.generationInfo.aspectRatio.replace(':', 'x');
    a.download = `prompt_${timestamp}_${type}_${aspectRatio}.plib`;

    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  }, [entry]);

  const handleCopy = useCallback(() => {
    if (!entry) return;
    navigator.clipboard.writeText(entry.prompt).then(() => {
      setIsCopied(true);
      setTimeout(() => setIsCopied(false), 2000);
    });
  }, [entry]);

  if (!isOpen || !entry) return null;

  const { images, prompt, generationInfo, referenceImages } = entry;
  const activeImage = images[currentImageIndex] ?? images[0] ?? '';

  return (
    <div
      className="fixed inset-0 bg-black/90 backdrop-blur-md z-50 flex items-center justify-center transition-opacity animate-fade-in p-4"
      onClick={onClose}
      role="dialog"
      aria-modal="true"
      aria-label="Image detail view"
    >
      <div
        className="bg-neutral-900 rounded-2xl w-full max-w-7xl h-full max-h-[90vh] flex flex-col md:flex-row overflow-hidden shadow-2xl border border-neutral-700"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Main content: Image Viewer */}
        <div className="w-full md:w-[calc(100%-400px)] h-2/3 md:h-full bg-black flex items-center justify-center relative group p-4">
          <ImageDisplay
            src={activeImage}
            alt={`Generated content ${currentImageIndex + 1}`}
            containerClassName="w-full h-full"
            className="w-full h-full object-contain"
          />

          {/* Prev/Next buttons */}
          <button
            onClick={onPrevFile}
            className="absolute left-4 top-1/2 -translate-y-1/2 text-white bg-neutral-800/50 rounded-full p-2 hover:bg-neutral-700 transition-colors disabled:opacity-0 disabled:cursor-not-allowed opacity-0 group-hover:opacity-100 focus:opacity-100"
            aria-label="Previous file"
            disabled={!canGoPrev}
            title="Previous file (Left arrow)"
          >
            <ChevronLeftIcon className="h-8 w-8" />
          </button>
          <button
            onClick={onNextFile}
            className="absolute right-4 top-1/2 -translate-y-1/2 text-white bg-neutral-800/50 rounded-full p-2 hover:bg-neutral-700 transition-colors disabled:opacity-0 disabled:cursor-not-allowed opacity-0 group-hover:opacity-100 focus:opacity-100"
            aria-label="Next file"
            disabled={!canGoNext}
            title="Next file (Right arrow)"
          >
            <ChevronRightIcon className="h-8 w-8" />
          </button>

          {images.length > 1 && (
            <div className="absolute bottom-4 left-1/2 -translate-x-1/2 flex gap-2 bg-neutral-900/80 backdrop-blur-sm rounded-xl p-2 max-w-full overflow-x-auto">
              {images.map((img, index) => (
                <button
                  key={index}
                  onClick={(e) => {
                    e.stopPropagation();
                    onSelectImage(index);
                  }}
                  className={`w-16 h-16 rounded-md border transition-colors ${index === currentImageIndex ? 'border-fuchsia-500' : 'border-transparent hover:border-neutral-500'}`}
                  title={`View image ${index + 1}`}
                >
                  <ImageDisplay
                    src={img}
                    alt={`Image option ${index + 1}`}
                    containerClassName="w-full h-full"
                    className="w-full h-full object-cover rounded-md"
                  />
                </button>
              ))}
            </div>
          )}
        </div>

        {/* Right Side: Details Panel */}
        <div className="w-full md:w-[400px] flex-shrink-0 h-1/3 md:h-full flex flex-col p-6 relative overflow-y-auto bg-neutral-800 border-l border-neutral-700">
          <button
            onClick={onClose}
            className="absolute top-4 right-4 p-2 text-neutral-400 hover:text-white hover:bg-neutral-700 rounded-full transition-colors z-10"
            aria-label="Close"
          >
            <CloseIcon className="w-6 h-6" />
          </button>
          
          <div className="flex-grow flex flex-col pt-8 space-y-6">
            <h2 className="text-xl font-bold text-white pr-8">Details</h2>

            {/* Prompt Section */}
            <div>
              <h3 className="text-sm font-semibold text-neutral-400 mb-2 flex items-center gap-2">
                <TerminalIcon className="w-4 h-4" />
                Prompt
              </h3>
              <div className="relative bg-neutral-900 p-3 rounded-lg border border-neutral-700 text-base max-h-48 overflow-y-auto">
                <p className="text-neutral-200 whitespace-pre-wrap">{prompt}</p>
                <button
                  onClick={handleCopy}
                  className="absolute top-2 right-2 p-1.5 text-neutral-400 hover:text-white bg-neutral-700/50 hover:bg-neutral-700 rounded-md transition"
                  title={isCopied ? 'Copied!' : 'Copy prompt'}
                >
                  <CopyIcon className="w-4 h-4" />
                </button>
              </div>
            </div>

            {/* Info Section */}
            <div>
              <h3 className="text-sm font-semibold text-neutral-400 mb-3">Generation Info</h3>
              <div className="grid grid-cols-2 gap-3 text-neutral-300">
                <div className="bg-neutral-900 p-3 rounded-lg border border-neutral-700">
                  <div className="text-xs text-neutral-500">Model</div>
                  <div className="font-medium truncate">{generationInfo.model}</div>
                </div>
                <div className="bg-neutral-900 p-3 rounded-lg border border-neutral-700">
                  <div className="text-xs text-neutral-500">Aspect Ratio</div>
                  <div className="font-medium">{generationInfo.aspectRatio}</div>
                </div>
                <div className="col-span-2 bg-neutral-900 p-3 rounded-lg border border-neutral-700">
                  <div className="text-xs text-neutral-500">Timestamp</div>
                  <div className="font-medium">{new Date(generationInfo.timestamp).toLocaleString()}</div>
                </div>
              </div>
            </div>

            {/* Reference Images Section */}
            {referenceImages && referenceImages.length > 0 && (
              <div>
                <h3 className="text-sm font-semibold text-neutral-400 mb-2">Reference Images</h3>
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
            
            <div className="flex-grow"></div>
            
            {/* Actions */}
            <div className="pt-6 mt-auto border-t border-neutral-700 space-y-3 flex-shrink-0">
              <button
                onClick={handleDownload}
                className="w-full flex items-center justify-center gap-2 px-4 py-3 text-base font-semibold rounded-lg text-neutral-200 bg-neutral-700 hover:bg-neutral-600 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-offset-neutral-800 focus:ring-white transition-colors duration-200"
              >
                <DownloadIcon className="w-5 h-5" />
                Download Image ({currentImageIndex + 1} of {images.length})
              </button>
              <button
                onClick={handleSavePlib}
                className="w-full flex items-center justify-center gap-2 px-4 py-3 text-base font-semibold rounded-lg text-neutral-200 bg-neutral-700 hover:bg-neutral-600 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-offset-neutral-800 focus:ring-white transition-colors duration-200"
              >
                <SaveIcon className="w-5 h-5" />
                Download .plib
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};

export default Lightbox;
