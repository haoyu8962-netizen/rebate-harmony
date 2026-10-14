import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { CouliColors } from '../CouliColors';
import { CouliFocus, CouliInteraction, CouliRadius, CouliSpacing } from '../CouliMetrics';
import { CouliFontWeight, CouliTypography } from '../CouliTypography';
import { CouliButton } from './Basics';
import { CodeCellLayout } from './CodeCells';
import { CouliIcon } from './CouliIcon';
import { CouliTextModifier, TABULAR_FEATURE } from './CouliText';
import { CouliFontScale } from './FontScale';
import { CouliAnnounce } from './States';

// 二次验证面板（StepUpSheet）的纯视图：APP-13a §3 鸿蒙——从 features/wallet 挪到 DesignSystem，钱包（提现、收款账号）与「我的」
// （申请注销、换手机号）共用。Feature 之间不能依赖，所以视图放这里、只认本文件的驱动接口（StepUpPanelDriver）；执行器仍在 Core
// （stepup/StepUpController），由各 Feature 用几行接线把执行器的快照推给驱动。行为与 APP-09 的面板完全相同（R1-11、R2-09、第 48 条）。

/** 面板要显示的状态（执行器快照的视图投影）。 */
export class StepUpPanelState {
  sent: boolean = false;
  sending: boolean = false;
  countdown: number = 0;
  code: string = '';
  errorText: string = '';
  /** 新错误加 1（据此 assertive 播报一次）。 */
  errorSeq: number = 0;
  noPhone: boolean = false;
  sendBlocked: boolean = false;
  verifyBlocked: boolean = false;
  /** 清空输入的次数（据此把焦点放回输入框）。 */
  clearSeq: number = 0;
  verifying: boolean = false;
}

/** 面板文字（Feature 按 action 给出标题；其余取同一套 step_up.* 草稿键）。 */
export class StepUpPanelTexts {
  title: string = '';
  sent: string = '';
  close: string = '';
  resend: string = '';
  submit: string = '';
  codeSpoken: (n: number) => string = (_n: number) => '';
  resendIn: (n: number) => string = (_n: number) => '';
}

/** 面板驱动：Feature 把执行器的动作接到这几个出口，并在执行器每次变化时 push 快照。 */
export class StepUpPanelDriver {
  state: StepUpPanelState = new StepUpPanelState();
  send: () => void = () => {
  };
  setCode: (text: string) => void = (_t: string) => {
  };
  verify: () => void = () => {
  };
  close: () => void = () => {
  };
  private listener: (s: StepUpPanelState) => void = (_s: StepUpPanelState) => {
  };

  push(state: StepUpPanelState): void {
    this.state = state;
    try {
      this.listener(state);
    } catch (e) {
      // 视图回调出错不影响执行器。
    }
  }

  listen(listener: (s: StepUpPanelState) => void): void {
    this.listener = listener;
  }
}

/**
 * 面板按键盘弹起后的可用高度布局（APP-09 鸿蒙 R1-11、R2-09，共性第 11、33 条；AdaptShortStepUp）。与 Core 的 StepUpSheetFit 同一组算式
 * （Core 保留原类给已有单测；core 单测 StepUpPanelFit 与它逐值比对）。单位 vp。
 */
export class StepUpPanelFit {
  static readonly TOP_GAP: number = 24;
  static readonly MIN_PANEL: number = 160;
  static readonly MIN_MIDDLE: number = 48;
  static readonly FALLBACK_PANEL: number = 560;
  static readonly MIN_SCROLL: number = 48;

  static maxPanel(viewport: number, topInset: number, bottomInset: number, keyboard: number): number {
    if (!(viewport > 0)) {
      return StepUpPanelFit.FALLBACK_PANEL;
    }
    const kb: number = keyboard > 0 ? keyboard : 0;
    const avail: number = viewport - Math.max(0, topInset) - StepUpPanelFit.TOP_GAP - kb - Math.max(0, bottomInset);
    return Math.max(StepUpPanelFit.MIN_PANEL, Math.floor(avail));
  }

  static middle(panelMax: number, header: number, footer: number, chrome: number, natural: number,
    minMiddle: number = StepUpPanelFit.MIN_MIDDLE): number {
    const avail: number = panelMax - Math.max(0, header) - Math.max(0, footer) - Math.max(0, chrome);
    const floor: number = Math.min(Math.max(StepUpPanelFit.MIN_MIDDLE, minMiddle), Math.max(0, natural));
    return Math.max(floor, Math.min(Math.max(0, natural), Math.floor(avail)));
  }

