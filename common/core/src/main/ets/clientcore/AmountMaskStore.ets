// 金额隐藏开关的本机偏好（BR-TEXT-10 细则「金额隐藏」；APP-09 rule-gaps G24）：订单页（APP-08）、钱包页（APP-09）与以后的「我的」页
// （APP-12）共用同一份。原在 entry/orders/AppOrders.ets，按 G24 挪到 Core；存储名与键不变（Preferences couli_device_prefs /
// amount_mask.hidden，不做迁移）。仍是本机偏好：不随账号、不随环境清除、不上传（不在 CouliPreferences.ALL_NAMESPACES 里）。
// 任一页面切换后同步通知其他页面（AC-S1-105：在钱包点眼睛，订单页也随之隐藏）。
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/** 偏好的读写端口（生产：Preferences；测试：内存）。写失败返回 false。 */
export interface AmountMaskBackend {
  read(): boolean;

  write(hidden: boolean): boolean;
}

/** 内存实现（单测与未接上下文时）。 */
export class MemoryAmountMaskBackend implements AmountMaskBackend {
  hidden: boolean = false;
  writes: number = 0;

  read(): boolean {
    return this.hidden;
  }

  write(hidden: boolean): boolean {
    this.writes++;
    this.hidden = hidden;
    return true;
  }
}

/** Preferences 实现：couli_device_prefs / amount_mask.hidden（APP-08 起的存储名与键，不变）。 */
export class PreferencesAmountMaskBackend implements AmountMaskBackend {
  static readonly NAMESPACE: string = 'couli_device_prefs';
  static readonly KEY: string = 'amount_mask.hidden';
  private readonly context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  private prefs(): preferences.Preferences | null {
    try {
      return preferences.getPreferencesSync(this.context, { name: PreferencesAmountMaskBackend.NAMESPACE });
    } catch (e) {
      return null;
    }
  }

  read(): boolean {
    const p: preferences.Preferences | null = this.prefs();
    if (p === null) {
      return false;
    }
    try {
      return p.getSync(PreferencesAmountMaskBackend.KEY, false) === true;
    } catch (e) {
      return false;
    }
  }

  write(hidden: boolean): boolean {
    const p: preferences.Preferences | null = this.prefs();
    if (p === null) {
      return false;
    }
    try {
      p.putSync(PreferencesAmountMaskBackend.KEY, hidden);
      p.flushSync();
      return true;
    } catch (e) {
      return false;
    }
  }
}

/** 金额隐藏开关（进程一份）。读不出按「不隐藏」；写不进时本进程内仍按用户的选择显示。 */
export class AmountMaskStore {
  static readonly shared: AmountMaskStore = new AmountMaskStore();
  private backend: AmountMaskBackend = new MemoryAmountMaskBackend();
  private value: boolean = false;
  private loaded: boolean = false;
  private listeners: ((hidden: boolean) => void)[] = [];

  /** EntryAbility.onCreate 接上 Preferences（之前读写按内存）。 */
  attach(backend: AmountMaskBackend): void {
    this.backend = backend;
    this.loaded = false;
    this.notify();
  }

  get hidden(): boolean {
    if (!this.loaded) {
      this.loaded = true;
      try {
        this.value = this.backend.read();
      } catch (e) {
        this.value = false;
      }
    }
    return this.value;
  }

  /** 设置并落盘，通知全部页面（不上传、不随账号）。 */
  set(hidden: boolean): void {
    this.loaded = true;
    this.value = hidden;
    try {
      this.backend.write(hidden);
    } catch (e) {
      // 写不进：本进程内照用户的选择显示。
    }
    this.notify();
  }

  toggle(): boolean {
    this.set(!this.hidden);
    return this.value;
  }

  /** 订阅变化；返回取消订阅。 */
  subscribe(listener: (hidden: boolean) => void): () => void {
    this.listeners.push(listener);
    return (): void => {
      this.listeners = this.listeners.filter((l: (hidden: boolean) => void): boolean => l !== listener);
    };
  }

  private notify(): void {
    const v: boolean = this.hidden;
    for (const l of this.listeners.slice()) {
      try {
        l(v);
      } catch (e) {
        // 订阅方出错不影响其他页面。
      }
    }
  }
}
