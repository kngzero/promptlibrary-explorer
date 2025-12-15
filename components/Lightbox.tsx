import React, { useEffect, useCallback, useState, useMemo, useRef } from 'react';
import type { PromptEntry } from '../types';
import {
  CloseIcon,
  ChevronLeftIcon,
  ChevronRightIcon,
  DownloadIcon,
  CopyIcon,
  TerminalIcon,
  SaveIcon,
} from './icons';
import ImageDisplay from './ImageDisplay';

type ImageKind = 'image' | 'reference';

interface ImageContextTarget {
  type: ImageKind;
  index: number;
}

const extensionFromMime = (mime: string | null | undefined): string | null => {
  if (!mime) return null;
  const normalized = mime.toLowerCase();
  if (normalized.includes('png')) return 'png';
  if (normalized.includes('jpeg') || normalized.includes('jpg')) return 'jpg';
  if (normalized.includes('webp')) return 'webp';
  if (normalized.includes('gif')) return 'gif';
  return null;
};

const extensionFromPath = (path: string | null | undefined): string | null => {
  if (!path) return null;
  const match = /\.([a-z0-9]+)(?:\?|#|$)/i.exec(path);
  return match ? match[1].toLowerCase() : null;
};

const mimeFromExtension = (ext: string | null | undefined): string => {
  switch ((ext || '').toLowerCase()) {
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'webp':
      return 'image/webp';
    case 'gif':
      return 'image/gif';
    default:
      return 'application/octet-stream';
  }
};

const isLikelyBase64 = (value: string) => /^[A-Za-z0-9+/=\s]+$/.test(value) && value.length > 100;
const isLikelyAbsolutePath = (value: string) =>
  value.startsWith('/') || /^[a-zA-Z]:[\\/]/.test(value) || value.startsWith('\\\\');

interface ResolveImageBlobParams {
  rawSource: string;
  displaySource?: string | null;
  sourcePath?: string;
}

const dataUrlToBlob = (dataUrl: string): { blob: Blob; mime: string } => {
  const commaIndex = dataUrl.indexOf(',');
  if (commaIndex === -1) {
    throw new Error('Invalid data URL format.');
  }
  const header = dataUrl.slice(5, commaIndex); // strip "data:"
  const dataPart = dataUrl.slice(commaIndex + 1);
  const [mimePart, ...flags] = header.split(';');
  const mime = mimePart || 'application/octet-stream';
  const isBase64 = flags.includes('base64');
  const byteString = isBase64 ? atob(dataPart) : decodeURIComponent(dataPart);
  const len = byteString.length;
  const bytes = new Uint8Array(len);
  for (let i = 0; i < len; i++) {
    bytes[i] = byteString.charCodeAt(i);
  }
  return { blob: new Blob([bytes], { type: mime }), mime };
};

const resolveImageBlob = async ({ rawSource, displaySource, sourcePath }: ResolveImageBlobParams): Promise<{ blob: Blob; extension: string }> => {
  if (!rawSource) {
    throw new Error('No image source provided.');
  }

  if (rawSource.startsWith('data:')) {
    const { blob, mime } = dataUrlToBlob(rawSource);
    const extension = extensionFromMime(mime) || extensionFromPath(displaySource) || 'png';
    return { blob, extension };
  }

  if (/^https?:\/\//i.test(rawSource) || rawSource.startsWith('tauri://')) {
    const response = await fetch(rawSource);
    if (!response.ok) {
      throw new Error(`Failed to fetch remote image: ${response.status}`);
    }
    const blob = await response.blob();
    const extension =
      extensionFromMime(blob.type) || extensionFromPath(rawSource) || extensionFromPath(displaySource) || 'png';
    return { blob, extension };
  }

  if (isLikelyBase64(rawSource)) {
    const normalized = rawSource.replace(/\s+/g, '');
    const binaryString = atob(normalized);
    const len = binaryString.length;
    const bytes = new Uint8Array(len);
    for (let i = 0; i < len; i++) {
      bytes[i] = binaryString.charCodeAt(i);
    }
    const extension = extensionFromPath(displaySource) || 'png';
    const mime = mimeFromExtension(extension);
    const blob = new Blob([bytes], { type: mime });
    return { blob, extension };
  }

  if (isLikelyAbsolutePath(rawSource) || /\.(png|jpe?g|webp|gif)$/i.test(rawSource)) {
    const fs = await import('@tauri-apps/api/fs');
    const pathApi = await import('@tauri-apps/api/path');
    let resolvedPath = rawSource;

    if (!isLikelyAbsolutePath(rawSource)) {
      if (!sourcePath) {
        throw new Error('Cannot resolve relative image path without source context.');
      }
      const dir = await pathApi.dirname(sourcePath);
      resolvedPath = await pathApi.join(dir, rawSource);
    }

    const contents = await fs.readBinaryFile(resolvedPath);
    const byteData = contents instanceof Uint8Array ? contents : new Uint8Array(contents);
    const normalized = new Uint8Array(byteData.byteLength);
    normalized.set(byteData);
    const arrayBuffer = normalized.buffer;
    const extension = extensionFromPath(resolvedPath) || extensionFromPath(displaySource) || 'png';
    const mime = mimeFromExtension(extension);
    const blob = new Blob([arrayBuffer], { type: mime });
    return { blob, extension };
  }

  throw new Error('Unknown image data format.');
};

const isTauriEnvironment = () =>
  typeof window !== 'undefined' &&
  (Boolean((window as unknown as { __TAURI__?: unknown }).__TAURI__) ||
    Boolean((window as unknown as { __TAURI_IPC__?: unknown }).__TAURI_IPC__));

const triggerBlobDownload = (blob: Blob, filename: string) => {
  const downloadUrl = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = downloadUrl;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  document.body.removeChild(link);
  URL.revokeObjectURL(downloadUrl);
};

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
  onShowToast: (message: string, type: 'success' | 'error' | 'info') => void;
}

