// 违反样例：用 router 导航。
import { router } from '@kit.ArkUI';
import legacyRouter from '@ohos.router';

export function go(): void {
  router.pushUrl({ url: 'pages/Next' });
  legacyRouter.back();
}
