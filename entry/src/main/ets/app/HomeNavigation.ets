import { router } from '@kit.ArkUI';

const HOME_URL: string = 'pages/Index';

/**
 * Pop to Index when it is still on the stack; otherwise rebuild a clean home
 * route. router.back with a URL that is not on the stack neither throws nor
 * navigates: after a remote disband clears the stack (Index gone), a later
 * "leave team" stayed on the lobby showing "正在退出队伍…" (device 2026-10-29).
 */
export async function navigateToHome(): Promise<void> {
  let onStack = false;
  try {
    onStack = router.getStateByUrl(HOME_URL).length > 0;
  } catch (_e) {
    onStack = false;
  }
  if (onStack) {
    router.back({ url: HOME_URL });
    return;
  }
  router.clear();
  await router.replaceUrl({ url: HOME_URL });
}
