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
      Image($rawfile('scenes/sunset/entities/barrel.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 1) {
      Image($rawfile('scenes/sunset/entities/bench.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 2) {
      Image($rawfile('scenes/sunset/entities/billboard.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 3) {
      Image($rawfile('scenes/sunset/entities/billboardreck.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 4) {
      Image($rawfile('scenes/sunset/entities/blocksign.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 5) {
      Image($rawfile('scenes/sunset/entities/busstop.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 6) {
      Image($rawfile('scenes/sunset/entities/cable.png'))
        .width(this.displayWidth)
        .height(this.displayHeight)
        .objectFit(ImageFit.Contain);
    } else if (index === 7) {
      Image($rawfile('scenes/sunset/entities/cactus.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 8) {
      Image($rawfile('scenes/sunset/entities/cart.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 9) {
      Image($rawfile('scenes/sunset/entities/drain.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 10) {
      Image($rawfile('scenes/sunset/entities/firehydrant.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 11) {
      Image($rawfile('scenes/sunset/entities/gaslight.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 12) {
      Image($rawfile('scenes/sunset/entities/mailbox.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 13) {
      Image($rawfile('scenes/sunset/entities/milemeter.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 14) {
      Image($rawfile('scenes/sunset/entities/paperbox.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 15) {
      Image($rawfile('scenes/sunset/entities/petrol.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 16) {
      Image($rawfile('scenes/sunset/entities/phone.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 17) {
      Image($rawfile('scenes/sunset/entities/rocks.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 18) {
      Image($rawfile('scenes/sunset/entities/sign.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 19) {
      Image($rawfile('scenes/sunset/entities/snowcone.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 20) {
      Image($rawfile('scenes/sunset/entities/telescope.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 21) {
      Image($rawfile('scenes/sunset/entities/tier.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 22) {
      Image($rawfile('scenes/sunset/entities/trashcan.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 23) {
      Image($rawfile('scenes/sunset/entities/tree.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else if (index === 24) {
      Image($rawfile('scenes/sunset/entities/umbrella.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
    } else {
      Image($rawfile('scenes/sunset/entities/vendingmachine.png')).height(this.displayHeight).objectFit(ImageFit.Contain);
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
