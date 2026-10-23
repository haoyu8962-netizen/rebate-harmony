// 组件目录直达（DS-02 设备测试用，只在 Debug / Staging 编译）：tests-harmony-handback v2 预定的接口。
// 启动 / 热启动 Want 带 parameters['couli.ds02.component'] = 清单组件名时，已打开的组件目录（经真实隐私入口、调试面板进入）
// 回到索引并直接打开同一个真实 CatalogDetail；目录还没打开时先记下，目录出现时再打开。不合法的名字忽略。
import { catalogComponent } from './CatalogManifest';

export const CATALOG_LAUNCH_KEY: string = 'couli.ds02.component';

export class CatalogLaunch {
  static readonly shared: CatalogLaunch = new CatalogLaunch();
  private pending: string = '';
  /** 已打开的目录索引登记的打开函数（目录消失时清掉）。 */
  private listener: (() => void) | undefined = undefined;

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
    return name;
  }
}
