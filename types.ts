// Aspect ratio reported by image generators. Falls back to 'N/A' for unknown assets.
export type AspectRatio = "1:1" | "16:9" | "9:16" | "4:3" | "3:4" | "N/A";

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

export interface FileMetadata {
  fileName: string;
  fileType: string;
  width?: number | null;
  height?: number | null;
  modifiedMs?: number | null;
}

export interface PromptEntry {
  prompt: string;
  blindPrompt?: string;
  hint?: string;
  generationInfo: GenerationInfo;
  images: string[]; // base64 encoded strings or Tauri file URLs for display
  referenceImages?: string[]; // base64 encoded strings or Tauri file URLs for display
  sourcePath?: string; // original filesystem path for the .plib or image file
  rawImages?: string[]; // unmodified data as read from the source .plib or file path
  rawReferenceImages?: string[]; // unmodified data for reference images
  analysis?: PromptAnalysis;
  fileMetadata?: FileMetadata | null;
}

// Type for file entries from Tauri's readDir
export interface FsFileEntry {
  path: string;
  name?: string;
  children?: FsFileEntry[]; // isDir is true if this is present
}

export type SortField = "type" | "name";
export type SortDirection = "asc" | "desc";

export interface SortConfig {
  field: SortField;
  direction: SortDirection;
}

export interface FilterConfig {
  hideOther: boolean;
  hideJpg: boolean;
  hidePng: boolean;
}

export interface Breadcrumb {
  name: string;
  path: string;
}

export interface PromptAnalysis {
  full_prompt?: string;
  short_description?: string;
  subject?: string;
  subject_pose?: string;
  composition?: string;
  art_style?: string;
  camera_settings?: string;
  lighting?: string;
  color_palette?: string;
  mood?: string;
  [key: string]: unknown;
}
