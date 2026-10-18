import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

/** Missing is an empty initial state; other read failures must not erase local records. */
export async function readOptional(path: string): Promise<string> {
  return await fs.access(path) ? await fs.readText(path) : '';
}

/** Callers serialize mutations. Rename commits one complete snapshot, without Preferences' 8KB value limit. */
export async function writeAtomic(path: string, contents: string): Promise<void> {
  const temporary = `${path}.tmp-${util.generateRandomUUID(true)}`;
  let committed = false;
  try {
    const file = await fs.open(temporary, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY);
    try {
      const bytes = new util.TextEncoder().encodeInto(contents);
      let written = 0;
      while (written < bytes.byteLength) {
        const remaining = written === 0 ? bytes.buffer : bytes.buffer.slice(written);
        const count = await fs.write(file.fd, remaining);
        if (count <= 0 || count > bytes.byteLength - written) {
          throw new Error('本机记录写入未完成，请检查存储空间后重试');
        }
        written += count;
      }
      await fs.fsync(file.fd);
    } finally {
      await fs.close(file);
    }
    await fs.rename(temporary, path);
    committed = true;
  } finally {
    if (!committed) {
      try {
        if (await fs.access(temporary)) { await fs.unlink(temporary); }
      } catch (_error) {
        // A leftover temporary is ignored by readers; the previous committed file remains authoritative.
      }
    }
  }
}
