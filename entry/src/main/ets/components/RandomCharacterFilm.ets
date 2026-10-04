import { curves } from '@kit.ArkUI';
import { RANDOM_CHARACTER_KEYS } from '../assets/CharacterCatalog';
import { CORAL, INK, LILAC, WHITE } from './ComicKit';

export const RANDOM_FILM_HEIGHT: number = 250;
const FILM_SIDE_INSET: number = 12;
const FILM_REEL_TOP: number = 39;
const FILM_REEL_HEIGHT: number = 181;
const FILM_CARD_WIDTH: number = 116;
const FILM_CARD_HEIGHT: number = 150;
const FILM_CARD_GAP: number = 14;
const FILM_CARD_TOP: number = 14;
const FILM_IMAGE_WIDTH: number = 102;
const FILM_IMAGE_HEIGHT: number = 126;
const FILM_ROLL_MS: number = 1600;
const FILM_RESULT_ALIGN_MS: number = 240;
const FILM_START_INDEX: number = 2;
const FILM_STOP_BASE: number = 10;
const FILM_FOCUS_WIDTH: number = 120;
const FILM_FOCUS_HEIGHT: number = 154;
const FILM_FOCUS_TOP: number = 12;
const FILM_FOCUS_RING: number = 6;

/** Lobby-only film: motion never draws a new role or reveals its color palette. */
@Component
export struct RandomCharacterFilm {
  @Prop @Watch('onPlaybackRequested') request: number = 0;
  @Prop @Watch('onPlaybackCancelled') cancelRequest: number = 0;
  @Prop @Watch('onMemberChanged') memberId: string = '';
  @Prop @Watch('onPlaybackRequested') ready: boolean = false;
  @Prop @Watch('onResultChanged') resolvedAvatarKey: string = '';
  @Prop @Watch('onResultChanged') selectionPending: boolean = false;
  @Prop @Watch('onResultChanged') drawId: number = 0;
  @Prop @Watch('onResultChanged') skipPlayback: boolean = false;
  @Prop revealReady: boolean = false;
  onSettled: (memberId: string, drawId: number) => void = () => {};
  @State private reelWidth: number = 0;
  @State private trackOffsetX: number = -FILM_START_INDEX * (FILM_CARD_WIDTH + FILM_CARD_GAP);
  @State private rolling: boolean = false;
  @State private beatIndex: number = -1;
  @State private aligningResult: boolean = false;
  private mounted: boolean = false;
  private generation: number = 0;
  private kickTimer: number = -1;
  private beatTimers: number[] = [];
  private lastPlayedMemberId: string = '';
  private lastPlayedRequest: number = -1;
  private suppressed: boolean = false;
  private settledIndex: number = FILM_START_INDEX;
  private playbackFinished: boolean = false;
  private aligningDrawId: number = 0;
  private completedIdentity: string = '';
  private readonly cardIndices: number[] = this.makeCardIndices();
  private readonly holes: number[] = [0, 1, 2, 3, 4, 5, 6];
  private readonly beatIndices: number[] = [0, 1, 2, 3];

  aboutToAppear(): void {
    this.mounted = true;
    this.playIfNeeded();
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.invalidatePlayback();
  }

  private poolSize(): number {
    return Math.max(1, RANDOM_CHARACTER_KEYS.length);
  }

  private stopBase(): number {
    return Math.ceil(FILM_STOP_BASE / this.poolSize()) * this.poolSize();
  }

  private makeCardIndices(): number[] {
    const indices: number[] = [];
    for (let i = 0; i < this.stopBase() + this.poolSize() + 4; i++) {
      indices.push(i);
    }
    return indices;
  }

  private cardAvatar(index: number): string {
    return RANDOM_CHARACTER_KEYS[index % this.poolSize()] ?? '';
  }

  private cardOffset(index: number): number {
    return -index * (FILM_CARD_WIDTH + FILM_CARD_GAP);
  }

  private trackWidth(): number {
    return this.cardIndices.length * FILM_CARD_WIDTH + (this.cardIndices.length - 1) * FILM_CARD_GAP;
  }

  private resultIndex(): number {
    const poolIndex = RANDOM_CHARACTER_KEYS.indexOf(this.resolvedAvatarKey);
    return poolIndex >= 0 ? this.stopBase() + poolIndex : this.stopBase();
  }

