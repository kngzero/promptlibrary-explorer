import { readTextFile } from '@tauri-apps/api/fs';
import type { PromptAnalysis, PromptEntry } from '../types';

type AoeImageBlock = {
  previewUrl?: string;
  base64?: string;
  mimeType?: string;
};

type AoeFile = {
  timestamp?: number;
  image?: AoeImageBlock;
  analysis?: PromptAnalysis;
  model?: string;
  hint?: string;
};

const cache = new Map<string, PromptEntry>();

const extractPrompt = (analysis: PromptAnalysis | undefined): { prompt: string; shortDescription: string } => {
  if (!analysis) return { prompt: '', shortDescription: '' };

  const fullPrompt = typeof analysis.full_prompt === 'string' ? analysis.full_prompt.trim() : '';
  const shortDescription =
    typeof analysis.short_description === 'string' ? analysis.short_description.trim() : '';

  return {
    prompt: fullPrompt || shortDescription,
    shortDescription,
  };
};

const normalizeImage = (image: AoeImageBlock | undefined): { display: string | null; raw: string | null; mimeType: string } => {
  const mimeType = image?.mimeType?.trim() || 'image/jpeg';
  const previewUrl = image?.previewUrl?.trim() || null;
  const base64 = image?.base64?.trim() || null;

  if (previewUrl) {
    return { display: previewUrl, raw: base64 || previewUrl, mimeType };
  }

  if (base64) {
    return { display: `data:${mimeType};base64,${base64}`, raw: base64, mimeType };
  }

  return { display: null, raw: null, mimeType };
};

/**
 * Reads and normalizes an .aoe snapshot file into a PromptEntry.
 */
export const getAoeData = async (filePath: string): Promise<PromptEntry | null> => {
  if (cache.has(filePath)) {
    return cache.get(filePath) || null;
  }

  try {
    const contents = await readTextFile(filePath);
    const parsed: AoeFile = JSON.parse(contents);

    const { display, raw } = normalizeImage(parsed.image);
    if (!display) {
      console.warn(`Invalid .aoe file (missing image data): ${filePath}`);
      return null;
    }

    const { prompt: analysisPrompt, shortDescription } = extractPrompt(parsed.analysis);
    const hint = typeof parsed.hint === 'string' && parsed.hint.trim() ? parsed.hint.trim() : '';
    const timestampMs =
      typeof parsed.timestamp === 'number' && Number.isFinite(parsed.timestamp)
        ? parsed.timestamp
        : Date.now();

    const resolvedPrompt = analysisPrompt || hint || shortDescription || 'Recovered snapshot';

    const entry: PromptEntry = {
      prompt: resolvedPrompt,
      blindPrompt: shortDescription || hint || undefined,
      hint: hint || undefined,
      images: [display],
      rawImages: [raw ?? display],
      generationInfo: {
        aspectRatio: 'N/A',
        model: parsed.model || 'Art Official Elements Snapshot',
        timestamp: new Date(timestampMs).toISOString(),
        numberOfImages: 1,
      },
      sourcePath: filePath,
      analysis: parsed.analysis,
    };

    cache.set(filePath, entry);
    return entry;
  } catch (error) {
    console.error(`Failed to read or parse .aoe file: ${filePath}`, error);
    return null;
  }
};

export const clearAoeCache = () => {
  cache.clear();
};
