import { getShareCheckInSummary, ShareCheckInDay } from '../store/ShareCheckInStore';
import { formatTrialExpiry, resolveDrumAccess } from '../store/EntitlementStore';
import { CARD_SHADOW, CONTROL_SHADOW, CORAL, INK, LILAC, PAPER, WHITE } from './ComicKit';

const SHARE_CALENDAR_SIDE_INSET: number = 18;
const SHARE_CALENDAR_BOTTOM: number = 28;
const SHARE_CALENDAR_HEIGHT: number = 640;
const SHARE_CALENDAR_MAX_HEIGHT: string = '88%';
const SHARE_CALENDAR_CELL_HEIGHT: number = 37;
const SHARE_CALENDAR_CELL_GAP: number = 3;
const SHARE_CALENDAR_INFO_SIZE: number = 18;
const SHARE_CALENDAR_SECTION_HEIGHT: number = 32;
const SHARE_CALENDAR_WEEKDAYS: string[] = ['一', '二', '三', '四', '五', '六', '日'];
const BEIJING_OFFSET_MS: number = 8 * 3600000;

interface ShareCalendarCell {
  key: string;
  day: number;
  dayKey: string;
  completed: boolean;
  rewarded: boolean;
}

/** The activity ledger is per install; solo/team only describes the calling work list. */
@Component
export struct ShareCalendarSheet {
  @Prop bottomInset: number = 0;
  @Prop scope: string = 'all';
  @Prop showShareAction: boolean = false;
  @Prop showStoreAction: boolean = false;
  onClose: () => void = () => {};
  onShare: () => void = () => {};
  onOpenStore: () => void = () => {};
  @StorageLink('shareCheckInEpoch') @Watch('refresh') checkInEpoch: number = 0;
  @StorageLink('storeEntitlementEpoch') @Watch('refreshAccess') entitlementEpoch: number = 0;
  @State tab: number = 0;
  @State history: ShareCheckInDay[] = [];
  @State cells: ShareCalendarCell[] = [];
  @State streakDays: number = 0;
  @State todayCompleted: boolean = false;
  @State clockBlocked: boolean = false;
  @State ledgerReady: boolean = false;
  @State accessSource: string = 'locked';
  @State accessExpiresAt: number = 0;
  @State monthOffset: number = 0;
  @State monthTitle: string = '';
  @State selectedDayKey: string = '';
  @State calendarRows: number = 5;

  aboutToAppear(): void {
    this.selectedDayKey = this.todayKey();
    this.refresh();
  }

  refresh(): void {
    const summary = getShareCheckInSummary();
    this.history = summary.history;
    this.streakDays = summary.streakDays;
    this.todayCompleted = summary.todayCompleted;
    this.clockBlocked = summary.clockBlocked;
    this.ledgerReady = summary.ready;
    this.refreshAccess();
    this.rebuildCalendar();
  }

  private refreshAccess(): void {
    const access = resolveDrumAccess();
    this.accessSource = access.source;
    this.accessExpiresAt = access.expiresAt;
  }

  private todayKey(): string {
    return new Date(Date.now() + BEIJING_OFFSET_MS).toISOString().substring(0, 10);
  }

