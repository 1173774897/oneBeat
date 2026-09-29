import { systemDateTime } from '@kit.BasicServicesKit';

/** Monotonic clock for sync (milliseconds), unaffected by wall-clock corrections. */
export class MonotonicClock {
  static nowMs(): number {
    return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP);
  }
}
