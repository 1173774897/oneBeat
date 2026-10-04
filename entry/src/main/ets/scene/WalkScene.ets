import { SessionMember } from '../protocol/messages';
import {
  ENTITY_SPAWN_RECENT_WINDOW,
  entityDisplaySize,
  memberAvatar,
  randomSideEntityIndex,
  walkerAnimFrameIndex,
  WALK_FRAMES_PER_BEAT
} from '../assets/AssetCatalog';
import { WalkerSprite } from './WalkerSprite';
import { SideEntitySprite } from './SideEntitySprite';
import { VegetationSprite } from './VegetationSprite';
import { AppSession } from '../app/AppSession';
import { TransportVisualSnapshot } from '../audio/MetronomeEngine';
import { MonotonicClock } from '../common/MonotonicClock';

const ENTITY_DISPLAY_HEIGHT: number = 110;
const ENTITY_DISPLAY_WIDTH: number = 120;
const WALKER_SPRITE_H: number = 140;
const WALKER_RANK_H: number = 22;
/** 增大则人物下移 */
const SPRITE_FEET_LIFT: number = -25;
/** 队员列左右留白（px）；增大则整体更靠中间、人物更挤 */
const WALKER_STAND_SIDE_MARGIN: number = 5;
/** 相对 walkerColumnTop() 的纵向偏移；增大上界则人物整体下移 */
const WALKER_STAND_Y_OFFSET_MIN: number = -38;
const WALKER_STAND_Y_OFFSET_MAX: number = 26;
const WALKER_COLUMN_HALF_WIDTH: number = 70;
const WALKER_COLUMN_WIDTH: number = WALKER_COLUMN_HALF_WIDTH * 2;
/** 纵深缩放：yOffset 最小（远）与最大（近）对应的 scale（站位间距公式会引用 NEAR） */
const WALKER_DEPTH_SCALE_FAR: number = 0.80;
const WALKER_DEPTH_SCALE_NEAR: number = 1.12;
/** 两队员列中心最小水平间距（px），约为最大缩放列宽 + 余量 */
const WALKER_STAND_MIN_CENTER_SEP_PX: number =
  Math.ceil(WALKER_COLUMN_WIDTH * WALKER_DEPTH_SCALE_NEAR) + 22;
/** 行进页人物 z 基底（低于 neon 前景遮挡，见 neonForeground zIndex） */
const WALKER_STAND_Z_BASE: number = 18;
/** 远近之间 z 增量（远=BASE，近=BASE+SPAN，均须 < NEON_FOREGROUND_Z_INDEX） */
const WALKER_STAND_Z_SPAN: number = 10;
/** 槽位在安全带内的横向区间（0～1），尽量用满可站宽度 */
const WALKER_STAND_SLOT_X_MIN: number = 0.03;
const WALKER_STAND_SLOT_X_MAX: number = 0.97;
/** 槽位内 x 随机抖动；仅在未与其它队员水平重叠时应用 */
const WALKER_STAND_X_JITTER_RATIO: number = 0.06;
/** 霓虹前景遮挡层 zIndex（须在人物之上） */
const NEON_FOREGROUND_Z_INDEX: number = 30;
/** 列内脚底锚点（自列顶向下 px），与 scale center 对齐 */
const WALKER_COLUMN_FEET_ANCHOR_Y: number = WALKER_RANK_H + WALKER_SPRITE_H;
/** 屏高下缘留白；可为负值，让步道略超出屏底（由外层 clip） */
const ROAD_BOTTOM_INSET_RATIO: number = 0;
/** 步道带高度占屏高比例 */
const ROAD_BAND_HEIGHT_RATIO: number = 0.46;
const ROAD_PATH_CENTER_RATIO: number = 0.66;
/** 每张横向循环图覆盖两屏，降低街机滚动中的重复频率 */
const LAYER_TILE_SCREEN_COUNT: number = 2;
/** 每前进多少像素（步道坐标）尝试生成一个路边物体 */
const SPAWN_EVERY_ROAD_PX: number = 260;
/** 滚动生成时前景侧所占比例（其余为背景侧） */
const FOREGROUND_SPAWN_CHANCE: number = 0.22;
/** 背景侧物体略高（远）；前景侧物体更低（近） */
const ENTITY_BG_LIFT_PX: number = 115;
const ENTITY_FG_DROP_PX: number = 45;
const VEGETATION_DISPLAY_HEIGHT: number = 58;
const VEGETATION_DISPLAY_WIDTH: number = 78;
/** 素材底边对齐步道时的锚点（仅几何，不是缩放） */
const VEGETATION_FOOT_ANCHOR_RATIO: number = 0.72;
/** 相对 walkPathY 锚点再偏移：正值=沿步道下移，负值=上移；背景/前景分开调 */
const VEGETATION_BG_PATH_OFFSET_PX: number = -114;
const VEGETATION_FG_PATH_OFFSET_PX: number = 44;
const SPAWN_EVERY_VEGETATION_PX: number = 145;
/** 步道正中带（约 36%–50% 屏宽）长植物的占比 */
const VEGETATION_CENTER_BAND_CHANCE: number = 0.05;
/** 霓虹远景天际线层顶边距（占屏高）；增大则天际线下移 */
const NEON_FAR_SKYLINE_TOP_RATIO: number = 0.11;
/** 霓虹前景遮挡：滚动速度倍率（相对步道） */
const NEON_OCCLUDER_SCROLL_RATIO: number = 1.15;
/** 霓虹前景遮挡：空白基准宽度（相对单张 tile 宽度），实际空白 = 基准 × 随机 1～6 倍 */
const NEON_OCCLUDER_BASE_GAP_TILE_RATIO: number = 1.15;
const NEON_OCCLUDER_LAYER_HEIGHT_RATIO: number = 1;
const NEON_OCCLUDER_VARIANT_COUNT: number = 6;
/** 遮挡图底边超出道路底 / 屏底再向下延伸（vp），叠加 bottomSafeInset 穿过底部安全区 */
const NEON_OCCLUDER_EXTRA_BOTTOM_BLEED_PX: number = 10;

