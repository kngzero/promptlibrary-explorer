import React, { useEffect, useMemo, useState } from 'react';
import ImageDisplay from './ImageDisplay';
import { BracesIcon, CheckIcon, ChevronRightIcon, CloseIcon, CompareIcon, CopyIcon, PencilIcon } from './icons';
import type { PromptEntry } from '../types';

type SegmentKey =
  | 'full_prompt'
  | 'short_description'
  | 'subject'
  | 'subject_pose'
  | 'composition'
  | 'art_style'
  | 'lighting'
  | 'camera_settings'
  | 'color_palette'
  | 'mood';

type SegmentState = Record<SegmentKey, string>;
type SelectionState = Partial<Record<SegmentKey, { from: 'A' | 'B'; value: string }>>;

const SEGMENTS: { key: SegmentKey; label: string; accent: string }[] = [
  { key: 'full_prompt', label: 'Full Prompt', accent: '#ffffff' },
  { key: 'short_description', label: 'Brief', accent: '#e5e7eb' },
  { key: 'subject', label: 'Subject', accent: '#f472b6' },
  { key: 'subject_pose', label: 'Action', accent: '#38bdf8' },
  { key: 'composition', label: 'Place', accent: '#34d399' },
  { key: 'art_style', label: 'Style', accent: '#a78bfa' },
  { key: 'lighting', label: 'Lighting', accent: '#f59e0b' },
  { key: 'camera_settings', label: 'Camera', accent: '#fb923c' },
  { key: 'color_palette', label: 'Palette', accent: '#f472b6' },
  { key: 'mood', label: 'Mood', accent: '#fb7185' },
];

