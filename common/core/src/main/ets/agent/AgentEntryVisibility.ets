// APP-10b G56（FU-HM-0715）：Config features.flags['agent.entry.visible'] 的 App 级可见性。false 时底部 AI 助手 Tab 换成「搜索」
// （ShellState），首页【问 AI】、商品详情与订单详情【问问 AI】一起隐藏，且点击入口在打开之前再现读一次——隐藏后不可达，不再打开
// 「未开放」页。页面订阅它（不在 Core 里放 @ObservedV2：Local Test 环境）；它订阅 ConfigStore 的变化。
import { ConfigStore } from '../clientcore/ConfigStore';

export type AgentEntryListener = (visible: boolean) => void;

export class AgentEntryVisibility {
  private static instance: AgentEntryVisibility | null = null;

  /** App 共用的一份（entry 的 AppAgent 接配置；页面订阅）。 */
  static get shared(): AgentEntryVisibility {
    if (AgentEntryVisibility.instance === null) {
      AgentEntryVisibility.instance = new AgentEntryVisibility();
    }
    return AgentEntryVisibility.instance as AgentEntryVisibility;
  }

  /** features JSON（Config 的 features 键）→ 入口开关：缺省、读不出、格式不对都按可见；只认 false 为关。 */
  static fromFeatures(text: string | null): boolean {
    if (text === null) {
      return true;
    }
    try {
      const features: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      if (features === null || typeof features !== 'object') {
        return true;
      }
      const flags: Object | undefined = features['flags'];
      if (flags === undefined || flags === null || typeof flags !== 'object') {
        return true;
      }
      return (flags as Record<string, Object>)['agent.entry.visible'] !== false;
    } catch (e) {
      return true;
    }
  }

  private source: () => boolean = () => true;
  private last: boolean = true;
  private listeners: AgentEntryListener[] = [];
  private unsubscribeConfig: (() => void) | null = null;
  private boundStore: ConfigStore | null = null;

  /**
   * 接入口开关的来源（现读；App：AppAgent.entryVisible，含 Debug 的截图覆盖）并订阅配置变化。同一 store 只订阅一次；换 store 时先退订旧的。
   */
  bind(store: ConfigStore | null, source: () => boolean): void {
    this.source = source;
    if (store !== this.boundStore) {
      const off: (() => void) | null = this.unsubscribeConfig;
      this.unsubscribeConfig = null;
      if (off !== null) {
        off();
      }
      this.boundStore = store;
      if (store !== null) {
        this.unsubscribeConfig = store.subscribe((): void => {
          this.refresh();
        });
      }
    }
    this.refresh();
  }

  /** 此刻是否可见（现读一次来源；变了同步通知订阅者）。 */
  refresh(): boolean {
    let now: boolean = true;
    try {
      now = this.source();
    } catch (e) {
      now = true;
    }
    if (now !== this.last) {
      this.last = now;
      for (const listener of this.listeners.slice()) {
        try {
          listener(now);
        } catch (e) {
          // 一个页面出错不影响别的订阅者。
        }
      }
    }
    return now;
  }

  /** 上次读到的值（页面初值；不触发读取）。 */
  get visible(): boolean {
    return this.last;
  }

  /** 订阅变化（页面 aboutToAppear 订阅、aboutToDisappear 退订）；返回退订函数。 */
  subscribe(listener: AgentEntryListener): () => void {
    this.listeners.push(listener);
    return (): void => {
      const i: number = this.listeners.indexOf(listener);
      if (i >= 0) {
        this.listeners.splice(i, 1);
      }
    };
  }

  /** 入口点击：打开之前再现读一次，不可见就不执行（返回 false）——隐藏后残留的旧按钮也打不开 Agent 页。 */
  guard(action: () => void): boolean {
    if (!this.refresh()) {
      return false;
    }
    action();
    return true;
  }
}

/**
 * 来源页的【问问 AI】入口（FU-HM-0715 R1-05，订单详情）：构造详情时一次性固定文字与动作（动作里带构造时取得的来源票据与固定的
 * 订单标识，归属校验仍在 AppAgent.openWithContext / AgentContextHandoff），显示与否动态——入口开关（AgentEntryVisibility，订阅 Config 变化）
 * 加 allowed（现读：agent.enabled、隐私同意等）。入口开关关着时建页，之后 Config 打开，原页直接显示入口，不用退出重进。
 */
export class AgentAskEntry {
  /** 构造时固定的文字（空串不显示）。 */
  readonly text: string;
  private readonly visibility: AgentEntryVisibility;
  private readonly allowed: () => boolean;
  private readonly action: () => void;

  constructor(visibility: AgentEntryVisibility, text: string, allowed: () => boolean, action: () => void) {
    this.visibility = visibility;
    this.text = text;
    this.allowed = allowed;
    this.action = action;
  }

  /** 此刻是否显示（入口开关用最近一次的值，allowed 现读；读不出按不显示）。 */
  get shown(): boolean {
    if (this.text.length === 0 || !this.visibility.visible) {
      return false;
    }
    try {
      return this.allowed();
    } catch (e) {
      return false;
    }
  }

  /** 现读一次入口开关后的显示结论（页面 aboutToAppear 用）。 */
  refresh(): boolean {
    this.visibility.refresh();
    return this.shown;
  }

  /** 入口开关变化时交出新的显示结论；返回退订函数（页面 aboutToDisappear 调）。 */
  subscribe(listener: (shown: boolean) => void): () => void {
    return this.visibility.subscribe((_visible: boolean): void => {
      listener(this.shown);
    });
  }

  /** 点击：打开之前现读，不显示就不执行（返回 false）；执行的是构造时固定的动作（来源票据不重新取）。 */
  tap(): boolean {
    if (!this.refresh()) {
      return false;
    }
    this.action();
    return true;
  }
}
