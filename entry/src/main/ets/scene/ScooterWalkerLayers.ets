/** 与 mismatch 相同布局尺寸 */
const SCOOTER_WALKER_SIZE: number = 140;

@Component
export struct ScooterWalkerLayers {
  @Prop frameIndex: number = 0;

  @Builder
  private frameImage(path: string, index: number) {
    Image($rawfile(path))
      .width(SCOOTER_WALKER_SIZE)
      .height(SCOOTER_WALKER_SIZE)
      .objectFit(ImageFit.Contain)
      .visibility(this.frameIndex === index ? Visibility.Visible : Visibility.Hidden);
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      this.frameImage('walk/scooter/frame_01.png', 0);
      this.frameImage('walk/scooter/frame_02.png', 1);
      this.frameImage('walk/scooter/frame_03.png', 2);
      this.frameImage('walk/scooter/frame_04.png', 3);
      this.frameImage('walk/scooter/frame_05.png', 4);
      this.frameImage('walk/scooter/frame_06.png', 5);
      this.frameImage('walk/scooter/frame_07.png', 6);
      this.frameImage('walk/scooter/frame_08.png', 7);
      this.frameImage('walk/scooter/frame_09.png', 8);
      this.frameImage('walk/scooter/frame_10.png', 9);
      this.frameImage('walk/scooter/frame_11.png', 10);
      this.frameImage('walk/scooter/frame_12.png', 11);
      this.frameImage('walk/scooter/frame_13.png', 12);
      this.frameImage('walk/scooter/frame_14.png', 13);
      this.frameImage('walk/scooter/frame_15.png', 14);
      this.frameImage('walk/scooter/frame_16.png', 15);
    }
    .width(SCOOTER_WALKER_SIZE)
    .height(SCOOTER_WALKER_SIZE);
  }
}