interface SideEntityView {
  id: string;
  entityIndex: number;
  /** 与步道共用的横向世界坐标，随 roadScroll 一起“向左走” */
  roadX: number;
  side: number;
  isForeground: boolean;
}

interface VegetationView {
  id: string;
  plantIndex: number;
  roadX: number;
  /** 屏幕横向偏移（与 road 同步滚动），与步道中心 lane 无关 */
  laneOffsetPx: number;
  isForeground: boolean;
}

interface NeonOccluderSegment {
  id: string;
  /** 1～6，对应 neon_front_occludersN.png */
  variant: number;
  flipped: boolean;
  /** 遮挡图左缘（与 roadScroll×1.15 同一滚动坐标系） */
  worldX: number;
  /** 该张之后的空白宽度（px） */
  gapAfter: number;
}

/** 与 members 下标一一对应；xRatio 为安全带宽内 0～1 */
interface WalkerStandSlot {
  xRatio: number;
  yOffset: number;
}

@Component
export struct WalkScene {
  @Prop @Watch('onScrollSpeedChanged') scrollSpeed: number = 0;
  @Prop bpm: number = 120;
  @Prop @Watch('onPlayingChanged') isPlaying: boolean = false;
  @Prop @Watch('onMembersChanged') members: SessionMember[] = [];
  @Prop @Watch('onSceneKeyChanged') sceneKey: string = 'sunset_coast';
  @StorageLink('safeAreaBottom') bottomSafeInset: number = 0;
  @State roadScroll: number = 0;
  @State animBeatIndex: number = 0;
  @State animBeatInBar: number = 1;
  @State animStepInBeat: number = 0;
  @State sideEntities: SideEntityView[] = [];
  @State vegetation: VegetationView[] = [];
  @State sceneWidth: number = 360;
  @State sceneHeight: number = 420;
  @State atmospherePhase: number = 0;
  @State neonOccluderSegments: NeonOccluderSegment[] = [];
  @State walkerStands: WalkerStandSlot[] = [];
  private loopTimer: number = -1;
  private activeTransportRevision: number = -1;
  private transportRoadBase: number = 0;
  private transportRoadAnchorMs: number = 0;
  private activeScrollSpeed: number = 0;
  private entityCounter: number = 0;
  /** 最近生成的路边物体下标，间隔窗口内不重复 */
  private recentSpawnedEntityIndices: number[] = [];
  private roadPxSinceSpawn: number = 0;
  private vegetationPxSinceSpawn: number = 0;
  private vegetationCounter: number = 0;
  private seeded: boolean = false;
  private lastAtmosphereTickMs: number = 0;
  private occluderSegmentCounter: number = 0;
  private occluderTailWorldX: number = 0;
  private walkerLayoutMemberSig: string = '';

  aboutToAppear(): void {
    this.animBeatIndex = 0;
    this.animBeatInBar = 1;
    this.animStepInBeat = 0;
    this.walkerStands = [];
    this.walkerLayoutMemberSig = '';
    this.startLoop();
    if (this.sceneWidth > 0 && this.members.length > 0) {
      this.ensureWalkerStands();
    }
  }

  aboutToDisappear(): void {
    this.stopLoop();
  }

  onScrollSpeedChanged(): void {
    this.startLoop();
  }

  onPlayingChanged(): void {
    if (!this.isPlaying) {
      this.animBeatIndex = 0;
      this.animBeatInBar = 1;
      this.animStepInBeat = 0;
      this.roadPxSinceSpawn = 0;
    }
  }

  onMembersChanged(): void {
    if (this.walkerStands.length !== this.members.length) {
      this.walkerLayoutMemberSig = '';
    }
    this.ensureWalkerStands();
  }

  private updateWalkFrame(snapshot: TransportVisualSnapshot): void {
    if (!snapshot.running || snapshot.mainPlayheadMs < 0 || snapshot.beatInBar <= 0) {
      this.animBeatIndex = 0;
      this.animBeatInBar = 1;
      this.animStepInBeat = 0;
      return;
    }
    const step = Math.min(WALK_FRAMES_PER_BEAT - 1,
      Math.floor(snapshot.beatPhase * WALK_FRAMES_PER_BEAT));
    if (this.animBeatIndex !== snapshot.beatIndex || this.animBeatInBar !== snapshot.beatInBar ||
      this.animStepInBeat !== step) {
      this.animBeatIndex = snapshot.beatIndex;
      this.animBeatInBar = snapshot.beatInBar;
      this.animStepInBeat = step;
    }
  }

  private walkerFrameFor(member: SessionMember, index: number): number {
    const avatar = memberAvatar(member.avatarKey, index, member.resolvedAvatarKey ?? '');
    return walkerAnimFrameIndex(avatar, this.animBeatIndex, this.animStepInBeat, this.animBeatInBar);
  }

  private startLoop(): void {
    if (this.loopTimer >= 0) {
      return;
    }
    this.lastAtmosphereTickMs = MonotonicClock.nowMs();
    this.loopTimer = setInterval(() => {
      this.tickFrame();
    }, 16);
    if (!this.seeded && this.sceneWidth > 0) {
      this.seedEntities();
    }
  }

  private stopLoop(): void {
    if (this.loopTimer >= 0) {
      clearInterval(this.loopTimer);
      this.loopTimer = -1;
    }
  }

  private scrollSpeedPx(): number {
    if (this.scrollSpeed > 0) {
      return this.scrollSpeed;
    }
    if (this.isPlaying) {
      return this.bpm * 1.2;
    }
    return 0;
  }

  private onSceneKeyChanged(): void {
    this.sideEntities = [];
    this.vegetation = [];
    this.recentSpawnedEntityIndices = [];
    this.seeded = false;
    this.resetNeonOccluderStrip();
    if (this.sceneWidth > 0) {
      this.seedEntities();
    }
  }

