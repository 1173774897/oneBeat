import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const PREFERENCES_NAME: string = 'onebeat_audio_latency';
const KEY_OUTPUT_COMPENSATION_MS: string = 'outputCompensationMs';
const KEY_INPUT_LATENCY_MS: string = 'inputLatencyMs';
const KEY_INPUT_LATENCY_VERSION: string = 'inputLatencyVersion';
// Version 3 uses the renderer-presentation frame as the reference and subtracts
// only its downstream HARDWARE leg. Older values used submit/ALL semantics and
// must not be mixed with the fixed loopback path.
const INPUT_LATENCY_VERSION: number = 3;

let appContext: common.Context | undefined = undefined;
// -1 = 未校准；>= 0 表示「节拍打卡机」实测出的 app→耳朵 完整时延补偿（毫秒）。
let calibrationMs: number = -1;
// -1 = 未校准；>= 0 表示麦克风输入侧时延（麦克风→ADC→输入缓冲→AEC/降噪→readData，毫秒）。
// mic 回环测的是「输出 + 输入」往返，保存输出补偿前需先扣掉它，语义才和打卡机一致。
let inputLatencyMs: number = -1;

export function bindAudioLatencyPersistenceContext(context: common.Context): void {
  appContext = context;
}

/** 同步读取当前生效的校准补偿值；未校准返回 -1。 */
export function getCalibrationMs(): number {
  return calibrationMs;
}

/** 引擎使用的完整路由补偿；是否属于无线耳机由音频引擎在应用前判断。 */
export function getEffectiveCalibrationMs(): number {
  return calibrationMs;
}

async function openPreferences(): Promise<preferences.Preferences | undefined> {
  if (appContext === undefined) {
    return undefined;
  }
  return preferences.getPreferences(appContext, PREFERENCES_NAME);
}

export async function restoreCalibrationMs(): Promise<void> {
  const pref = await openPreferences();
  if (pref === undefined) {
    return;
  }
  const value = (await pref.get(KEY_OUTPUT_COMPENSATION_MS, -1)) as number;
  calibrationMs = (typeof value === 'number' && Number.isFinite(value) && value >= 0) ? value : -1;
}

/** 同步读取当前生效的输入侧时延；未校准返回 -1。 */
export function getInputLatencyMs(): number {
  return inputLatencyMs;
}

export async function restoreInputLatencyMs(): Promise<void> {
  const pref = await openPreferences();
  if (pref === undefined) {
    return;
  }
  const value = (await pref.get(KEY_INPUT_LATENCY_MS, -1)) as number;
  const version = (await pref.get(KEY_INPUT_LATENCY_VERSION, 0)) as number;
  inputLatencyMs = (version === INPUT_LATENCY_VERSION && typeof value === 'number' &&
    Number.isFinite(value) && value > 0) ? value : -1;
}

export async function saveInputLatencyMs(value: number): Promise<void> {
  if (!Number.isFinite(value) || value <= 0) {
    // Zero/negative means the two timing references did not describe the same
    // route. Persisting it would turn the mic input leg into output compensation.
    throw new Error(`无效的输入侧时延: ${value}`);
  }
  const pref = await openPreferences();
  if (pref === undefined) {
    inputLatencyMs = value;
    return;
  }
  await pref.put(KEY_INPUT_LATENCY_MS, value);
  await pref.put(KEY_INPUT_LATENCY_VERSION, INPUT_LATENCY_VERSION);
  await pref.flush();
  inputLatencyMs = value;
}

export async function clearInputLatencyMs(): Promise<void> {
  const pref = await openPreferences();
  if (pref === undefined) {
    inputLatencyMs = -1;
    return;
  }
  await pref.delete(KEY_INPUT_LATENCY_MS);
  await pref.delete(KEY_INPUT_LATENCY_VERSION);
  await pref.flush();
  inputLatencyMs = -1;
}

export async function saveCalibrationMs(value: number): Promise<void> {
  if (!Number.isFinite(value) || value < 0) {
    throw new Error(`无效的输出补偿: ${value}`);
  }
  const pref = await openPreferences();
  if (pref === undefined) {
    calibrationMs = value;
    return;
  }
  await pref.put(KEY_OUTPUT_COMPENSATION_MS, value);
  await pref.flush();
  calibrationMs = value;
}

export async function clearCalibrationMs(): Promise<void> {
  const pref = await openPreferences();
  if (pref === undefined) {
    calibrationMs = -1;
    return;
  }
  await pref.delete(KEY_OUTPUT_COMPENSATION_MS);
  await pref.flush();
  calibrationMs = -1;
}
