const MATCHMAN_SCALE: number = 0.7;
const MATCHMAN_LAYOUT_SIZE: number = 140;
const MATCHMAN_SPRITE_SIZE: number = MATCHMAN_LAYOUT_SIZE * MATCHMAN_SCALE;

@Component
export struct MatchmanWalkerLayers {
  @Prop frameIndex: number = 0;

  @Builder
  private frameImage(path: string, index: number) {
    Image($rawfile(path))
      .width(MATCHMAN_SPRITE_SIZE)
      .height(MATCHMAN_SPRITE_SIZE)
      .objectFit(ImageFit.Contain)
      .visibility(this.frameIndex === index ? Visibility.Visible : Visibility.Hidden);
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      this.frameImage('walk/matchman/frame_01.png', 0);
      this.frameImage('walk/matchman/frame_02.png', 1);
      this.frameImage('walk/matchman/frame_03.png', 2);
      this.frameImage('walk/matchman/frame_04.png', 3);
      this.frameImage('walk/matchman/frame_05.png', 4);
      this.frameImage('walk/matchman/frame_06.png', 5);
      this.frameImage('walk/matchman/frame_07.png', 6);
      this.frameImage('walk/matchman/frame_08.png', 7);
    }
    .width(MATCHMAN_LAYOUT_SIZE)
    .height(MATCHMAN_LAYOUT_SIZE);
  }
}
