import { WalkerAvatarKey } from '../assets/AssetCatalog';
import { LilrollWalkerLayers } from './LilrollWalkerLayers';
import { TeapotWalkerLayers } from './TeapotWalkerLayers';
import { WaveWalkerLayers } from './WaveWalkerLayers';
import { ScooterWalkerLayers } from './ScooterWalkerLayers';
import { LampWalkerLayers } from './LampWalkerLayers';
import { RandomPoolWalkerLayers } from './RandomPoolWalkerLayers';

const CLOUD_SCALE: number = 0.7;
const BASE_WALKER_SIZE: number = 140;
const CLOUD_WALKER_SIZE: number = BASE_WALKER_SIZE * CLOUD_SCALE;

@Component
export struct WalkerSprite {
  @Prop @Watch('onFrameChanged') frameIndex: number = 0;
  @Prop avatar: WalkerAvatarKey = 'cloud';
  @Prop colorSlot: number = 0;

  onFrameChanged(): void {
    // Prop watch keeps the stack in sync when frameIndex updates.
  }

  @Builder
  private cloudLayers() {
    Stack({ alignContent: Alignment.Bottom }) {
      Image($rawfile('walk/cloud/frame_01.png'))
        .width(CLOUD_WALKER_SIZE).height(CLOUD_WALKER_SIZE).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 0 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/cloud/frame_02.png'))
        .width(CLOUD_WALKER_SIZE).height(CLOUD_WALKER_SIZE).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 1 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/cloud/frame_03.png'))
        .width(CLOUD_WALKER_SIZE).height(CLOUD_WALKER_SIZE).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 2 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/cloud/frame_04.png'))
        .width(CLOUD_WALKER_SIZE).height(CLOUD_WALKER_SIZE).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 3 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/cloud/frame_05.png'))
        .width(CLOUD_WALKER_SIZE).height(CLOUD_WALKER_SIZE).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 4 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/cloud/frame_06.png'))
        .width(CLOUD_WALKER_SIZE).height(CLOUD_WALKER_SIZE).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 5 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/cloud/frame_07.png'))
        .width(CLOUD_WALKER_SIZE).height(CLOUD_WALKER_SIZE).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 6 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/cloud/frame_08.png'))
        .width(CLOUD_WALKER_SIZE).height(CLOUD_WALKER_SIZE).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 7 ? Visibility.Visible : Visibility.Hidden)
    }
    .width(BASE_WALKER_SIZE)
    .height(BASE_WALKER_SIZE)
  }

  @Builder
  private mismatchLayers() {
    Stack() {
      Image($rawfile('walk/mismatch/frame_01.png'))
        .width(140).height(140).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 0 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/mismatch/frame_02.png'))
        .width(140).height(140).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 1 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/mismatch/frame_03.png'))
        .width(140).height(140).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 2 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/mismatch/frame_04.png'))
        .width(140).height(140).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 3 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/mismatch/frame_05.png'))
        .width(140).height(140).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 4 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/mismatch/frame_06.png'))
        .width(140).height(140).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 5 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/mismatch/frame_07.png'))
        .width(140).height(140).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 6 ? Visibility.Visible : Visibility.Hidden)
      Image($rawfile('walk/mismatch/frame_08.png'))
        .width(140).height(140).objectFit(ImageFit.Contain)
        .visibility(this.frameIndex === 7 ? Visibility.Visible : Visibility.Hidden)
    }
    .width(BASE_WALKER_SIZE)
    .height(BASE_WALKER_SIZE)
  }

  build() {
    if (this.avatar === 'cloud') {
      this.cloudLayers();
    } else if (this.avatar === 'lilroll') {
      LilrollWalkerLayers({ frameIndex: this.frameIndex });
    } else if (this.avatar === 'teapot') {
      TeapotWalkerLayers({ frameIndex: this.frameIndex });
    } else if (this.avatar === 'wave') {
      WaveWalkerLayers({ frameIndex: this.frameIndex });
    } else if (this.avatar === 'scooter') {
      ScooterWalkerLayers({ frameIndex: this.frameIndex });
    } else if (this.avatar === 'lamp') {
      LampWalkerLayers({ frameIndex: this.frameIndex });
    } else if (this.avatar === 'braids' || this.avatar === 'boonie') {
      RandomPoolWalkerLayers({
        frameIndex: this.frameIndex,
        avatar: this.avatar,
        colorSlot: this.colorSlot
      });
    } else {
      this.mismatchLayers();
    }
  }
}
