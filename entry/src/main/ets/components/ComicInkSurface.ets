import { INK } from './ComicKit';

export const COMIC_CARD_INK_OFFSET: number = 4;
export const COMIC_CONTROL_INK_OFFSET: number = 2;

/**
 * Paint inside a host's custom background with clipping disabled on that host.
 * Native radius-zero shadows disappear on some supported devices. The matching
 * face covers this solid backing; neither layer changes layout or receives taps.
 * Keep image cropping on an inner frame so it cannot crop the offset ink layer.
 * Do not combine this builder with backgroundColor/border on the same host; wrap an
 * inner face instead, or use DrumPaper when the backing must track measured bounds.
 */
@Builder
export function comicInkSurface(
  fill: string,
  cornerRadius: number = 7,
  inkOffset: number = COMIC_CARD_INK_OFFSET
) {
  Stack({ alignContent: Alignment.TopStart }) {
    Rect().width('100%').height('100%').radius(cornerRadius).fill(INK)
      .translate({ x: inkOffset, y: inkOffset })
    Rect().width('100%').height('100%').radius(cornerRadius).fill(fill)
  }.width('100%').height('100%').clip(false)
    .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
}
