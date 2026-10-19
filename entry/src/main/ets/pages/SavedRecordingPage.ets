import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { fileUri } from '@kit.CoreFileKit';
import { AppSession } from '../app/AppSession';
import { logUserFailure, showUserNotice, userErrorMessage } from '../common/UserFeedback';
import { CARD_SHADOW, CONTROL_SHADOW, CORAL, INK, LILAC, PAPER, WHITE } from '../components/ComicKit';
import { RecordingClip, RecordingScope } from '../recording/RecordingModels';
import { RecordingRepository } from '../recording/RecordingRepository';
import { RecordingShareService } from '../sharing/RecordingShareService';
import { ShareCalendarSheet } from '../components/ShareCalendarSheet';
import { getShareCheckInSummary, getShareCheckInTodayKey } from '../store/ShareCheckInStore';
import { SHARE_CHECK_IN_DAY_MS } from '../store/ShareCheckInRules';

const SAVED_PAGE_SIDE_INSET: number = 24;
const SAVED_HEADER_TOP: number = 10;
const SAVED_TITLE_TOP: number = 18;
const SAVED_TITLE_HEIGHT: number = 40;
const SAVED_TICKET_TOP_GAP: number = 26;
const SAVED_TICKET_MAX_WIDTH: number = 420;
const SAVED_TICKET_INSET: number = 14;
const SAVED_TICKET_FOOTER_HEIGHT: number = 132;
const SAVED_TICKET_NOTCH: number = 8;
const SAVED_TICKET_RADIUS: number = 14;
const SAVED_TICKET_SHADOW_X: number = 5;
const SAVED_TICKET_SHADOW_Y: number = 6;
const SAVED_COVER_MIN_HEIGHT: number = 180;
const SAVED_COVER_MAX_HEIGHT: number = 420;
const SAVED_SHARE_HEIGHT: number = 56;
const SAVED_ACTION_GAP: number = 10;
const SAVED_CHECK_IN_WIDTH: number = 108;
const SAVED_SHARE_ICON_SIZE: number = 28;
const SAVED_CAPTION_TOP: number = 24;
const SAVED_PAGE_BOTTOM: number = 16;
const SAVED_PAUSE_SHEET_WIDTH: string = '88%';

interface SavedRecordingParams {
  clipId: string;
  scope?: RecordingScope;
}

@Entry
@Component
struct SavedRecordingPage {
  @StorageLink('safeAreaTop') topSafeInset: number = 0;
  @StorageLink('safeAreaBottom') bottomSafeInset: number = 0;
  @StorageLink('recordingShareEpoch') @Watch('refreshShareStatus') shareEpoch: number = 0;
  @StorageLink('shareCheckInEpoch') @Watch('refreshShareStatus') checkInEpoch: number = 0;
  @State savedClip: RecordingClip | undefined = undefined;
  @State coverLoading: boolean = false;
  @State busy: boolean = false;
  @State pauseConfirmVisible: boolean = false;
  @State canCheckInToday: boolean = false;
  @State checkingIn: boolean = false;
  @State calendarVisible: boolean = false;
  @State bodyHeight: number = 650;
  @State ticketWidth: number = 310;
  private clipId: string = '';
  private active: boolean = false;
  private coverTask: Promise<void> | undefined = undefined;
  private recordingScope: RecordingScope = 'solo';
  private dayRefreshTimer: number = -1;

  aboutToAppear(): void {
    const params = router.getParams() as SavedRecordingParams;
    this.clipId = params?.clipId ?? '';
    this.recordingScope = params?.scope ?? 'solo';
    this.active = true;
    this.refreshClip();
    this.refreshShareStatus();
    this.scheduleDayRefresh();
  }

  onPageShow(): void {
    this.active = true;
    void RecordingShareService.markReturnedToApp()
      .then(() => { if (this.active) { this.refreshShareStatus(); } })
      .catch((error: Object) => logUserFailure('saved-recording-return', error));
    this.refreshClip();
    this.refreshShareStatus();
    this.scheduleDayRefresh();
  }

  onPageHide(): void {
    this.active = false;
    this.clearDayRefresh();
  }

  aboutToDisappear(): void {
    this.active = false;
    this.clearDayRefresh();
  }

  onBackPress(): boolean {
    if (this.busy) { return true; }
    if (this.calendarVisible) { this.calendarVisible = false; return true; }
    if (this.pauseConfirmVisible) {
      this.pauseConfirmVisible = false;
      return true;
    }
    return false;
  }

