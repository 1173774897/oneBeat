import { isAvatarAllowedForSession, isRandomAvatar, isRandomPoolCharacter } from './CharacterCatalog';

export const WALK_FRAME_COUNT: number = 8;
export const LILROLL_WALK_FRAME_COUNT: number = 16;
export const WALK_FRAMES_PER_BEAT: number = 4;
export const SCOOTER_WALK_FRAME_COUNT: number = 16;

export const ROAD_IMAGES: string[] = [
  'scenes/sunset/sunset_road.png'
];

/** 夕阳海边步道两侧物体（与 scenes/sunset/entities 文件名一致） */
export const SIDE_ENTITIES: string[] = [
  'scenes/sunset/entities/barrel.png',
  'scenes/sunset/entities/bench.png',
  'scenes/sunset/entities/billboard.png',
  'scenes/sunset/entities/billboardreck.png',
  'scenes/sunset/entities/blocksign.png',
  'scenes/sunset/entities/busstop.png',
  'scenes/sunset/entities/cable.png',
  'scenes/sunset/entities/cactus.png',
  'scenes/sunset/entities/cart.png',
  'scenes/sunset/entities/drain.png',
  'scenes/sunset/entities/firehydrant.png',
  'scenes/sunset/entities/gaslight.png',
  'scenes/sunset/entities/mailbox.png',
  'scenes/sunset/entities/milemeter.png',
  'scenes/sunset/entities/paperbox.png',
  'scenes/sunset/entities/petrol.png',
  'scenes/sunset/entities/phone.png',
  'scenes/sunset/entities/rocks.png',
  'scenes/sunset/entities/sign.png',
  'scenes/sunset/entities/snowcone.png',
  'scenes/sunset/entities/telescope.png',
  'scenes/sunset/entities/tier.png',
  'scenes/sunset/entities/trashcan.png',
  'scenes/sunset/entities/tree.png',
  'scenes/sunset/entities/umbrella.png',
  'scenes/sunset/entities/vendingmachine.png'
];

/** 前景侧仅使用较矮的物体（对应 SIDE_ENTITIES 下标） */
const SIDE_ENTITY_INDEX_BILLBOARDRECK: number = 3;
const SIDE_ENTITY_INDEX_CABLE: number = 6;
const BILLBOARDRECK_DISPLAY_SCALE: number = 2;
const SIDE_ENTITY_NATIVE_HEIGHT: number = 400;
const SIDE_ENTITY_DISPLAY_HEIGHT: number = 110;
const SIDE_ENTITY_DISPLAY_WIDTH: number = 120;
const CABLE_NATIVE_WIDTH: number = 1000;
const CABLE_NATIVE_HEIGHT: number = 600;

export interface EntityDisplaySize {
  width: number;
  height: number;
}

/** 按素材像素比例缩放；cable 为 1000×600，与默认 300×400 系列同比例尺 */
export function entityDisplaySize(entityIndex: number, sceneKey: string = 'sunset_coast'): EntityDisplaySize {
  if (isNeonStreetScene(sceneKey)) {
    if (entityIndex === NEON_SIDE_ENTITY_INDEX_BILLBOARD ||
      entityIndex === NEON_SIDE_ENTITY_INDEX_NEONCAT ||
      entityIndex === NEON_SIDE_ENTITY_INDEX_STREETLIGHT) {
      return neonLargeEntityDisplaySize();
    }
    return {
      width: SIDE_ENTITY_DISPLAY_WIDTH,
      height: SIDE_ENTITY_DISPLAY_HEIGHT
    };
  }
  if (entityIndex === SIDE_ENTITY_INDEX_CABLE) {
    const scale = SIDE_ENTITY_DISPLAY_HEIGHT / SIDE_ENTITY_NATIVE_HEIGHT;
    return {
      width: Math.round(CABLE_NATIVE_WIDTH * scale),
      height: Math.round(CABLE_NATIVE_HEIGHT * scale)
    };
  }
  if (entityIndex === SIDE_ENTITY_INDEX_BILLBOARDRECK) {
    return {
      width: SIDE_ENTITY_DISPLAY_WIDTH * BILLBOARDRECK_DISPLAY_SCALE,
      height: SIDE_ENTITY_DISPLAY_HEIGHT * BILLBOARDRECK_DISPLAY_SCALE
    };
  }
  return {
    width: SIDE_ENTITY_DISPLAY_WIDTH,
    height: SIDE_ENTITY_DISPLAY_HEIGHT
  };
}