  private seedEntities(): void {
    this.seeded = true;
    const base = this.roadScroll;
    this.addEntity(base + this.sceneWidth * 0.12, -1, false);
    this.addEntity(base + this.sceneWidth * 0.32, -1, false);
    this.addEntity(base + this.sceneWidth * 0.52, 1, false);
    this.addEntity(base + this.sceneWidth * 0.72, -1, false);
    this.addEntity(base + this.sceneWidth * 0.90, 1, true);
    if (this.sceneKey !== 'neon_street') {
      const w = this.sceneWidth;
      this.addVegetation(base + w * 0.12, this.pickVegetationLaneOffset(), false);
      this.addVegetation(base + w * 0.32, this.pickVegetationLaneOffset(), false);
      this.addVegetation(base + w * 0.52, this.pickVegetationLaneOffset(), false);
      this.addVegetation(base + w * 0.72, this.pickVegetationLaneOffset(), false);
      this.addVegetation(base + w * 0.90, this.pickVegetationLaneOffset(), false);
    }
  }

  private spawnAheadEntity(): void {
    const ahead = this.roadScroll + this.sceneWidth + 40;
    const side = Math.random() > 0.5 ? 1 : -1;
    const isForeground = Math.random() < FOREGROUND_SPAWN_CHANCE;
    this.addEntity(ahead, side, isForeground);
  }

  /** 多数在步道外缘两侧，极少落在步道中间带 */
  private pickVegetationLaneOffset(): number {
    const w = this.sceneWidth > 0 ? this.sceneWidth : 360;
    const roll = Math.random();
    if (roll < VEGETATION_CENTER_BAND_CHANCE) {
      return w * (0.36 + Math.random() * 0.14);
    }
    if (roll < 0.48) {
      return w * (0.02 + Math.random() * 0.10);
    }
    if (roll < 0.91) {
      return w * (0.76 + Math.random() * 0.14);
    }
    if (roll < 0.965) {
      return w * (0.12 + Math.random() * 0.10);
    }
    return w * (0.62 + Math.random() * 0.10);
  }

  private addVegetation(roadX: number, laneOffsetPx: number, isForeground: boolean): void {
    const plant: VegetationView = {
      id: `v-${this.vegetationCounter++}`,
      plantIndex: Math.floor(Math.random() * 12),
      roadX: roadX,
      laneOffsetPx: laneOffsetPx,
      isForeground: isForeground
    };
    this.vegetation = [...this.vegetation, plant];
  }

  private spawnAheadVegetation(): void {
    const ahead = this.roadScroll + this.sceneWidth + 24;
    this.addVegetation(ahead, this.pickVegetationLaneOffset(), Math.random() < 0.30);
  }

  private addEntity(roadX: number, side: number, isForeground: boolean): void {
    const entityIndex = randomSideEntityIndex(isForeground, this.recentSpawnedEntityIndices, this.sceneKey);
    this.recentSpawnedEntityIndices = [...this.recentSpawnedEntityIndices, entityIndex]
      .slice(-ENTITY_SPAWN_RECENT_WINDOW);
    const entity: SideEntityView = {
      id: `e-${this.entityCounter++}`,
      entityIndex: entityIndex,
      roadX: roadX,
      side: side,
      isForeground: isForeground
    };
    this.sideEntities = [...this.sideEntities, entity];
  }

  /** 按屏幕坐标回收：右车道有更大 lane 偏移，不能用 roadX  alone 判断 */
  private isEntityOnScreen(item: SideEntityView): boolean {
    const screenX = this.entityScreenX(item);
    const margin = 12;
    const size = entityDisplaySize(item.entityIndex, this.sceneKey);
    return screenX + size.width > -margin;
  }

  private pruneOffscreenEntities(): void {
    const next = this.sideEntities.filter((item) => this.isEntityOnScreen(item));
    if (next.length !== this.sideEntities.length) {
      this.sideEntities = next;
    }
  }

  private isVegetationOnScreen(item: VegetationView): boolean {
    const screenX = this.vegetationScreenX(item);
    return screenX + VEGETATION_DISPLAY_WIDTH > -12;
  }

  private pruneOffscreenVegetation(): void {
    const next = this.vegetation.filter((item) => this.isVegetationOnScreen(item));
    if (next.length !== this.vegetation.length) {
      this.vegetation = next;
    }
  }

  private tickFrame(): void {
    const now = MonotonicClock.nowMs();
    const snapshot = AppSession.get()?.metronome.getVisualSnapshot();
    const speed = this.scrollSpeedPx();
    let advancedPx = 0;
    if (snapshot !== undefined && snapshot.running) {
      const mainPlayheadMs = Math.max(0, snapshot.mainPlayheadMs);
      if (snapshot.revision !== this.activeTransportRevision) {
        this.activeTransportRevision = snapshot.revision;
        this.transportRoadBase = this.roadScroll;
        this.transportRoadAnchorMs = 0;
        this.activeScrollSpeed = speed;
      } else if (speed !== this.activeScrollSpeed) {
        this.transportRoadBase = this.roadScroll;
        this.transportRoadAnchorMs = mainPlayheadMs;
        this.activeScrollSpeed = speed;
      }
      if (snapshot.mainPlayheadMs >= 0 && speed > 0) {
        const targetRoadScroll = this.transportRoadBase +
          this.activeScrollSpeed * Math.max(0, mainPlayheadMs - this.transportRoadAnchorMs) / 1000;
        advancedPx = Math.max(0, targetRoadScroll - this.roadScroll);
        this.roadScroll = Math.max(this.roadScroll, targetRoadScroll);
      }
      this.updateWalkFrame(snapshot);
    } else if (!this.isPlaying) {
      this.activeTransportRevision = -1;
    }

    if (advancedPx > 0) {
      if (advancedPx > Math.max(720, this.sceneWidth * 4)) {
        this.sideEntities = [];
        this.vegetation = [];
        this.seeded = false;
        this.roadPxSinceSpawn = 0;
        this.vegetationPxSinceSpawn = 0;
        this.seedEntities();
        this.resetNeonOccluderStrip();
        advancedPx = 0;
      }
      this.roadPxSinceSpawn += advancedPx;
      while (this.roadPxSinceSpawn >= SPAWN_EVERY_ROAD_PX) {
        this.roadPxSinceSpawn -= SPAWN_EVERY_ROAD_PX;
        this.spawnAheadEntity();
      }
      if (this.sceneKey !== 'neon_street') {
        this.vegetationPxSinceSpawn += advancedPx;
        while (this.vegetationPxSinceSpawn >= SPAWN_EVERY_VEGETATION_PX) {
          this.vegetationPxSinceSpawn -= SPAWN_EVERY_VEGETATION_PX;
          this.spawnAheadVegetation();
        }
      }
      this.pruneOffscreenEntities();
      this.pruneOffscreenVegetation();
    }
    if (this.sceneKey === 'neon_street') {
      this.extendNeonOccluderStrip();
      if (now - this.lastAtmosphereTickMs >= 80) {
        this.lastAtmosphereTickMs = now;
        this.atmospherePhase = (this.atmospherePhase + 1) % 120;
      }
    }
  }

