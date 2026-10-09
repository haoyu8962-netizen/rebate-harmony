import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DEFAULT_RECHECK_INTERVAL_SEC, UpdateCheckResult, UpdatePersisted, UpdateStore, UpdateStoreListing } from './UpdateGate';

/** 落盘的 JSON 形状（不是业务契约，rule-gaps G12）。 */
interface StoredListing {
  store: string;
  version: string;
}

interface StoredResult {
  minSupported: string | null;
  recommended: string | null;
  latest: string | null;
  defaultStore: string | null;
  stores: StoredListing[];
  recheckIntervalSec: number;
  updateTitle: string | null;
  updateNotes: string | null;
}

interface StoredState {
  result: StoredResult | null;
  lastSuccessAtMillis: number | null;
  forcedBy10405: boolean;
  forcedMinimum: string | null;
  forcedAppVersion: string | null;
  forcedByServer?: boolean;
  dismissedLatest: string | null;
}

const KEY: string = 'update.state';

/**
 * Preferences 实现的强更结论存储（一个键存整份 JSON；每次写入 flushSync：强更结论写下后进程被杀，下次冷启动仍要直接拦）。
 * namespace：Release 用 CouliPreferences.UPDATE_NAMESPACE；Debug / Staging 的调试假结果用 UPDATE_DEBUG_NAMESPACE，
 * 不写进 Release 读取的存储（三端统一裁定：同签名覆盖安装成 Release 后不会被假的强更结论拦住）。两个命名空间都在
 * ALL_NAMESPACES 里：检查结果属于连接的那套服务器，切换环境时随命名空间清理。
 * 每次读写都重新取 Preferences 实例（清理器 deletePreferences 之后拿到新实例，不用已删除的旧句柄）。
 * 读失败或内容损坏时按「什么都不知道」（冷启动照常检查；不凭坏数据拦人）。
 * 写失败时不抛给调用方（检查结果回调里不能炸）：本进程改用内存里的值，保证本次运行的结论一致；下次冷启动按磁盘上的旧值。
 */
export class PreferencesUpdateStore implements UpdateStore {
  private readonly context: common.Context;
  readonly namespace: string;
  /** 落盘失败后本进程使用的值（落盘成功即清掉，回到每次读磁盘）。 */
  private unsaved: UpdatePersisted | null = null;

  constructor(context: common.Context, namespace: string) {
    this.context = context;
    this.namespace = namespace;
  }

  private prefs(): preferences.Preferences {
    return preferences.getPreferencesSync(this.context, { name: this.namespace });
  }

  load(): UpdatePersisted {
    if (this.unsaved !== null) {
      return this.unsaved.copy();
    }
    try {
      const raw: preferences.ValueType = this.prefs().getSync(KEY, '');
      if (typeof raw !== 'string' || raw.length === 0) {
        return new UpdatePersisted();
      }
      return PreferencesUpdateStore.decode(raw as string);
    } catch (e) {
      return new UpdatePersisted();
    }
  }

  save(value: UpdatePersisted): void {
    try {
      const p: preferences.Preferences = this.prefs();
      p.putSync(KEY, PreferencesUpdateStore.encode(value));
      p.flushSync();
      this.unsaved = null;
    } catch (e) {
      hilog.error(0x0000, 'CouliUpdate', 'save update state failed: %{public}s', JSON.stringify(e));
      this.unsaved = value.copy();
    }
  }

  static encode(value: UpdatePersisted): string {
    const result: UpdateCheckResult | null = value.result;
    let stored: StoredResult | null = null;
    if (result !== null) {
      stored = {
        minSupported: result.minSupported,
        recommended: result.recommended,
        latest: result.latest,
        defaultStore: result.defaultStore,
        stores: result.stores.map((s: UpdateStoreListing): StoredListing => {
          const item: StoredListing = { store: s.store, version: s.version };
          return item;
        }),
        recheckIntervalSec: result.recheckIntervalSec,
        updateTitle: result.updateTitle,
        updateNotes: result.updateNotes
      };
    }
    const state: StoredState = {
      result: stored,
      lastSuccessAtMillis: value.lastSuccessAtMillis,
      forcedBy10405: value.forcedBy10405,
      forcedMinimum: value.forcedMinimum,
      forcedAppVersion: value.forcedAppVersion,
      forcedByServer: value.forcedByServer,
      dismissedLatest: value.dismissedLatest
    };
    return JSON.stringify(state);
  }

  static decode(text: string): UpdatePersisted {
    const state: StoredState = JSON.parse(text) as StoredState;
    const out: UpdatePersisted = new UpdatePersisted();
    const r: StoredResult | null | undefined = state.result;
    if (r !== null && r !== undefined) {
      const listings: UpdateStoreListing[] = [];
      const stores: StoredListing[] = Array.isArray(r.stores) ? r.stores : [];
      for (const s of stores) {
        if (typeof s.store === 'string' && typeof s.version === 'string') {
          listings.push(new UpdateStoreListing(s.store, s.version));
        }
      }
      out.result = new UpdateCheckResult(PreferencesUpdateStore.text(r.minSupported),
        PreferencesUpdateStore.text(r.recommended), PreferencesUpdateStore.text(r.latest),
        PreferencesUpdateStore.text(r.defaultStore), listings,
        typeof r.recheckIntervalSec === 'number' ? r.recheckIntervalSec : DEFAULT_RECHECK_INTERVAL_SEC,
        PreferencesUpdateStore.text(r.updateTitle), PreferencesUpdateStore.text(r.updateNotes));
    }
    out.lastSuccessAtMillis = typeof state.lastSuccessAtMillis === 'number' ? state.lastSuccessAtMillis : null;
    out.forcedBy10405 = state.forcedBy10405 === true;
    out.forcedMinimum = PreferencesUpdateStore.text(state.forcedMinimum);
    out.forcedAppVersion = PreferencesUpdateStore.text(state.forcedAppVersion);
    out.forcedByServer = state.forcedByServer === true;
    out.dismissedLatest = PreferencesUpdateStore.text(state.dismissedLatest);
    return out;
  }

  private static text(value: string | null | undefined): string | null {
    return typeof value === 'string' ? value : null;
  }
}