  private hostContext(): common.UIAbilityContext {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) { throw new Error('无法获取应用上下文'); }
    return context as common.UIAbilityContext;
  }

  private refreshClip(): void {
    this.savedClip = RecordingRepository.get(this.clipId);
    if (this.savedClip === undefined || this.savedClip.coverPath !== undefined || this.coverTask !== undefined) { return; }
    this.coverLoading = true;
    const id = this.clipId;
    const task = this.loadCover(id).finally(() => {
      if (this.coverTask === task) { this.coverTask = undefined; }
      this.coverLoading = false;
    });
    this.coverTask = task;
  }

  private async loadCover(id: string): Promise<void> {
    try {
      await RecordingRepository.ensureCover(id);
      if (this.active && this.clipId === id) { this.savedClip = RecordingRepository.get(id); }
    } catch (error) {
      // A derived thumbnail may fail without changing the already saved album video or shareable work.
      logUserFailure('saved-recording-cover', error);
    }
  }

  private coverSource(): string {
    const path = this.savedClip?.coverPath;
    return path === undefined ? '' : fileUri.getUriFromPath(path);
  }

  private durationLabel(): string {
    const seconds = Math.floor(Math.max(0, this.savedClip?.durationMs ?? 0) / 1000);
    return `${Math.floor(seconds / 60).toString().padStart(2, '0')}:${(seconds % 60).toString().padStart(2, '0')}`;
  }

  private practicePlaying(): boolean {
    const state = AppSession.get()?.controller.state;
    return state === 'playing' || state === 'countdown';
  }

  private requestShare(): void {
    if (this.busy) { return; }
    if (RecordingRepository.get(this.clipId) === undefined) {
      showUserNotice('本机作品已移除，请前往相册分享已保存的视频', 'saved-recording-missing');
      return;
    }
    if (this.practicePlaying()) {
      if (AppSession.get()?.controller.isLeader) {
        this.pauseConfirmVisible = true;
      } else {
        showUserNotice('请等队长暂停后再分享，视频已保存到相册', 'saved-recording-member-playing');
      }
      return;
    }
    void this.shareClip();
  }

  private async pauseAndShare(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    const session = AppSession.get();
    try {
      // Only a deliberate leader confirmation may pause the shared practice. Members never pause it for sharing.
      if (this.practicePlaying()) {
        if (!session?.controller.isLeader) {
          showUserNotice('请等队长暂停后再分享，视频已保存到相册', 'saved-recording-member-playing');
          return;
        }
        await session.leaderPause();
      }
      if (session !== AppSession.get() || this.practicePlaying()) {
        showUserNotice('练习状态已变化，请重新点击分享', 'saved-recording-session-changed');
        return;
      }
      this.pauseConfirmVisible = false;
    } catch (error) {
      logUserFailure('saved-recording-pause', error);
      showUserNotice('暂停练习失败，视频已保存到相册', 'saved-recording-pause');
      return;
    } finally {
      this.busy = false;
    }
    if (this.active) { await this.shareClip(); }
  }

  private async shareClip(): Promise<void> {
    if (this.busy || !this.active) { return; }
    if (this.practicePlaying()) { this.requestShare(); return; }
    const clip = RecordingRepository.get(this.clipId);
    if (clip === undefined) {
      showUserNotice('本机作品已移除，请前往相册分享已保存的视频', 'saved-recording-missing');
      return;
    }
    this.busy = true;
    try {
      await RecordingShareService.share(clip, this.hostContext(), 'system');
      this.refreshShareStatus();
    } catch (error) {
      logUserFailure('saved-recording-share', error);
      showUserNotice(userErrorMessage(error, '未能打开系统分享面板，请稍后重试'), 'saved-recording-share');
    } finally {
      this.busy = false;
    }
  }

  refreshShareStatus(): void {
    // Repeated shares before confirmation must retain the daily action. Opening
    // the chooser alone never qualifies; the service owns handoff/fallback validation.
    this.canCheckInToday = !getShareCheckInSummary().todayCompleted &&
      RecordingShareService.getPendingForClipToday(this.clipId) !== undefined;
  }

  private clearDayRefresh(): void {
    if (this.dayRefreshTimer >= 0) { clearTimeout(this.dayRefreshTimer); }
    this.dayRefreshTimer = -1;
  }

  private scheduleDayRefresh(): void {
    this.clearDayRefresh();
    const nextDay = new Date(`${getShareCheckInTodayKey()}T00:00:00+08:00`).getTime() + SHARE_CHECK_IN_DAY_MS;
    this.dayRefreshTimer = setTimeout(() => {
      this.dayRefreshTimer = -1;
      if (!this.active) { return; }
      this.refreshShareStatus();
      this.scheduleDayRefresh();
    }, Math.max(1000, nextDay - Date.now() + 250));
  }

  private async confirmToday(): Promise<void> {
    if (this.busy || !this.active) { return; }
    // Revalidate at the tap: midnight or a check-in on another work can make
    // the visible action stale. Only this deliberate tap confirms publication.
    const pending = RecordingShareService.getPendingForClipToday(this.clipId);
    if (pending === undefined) {
      this.refreshShareStatus();
      if (getShareCheckInSummary().todayCompleted) {
        this.calendarVisible = true;
      } else {
        showUserNotice('今天还没有待确认的分享，请重新分享后打卡', 'saved-recording-check-in-current');
      }
      return;
    }
    this.busy = true;
    this.checkingIn = true;
    try {
      await RecordingShareService.confirmPublished(pending.id);
      this.refreshShareStatus();
      if (this.active) { this.calendarVisible = true; }
    } catch (error) {
      logUserFailure('saved-recording-check-in', error);
      if (this.active) {
        showUserNotice(userErrorMessage(error, '打卡暂未保存，请稍后重试；待确认分享会保留'), 'saved-recording-check-in');
      }
      this.refreshShareStatus();
    } finally {
      this.checkingIn = false;
      this.busy = false;
    }
  }

  private practiceLabel(): string {
    return `${(this.savedClip?.scope ?? this.recordingScope) === 'team' ? '多人练习' : '单人练习'} · ${this.durationLabel()}`;
  }

  private coverHeight(): number {
    const fixedHeight = SAVED_TITLE_TOP + SAVED_TITLE_HEIGHT + SAVED_TICKET_TOP_GAP +
      SAVED_TICKET_INSET * 2 + SAVED_TICKET_FOOTER_HEIGHT + SAVED_CAPTION_TOP + 40 + 10;
    // Shrink only the static cover on short screens. A scroll fallback preserves the complete share control.
    return Math.min(SAVED_COVER_MAX_HEIGHT, Math.max(SAVED_COVER_MIN_HEIGHT, this.bodyHeight - fixedHeight));
  }

  private ticketHeight(): number {
    return this.coverHeight() + SAVED_TICKET_INSET * 2 + SAVED_TICKET_FOOTER_HEIGHT;
  }

  private tearY(): number {
    return this.coverHeight() + SAVED_TICKET_INSET * 2;
  }

  private ticketOutline(): string {
    // SVG path commands use physical pixels, while measured Areas and the layout constants use vp.
    // Convert coordinates together so high-density devices keep the notches aligned with the footer.
    const l = vp2px(1);
    const r = vp2px(Math.max(2, this.ticketWidth - 1));
    const b = vp2px(this.ticketHeight() - 1);
    const c = vp2px(SAVED_TICKET_RADIUS);
    const n = vp2px(SAVED_TICKET_NOTCH);
    const y = vp2px(this.tearY());
    return `M ${l + c} ${l} H ${r - c} Q ${r} ${l} ${r} ${l + c} V ${y - n}` +
      ` A ${n} ${n} 0 0 0 ${r} ${y + n} V ${b - c} Q ${r} ${b} ${r - c} ${b}` +
      ` H ${l + c} Q ${l} ${b} ${l} ${b - c} V ${y + n}` +
      ` A ${n} ${n} 0 0 0 ${l} ${y - n} V ${l + c} Q ${l} ${l} ${l + c} ${l} Z`;
  }

  @Builder
  private cover() {
    // A static first-frame image must never acquire audio focus from a running practice.
    Stack({ alignContent: Alignment.BottomEnd }) {
      if (this.coverSource().length > 0) {
        Image(this.coverSource()).width('100%').height('100%').objectFit(ImageFit.Cover)
      } else {
        Column({ space: 10 }) {
          Text('TAKE').fontSize(28).fontWeight(900).fontStyle(FontStyle.Italic).fontColor('#978C7A')
          Text(this.coverLoading ? '正在准备视频缩略图…' : '视频已保存在相册')
            .fontSize(12).fontColor('#736B60').textAlign(TextAlign.Center)
        }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      }
      if (this.savedClip !== undefined) {
        Text(this.durationLabel()).fontSize(12).fontWeight(900).fontColor(WHITE)
          .padding({ left: 8, right: 8, top: 5, bottom: 5 }).backgroundColor('#A6171B1F')
          .borderRadius(5).margin(10)
      }
    }.width('100%').height(this.coverHeight()).backgroundColor('#F0EADD').borderRadius(10)
      .clip(true).accessibilityText('已保存视频的静态缩略图')
  }

  @Builder
  private shareButton() {
    Stack() {
      Row().width('100%').height(SAVED_SHARE_HEIGHT).backgroundColor(INK).borderRadius(14)
        .translate({ x: 1, y: 4 }).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      Button({ type: ButtonType.Normal }) {
        Row({ space: this.canCheckInToday ? 8 : 12 }) {
          Image($rawfile('comic/icons/share_video.svg')).width(SAVED_SHARE_ICON_SIZE).height(SAVED_SHARE_ICON_SIZE)
            .objectFit(ImageFit.Contain).accessibilityLevel('no')
          Text(this.busy && !this.checkingIn ? '准备中…' : '分享').fontSize(this.canCheckInToday ? 18 : 22).fontWeight(900).fontColor(WHITE)
        }.justifyContent(FlexAlign.Center)
      }.width('100%').height(SAVED_SHARE_HEIGHT).padding({ left: 12, right: 12 })
        .backgroundColor(CORAL).border({ width: 1.5, color: INK }).borderRadius(14)
        .enabled(!this.busy && this.savedClip !== undefined).opacity(this.busy ? 0.65 : 1)
        .accessibilityText(this.busy && !this.checkingIn ? '正在准备分享视频' : '分享视频，打开系统分享面板')
        .onClick(() => this.requestShare())
    }.width('100%').height(SAVED_SHARE_HEIGHT)
  }

  @Builder
  private ticketActions() {
    Row({ space: this.canCheckInToday ? SAVED_ACTION_GAP : 0 }) {
      Column() {
        this.shareButton()
      }.layoutWeight(1)
      if (this.canCheckInToday) {
        Stack() {
          Row().width('100%').height(SAVED_SHARE_HEIGHT).backgroundColor(INK).borderRadius(14)
            .translate({ x: 1, y: 4 }).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
          Button(this.checkingIn ? '记卡中…' : '去打卡', { type: ButtonType.Normal })
            .width('100%').height(SAVED_SHARE_HEIGHT).padding({ left: 8, right: 8 })
            .fontSize(17).fontWeight(900).fontColor(INK).backgroundColor(LILAC)
            .border({ width: 1.5, color: INK }).borderRadius(14).enabled(!this.busy)
            .accessibilityText(this.checkingIn ? '正在保存今日打卡' : '确认已发布并查看分享日历')
            .onClick(() => { void this.confirmToday(); })
        }.width(SAVED_CHECK_IN_WIDTH).height(SAVED_SHARE_HEIGHT)
      }
    }.width('100%').height(SAVED_SHARE_HEIGHT)
  }

  @Builder
  private ticket() {
    Stack({ alignContent: Alignment.TopStart }) {
      Path().commands(this.ticketOutline()).width('100%').height('100%').fill(INK)
        .translate({ x: SAVED_TICKET_SHADOW_X, y: SAVED_TICKET_SHADOW_Y })
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      Path().commands(this.ticketOutline()).width('100%').height('100%').fill(WHITE).stroke(INK).strokeWidth(1.5)
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      Path().commands(`M ${vp2px(18)} ${vp2px(this.tearY())} H ${vp2px(this.ticketWidth - 18)}`)
        .width('100%').height('100%').stroke('#B5B0A5').strokeWidth(1).strokeDashArray([4, 5])
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      Column() {
        Column() {
          this.cover()
        }.width('100%').padding(SAVED_TICKET_INSET)
        Column() {
          Row({ space: 6 }) {
            Image($rawfile('comic/icons/saved_video.svg')).width(16).height(16).objectFit(ImageFit.Contain)
              .accessibilityLevel('no')
            Text(this.practiceLabel()).fontSize(12).minFontSize(10).maxFontSize(12)
              .fontWeight(900).fontColor(INK).maxLines(1).layoutWeight(1)
            Row({ space: 4 }) {
              Image($rawfile('comic/icons/saved_check.svg')).width(15).height(15).objectFit(ImageFit.Contain)
                .accessibilityLevel('no')
              Text('视频已存入相册').fontSize(10).fontWeight(FontWeight.Bold).fontColor('#78766F').maxLines(1)
            }
          }.width('100%').height(44).margin({ bottom: 12 })
          this.ticketActions()
        }.width('100%').height(SAVED_TICKET_FOOTER_HEIGHT).padding({ left: 16, right: 16, bottom: 20 })
      }.width('100%')
    }.width('100%').height(this.ticketHeight())
      .onAreaChange((_previous: Area, area: Area) => {
        const width = Number(area.width);
        if (width > 0 && Math.abs(width - this.ticketWidth) > 0.1) { this.ticketWidth = width; }
      })
  }

  @Builder
  private pauseConfirm() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 14 }) {
        Text('先让练习停一拍').fontSize(23).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK).width('100%')
        Text('分享会切换到其他应用。请先暂停练习，再打开系统分享面板；视频已经保存到相册。')
          .fontSize(13).fontColor('#625C54').lineHeight(21).width('100%')
        Button('暂停练习并分享', { type: ButtonType.Normal }).width('100%').height(48)
          .fontSize(16).fontWeight(900).fontColor(INK).backgroundColor(CORAL)
          .border({ width: 1.5, color: INK }).borderRadius(6).shadow(CONTROL_SHADOW)
          .enabled(!this.busy).onClick(() => { void this.pauseAndShare(); })
        Text('继续练习，稍后再分享').fontSize(12).fontWeight(900).fontColor(INK).padding(6)
          .enabled(!this.busy).onClick(() => { this.pauseConfirmVisible = false; })
      }.width(SAVED_PAUSE_SHEET_WIDTH).padding(20).backgroundColor(PAPER)
        .border({ width: 2, color: INK }).borderRadius(9).shadow(CARD_SHADOW)
    }.width('100%').height('100%').backgroundColor('#82000000').zIndex(110)
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Button({ type: ButtonType.Normal }) {
            Text('‹').fontSize(34).fontWeight(900).fontColor(INK).textAlign(TextAlign.Center)
          }.width(44).height(44).padding(0).backgroundColor('#00000000')
            .margin({ left: -10 }).enabled(!this.busy).accessibilityText('返回我的作品')
            .onClick(() => router.back())
          Blank()
          Text('同拍').fontSize(16).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK)
        }.width('100%').height(44).margin({ top: this.topSafeInset + SAVED_HEADER_TOP })
        Scroll() {
          Column() {
            Row({ space: 12 }) {
              Text('已保存到相册').fontSize(28).minFontSize(22).maxFontSize(28).maxLines(1)
                .fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK)
              Image($rawfile('comic/icons/saved_check.svg')).width(28).height(28).objectFit(ImageFit.Contain)
                .accessibilityLevel('no')
            }.width('100%').height(SAVED_TITLE_HEIGHT)
              .margin({ top: SAVED_TITLE_TOP, bottom: SAVED_TICKET_TOP_GAP })
            this.ticket()
            Text(this.canCheckInToday ? '分享已交接，发布后点“去打卡”确认。' : '把这一拍，分享给同频的人。')
              .fontSize(12).fontColor('#817C73').textAlign(TextAlign.Center).maxLines(2).lineHeight(20)
              .width('100%').height(40).margin({ top: SAVED_CAPTION_TOP })
          }.width('100%').constraintSize({ maxWidth: SAVED_TICKET_MAX_WIDTH })
            .padding({ right: SAVED_TICKET_SHADOW_X + 1, bottom: 10 })
        }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
          .onAreaChange((_previous: Area, area: Area) => {
            const height = Number(area.height);
            if (height > 0 && Math.abs(height - this.bodyHeight) > 0.1) { this.bodyHeight = height; }
          })
      }.width('100%').height('100%').padding({ left: SAVED_PAGE_SIDE_INSET, right: SAVED_PAGE_SIDE_INSET,
        bottom: this.bottomSafeInset + SAVED_PAGE_BOTTOM }).backgroundColor(PAPER)
      if (this.pauseConfirmVisible) { this.pauseConfirm() }
      if (this.calendarVisible) {
        ShareCalendarSheet({
          scope: this.savedClip?.scope ?? this.recordingScope,
          bottomInset: this.bottomSafeInset,
          onClose: (): void => { this.calendarVisible = false; }
        })
      }
    }.width('100%').height('100%').backgroundColor(PAPER)
  }
}