  private roadTileWidth(): number {
    return (this.sceneWidth > 0 ? this.sceneWidth : 360) * LAYER_TILE_SCREEN_COUNT;
  }

  private roadBandHeight(): number {
    return this.sceneHeight * ROAD_BAND_HEIGHT_RATIO;
  }

  private roadLoopOffset(): number {
    const tileW = this.roadTileWidth();
    return this.roadScroll % (tileW * 2);
  }

  private layerLoopOffset(speedRatio: number): number {
    const tileW = this.roadTileWidth();
    return (this.roadScroll * speedRatio) % (tileW * 2);
  }

  /** 街区块层：同向平铺，循环周期 = 单张 tile 宽 */
  private neonStreetBlocksLoopOffset(): number {
    const tileW = this.roadTileWidth();
    return (this.roadScroll * 0.22) % tileW;
  }

  private neonOccluderTileWidth(): number {
    return this.roadTileWidth();
  }

  private neonOccluderScrollX(): number {
    return this.roadScroll * NEON_OCCLUDER_SCROLL_RATIO;
  }

  /** 新遮挡段只能出现在该 worldX 及以右（屏幕右缘外） */
  private neonOccluderSpawnFrontX(): number {
    return this.neonOccluderScrollX() + this.sceneWidth;
  }

  private randomOccluderGapAfter(): number {
    const multiplier = 1 + Math.floor(Math.random() * 6);
    return this.neonOccluderTileWidth() * NEON_OCCLUDER_BASE_GAP_TILE_RATIO * multiplier;
  }

  private buildNeonOccluderSegment(atWorldX: number): NeonOccluderSegment {
    return {
      id: `oc-${this.occluderSegmentCounter++}`,
      variant: 1 + Math.floor(Math.random() * NEON_OCCLUDER_VARIANT_COUNT),
      flipped: Math.random() < 0.5,
      worldX: atWorldX,
      gapAfter: this.randomOccluderGapAfter()
    };
  }

  private resetNeonOccluderStrip(): void {
    this.neonOccluderSegments = [];
    this.occluderSegmentCounter = 0;
    if (this.sceneKey === 'neon_street' && this.sceneWidth > 0) {
      this.occluderTailWorldX = this.neonOccluderSpawnFrontX();
      this.extendNeonOccluderStrip();
    } else {
      this.occluderTailWorldX = 0;
    }
  }

  private extendNeonOccluderStrip(): void {
    if (this.sceneKey !== 'neon_street' || this.sceneWidth <= 0) {
      return;
    }
    const scrollX = this.neonOccluderScrollX();
    const spawnFront = this.neonOccluderSpawnFrontX();
    const targetX = spawnFront + this.neonOccluderTileWidth() * 2;
    const tileW = this.neonOccluderTileWidth();
    let tail = Math.max(this.occluderTailWorldX, spawnFront);
    const appended: NeonOccluderSegment[] = [];
    while (tail < targetX) {
      const segment = this.buildNeonOccluderSegment(tail);
      appended.push(segment);
      tail += tileW + segment.gapAfter;
    }
    this.occluderTailWorldX = tail;
    const minKeepX = scrollX - tileW;
    const kept = this.neonOccluderSegments.filter((segment) => segment.worldX + tileW > minKeepX);
    this.neonOccluderSegments = kept.concat(appended);
  }

  private neonOccluderScreenX(segment: NeonOccluderSegment): number {
    return segment.worldX - this.neonOccluderScrollX();
  }

  private roadBottomY(): number {
    return this.roadSurfaceY() + this.roadBandHeight();
  }

  private neonOccluderLayerHeight(): number {
    return this.sceneHeight * NEON_OCCLUDER_LAYER_HEIGHT_RATIO;
  }

  private neonOccluderBottomBleedPx(): number {
    return this.bottomSafeInset + NEON_OCCLUDER_EXTRA_BOTTOM_BLEED_PX;
  }

  /** 遮挡层底边略低于道路底，穿过底部安全区 */
  private neonOccluderTopY(): number {
    return this.roadBottomY() - this.neonOccluderLayerHeight() + this.neonOccluderBottomBleedPx();
  }

  private neonStreetOpacity(): number {
    const flicker = this.atmospherePhase % 48;
    return flicker === 0 || flicker === 2 ? 0.88 : flicker === 1 ? 0.95 : 1;
  }

  private neonRainOffset(): number {
    return -10 + (this.atmospherePhase % 16) * 1.25;
  }

  private roadSurfaceY(): number {
    return this.sceneHeight - this.sceneHeight * ROAD_BOTTOM_INSET_RATIO - this.roadBandHeight();
  }

