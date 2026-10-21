import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { media } from '@kit.MediaKit';

const COVER_JPEG_QUALITY: number = 95;

/** Creates one durable cover at the recording's resolution, releasing decoder/PixelMap resources. */
export class RecordingCoverService {
  static async generate(videoPath: string, coverPath: string,
    sourceWidth: number, sourceHeight: number): Promise<void> {
    // Existing covers stay immutable; higher resolution applies only to new
    // extraction, without upgrading or invalidating previously generated files.
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
          // Capture already bounds video width to 1080px. Keep its native
          // detail so high-density tickets do not enlarge a 430–540px image.
          const width = Math.max(2, Math.floor(Math.max(2, sourceWidth) / 2) * 2);
          const height = Math.max(2, Math.floor(Math.max(2, sourceHeight) / 2) * 2);
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
