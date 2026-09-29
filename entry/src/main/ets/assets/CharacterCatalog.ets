import { SessionMember } from '../protocol/messages';

export const MATCHMAN_AVATAR_KEY: string = 'matchman';

export const TEAM_ROSTER_KEYS: string[] =
  ['matchman', 'mismatch', 'cloud', 'teapot', 'wave', 'scooter'];

export const SOLO_ONLY_ROSTER_KEYS: string[] = ['lilroll'];

export function rosterKeysForLobby(soloTeam: boolean): string[] {
  if (soloTeam) {
    return TEAM_ROSTER_KEYS.concat(SOLO_ONLY_ROSTER_KEYS);
  }
  return TEAM_ROSTER_KEYS.slice();
}

export function defaultSessionAvatar(): string {
  return MATCHMAN_AVATAR_KEY;
}

export function isDuplicatableAvatar(key: string): boolean {
  return key === MATCHMAN_AVATAR_KEY;
}

export function isExclusiveAvatar(key: string): boolean {
  return !isDuplicatableAvatar(key);
}

export function isCharacterOwned(key: string): boolean {
  if (key === MATCHMAN_AVATAR_KEY) {
    return true;
  }
  if (AppStorage.get<boolean>('storePassActive') === true) {
    return true;
  }
  const raw = AppStorage.get<string>('storeOwnedCharacters') ?? '';
  if (raw.length === 0) {
    return defaultOwnedCharacterKeys().indexOf(key) >= 0;
  }
  try {
    const owned = JSON.parse(raw) as string[];
    return owned.indexOf(key) >= 0;
  } catch (_e) {
    return defaultOwnedCharacterKeys().indexOf(key) >= 0;
  }
}

export function defaultOwnedCharacterKeys(): string[] {
  return [MATCHMAN_AVATAR_KEY, 'cloud', 'mismatch', 'teapot', 'wave', 'scooter'];
}

export function isRosterAvatarKey(key: string, soloTeam: boolean): boolean {
  return rosterKeysForLobby(soloTeam).indexOf(key) >= 0;
}

export function isAvatarAllowedForSession(key: string, soloTeam: boolean): boolean {
  return isRosterAvatarKey(key, soloTeam) && isCharacterOwned(key);
}

export function isExclusiveTakenByOther(
  members: SessionMember[],
  avatarKey: string,
  excludeMemberId: string
): boolean {
  if (!isExclusiveAvatar(avatarKey)) {
    return false;
  }
  for (let i = 0; i < members.length; i++) {
    const m = members[i];
    if (m.id === excludeMemberId) {
      continue;
    }
    if (m.avatarKey === avatarKey) {
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
    const m = members[i];
    if (m.id === excludeMemberId) {
      continue;
    }
    if (m.lobbyReady === true && isExclusiveAvatar(m.avatarKey)) {
      locked.add(m.avatarKey);
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
  return MATCHMAN_AVATAR_KEY;
}

export type CharacterPickState = 'selectable' | 'taken' | 'unowned' | 'lockedByReady' | 'selfReadyLocked';

export function characterPickState(
  key: string,
  members: SessionMember[],
  editingMemberId: string,
  soloTeam: boolean
): CharacterPickState {
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
  if (!isCharacterOwned(key) || !isAvatarAllowedForSession(key, soloTeam)) {
    return 'unowned';
  }
  const readyLocked = getExclusiveAvatarsLockedByReadyMembers(members, editingMemberId);
  if (readyLocked.has(key)) {
    return 'lockedByReady';
  }
  if (isExclusiveTakenByOther(members, key, editingMemberId)) {
    return 'taken';
  }
  return 'selectable';
}

export function sortRosterKeysForPicker(keys: string[]): string[] {
  const dup: string[] = [];
  const rest: string[] = [];
  for (let i = 0; i < keys.length; i++) {
    if (keys[i] === MATCHMAN_AVATAR_KEY) {
      dup.push(keys[i]);
    } else {
      rest.push(keys[i]);
    }
  }
  return dup.concat(rest);
}
