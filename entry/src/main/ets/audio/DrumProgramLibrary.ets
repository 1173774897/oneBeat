import { common } from '@kit.AbilityKit';
import { DrumProgram, parseDrumProgram, serializeDrumProgram, styleByKey } from './DrumMachineCatalog';
import { isValidMeter } from '../common/MeterModel';
import { readOptionalSync, writeAtomicSync } from '../common/AtomicTextFile';

/** The editor and stage share stable IDs and the same local arrangement library. */
export interface SavedDrumProgram {
  id: string;
  name: string;
  program: string;
}

/** Empty libraryId means deliberately unnamed; absence means the source had no identity metadata. */
export interface RecentDrumProgram {
  program: string;
  libraryId?: string;
}

const SAVED_DRUM_PROGRAMS_KEY: string = 'savedDrumPrograms';
const RECENT_DRUM_PROGRAM_KEY: string = 'recentDrumProgram';
let libraryFilePath: string = '';

interface DrumProgramLibrarySnapshot {
  version: number;
  savedPrograms: SavedDrumProgram[];
  recentProgram?: RecentDrumProgram;
}

/** Restore before showing any page. filesDir survives process exits and updates, and belongs to this installation. */
export function initializeDrumProgramLibrary(context: common.Context): void {
  libraryFilePath = '';
  const path = `${context.filesDir}/drum-programs-v1.json`;
  const raw = readOptionalSync(path);
  if (raw.length > 0) {
    const snapshot = JSON.parse(raw) as DrumProgramLibrarySnapshot;
    if (snapshot === null || typeof snapshot !== 'object' || snapshot.version !== 1 ||
      !Array.isArray(snapshot.savedPrograms)) {
      throw new Error('我的编排读取失败，请保留应用数据后重试');
    }
    const saved = canonicalSavedPrograms(snapshot.savedPrograms);
    const recent = validatedRecentProgram(snapshot.recentProgram);
    AppStorage.setOrCreate(SAVED_DRUM_PROGRAMS_KEY, JSON.stringify(saved));
    AppStorage.setOrCreate(RECENT_DRUM_PROGRAM_KEY, recent === undefined ? '' : JSON.stringify(recent));
  } else {
    // If the ability is recreated in the same process, retain any existing in-memory records.
    const saved = loadSavedDrumPrograms();
    const recent = loadRecentDrumProgram();
    if (saved.length > 0 || recent !== undefined) {
      writeAtomicSync(path, JSON.stringify({ version: 1, savedPrograms: saved, recentProgram: recent } as DrumProgramLibrarySnapshot));
    }
  }
  libraryFilePath = path;
}

function validatedRecentProgram(recent?: RecentDrumProgram): RecentDrumProgram | undefined {
  if (recent === undefined || recent === null || typeof recent !== 'object' || Array.isArray(recent) ||
    typeof recent.program !== 'string' || !hasSavedProgramShape(recent.program) ||
    (recent.libraryId !== undefined && typeof recent.libraryId !== 'string')) { return undefined; }
  return { program: serializeDrumProgram(parseDrumProgram(recent.program)), libraryId: recent.libraryId };
}

function persistSnapshot(saved: SavedDrumProgram[], recent?: RecentDrumProgram): void {
  if (libraryFilePath.length === 0) { throw new Error('我的编排尚未准备好，请重启应用后重试'); }
  const snapshot: DrumProgramLibrarySnapshot = { version: 1, savedPrograms: saved, recentProgram: recent };
  // Store the growing library in a file: Preferences values have an 8KB string limit.
  // Commit before publishing to AppStorage; failed writes must not masquerade as successful saves.
  writeAtomicSync(libraryFilePath, JSON.stringify(snapshot));
}

function hasSavedProgramShape(raw: string): boolean {
  try {
    const parsed = JSON.parse(raw) as DrumProgram;
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed) ||
      !isValidMeter(parsed.beatsPerBar, parsed.beatUnit) ||
      !Array.isArray(parsed.sections) || parsed.sections.length === 0) {
      return false;
    }
    for (let i = 0; i < parsed.sections.length; i++) {
      const section = parsed.sections[i];
      if (section === null || typeof section !== 'object' || Array.isArray(section) ||
        typeof section.id !== 'string' || section.id.length === 0 ||
        !Number.isInteger(section.patternIndex) || section.patternIndex < 0 ||
        !Number.isInteger(section.fillIndex) || section.fillIndex < 0 ||
        !Number.isInteger(section.repeats) || section.repeats < 1 ||
        !Number.isInteger(section.fillEvery) || section.fillEvery < 0 ||
        typeof section.styleKey !== 'string' || styleByKey(section.styleKey).key !== section.styleKey) {
        return false;
      }
    }
    return true;
  } catch (_error) {
    return false;
  }
}

