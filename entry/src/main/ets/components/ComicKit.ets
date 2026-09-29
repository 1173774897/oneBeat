import { rosterKeysForLobby } from '../assets/CharacterCatalog';

export const PAPER: string = '#FFF9EE';
export const INK: string = '#171B1F';
export const CORAL: string = '#FF7056';
export const LILAC: string = '#C5B7EB';
export const TEAL: string = '#29B5AE';

export function lobbyAvatars(soloTeam: boolean): string[] {
  return rosterKeysForLobby(soloTeam);
}

export function avatarDisplayName(key: string): string {
  if (key === 'matchman') { return '火柴人'; }
  if (key === 'mismatch') { return '条纹步客'; }
  if (key === 'cloud') { return '云行者'; }
  if (key === 'lilroll') { return 'Lilroll'; }
  if (key === 'teapot') { return '茶壶太太'; }
  if (key === 'wave') { return 'Wave'; }
  if (key === 'scooter') { return '滑板车'; }
  return key;
}

@Component
export struct ComicCharacter {
  @Prop avatar: string = 'matchman';
  @Prop portrait: boolean = false;
  build() {
    Image($rawfile(`comic/${this.portrait ? 'avatars' : 'characters'}/${this.avatar}.png`))
      .width('100%').height('100%').objectFit(ImageFit.Contain)
  }
}

@Component
export struct ComicButton {
  @Prop label: string = '';
  @Prop fill: string = CORAL;
  @Prop active: boolean = true;
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
      .shadow({ radius: 0, offsetX: 2, offsetY: 3, color: INK })
      .enabled(this.active).opacity(this.active ? 1 : 0.5).onClick(this.action)
  }
}