export const FOREGROUND_ENTITY_INDICES: number[] = [
  0, // barrel
  1, // bench
  7, // cactus
  9, // drain
  17 // rocks
];

/** 霓虹街口步道两侧物体（与 scenes/neon/entities 文件名一致） */
export const NEON_SIDE_ENTITIES: string[] = [
  'scenes/neon/entities/bikes.png',
  'scenes/neon/entities/billboard.png',
  'scenes/neon/entities/blindeggs.png',
  'scenes/neon/entities/blocksign.png',
  'scenes/neon/entities/busstop.png',
  'scenes/neon/entities/drain.png',
  'scenes/neon/entities/electricitybox.png',
  'scenes/neon/entities/electricplugs.png',
  'scenes/neon/entities/gamemachine.png',
  'scenes/neon/entities/laundrymachines.png',
  'scenes/neon/entities/magnifier.png',
  'scenes/neon/entities/neoncat.png',
  'scenes/neon/entities/phonebooth.png',
  'scenes/neon/entities/scooter.png',
  'scenes/neon/entities/snackcart.png',
  'scenes/neon/entities/streetlight.png',
  'scenes/neon/entities/tank.png',
  'scenes/neon/entities/tape.png',
  'scenes/neon/entities/threemeters.png',
  'scenes/neon/entities/trafficlight.png',
  'scenes/neon/entities/umbrella.png'
];

const NEON_SIDE_ENTITY_INDEX_BILLBOARD: number = 1;
const NEON_SIDE_ENTITY_INDEX_DRAIN: number = 5;
const NEON_SIDE_ENTITY_INDEX_NEONCAT: number = 11;
const NEON_SIDE_ENTITY_INDEX_STREETLIGHT: number = 15;
const NEON_SIDE_ENTITY_INDEX_TAPE: number = 17;

function neonLargeEntityDisplaySize(): EntityDisplaySize {
  return {
    width: SIDE_ENTITY_DISPLAY_WIDTH * BILLBOARDRECK_DISPLAY_SCALE,
    height: SIDE_ENTITY_DISPLAY_HEIGHT * BILLBOARDRECK_DISPLAY_SCALE
  };
}

const NEON_FOREGROUND_ENTITY_INDICES: number[] = [
  5, // drain
  17 // tape
];

export function isNeonStreetScene(sceneKey: string): boolean {
  return sceneKey === 'neon_street';
}

/** 与最近若干次生成互斥（见 randomSideEntityIndex 的 recentIndices） */
export const ENTITY_SPAWN_RECENT_WINDOW: number = 3;

function pickFromPoolExcludingRecent(pool: number[], recentIndices: number[]): number {
  if (pool.length === 0) {
    return 0;
  }
  if (recentIndices.length === 0) {
    return pool[Math.floor(Math.random() * pool.length)];
  }
  const banned: Set<number> = new Set(recentIndices);
  let choices = pool.filter((idx) => !banned.has(idx));
  if (choices.length === 0) {
    choices = pool;
  }
  return choices[Math.floor(Math.random() * choices.length)];
}

