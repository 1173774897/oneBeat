import { router } from '@kit.ArkUI';

const HOME_URL: string = 'pages/Index';
const TEAM_URL: string = 'pages/TeamPage';

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

/**
 * Leaving a team returns to 多人练习 so the player can regroup immediately,
 * matching where a remote disband already lands. Same stack caveat as
 * navigateToHome: back({ url }) is a silent no-op when the page is gone, so a
 * missing TeamPage is rebuilt; its own back action then rebuilds Index.
 */
export async function navigateToTeam(): Promise<void> {
  let onStack = false;
  try {
    onStack = router.getStateByUrl(TEAM_URL).length > 0;
  } catch (_e) {
    onStack = false;
  }
  if (onStack) {
    router.back({ url: TEAM_URL });
    return;
  }
  router.clear();
  await router.replaceUrl({ url: TEAM_URL });
}
