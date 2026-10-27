import { ActionButton } from './ActionButton';
import { isRandomAvatar, isRandomPoolCharacter, rosterKeysForLobby } from '../assets/CharacterCatalog';

export const PAPER: string = '#FFF9EE';
export const INK: string = '#171B1F';
export const CORAL: string = '#FF7056';
export const LILAC: string = '#C5B7EB';
export const TEAL: string = '#29B5AE';
export const WHITE: string = '#FFFDF8';
export const BLUE: string = '#A9C9F2';
const COMIC_BUTTON_HEIGHT: number = 56;
const COMIC_BUTTON_RADIUS: number = 7;
// Supported older ArkUI runtimes suppress component shadows when radius is zero.
// A 1px blur keeps near-hard ink edges without changing layout; textShadow is separate.
export const INK_SHADOW_RADIUS: number = 1;
// Keep ink-shadow styling independent of legacy page geometry and corner radii.
export const CARD_SHADOW: ShadowOptions = { radius: INK_SHADOW_RADIUS, offsetX: 3, offsetY: 4, color: INK };
export const CONTROL_SHADOW: ShadowOptions = { radius: INK_SHADOW_RADIUS, offsetX: 2, offsetY: 2, color: INK };

/** Solid ink backing with numeric vp offsets, independent of native shadow blur. */
export interface ComicHardShadowOptions {
  offsetX: number;
  offsetY: number;
  color: string;
}

export function lobbyAvatars(soloTeam: boolean): string[] {
  return rosterKeysForLobby(soloTeam);
}

export function avatarDisplayName(key: string): string {
  if (key === 'random') { return '随机角色'; }
  if (key === 'lamp' || key === 'matchman') { return '台灯漫游者'; }
  if (key === 'mismatch') { return '条纹步客'; }
  if (key === 'cloud') { return '云行者'; }
  if (key === 'lilroll') { return 'Lilroll'; }
  if (key === 'teapot') { return '茶壶太太'; }
  if (key === 'wave') { return 'Wave'; }
  if (key === 'scooter') { return '思古特'; }
  return key;
}

export function revealedAvatarAsset(
  avatarKey: string,
  resolvedAvatarKey: string = '',
  colorSlot: number = 0
): string {
  if (isRandomAvatar(avatarKey) && isRandomPoolCharacter(resolvedAvatarKey)) {
    const palette = colorSlot === 1 ? 2 : 1;
    return `${resolvedAvatarKey}_palette_${palette}`;
  }
  return avatarKey === 'matchman' ? 'lamp' : avatarKey;
}

@Component
export struct ComicCharacter {
  @Prop avatar: string = 'lamp';
  @Prop portrait: boolean = false;
  // Interactive roster slots own their long-press sorting. Those callers must
  // disable native Image dragging without changing artwork elsewhere.
  @Prop allowNativeDrag: boolean = true;
  // Only pass a controller-confirmed lobby silhouette here, never a color slot.
  @Prop mysteryAvatar: string = '';
  // Pose artwork is only for static editorial scenes; walking sprites and
  // portraits retain their original assets and animation/selection contracts.
  @Prop pose: string = '';
  @Prop objectFit: ImageFit = ImageFit.Contain;
  build() {
    if (this.avatar === 'random') {
      if (isRandomPoolCharacter(this.mysteryAvatar)) {
        Image($rawfile(`comic/mystery/${this.mysteryAvatar}.png`))
          .width('100%').height('100%').objectFit(this.objectFit)
          .draggable(this.allowNativeDrag)
      } else {
        Stack() {
          Text('?').fontSize(this.portrait ? 34 : 92).fontWeight(900).fontColor(INK)
            .width('100%').height('100%').textAlign(TextAlign.Center)
        }.width('100%').height('100%')
      }
    } else {
      Image($rawfile(this.portrait ? `comic/avatars/${this.avatar}.png` :
        this.pose.length > 0 ? `comic/poses/${this.pose}.png` : `comic/characters/${this.avatar}.png`))
        .width('100%').height('100%').objectFit(this.objectFit)
        .draggable(this.allowNativeDrag)
    }
  }
}

@Component
export struct ComicButton {
  @Prop label: string = '';
  @Prop fill: string = CORAL;
  @Prop active: boolean = true;
  @Prop badgeLabel: string = '';
  @Prop badgeIcon: string = '';
  @Prop badgeFill: string = PAPER;
  // Existing pages retain native shadow rendering unless a solid backing is supplied.
  @Prop inkShadow: ShadowOptions = CARD_SHADOW;
  @Prop hardShadow: ComicHardShadowOptions | undefined = undefined;
  action: () => void = () => {};

  build() {
    ActionButton({
      label: this.label, active: this.active, fill: this.fill,
      controlHeight: COMIC_BUTTON_HEIGHT, cornerRadius: COMIC_BUTTON_RADIUS,
      lineWidth: 1.5, lineColor: INK, contentPadding: { left: 16, right: 14 },
      hardShadow: this.hardShadow, inkShadow: this.inkShadow,
      accessibilityLabel: this.badgeLabel.length > 0 && this.badgeIcon.length > 0 ?
        `${this.label}，${this.badgeLabel}` : this.label,
      action: () => this.action()
    }) {
      Row() {
        Text(this.label).fontSize(22).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK)
        Blank()
        if (this.badgeLabel.length > 0 && this.badgeIcon.length > 0) {
          Row({ space: 5 }) {
            Image($rawfile(this.badgeIcon)).width(22).height(22).objectFit(ImageFit.Contain)
            Text(this.badgeLabel).fontSize(9).fontWeight(900).fontColor(INK).letterSpacing(0.7)
          }
          .width(92).height(30).justifyContent(FlexAlign.Center)
          .backgroundColor(this.badgeFill).border({ width: 1.2, color: INK }).borderRadius(4)
          .rotate({ angle: -2 }).margin({ right: 9 })
        }
        Text('›').fontSize(30).fontColor(INK)
      }.width('100%').alignItems(VerticalAlign.Center)
    }
  }
}