  static available(viewport: number, topInset: number, bottomInset: number, keyboard: number): number {
    if (!(viewport > 0)) {
      return StepUpPanelFit.FALLBACK_PANEL;
    }
    const kb: number = keyboard > 0 ? keyboard : 0;
    const avail: number = viewport - Math.max(0, topInset) - StepUpPanelFit.TOP_GAP - kb - Math.max(0, bottomInset);
    return Math.max(StepUpPanelFit.MIN_SCROLL, Math.floor(avail));
  }

  static degraded(available: number, header: number, footer: number, chrome: number, minMiddle: number): boolean {
    if (!(header > 0) || !(footer > 0)) {
      return false;
    }
    return header + footer + Math.max(0, chrome) + Math.max(StepUpPanelFit.MIN_MIDDLE, minMiddle) > available;
  }

  static outer(available: number, panelMax: number, header: number, footer: number, chrome: number, middle: number,
    degraded: boolean): number {
    if (degraded) {
      return available;
    }
    if (!(header > 0) || !(footer > 0)) {
      return Math.min(panelMax, StepUpPanelFit.FALLBACK_PANEL);
    }
    return Math.min(panelMax, Math.ceil(header + footer + Math.max(0, chrome) + Math.max(0, middle)));
  }

  static spacer(keyboard: number): number {
    return keyboard > 0 ? Math.ceil(keyboard) : 0;
  }
}

const CODE_LENGTH: number = 6;
/** 面板的上下内边距（16 + 24）与三段之间的两个间距（16 × 2），vp。 */
const PANEL_CHROME: number = CouliSpacing.space4 + CouliSpacing.space6 + CouliSpacing.space4 * 2;

@ObservedV2
class StepUpModel {
  @Trace code: string = '';
  @Trace sent: boolean = false;
  @Trace countdown: number = 0;
  @Trace errorText: string = '';
  @Trace verifying: boolean = false;
  @Trace sending: boolean = false;
  @Trace noPhone: boolean = false;
  @Trace sendBlocked: boolean = false;
  @Trace verifyBlocked: boolean = false;
}

/**
 * 二次验证面板内容（StepUpSheet；设计稿 WithdrawStepUp、A11yFocusStepUp、AdaptShortStepUp）。由发起页用 bindSheet 承载：点遮罩与下滑不关闭
 * （onWillDismiss 只放行系统返回），关闭只能点【关闭】或系统返回；关闭后焦点回到发起页的【提交】/【保存】。
 * 标题（打开时读屏焦点进入）→ 「验证码已发送至你绑定的手机号」（G16，不显示号码）→ 关闭 → 6 格验证码（一个整串输入框，读屏读
 * 「验证码，已输入 n 位，共 6 位」）→ 倒计时 / 重新获取 →【验证并提交】（输满 6 位才可用）。20002 / 20003 清空并 assertive 播报。
 * 键盘（R1-11，AdaptShortStepUp）：承载的 bindSheet 不自己避让键盘（SheetKeyboardAvoidMode.NONE，页面也不避让），本组件订阅窗口的
 * keyboardHeightChange，按键盘弹起后的可用高度布局（StepUpSheetFit）：标题区与底部【验证并提交】固定，只有中段（验证码、错误、倒计时）
 * 滚动；面板下方垫一块与键盘等高的占位，整个面板贴在键盘上沿。短视口、200% 字号、不同键盘高度都按同一算式。
 * 降级（R2-09，共性第 33 条）：三段最小高放不下键盘上方的真实可用高时，整块放进一个等于可用高的滚动区（标题、关闭、验证码、
 * 【验证并提交】都可滚动到达，面板不顶出窗口）。常规与降级是同一棵组件树（外层 Scroll 只改高度与能否滚动），输入框不重建。
 */
