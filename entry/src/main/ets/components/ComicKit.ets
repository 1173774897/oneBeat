import { isRandomAvatar, isRandomPoolCharacter, rosterKeysForLobby } from '../assets/CharacterCatalog';

export const PAPER: string = '#FFF9EE';
export const INK: string = '#171B1F';
export const CORAL: string = '#FF7056';
export const LILAC: string = '#C5B7EB';
export const TEAL: string = '#29B5AE';
export const WHITE: string = '#FFFDF8';
export const BLUE: string = '#A9C9F2';
// Keep ink-shadow styling independent of legacy page geometry and corner radii.
export const CARD_SHADOW: ShadowOptions = { radius: 0, offsetX: 3, offsetY: 4, color: INK };
export const CONTROL_SHADOW: ShadowOptions = { radius: 0, offsetX: 2, offsetY: 2, color: INK };

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
  // Only pass a controller-confirmed lobby silhouette here, never a color slot.
  @Prop mysteryAvatar: string = '';
  // Pose artwork is only for static editorial scenes; walking sprites and
  // portraits retain their original assets and animation/selection contracts.
  @Prop pose: string = '';
  build() {
    if (this.avatar === 'random') {
      if (isRandomPoolCharacter(this.mysteryAvatar)) {
        Image($rawfile(`comic/mystery/${this.mysteryAvatar}.png`))
          .width('100%').height('100%').objectFit(ImageFit.Contain)
      } else {
        Stack() {
          Text('?').fontSize(this.portrait ? 34 : 92).fontWeight(900).fontColor(INK)
            .width('100%').height('100%').textAlign(TextAlign.Center)
        }.width('100%').height('100%')
      }
    } else {
      Image($rawfile(this.portrait ? `comic/avatars/${this.avatar}.png` :
        this.pose.length > 0 ? `comic/poses/${this.pose}.png` : `comic/characters/${this.avatar}.png`))
        .width('100%').height('100%').objectFit(ImageFit.Contain)
    }
  }
}

@Component
export struct ComicButton {
  @Prop label: string = '';
  @Prop fill: string = CORAL;
  @Prop active: boolean = true;
  // The home page keeps its original shadow while other pages use the shared style.
  @Prop inkShadow: ShadowOptions = CARD_SHADOW;
  action: () => void = () => {};
  build() {
    Button({ type: ButtonType.Normal }) {
      Row() {
        Text(this.label).fontSize(22).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK)
        Blank()
        Text('›').fontSize(30).fontColor(INK)
      }.width('100%').padding({ left: 16, right: 14 })
    }.width('100%').height(56).backgroundColor(this.fill)
      .border({ width: 1.5, color: INK }).borderRadius(7)
      .shadow(this.inkShadow)
      .enabled(this.active).opacity(this.active ? 1 : 0.5).onClick(this.action)
  }
}
