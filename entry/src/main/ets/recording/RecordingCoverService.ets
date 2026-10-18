import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { media } from '@kit.MediaKit';

const COVER_MAX_WIDTH_PX: number = 540;
const COVER_MAX_HEIGHT_PX: number = 960;
const COVER_JPEG_QUALITY: number = 90;

/** Creates one durable cover without retaining decoder or PixelMap resources. */
export class RecordingCoverService {
  static async generate(videoPath: string, coverPath: string,
    sourceWidth: number, sourceHeight: number): Promise<void> {
    if (await fs.access(coverPath) && (await fs.stat(coverPath)).size > 0) { return; }
    const temporaryPath = `${coverPath}.tmp`;
    let committed = false;
    try {
      const videoStat = await fs.stat(videoPath);
      if (!videoStat.isFile() || videoStat.size <= 0) { throw new Error('录制视频为空，无法生成封面'); }
      const sourceFile = await fs.open(videoPath, fs.OpenMode.READ_ONLY);
      try {
        const generator = await media.createAVImageGenerator();
        try {
          generator.fdSrc = { fd: sourceFile.fd, offset: 0, length: videoStat.size };
          const scale = Math.min(1,
            COVER_MAX_WIDTH_PX / Math.max(1, sourceWidth),
            COVER_MAX_HEIGHT_PX / Math.max(1, sourceHeight));
          const width = Math.max(2, Math.floor(Math.max(2, sourceWidth) * scale / 2) * 2);
          const height = Math.max(2, Math.floor(Math.max(2, sourceHeight) * scale / 2) * 2);
          const pixelMap = await generator.fetchFrameByTime(
            0, media.AVImageQueryOptions.AV_IMAGE_QUERY_NEXT_SYNC, { width: width, height: height });
          try {
            const packer = image.createImagePacker();
            try {
              const destination = await fs.open(temporaryPath,
                fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
              try {
                const options: image.PackingOption = { format: 'image/jpeg', quality: COVER_JPEG_QUALITY };
                await packer.packToFile(pixelMap, destination.fd, options);
                await fs.fsync(destination.fd);
              } finally {
                await fs.close(destination);
              }
            } finally {
              await packer.release();
            }
          } finally {
            await pixelMap.release();
          }
        } finally {
          await generator.release();
        }
      } finally {
        await fs.close(sourceFile);
      }
      if ((await fs.stat(temporaryPath)).size <= 0) { throw new Error('录制封面生成失败'); }
      await fs.rename(temporaryPath, coverPath);
      committed = true;
    } finally {
      if (!committed) {
        try {
          if (await fs.access(temporaryPath)) { await fs.unlink(temporaryPath); }
        } catch (_error) {
          // A failed thumbnail never invalidates the playable recording.
        }
      }
    }
  }
}
