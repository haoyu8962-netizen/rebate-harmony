import {
  AgentChipTap, AgentConsentTicket, AgentErrorView, AgentPageTicket, AgentPhase, AgentReplyTicket, AgentReportSheetView,
  AgentRetryTap, AgentRunTicket, AgentSnapshot, AgentTurnView
} from 'core';
import {
  CouliAnnounce, CouliButton, CouliButtonSize, CouliButtonVariant, CouliColors, CouliFocus, CouliIcon,
  CouliInteraction, CouliLayout, CouliPasteButton, CouliRadius, CouliSpacing, CouliTextModifier, CouliTypography,
  EmptyState, ErrorState
} from 'designsystem';
import { AgentChipRow, AgentTurnItemView } from './AgentCards';
import { AgentConsentHost } from './AgentConsentDialog';
import { AgentScreenModel, AgentScreenPort, AgentTurnItem } from './AgentScreenModel';

/** entry 填入的页面模型（Agent Tab 一份；本模块不 import entry）。 */
export class AgentActions {
  static model: AgentScreenModel = new AgentScreenModel();
}

/**
 * 一次渲染的票据与参数（ForEach 单项：回调捕获这一项里的普通值，执行时只比较；键变了整项重建，@Builder 的按值参数随之更新）。
 */
class ComposerState {
  readonly page: AgentPageTicket;
  readonly stop: AgentRunTicket | null;
  readonly disabled: boolean;
  readonly quota: boolean;
  readonly ordersChip: AgentChipTap | null;
  readonly contextKey: string | null;
  readonly ready: boolean;

  constructor(s: AgentSnapshot, ready: boolean) {
    this.page = s.page;
    this.stop = s.stop;
    // 限流期、AI 同意没记录成功（待同意 / 提交中 / 失败）、只读过期会话（G09）时发送与胶囊都禁用（R1-01；执行层另有同一闸门）。
    this.disabled = s.sendBlocked || s.readOnly;
    this.quota = s.quotaExhausted;
    this.ordersChip = s.ordersChip;
    this.contextKey = s.contextLabelKey;
    this.ready = ready;
  }

  get key(): string {
    return [String(this.page.controller), String(this.page.conversation), this.stop === null ? '-' : this.stop.run,
      String(this.disabled), String(this.quota), this.contextKey ?? '-', String(this.ordersChip !== null),
      String(this.ready)].join('|');
  }
}

/** 离底部超过一屏高度的 1/4 视为「已上滑」（G30，代拟）：用列表最后一项是否可见近似。 */
const BOTTOM_SLACK_ITEMS: number = 0;

/**
 * 底部 Tab「AgentChat」的根页（APP-10）：页面骨架（03 §7.5）——顶部标题与【新对话】、公示（config.agent.filing_text，空串不显示）、
 * 空态（agent.welcome +「你可以这样问我」示例）、消息列表（List + LazyForEach，时间顺序即读屏顺序）、快捷胶囊（粘贴查返利 / 查订单）、
 * 输入框（500 字，发送中禁用并显示【停止】）、自动滚动与「回到底部」（读屏开启时不自动滚动，改为播报文字）。
 * 「未开放」态（G01）：不显示输入框、不弹同意框、不发请求。数据、票据与文字都由 Core 的 AgentController 给（视图只展示）。
 */
@ComponentV2
export struct AgentTabRoot {
  /** 只读打开（基本模式、强更检查结果未知）：不得自动发起写请求或授权（03 §4.4）。 */
  @Param readonlyMode: boolean = false;
  @Local model: AgentScreenModel = AgentActions.model;
  @Local atBottom: boolean = true;
  /** 举报半屏显示（快照里有半屏且页面可见；系统关闭时经 reportClose 回写，G29）。 */
  @Local sheetShown: boolean = false;
  /** 半屏内容（关闭动画期间保留上一份，不让内容先变空；ArkUI 内容为空时不响应关闭）。 */
  @Local sheetView: AgentReportSheetView | undefined = undefined;
  private instance: number = 0;
  private scroller: Scroller = new Scroller();
  private consent: AgentConsentHost | null = null;
  private lastAnnounced: string = '';
  private lastCount: number = 0;