  private walkPathY(): number {
    return this.roadSurfaceY() + this.roadBandHeight() * ROAD_PATH_CENTER_RATIO;
  }

  private walkerColumnTop(): number {
    return this.walkPathY() - WALKER_RANK_H - WALKER_SPRITE_H + SPRITE_FEET_LIFT;
  }

  /** 屏幕 X：roadX 与步道 scroll 同步，仅加左右车道固定偏移 */
  private entityScreenX(item: SideEntityView): number {
    const alongRoad = item.roadX - this.roadScroll;
    const leftLane = this.sceneWidth * 0.02;
    const rightLane = this.sceneWidth * 0.52;
    return alongRoad + (item.side < 0 ? leftLane : rightLane);
  }

  private entityTop(item: SideEntityView): number {
    const size = entityDisplaySize(item.entityIndex, this.sceneKey);
    const base = this.walkPathY() - size.height;
    return item.isForeground ? base + ENTITY_FG_DROP_PX : base - ENTITY_BG_LIFT_PX;
  }

  private entityZIndex(item: SideEntityView): number {
    return item.isForeground ? 25 : 12;
  }

  private vegetationScreenX(item: VegetationView): number {
    return item.roadX - this.roadScroll + item.laneOffsetPx;
  }

  /** 植物在步道上的纵向位置（与 displayHeight 缩放无关，改上面 PATH_OFFSET 常量） */
  private vegetationTop(item: VegetationView): number {
    const anchorY = this.walkPathY() - VEGETATION_DISPLAY_HEIGHT * VEGETATION_FOOT_ANCHOR_RATIO;
    const offset = item.isForeground ? VEGETATION_FG_PATH_OFFSET_PX : VEGETATION_BG_PATH_OFFSET_PX;
    return anchorY + offset;
  }

  private vegetationZIndex(item: VegetationView): number {
    return item.isForeground ? 23 : 11;
  }

  /** 人物列锚点（列顶边）允许的最小/最大 x，保证整列在屏内 */
  private walkerStandLeftMinXPx(): number {
    return WALKER_STAND_SIDE_MARGIN;
  }

  private walkerStandLeftMaxXPx(): number {
    const maxLeft = this.sceneWidth - WALKER_STAND_SIDE_MARGIN - WALKER_COLUMN_WIDTH;
    return Math.max(this.walkerStandLeftMinXPx(), maxLeft);
  }

  private walkerStandCenterMinXPx(): number {
    return this.walkerStandLeftMinXPx() + WALKER_COLUMN_HALF_WIDTH;
  }

  private walkerStandCenterMaxXPx(): number {
    return this.walkerStandLeftMaxXPx() + WALKER_COLUMN_HALF_WIDTH;
  }

  private walkerStandCenterSpanPx(): number {
    return Math.max(0, this.walkerStandCenterMaxXPx() - this.walkerStandCenterMinXPx());
  }

  /** xRatio∈[0,1] 映射到安全带宽内的列中心，再转为列左边 x 并钳制 */
  private walkerLeftXFromRatio(xRatio: number): number {
    const span = this.walkerStandCenterSpanPx();
    const clampedRatio = Math.max(0, Math.min(1, xRatio));
    const centerX = this.walkerStandCenterMinXPx() + span * clampedRatio;
    const leftX = centerX - WALKER_COLUMN_HALF_WIDTH;
    return Math.max(this.walkerStandLeftMinXPx(), Math.min(this.walkerStandLeftMaxXPx(), leftX));
  }

  private walkerStandsAreComplete(): boolean {
    return this.walkerStands.length === this.members.length && this.members.length > 0;
  }

  /** 含顺序，避免仅 id 集合相同但顺序变化时站位错位 */
  private memberListSignature(): string {
    let sig = `${this.members.length}:`;
    for (let i = 0; i < this.members.length; i++) {
      sig += this.members[i].id;
      if (i < this.members.length - 1) {
        sig += ',';
      }
    }
    return sig;
  }

  private walkerSlotXRatio(memberIndex: number, total: number): number {
    if (total <= 1) {
      return 0.5;
    }
    const slot = memberIndex / (total - 1);
    return WALKER_STAND_SLOT_X_MIN + (WALKER_STAND_SLOT_X_MAX - WALKER_STAND_SLOT_X_MIN) * slot;
  }

  private walkerDefaultYOffset(memberIndex: number, total: number): number {
    const ySpan = WALKER_STAND_Y_OFFSET_MAX - WALKER_STAND_Y_OFFSET_MIN;
    if (total <= 1) {
      return 0;
    }
    const tier = memberIndex % 3;
    return WALKER_STAND_Y_OFFSET_MIN + (ySpan * tier) / 2;
  }

  private standHorizontalSepOk(centerX: number, placed: number[][]): boolean {
    const minHoriz = WALKER_STAND_MIN_CENTER_SEP_PX;
    for (let i = 0; i < placed.length; i++) {
      if (Math.abs(centerX - placed[i][0]) < minHoriz) {
        return false;
      }
    }
    return true;
  }

