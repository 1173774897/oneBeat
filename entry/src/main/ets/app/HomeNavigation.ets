import { router } from '@kit.ArkUI';

/** Pop to Index when it is still on the stack; otherwise rebuild a clean home route. */
export async function navigateToHome(): Promise<void> {
  try {
    router.back({ url: 'pages/Index' });
  } catch (_e) {
    router.clear();
    await router.replaceUrl({ url: 'pages/Index' });
  }
}
