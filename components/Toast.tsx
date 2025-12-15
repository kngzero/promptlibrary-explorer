import React, { useEffect, useState } from 'react';
import { CheckIcon, ErrorIcon } from './icons';

type ToastType = 'success' | 'error' | 'info';

interface ToastProps {
  message: string;
  type: ToastType;
  onClose: () => void;
}

const ICONS: Record<ToastType, React.ReactNode> = {
  success: <CheckIcon className="h-6 w-6 text-green-300" />,
  error: <ErrorIcon className="h-6 w-6 text-red-300" />,
  info: <CheckIcon className="h-6 w-6 text-blue-300" />, // Using CheckIcon for info for simplicity
};

const BG_COLORS: Record<ToastType, string> = {
  success: 'bg-green-800/90 border-green-600/50',
  error: 'bg-red-900/90 border-red-500/50',
  info: 'bg-blue-800/90 border-blue-600/50',
};

const Toast: React.FC<ToastProps> = ({ message, type, onClose }) => {
  const [isExiting, setIsExiting] = useState(false);

  useEffect(() => {
    const timer = setTimeout(() => {
      setIsExiting(true);
    }, 3000); // Auto-dismiss after 3 seconds

    return () => clearTimeout(timer);
  }, []);

  useEffect(() => {
    if (isExiting) {
      const timer = setTimeout(onClose, 300); // Wait for animation to finish
      return () => clearTimeout(timer);
    }
  }, [isExiting, onClose]);

  return (
    <div
      className={`fixed top-5 left-1/2 -translate-x-1/2 z-[1200] pointer-events-none max-w-sm w-auto px-6 py-4 rounded-xl shadow-lg flex flex-col items-center text-center gap-3 text-white backdrop-blur-md ${BG_COLORS[type]} ${isExiting ? 'animate-slide-out-up' : 'animate-slide-in-down'}`}
      role="alert"
    >
      <div className="flex items-center justify-center">{ICONS[type]}</div>
      <p className="text-sm font-medium">{message}</p>
    </div>
  );
};

export default Toast;