@ComponentV2
export struct StepUpPanel {
  @Param @Require driver: StepUpPanelDriver;
  @Param @Require texts: StepUpPanelTexts;
  /** 调试截图用的视口高覆盖（vp；0 = 用窗口实际高度）。只由 Debug / Staging 的启动参数给出。 */
  @Param viewportOverride: number = 0;
  @Event onClose: () => void = () => {
  };
  @Local model: StepUpModel = new StepUpModel();
  @Local fontScale: CouliFontScale = CouliFontScale.shared();
  @Local areaWidth: number = 0;
  /** 键盘高（vp；收起为 0）、窗口高与上下安全区（vp）。 */
  @Local keyboardVp: number = 0;
  @Local windowVp: number = 0;
  @Local topInsetVp: number = 0;
  @Local bottomInsetVp: number = 0;
  /** 三段的自然高（vp）：中段 Scroll 的高度按「面板最大高 − 标题区 − 底部操作区 − 内边距与间距」与中段自然高取小。 */
  @Local headerVp: number = 0;
  @Local middleVp: number = 0;
  @Local footerVp: number = 0;
  private readonly middleScroller: Scroller = new Scroller();
  private readonly panelScroller: Scroller = new Scroller();
  private lastErrorSeq: number = 0;
  private lastClear: number = 0;
  private win: window.Window | null = null;
  private readonly onKeyboard: (height: number) => void = (height: number): void => {
    this.keyboardVp = height > 0 ? this.getUIContext().px2vp(height) : 0;
  };

  aboutToAppear(): void {
    CouliFontScale.attach(this.getUIContext());
    this.driver.listen((s: StepUpPanelState): void => this.apply(s));
    this.apply(this.driver.state);
    this.attachWindow();
    // 打开即对当前 action 发码（共享截止时间没过时不发，恢复倒计时，R1-06）。
    this.driver.send();
  }

  aboutToDisappear(): void {
    this.driver.close();
    const win: window.Window | null = this.win;
    this.win = null;
    if (win !== null) {
      try {
        win.off('keyboardHeightChange', this.onKeyboard);
      } catch (e) {
        // 窗口已销毁时忽略。
      }
    }
  }

