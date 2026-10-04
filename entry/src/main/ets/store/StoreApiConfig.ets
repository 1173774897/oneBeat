// Fill these two values after the test and production API domains are ready.
// Keep the scheme as https:// and do not add a trailing slash.
export const STORE_API_BASE_URL_TEST: string = 'https://onebeatapistaging.liluanxin.com:8443';
export const STORE_API_BASE_URL_PROD: string = 'https://onebeatapi.liluanxin.com';

// Change only this key when switching the locally built app between environments.
export const STORE_API_ENVIRONMENT: string = 'test';

export function storeApiBaseUrl(): string {
  const configured = STORE_API_ENVIRONMENT === 'prod' ? STORE_API_BASE_URL_PROD : STORE_API_BASE_URL_TEST;
  if (configured.endsWith('/')) {
    return configured.substring(0, configured.length - 1);
  }
  return configured;
}

export function isStoreApiConfigured(): boolean {
  return storeApiBaseUrl().startsWith('https://');
}
