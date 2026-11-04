import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { PRIVACY_CONSENT_DECLINED_CODE } from '../common/UserFeedback';

/**
 * Separate consent for sending Store data to the developer server in Hong Kong.
 *
 * PIPL treats a transfer from the mainland to Hong Kong as cross-border, which
 * needs consent apart from accepting the privacy statement. Every Huawei login
 * and every authenticated Store request sends account and purchase data there,
 * so they all wait for this consent. The anonymous product-list query carries
 * no personal data and is deliberately not gated (product decision 2026-11-03).
 * Declining blocks only the Store; practice, teams and recording are unaffected.
 */

const PREFERENCES_NAME: string = 'onebeat_privacy_consent';
const KEY_ACCEPTED_VERSION: string = 'storeCrossBorderHkVersion';
// Bump when the cross-border section of the privacy statement changes in
// substance (recipient, location, data types, purpose); users confirm again.
const CONSENT_VERSION: number = 1;

export type CrossBorderConsentPrompter = () => Promise<boolean>;

let consentContext: common.Context | undefined = undefined;
let accepted: boolean = false;
let loading: Promise<void> = Promise.resolve();
let prompter: CrossBorderConsentPrompter | undefined = undefined;
let pendingPrompt: Promise<boolean> | undefined = undefined;

async function openPreferences(): Promise<preferences.Preferences | undefined> {
  if (consentContext === undefined) {
    return undefined;
  }
  return preferences.getPreferences(consentContext, PREFERENCES_NAME);
}

async function loadAcceptedVersion(): Promise<void> {
  try {
    const pref = await openPreferences();
    const version = pref === undefined ? 0 : (await pref.get(KEY_ACCEPTED_VERSION, 0)) as number;
    accepted = version >= CONSENT_VERSION;
  } catch (_e) {
    // An unreadable record must fail closed: ask again rather than transfer.
    accepted = false;
  }
}

/** Called once at startup; until the record loads, consent counts as absent. */
export function bindCrossBorderConsentContext(context: common.Context): void {
  consentContext = context;
  loading = loadAcceptedVersion();
}

/**
 * Forgets consent after the Store account is deleted, so a later use of the
 * Store asks again before any data reaches the server.
 */
export async function revokeCrossBorderConsent(): Promise<void> {
  await loading;
  accepted = false;
  try {
    const pref = await openPreferences();
    if (pref !== undefined) {
      // Version 0 reads as "not accepted" (fail closed), unlike a missing write.
      await pref.put(KEY_ACCEPTED_VERSION, 0);
      await pref.flush();
    }
  } catch (_e) {
    // In-memory consent is already cleared; the next Store use asks again this run.
  }
}

/** Synchronous view for code that must not reach the server without consent. */
export function hasCrossBorderConsent(): boolean {
  return accepted;
}

/** The Store page registers its dialog while visible; undefined unregisters. */
export function setCrossBorderConsentPrompter(next: CrossBorderConsentPrompter | undefined): void {
  prompter = next;
}

/** Carries PRIVACY_CONSENT_DECLINED_CODE so isUserCancelled() treats it as a user choice. */
export class CrossBorderConsentDeclinedError extends Error {
  code: number = PRIVACY_CONSENT_DECLINED_CODE;

  constructor() {
    super('需要同意跨境传输后才能使用奇遇小铺');
  }
}

/**
 * Resolves when consent is on record. Non-interactive callers (silent session
 * renewal) never prompt; they fail with the declined code, which callers treat
 * like a cancelled login.
 */
export async function ensureCrossBorderConsent(interactive: boolean): Promise<void> {
  await loading;
  if (accepted) {
    return;
  }
  const ask = prompter;
  if (!interactive || ask === undefined) {
    throw new CrossBorderConsentDeclinedError();
  }
  // Concurrent Store actions share one dialog instead of stacking several.
  if (pendingPrompt === undefined) {
    pendingPrompt = ask();
  }
  let agreed = false;
  try {
    agreed = await pendingPrompt;
  } finally {
    pendingPrompt = undefined;
  }
  if (!agreed) {
    throw new CrossBorderConsentDeclinedError();
  }
  accepted = true;
  try {
    const pref = await openPreferences();
    if (pref !== undefined) {
      await pref.put(KEY_ACCEPTED_VERSION, CONSENT_VERSION);
      await pref.flush();
    }
  } catch (_e) {
    // Consent stays valid for this run; a failed write only means asking again later.
  }
}