/** recentIndices：最近已生成的下标，本次不再从中抽取 */
export function randomSideEntityIndex(isForeground: boolean, recentIndices: number[] = [],
  sceneKey: string = 'sunset_coast'): number {
  const windowed = recentIndices.length > ENTITY_SPAWN_RECENT_WINDOW
    ? recentIndices.slice(-ENTITY_SPAWN_RECENT_WINDOW)
    : recentIndices;
  if (isNeonStreetScene(sceneKey)) {
    if (isForeground) {
      return pickFromPoolExcludingRecent(NEON_FOREGROUND_ENTITY_INDICES, windowed);
    }
    const pool: number[] = [];
    for (let i = 0; i < NEON_SIDE_ENTITIES.length; i++) {
      if (i !== NEON_SIDE_ENTITY_INDEX_DRAIN && i !== NEON_SIDE_ENTITY_INDEX_TAPE) {
        pool.push(i);
      }
    }
    return pickFromPoolExcludingRecent(pool, windowed);
  }
  if (isForeground) {
    return pickFromPoolExcludingRecent(FOREGROUND_ENTITY_INDICES, windowed);
  }
  const count = SIDE_ENTITIES.length;
  const pool: number[] = [];
  for (let i = 0; i < count; i++) {
    pool.push(i);
  }
  return pickFromPoolExcludingRecent(pool, windowed);
}

export type WalkerAvatarKey =
  'cloud' | 'mismatch' | 'lilroll' | 'teapot' | 'wave' | 'scooter' | 'lamp' |
  'braids' | 'boonie' | 'curly' | 'buzz';

export function walkFramePath(avatar: WalkerAvatarKey, frameIndex: number, colorSlot: number = 0): string {
  const count = avatar === 'lilroll' ? LILROLL_WALK_FRAME_COUNT :
    avatar === 'scooter' ? SCOOTER_WALK_FRAME_COUNT : WALK_FRAME_COUNT;
  const idx = (frameIndex % count) + 1;
  const suffix = idx < 10 ? `0${idx}` : `${idx}`;
  if (isRandomPoolCharacter(avatar)) {
    return `walk/${avatar}/palette_${colorSlot + 1}/frame_${suffix}.png`;
  }
  return `walk/${avatar}/frame_${suffix}.png`;
}

export function standFramePath(avatar: WalkerAvatarKey, colorSlot: number = 0): string {
  if (isRandomPoolCharacter(avatar)) {
    return `stand/${avatar}/palette_${colorSlot === 1 ? 2 : 1}/frame_01.png`;
  }
  return `stand/${avatar}/frame_01.png`;
}

/** Every beat owns four consecutive frames; the global beat index prevents a
 * short meter such as 3/4 from resetting a 16-frame walk cycle at each bar. */
export function walkerAnimFrameIndex(
  avatar: WalkerAvatarKey,
  beatIndex: number,
  stepInBeat: number,
  _beatInBar: number = 1
): number {
  const step = Math.max(0, Math.min(WALK_FRAMES_PER_BEAT - 1, stepInBeat));
  const frameCount = avatar === 'lilroll' ? LILROLL_WALK_FRAME_COUNT :
    avatar === 'scooter' ? SCOOTER_WALK_FRAME_COUNT : WALK_FRAME_COUNT;
  const absoluteFrame = beatIndex * WALK_FRAMES_PER_BEAT + step;
  return ((absoluteFrame % frameCount) + frameCount) % frameCount;
}

export function avatarForSlot(slot: number): WalkerAvatarKey {
  return slot % 2 === 0 ? 'cloud' : 'mismatch';
}

export function memberAvatar(avatarKey: string, slot: number, resolvedAvatarKey: string = ''): WalkerAvatarKey {
  const key = avatarKey === 'matchman' ? 'lamp' : avatarKey;
  if (isRandomAvatar(key) && isRandomPoolCharacter(resolvedAvatarKey)) {
    return resolvedAvatarKey as WalkerAvatarKey;
  }
  if (isRandomPoolCharacter(key)) {
    return key as WalkerAvatarKey;
  }
  if (key === 'cloud' || key === 'mismatch' || key === 'lilroll' || key === 'teapot' ||
    key === 'wave' || key === 'scooter' || key === 'lamp') {
    return key;
  }
  return avatarForSlot(slot);
}

export function isAllowedAvatarKey(key: string, soloTeam: boolean): boolean {
  return isAvatarAllowedForSession(key, soloTeam);
}