  private invalidatePlayback(): void {
    // Native animation completions can arrive after a role/member/page switch.
    // Guard those as well as timers so an obsolete film never restarts itself.
    this.generation += 1;
    this.playbackFinished = false;
    this.aligningResult = false;
    if (this.kickTimer >= 0) {
      clearTimeout(this.kickTimer);
      this.kickTimer = -1;
    }
    this.beatTimers.forEach((timer: number) => { clearTimeout(timer); });
    this.beatTimers = [];
  }

  private stopPlayback(): void {
    this.invalidatePlayback();
    this.rolling = false;
    this.beatIndex = -1;
    this.settledIndex = this.resultIndex();
    if (this.mounted) {
      this.getUIContext().animateTo({ duration: 0 }, () => {
        this.trackOffsetX = this.cardOffset(this.settledIndex);
      });
    }
  }

  private onPlaybackCancelled(): void {
    this.suppressed = true;
    this.stopPlayback();
  }

  private onMemberChanged(): void {
    this.suppressed = false;
    // Result/skip props may already have started this member before its own
    // watcher runs. Do not cancel that kick and then suppress it as a duplicate.
    if (this.mounted && this.ready && this.rolling && this.lastPlayedMemberId === this.memberId &&
      this.lastPlayedRequest === this.request) {
      return;
    }
    this.stopPlayback();
    this.playIfNeeded();
  }

  private onPlaybackRequested(): void {
    if (!this.ready) {
      this.stopPlayback();
      this.lastPlayedMemberId = '';
      this.lastPlayedRequest = -1;
      return;
    }
    if (this.request !== this.lastPlayedRequest) {
      this.suppressed = false;
    }
    this.playIfNeeded();
  }

  private playIfNeeded(): void {
    // Initialization and measurement may finish in either order. Consume the
    // entry/request only once BOTH are ready, never on a routine team refresh.
    if (!this.mounted || !this.ready || this.reelWidth <= 0 || this.memberId.length === 0 ||
      this.suppressed || RANDOM_CHARACTER_KEYS.length === 0) {
      return;
    }
    if (this.skipPlayback && !this.selectionPending) {
      this.restoreSettledPreview();
      return;
    }
    if (this.lastPlayedMemberId === this.memberId && this.lastPlayedRequest === this.request) {
      return;
    }
    this.lastPlayedMemberId = this.memberId;
    this.lastPlayedRequest = this.request;
    this.invalidatePlayback();
    const token = this.generation;
    this.rolling = true;
    this.beatIndex = 0;
    this.getUIContext().animateTo({ duration: 0 }, () => {
      this.trackOffsetX = this.cardOffset(FILM_START_INDEX);
    });
    // Commit the reset in its own frame before moving the repeated film strip.
    this.kickTimer = setTimeout(() => {
      this.kickTimer = -1;
      if (!this.isCurrentPlayback(token)) {
        return;
      }
      this.startBeatTicks(token);
      // The controller alone owns the draw. Late snapshots only adjust the
      // concealed stop; animation indices must never become a second lottery.
      this.settledIndex = this.resultIndex();
      this.getUIContext().animateTo({
        duration: FILM_ROLL_MS,
        curve: curves.cubicBezierCurve(0.14, 0.62, 0.24, 1),
        onFinish: () => {
          if (!this.isCurrentPlayback(token)) {
            return;
          }
          this.playbackFinished = true;
          this.rolling = false;
          this.beatIndex = -1;
          this.onResultChanged();
        }
      }, () => { this.trackOffsetX = this.cardOffset(this.settledIndex); });
    }, 16);
  }

  private isCurrentPlayback(token: number): boolean {
    return this.mounted && this.ready && token === this.generation;
  }

  private startBeatTicks(token: number): void {
    const delays: number[] = [140, 300, 500, 740, 1020, 1320];
    delays.forEach((delay: number, index: number) => {
      this.beatTimers.push(setTimeout(() => {
        if (this.isCurrentPlayback(token)) {
          this.beatIndex = (index + 1) % this.beatIndices.length;
        }
      }, delay));
    });
  }

