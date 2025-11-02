export type AspectRatio = "1:1" | "16:9" | "9:16" | "4:3" | "3:4";

export interface Preset {
  id: number;
  prompt: string;
  imageUrl: string;
  referenceImageUrl?: string;
  category: string;
  tags: string[];
  ratio?: AspectRatio;
}

export interface GenerationInfo {
  aspectRatio: AspectRatio;
  model: string;
  timestamp: string;
  numberOfImages: number;
}

export interface PromptEntry {
  prompt: string;
  generationInfo: GenerationInfo;
  images: string[]; // base64 encoded strings
  referenceImages?: string[]; // base64 encoded strings
}

// Type for file entries from Tauri's readDir
export interface FsFileEntry {
  path: string;
  name?: string;
  children?: FsFileEntry[]; // isDir is true if this is present
}
