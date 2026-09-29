@Component
export struct SideEntitySprite {
  @Prop entityIndex: number = 0;
  @Prop displayWidth: number = 120;
  @Prop displayHeight: number = 110;
  @Prop sceneKey: string = 'sunset_coast';

  @Builder
  private neonImageForIndex(index: number) {
    if (index === 0) {
      Image($rawfile('scenes/neon/entities/bikes.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 1) {
      Image($rawfile('scenes/neon/entities/billboard.png'))
        .width(this.displayWidth)
        .height(this.displayHeight)
        .objectFit(ImageFit.Contain);
    } else if (index === 2) {
      Image($rawfile('scenes/neon/entities/blindeggs.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 3) {
      Image($rawfile('scenes/neon/entities/blocksign.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 4) {
      Image($rawfile('scenes/neon/entities/busstop.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 5) {
      Image($rawfile('scenes/neon/entities/drain.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 6) {
      Image($rawfile('scenes/neon/entities/electricitybox.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 7) {
      Image($rawfile('scenes/neon/entities/electricplugs.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 8) {
      Image($rawfile('scenes/neon/entities/gamemachine.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 9) {
      Image($rawfile('scenes/neon/entities/laundrymachines.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 10) {
      Image($rawfile('scenes/neon/entities/magnifier.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 11) {
      Image($rawfile('scenes/neon/entities/neoncat.png'))
        .width(this.displayWidth)
        .height(this.displayHeight)
        .objectFit(ImageFit.Contain);
    } else if (index === 12) {
      Image($rawfile('scenes/neon/entities/phonebooth.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 13) {
      Image($rawfile('scenes/neon/entities/scooter.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 14) {
      Image($rawfile('scenes/neon/entities/snackcart.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 15) {
      Image($rawfile('scenes/neon/entities/streetlight.png'))
        .width(this.displayWidth)
        .height(this.displayHeight)
        .objectFit(ImageFit.Contain);
    } else if (index === 16) {
      Image($rawfile('scenes/neon/entities/tank.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 17) {
      Image($rawfile('scenes/neon/entities/tape.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 18) {
      Image($rawfile('scenes/neon/entities/threemeters.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 19) {
      Image($rawfile('scenes/neon/entities/trafficlight.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else {
      Image($rawfile('scenes/neon/entities/umbrella.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    }
  }

  @Builder
  private imageForIndex(index: number) {
    if (index === 0) {
      Image($rawfile('entities/barrel.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 1) {
      Image($rawfile('entities/bench.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 2) {
      Image($rawfile('entities/billboard.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 3) {
      Image($rawfile('entities/billboardreck.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 4) {
      Image($rawfile('entities/blocksign.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 5) {
      Image($rawfile('entities/busstop.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 6) {
      Image($rawfile('entities/cable.png'))
        .width(this.displayWidth)
        .height(this.displayHeight)
        .objectFit(ImageFit.Contain);
    } else if (index === 7) {
      Image($rawfile('entities/cactus.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 8) {
      Image($rawfile('entities/cart.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 9) {
      Image($rawfile('entities/drain.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 10) {
      Image($rawfile('entities/firehydrant.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 11) {
      Image($rawfile('entities/gaslight.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 12) {
      Image($rawfile('entities/mailbox.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 13) {
      Image($rawfile('entities/milemeter.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 14) {
      Image($rawfile('entities/paperbox.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 15) {
      Image($rawfile('entities/petrol.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 16) {
      Image($rawfile('entities/phone.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 17) {
      Image($rawfile('entities/rocks.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 18) {
      Image($rawfile('entities/sign.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 19) {
      Image($rawfile('entities/snowcone.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 20) {
      Image($rawfile('entities/telescope.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 21) {
      Image($rawfile('entities/tier.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 22) {
      Image($rawfile('entities/trashcan.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 23) {
      Image($rawfile('entities/tree.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 24) {
      Image($rawfile('entities/umbrella.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else {
      Image($rawfile('entities/vendingmachine.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    }
  }

  build() {
    Row() {
      if (this.sceneKey === 'neon_street') {
        this.neonImageForIndex(this.entityIndex);
      } else {
        this.imageForIndex(this.entityIndex);
      }
    }
    .width(this.displayWidth)
    .height(this.displayHeight)
    .justifyContent(FlexAlign.Center)
  }
}