  private onResultChanged(): void {
    if (this.selectionPending) {
      // Prop watchers may deliver request before pending. A cached stop must
      // not consume that explicit reroll before its pending state arrives.
      this.playIfNeeded();
      return;
    }
    if (this.skipPlayback && !this.rolling) {
      this.restoreSettledPreview();
      return;
    }
    // A member change may arrive while the previous member's skip flag is
    // still set. Its later release must start the new context, even without a tap.
    if (this.request !== this.lastPlayedRequest || this.memberId !== this.lastPlayedMemberId) {
      this.playIfNeeded();
      return;
    }
    if (!this.mounted || !this.ready || !this.playbackFinished || this.rolling || this.suppressed || this.selectionPending ||
      this.lastPlayedMemberId !== this.memberId || RANDOM_CHARACTER_KEYS.indexOf(this.resolvedAvatarKey) < 0) {
      return;
    }
    const index = this.resultIndex();
    if (index === this.settledIndex) {
      if (!this.aligningResult) {
        this.notifySettled();
        return;
      }
      if (this.aligningDrawId === this.drawId) {
        return;
      }
    }
    const token = this.generation;
    const drawId = this.drawId;
    this.settledIndex = index;
    this.aligningResult = true;
    this.aligningDrawId = drawId;
    this.getUIContext().animateTo({
      duration: FILM_RESULT_ALIGN_MS,
      curve: Curve.EaseOut,
      onFinish: () => {
        if (!this.isCurrentPlayback(token) || drawId !== this.drawId || drawId !== this.aligningDrawId) {
          return;
        }
        this.aligningResult = false;
        this.notifySettled();
      }
    }, () => {
      this.trackOffsetX = this.cardOffset(index);
    });
  }

  private restoreSettledPreview(): void {
    if (!this.mounted || !this.ready || this.suppressed || this.rolling || this.reelWidth <= 0 ||
      this.memberId.length === 0 || !Number.isSafeInteger(this.drawId) || this.drawId <= 0 ||
      RANDOM_CHARACTER_KEYS.indexOf(this.resolvedAvatarKey) < 0) {
      return;
    }
    // Completion belongs to the member/draw, not this component instance.
    // Restoring a stop neither draws again nor consumes a future explicit tap.
    if (!this.playbackFinished || this.aligningResult || this.settledIndex !== this.resultIndex()) {
      this.stopPlayback();
    }
    this.playbackFinished = true;
  }

  private notifySettled(): void {
    if (!this.mounted || !this.ready || !this.playbackFinished || this.rolling || this.aligningResult ||
      this.suppressed || this.selectionPending || !Number.isSafeInteger(this.drawId) || this.drawId <= 0 ||
      RANDOM_CHARACTER_KEYS.indexOf(this.resolvedAvatarKey) < 0) {
      return;
    }
    const identity = `${this.memberId}:${this.drawId}`;
    if (identity === this.completedIdentity) {
      return;
    }
    // Notify only after the final (possibly late-result) stop. All devices keep
    // their question marks until the leader publishes a shared reveal deadline.
    this.completedIdentity = identity;
    this.onSettled(this.memberId, this.drawId);
  }

  private showCardQuestion(index: number): boolean {
    return !this.revealReady || !this.playbackFinished || this.rolling || this.aligningResult ||
      index !== this.settledIndex;
  }

  private statusLabel(): string {
    if (!this.ready) {
      return '正在准备…';
    }
    if (this.rolling) {
      return '正在抽取…';
    }
    if (this.selectionPending || this.aligningResult || RANDOM_CHARACTER_KEYS.indexOf(this.resolvedAvatarKey) < 0) {
      return '正在同步…';
    }
    return this.revealReady ? '剪影已同步' : '正在同步全队…';
  }

  @Builder
  private sprocketHoles(top: number) {
    Row({ space: 9 }) {
      ForEach(this.holes, (_hole: number) => {
        Rect().width(6).height(4).fill(INK).radius(1)
      }, (hole: number) => hole.toString())
    }.width(96).height(4).position({ x: 10, y: top })
  }

