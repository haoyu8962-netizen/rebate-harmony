// 组件目录直达（DS-02 设备测试与录屏用，只在 Debug / Staging 编译）：tests-harmony-handback v2 预定的接口。
// 启动 / 热启动 Want 带 parameters['couli.ds02.component'] = 清单组件名时，已打开的组件目录（经真实隐私入口、调试面板进入）
// 回到索引并直接打开同一个真实 CatalogDetail；目录还没打开时先记下，目录出现时再打开。不合法的名字忽略。
// FU-HM-FEEL-KIT §2.4 冷启动：`aa start -a EntryAbility -b com.couli.hm --ps couli.ds02.component <组件名>` 在隐私已有结论（已同意或基本模式）时，
// 界面就绪后自动打开目录（BuildVariant.openPendingCatalog），未决时走同意页、不打开（D10-1163 ②）。
import { catalogComponent } from './CatalogManifest';

export const CATALOG_LAUNCH_KEY: string = 'couli.ds02.component';

export class CatalogLaunch {
  static readonly shared: CatalogLaunch = new CatalogLaunch();
  private pending: string = '';
  /** 已打开的目录索引登记的打开函数（目录消失时清掉）。 */
  private listener: (() => void) | undefined = undefined;
  /** 冷启动已推目录路由、等目录出现（避免重复推）。 */
  private opening: boolean = false;

  /** 来自 Want 参数；只接受清单里的组件名。 */
  request(value: Object | undefined): void {
    if (typeof value !== 'string') {
      return;
    }
    const name: string = value as string;
    if (catalogComponent(name) === undefined) {
      return;
    }
    this.pending = name;
    if (this.listener !== undefined) {
      this.listener();
    }
  }

  /** 目录索引出现时登记；随后立刻处理已记下的请求。 */
  attach(listener: () => void): void {
    this.listener = listener;
    if (this.pending.length > 0) {
      listener();
    }
  }

  detach(listener: () => void): void {
    if (this.listener === listener) {
      this.listener = undefined;
    }
  }

  /** 取走待打开的组件名（没有时为空串）。 */
  take(): string {
    const name: string = this.pending;
    this.pending = '';
    this.opening = false;
    return name;
  }

  /** 有待打开的组件、且还没推过目录路由（冷启动直达用）。 */
  hasPending(): boolean {
    return this.pending.length > 0 && !this.opening;
  }

  /** 冷启动已推目录路由，等目录出现后 take。 */
  markOpening(): void {
    this.opening = true;
  }
}
