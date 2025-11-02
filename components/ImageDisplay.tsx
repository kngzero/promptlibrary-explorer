import React, { useState, useEffect, useRef } from 'react';
import { BrokenImageIcon } from './icons';

interface ImageDisplayProps extends React.ImgHTMLAttributes<HTMLImageElement> {
  src: string;
  alt: string;
  containerClassName?: string;
}

const ImageDisplay: React.FC<ImageDisplayProps> = ({ src, alt, className, containerClassName, ...props }) => {
  const [isLoaded, setIsLoaded] = useState(false);
  const [hasError, setHasError] = useState(false);
  const [isInView, setIsInView] = useState(false);
  const placeholderRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    // If it's a data URL, we can assume it's "in view" immediately
    // as it doesn't need to be fetched.
    if (src.startsWith('data:')) {
      setIsInView(true);
      return;
    }

    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          setIsInView(true);
          observer.disconnect();
        }
      },
      {
        rootMargin: '200px 0px', // Start loading images 200px before they enter the viewport for a smoother experience
      }
    );

    const currentRef = placeholderRef.current;
    if (currentRef) {
      observer.observe(currentRef);
    }

    return () => {
      if (currentRef) {
        observer.unobserve(currentRef);
      }
    };
  }, [src]);

  const handleLoad = () => {
    setIsLoaded(true);
  };

  const handleError = () => {
    setHasError(true);
  };

  return (
    <div ref={placeholderRef} className={`relative bg-neutral-900 overflow-hidden ${containerClassName || ''}`}>
      {/* Skeleton Loader */}
      {!isLoaded && !hasError && (
        <div className="absolute inset-0 bg-neutral-900 animate-pulse"></div>
      )}

      {/* Error State */}
      {hasError && (
        <div className="absolute inset-0 flex items-center justify-center bg-zinc-800 text-zinc-500">
          <BrokenImageIcon className="w-1/3 h-1/3" />
        </div>
      )}
      
      {/* Actual Image */}
      {isInView && (
        <img
          src={src}
          alt={alt}
          onLoad={handleLoad}
          onError={handleError}
          className={`transition-opacity duration-500 ${isLoaded && !hasError ? 'opacity-100' : 'opacity-0'} ${className || ''}`}
          {...props}
        />
      )}
    </div>
  );
};

export default ImageDisplay;