const Lightbox: React.FC<LightboxProps> = ({
  isOpen,
  entry,
  currentImageIndex,
  onClose,
  onNextFile,
  onPrevFile,
  onSelectImage,
  canGoNext,
  canGoPrev,
  onShowToast,
}) => {
  const BASE_ZOOM = 1;
  const ZOOM_SCALE = 2.5;
  const [isCopied, setIsCopied] = useState(false);
  const [isDownloading, setIsDownloading] = useState(false);
  const [imageContextMenu, setImageContextMenu] = useState<{ x: number; y: number; target: ImageContextTarget } | null>(null);
  const [isZoomed, setIsZoomed] = useState(false);
  const [panPosition, setPanPosition] = useState({ x: 50, y: 50 });
  const viewerRef = useRef<HTMLDivElement | null>(null);

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

  useEffect(() => {
    if (!isOpen) {
      setImageContextMenu(null);
      setIsZoomed(false);
      setPanPosition({ x: 50, y: 50 });
    }
  }, [isOpen]);

  useEffect(() => {
    setIsZoomed(false);
    setPanPosition({ x: 50, y: 50 });
  }, [currentImageIndex]);

  const toggleZoom = useCallback((event: React.MouseEvent<HTMLDivElement>) => {
    event.stopPropagation();
    setIsZoomed((prev) => {
      if (prev) {
        setPanPosition({ x: 50, y: 50 });
      }
      return !prev;
    });
  }, []);

  const handleMouseMoveOnImage = useCallback(
    (event: React.MouseEvent<HTMLDivElement>) => {
      if (!isZoomed || !viewerRef.current) return;
      const rect = viewerRef.current.getBoundingClientRect();
      if (!rect.width || !rect.height) return;
      const x = ((event.clientX - rect.left) / rect.width) * 100;
      const y = ((event.clientY - rect.top) / rect.height) * 100;
      setPanPosition({
        x: Math.min(100, Math.max(0, x)),
        y: Math.min(100, Math.max(0, y)),
      });
    },
    [isZoomed]
  );

  const getImageSources = useCallback(
    (target: ImageContextTarget) => {
      if (!entry) {
        return { rawSource: null as string | null, displaySource: null as string | null };
      }

      if (target.type === 'image') {
        return {
          rawSource: entry.rawImages?.[target.index] ?? entry.images?.[target.index] ?? null,
          displaySource: entry.images?.[target.index] ?? null,
        };
      }

      return {
        rawSource: entry.rawReferenceImages?.[target.index] ?? entry.referenceImages?.[target.index] ?? null,
        displaySource: entry.referenceImages?.[target.index] ?? null,
      };
    },
    [entry]
  );

  const deriveFileNameForTarget = useCallback(
    (target: ImageContextTarget, ext: string | null | undefined) => {
      const safeExt = (ext || 'png').toLowerCase();
      const prefix = target.type === 'reference' ? 'reference_image' : 'generated_image';
      if (entry?.generationInfo?.timestamp && entry.generationInfo.timestamp !== 'N/A') {
        const parsed = new Date(entry.generationInfo.timestamp);
        if (!Number.isNaN(parsed.getTime())) {
          return `${prefix}_${parsed.getTime()}_${target.index + 1}.${safeExt}`;
        }
      }
      return `${prefix}_${target.index + 1}_${Date.now()}.${safeExt}`;
    },
    [entry]
  );

  const openContextMenuForTarget = useCallback((event: React.MouseEvent, target: ImageContextTarget) => {
    event.preventDefault();
    event.stopPropagation();
    setImageContextMenu({
      x: event.clientX,
      y: event.clientY,
      target,
    });
  }, []);

  const handleContextMenuAction = useCallback(
    async (action: 'save' | 'copy') => {
      if (!entry || !imageContextMenu) return;

      const { rawSource, displaySource } = getImageSources(imageContextMenu.target);

      if (!rawSource) {
        onShowToast('Image data is unavailable.', 'error');
        setImageContextMenu(null);
        return;
      }

      try {
        const { blob, extension } = await resolveImageBlob({
          rawSource,
          displaySource: displaySource ?? undefined,
          sourcePath: entry.sourcePath,
        });
        const safeExtension = (extension || 'png').toLowerCase();

        const attemptWebClipboardCopy = async () => {
          try {
            const clipboardApi = typeof navigator !== 'undefined' ? navigator.clipboard : undefined;
            const clipboardCtor = typeof window !== 'undefined' ? (window as any).ClipboardItem : undefined;
            if (!clipboardApi || typeof clipboardApi.write !== 'function' || !clipboardCtor) {
              return false;
            }
            const typeKey = blob.type || mimeFromExtension(extension);
            const clipboardItem = new clipboardCtor({
              [typeKey]: blob,
            });
            await clipboardApi.write([clipboardItem]);
            return true;
          } catch (clipboardError) {
            console.error('Browser clipboard copy failed.', clipboardError);
            return false;
          }
        };

        const attemptNativeClipboardCopy = async () => {
          if (!isTauriEnvironment()) return false;
          try {
            const { invoke } = await import('@tauri-apps/api/tauri');
            const buffer = await blob.arrayBuffer();
            await invoke('copy_image_to_clipboard', {
              imageData: Array.from(new Uint8Array(buffer)),
            });
            return true;
          } catch (nativeError) {
            console.error('Native clipboard copy failed.', nativeError);
            return false;
          }
        };

        const attemptNativeSave = async (defaultPath: string) => {
          if (!isTauriEnvironment()) return 'unsupported' as const;
          try {
            const dialog = await import('@tauri-apps/api/dialog');
            const selectedPath = await dialog.save({
              defaultPath,
              title: 'Save Image',
              filters: [
                {
                  name: 'Image',
                  extensions: [safeExtension],
                },
              ],
            });
            if (!selectedPath) {
              return 'cancelled' as const;
            }
            let finalPath = selectedPath;
            if (!/\.[^\\/]+$/.test(finalPath) && safeExtension) {
              finalPath = `${finalPath}.${safeExtension}`;
            }
            const fs = await import('@tauri-apps/api/fs');
            const buffer = await blob.arrayBuffer();
            await fs.writeBinaryFile({ path: finalPath, contents: new Uint8Array(buffer) });
            return 'success' as const;
          } catch (nativeError) {
            console.error('Native save dialog failed.', nativeError);
            return 'failed' as const;
          }
        };

        if (action === 'copy') {
          const copied = (await attemptWebClipboardCopy()) || (await attemptNativeClipboardCopy());
          if (!copied) {
            throw new Error('Clipboard image copy is not supported in this environment.');
          }
          onShowToast('Image copied to clipboard.', 'success');
        } else {
          const defaultPath = deriveFileNameForTarget(imageContextMenu.target, safeExtension);
          const nativeSaveResult = await attemptNativeSave(defaultPath);
          if (nativeSaveResult === 'cancelled') {
            return;
          }
          if (nativeSaveResult !== 'success') {
            triggerBlobDownload(blob, defaultPath);
          }
          onShowToast('Image saved successfully.', 'success');
        }
      } catch (error) {
        console.error('Image context action failed.', error);
        onShowToast(action === 'copy' ? 'Failed to copy image.' : 'Failed to save image.', 'error');
      } finally {
        setImageContextMenu(null);
      }
    },
    [entry, imageContextMenu, getImageSources, onShowToast, deriveFileNameForTarget]
  );
  const handleDownload = useCallback(
    async (e: React.MouseEvent<HTMLButtonElement>) => {
      e.stopPropagation(); // Prevent the lightbox from closing
      if (!entry) return;

      const rawImages = entry.rawImages ?? entry.images;
      const displayImages = entry.images ?? [];
      const rawSource = rawImages?.[currentImageIndex];
      const displaySource = displayImages[currentImageIndex];

      if (!rawSource) {
        onShowToast('No image data available to save.', 'error');
        return;
      }

      const deriveFileName = (ext: string | null | undefined) => {
        const timestamp = entry.generationInfo?.timestamp;
        const safeExt = ext ? ext.toLowerCase() : 'png';
        if (timestamp && timestamp !== 'N/A') {
          const parsed = new Date(timestamp);
          if (!Number.isNaN(parsed.getTime())) {
            return `generated_image_${parsed.getTime()}_${currentImageIndex + 1}.${safeExt}`;
          }
        }
        return `generated_image_${currentImageIndex + 1}_${Date.now()}.${safeExt}`;
      };

      setIsDownloading(true);

      try {
        const { blob, extension } = await resolveImageBlob({
          rawSource,
          displaySource,
          sourcePath: entry.sourcePath,
        });
        const safeExtension = (extension || 'png').toLowerCase();
        const defaultFileName = deriveFileName(safeExtension);

        let saved = false;

        if (isTauriEnvironment()) {
          try {
            const dialog = await import('@tauri-apps/api/dialog');
            const selectedPath = await dialog.save({
              defaultPath: defaultFileName,
              title: 'Save Image',
              filters: [
                {
                  name: 'Image',
                  extensions: [safeExtension],
                },
              ],
            });

            if (!selectedPath) {
              return;
            }

            let finalPath = selectedPath;
            if (!/\.[^\\/]+$/.test(finalPath)) {
              finalPath = `${finalPath}.${safeExtension}`;
            }

            const fs = await import('@tauri-apps/api/fs');
            const buffer = await blob.arrayBuffer();
            await fs.writeBinaryFile({ path: finalPath, contents: new Uint8Array(buffer) });
            saved = true;
          } catch (nativeError) {
            console.error('Native image save failed; falling back to browser download.', nativeError);
          }
        }

        if (!saved) {
          triggerBlobDownload(blob, defaultFileName);
          saved = true;
        }

        onShowToast('Image saved successfully.', 'success');
      } catch (error) {
        console.error('Unexpected error while saving image.', error);
        onShowToast('Failed to save image.', 'error');
      } finally {
        setIsDownloading(false);
      }
    },
    [entry, currentImageIndex, onShowToast]
  );

  const handleSavePlib = useCallback(
    async (e: React.MouseEvent<HTMLButtonElement>) => {
      e.stopPropagation();
      if (!entry) return;

      const { rawImages, rawReferenceImages, sourcePath, ...rest } = entry;
      const serialized = {
        ...rest,
        images: rawImages ?? rest.images,
        referenceImages: rawReferenceImages ?? rest.referenceImages,
      };

      const jsonString = JSON.stringify(serialized, null, 2);
      const blob = new Blob([jsonString], { type: 'application/json' });
      const timestampValue = new Date(entry.generationInfo.timestamp).getTime();
      const safeTimestamp = Number.isNaN(timestampValue) ? Date.now() : timestampValue;
      const type = entry.referenceImages && entry.referenceImages.length > 0 ? 'image' : 'text';
      const aspectRatio = (entry.generationInfo.aspectRatio || 'N/A').replace(':', 'x');
      const defaultFileName = `prompt_${safeTimestamp}_${type}_${aspectRatio}.plib`;

      try {
        if (isTauriEnvironment()) {
          try {
            const dialog = await import('@tauri-apps/api/dialog');
            const selectedPath = await dialog.save({
              defaultPath: defaultFileName,
              title: 'Save .plib File',
              filters: [
                {
                  name: 'Prompt Library',
                  extensions: ['plib'],
                },
              ],
            });

            if (!selectedPath) {
              return;
            }

            const fs = await import('@tauri-apps/api/fs');
            const finalPath = selectedPath.toLowerCase().endsWith('.plib') ? selectedPath : `${selectedPath}.plib`;
            await fs.writeTextFile({ path: finalPath, contents: jsonString });
            onShowToast('.plib file saved successfully.', 'success');
            return;
          } catch (nativeError) {
            console.error('Native .plib save failed; falling back to browser download.', nativeError);
          }
        }

        triggerBlobDownload(blob, defaultFileName);
        onShowToast('.plib file downloaded.', 'success');
      } catch (error) {
        console.error('Unexpected error while saving .plib file.', error);
        onShowToast('Failed to save .plib file.', 'error');
      }
    },
    [entry, onShowToast]
  );

  const handleCopy = useCallback(() => {
    if (!entry) return;
    const resolvedPrompt = entry.prompt?.trim() ? entry.prompt : entry.blindPrompt || '';
    if (!resolvedPrompt) return;
    navigator.clipboard.writeText(resolvedPrompt).then(() => {
      setIsCopied(true);
      setTimeout(() => setIsCopied(false), 2000);
    });
  }, [entry]);

  if (!isOpen || !entry) return null;

  const { images, generationInfo, referenceImages } = entry;
  const activeImage = images[currentImageIndex] ?? images[0] ?? '';
  const primaryPrompt = entry.prompt?.trim() ?? '';
  const fallbackPrompt = entry.blindPrompt?.trim() ?? '';
  const displayedPrompt = primaryPrompt || fallbackPrompt || 'No prompt provided.';
  const isPlibEntry = useMemo(() => {
    if (!entry?.sourcePath) return false;
    return /\.plib$/i.test(entry.sourcePath);
  }, [entry?.sourcePath]);
  const fileName =
    entry.fileMetadata?.fileName || entry.sourcePath?.split(/[\\/]/).pop() || 'Unknown file';
  const fileType =
    entry.fileMetadata?.fileType || (isPlibEntry ? 'Prompt Library File' : 'Unknown type');
  const metadataWidth = entry.fileMetadata?.width ?? null;
  const metadataHeight = entry.fileMetadata?.height ?? null;
  const hasDimensions = typeof metadataWidth === 'number' && typeof metadataHeight === 'number';
  const dimensionLabel = hasDimensions ? `${metadataWidth}px × ${metadataHeight}px` : 'Unknown';
  const modifiedLabel =
    typeof entry.fileMetadata?.modifiedMs === 'number'
      ? new Date(entry.fileMetadata.modifiedMs).toLocaleString()
      : 'Unknown';
  const contextMenuStyle = useMemo<React.CSSProperties | null>(() => {
    if (!imageContextMenu) return null;
    const menuWidth = 200;
    const menuHeight = 96;
    const viewportWidth = typeof window !== 'undefined' ? window.innerWidth : null;
    const viewportHeight = typeof window !== 'undefined' ? window.innerHeight : null;
    const adjustedLeft =
      viewportWidth !== null ? Math.min(imageContextMenu.x, Math.max(0, viewportWidth - menuWidth)) : imageContextMenu.x;
    const adjustedTop =
      viewportHeight !== null
        ? Math.min(imageContextMenu.y, Math.max(0, viewportHeight - menuHeight))
        : imageContextMenu.y;
    return { top: adjustedTop, left: adjustedLeft };
  }, [imageContextMenu]);

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
        <div
          className="w-full md:w-[calc(100%-400px)] h-2/3 md:h-full bg-black flex items-center justify-center relative group p-4"
          onContextMenu={(event) => {
            const targetElement = event.target as HTMLElement | null;
            if (targetElement?.closest('button')) {
              return;
            }
            openContextMenuForTarget(event, { type: 'image', index: currentImageIndex });
          }}
        >
          <div
            ref={viewerRef}
            className="w-full h-full relative overflow-hidden rounded-xl bg-neutral-900/60"
            onMouseMove={handleMouseMoveOnImage}
            onClick={toggleZoom}
            style={{ cursor: isZoomed ? 'zoom-out' : 'zoom-in' }}
          >
            <div className="w-full h-full flex items-center justify-center select-none">
              <div
                className="w-full h-full flex items-center justify-center"
                style={{
                  transform: `scale(${isZoomed ? ZOOM_SCALE : BASE_ZOOM})`,
                  transformOrigin: `${panPosition.x}% ${panPosition.y}%`,
                  transition: 'transform 150ms ease-out, transform-origin 150ms ease-out',
                }}
              >
                <ImageDisplay
                  src={activeImage}
                  alt={`Generated content ${currentImageIndex + 1}`}
                  containerClassName="w-full h-full overflow-visible"
                  className="w-full h-full object-contain pointer-events-none select-none"
                  draggable={false}
                />
              </div>
            </div>
          </div>

          {/* Prev/Next buttons */}
          <button
            onClick={(event) => {
              event.stopPropagation();
              onPrevFile();
            }}
            className={`absolute left-4 top-1/2 -translate-y-1/2 text-white bg-neutral-800/50 rounded-full p-2 hover:bg-neutral-700 transition-colors disabled:opacity-0 disabled:cursor-not-allowed ${
              isZoomed ? 'opacity-0 pointer-events-none' : 'opacity-0 group-hover:opacity-100 focus:opacity-100'
            }`}
            aria-label="Previous file"
            disabled={!canGoPrev}
            title="Previous file (Left arrow)"
          >
            <ChevronLeftIcon className="h-8 w-8" />
          </button>
          <button
            onClick={(event) => {
              event.stopPropagation();
              onNextFile();
            }}
            className={`absolute right-4 top-1/2 -translate-y-1/2 text-white bg-neutral-800/50 rounded-full p-2 hover:bg-neutral-700 transition-colors disabled:opacity-0 disabled:cursor-not-allowed ${
              isZoomed ? 'opacity-0 pointer-events-none' : 'opacity-0 group-hover:opacity-100 focus:opacity-100'
            }`}
            aria-label="Next file"
            disabled={!canGoNext}
            title="Next file (Right arrow)"
          >
            <ChevronRightIcon className="h-8 w-8" />
          </button>

          {images.length > 1 && (
            <div
              className={`absolute bottom-4 left-1/2 -translate-x-1/2 flex gap-2 bg-neutral-900/80 backdrop-blur-sm rounded-xl p-2 max-w-full overflow-x-auto transition-opacity ${
                isZoomed ? 'opacity-0 pointer-events-none' : 'opacity-100'
              }`}
            >
              {images.map((img, index) => (
                <button
                  key={index}
                  onClick={(e) => {
                    e.stopPropagation();
                    onSelectImage(index);
                  }}
                  onContextMenu={(event) => openContextMenuForTarget(event, { type: 'image', index })}
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
          
          <div className="flex-grow flex flex-col pt-8 space-y-6 text-zinc-300">
            <h2 className="text-xl font-bold text-white pr-8">Details</h2>

            <div>
              <h4 className="text-sm font-semibold text-zinc-400 mb-2">File Name</h4>
              <div className="bg-neutral-900/70 p-3 rounded-lg border border-neutral-700 text-sm">
                <p className="text-zinc-200 break-words">{fileName}</p>
              </div>
            </div>

            {isPlibEntry && (
              <div>
                <h4 className="text-sm font-semibold text-neutral-400 mb-2 flex items-center gap-2">
                  <TerminalIcon className="w-4 h-4" />
                  Prompt
                </h4>
                <div className="relative bg-neutral-900/70 p-3 rounded-lg border border-neutral-700 text-base max-h-48 overflow-y-auto">
                  <p className="text-neutral-200 whitespace-pre-wrap text-sm">{displayedPrompt}</p>
                  <button
                    onClick={handleCopy}
                    className="absolute top-2 right-2 p-1.5 text-neutral-400 hover:text-white bg-neutral-700/50 hover:bg-neutral-700 rounded-md transition"
                    title={isCopied ? 'Copied!' : 'Copy prompt'}
                  >
                    <CopyIcon className="w-4 h-4" />
                  </button>
                </div>
              </div>
            )}

            {isPlibEntry ? (
              <div>
                <h4 className="text-sm font-semibold text-neutral-400 mb-3">Generation Info</h4>
                <div className="grid grid-cols-2 gap-3 text-zinc-300 text-sm">
                  <div className="bg-neutral-900/70 p-3 rounded-lg border border-neutral-700">
                    <div className="text-xs text-zinc-500">Model</div>
                    <div className="font-medium truncate">{generationInfo.model}</div>
                  </div>
                  <div className="bg-neutral-900/70 p-3 rounded-lg border border-neutral-700">
                    <div className="text-xs text-zinc-500">Aspect Ratio</div>
                    <div className="font-medium">{generationInfo.aspectRatio}</div>
                  </div>
                  <div className="col-span-2 bg-neutral-900/70 p-3 rounded-lg border border-neutral-700">
                    <div className="text-xs text-zinc-500">Timestamp</div>
                    <div className="font-medium">{new Date(generationInfo.timestamp).toLocaleString()}</div>
                  </div>
                </div>
              </div>
            ) : (
              <div>
                <h4 className="text-sm font-semibold text-neutral-400 mb-3">File Details</h4>
                <div className="grid grid-cols-2 gap-3 text-zinc-300 text-sm">
                  <div className="bg-neutral-900/70 p-3 rounded-lg border border-neutral-700 col-span-2">
                    <div className="text-xs text-zinc-500">File Type</div>
                    <div className="font-medium">{fileType}</div>
                  </div>
                  <div className="bg-neutral-900/70 p-3 rounded-lg border border-neutral-700">
                    <div className="text-xs text-zinc-500">Dimensions</div>
                    <div className="font-medium">{dimensionLabel}</div>
                  </div>
                  <div className="bg-neutral-900/70 p-3 rounded-lg border border-neutral-700">
                    <div className="text-xs text-zinc-500">Date</div>
                    <div className="font-medium">{modifiedLabel}</div>
                  </div>
                </div>
              </div>
            )}

            {referenceImages && referenceImages.length > 0 && (
              <div>
                <h4 className="text-sm font-semibold text-neutral-400 mb-2">Reference Images</h4>
                <div className="flex flex-wrap gap-2">
                  {referenceImages.map((img, index) => (
                    <div
                      key={index}
                      className="w-16 h-16 rounded-md overflow-hidden"
                      onContextMenu={(event) => openContextMenuForTarget(event, { type: 'reference', index })}
                    >
                      <ImageDisplay
                        src={img}
                        alt={`Reference ${index + 1}`}
                        containerClassName="w-full h-full rounded-md"
                        className="w-full h-full object-cover"
                      />
                    </div>
                  ))}
                </div>
              </div>
            )}
            
            <div className="flex-grow"></div>
            
            {isPlibEntry && (
              <div className="pt-6 mt-auto border-t border-neutral-700 space-y-3 flex-shrink-0">
                <button
                  onClick={handleDownload}
                  className="w-full flex items-center justify-center gap-2 px-4 py-3 text-base font-semibold rounded-lg text-neutral-200 bg-neutral-700 hover:bg-neutral-600 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-offset-neutral-800 focus:ring-white transition-colors duration-200"
                  disabled={isDownloading}
                >
                  <DownloadIcon className="w-5 h-5" />
                  {isDownloading ? 'Preparing Save...' : `Save Image (${currentImageIndex + 1} of ${images.length})`}
                </button>
                <button
                  onClick={handleSavePlib}
                  className="w-full flex items-center justify-center gap-2 px-4 py-3 text-base font-semibold rounded-lg text-neutral-200 bg-neutral-700 hover:bg-neutral-600 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-offset-neutral-800 focus:ring-white transition-colors duration-200"
                >
                  <SaveIcon className="w-5 h-5" />
                  Save .plib
                </button>
              </div>
            )}
          </div>
        </div>
      </div>

      {imageContextMenu && contextMenuStyle && (
        <div
          className="fixed inset-0 z-[60]"
          onClick={(event) => {
            event.stopPropagation();
            setImageContextMenu(null);
          }}
          onContextMenu={(event) => {
            event.preventDefault();
            event.stopPropagation();
          }}
        >
          <div
            className="absolute bg-neutral-800 border border-neutral-700 rounded-md shadow-2xl py-1 text-sm text-neutral-100 min-w-[180px]"
            style={contextMenuStyle}
            onClick={(event) => event.stopPropagation()}
          >
            <button
              className="w-full px-4 py-2 text-left hover:bg-neutral-700 flex items-center justify-between gap-4"
              onClick={(event) => {
                event.stopPropagation();
                handleContextMenuAction('save');
              }}
            >
              Save Image
              <SaveIcon className="w-4 h-4 text-neutral-400" />
            </button>
            <button
              className="w-full px-4 py-2 text-left hover:bg-neutral-700 flex items-center justify-between gap-4"
              onClick={(event) => {
                event.stopPropagation();
                handleContextMenuAction('copy');
              }}
            >
              Copy Image
              <CopyIcon className="w-4 h-4 text-neutral-400" />
            </button>
          </div>
        </div>
      )}
    </div>
  );
};

export default Lightbox;