  aboutToAppear(): void {
    this.consent = new AgentConsentHost(this.getUIContext());
    this.instance = this.model.port.pageAppear();
    // 共性第 32 条：跟随状态随页面票据恢复（同一控制器、同一对话时沿用上次的阅读位置状态）。
    this.atBottom = this.model.followTicket === this.followKey() ? this.model.following : true;
    this.syncList();
  }

  private followKey(): string {
    return String(this.model.snapshot.page.controller) + '|' + String(this.model.snapshot.page.conversation);
  }

  @Monitor('atBottom')
  onFollow(_m: IMonitor): void {
    this.model.followTicket = this.followKey();
    this.model.following = this.atBottom;
  }

  aboutToDisappear(): void {
    // 页面实例销毁是同步出口：先关本实例的同意弹窗（不提交），再作废这个实例的控制器（page_destroyed）。
    this.consent?.close();
    this.model.port.pageDisappear(this.instance);
  }

  private t(key: string): string {
    return this.model.port.text(key);
  }

  /** 发送闸门限流期或 AI 同意没记录成功：胶囊、追问、卡片置灰（R1-01）。 */
  private blockedSend(): boolean {
    return this.model.snapshot.sendBlocked;
  }

  /** 消息内【重试】/【刷新】（harmony-review-r2 R2-06）：重连查询与刷新用读取闸门，同键重发与新消息用发送闸门。 */
  private retryBlocked(turn: AgentTurnView): boolean {
    const e: AgentErrorView | null = turn.error;
    const r: AgentRetryTap | null = e === null ? null : e.retry;
    return r === null ? this.blockedSend() : this.model.snapshot.retryDisabled(r.mode);
  }

  @Monitor('model.snapshot')
  onSnapshot(_m: IMonitor): void {
    this.syncList();
    this.syncSheet();
    this.syncConsent();
    const s: AgentSnapshot = this.model.snapshot;
    if (this.model.screenReader) {
      // 读屏开启：不自动滚动；新内容只播报文字（不播报金额）。
      if (s.announcement.length > 0 && s.announcement !== this.lastAnnounced) {
        this.lastAnnounced = s.announcement;
        CouliAnnounce.say(this.getUIContext(), s.announcement);
      }
      return;
    }
    if (this.atBottom && s.turns.length > 0) {
      setTimeout(() => {
        this.scroller.scrollEdge(Edge.Bottom);
      }, 0);
    }
  }

  @Monitor('model.visible', 'model.blocked')
  onVisible(_m: IMonitor): void {
    this.syncConsent();
    this.syncSheet();
  }

  private syncSheet(): void {
    const shown: boolean = this.model.snapshot.reportSheet !== null && this.model.visible;
    if (this.model.snapshot.reportSheet !== null) {
      this.sheetView = this.model.snapshot.reportSheet as AgentReportSheetView;
    }
    if (shown !== this.sheetShown) {
      this.sheetShown = shown;
    }
  }

  private syncList(): void {
    const s: AgentSnapshot = this.model.snapshot;
    this.model.source.replace(s.turns, s.revision);
    this.lastCount = s.turns.length;
  }

  /**
   * 同意弹窗只在「票据仍是此刻那一张、页面可见、没有阻挡层」时显示（R1-10，APP-11 第 18、21、22 条）：任一条件不满足就同步收起本实例
   * （不提交、不算拒绝），条件恢复后按同一张票据再显示；异步打开完成后由 AgentConsentHost 再核对一次，不满足立即收起。
   */
  private syncConsent(): void {
    const host: AgentConsentHost | null = this.consent;
    if (host === null) {
      return;
    }
    const ticket: AgentConsentTicket | null = this.model.snapshot.consent;
    const showable: boolean = ticket !== null && this.model.visible && !this.model.blocked
      && this.model.port.consentBeforeOpen(ticket as AgentConsentTicket);
    if (!showable) {
      if (host.openSerial !== 0) {
        host.close();
      }
      return;
    }
    const t: AgentConsentTicket = ticket as AgentConsentTicket;
    if (host.openSerial === t.serial) {
      return;
    }
    host.open(t, this.model.port, (): boolean => this.model.visible && !this.model.blocked
      && this.model.port.consentBeforeOpen(t));
  }

