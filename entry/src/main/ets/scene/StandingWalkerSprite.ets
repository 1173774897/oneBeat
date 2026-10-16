import { standFramePath, WalkerAvatarKey } from '../assets/AssetCatalog';
import { isRandomPoolCharacter } from '../assets/CharacterCatalog';

const STANDING_LAYOUT_SIZE: number = 140;
const STANDING_SMALL_SCALE: number = 0.7;
const STANDING_WAVE_SCALE: number = 0.85;
const STANDING_RANDOM_SCALE: number = 0.9;

@Component
export struct StandingWalkerSprite {
  @Prop avatar: WalkerAvatarKey = 'cloud';
  @Prop colorSlot: number = 0;

  private spriteSize(): number {
    // Keep the existing walk layout contract when switching to a standing asset.
    if (this.avatar === 'cloud' || this.avatar === 'teapot' || this.avatar === 'lamp') {
      return STANDING_LAYOUT_SIZE * STANDING_SMALL_SCALE;
    }
    if (this.avatar === 'wave') {
      return STANDING_LAYOUT_SIZE * STANDING_WAVE_SCALE;
    }
    if (isRandomPoolCharacter(this.avatar)) {
      return STANDING_LAYOUT_SIZE * STANDING_RANDOM_SCALE;
    }
    return STANDING_LAYOUT_SIZE;
  }

  build() {
    Stack({ alignContent: this.avatar === 'mismatch' ? Alignment.Center : Alignment.Bottom }) {
      Image($rawfile(standFramePath(this.avatar, this.colorSlot)))
        .width(this.spriteSize())
        .height(this.spriteSize())
        .objectFit(ImageFit.Contain)
    }
    .width(STANDING_LAYOUT_SIZE)
    .height(STANDING_LAYOUT_SIZE)
  }
}
