import {
  AgentBuyTap, AgentChipTap, AgentConsentTicket, AgentPageTicket, AgentRetryTap, AgentRunTicket, AgentSnapshot, AgentTap,
  AgentTurnView
} from 'core';
import { ProductCardData } from 'designsystem';

/**
 * Agent 页的执行出口（entry 的 AppAgent 实现；本模块不 import entry）。所有回调只交回渲染时生成的不可变票据（AgentTap、AgentBuyTap、
 * AgentChipTap、AgentRetryTap、AgentRunTicket、AgentPageTicket、AgentConsentTicket），执行层只比较；界面不在回调执行时重新读当前快照
 * （APP-09 第 63 条，APP-11 第 1 条）。
 */
export interface AgentScreenPort {
  /** 页面实例出现 / 消失（Tab 根页创建与销毁）：消失是同步出口，作废这个实例的控制器（page_destroyed）。 */
  pageAppear(): number;

  pageDisappear(instance: number): void;

  send(t: AgentPageTicket, text: string): boolean;

  stop(t: AgentRunTicket): void;

  newChat(t: AgentPageTicket): void;

  chip(t: AgentChipTap): void;

  tap(t: AgentTap): void;

  buy(t: AgentBuyTap): void;

  retry(t: AgentRetryTap): void;

  retryLoad(t: AgentPageTicket): void;

  consentAgree(t: AgentConsentTicket): void;

  consentDecline(t: AgentConsentTicket): void;

  consentDismissed(t: AgentConsentTicket): void;

  consentReopen(t: AgentPageTicket): void;

  /** 真正打开同意弹窗之前的复核：票据仍是此刻的那一个、页面可见、没有其他弹层。 */
  consentBeforeOpen(t: AgentConsentTicket): boolean;

  /** 粘贴胶囊（PasteButton 临时授权成功后读剪贴板）：读到的文字只写进发起时那一个控制器与对话世代的输入框（APP-09 第 59 条）。 */
  paste(t: AgentPageTicket): Promise<string | null>;

  /** 商品项（契约 ProductCard JSON）→ 卡片显示数据（DesignSystem 的同一映射，不做计算）。 */
  productCard(json: Record<string, Object>): ProductCardData;

  /** 文案（契约 → Agent 草稿表）。 */
  text(key: string): string;
}

class NoopPort implements AgentScreenPort {
  pageAppear(): number {
    return 0;
  }

  pageDisappear(_instance: number): void {
  }

  send(_t: AgentPageTicket, _text: string): boolean {
    return false;
  }

  stop(_t: AgentRunTicket): void {
  }

  newChat(_t: AgentPageTicket): void {
  }

  chip(_t: AgentChipTap): void {
  }

  tap(_t: AgentTap): void {
  }

  buy(_t: AgentBuyTap): void {
  }

  retry(_t: AgentRetryTap): void {
  }

  retryLoad(_t: AgentPageTicket): void {
  }

  consentAgree(_t: AgentConsentTicket): void {
  }

  consentDecline(_t: AgentConsentTicket): void {
  }

  consentDismissed(_t: AgentConsentTicket): void {
  }

  consentReopen(_t: AgentPageTicket): void {
  }

  consentBeforeOpen(_t: AgentConsentTicket): boolean {
    return false;
  }

  paste(_t: AgentPageTicket): Promise<string | null> {
    return Promise.resolve(null);
  }

  productCard(_json: Record<string, Object>): ProductCardData {
    return new ProductCardData();
  }

  text(_key: string): string {
    return '';
  }
}

/** 一条消息的列表项（LazyForEach 数据源用；键含快照版本，内容变化时重建这一项）。 */
export class AgentTurnItem {
  readonly turn: AgentTurnView;
  readonly key: string;

  constructor(turn: AgentTurnView, revision: number) {
    this.turn = turn;
    this.key = turn.key + ':' + String(revision);
  }
}

/** 消息列表的数据源（只在内存；不落盘）。 */
export class AgentTurnSource implements IDataSource {
  private items: AgentTurnItem[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): AgentTurnItem {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners = this.listeners.filter((l: DataChangeListener): boolean => l !== listener);
  }

  replace(turns: AgentTurnView[], revision: number): void {
    this.items = turns.map((t: AgentTurnView): AgentTurnItem => new AgentTurnItem(t, revision));
    for (const l of this.listeners) {
      l.onDataReloaded();
    }
  }
}

/** Agent 页的可观察状态（entry 在控制器 onChange 时整体替换快照）。 */
@ObservedV2
export class AgentScreenModel {
  @Trace snapshot: AgentSnapshot = new AgentSnapshot();
  /** 读屏开启：不自动滚动到底部，新内容用无障碍播报（APP-11 第 14、20 条）。 */
  @Trace screenReader: boolean = false;
  /** Agent Tab 选中且在前台、没有被别的页盖住（同意弹窗打开前复核）。 */
  @Trace visible: boolean = false;
  /** 有阻挡层（隐私弹窗、强更、更新提示、客服半屏、权限说明）：同意弹窗收起，阻挡层消失后再显示（R1-10）。 */
  @Trace blocked: boolean = false;
  /** 输入框草稿（只在内存；切 Tab 回来保留；不含金额，G15）。绑定写入时的对话世代（APP-09 第 59 条）。 */
  @Trace draft: string = '';
  draftConversation: number = 0;
  /** Release 构建或当前环境不提供 Agent（G01）。 */
  @Trace unavailableBuild: boolean = false;
  port: AgentScreenPort = new NoopPort();
  readonly source: AgentTurnSource = new AgentTurnSource();
}
