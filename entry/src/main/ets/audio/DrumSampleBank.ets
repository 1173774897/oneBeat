import { resourceManager } from '@kit.LocalizationKit';
import { DRUM_TRACKS } from './DrumMachineCatalog';

export class DrumSampleBank {
  private static manager: resourceManager.ResourceManager | undefined = undefined;
  private static banks: Map<string, Map<string, ArrayBuffer>> = new Map();

  static initialize(manager: resourceManager.ResourceManager): void {
    DrumSampleBank.manager = manager;
  }

  static async loadStyle(styleKey: string): Promise<Map<string, ArrayBuffer>> {
    const cached = DrumSampleBank.banks.get(styleKey);
    if (cached !== undefined) {
      return cached;
    }
    const bank: Map<string, ArrayBuffer> = new Map();
    const manager = DrumSampleBank.manager;
    if (manager === undefined) {
      // An empty kit would route every drum event through the generic click fallback.
      throw new Error('鼓机音色资源尚未初始化，请重试');
    }
    for (let i = 0; i < DRUM_TRACKS.length; i++) {
      const sampleKey = DRUM_TRACKS[i].key;
      const wav = await manager.getRawFileContent(`drums/${styleKey}/${sampleKey}.wav`);
      bank.set(sampleKey, DrumSampleBank.extractPcm(wav));
    }
    DrumSampleBank.banks.set(styleKey, bank);
    return bank;
  }

  private static extractPcm(wav: Uint8Array): ArrayBuffer {
    const headerSize = 44;
    const byteCount = Math.max(0, wav.byteLength - headerSize);
    const pcm = new ArrayBuffer(byteCount);
    const output = new Uint8Array(pcm);
    for (let i = 0; i < byteCount; i++) {
      output[i] = wav[i + headerSize];
    }
    return pcm;
  }
}