  @Builder
  private filmCard(index: number) {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.cardAvatar(index).length > 0) {
        Image($rawfile(`comic/mystery/${this.cardAvatar(index)}.png`))
          .width(FILM_IMAGE_WIDTH).height(FILM_IMAGE_HEIGHT).objectFit(ImageFit.Contain)
          .position({ x: 5, y: 11 })
      }
      if (this.showCardQuestion(index)) {
        Text('?').fontSize(65).fontWeight(900).fontColor(WHITE)
          .textAlign(TextAlign.Center).width(FILM_CARD_WIDTH).height(84)
          .textShadow({ radius: 0, offsetX: 2, offsetY: 2, color: INK })
          .rotate({ angle: -5 }).position({ x: 0, y: 28 })
      }
      this.sprocketHoles(6)
      this.sprocketHoles(FILM_CARD_HEIGHT - 10)
    }.width(FILM_CARD_WIDTH).height(FILM_CARD_HEIGHT).flexShrink(0)
      .backgroundColor(WHITE).border({ width: 2, color: INK }).borderRadius(3)
      .shadow({ radius: 0, offsetX: 2, offsetY: 3, color: INK })
  }

  @Builder
  private filmReel() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row({ space: FILM_CARD_GAP }) {
        ForEach(this.cardIndices, (index: number) => {
          this.filmCard(index)
        }, (index: number) => index.toString())
      }.width(this.trackWidth()).height(FILM_CARD_HEIGHT)
        .position({ x: this.reelWidth / 2 - FILM_CARD_WIDTH / 2, y: FILM_CARD_TOP })
        .translate({ x: this.trackOffsetX })
      Rect().width(FILM_FOCUS_WIDTH + FILM_FOCUS_RING * 2)
        .height(FILM_FOCUS_HEIGHT + FILM_FOCUS_RING * 2).radius(5)
        .fill(Color.Transparent).stroke(CORAL).strokeWidth(FILM_FOCUS_RING)
        .position({ x: this.reelWidth / 2 - FILM_FOCUS_WIDTH / 2 - FILM_FOCUS_RING,
          y: FILM_FOCUS_TOP - FILM_FOCUS_RING })
      Rect().width(FILM_FOCUS_WIDTH).height(FILM_FOCUS_HEIGHT).radius(3)
        .fill(Color.Transparent).stroke(INK).strokeWidth(3)
        .position({ x: this.reelWidth / 2 - FILM_FOCUS_WIDTH / 2, y: FILM_FOCUS_TOP })
      Text('▼').fontSize(13).fontWeight(900).fontColor(INK).textAlign(TextAlign.Center)
        .width(24).height(17).backgroundColor(CORAL).border({ width: 1.5, color: INK }).borderRadius(2)
        .position({ x: this.reelWidth / 2 - 12, y: 0 })
    }.width('100%').height(FILM_REEL_HEIGHT).clip(true)
      .onAreaChange((_oldArea, area) => {
        this.reelWidth = area.width as number;
        this.playIfNeeded();
      })
  }

  build() {
    Column() {
      Row() {
        Text('RANDOM PICK').fontSize(12).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK)
          .padding({ left: 7, right: 7, top: 3, bottom: 3 })
          .backgroundColor(CORAL).border({ width: 1.5, color: INK }).borderRadius(3)
          .shadow({ radius: 0, offsetX: 2, offsetY: 2, color: INK }).rotate({ angle: -3 })
        Blank()
        Text(this.statusLabel()).fontSize(11).fontWeight(FontWeight.Bold).fontColor(INK)
      }.width('100%').height(FILM_REEL_TOP)
      this.filmReel()
      Row() {
        Text('JUST KEEP THE BEAT.').fontSize(10).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK)
        Blank()
        Row({ space: 4 }) {
          ForEach(this.beatIndices, (beat: number) => {
            Rect().width(8).height(8).radius(1).stroke(INK).strokeWidth(1)
              .fill(this.beatIndex === beat ? CORAL : WHITE)
          }, (beat: number) => beat.toString())
        }
      }.width('100%').height(RANDOM_FILM_HEIGHT - FILM_REEL_TOP - FILM_REEL_HEIGHT)
    }.width('100%').height(RANDOM_FILM_HEIGHT)
      .padding({ left: FILM_SIDE_INSET, right: FILM_SIDE_INSET })
      .backgroundColor(LILAC).border({ width: 1.5, color: INK }).borderRadius(6).clip(true)
      .accessibilityGroup(true).accessibilityText(`随机角色，${this.statusLabel()}`)
      .hitTestBehavior(HitTestMode.None)
  }
}
