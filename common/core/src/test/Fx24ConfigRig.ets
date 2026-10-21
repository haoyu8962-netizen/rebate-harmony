// F-X-24 测试辅助：只提供原始 /v1/config 响应、内存 LKG 与可控刷新，不复制配置解析规则。
import { BundledConfig } from 'generated';
import { ConfigReply, ConfigStore } from '../main/ets/clientcore/ConfigStore';

export const DISABLED_KEY: string = 'bridge_disabled_methods';

/** null 表示键缺失；字符串 'null' 表示显式 JSON null。其余值逐字来自共用 vectors.md。 */
export function configBody(raw: string | null, version: string = 'fx24'): string {
  const body: Record<string, Object> = JSON.parse(BundledConfig.DATA_JSON) as Record<string, Object>;
  body['dict_version'] = version;
  if (raw !== null) {
    body[DISABLED_KEY] = JSON.parse(raw) as Object;
  }
  return JSON.stringify(body);
}

export class Fx24ConfigRig {
  file: string | null;
  readonly store: ConfigStore;
  readonly warnings: string[] = [];
  private done: ((reply: ConfigReply) => void) | null = null;

  constructor(bundledRaw: string | null = null, file: string | null = null) {
    this.file = file;
    this.store = new ConfigStore((): string | null => this.file, (value: string | null): void => {
      this.file = value;
    }, (_etag: string | null, done: (reply: ConfigReply) => void): void => {
      this.done = done;
    }, (): number => 1790661600000, configBody(bundledRaw, 'bundled'));
    this.store.onColdStart();
  }

  /** 完成冷启动或前台刷新；没有在途请求时走真实 onForeground 入口。 */
  reply(reply: ConfigReply): void {
    if (this.done === null) {
      this.store.onForeground();
    }
    const done: ((reply: ConfigReply) => void) | null = this.done;
    if (done === null) {
      throw new Error('ConfigStore did not start a fetch');
    }
    this.done = null;
    done(reply);
  }

  apply(raw: string | null, version: string = 'current'): void {
    this.reply(new ConfigReply(ConfigReply.OK, configBody(raw, version), '"' + version + '"'));
  }

  /** 测试依赖的新产品接口；这里只转发，既不挑拣元素也不做缺省。 */
  methods(): string[] {
    return this.store.bridgeDisabledMethods((key: string): void => {
      this.warnings.push(key);
    });
  }
}