  @Builder
  header(page: AgentPageTicket, ready: boolean) {
    Column({ space: CouliSpacing.space1 }) {
      Row() {
        Text(this.t('agent.name'))
          .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary))
          .layoutWeight(1)
          .accessibilityLevel('yes')
        if (ready) {
          Row({ space: CouliSpacing.space1 }) {
            CouliIcon({ name: 'chat', iconSize: 18, color: CouliColors.textPrimary })
            Text(this.t('agent.draft.new_chat'))
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
          }
          .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: CouliInteraction.minTouchTarget })
          .padding({ left: CouliSpacing.space2, right: CouliSpacing.space2 })
          .accessibilityGroup(true)
          .accessibilityRole(AccessibilityRoleType.BUTTON)
          .accessibilityText(this.t('agent.draft.new_chat'))
          .focusable(true)
          .focusBox(CouliFocus.box)
          .onClick(() => {
            this.model.port.newChat(page);
          })
        }
      }
      .width('100%')
      if (this.model.snapshot.filingText.length > 0) {
        Text(this.model.snapshot.filingText)
          .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
          .width('100%')
      }
    }
    .width('100%')
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space2,
      bottom: CouliSpacing.space2 })
    .backgroundColor(CouliColors.backgroundSurface)
  }

  @Builder
  emptyState() {
    Scroll() {
      Column({ space: CouliSpacing.space4 }) {
        Text(this.t('agent.welcome'))
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
          .width('100%')
        if (this.model.snapshot.examples.length > 0) {
          Text(this.t('agent.draft.examples_title'))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          AgentChipRow({
            chips: this.model.snapshot.examples,
            disabled: this.model.snapshot.sending || this.blockedSend() || this.model.snapshot.quotaExhausted,
            port: this.model.port
          })
        }
      }
      .width('100%')
      .padding(CouliSpacing.space4)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
  }

  @Builder
  messages() {
    Stack({ alignContent: Alignment.Bottom }) {
      List({ scroller: this.scroller }) {
        if (this.model.snapshot.earlier !== 'hidden') {
          ListItem() {
            // @Builder 按值传参不随状态刷新：按状态做键重建（「加载中 / 没有更早的」跟着变）。
            Column() {
              ForEach([this.model.snapshot.earlier], (state: string) => {
                this.earlierRow(this.model.snapshot.page, state, this.model.snapshot.earlierDisabled,
                  this.model.snapshot.loadErrorText)
              }, (state: string) => 'earlier|' + state + '|' + String(this.model.snapshot.page.conversation) + '|'
                + String(this.model.snapshot.earlierDisabled) + '|' + this.model.snapshot.loadErrorText)
            }
          }
        }
        LazyForEach(this.model.source, (item: AgentTurnItem) => {
          ListItem() {
            AgentTurnItemView({
              turn: item.turn, port: this.model.port, busy: this.model.snapshot.sending,
              limited: this.blockedSend(), retryLimited: this.retryBlocked(item.turn),
              actionLimited: this.model.snapshot.actionDisabled
            })
          }
        }, (item: AgentTurnItem) => item.key)
        if (this.model.snapshot.sessionNotice.length > 0) {
          ListItem() {
            Column() {
              ForEach([this.model.snapshot.sessionNotice], (text: string) => {
                this.sessionNotice(this.model.snapshot.page, text)
              }, (text: string) => 'notice|' + text + '|' + String(this.model.snapshot.page.conversation))
            }
          }
        }
      }
      .width('100%')
      .height('100%')
      .edgeEffect(EdgeEffect.Spring)
      .onReachStart(() => {
        // 滚到顶部（第一条消息进入可见区）：取更早一页（G08；一次只在途一页、读取闸门期间不取由 Core 判断）。
        if (this.model.snapshot.earlier === 'more') {
          this.model.port.loadEarlier(this.model.snapshot.page);
        }
      })
      .onScrollIndex((_start: number, end: number) => {
        this.atBottom = end >= this.model.source.totalCount() - 1 - BOTTOM_SLACK_ITEMS;
      })
      .onReachEnd(() => {
        this.atBottom = true;
      })
      if (!this.atBottom) {
        Row({ space: CouliSpacing.space1 }) {
          CouliIcon({ name: 'chevron-down', iconSize: 16, color: CouliColors.textPrimary })
          Text(this.t('agent.draft.back_to_bottom'))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
        }
        .padding({ left: CouliSpacing.space3, right: CouliSpacing.space3 })
        .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
        .backgroundColor(CouliColors.backgroundSurface)
        .borderRadius(CouliRadius.pill)
        .border({ width: 1, color: CouliColors.borderSubtle })
        .margin({ bottom: CouliSpacing.space3 })
        .accessibilityGroup(true)
        .accessibilityRole(AccessibilityRoleType.BUTTON)
        .accessibilityText(this.t('agent.draft.back_to_bottom'))
        .focusable(true)
        .focusBox(CouliFocus.box)
        .onClick(() => {
          this.atBottom = true;
          this.scroller.scrollEdge(Edge.Bottom);
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 「加载更早的消息」/ 加载中 /「没有更早的消息」/ 加载失败（G08；文案 TODO(N-38)）。读取闸门期间不可点（R2-06）；失败时有统一文案（5xxxx 带
   * trace6）就显示它（R2-05）。
   */
  @Builder
  earlierRow(page: AgentPageTicket, state: string, disabled: boolean, failedText: string) {
    Row({ space: CouliSpacing.space2 }) {
      if (state === 'loading') {
        LoadingProgress()
          .width(16)
          .height(16)
          .color(CouliColors.textSecondary)
      }
      Text(state === 'failed' && failedText.length > 0 ? failedText : this.t(state === 'none' ? 'agent.draft.history.none' :
        state === 'failed' ? 'agent.draft.history.failed' : 'agent.draft.history.earlier'))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
    .accessibilityGroup(true)
    .focusable(state === 'more' || state === 'failed')
    .focusBox(CouliFocus.box)
    .enabled(!disabled)
    .opacity(disabled && (state === 'more' || state === 'failed') ? 0.5 : 1)
    .onClick(() => {
      if ((state === 'more' || state === 'failed') && !this.model.snapshot.earlierDisabled) {
        this.model.port.loadEarlier(page);
      }
    })
  }

  /** 会话提示（过期只读、历史 30504）：error.30504 +【新对话】（G09）。 */
  @Builder
  sessionNotice(page: AgentPageTicket, text: string) {
    Column({ space: CouliSpacing.space2 }) {
      Text(text)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        .textAlign(TextAlign.Center)
      CouliButton({
        text: this.t('agent.draft.new_chat'),
        variant: CouliButtonVariant.SECONDARY,
        buttonSize: CouliButtonSize.COMPACT,
        buttonId: 'agent-session-new-chat',
        onTap: () => {
          this.model.port.newChat(page);
        }
      })
    }
    .width('100%')
    .padding(CouliSpacing.space4)
    .alignItems(HorizontalAlign.Center)
  }

  /** 举报半屏（AgentReport 稿）：内容是独立组件（@Param 随快照刷新）。 */
  @Builder
  reportSheet() {
    AgentReportSheetContent({ view: this.sheetView, port: this.model.port,
      actionLimited: this.model.snapshot.actionDisabled })
  }

  /** 快捷胶囊 + 输入框（page：渲染时的对话票据；回调只比较）。 */
  @Builder
  composer(page: AgentPageTicket, stop: AgentRunTicket | null, disabled: boolean, quota: boolean,
    ordersChip: AgentChipTap | null, contextKey: string | null) {
    Column({ space: CouliSpacing.space2 }) {
      if (contextKey !== null) {
        Text(this.t(contextKey as string))
          .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
          .padding({ left: CouliSpacing.space2, right: CouliSpacing.space2, top: 2, bottom: 2 })
          .backgroundColor(CouliColors.backgroundMuted)
          .borderRadius(CouliRadius.pill)
      }
      Row({ space: CouliSpacing.space2 }) {
        // 粘贴查返利（BR-ID-16）：系统 PasteButton，读到的文字填进输入框，由用户点发送（不自动发送剪贴板内容，G29）。
        CouliPasteButton({
          disabled: disabled || stop !== null,
          buttonId: 'agent-paste',
          tinted: true,
          onResult: (success: boolean) => {
            if (!success) {
              return;
            }
            this.model.port.paste(page).then((text: string | null) => {
              if (text !== null && this.model.snapshot.conversation === page.conversation
                && this.model.snapshot.owner === page.controller) {
                this.model.draft = text;
                this.model.draftConversation = page.conversation;
              }
            });
          }
        })
        Text(this.t('agent.draft.chip.paste'))
          .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        if (ordersChip !== null) {
          AgentChipRow({ chips: [ordersChip as AgentChipTap], disabled: disabled || stop !== null, port: this.model.port })
            .layoutWeight(1)
        }
      }
      .width('100%')
      Row({ space: CouliSpacing.space2 }) {
        TextInput({
          text: this.model.draftConversation === page.conversation ? this.model.draft : '',
          placeholder: quota ? this.t('agent.draft.quota.input_disabled') : this.t('agent.draft.input_placeholder')
        })
          .layoutWeight(1)
          .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
          .enabled(!quota && !disabled)
          .maxLength(1000)
          .onChange((value: string) => {
            // 输入只写进渲染时那一个对话世代（APP-09 第 59 条）。
            if (this.model.snapshot.conversation === page.conversation && this.model.snapshot.owner === page.controller) {
              this.model.draft = value;
              this.model.draftConversation = page.conversation;
            }
          })
          .onSubmit(() => {
            if (this.model.port.send(page, this.model.draft)) {
              this.model.draft = '';
            }
          })
        if (stop !== null) {
          CouliButton({
            text: this.t('agent.draft.stop'),
            variant: CouliButtonVariant.SECONDARY,
            buttonSize: CouliButtonSize.COMPACT,
            buttonId: 'agent-stop',
            onTap: () => {
              this.model.port.stop(stop as AgentRunTicket);
            }
          })
        } else {
          CouliButton({
            text: this.t('agent.draft.send'),
            variant: CouliButtonVariant.PRIMARY,
            buttonSize: CouliButtonSize.COMPACT,
            disabled: disabled || quota || this.model.draft.trim().length === 0,
            buttonId: 'agent-send',
            onTap: () => {
              if (this.model.port.send(page, this.model.draft)) {
                this.model.draft = '';
              }
            }
          })
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space2,
      bottom: CouliSpacing.space2 })
    .backgroundColor(CouliColors.backgroundSurface)
  }

  @Builder
  ready() {
    Column() {
      Column() {
        if (this.model.snapshot.turns.length === 0) {
          this.emptyState()
        } else {
          this.messages()
        }
      }
      .layoutWeight(1)
      .width('100%')
      ForEach([new ComposerState(this.model.snapshot, true)], (c: ComposerState) => {
        this.composer(c.page, c.stop, c.disabled, c.quota, c.ordersChip, c.contextKey)
      }, (c: ComposerState) => c.key)
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Column() {
      ForEach([new ComposerState(this.model.snapshot,
        this.model.snapshot.phase === AgentPhase.READY && !this.readonlyMode)], (c: ComposerState) => {
        this.header(c.page, c.ready)
      }, (c: ComposerState) => 'header|' + c.key)
      Column() {
        if (this.readonlyMode || this.model.snapshot.phase === AgentPhase.BLOCKED
          || this.model.snapshot.phase === AgentPhase.IDLE) {
          Blank()
        } else if (this.model.snapshot.phase === AgentPhase.UNAVAILABLE) {
          EmptyState({
            icon: 'chat',
            title: this.t('error.30501'),
            message: this.t('agent.draft.unavailable_hint')
          })
        } else if (this.model.snapshot.phase === AgentPhase.LOADING) {
          Column() {
            LoadingProgress()
              .width(32)
              .height(32)
              .color(CouliColors.textSecondary)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.model.snapshot.phase === AgentPhase.LOAD_FAILED) {
          ForEach([this.model.snapshot.page], (page: AgentPageTicket) => {
            ErrorState({
              title: this.model.snapshot.loadErrorText,
              retryText: this.t('agent.draft.retry'),
              // R2-06：整页加载（取当前会话 + 历史首页）的【重试】受读取闸门控制。
              retryDisabled: this.model.snapshot.loadRetryDisabled,
              onRetry: () => {
                this.model.port.retryLoad(page);
              }
            })
          }, (page: AgentPageTicket) => 'load|' + page.controller + '|' + page.conversation)
        } else if (this.model.snapshot.phase === AgentPhase.CONSENT_DECLINED) {
          Column({ space: CouliSpacing.space4 }) {
            Text(this.t(this.model.snapshot.consentFailed ? 'agent.draft.consent.failed' : 'agent.draft.consent.declined'))
              .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
              .textAlign(TextAlign.Center)
            ForEach([this.model.snapshot.page], (page: AgentPageTicket) => {
              CouliButton({
                text: this.t('agent.draft.consent.reagree'),
                variant: CouliButtonVariant.PRIMARY,
                buttonId: 'agent-consent-reagree',
                onTap: () => {
                  this.model.port.consentReopen(page);
                }
              })
            }, (page: AgentPageTicket) => 'reagree|' + page.controller + '|' + page.conversation)
          }
          .width('100%')
          .height('100%')
          .padding(CouliSpacing.space6)
          .justifyContent(FlexAlign.Center)
        } else {
          this.ready()
        }
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
    .backgroundColor(CouliColors.backgroundCanvas)
    .bindSheet(this.sheetShown!!, this.reportSheet(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: true,
      onWillDismiss: (action: DismissSheetAction) => {
        // 系统返回、点遮罩、关闭按钮：只关本实例（不提交、不导航，G29）。
        action.dismiss();
      },
      onDisappear: () => {
        this.sheetShown = false;
        const v: AgentReportSheetView | null = this.model.snapshot.reportSheet;
        if (v !== null) {
          this.model.port.reportClose((v as AgentReportSheetView).ticket);
        }
      }
    })
  }
}

/** Tab 注册表用的入口（entry 以 wrapBuilder 登记到路由名 AgentChat；entry 也可以在外面叠购买浮层）。 */
@Builder
export function agentTabRootBuilder(readonlyMode: boolean) {
  AgentTabRoot({ readonlyMode: readonlyMode })
}

/** 举报半屏内容（AgentReport 稿）：被举报回复的摘要、五个原因单选、补充说明（选填）、【提交举报】。只在内存；回调只交回渲染时的回复票据。 */
@ComponentV2
struct AgentReportSheetContent {
  @Param view: AgentReportSheetView | undefined = undefined;
  @Param port: AgentScreenPort | undefined = undefined;
  @Param actionLimited: boolean = false;

  private t(key: string): string {
    return this.port?.text(key) ?? '';
  }

  @Builder
  reasonRow(v: AgentReportSheetView, reason: string) {
    Row({ space: CouliSpacing.space2 }) {
      Radio({ value: reason, group: 'agent-report-reason' })
        .checked(v.selected === reason)
        .enabled(!v.submitting)
        .hitTestBehavior(HitTestMode.None)
      Text(reason)
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
        .layoutWeight(1)
    }
    .width('100%')
    .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
    .accessibilityGroup(true)
    .accessibilityRole(AccessibilityRoleType.RADIO)
    .accessibilityChecked(v.selected === reason)
    .accessibilityText(reason)
    .focusable(true)
    .focusBox(CouliFocus.box)
    .onClick(() => {
      if (!v.submitting) {
        this.port?.reportEdit(v.ticket, reason, v.supplement);
      }
    })
  }

  build() {
    if (this.view !== undefined) {
      Scroll() {
        Column({ space: CouliSpacing.space3 }) {
          Text(this.t('agent.draft.report.title'))
            .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary))
            .accessibilityLevel('yes')
          Text(this.t('agent.draft.report.subtitle'))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          Text(this.view.quote)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding(CouliSpacing.space3)
            .width('100%')
            .backgroundColor(CouliColors.backgroundMuted)
            .borderRadius(CouliRadius.card)
          ForEach(this.view.reasons, (reason: string) => {
            this.reasonRow(this.view as AgentReportSheetView, reason)
          }, (reason: string) => reason + ':' + String((this.view as AgentReportSheetView).selected === reason))
          if (this.view.inlineError) {
            Text(this.t('agent.draft.report.reason_error'))
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusWarningText))
          }
          TextArea({ text: this.view.supplement, placeholder: this.t('agent.draft.report.supplement') })
            .width('100%')
            .height(88)
            .maxLength(this.view.supplementLimit)
            .enabled(!this.view.submitting)
            .onChange((value: string) => {
              const v: AgentReportSheetView | undefined = this.view;
              if (v !== undefined) {
                this.port?.reportEdit(v.ticket, v.selected, value);
              }
            })
          CouliButton({
            text: this.t('agent.draft.report.submit'),
            variant: CouliButtonVariant.PRIMARY,
            fullWidth: true,
            disabled: this.view.selected === null || this.view.submitting || this.actionLimited,
            buttonId: 'agent-report-submit',
            onTap: () => {
              const v: AgentReportSheetView | undefined = this.view;
              if (v !== undefined) {
                this.port?.reportSubmit(v.ticket);
              }
            }
          })
        }
        .width('100%')
        .padding(CouliSpacing.space4)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
    }
  }
}