  /** 队员 id 集合变化或重新进入行进页（sig 已清空）时整组随机站位 */
  private ensureWalkerStands(): void {
    if (this.sceneWidth <= 0 || this.members.length === 0) {
      return;
    }
    const sig = this.memberListSignature();
    if (sig === this.walkerLayoutMemberSig && this.walkerStandsAreComplete()) {
      return;
    }
    this.walkerLayoutMemberSig = sig;
    const total = this.members.length;
    const baseY = this.walkerColumnTop();
    const ySpan = WALKER_STAND_Y_OFFSET_MAX - WALKER_STAND_Y_OFFSET_MIN;
    const centerSpan = this.walkerStandCenterSpanPx();
    const centerMin = this.walkerStandCenterMinXPx();
    const placed: number[][] = [];
    const stands: WalkerStandSlot[] = [];
    for (let m = 0; m < total; m++) {
      const slotRatio = this.walkerSlotXRatio(m, total);
      let xRatio = slotRatio;
      let yOffset = this.walkerDefaultYOffset(m, total);
      let placedOk = false;
      for (let attempt = 0; attempt < 25 && !placedOk; attempt++) {
        const jitter = attempt === 0 ? 0 : (Math.random() - 0.5) * WALKER_STAND_X_JITTER_RATIO;
        const yJitter = attempt === 0 ? 0 : (Math.random() - 0.5) * ySpan * 0.22;
        const candidateRatio = Math.max(0, Math.min(1, slotRatio + jitter));
        const candidateY = Math.max(WALKER_STAND_Y_OFFSET_MIN,
          Math.min(WALKER_STAND_Y_OFFSET_MAX, this.walkerDefaultYOffset(m, total) + yJitter));
        const centerX = centerMin + centerSpan * candidateRatio;
        if (placed.length === 0 || this.standHorizontalSepOk(centerX, placed)) {
          xRatio = candidateRatio;
          yOffset = candidateY;
          placed.push([centerX, baseY + candidateY]);
          placedOk = true;
        }
      }
      if (!placedOk) {
        xRatio = slotRatio;
        yOffset = this.walkerDefaultYOffset(m, total);
        placed.push([centerMin + centerSpan * xRatio, baseY + yOffset]);
      }
      stands.push({ xRatio: xRatio, yOffset: yOffset });
    }
    this.walkerStands = stands.slice();
  }

  private walkerStandAt(index: number): WalkerStandSlot | undefined {
    if (index < 0 || index >= this.walkerStands.length) {
      return undefined;
    }
    return this.walkerStands[index];
  }

  private walkerPositionX(index: number): number {
    const stand = this.walkerStandAt(index);
    if (stand !== undefined) {
      return this.walkerLeftXFromRatio(stand.xRatio);
    }
    return this.walkerLeftXFromRatio(this.walkerSlotXRatio(index, this.members.length));
  }

  private walkerPositionY(index: number): number {
    const stand = this.walkerStandAt(index);
    if (stand !== undefined) {
      return this.walkerColumnTop() + stand.yOffset;
    }
    return this.walkerColumnTop() + this.walkerDefaultYOffset(index, this.members.length);
  }

  private walkerDepthT(index: number): number {
    const yOff = this.walkerDepthYOffset(index);
    const ySpan = WALKER_STAND_Y_OFFSET_MAX - WALKER_STAND_Y_OFFSET_MIN;
    if (ySpan <= 0) {
      return 0.5;
    }
    return Math.max(0, Math.min(1, (yOff - WALKER_STAND_Y_OFFSET_MIN) / ySpan));
  }

  private walkerPositionZ(index: number): number {
    return WALKER_STAND_Z_BASE + Math.round(this.walkerDepthT(index) * WALKER_STAND_Z_SPAN);
  }

  private walkerDepthYOffset(index: number): number {
    const stand = this.walkerStandAt(index);
    if (stand !== undefined) {
      return stand.yOffset;
    }
    return this.walkerDefaultYOffset(index, this.members.length);
  }

  /** yOffset 越大（越靠下/越近）scale 越大 */
  private walkerDepthScale(index: number): number {
    const t = this.walkerDepthT(index);
    return WALKER_DEPTH_SCALE_FAR + t * (WALKER_DEPTH_SCALE_NEAR - WALKER_DEPTH_SCALE_FAR);
  }

  @Builder
  private roadTileDirt1(mirrored: boolean) {
    Image($rawfile('road/dirtroad1.png'))
      .width(this.roadTileWidth())
      .height(this.roadBandHeight())
      .objectFit(ImageFit.Fill)
      .scale({ x: mirrored ? -1 : 1 })
  }

  @Builder
  private roadTileNeon(mirrored: boolean) {
    Image($rawfile('scenes/neon/neon_road.png'))
      .width(this.roadTileWidth())
      .height(this.roadBandHeight())
      .objectFit(ImageFit.Fill)
      .scale({ x: mirrored ? -1 : 1 })
  }

  @Builder
  private roadTile(mirrored: boolean) {
    if (this.sceneKey === 'neon_street') {
      this.roadTileNeon(mirrored)
    } else {
      this.roadTileDirt1(mirrored)
    }
  }

  /** 单张宽幅道路首尾相接，按自身宽度连续循环 */
  @Builder
  private roadStrip() {
    Row({ space: 0 }) {
      this.roadTile(false);
      this.roadTile(true);
      this.roadTile(false);
      this.roadTile(true);
    }
    .width(this.roadTileWidth() * 4)
    .translate({ x: -this.roadLoopOffset() })
  }