function canonicalSavedPrograms(entries: SavedDrumProgram[]): SavedDrumProgram[] {
  const saved: SavedDrumProgram[] = [];
  const ids: Set<string> = new Set<string>();
  for (let i = 0; i < entries.length; i++) {
    const entry = entries[i];
    if (entry === null || typeof entry !== 'object' || Array.isArray(entry) ||
      typeof entry.id !== 'string' || entry.id.trim().length === 0 || ids.has(entry.id) ||
      typeof entry.name !== 'string' || entry.name.trim().length === 0 ||
      typeof entry.program !== 'string' || !hasSavedProgramShape(entry.program)) {
      continue;
    }
    // Validate first: the Catalog's playback fallback must not turn corrupt or
    // obsolete library data into a seemingly valid new arrangement.
    const program = serializeDrumProgram(parseDrumProgram(entry.program));
    saved.push({ id: entry.id, name: entry.name, program: program });
    ids.add(entry.id);
  }
  return saved;
}

/** Returns independent canonical records; reading never rewrites or deletes the stored library. */
export function loadSavedDrumPrograms(): SavedDrumProgram[] {
  const raw = AppStorage.get<string>(SAVED_DRUM_PROGRAMS_KEY);
  if (typeof raw !== 'string' || raw.length === 0) {
    return [];
  }
  try {
    const parsed = JSON.parse(raw) as SavedDrumProgram[];
    return Array.isArray(parsed) ? canonicalSavedPrograms(parsed) : [];
  } catch (_error) {
    return [];
  }
}

/** All callers share one validation boundary while preserving accepted IDs/order. */
export function writeSavedDrumPrograms(entries: SavedDrumProgram[]): void {
  const saved = canonicalSavedPrograms(entries);
  persistSnapshot(saved, loadRecentDrumProgram());
  AppStorage.setOrCreate(SAVED_DRUM_PROGRAMS_KEY, JSON.stringify(saved));
}

/** Explicit identity survives edits; only an unknown origin may use a unique exact-content match. */
export function resolveSavedDrumProgram(
  program: string,
  libraryId: string | undefined,
  entries: SavedDrumProgram[]
): SavedDrumProgram | undefined {
  if (libraryId !== undefined) {
    return entries.find((entry: SavedDrumProgram) => entry.id === libraryId);
  }
  if (!hasSavedProgramShape(program)) { return undefined; }
  const canonical = serializeDrumProgram(parseDrumProgram(program));
  const matches = entries.filter((entry: SavedDrumProgram) => entry.program === canonical);
  return matches.length === 1 ? matches[0] : undefined;
}

/** The content and its local identity are one cache record; a save/apply cannot pair unrelated versions. */
export function rememberRecentDrumProgram(program: string, libraryId: string): void {
  const recent: RecentDrumProgram = { program: serializeDrumProgram(parseDrumProgram(program)), libraryId: libraryId };
  persistSnapshot(loadSavedDrumPrograms(), recent);
  AppStorage.setOrCreate(RECENT_DRUM_PROGRAM_KEY, JSON.stringify(recent));
}

export function loadRecentDrumProgram(): RecentDrumProgram | undefined {
  const raw = AppStorage.get<string>(RECENT_DRUM_PROGRAM_KEY);
  if (typeof raw === 'string' && raw.length > 0) {
    try {
      const recent = JSON.parse(raw) as RecentDrumProgram;
      if (recent !== null && typeof recent === 'object' && !Array.isArray(recent) &&
        typeof recent.program === 'string' && hasSavedProgramShape(recent.program) &&
        typeof recent.libraryId === 'string') {
        return { program: serializeDrumProgram(parseDrumProgram(recent.program)), libraryId: recent.libraryId };
      }
    } catch (_error) {
      // An incomplete cache cannot assign a saved record to unrelated content.
    }
  }
  const program = AppStorage.get<string>('myDrumProgram');
  return typeof program === 'string' && hasSavedProgramShape(program) ?
    { program: serializeDrumProgram(parseDrumProgram(program)) } : undefined;
}
