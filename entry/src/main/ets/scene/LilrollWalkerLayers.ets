const LILROLL_WALKER_SIZE: number = 140;

@Component
export struct LilrollWalkerLayers {
  @Prop @Watch('onFrameChanged') frameIndex: number = 0;

  onFrameChanged(): void {
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Image($rawfile('walk/lilroll/frame_01.png'))
        .width(LILROLL_WALKER_SIZE).height(LILROLL_WALKER_SIZE).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 0 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/lilroll/frame_02.png'))
        .width(LILROLL_WALKER_SIZE).height(LILROLL_WALKER_SIZE).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 1 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/lilroll/frame_03.png'))
        .width(LILROLL_WALKER_SIZE).height(LILROLL_WALKER_SIZE).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 2 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/lilroll/frame_04.png'))
        .width(LILROLL_WALKER_SIZE).height(LILROLL_WALKER_SIZE).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 3 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/lilroll/frame_05.png'))
        .width(LILROLL_WALKER_SIZE).height(LILROLL_WALKER_SIZE).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 4 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/lilroll/frame_06.png'))
        .width(LILROLL_WALKER_SIZE).height(LILROLL_WALKER_SIZE).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 5 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/lilroll/frame_07.png'))
        .width(LILROLL_WALKER_SIZE).height(LILROLL_WALKER_SIZE).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 6 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/lilroll/frame_08.png'))
        .width(LILROLL_WALKER_SIZE).height(LILROLL_WALKER_SIZE).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 7 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/lilroll/frame_09.png'))
        .width(LILROLL_WALKER_SIZE).height(LILROLL_WALKER_SIZE).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 8 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/lilroll/frame_10.png'))
        .width(LILROLL_WALKER_SIZE).height(LILROLL_WALKER_SIZE).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 9 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/lilroll/frame_11.png'))
        .width(LILROLL_WALKER_SIZE).height(LILROLL_WALKER_SIZE).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 10 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/lilroll/frame_12.png'))
        .width(LILROLL_WALKER_SIZE).height(LILROLL_WALKER_SIZE).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 11 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/lilroll/frame_13.png'))
        .width(LILROLL_WALKER_SIZE).height(LILROLL_WALKER_SIZE).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 12 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/lilroll/frame_14.png'))
        .width(LILROLL_WALKER_SIZE).height(LILROLL_WALKER_SIZE).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 13 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/lilroll/frame_15.png'))
        .width(LILROLL_WALKER_SIZE).height(LILROLL_WALKER_SIZE).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 14 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/lilroll/frame_16.png'))
        .width(LILROLL_WALKER_SIZE).height(LILROLL_WALKER_SIZE).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 15 ? Visibility.Visible : Visibility.Hidden)
    }
    .width(LILROLL_WALKER_SIZE)
    .height(LILROLL_WALKER_SIZE)
  }
}