  @Builder
  private neonBackground() {
    Image($rawfile('scenes/neon/neon_sky.png'))
      .width('100%')
      .height('100%')
      .objectFit(ImageFit.Cover)
      .zIndex(0)

    Stack({ alignContent: Alignment.TopStart }) {
      Row({ space: 0 }) {
        Image($rawfile('scenes/neon/neon_far_skyline.png')).width(this.roadTileWidth()).height(this.sceneHeight * 0.54).objectFit(ImageFit.Fill)
        Image($rawfile('scenes/neon/neon_far_skyline.png')).width(this.roadTileWidth()).height(this.sceneHeight * 0.54).objectFit(ImageFit.Fill).scale({ x: -1 })
        Image($rawfile('scenes/neon/neon_far_skyline.png')).width(this.roadTileWidth()).height(this.sceneHeight * 0.54).objectFit(ImageFit.Fill)
        Image($rawfile('scenes/neon/neon_far_skyline.png')).width(this.roadTileWidth()).height(this.sceneHeight * 0.54).objectFit(ImageFit.Fill).scale({ x: -1 })
      }
      .width(this.roadTileWidth() * 4)
      .translate({ x: -this.layerLoopOffset(0.05) })
    }
    .width('100%')
    .height(this.sceneHeight * 0.54)
    .clip(true)
    .position({ x: 0, y: this.sceneHeight * NEON_FAR_SKYLINE_TOP_RATIO })
    .zIndex(2)

    Stack({ alignContent: Alignment.TopStart }) {
      Row({ space: 0 }) {
        Image($rawfile('scenes/neon/neon_street_blocks.png')).width(this.roadTileWidth()).height(this.sceneHeight * 0.60).objectFit(ImageFit.Fill)
        Image($rawfile('scenes/neon/neon_street_blocks.png')).width(this.roadTileWidth()).height(this.sceneHeight * 0.60).objectFit(ImageFit.Fill)
        Image($rawfile('scenes/neon/neon_street_blocks.png')).width(this.roadTileWidth()).height(this.sceneHeight * 0.60).objectFit(ImageFit.Fill)
        Image($rawfile('scenes/neon/neon_street_blocks.png')).width(this.roadTileWidth()).height(this.sceneHeight * 0.60).objectFit(ImageFit.Fill)
      }
      .width(this.roadTileWidth() * 4)
      .translate({ x: -this.neonStreetBlocksLoopOffset() })
    }
    .width('100%')
    .height(this.sceneHeight * 0.60)
    .clip(true)
    .position({ x: 0, y: this.sceneHeight * 0.15 })
    .opacity(this.neonStreetOpacity())
    .zIndex(6)
  }

  @Builder
  private neonOccluderVariantImage(variant: number, flipped: boolean) {
    if (variant === 1) {
      Image($rawfile('scenes/neon/neon_front_occluders1.png'))
        .width(this.neonOccluderTileWidth()).height(this.neonOccluderLayerHeight())
        .objectFit(ImageFit.Fill).scale({ x: flipped ? -1 : 1 });
    } else if (variant === 2) {
      Image($rawfile('scenes/neon/neon_front_occluders2.png'))
        .width(this.neonOccluderTileWidth()).height(this.neonOccluderLayerHeight())
        .objectFit(ImageFit.Fill).scale({ x: flipped ? -1 : 1 });
    } else if (variant === 3) {
      Image($rawfile('scenes/neon/neon_front_occluders3.png'))
        .width(this.neonOccluderTileWidth()).height(this.neonOccluderLayerHeight())
        .objectFit(ImageFit.Fill).scale({ x: flipped ? -1 : 1 });
    } else if (variant === 4) {
      Image($rawfile('scenes/neon/neon_front_occluders4.png'))
        .width(this.neonOccluderTileWidth()).height(this.neonOccluderLayerHeight())
        .objectFit(ImageFit.Fill).scale({ x: flipped ? -1 : 1 });
    } else if (variant === 5) {
      Image($rawfile('scenes/neon/neon_front_occluders5.png'))
        .width(this.neonOccluderTileWidth()).height(this.neonOccluderLayerHeight())
        .objectFit(ImageFit.Fill).scale({ x: flipped ? -1 : 1 });
    } else {
      Image($rawfile('scenes/neon/neon_front_occluders6.png'))
        .width(this.neonOccluderTileWidth()).height(this.neonOccluderLayerHeight())
        .objectFit(ImageFit.Fill).scale({ x: flipped ? -1 : 1 });
    }
  }

  @Builder
  private neonForeground() {
    Stack({ alignContent: Alignment.BottomStart }) {
      ForEach(this.neonOccluderSegments, (segment: NeonOccluderSegment) => {
        Row() {
          this.neonOccluderVariantImage(segment.variant, segment.flipped)
        }
        .width(this.neonOccluderTileWidth())
        .height(this.neonOccluderLayerHeight())
        .position({ x: this.neonOccluderScreenX(segment), y: 0 })
      }, (segment: NeonOccluderSegment) => segment.id)
    }
    .width('100%')
    .height(this.neonOccluderLayerHeight())
    .clip(false)
    .position({ x: 0, y: this.neonOccluderTopY() })
    .opacity(0.88)
    .zIndex(NEON_FOREGROUND_Z_INDEX)
  }

  @Builder
  private neonRain() {
    Image($rawfile('scenes/neon/neon_rain.png'))
      .width('104%')
      .height('104%')
      .objectFit(ImageFit.Fill)
      .position({ x: '-2%', y: this.neonRainOffset() })
      .opacity(0.16)
      .zIndex(40)
      .hitTestBehavior(HitTestMode.None)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.sceneKey === 'neon_street') {
        this.neonBackground()
      }

      Image($rawfile('background/sunset_sky.png'))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .visibility(this.sceneKey === 'neon_street' ? Visibility.None : Visibility.Visible)
        .zIndex(0)

      Image($rawfile('background/sunset_sun.png'))
        .width(this.sceneWidth * 0.30)
        .height(this.sceneWidth * 0.30)
        .objectFit(ImageFit.Contain)
        .position({ x: this.sceneWidth * 0.56, y: this.sceneHeight * 0.24 })
        .visibility(this.sceneKey === 'neon_street' ? Visibility.None : Visibility.Visible)
        .zIndex(1)

      Stack({ alignContent: Alignment.TopStart }) {
        Row({ space: 0 }) {
          Image($rawfile('background/sunset_clouds.png')).width(this.roadTileWidth()).height(this.sceneHeight * 0.36).objectFit(ImageFit.Fill)
          Image($rawfile('background/sunset_clouds.png')).width(this.roadTileWidth()).height(this.sceneHeight * 0.36).objectFit(ImageFit.Fill)
          Image($rawfile('background/sunset_clouds.png')).width(this.roadTileWidth()).height(this.sceneHeight * 0.36).objectFit(ImageFit.Fill)
          Image($rawfile('background/sunset_clouds.png')).width(this.roadTileWidth()).height(this.sceneHeight * 0.36).objectFit(ImageFit.Fill)
        }
        .width(this.roadTileWidth() * 4)
        .translate({ x: -this.layerLoopOffset(0.05) })
      }
      .width('100%')
      .height(this.sceneHeight * 0.36)
      .clip(true)
      .position({ x: 0, y: this.sceneHeight * 0.12 })
      .visibility(this.sceneKey === 'neon_street' ? Visibility.None : Visibility.Visible)
      .zIndex(2)

