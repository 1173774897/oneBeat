import { PathShape } from '@kit.ArkUI';
import { INK, WHITE } from './ComicKit';

export const TEAM_TICKET_SHADOW_X: number = 4;
export const TEAM_TICKET_SHADOW_Y: number = 5;
const TICKET_CORNER: number = 9;
const TICKET_NOTCH: number = 8;
const TICKET_HALFTONE_SCALE: number = 1;
const CAPTAIN_HALFTONE_TOP_X: number = -16;
const CAPTAIN_HALFTONE_TOP_Y: number = 25;
const MEMBER_HALFTONE_TOP_Y: number = 72;
const CAPTAIN_HALFTONE_COLOR: string = '#FFC1AF';
const MEMBER_HALFTONE_COLOR: string = '#D7C5F2';

/** Static decoration only: the page owns all content and its single tap target. */
@Component
export struct TeamTicketBackdrop {
  @Prop ticketHeight: number = 400;
  @Prop firstNotchY: number = 52;
  @Prop tearY: number = 338;
  @Prop fill: string = WHITE;
  /** Optional printed artwork, clipped by the same contour as the ticket face. */
  @Prop halftone: string = '';
  @State private measuredWidth: number = 160;

  private ticketOutline(): string {
    // Path coordinates are physical pixels; measured layout and tuning values
    // are vp. Convert together so notches stay attached on both screen densities.
    const l = vp2px(1);
    const r = vp2px(Math.max(30, this.measuredWidth - 1));
    const b = vp2px(this.ticketHeight - 1);
    const c = vp2px(TICKET_CORNER);
    const n = vp2px(TICKET_NOTCH);
    const upper = vp2px(this.firstNotchY);
    const tear = vp2px(this.tearY);
    return `M ${l + c} ${l} H ${r - c} L ${r} ${l + c} V ${upper - n}` +
      ` A ${n} ${n} 0 0 0 ${r} ${upper + n} V ${tear - n}` +
      ` A ${n} ${n} 0 0 0 ${r} ${tear + n} V ${b - c} L ${r - c} ${b}` +
      ` H ${l + c} L ${l} ${b - c} V ${tear + n}` +
      ` A ${n} ${n} 0 0 0 ${l} ${tear - n} V ${upper + n}` +
      ` A ${n} ${n} 0 0 0 ${l} ${upper - n} V ${l + c} Z`;
  }

  @Builder
  private printedHalftone() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.halftone === 'captain') {
        Image($rawfile('comic/decor/ticket-halftone-ink.svg'))
          .fillColor(CAPTAIN_HALFTONE_COLOR)
          .width(72 * TICKET_HALFTONE_SCALE).height(126 * TICKET_HALFTONE_SCALE)
          .position({ x: CAPTAIN_HALFTONE_TOP_X, y: CAPTAIN_HALFTONE_TOP_Y })
        Image($rawfile('comic/decor/ticket-halftone-ink-corner.svg'))
          .fillColor(CAPTAIN_HALFTONE_COLOR)
          .width(100 * TICKET_HALFTONE_SCALE).height(122 * TICKET_HALFTONE_SCALE)
          .scale({ x: -1, y: 1 })
          .position({ x: this.measuredWidth - 92 * TICKET_HALFTONE_SCALE, y: this.tearY - 137 })
      } else if (this.halftone === 'member') {
        Image($rawfile('comic/decor/ticket-halftone-lilac.svg'))
          .fillColor(MEMBER_HALFTONE_COLOR)
          .width(96 * TICKET_HALFTONE_SCALE).height(168 * TICKET_HALFTONE_SCALE)
          .position({ x: this.measuredWidth - 90 * TICKET_HALFTONE_SCALE, y: MEMBER_HALFTONE_TOP_Y })
        Image($rawfile('comic/decor/ticket-halftone-ink-corner.svg'))
          .fillColor(MEMBER_HALFTONE_COLOR)
          .width(70 * TICKET_HALFTONE_SCALE).height(85.6 * TICKET_HALFTONE_SCALE)
          .position({ x: 0, y: this.tearY - 108 })
      } else if (this.halftone === 'join') {
        Image($rawfile('comic/decor/ticket-halftone-lilac.svg'))
          .fillColor(MEMBER_HALFTONE_COLOR)
          .width(70 * TICKET_HALFTONE_SCALE).height(122.5 * TICKET_HALFTONE_SCALE)
          .position({ x: this.measuredWidth - 62 * TICKET_HALFTONE_SCALE, y: this.tearY - 55 })
        Image($rawfile('comic/decor/ticket-halftone-lilac-corner.svg'))
          .fillColor(MEMBER_HALFTONE_COLOR)
          .width(82 * TICKET_HALFTONE_SCALE).height(100 * TICKET_HALFTONE_SCALE)
          .position({ x: -6, y: this.ticketHeight - 100 })
      }
    }.width('100%').height(this.ticketHeight)
      // Dot patches can reach the paper edge without filling the notches or
      // spilling onto the hard shadow; the contour remains the single authority.
      .clipShape(new PathShape({ commands: this.ticketOutline() }))
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Path().commands(this.ticketOutline()).width('100%').height(this.ticketHeight).fill(INK)
        .translate({ x: TEAM_TICKET_SHADOW_X, y: TEAM_TICKET_SHADOW_Y })
      Path().commands(this.ticketOutline()).width('100%').height(this.ticketHeight)
        .fill(this.fill)
      if (this.halftone.length > 0) {
        this.printedHalftone()
      }
      Path().commands(this.ticketOutline()).width('100%').height(this.ticketHeight)
        .fill('#00000000').stroke(INK).strokeWidth(1.8)
      Path().commands(`M ${vp2px(13)} ${vp2px(this.tearY)} H ${vp2px(this.measuredWidth - 13)}`)
        .width('100%').height(this.ticketHeight).stroke(INK).strokeWidth(1.2).strokeDashArray([2.5, 4])
    }.width('100%').height(this.ticketHeight).clip(false)
      .onAreaChange((_old: Area, area: Area) => {
        const width = Number(area.width);
        if (width > 0 && Math.abs(width - this.measuredWidth) > 0.1) { this.measuredWidth = width; }
      })
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
  }
}

@Component
export struct TeamWifiFooter {
  build() {
    Row({ space: 10 }) {
      Row({ space: 5 }) {
        Image($rawfile('comic/icons/ticket-wifi.svg')).width(22).height(19).objectFit(ImageFit.Contain)
          .accessibilityLevel('no')
        Text('Wi-Fi 直连').fontSize(11).fontWeight(900).fontColor(INK).maxLines(1)
      }.padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .border({ width: 1, color: INK }).borderRadius(18)
      Text('无需连接同一个路由器').fontSize(10).minFontSize(8).maxFontSize(10)
        .fontColor('#8B8B8F').fontWeight(FontWeight.Bold).maxLines(1)
    }.width('100%').height(28).justifyContent(FlexAlign.Center)
      .hitTestBehavior(HitTestMode.None)
  }
}