  private rebuildCalendar(): void {
    const today = new Date(Date.now() + BEIJING_OFFSET_MS);
    const first = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth() + this.monthOffset, 1));
    const year = first.getUTCFullYear();
    const month = first.getUTCMonth();
    const leading = (first.getUTCDay() + 6) % 7;
    const dayCount = new Date(Date.UTC(year, month + 1, 0)).getUTCDate();
    this.calendarRows = Math.ceil((leading + dayCount) / 7);
    this.monthTitle = `${year} 年 ${month + 1} 月`;
    const entries: Map<string, ShareCheckInDay> = new Map();
    for (const entry of this.history) {
      entries.set(entry.dayKey, entry);
    }
    const cells: ShareCalendarCell[] = [];
    for (let index = 0; index < this.calendarRows * 7; index++) {
      const day = index - leading + 1;
      if (day < 1 || day > dayCount) {
        cells.push({ key: `blank-${index}`, day: 0, dayKey: '', completed: false, rewarded: false });
      } else {
        const key = `${year}-${(month + 1).toString().padStart(2, '0')}-${day.toString().padStart(2, '0')}`;
        const record = entries.get(key);
        cells.push({ key, day, dayKey: key, completed: record !== undefined, rewarded: record?.rewardGranted ?? false });
      }
    }
    this.cells = cells;
  }

  private moveMonth(delta: number): void {
    if (this.monthOffset + delta > 0) {
      return;
    }
    this.monthOffset += delta;
    this.rebuildCalendar();
  }

  private accessLabel(): string {
    if (this.accessSource === 'trial') {
      return `试用中 · 截止 ${formatTrialExpiry(this.accessExpiresAt)}`;
    }
    if (this.accessSource === 'monthly') {
      return '月卡已解锁 · 分享继续记卡';
    }
    if (this.accessSource === 'owned') {
      return '鼓机已解锁 · 分享继续记卡';
    }
    return '连续分享 3 天起，每天可领 24 小时鼓机试用';
  }

  private showsTrialRewards(): boolean {
    // Membership changes presentation only: keep historical rewards in the ledger
    // so they reappear unchanged if the user's monthly pass later expires.
    return this.accessSource !== 'monthly';
  }

  private ruleLines(): string[] {
    const lines: string[] = [
      '① 录下行进视频并发布至任一分享平台，返回票根页点击“去打卡”确认后完成打卡。打开分享面板或保存到相册不会自动记卡。'
    ];
    if (!this.showsTrialRewards()) {
      lines.push('② 按北京时间自然日记录，每天确认一次。连续分享会累计打卡天数，中断后重新累计。');
      lines.push('③ 月卡权益生效中，可直接使用定制鼓机。分享用于记录练习，和同频的人留下这一拍。');
      lines.push('④ 今日完成打卡后，分享按钮恢复整行，当天不再显示“去打卡”。');
      lines.push('⑤ 记录保存在本机，换设备、卸载或清除数据后不恢复。');
    } else {
      lines.push('② 按北京时间自然日计，连续第 3、4、5…天，每天首次符合条件的分享赠送 24 小时试用；一天可多次分享，只领一次。');
      lines.push('③ 截止为确认时刻起 24 小时，时长不累加。漏一天重新累计，已领试用仍按原截止有效。');
      lines.push('④ 月卡有效时照常打卡，不赠试用；今日完成打卡后，分享按钮恢复整行，当天不再显示“去打卡”，不补发历史奖励。');
      lines.push('⑤ 到期不影响正在进行的本轮播放；下一次启动、恢复、试听或应用鼓机时需有效权益。记录保存在本机，换设备、卸载或清除数据后不恢复。');
    }
    return lines;
  }

  private selectedDetail(): string {
    const record = this.history.find((day: ShareCheckInDay) => day.dayKey === this.selectedDayKey);
    if (record === undefined) {
      return '这天还没有分享打卡';
    }
    const outcome = this.showsTrialRewards() && record.rewardGranted ?
      `已领 24h · 截止 ${formatTrialExpiry(record.trialExpiresAt)}` : '已完成打卡';
    return `连续第 ${record.streakOrdinal} 天 · 分享 ${record.shareCount} 次\n${outcome}`;
  }

  private scopeLabel(): string {
    if (this.scope === 'solo') {
      return '当前单人作品 · 单人与队伍共用打卡记录';
    }
    if (this.scope === 'team') {
      return '当前队伍作品 · 单人与队伍共用打卡记录';
    }
    return '单人与队伍作品，共用本机这份连续分享记录';
  }

  @Builder
  private calendar() {
    Column({ space: 8 }) {
      Row() {
        Text('‹').fontSize(28).fontWeight(900).width(32).textAlign(TextAlign.Center)
          .onClick(() => this.moveMonth(-1))
        Blank()
        Text(this.monthTitle).fontSize(15).fontWeight(900).fontColor(INK)
        Blank()
        Text('›').fontSize(28).fontWeight(900).width(32).textAlign(TextAlign.Center)
          .opacity(this.monthOffset < 0 ? 1 : 0.25).enabled(this.monthOffset < 0)
          .onClick(() => this.moveMonth(1))
      }.width('100%')
      Row() {
        ForEach(SHARE_CALENDAR_WEEKDAYS, (label: string) => {
          Text(label).layoutWeight(1).textAlign(TextAlign.Center).fontSize(10).fontWeight(FontWeight.Bold).fontColor('#777064')
        }, (label: string) => label)
      }.width('100%')
      Grid() {
        ForEach(this.cells, (cell: ShareCalendarCell) => {
          GridItem() {
            if (cell.day > 0) {
              Column({ space: 0 }) {
                Text(`${cell.day}`).fontSize(12).fontWeight(cell.completed ? 900 : FontWeight.Normal).fontColor(INK)
                Text(cell.rewarded && this.showsTrialRewards() ? '★' : (cell.completed ? '●' : ' ')).fontSize(8).fontWeight(900).fontColor('#7860A4')
              }.width('100%').height(SHARE_CALENDAR_CELL_HEIGHT).justifyContent(FlexAlign.Center)
                .backgroundColor(cell.rewarded && this.showsTrialRewards() ? LILAC : (cell.completed ? '#E5F3EA' : WHITE))
                .border({ width: this.selectedDayKey === cell.dayKey ? 2 : 1,
                  color: this.selectedDayKey === cell.dayKey ? INK : (cell.dayKey === this.todayKey() ? CORAL : '#DDD5C9') })
                .borderRadius(5).onClick(() => { this.selectedDayKey = cell.dayKey; })
            }
          }
        }, (cell: ShareCalendarCell) => cell.key)
      }.columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr')
        .columnsGap(SHARE_CALENDAR_CELL_GAP).rowsGap(SHARE_CALENDAR_CELL_GAP)
        .height(this.calendarRows * SHARE_CALENDAR_CELL_HEIGHT + (this.calendarRows - 1) * SHARE_CALENDAR_CELL_GAP)
        .width('100%').scrollBar(BarState.Off)
      Row({ space: 12 }) {
        Text('● 已打卡').fontSize(9).fontColor('#467A70')
        if (this.showsTrialRewards()) {
          Text('★ 已领试用').fontSize(9).fontColor('#7860A4')
        }
        Text('红框为今日').fontSize(9).fontColor('#A45D45')
      }.width('100%')
      Column({ space: 4 }) {
        Text(this.selectedDayKey).fontSize(12).fontWeight(900).fontColor(INK).width('100%')
        Text(this.selectedDetail()).fontSize(11).fontColor('#5D574F').lineHeight(18).width('100%')
      }.width('100%').padding(10).backgroundColor(PAPER).borderRadius(5)
      Text(this.scopeLabel()).fontSize(9).fontColor('#777064').width('100%')
    }.width('100%')
  }

  @Builder
  private rules() {
    Column({ space: 10 }) {
      ForEach(this.ruleLines(), (line: string) => {
        Text(line).fontSize(12).fontColor('#5D574F').lineHeight(19).width('100%')
      }, (line: string) => line)
    }.width('100%')
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column().width('100%').height('100%').backgroundColor('#400F0D09').onClick(() => this.onClose())
      Column({ space: 11 }) {
        Row() {
          Text('打卡日历').fontSize(22).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK)
          Blank()
          Text('×').fontSize(25).fontWeight(FontWeight.Bold).fontColor(INK).width(32).height(32)
            .textAlign(TextAlign.Center).onClick(() => this.onClose())
        }.width('100%')
        Text() {
          Span(`${this.accessLabel()} `)
          ImageSpan($rawfile('comic/icons/info.svg')).width(SHARE_CALENDAR_INFO_SIZE).height(SHARE_CALENDAR_INFO_SIZE)
            .verticalAlign(ImageSpanAlignment.CENTER)
        }.fontSize(12).fontWeight(900).fontColor('#61566F').lineHeight(23).width('100%')
          .accessibilityText(`${this.accessLabel()}，查看玩法说明`).onClick(() => { this.tab = 1; })
        Text(`已连续 ${this.streakDays} 天 · ${this.todayCompleted ? '今日已打卡' : '今日待打卡'}`)
          .fontSize(13).fontWeight(900).fontColor(INK).width('100%')
        if (!this.ledgerReady || this.clockBlocked) {
          Text(this.clockBlocked ? '设备时间发生回拨，请恢复自动时间后再打卡。已有记录会保留。' : '本机记录正在恢复，请稍后重试。')
            .fontSize(11).fontColor('#A34530').lineHeight(18).width('100%')
        }
        Row() {
          Text(this.tab === 0 ? '打卡记录' : '玩法说明').fontSize(13).fontWeight(900).fontColor(INK)
          Blank()
          if (this.tab === 1) {
            Button('‹ 返回日历', { type: ButtonType.Normal }).width(94).height(SHARE_CALENDAR_SECTION_HEIGHT)
              .padding({ left: 8, right: 8 }).fontSize(12).fontWeight(900).fontColor(INK)
              .backgroundColor(PAPER).border({ width: 1, color: INK }).borderRadius(4)
              .onClick(() => { this.tab = 0; })
          }
        }.width('100%').height(SHARE_CALENDAR_SECTION_HEIGHT)
        // Keep the shell and controls stationary; only the active tab scrolls on short screens.
        // Separate scroll nodes also open each tab at its own beginning instead of reusing an old offset.
        if (this.tab === 0) {
          Scroll() {
            this.calendar()
          }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
        } else {
          Scroll() {
            this.rules()
          }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
        }
        if (this.showShareAction) {
          Button('去分享作品', { type: ButtonType.Normal }).width('100%').height(42).fontSize(13).fontWeight(900).fontColor(INK)
            .backgroundColor(LILAC).border({ width: 1, color: INK }).borderRadius(5).shadow(CONTROL_SHADOW)
            .onClick(() => this.onShare())
        }
        if (this.showStoreAction && this.accessSource === 'locked') {
          Text('畅游月卡也可直接解锁 ›').fontSize(12).fontWeight(FontWeight.Bold).fontColor('#61566F')
            .onClick(() => this.onOpenStore())
        }
      }.width(`calc(100% - ${SHARE_CALENDAR_SIDE_INSET * 2}vp)`)
        .height(SHARE_CALENDAR_HEIGHT).constraintSize({ maxHeight: SHARE_CALENDAR_MAX_HEIGHT }).padding(16)
        .backgroundColor('#FFF9EC').border({ width: 1.5, color: INK }).borderRadius(10).shadow(CARD_SHADOW)
        .margin({ bottom: SHARE_CALENDAR_BOTTOM + this.bottomInset })
    }.width('100%').height('100%').zIndex(120)
  }
}
