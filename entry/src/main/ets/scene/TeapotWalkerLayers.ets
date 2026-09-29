/** 与 WalkerSprite 中 cloud 相同缩放（0.7 × 140） */
const TEAPOT_WALKER_SIZE: number = 140 * 0.7;
const TEAPOT_LAYOUT_SIZE: number = 140;

@Component
export struct TeapotWalkerLayers {
  @Prop frameIndex: number = 0;

  @Builder
  private frameImage(path: string, index: number) {
    Image($rawfile(path))
      .width(TEAPOT_WALKER_SIZE)
      .height(TEAPOT_WALKER_SIZE)
      .objectFit(ImageFit.Contain)
      .visibility(this.frameIndex === index ? Visibility.Visible : Visibility.Hidden);
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      this.frameImage('walk/teapot/frame_01.png', 0);
      this.frameImage('walk/teapot/frame_02.png', 1);
      this.frameImage('walk/teapot/frame_03.png', 2);
      this.frameImage('walk/teapot/frame_04.png', 3);
      this.frameImage('walk/teapot/frame_05.png', 4);
      this.frameImage('walk/teapot/frame_06.png', 5);
      this.frameImage('walk/teapot/frame_07.png', 6);
      this.frameImage('walk/teapot/frame_08.png', 7);
    }
    .width(TEAPOT_LAYOUT_SIZE)
    .height(TEAPOT_LAYOUT_SIZE);
  }
}
