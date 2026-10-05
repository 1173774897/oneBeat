import { isRandomPoolCharacter } from '../assets/CharacterCatalog';

const RANDOM_POOL_LAYOUT_SIZE: number = 140;
const RANDOM_POOL_SCALE: number = 0.9;
const RANDOM_POOL_SPRITE_SIZE: number = RANDOM_POOL_LAYOUT_SIZE * RANDOM_POOL_SCALE;

@Component
export struct RandomPoolWalkerLayers {
  @Prop frameIndex: number = 0;
  @Prop avatar: string = 'braids';
  @Prop colorSlot: number = 0;

  @Builder
  private frameImage(path: string, index: number) {
    Image($rawfile(path))
      .width(RANDOM_POOL_SPRITE_SIZE)
      .height(RANDOM_POOL_SPRITE_SIZE)
      .objectFit(ImageFit.Contain)
      .visibility(this.frameIndex === index ? Visibility.Visible : Visibility.Hidden);
  }

  @Builder
  private paletteFrames(prefix: string) {
    Stack({ alignContent: Alignment.Bottom }) {
      this.frameImage(`${prefix}/frame_01.png`, 0);
      this.frameImage(`${prefix}/frame_02.png`, 1);
      this.frameImage(`${prefix}/frame_03.png`, 2);
      this.frameImage(`${prefix}/frame_04.png`, 3);
      this.frameImage(`${prefix}/frame_05.png`, 4);
      this.frameImage(`${prefix}/frame_06.png`, 5);
      this.frameImage(`${prefix}/frame_07.png`, 6);
      this.frameImage(`${prefix}/frame_08.png`, 7);
    }
    .width(RANDOM_POOL_LAYOUT_SIZE)
    .height(RANDOM_POOL_LAYOUT_SIZE);
  }

  build() {
    this.paletteFrames(
      `walk/${isRandomPoolCharacter(this.avatar) ? this.avatar : 'braids'}/palette_${this.colorSlot === 1 ? 2 : 1}`
    );
  }
}