const normalizeWord = (word: string) => word.toLowerCase().replace(/[^\w'-]/g, '').trim();

const buildReferenceSet = (text: string) => {
  if (!text) return new Set<string>();
  const parts = text.split(/\s+/).map(normalizeWord).filter(Boolean);
  return new Set(parts);
};

const diffTokens = (text: string, referenceSet: Set<string>) => {
  if (!text) return [{ text: '—', unique: false }];
  const parts = text.split(/(\s+)/);
  return parts.map((part) => {
    const normalized = normalizeWord(part);
    const isWord = !!normalized;
    const unique = isWord && !referenceSet.has(normalized);
    return { text: part, unique };
  });
};

const buildSegmentState = (entry: PromptEntry | null): SegmentState => {
  const analysis = entry?.analysis ?? {};
  return SEGMENTS.reduce((acc, { key }) => {
    const raw = (analysis as Record<string, unknown>)[key];
    const value = typeof raw === 'string' && raw.trim() ? raw.trim() : '';
    if (key === 'full_prompt' && !value) {
      acc[key] = entry?.prompt?.trim() || '';
    } else if (key === 'short_description' && !value) {
      acc[key] = entry?.blindPrompt?.trim() || entry?.hint?.trim() || '';
    } else {
      acc[key] = value;
    }
    return acc;
  }, {} as SegmentState);
};

interface StackItemProps {
  label: string;
  value: string;
  referenceValue: string;
  selected: boolean;
  accentColor: string;
  highlightEnabled: boolean;
  collapsed: boolean;
  onChange: (value: string) => void;
  onToggle: () => void;
  onToggleCollapse: () => void;
}

const StackItem: React.FC<StackItemProps> = ({
  label,
  value,
  referenceValue,
  selected,
  accentColor,
  highlightEnabled,
  collapsed,
  onChange,
  onToggle,
  onToggleCollapse,
}) => {
  const [isEditing, setIsEditing] = useState(false);
  const [draft, setDraft] = useState(value);

  useEffect(() => {
    setDraft(value);
  }, [value]);

  const referenceSet = useMemo(() => buildReferenceSet(referenceValue), [referenceValue]);
  const tokens = useMemo(() => diffTokens(value, referenceSet), [value, referenceSet]);

  const handleSave = (e: React.MouseEvent) => {
    e.stopPropagation();
    onChange(draft.trim());
    setIsEditing(false);
  };

  const handleCancel = (e: React.MouseEvent) => {
    e.stopPropagation();
    setDraft(value);
    setIsEditing(false);
  };

  return (
    <div
      onClick={onToggle}
      className={`rounded-lg border transition-all duration-150 bg-zinc-900/60 hover:bg-zinc-900/90 ${
        selected ? 'border-fuchsia-500 shadow-[0_0_0_2px_rgba(217,70,239,0.35)] shadow-fuchsia-500/30' : 'border-zinc-800 hover:border-zinc-700'
      }`}
      style={{ borderLeft: `4px solid ${accentColor}` }}
    >
      <div className="flex items-center justify-between gap-2 px-3 py-2">
        <div className="flex items-center gap-2">
          <button
            onClick={(e) => {
              e.stopPropagation();
              onToggleCollapse();
            }}
            className="p-1 rounded-md hover:bg-zinc-800 text-zinc-400"
            title={collapsed ? 'Expand' : 'Collapse'}
          >
            <ChevronRightIcon
              className={`w-4 h-4 transition-transform ${collapsed ? '' : 'rotate-90'}`}
            />
          </button>
          <span className="inline-block w-2 h-2 rounded-full" style={{ backgroundColor: accentColor }} />
          <span className="text-xs font-semibold uppercase tracking-wide text-zinc-300">{label}</span>
        </div>
        <div className="flex items-center gap-2">
          {isEditing ? (
            <>
              <button
                onClick={handleSave}
                className="p-1 rounded-md bg-fuchsia-600 text-white hover:bg-fuchsia-500"
                title="Save changes"
              >
                <CheckIcon className="w-3.5 h-3.5" />
              </button>
              <button
                onClick={handleCancel}
                className="p-1 rounded-md bg-zinc-800 text-zinc-200 hover:bg-zinc-700"
                title="Cancel editing"
              >
                <CloseIcon className="w-3.5 h-3.5" />
              </button>
            </>
          ) : (
            <button
              onClick={(e) => {
                e.stopPropagation();
                setIsEditing(true);
              }}
              className="p-1 rounded-md bg-zinc-800 text-zinc-200 hover:bg-zinc-700"
              title="Edit this segment"
            >
              <PencilIcon className="w-3.5 h-3.5" />
            </button>
          )}
        </div>
      </div>
      {!collapsed && (
        <div className="px-3 pb-3">
          {isEditing ? (
            <textarea
              value={draft}
              onClick={(e) => e.stopPropagation()}
              onChange={(e) => setDraft(e.target.value)}
              className="w-full rounded-md bg-zinc-950 border border-zinc-800 px-2 py-2 text-sm text-zinc-100 focus:outline-none focus:ring-2 focus:ring-fuchsia-500 resize-none"
              rows={3}
              placeholder="Describe this segment..."
            />
          ) : (
            <p className="text-sm leading-relaxed text-zinc-100 whitespace-pre-wrap">
              {tokens.map((token, idx) =>
                token.unique && highlightEnabled ? (
                  <span
                    key={`${token.text}-${idx}`}
                    className="bg-fuchsia-500/10 underline decoration-2 decoration-fuchsia-400 underline-offset-4 rounded-sm px-0.5"
                  >
                    {token.text}
                  </span>
                ) : (
                  <span key={`${token.text}-${idx}`}>{token.text}</span>
                )
              )}
            </p>
          )}
        </div>
      )}
    </div>
  );
};

interface PromptStackProps {
  title: string;
  entry: PromptEntry | null;
  segments: SegmentState;
  referenceSegments: SegmentState;
  selectedKeys: Set<SegmentKey>;
  accentPalette: Record<SegmentKey, string>;
  highlightEnabled: boolean;
  collapsedKeys: Set<SegmentKey>;
  onChangeSegment: (key: SegmentKey, value: string) => void;
  onToggleSegment: (key: SegmentKey) => void;
  onToggleCollapse: (key: SegmentKey) => void;
  accentColor: string;
}

const PromptStack: React.FC<PromptStackProps> = ({
  title,
  entry,
  segments,
  referenceSegments,
  selectedKeys,
  accentPalette,
  highlightEnabled,
  collapsedKeys,
  onChangeSegment,
  onToggleSegment,
  onToggleCollapse,
  accentColor,
}) => {
  const palette = accentPalette;
  return (
    <div className="bg-zinc-900/80 border border-zinc-800 rounded-xl p-3 flex flex-col gap-3 overflow-hidden h-full min-h-0">
      <div className="flex items-center gap-3">
        <div className={`w-9 h-9 rounded-lg flex items-center justify-center text-sm font-bold ${accentColor} bg-zinc-800`}>
          {title}
        </div>
        <div className="flex flex-col overflow-hidden">
          <span className="text-sm font-semibold text-white truncate">
            {entry?.fileMetadata?.fileName || entry?.sourcePath?.split(/[\\/]/).pop() || 'Snapshot'}
          </span>
          <span className="text-xs text-zinc-400 truncate">
            {entry?.generationInfo?.model || 'Art Official Elements'}
          </span>
        </div>
      </div>

      {entry?.images?.[0] && (
        <div className="rounded-lg border border-zinc-800 overflow-hidden">
          <ImageDisplay
            src={entry.images[0]}
            alt={`${title} preview`}
            containerClassName="w-full h-40 bg-zinc-950"
            className="w-full h-full object-cover"
          />
        </div>
      )}

      <div className="flex items-center justify-between text-xs text-zinc-400">
      </div>

      <div className="space-y-2 overflow-y-auto pr-1 custom-scrollbar">
        {SEGMENTS.map(({ key, label }) => (
          <StackItem
            key={key}
            label={label}
            value={segments[key] || ''}
            referenceValue={referenceSegments[key] || ''}
            selected={selectedKeys.has(key)}
            accentColor={palette[key]}
            highlightEnabled={highlightEnabled}
            collapsed={collapsedKeys.has(key)}
            onChange={(value) => onChangeSegment(key, value)}
            onToggle={() => onToggleSegment(key)}
            onToggleCollapse={() => onToggleCollapse(key)}
          />
        ))}
      </div>
    </div>
  );
};

interface AoeComparisonModalProps {
  sourceA: PromptEntry | null;
  sourceB: PromptEntry | null;
  onClose: () => void;
}

const AoeComparisonModal: React.FC<AoeComparisonModalProps> = ({ sourceA, sourceB, onClose }) => {
  const [segmentsA, setSegmentsA] = useState<SegmentState>(() => buildSegmentState(sourceA));
  const [segmentsB, setSegmentsB] = useState<SegmentState>(() => buildSegmentState(sourceB));
  const [selections, setSelections] = useState<SelectionState>({});
  const [isPreviewOpen, setIsPreviewOpen] = useState(() =>
    typeof window !== 'undefined' ? window.innerWidth >= 768 : true
  );
  const [highlightEnabled, setHighlightEnabled] = useState(false);
  const [collapsedA, setCollapsedA] = useState<Set<SegmentKey>>(new Set());
  const [collapsedB, setCollapsedB] = useState<Set<SegmentKey>>(new Set());

  useEffect(() => {
    setSegmentsA(buildSegmentState(sourceA));
    setSegmentsB(buildSegmentState(sourceB));
    setSelections({});
    setCollapsedA(new Set());
    setCollapsedB(new Set());
  }, [sourceA, sourceB]);

  useEffect(() => {
    const media = window.matchMedia('(min-width: 768px)');
    const handler = (event: MediaQueryListEvent) => {
      if (event.matches) {
        setIsPreviewOpen(true);
      }
    };
    media.addEventListener('change', handler);
    return () => media.removeEventListener('change', handler);
  }, []);

  const selectedKeysA = useMemo(
    () =>
      new Set(
        Object.entries(selections)
          .filter(([, payload]) => payload?.from === 'A')
          .map(([key]) => key as SegmentKey)
      ),
    [selections]
  );
  const selectedKeysB = useMemo(
    () =>
      new Set(
        Object.entries(selections)
          .filter(([, payload]) => payload?.from === 'B')
          .map(([key]) => key as SegmentKey)
      ),
    [selections]
  );

  const allCollapsed =
    collapsedA.size === SEGMENTS.length && collapsedB.size === SEGMENTS.length;

  const previewObject = useMemo(() => {
    const entries: [SegmentKey, { from: 'A' | 'B'; value: string }][] = [];
    for (const [key, payload] of Object.entries(selections)) {
      if (payload) {
        entries.push([key as SegmentKey, payload]);
      }
    }
    return Object.fromEntries(entries.map(([key, payload]) => [key, payload.value]));
  }, [selections]);

  const previewJson = useMemo(() => JSON.stringify(previewObject, null, 2), [previewObject]);

  const handleChange = (side: 'A' | 'B', key: SegmentKey, value: string) => {
    if (side === 'A') {
      setSegmentsA((prev) => ({ ...prev, [key]: value }));
    } else {
      setSegmentsB((prev) => ({ ...prev, [key]: value }));
    }

    setSelections((prev) => {
      if (prev[key]?.from === side) {
        return { ...prev, [key]: { ...prev[key], value } };
      }
      return prev;
    });
  };

  const handleToggle = (side: 'A' | 'B', key: SegmentKey) => {
    setSelections((prev) => {
      const existing = prev[key];
      if (existing?.from === side) {
        const next = { ...prev };
        delete next[key];
        return next;
      }
      const value = side === 'A' ? segmentsA[key] : segmentsB[key];
      return { ...prev, [key]: { from: side, value } };
    });
  };

  const toggleCollapseSingle = (side: 'A' | 'B', key: SegmentKey) => {
    if (side === 'A') {
      setCollapsedA((prev) => {
        const next = new Set(prev);
        if (next.has(key)) {
          next.delete(key);
        } else {
          next.add(key);
        }
        return next;
      });
    } else {
      setCollapsedB((prev) => {
        const next = new Set(prev);
        if (next.has(key)) {
          next.delete(key);
        } else {
          next.add(key);
        }
        return next;
      });
    }
  };

  const toggleCollapseAll = () => {
    if (allCollapsed) {
      setCollapsedA(new Set());
      setCollapsedB(new Set());
    } else {
      setCollapsedA(new Set(SEGMENTS.map(({ key }) => key)));
      setCollapsedB(new Set(SEGMENTS.map(({ key }) => key)));
    }
  };

  return (
    <div className="fixed inset-0 z-50 bg-black/80 backdrop-blur-sm flex items-center justify-center overflow-hidden">
      <div className="w-full h-full bg-zinc-950 border-t border-zinc-800 overflow-hidden flex flex-col">
        <div className="flex items-center justify-between px-4 py-3 border-b border-zinc-800 flex-shrink-0">
          <div className="flex items-center gap-3">
            <CompareIcon className="w-5 h-5 text-fuchsia-400" />
            <div>
              <h2 className="text-lg font-semibold text-white leading-tight">AOE Comparison</h2>
              <p className="text-xs text-zinc-400">
                Select a card to add it to Hybrid JSON. Toggle highlight to see unique words.
              </p>
            </div>
          </div>
          <div className="flex items-center gap-3">
            <button
              onClick={toggleCollapseAll}
              className="px-3 py-1.5 text-xs rounded-md border border-zinc-700 bg-zinc-800 text-zinc-200 hover:bg-zinc-700"
              title={allCollapsed ? 'Expand all segments' : 'Collapse all segments'}
            >
              {allCollapsed ? 'Expand all' : 'Collapse all'}
            </button>
            <label className="flex items-center gap-2 text-xs text-zinc-300">
              <input
                type="checkbox"
                className="h-4 w-4 rounded bg-zinc-800 border-zinc-700 text-fuchsia-500 focus:ring-fuchsia-500"
                checked={highlightEnabled}
                onChange={(e) => setHighlightEnabled(e.target.checked)}
              />
              Highlight unique words
            </label>
            <button
              onClick={onClose}
              className="p-2 rounded-lg bg-zinc-900 text-zinc-300 hover:bg-zinc-800 border border-zinc-800"
              title="Close"
            >
              <CloseIcon className="w-5 h-5" />
            </button>
          </div>
        </div>

        <div className="flex-1 grid grid-cols-1 md:grid-cols-3 gap-3 p-4 overflow-hidden min-h-0">
          <div className="md:col-span-2 grid grid-cols-1 md:grid-cols-2 gap-3 overflow-hidden min-h-0">
            <div className="overflow-hidden min-h-0">
              <PromptStack
                title="A"
                entry={sourceA}
                segments={segmentsA}
                referenceSegments={segmentsB}
                selectedKeys={selectedKeysA}
                accentPalette={Object.fromEntries(SEGMENTS.map(({ key, accent }) => [key, accent])) as Record<SegmentKey, string>}
                highlightEnabled={highlightEnabled}
                collapsedKeys={collapsedA}
                onChangeSegment={(key, value) => handleChange('A', key, value)}
                onToggleSegment={(key) => handleToggle('A', key)}
                onToggleCollapse={(key) => toggleCollapseSingle('A', key)}
                accentColor="text-fuchsia-100"
              />
            </div>
            <div className="overflow-hidden min-h-0">
              <PromptStack
                title="B"
                entry={sourceB}
                segments={segmentsB}
                referenceSegments={segmentsA}
                selectedKeys={selectedKeysB}
                accentPalette={Object.fromEntries(SEGMENTS.map(({ key, accent }) => [key, accent])) as Record<SegmentKey, string>}
                highlightEnabled={highlightEnabled}
                collapsedKeys={collapsedB}
                onChangeSegment={(key, value) => handleChange('B', key, value)}
                onToggleSegment={(key) => handleToggle('B', key)}
                onToggleCollapse={(key) => toggleCollapseSingle('B', key)}
                accentColor="text-emerald-100"
              />
            </div>
          </div>

          <div className="bg-zinc-900/70 border border-zinc-800 rounded-xl p-3 flex flex-col overflow-hidden min-h-0">
            <div className="flex items-center justify-between gap-2">
              <div className="flex items-center gap-2">
                <BracesIcon className="w-5 h-5 text-fuchsia-400" />
                <div className="text-sm font-semibold text-white">Hybrid JSON</div>
              </div>
              <div className="flex items-center gap-2">
                <button
                  className="hidden md:inline-flex items-center gap-1 text-xs px-2 py-1 rounded-md border border-zinc-700 bg-zinc-800 text-zinc-200 hover:bg-zinc-700"
                  onClick={() => {
                    navigator.clipboard?.writeText(previewJson).catch(() => {});
                  }}
                  title="Copy hybrid JSON"
                >
                  <CopyIcon className="w-3.5 h-3.5" />
                  Copy
                </button>
                <button
                  className="md:hidden text-xs px-2 py-1 rounded-md border border-zinc-700 bg-zinc-800 text-zinc-200"
                  onClick={() => setIsPreviewOpen((prev) => !prev)}
                >
                  {isPreviewOpen ? 'Hide' : 'Show'}
                </button>
              </div>
            </div>
            {isPreviewOpen && (
              <div className="mt-3 flex-1 overflow-auto rounded-lg border border-zinc-800 bg-zinc-950 p-3">
                <pre className="text-xs text-zinc-200 whitespace-pre-wrap">{previewJson}</pre>
              </div>
            )}
            {!isPreviewOpen && (
              <p className="mt-3 text-xs text-zinc-400 md:hidden">
                Collapsed on mobile to keep the stacks readable. Tap &ldquo;Show&rdquo; to view your curated JSON.
              </p>
            )}
            <div className="mt-3 text-xs text-zinc-400">
              {Object.keys(selections).length === 0
                ? 'Select any segment to build your master prompt JSON.'
                : `${Object.keys(selections).length} segment${Object.keys(selections).length === 1 ? '' : 's'} added.`}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};

export default AoeComparisonModal;
