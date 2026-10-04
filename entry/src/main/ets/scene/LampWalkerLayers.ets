/** 与 WalkerSprite 中 cloud 相同缩放（0.7 × 140） */
const LAMP_SCALE: number = 0.7;
const LAMP_LAYOUT_SIZE: number = 140;
const LAMP_SPRITE_SIZE: number = LAMP_LAYOUT_SIZE * LAMP_SCALE;

@Component
export struct LampWalkerLayers {
  @Prop frameIndex: number = 0;

  @Builder
  private frameImage(path: string, index: number) {
    Image($rawfile(path))
      .width(LAMP_SPRITE_SIZE)
      .height(LAMP_SPRITE_SIZE)
      .objectFit(ImageFit.Contain)
      .visibility(this.frameIndex === index ? Visibility.Visible : Visibility.Hidden);
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      this.frameImage('walk/lamp/frame_01.png', 0);
      this.frameImage('walk/lamp/frame_02.png', 1);
      this.frameImage('walk/lamp/frame_03.png', 2);
      this.frameImage('walk/lamp/frame_04.png', 3);
      this.frameImage('walk/lamp/frame_05.png', 4);
      this.frameImage('walk/lamp/frame_06.png', 5);
      this.frameImage('walk/lamp/frame_07.png', 6);
      this.frameImage('walk/lamp/frame_08.png', 7);
    }
    .width(LAMP_LAYOUT_SIZE)
    .height(LAMP_LAYOUT_SIZE);
  }
}
