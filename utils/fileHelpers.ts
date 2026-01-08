export const isImageFile = (name: string) => /\.(png|jpe?g|webp|gif)$/i.test(name);
export const isPlibFile = (name: string) => /\.plib$/i.test(name);
export const isAoeFile = (name: string) => /\.aoe$/i.test(name);
export const isPromptSnapshotFile = (name: string) => isPlibFile(name) || isAoeFile(name);

import { FsFileEntry } from '../types';

export const isPreviewableItem = (item: FsFileEntry) => {
  if (item.children) return false;
  const name = item.name?.toLowerCase() || '';
  return isPromptSnapshotFile(name) || isImageFile(name);
};

export const isDroppableFile = (path: string) => /\.(plib|aoe|png|jpe?g)$/i.test(path.toLowerCase());
