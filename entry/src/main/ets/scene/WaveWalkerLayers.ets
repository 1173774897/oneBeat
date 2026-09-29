const WAVE_WALKER_SIZE: number = 140 * 0.85;
const WAVE_LAYOUT_SIZE: number = 140;

@Component
export struct WaveWalkerLayers {
  @Prop frameIndex: number = 0;

  @Builder
  private frameImage(path: string, index: number) {
    Image($rawfile(path))
      .width(WAVE_WALKER_SIZE)
      .height(WAVE_WALKER_SIZE)
      .objectFit(ImageFit.Contain)
      .visibility(this.frameIndex === index ? Visibility.Visible : Visibility.Hidden);
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      this.frameImage('walk/wave/frame_01.png', 0);
      this.frameImage('walk/wave/frame_02.png', 1);
      this.frameImage('walk/wave/frame_03.png', 2);
      this.frameImage('walk/wave/frame_04.png', 3);
      this.frameImage('walk/wave/frame_05.png', 4);
      this.frameImage('walk/wave/frame_06.png', 5);
      this.frameImage('walk/wave/frame_07.png', 6);
      this.frameImage('walk/wave/frame_08.png', 7);
    }
    .width(WAVE_LAYOUT_SIZE)
    .height(WAVE_LAYOUT_SIZE);
  }
}