      Stack({ alignContent: Alignment.TopStart }) {
        Row({ space: 0 }) {
          Image($rawfile('background/ocean.png')).width(this.roadTileWidth()).height(this.sceneHeight * 0.34).objectFit(ImageFit.Fill)
          Image($rawfile('background/ocean.png')).width(this.roadTileWidth()).height(this.sceneHeight * 0.34).objectFit(ImageFit.Fill)
          Image($rawfile('background/ocean.png')).width(this.roadTileWidth()).height(this.sceneHeight * 0.34).objectFit(ImageFit.Fill)
          Image($rawfile('background/ocean.png')).width(this.roadTileWidth()).height(this.sceneHeight * 0.34).objectFit(ImageFit.Fill)
        }
        .width(this.roadTileWidth() * 4)
        .translate({ x: -this.layerLoopOffset(0.12) })
      }
      .width('100%')
      .height(this.sceneHeight * 0.34)
      .clip(true)
      .position({ x: 0, y: this.sceneHeight * 0.36 })
      .visibility(this.sceneKey === 'neon_street' ? Visibility.None : Visibility.Visible)
      .zIndex(3)

      Stack({ alignContent: Alignment.TopStart }) {
        Row({ space: 0 }) {
          Image($rawfile('background/midground_dirt.png')).width(this.roadTileWidth()).height(this.sceneHeight * 0.22).objectFit(ImageFit.Fill)
          Image($rawfile('background/midground_dirt.png')).width(this.roadTileWidth()).height(this.sceneHeight * 0.22).objectFit(ImageFit.Fill)
          Image($rawfile('background/midground_dirt.png')).width(this.roadTileWidth()).height(this.sceneHeight * 0.22).objectFit(ImageFit.Fill)
          Image($rawfile('background/midground_dirt.png')).width(this.roadTileWidth()).height(this.sceneHeight * 0.22).objectFit(ImageFit.Fill)
        }
        .width(this.roadTileWidth() * 4)
        .translate({ x: -this.layerLoopOffset(0.25) })
      }
      .width('100%')
      .height(this.sceneHeight * 0.22)
      .clip(true)
      .position({ x: 0, y: this.sceneHeight * 0.48 })
      .visibility(this.sceneKey === 'neon_street' ? Visibility.None : Visibility.Visible)
      .zIndex(6)

      Stack({ alignContent: Alignment.TopStart }) {
        this.roadStrip();
      }
      .width('100%')
      .height(this.roadBandHeight())
      .clip(true)
      .position({ x: 0, y: this.roadSurfaceY() })
      .zIndex(10)

      ForEach(this.sideEntities, (item: SideEntityView) => {
        SideEntitySprite({
          sceneKey: this.sceneKey,
          entityIndex: item.entityIndex,
          displayWidth: entityDisplaySize(item.entityIndex, this.sceneKey).width,
          displayHeight: entityDisplaySize(item.entityIndex, this.sceneKey).height
        })
          .width(entityDisplaySize(item.entityIndex, this.sceneKey).width)
          .height(entityDisplaySize(item.entityIndex, this.sceneKey).height)
          .position({ x: this.entityScreenX(item), y: this.entityTop(item) })
          .zIndex(this.entityZIndex(item))
      }, (item: SideEntityView) => item.id)

      ForEach(this.vegetation, (item: VegetationView) => {
        VegetationSprite({ plantIndex: item.plantIndex, displayHeight: VEGETATION_DISPLAY_HEIGHT })
          .width(VEGETATION_DISPLAY_WIDTH)
          .height(VEGETATION_DISPLAY_HEIGHT)
          .position({ x: this.vegetationScreenX(item), y: this.vegetationTop(item) })
          .visibility(this.sceneKey === 'neon_street' ? Visibility.None : Visibility.Visible)
          .zIndex(this.vegetationZIndex(item))
      }, (item: VegetationView) => item.id)

      ForEach(this.members, (member: SessionMember, index: number) => {
        Column() {
          Text(`${index + 1} · ${member.displayName}`)
            .fontSize(11)
            .fontColor(Color.White)
            .backgroundColor('#AA000000')
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(6)
          WalkerSprite({
            frameIndex: this.walkerFrameFor(member, index),
            avatar: memberAvatar(member.avatarKey, index, member.resolvedAvatarKey ?? ''),
            colorSlot: member.colorSlot ?? 0
          })
        }
        .alignItems(HorizontalAlign.Center)
        .scale({
          x: this.walkerDepthScale(index),
          y: this.walkerDepthScale(index),
          centerX: WALKER_COLUMN_HALF_WIDTH,
          centerY: WALKER_COLUMN_FEET_ANCHOR_Y
        })
        .position({
          x: this.walkerPositionX(index),
          y: this.walkerPositionY(index)
        })
        .zIndex(this.walkerPositionZ(index))
      }, (member: SessionMember, index: number) => `${index}:${member.id}`)

      if (this.sceneKey === 'neon_street') {
        this.neonForeground()
        this.neonRain()
      }
    }
    .width('100%')
    .height('100%')
    .clip(this.sceneKey !== 'neon_street')
    .onAreaChange((_old, area) => {
      this.sceneWidth = area.width as number;
      this.sceneHeight = area.height as number;
      if (!this.seeded && this.sceneWidth > 0) {
        this.seedEntities();
      }
      if (this.sceneWidth > 0) {
        this.ensureWalkerStands();
      }
      if (this.sceneKey === 'neon_street' && this.neonOccluderSegments.length === 0) {
        this.resetNeonOccluderStrip();
      }
    })
  }
}
