let bootstrapRefreshPromise: Promise<void> | undefined = undefined;

export function invalidateStoreBootstrapRefresh(): void {
  bootstrapRefreshPromise = undefined;
}

export function getStoreBootstrapRefreshPromise(): Promise<void> | undefined {
  return bootstrapRefreshPromise;
}

export function setStoreBootstrapRefreshPromise(promise: Promise<void> | undefined): void {
  bootstrapRefreshPromise = promise;
}
