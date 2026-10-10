// Debug / Staging（core 模块 staging target）：首页草稿预览的纯策略（TECH-11、03 §3.6、G24）。只在 product=staging 编译，由
// src/staging/ets/config/DebugOnly.ets 导出；Release（default target）没有本文件与任何同名代码（tools/ci/release-scan.sh 查调试路由名）。
// 单测（Hypium 按 default target 编译）直接按相对路径引入本文件（rule-gaps H01）。
import { HomeDecoded } from '../../../main/ets/home/HomeModels';
import { HomeJson, HomeJsonRead } from '../../../main/ets/home/HomeJson';

type PreviewJson = Record<string, Object | null>;

/**
 * 草稿预览的结果判定：ok 且整页有效 → draft；30701（过期或环境不符）→ expired；其余 → error（统一错误消息 +【重试】）。
 * 预览一律只读（G24 ⑥）：不写 LKG、弹窗计数、公告关闭记录，不发埋点，不切换环境（用当前选中的环境，G24 ③）。
 */
export class HomePreviewPolicy {
  static readonly DRAFT: string = 'draft';
  static readonly EXPIRED: string = 'expired';
  static readonly ERROR: string = 'error';
  /** 有效期按收到 token 起算 10 分钟（G24 ⑤，代拟；拿不到签发时刻）。 */
  static readonly VALID_MS: number = 10 * 60 * 1000;

  static screenOf(ok: boolean, code: number, page: PreviewJson | null): string {
    if (ok) {
      if (page === null) {
        return HomePreviewPolicy.ERROR;
      }
      const decoded: HomeDecoded = HomeJson.decodePage(page, 'harmony', '0');
      return decoded.valid ? HomePreviewPolicy.DRAFT : HomePreviewPolicy.ERROR;
    }
    return code === 30701 ? HomePreviewPolicy.EXPIRED : HomePreviewPolicy.ERROR;
  }

  /** 向量接线：routeParams 只有 Router 留下的 page_key / token；result = {kind: ok|error, page?, code?}。 */
  static of(routeParams: PreviewJson, result: PreviewJson): PreviewJson {
    const ok: boolean = result['kind'] === 'ok';
    const code: Object | null | undefined = result['code'];
    const screen: string = HomePreviewPolicy.screenOf(ok, typeof code === 'number' ? code as number : -1,
      HomeJsonRead.objectOf(result['page']));
    const out: PreviewJson = {};
    out['screenRaw'] = screen;
    out['pageKey'] = routeParams['page_key'] ?? null;
    out['token'] = routeParams['token'] ?? null;
    out['writesLkg'] = false;
    out['writesPopupCount'] = false;
    out['writesNoticeClosed'] = false;
    out['sendsEvents'] = false;
    out['switchesEnv'] = false;
    return out;
  }
}