  /** 取窗口高、上下安全区并订阅键盘高度（window API 7 / 9）。取不到时按缺省最大高布局。 */
  private attachWindow(): void {
    try {
      const ui: UIContext = this.getUIContext();
      const context: common.UIAbilityContext = ui.getHostContext() as common.UIAbilityContext;
      window.getLastWindow(context).then((win: window.Window): void => {
        try {
          const rect: window.Rect = win.getWindowProperties().windowRect;
          this.windowVp = ui.px2vp(rect.height);
          const sys: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
          this.topInsetVp = ui.px2vp(sys.topRect.height);
          const nav: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
          this.bottomInsetVp = ui.px2vp(nav.bottomRect.height);
          const kb: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD);
          this.onKeyboard(kb.bottomRect.height);
          win.on('keyboardHeightChange', this.onKeyboard);
          this.win = win;
        } catch (e) {
          // 窗口属性取不到：按缺省最大高。
        }
      }).catch((): void => {
        // 取不到窗口：按缺省最大高。
      });
    } catch (e) {
      // 上下文不可用。
    }
  }

  private panelMax(): number {
    const viewport: number = this.viewportOverride > 0 ? this.viewportOverride : this.windowVp;
    return StepUpPanelFit.maxPanel(viewport, this.topInsetVp, this.bottomInsetVp, this.keyboardVp);
  }

  private available(): number {
    const viewport: number = this.viewportOverride > 0 ? this.viewportOverride : this.windowVp;
    return StepUpPanelFit.available(viewport, this.topInsetVp, this.bottomInsetVp, this.keyboardVp);
  }

  /** 中段最小高：一行验证码格完整可见（格高随字号变化）。 */
  private minMiddle(): number {
    return Math.ceil(this.layout().cellHeight) + 2;
  }

  /** 三段最小高放不下可用高：整块滚动的降级布局（R2-09）。 */
  private degraded(): boolean {
    return StepUpPanelFit.degraded(this.available(), this.headerVp, this.footerVp, PANEL_CHROME, this.minMiddle());
  }

  /** 中段可用高：标题区与底部操作区固定，只压缩中段（自然高未量到时先按两倍命中区）；降级时中段取自然高（随整块滚动）。 */
  private middleHeight(): number {
    const natural: number = this.middleVp > 0 ? this.middleVp : CouliInteraction.minTouchTarget * 2;
    if (this.degraded()) {
      return natural;
    }
    return StepUpPanelFit.middle(this.panelMax(), this.headerVp, this.footerVp, PANEL_CHROME, natural,
      this.minMiddle());
  }

  /** 外层滚动区（整个面板）的高度。 */
  private outerHeight(): number {
    return StepUpPanelFit.outer(this.available(), this.panelMax(), this.headerVp, this.footerVp, PANEL_CHROME,
      this.middleHeight(), this.degraded());
  }

  private apply(s: StepUpPanelState): void {
    const m: StepUpModel = this.model;
    m.code = s.code;
    m.sent = s.sent;
    m.countdown = s.countdown;
    m.verifying = s.verifying;
    m.sending = s.sending;
    m.noPhone = s.noPhone;
    m.sendBlocked = s.sendBlocked;
    m.verifyBlocked = s.verifyBlocked;
    m.errorText = s.errorText;
    if (s.errorText.length > 0 && s.errorSeq !== this.lastErrorSeq) {
      this.lastErrorSeq = s.errorSeq;
      // 验证码错误等：立即 assertive 播报，焦点留在输入框。
      CouliAnnounce.say(this.getUIContext(), s.errorText);
    }
    if (s.clearSeq !== this.lastClear) {
      this.lastClear = s.clearSeq;
      try {
        this.getUIContext().getFocusController().requestFocus('step_up_code');
      } catch (e) {
        // 输入框尚未出现时忽略。
      }
    }
  }

  private layout(): CodeCellLayout {
    return CodeCellLayout.compute(this.areaWidth, CODE_LENGTH, this.fontScale.scale);
  }

  private codeSpoken(): string {
    return this.texts.codeSpoken(this.model.code.length);
  }

  @Builder
  cells() {
    Stack() {
      // 六格按可用宽度均分（layoutWeight），320 宽、200% 字号也在一行内完整可见。
      Row({ space: CouliSpacing.space2 }) {
        ForEach([0, 1, 2, 3, 4, 5], (index: number) => {
          Text(index < this.model.code.length ? this.model.code.charAt(index) : '')
            .fontSize(this.layout().fontSize + 'vp')
            .lineHeight(this.layout().cellHeight + 'vp')
            .fontColor(CouliColors.textPrimary)
            .fontWeight(CouliFontWeight.bold)
            .fontFeature(TABULAR_FEATURE)
            .maxLines(1)
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(this.layout().cellHeight)
            .borderRadius(CouliRadius.button)
            .border({
              width: index === this.model.code.length ? 2 : 1,
              color: index === this.model.code.length ? CouliColors.focusRing :
                (this.model.errorText.length > 0 ? CouliColors.statusErrorText : CouliColors.borderControl)
            })
            .backgroundColor(CouliColors.backgroundSurface)
        }, (index: number) => String(index))
      }
      .width('100%')
      .accessibilityLevel('no-hide-descendants')
      // 一个透明整串输入框盖在 6 格上（读屏只读一次）；数字键盘。TODO(N-32) H06：ContentType 没有一次性验证码类型（API 20）。
      TextInput({ text: this.model.code })
        .type(InputType.Number)
        .maxLength(CODE_LENGTH)
        .opacity(0.01)
        .fontColor(Color.Transparent)
        .placeholderColor(Color.Transparent)
        .caretColor(Color.Transparent)
        .width('100%')
        .height(this.layout().cellHeight)
        .accessibilityText(this.codeSpoken())
        .id('step_up_code')
        .defaultFocus(true)
        .onChange((value: string) => {
          this.driver.setCode(value);
        })
        .onSubmit(() => {
          this.driver.verify();
        })
    }
    .width('100%')
    .onAreaChange((_old: Area, now: Area) => {
      this.areaWidth = now.width as number;
    })
  }

  build() {
    Column() {
      // 外层滚动区：常规布局时高度等于三段之和、不滚动；降级时等于可用高、整块滚动（R2-09）。
      Scroll(this.panelScroller) {
        Column({ space: CouliSpacing.space4 }) {
          Row({ space: CouliSpacing.space2 }) {
            Text(this.texts.title)
              .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
                CouliFontWeight.semibold))
              .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
              .id('step_up_title')
              .focusable(true)
              .focusBox(CouliFocus.box)
              .layoutWeight(1)
            Button({ type: ButtonType.Normal, stateEffect: true }) {
              CouliIcon({ name: 'close', iconSize: 22, color: CouliColors.textPrimary })
            }
            .width(CouliInteraction.minTouchTarget)
            .height(CouliInteraction.minTouchTarget)
            .backgroundColor(Color.Transparent)
            .accessibilityText(this.texts.close)
            .id('step_up_close')
            .focusable(true)
            .focusBox(CouliFocus.box)
            .onClick(() => {
              this.onClose();
            })
          }
          .alignItems(VerticalAlign.Top)
          .width('100%')
          .onAreaChange((_old: Area, now: Area) => {
            this.headerVp = now.height as number;
          })
          // 中段（验证码格、错误提示）：唯一可滚动的部分（键盘弹起、短视口、200% 字号时压缩）。
          Scroll(this.middleScroller) {
            Column({ space: CouliSpacing.space2 }) {
              if (this.model.sent) {
                // 「验证码已发送至你绑定的手机号」放在中段（标题区只留标题与关闭，200% 字号时少占固定高度）。
                Text(this.texts.sent)
                  .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
                  .width('100%')
              }
              this.cells()
              if (this.model.errorText.length > 0) {
                Text(this.model.errorText)
                  .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText))
                  .width('100%')
                  .id('step_up_error')
              }
            }
            .width('100%')
            .onAreaChange((_old: Area, now: Area) => {
              this.middleVp = now.height as number;
            })
          }
          .width('100%')
          .height(this.middleHeight())
          .onAreaChange((_old: Area, now: Area) => {
            // 中段被压缩时滚到底：验证码格与错误提示完整可见（「已发送」一句在上方，可滚回去读）。
            if ((now.height as number) < this.middleVp) {
              this.middleScroller.scrollEdge(Edge.Bottom);
            }
          })
          .scrollBar(this.degraded() ? BarState.Off : BarState.Auto)
          .edgeEffect(EdgeEffect.None)
          // 降级时中段不自己滚（取自然高），手势交给外层整块滚动；常规时中段先滚，到边再交给外层（外层此时不可滚）。
          .enableScrollInteraction(!this.degraded())
          .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
          // 底部操作区（倒计时 / 重新获取 +【验证并提交】）：固定，不随中段滚动（共性第 11 条）。
          Column({ space: CouliSpacing.space2 }) {
            Row() {
              Blank()
              if (this.model.countdown > 0) {
                Text(this.texts.resendIn(this.model.countdown))
                  .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary,
                    undefined, true))
              } else if (!this.model.noPhone) {
                Text(this.texts.resend)
                  .attributeModifier(new CouliTextModifier(CouliTypography.footnote,
                    this.model.sendBlocked ? CouliColors.textSecondary : CouliColors.textLink, CouliFontWeight.medium))
                  .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
                  .accessibilityRole(AccessibilityRoleType.BUTTON)
                  .enabled(!this.model.sendBlocked && !this.model.sending)
                  .focusable(true)
                  .focusBox(CouliFocus.box)
                  .id('step_up_resend')
                  .onClick(() => {
                    this.driver.send();
                  })
              }
            }
            .width('100%')
            CouliButton({
              text: this.texts.submit,
              fullWidth: true,
              loading: this.model.verifying,
              disabled: this.model.code.length !== CODE_LENGTH || this.model.verifyBlocked,
              buttonId: 'step_up_submit',
              onTap: () => {
                this.driver.verify();
              }
            })
          }
          .width('100%')
          .onAreaChange((_old: Area, now: Area) => {
            this.footerVp = now.height as number;
          })
        }
        .width('100%')
        .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space4,
          bottom: CouliSpacing.space6 })
        .id('step_up_panel')
      }
      .width('100%')
      .height(this.outerHeight())
      .align(Alignment.Top)
      .enableScrollInteraction(this.degraded())
      .scrollBar(this.degraded() ? BarState.Auto : BarState.Off)
      .edgeEffect(EdgeEffect.None)
      .id('step_up_panel_scroll')
      // 键盘占位：面板整体贴在键盘上沿（键盘收起为 0）。
      Column()
        .width('100%')
        .height(StepUpPanelFit.spacer(this.keyboardVp))
        .id('step_up_kb_spacer')
        .accessibilityLevel('no')
    }
    .width('100%')
  }
}

/** bindSheet 的关闭拦截：只放行系统返回与代码关闭（点遮罩、下滑都不关闭；资金类，adaptation-a11y-spec §4）。 */
export function stepUpWillDismiss(action: DismissSheetAction): void {
  if (action.reason === DismissReason.PRESS_BACK) {
    action.dismiss();
  }
}
