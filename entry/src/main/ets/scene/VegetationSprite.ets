@Component
export struct VegetationSprite {
  @Prop plantIndex: number = 0;
  @Prop displayHeight: number = 52;

  @Builder
  private plantForIndex(index: number) {
    if (index === 0) {
      Image($rawfile('vegetation/plant_01.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 1) {
      Image($rawfile('vegetation/plant_02.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 2) {
      Image($rawfile('vegetation/plant_03.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 3) {
      Image($rawfile('vegetation/plant_04.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 4) {
      Image($rawfile('vegetation/plant_05.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 5) {
      Image($rawfile('vegetation/plant_06.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 6) {
      Image($rawfile('vegetation/plant_07.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 7) {
      Image($rawfile('vegetation/plant_08.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 8) {
      Image($rawfile('vegetation/plant_09.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 9) {
      Image($rawfile('vegetation/plant_10.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 10) {
      Image($rawfile('vegetation/plant_11.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else {
      Image($rawfile('vegetation/plant_12.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    }
  }

  build() {
    Row() {
      this.plantForIndex(this.plantIndex);
    }
    .width(this.displayHeight * 1.35)
    .height(this.displayHeight)
    .justifyContent(FlexAlign.Center)
  }
}
