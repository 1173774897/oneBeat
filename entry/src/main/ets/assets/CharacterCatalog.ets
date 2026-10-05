import { SessionMember } from '../protocol/messages';
import { isCharacterAccessible } from '../store/EntitlementStore';

export const RANDOM_AVATAR_KEY: string = 'random';
export const LAMP_AVATAR_KEY: string = 'lamp';

/** Random-only identities each ship two eight-frame palettes and one concealed lobby silhouette. */
export const RANDOM_CHARACTER_KEYS: string[] = ['braids', 'boonie', 'curly', 'buzz'];

export const TEAM_ROSTER_KEYS: string[] =
  [RANDOM_AVATAR_KEY, 'mismatch', 'cloud', 'teapot', 'wave', 'scooter', 'lilroll', LAMP_AVATAR_KEY];

export const SOLO_ONLY_ROSTER_KEYS: string[] = [];

/** 旧存档/联机仍可能带 matchman，统一映射为现在的台灯角色。 */
export function normalizeAvatarKey(key: string): string {
  if (key === 'matchman') {
    return LAMP_AVATAR_KEY;
  }
  return key;
}

export function rosterKeysForLobby(soloTeam: boolean): string[] {
  if (soloTeam) {
    return TEAM_ROSTER_KEYS.concat(SOLO_ONLY_ROSTER_KEYS);
  }
  return TEAM_ROSTER_KEYS.slice();
}

export function defaultSessionAvatar(): string {
  return RANDOM_AVATAR_KEY;
}

export function isRandomAvatar(key: string): boolean {
  return normalizeAvatarKey(key) === RANDOM_AVATAR_KEY;
}

export function isRandomPoolCharacter(key: string): boolean {
  return RANDOM_CHARACTER_KEYS.indexOf(key) >= 0;
}

export function randomPaletteCount(key: string): number {
  return isRandomPoolCharacter(key) ? 2 : 0;
}

export function pickRandomCharacterKey(): string {
  if (RANDOM_CHARACTER_KEYS.length === 0) {
    return '';
  }
  return RANDOM_CHARACTER_KEYS[Math.floor(Math.random() * RANDOM_CHARACTER_KEYS.length)];
}

export function pickRandomColorSlot(
  members: SessionMember[],
  resolvedAvatarKey: string,
  excludeMemberId: string
): number {
  const count = randomPaletteCount(resolvedAvatarKey);
  if (count <= 0) {
    return -1;
  }
  const used: boolean[] = [];
  for (let i = 0; i < count; i++) {
    used.push(false);
  }
  for (let i = 0; i < members.length; i++) {
    const member = members[i];
    if (member.id === excludeMemberId || !isRandomAvatar(member.avatarKey) ||
      member.resolvedAvatarKey !== resolvedAvatarKey) {
      continue;
    }
    const slot = member.colorSlot ?? -1;
    if (slot >= 0 && slot < count) {
      used[slot] = true;
    }
  }
  const start = Math.floor(Math.random() * count);
  for (let offset = 0; offset < count; offset++) {
    const candidate = (start + offset) % count;
    if (!used[candidate]) {
      return candidate;
    }
  }
  // Every palette is already represented, so repetition is now intentional.
  return start;
}

export function isDuplicatableAvatar(key: string): boolean {
  return isRandomAvatar(key);
}

export function isExclusiveAvatar(key: string): boolean {
  return !isDuplicatableAvatar(key);
}

export function isCharacterOwned(key: string): boolean {
  const normalized = normalizeAvatarKey(key);
  return isRandomAvatar(normalized) || isCharacterAccessible(normalized);
}

export function defaultOwnedCharacterKeys(): string[] {
  return [];
}

export function isRosterAvatarKey(key: string, soloTeam: boolean): boolean {
  return rosterKeysForLobby(soloTeam).indexOf(normalizeAvatarKey(key)) >= 0;
}

export function isAvatarAllowedForSession(key: string, soloTeam: boolean): boolean {
  const normalized = normalizeAvatarKey(key);
  return isRosterAvatarKey(normalized, soloTeam) && isCharacterOwned(normalized);
}

export function isExclusiveTakenByOther(
  members: SessionMember[],
  avatarKey: string,
  excludeMemberId: string
): boolean {
  const key = normalizeAvatarKey(avatarKey);
  if (!isExclusiveAvatar(key)) {
    return false;
  }
  for (let i = 0; i < members.length; i++) {
    const member = members[i];
    if (member.id === excludeMemberId) {
      continue;
    }
    if (normalizeAvatarKey(member.avatarKey) === key) {
      return true;
    }
  }
  return false;
}

export function getExclusiveAvatarsLockedByReadyMembers(
  members: SessionMember[],
  excludeMemberId: string = ''
): Set<string> {
  const locked: Set<string> = new Set();
  for (let i = 0; i < members.length; i++) {
    const member = members[i];
    if (member.id === excludeMemberId) {
      continue;
    }
    const key = normalizeAvatarKey(member.avatarKey);
    if (member.lobbyReady === true && isExclusiveAvatar(key)) {
      locked.add(key);
    }
  }
  return locked;
}

export function pickFallbackAvatar(members: SessionMember[], excludeMemberId: string, soloTeam: boolean): string {
  const roster = rosterKeysForLobby(soloTeam);
  const readyLocked = getExclusiveAvatarsLockedByReadyMembers(members, excludeMemberId);
  for (let i = 0; i < roster.length; i++) {
    const key = roster[i];
    if (!isCharacterOwned(key)) {
      continue;
    }
    if (isDuplicatableAvatar(key)) {
      return key;
    }
    if (readyLocked.has(key)) {
      continue;
    }
    if (!isExclusiveTakenByOther(members, key, excludeMemberId)) {
      return key;
    }
  }
  return RANDOM_AVATAR_KEY;
}

export type CharacterPickState = 'selectable' | 'taken' | 'unowned' | 'lockedByReady' | 'selfReadyLocked';

export function characterPickState(
  key: string,
  members: SessionMember[],
  editingMemberId: string,
  soloTeam: boolean
): CharacterPickState {
  const rosterKey = normalizeAvatarKey(key);
  let editingReady = false;
  for (let i = 0; i < members.length; i++) {
    if (members[i].id === editingMemberId) {
      editingReady = members[i].lobbyReady === true;
      break;
    }
  }
  if (editingReady) {
    return 'selfReadyLocked';
  }
  if (!isCharacterOwned(rosterKey) || !isAvatarAllowedForSession(rosterKey, soloTeam)) {
    return 'unowned';
  }
  const readyLocked = getExclusiveAvatarsLockedByReadyMembers(members, editingMemberId);
  if (readyLocked.has(rosterKey)) {
    return 'lockedByReady';
  }
  if (isExclusiveTakenByOther(members, rosterKey, editingMemberId)) {
    return 'taken';
  }
  return 'selectable';
}

export function sortRosterKeysForPicker(keys: string[]): string[] {
  const available: string[] = [];
  const locked: string[] = [];
  for (let i = 0; i < keys.length; i++) {
    if (isCharacterOwned(keys[i])) {
      available.push(keys[i]);
    } else {
      locked.push(keys[i]);
    }
  }
  const fallbackIndex = available.indexOf(RANDOM_AVATAR_KEY);
  if (fallbackIndex > 0) {
    available.splice(fallbackIndex, 1);
    available.unshift(RANDOM_AVATAR_KEY);
  }
  return available.concat(locked);
}
