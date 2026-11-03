import {
  MeDraftTexts, MeGridColumns, MeGridGroups, MeGuideText, MeLevel, MeMaskAnnounce, MeNoticeAnnounce, MePhase, MeRecord,
  MeTabController, MeTabSnapshot, MeView
} from 'core';
import {
  CouliAnnounce, CouliButton, CouliColors, CouliFocus, CouliFontScale, CouliFontWeight, CouliFormat, CouliInteraction,
  CouliLayout, CouliRadius, CouliShadow, CouliSpacing, CouliTextModifier, CouliToast, CouliTypography, ErrorState, PriceTerms
} from 'designsystem';
import { Bound, DraftMeTexts, MeMaskUi, MeNoticeBar, MeTexts } from './MeKit';

type JSONValue = Object | null;

/** 邀请码行复制图标的视觉边长与「邀请人」同行时离图标的间距（vp；48 命中区以图标为中心向右伸 16，留 0.5 防像素取整相交）。 */
const COPY_ICON: number = 16;
const INVITER_GAP: number = 16.5;

/** 「我的」Tab 的出口（entry 接 Router、统一客服出口、APP-07 统一剪贴板写入口与引导条偏好）。 */
export class MeTabConfig {
  readonly controller: MeTabController;
  texts: MeTexts = new DraftMeTexts();
  /** 本端路由表里有、since 满足的路由（宫格裁剪，G31）。 */
  availableRoutes: () => string[] = () => [];
  /** features.flags 的收益看板开关（G31，APP-09 G20）。 */
  earningsFlag: () => boolean | null = () => null;
  /** 经 Router 以路由名打开（执行前复核身份）。 */
  open: (route: string, params: Record<string, Object>, identity: string) => void =
    (_r: string, _p: Record<string, Object>, _i: string) => {
    };
  /** 游客【登录 / 注册】。 */
  login: () => void = () => {
  };
  /** 统一客服出口（G20）。 */
  customerService: () => void = () => {
  };
  /** 复制邀请码：只走 APP-07 统一写入口（先记自写 hash 并确认落盘，记录失败就不写）。 */
  copy: (text: string, identity: string) => Promise<boolean> = (_t: string, _i: string) => Promise.resolve(false);
  /** 通知引导条此刻是否显示（G28：已登录、系统未开、拒绝 ≥48 小时、关闭 ≥7 天）。 */
  guideBarVisible: () => boolean = () => false;
  /** 关闭引导条（记关闭时刻，设备级）；identity 是渲染时捕获的归属，执行时只比较。 */
  closeGuideBar: (identity: string) => void = (_i: string) => {
  };
  /** 点引导条：只跳系统里本 App 的通知设置，不经 PermissionRequester 申请。 */
  openSystemNotificationSettings: () => void = () => {
  };

  constructor(controller: MeTabController) {
    this.controller = controller;
  }
}

@ObservedV2
class MeTabModel {
  @Trace phase: string = MePhase.IDLE;
  @Trace level: string = MeLevel.GUEST;
  @Trace version: number = 0;
  @Trace view: MeRecord | null = null;
  @Trace nickname: string = '';
  @Trace errorText: string = '';
  @Trace refreshError: string = '';
  @Trace blocked: boolean = false;
  @Trace refreshing: boolean = false;
  @Trace guideBar: boolean = false;
  @Trace identity: string = '';
}

/** 宫格格子（渲染时固定路由与身份）。 */
class GridCell {
  readonly group: string;
  readonly label: string;
  readonly icon: string;
  readonly route: string | null;
  readonly cs: boolean;
  readonly bound: Bound;

  constructor(group: string, label: string, icon: string, route: string | null, cs: boolean, bound: Bound) {
    this.group = group;
    this.label = label;
    this.icon = icon;
    this.route = route;
    this.cs = cs;
    this.bound = bound;
  }
}

/**
 * 「我的」Tab（设计稿 Me、MeGuest、MeHidden、MeMinor；G04、G05、G06、G28、G31、G36）。
 * - 游客：引导登录 + 宫格只有「帮助中心」「设置」；没有铃铛、余额卡和其他宫格。
 * - 已登录：铃铛（消息中心，无红点）、通知引导条、身份卡（昵称、本人邀请码与【复制】、邀请人已绑定 / 未绑定）、余额卡（可提现余额【提现】、
 *   预估收益，金额隐藏）、分组宫格。资料加载失败显示错误态与【重试】，不回落到游客态。
 * Tab 根整个进程保留（切 Tab 只是隐藏），返回「我的」时滚动位置保持（AdaptBackRestore）。
 */
@ComponentV2
export struct MeTabView {
  @Param @Require config: MeTabConfig;
  @Local model: MeTabModel = new MeTabModel();
  @Local maskUi: MeMaskUi = new MeMaskUi();
  private readonly scroller: Scroller = new Scroller();
  private lastErrorSeq: number = 0;
  /** APP-12v 视图层状态（不进执行器、不进快照）：字号比例、宫格可用宽、邀请码行几何、上一条已播的刷新失败文字。 */
  @Local fontScale: CouliFontScale = CouliFontScale.shared();
  @Local gridWidth: number = 0;
  /** 邀请码流式行（HM6 / 评审 r1 S1-1 方案 A）的几何：行宽、码段框、码段末行（右端、上缘、行高）、邀请人尺寸（vp）。 */
  @Local flowWidth: number = 0;
  @Local codeFrameH: number = 0;
  @Local codeLastEnd: number = 0;
  @Local codeLastTop: number = 0;
  @Local codeLineH: number = 0;
  @Local inviterW: number = 0;
  @Local inviterH: number = 0;
  private readonly codeController: TextController = new TextController();
  private lastNotice: string = '';

  aboutToAppear(): void {
    this.config.controller.onChange = (s: MeTabSnapshot): void => this.apply(s);
    this.apply(this.config.controller.snapshot);
  }

  aboutToDisappear(): void {
    this.maskUi.dispose();
  }

  private t(key: string): string {
    return this.config.texts.text(key);
  }

  private apply(s: MeTabSnapshot): void {
    const m: MeTabModel = this.model;
    m.phase = s.phase;
    m.level = s.level;
    m.blocked = s.blocked;
    m.refreshing = s.refreshing;
    // FU-HM-0712（共性第 63、65 条）：身份与显示的数据同源（执行器快照），不在 apply 时现读当前会话。
    m.identity = s.identity;
    m.errorText = s.error === null ? '' : s.error.text;
    m.refreshError = s.refreshError === null ? '' : s.refreshError.text;
    m.nickname = s.me === null ? '' : (typeof s.me['nickname'] === 'string' ? s.me['nickname'] as string : '');
    m.view = MeView.of(s.level, s.me, false, this.config.availableRoutes(), this.config.earningsFlag());
    m.guideBar = s.level === MeLevel.MEMBER && this.config.guideBarVisible();
    m.version = s.version;
    if (s.error !== null && s.error.seq !== this.lastErrorSeq) {
      // 整页加载失败 assertive 播报，焦点移到【重试】（APP-06a 第 16 条）。
      this.lastErrorSeq = s.error.seq;
      const ui: UIContext = this.getUIContext();
      CouliAnnounce.say(ui, s.error.text);
      setTimeout(() => {
        try {
          ui.getFocusController().requestFocus('me_retry');
        } catch (e) {
          // 控件尚未出现时忽略。
        }
      }, 0);
    }
  }

  /** 引导条状态在回到可见时重算（系统设置可能变了）。 */
  refreshGuideBar(): void {
    this.model.guideBar = this.model.level === MeLevel.MEMBER && this.config.guideBarVisible();
  }

  private member(): boolean {
    return this.model.level === MeLevel.MEMBER;
  }

  private icon(item: string): string {
    switch (item) {
      case 'me.grid.orders':
        return 'orders';
      case 'me.grid.wallet':
        return 'wallet';
      case 'me.grid.ledger':
        return 'ledger';
      case 'me.grid.find_order':
        return 'find-order';
      case 'me.grid.invite':
        return 'user-plus';
      case 'me.grid.earnings':
        return 'trend';
      case 'me.grid.help':
        return 'help';
      case 'me.grid.cs':
        return 'headset';
      case 'me.grid.auth':
        return 'shield';
      default:
        return 'settings';
    }
  }

  private cells(group: string): GridCell[] {
    const v: MeRecord | null = this.model.view;
    const out: GridCell[] = [];
    if (v === null || !Array.isArray(v['grid'])) {
      return out;
    }
    for (const raw of v['grid'] as JSONValue[]) {
      const c: MeRecord = raw as MeRecord;
      if (c['group'] !== group) {
        continue;
      }
      const key: string | null = MeDraftTexts.gridKey(c['item'] as string);
      if (key === null) {
        continue;
      }
      const route: string | null = typeof c['route'] === 'string' ? c['route'] as string : null;
      out.push(new GridCell(group, this.t(key), this.icon(key), route, c['cs'] === true,
        new Bound(this.model.identity, this.model.version, route ?? 'cs')));
    }
    return out;
  }

  private tapCell(cell: GridCell): void {
    if (cell.cs) {
      this.config.customerService();
      return;
    }
    if (cell.route !== null) {
      this.config.open(cell.route, {}, cell.bound.identity);
    }
  }

  private inviteCode(): string | null {
    const v: MeRecord | null = this.model.view;
    const block: JSONValue | undefined = v === null ? null : v['inviteCodeBlock'];
    if (block === null || block === undefined || typeof block !== 'object') {
      return null;
    }
    const code: JSONValue | undefined = (block as MeRecord)['code'];
    return typeof code === 'string' ? code as string : null;
  }

  private fen(node: string): number | null {
    const v: MeRecord | null = this.model.view;
    const balance: JSONValue | undefined = v === null ? null : v['balance'];
    if (balance === null || balance === undefined || typeof balance !== 'object') {
      return null;
    }
    const n: JSONValue | undefined = (balance as MeRecord)[node];
    if (n === null || n === undefined || typeof n !== 'object') {
      return null;
    }
    const f: JSONValue | undefined = (n as MeRecord)['fen'];
    return typeof f === 'number' ? f as number : null;
  }

  private amountText(fen: number | null): string {
    if (fen === null) {
      return '';
    }
    return this.maskUi.masked ? PriceTerms.amountMask : CouliFormat.money(fen);
  }

  private amountSpoken(fen: number | null): string {
    if (fen === null) {
      return '';
    }
    return this.maskUi.masked ? this.t('me.amount_hidden') : CouliFormat.moneySpoken(fen);
  }

  private async copyCode(bound: Bound): Promise<void> {
    const ui: UIContext = this.getUIContext();
    const ok: boolean = await this.config.copy(bound.value, bound.identity);
    // 复制成功 polite 播报一次（系统 Toast 由读屏礼貌播报，A11yAnnounce）。
    CouliToast.show(ui, this.t(ok ? 'invite.copy_code.done' : 'me.copy_failed'));
  }


  // ---------------------------------------------------------------- APP-12v 视觉（视图层；上面的守卫区逐字节不动）

  /** 刷新失败提示条出现 / 文案变化时 assertive 播报一次（H-M05；同一句不重播，消失不播；不改 apply）。 */
  @Monitor('model.refreshError')
  onRefreshErrorChanged(): void {
    const now: string = this.model.refreshError;
    const say: string | null = MeNoticeAnnounce.next(this.lastNotice, now);
    this.lastNotice = now;
    if (say !== null) {
      CouliAnnounce.say(this.getUIContext(), say);
    }
  }

  /** icon() 给的图标名 → HarmonyOS Symbol（H-M03 / D10-559：宫格功能图标用系统图标集，收益看板柱状 histogram）。 */
  private symbolOf(name: string): Resource {
    switch (name) {
      case 'orders':
        return $r('sys.symbol.doc_plaintext');
      case 'wallet':
        return $r('sys.symbol.wallet');
      case 'ledger':
        return $r('sys.symbol.list_bullet');
      case 'find-order':
        return $r('sys.symbol.doc_text_badge_magnifyingglass');
      case 'user-plus':
        return $r('sys.symbol.person_badge_plus');
      case 'trend':
        return $r('sys.symbol.histogram');
      case 'help':
        return $r('sys.symbol.questionmark_circle');
      case 'headset':
        return $r('sys.symbol.headphones');
      case 'shield':
        return $r('sys.symbol.checkmark_shield');
      case 'settings':
        return $r('sys.symbol.gearshape');
      default:
        return $r('sys.symbol.gearshape');
    }
  }

  /** 金额隐藏切换：记下切换前的值，toggle 后确实翻转才播一次（G-M13 / H-M06）。 */
  private toggleMask(): void {
    const before: boolean = this.maskUi.masked;
    this.maskUi.toggle();
    const key: string | null = MeMaskAnnounce.key(before, this.maskUi.masked);
    if (key !== null) {
      CouliAnnounce.say(this.getUIContext(), this.t(key));
    }
  }

  /** 宫格列数（H-M08）：宫格可用宽与本页全部格名中最宽者（按当前字号比例量宽，vp）。 */
  private gridColumns(): number {
    const ui: UIContext = this.getUIContext();
    const size: number = CouliTypography.footnote.size * this.fontScale.scale;
    let widest: number = 0;
    for (const group of MeGridGroups.MEMBER_ORDER) {
      for (const cell of this.cells(group)) {
        try {
          const px: number = ui.getMeasureUtils().measureText({
            textContent: cell.label, fontSize: size + 'vp', fontWeight: CouliFontWeight.regular
          }) as number;
          widest = Math.max(widest, ui.px2vp(px));
        } catch (e) {
          // 量不出时按 4 列（MeGridColumns.count 对 0 宽保持最多列）。
        }
      }
    }
    return MeGridColumns.count(this.gridWidth, widest);
  }

  /**
   * 码段排版后取末行几何（照 Android InviteFlow：复制跟在码段末行末字后）。单行时末行 = 整个框；折行时用 TextController 的
   * LayoutManager 取末行右端（LineMetrics 单位按末行 topHeight 与「行高 ×（行数 − 1）」比对判断是 px 还是 vp）。
   */
  private measureCode(w: number, h: number): void {
    let end: number = w;
    let top: number = 0;
    let lineH: number = h;
    try {
      const lm: LayoutManager = this.codeController.getLayoutManager();
      const n: number = lm.getLineCount();
      if (n > 1) {
        const m: LineMetrics = lm.getLineMetrics(n - 1);
        const ui: UIContext = this.getUIContext();
        lineH = h / n;
        const expectTop: number = lineH * (n - 1);
        const asPx: boolean = Math.abs(ui.px2vp(m.topHeight) - expectTop) <= Math.abs(m.topHeight - expectTop);
        const right: number = asPx ? ui.px2vp(m.left + m.width) : m.left + m.width;
        end = Math.min(w, Math.max(0, right));
        top = h - lineH;
      }
    } catch (e) {
      // 取不到排版信息时按单行处理（复制跟在框右缘后）。
    }
    this.codeFrameH = h;
    this.codeLastEnd = end;
    this.codeLastTop = top;
    this.codeLineH = lineH;
  }

  /** 复制图标（视觉 16）左上角：码段末行末字后 4，与末行垂直居中。 */
  private copyX(): number {
    return this.codeLastEnd + CouliSpacing.space1;
  }

  private copyY(): number {
    return this.codeLastTop + (this.codeLineH - COPY_ICON) / 2;
  }

  /** 「邀请人」放得下就与码同行（离图标 16.5：48 命中区以图标为中心向右伸 16，不盖邀请人），否则下一行。 */
  private inviterSameLine(): boolean {
    return this.flowWidth > 0 && this.inviterW > 0 &&
      this.copyX() + COPY_ICON + INVITER_GAP + this.inviterW <= this.flowWidth;
  }

  private inviterX(): number {
    return this.inviterSameLine() ? this.copyX() + COPY_ICON + INVITER_GAP : 0;
  }

  /** 下一行时行距 4；复制命中区（图标中心 ±24）与邀请人横向相交且会压到它时，邀请人下移到命中区之下。 */
  private inviterY(): number {
    if (this.inviterSameLine()) {
      return this.codeLastTop + (this.codeLineH - this.inviterH) / 2;
    }
    const half: number = CouliInteraction.minTouchTarget / 2;
    const hitBottom: number = this.copyY() + COPY_ICON / 2 + half;
    const next: number = this.codeFrameH + CouliSpacing.space1;
    const crosses: boolean = this.inviterW > this.copyX() + COPY_ICON / 2 - half;
    return crosses && next < hitBottom ? hitBottom + 0.5 : next;
  }

  private flowHeight(): number {
    return Math.max(this.codeFrameH, this.inviterY() + this.inviterH, CouliTypography.caption.size);
  }

  @Builder
  header() {
    Row() {
      Text(this.t('me.title'))
        .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary,
          CouliFontWeight.semibold))
        .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
        .id('me_title')
        .layoutWeight(1)
      if (this.member() && this.model.view !== null && this.model.view['bell'] !== null) {
        ForEach([new Bound(this.model.identity, this.model.version)], (b: Bound) => {
          this.bell(b)
        }, (b: Bound) => 'me_bell_' + b.id)
      }
    }
    .width('100%')
    .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space1 })
  }

  @Builder
  bell(bound: Bound) {
        // G04：铃铛只经 Router 打开 Messages（h5），不显示未读红点，读屏「消息中心」。
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.bell'))
            .fontSize('24vp')
            .fontColor([CouliColors.textPrimary])
            .accessibilityLevel('no')
        }
        .id('me_bell')
        .width(CouliInteraction.minTouchTarget)
        .height(CouliInteraction.minTouchTarget)
        .backgroundColor(Color.Transparent)
        .accessibilityText(this.t('me.bell'))
        .focusBox(CouliFocus.box)
        .onClick(() => {
          // 打开前比较：渲染时捕获的身份（APP-09 第 63 条：不在点击时读可观察状态取身份）。
          this.config.open('Messages', {}, bound.identity);
        })
  }

  @Builder
  guideBar(bound: Bound) {
    // HM3 / HM4：muted 底、圆角 12、内边距 上右下 4 左 12；次文字色铃铛 20；正文 14 主文字，句尾「去开启」链接样式（G-M10 切分在 Core）。
    Row({ space: CouliSpacing.space2 }) {
      Row({ space: CouliSpacing.space2 }) {
        SymbolGlyph($r('sys.symbol.bell'))
          .fontSize('20vp')
          .fontColor([CouliColors.textSecondary])
          .accessibilityLevel('no')
        Text() {
          Span(MeGuideText.split(this.t('perm.push.guide_bar')).head)
            .fontSize(CouliTypography.footnote.fontSize)
            .fontColor(CouliColors.textPrimary)
            .fontWeight(CouliFontWeight.regular)
          // 不可切（linked=false）时尾段为空串，整句按普通样式（回退）。
          Span(MeGuideText.split(this.t('perm.push.guide_bar')).tail)
            .fontSize(CouliTypography.footnote.fontSize)
            .fontColor(CouliColors.textLink)
            .fontWeight(CouliFontWeight.semibold)
            .decoration({ type: TextDecorationType.Underline, color: CouliColors.textLink })
        }
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
        .layoutWeight(1)
        // 带 Span 的 Text 不自己接触摸（点哪里都是整条正文区这一个目标）。
        .hitTestBehavior(HitTestMode.None)
      }
      .layoutWeight(1)
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
      .id('me_guide_bar')
      .accessibilityGroup(true)
      .accessibilityText(this.t('perm.push.guide_bar'))
      .accessibilityRole(AccessibilityRoleType.BUTTON)
      .focusable(true)
      .focusBox(CouliFocus.box)
      .onClick(() => this.config.openSystemNotificationSettings())
      Button({ type: ButtonType.Normal, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize('20vp')
          .fontColor([CouliColors.textSecondary])
          .accessibilityLevel('no')
      }
      .id('me_guide_bar_close')
      .width(CouliInteraction.minTouchTarget)
      .height(CouliInteraction.minTouchTarget)
      .backgroundColor(Color.Transparent)
      .accessibilityText(this.t('me.guide_bar.close'))
      .focusBox(CouliFocus.box)
      .onClick(() => {
        this.config.closeGuideBar(bound.identity);
        this.model.guideBar = false;
      })
    }
    .id('me_guide')
    .width('100%')
    .padding({ top: CouliSpacing.space1, right: CouliSpacing.space1, bottom: CouliSpacing.space1,
      left: CouliSpacing.space3 })
    .borderRadius(CouliRadius.button)
    .backgroundColor(CouliColors.backgroundMuted)
  }

  @Builder
  avatar(avatarId: string) {
    Column() {
      SymbolGlyph($r('sys.symbol.person'))
        .fontSize('32vp')
        .fontColor([CouliColors.textSecondary])
        .accessibilityLevel('no')
    }
    .id(avatarId)
    .width(56)
    .height(56)
    .borderRadius(CouliRadius.pill)
    .backgroundColor(CouliColors.backgroundMuted)
    .justifyContent(FlexAlign.Center)
    .accessibilityLevel('no-hide-descendants')
  }

  @Builder
  identityCard(bound: Bound) {
    Row({ space: CouliSpacing.space3 }) {
      this.avatar('me_avatar')
      Column({ space: CouliSpacing.space1 }) {
        Text(this.model.nickname)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
            CouliFontWeight.semibold))
          .id('me_nickname')
        if (bound.value.length > 0) {
          // G05：invite_code 为 null 时整块不显示（不显示原因）。HM6（评审 r1 S1-1 方案 A，照 Android InviteFlow）：真流式行——
          // 码段一个读屏节点「我的邀请码 K7M3QX」（行高 18，可折行）；复制视觉 16 紧跟码段末行末字后 4，命中 48 以图标为中心
          // （responseRegion，可压在不可点的码段上，不撑高行）；「邀请人」放得下就同行（离图标 16.5，命中区不盖它），否则下一行，
          // 与命中区相交时再下移。回调 copyCode(bound) 原样。
          Stack({ alignContent: Alignment.TopStart }) {
            Text(undefined, { controller: this.codeController }) {
              Span(this.t('me.invite_code') + ' ')
                .fontSize(CouliTypography.caption.fontSize)
                .fontColor(CouliColors.textSecondary)
                .fontWeight(CouliFontWeight.regular)
              Span(bound.value)
                .fontSize(CouliTypography.caption.fontSize)
                .fontColor(CouliColors.textPrimary)
                .fontWeight(CouliFontWeight.semibold)
                .letterSpacing(1)
            }
            .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary, undefined, true))
            .constraintSize({ maxWidth: this.flowWidth > 0 ? this.flowWidth - CouliSpacing.space1 - COPY_ICON : '100%' })
            .id('me_invite_code')
            .accessibilityGroup(true)
            .accessibilityText(this.t('me.invite_code') + ' ' + bound.value)
            .onAreaChange((_o: Area, n: Area) => {
              this.measureCode(n.width as number, n.height as number);
            })
            Button({ type: ButtonType.Normal, stateEffect: true }) {
              SymbolGlyph($r('sys.symbol.rectangle_on_rectangle'))
                .fontSize('16vp')
                .fontColor([CouliColors.textLink])
                .accessibilityLevel('no')
            }
            .id('me_copy_invite')
            .width(COPY_ICON)
            .height(COPY_ICON)
            .padding(0)
            .position({ x: this.copyX(), y: this.copyY() })
            .responseRegion({ x: -16, y: -16, width: CouliInteraction.minTouchTarget, height: CouliInteraction.minTouchTarget })
            .backgroundColor(Color.Transparent)
            .accessibilityText(this.t('me.copy') + this.t('me.invite_code'))
            .focusBox(CouliFocus.box)
            .onClick(() => {
              this.copyCode(bound);
            })
            Text(this.t(this.model.view !== null && this.model.view['inviterTextKey'] === MeView.INVITER_BOUND_KEY ?
              'me.inviter_bound' : 'me.inviter_unbound'))
              .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
              .id('me_inviter')
              .position({ x: this.inviterX(), y: this.inviterY() })
              .onAreaChange((_o: Area, n: Area) => {
                this.inviterW = n.width as number;
                this.inviterH = n.height as number;
              })
          }
          .width('100%')
          .height(this.flowHeight())
          // 复制命中区上下伸出本行 16：行容器自己的命中区跟着上下扩，保证越界的那部分能命中到复制。
          .responseRegion([
            { x: 0, y: -16, width: '100%', height: 16 },
            { x: 0, y: 0, width: '100%', height: '100%' },
            { x: 0, y: '100%', width: '100%', height: 16 }
          ])
          .onAreaChange((_o: Area, n: Area) => {
            this.flowWidth = n.width as number;
          })
        } else {
          Text(this.t(this.model.view !== null && this.model.view['inviterTextKey'] === MeView.INVITER_BOUND_KEY ?
            'me.inviter_bound' : 'me.inviter_unbound'))
            .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
            .id('me_inviter')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .responseRegion([
        { x: 0, y: -16, width: '100%', height: 16 },
        { x: 0, y: 0, width: '100%', height: '100%' },
        { x: 0, y: '100%', width: '100%', height: 16 }
      ])
    }
    .id('me_identity_card')
    .width('100%')
    .padding(CouliSpacing.space4)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
    .shadow(CouliShadow.card)
  }

  @Builder
  balanceCard(bound: Bound) {
    Column({ space: CouliSpacing.space3 }) {
      // HM7：首行「可提现余额」14/500 + 眼睛 20 紧凑（间距 4；命中 48 用 responseRegion，不撑高首行 = 文字行高 21）。
      // HM10：首行文字一个读屏节点「可提现余额，金额 / 金额已隐藏」（大数不再单独读），顺序 金额 → 眼睛 →【提现】→ 预估。
      Row({ space: CouliSpacing.space1 }) {
        Text(this.t('me.withdrawable'))
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textInverse,
            CouliFontWeight.medium))
          .id('me_withdrawable_label')
          .accessibilityText(this.t('me.withdrawable') + PriceTerms.comma + this.amountSpoken(this.fen('withdrawable')))
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          SymbolGlyph(this.maskUi.masked ? $r('sys.symbol.eye_slash') : $r('sys.symbol.eye'))
            .fontSize('20vp')
            .fontColor([CouliColors.textInverse])
            .accessibilityLevel('no')
        }
        .id('me_amount_mask')
        .width(20)
        .height(20)
        .padding(0)
        .responseRegion({ x: -14, y: -14, width: CouliInteraction.minTouchTarget, height: CouliInteraction.minTouchTarget })
        .backgroundColor(Color.Transparent)
        .accessibilityText(this.t(this.maskUi.masked ? 'amount_mask.show' : 'amount_mask.hide'))
        .focusBox(CouliFocus.box)
        .onClick(() => {
          this.toggleMask();
        })
      }
      .padding({ right: 14 })
      .responseRegion([
        { x: 0, y: -14, width: '100%', height: 14 },
        { x: 0, y: 0, width: '100%', height: '100%' },
        { x: 0, y: '100%', width: '100%', height: 14 }
      ])
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Center }) {
        Text(this.amountText(this.fen('withdrawable')))
          .attributeModifier(new CouliTextModifier(CouliTypography.display, CouliColors.textInverse,
            CouliFontWeight.bold, true))
          .id('me_withdrawable')
          .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
          .accessibilityLevel('no')
          .margin({ right: CouliSpacing.space3 })
        // HM8：白底【提现】（button.inverse 令牌、600），最小宽 96、视觉 48，放不下整块换行。
        Button(this.t('me.withdraw'), { type: ButtonType.Normal })
          .id('me_withdraw')
          .constraintSize({ minWidth: 96, minHeight: CouliInteraction.minTouchTarget })
          .padding({ left: CouliSpacing.space5, right: CouliSpacing.space5 })
          .borderRadius(CouliRadius.button)
          .backgroundColor(CouliColors.buttonInverseBackground)
          .fontColor(CouliColors.buttonInverseText)
          .fontSize(CouliTypography.body.fontSize)
          .fontWeight(CouliFontWeight.semibold)
          .accessibilityText(this.t('me.withdraw'))
          .focusBox(CouliFocus.box)
          .onClick(() => {
            // G06：【提现】只经 Router 打开 Wallet（不直接打开 Withdraw）；身份取渲染时的绑定。
            this.config.open('Wallet', {}, bound.identity);
          })
      }
      .width('100%')
      // HM9：钟表 14 +「预估收益」14 常规 → 22/600 数值，纵距 2；读屏只读数值节点一次「预估收益，金额」。
      Column({ space: 2 }) {
        Row({ space: CouliSpacing.space1 }) {
          SymbolGlyph($r('sys.symbol.clock'))
            .fontSize('14vp')
            .fontColor([CouliColors.textInverse])
          Text(this.t('me.estimated'))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textInverse))
        }
        .accessibilityLevel('no-hide-descendants')
        Text(this.amountText(this.fen('estimated')))
          .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textInverse,
            CouliFontWeight.semibold, true))
          .id('me_estimated')
          .accessibilityText(this.t('me.estimated') + PriceTerms.comma + this.amountSpoken(this.fen('estimated')))
      }
      .id('me_estimated_block')
      .alignItems(HorizontalAlign.Start)
    }
    .id('me_balance_card')
    .width('100%')
    .padding(CouliSpacing.space5)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.brandPrimary)
    .shadow(CouliShadow.card)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  gridCard(group: string, cells: GridCell[], gridId: string, columns: number) {
    Column({ space: CouliSpacing.space1 }) {
      Text(this.t('me.group.' + group))
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
          CouliFontWeight.semibold))
        .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
        .padding({ left: CouliSpacing.space2, right: CouliSpacing.space2 })
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(cells, (cell: GridCell) => {
          Column({ space: CouliSpacing.space1 }) {
            SymbolGlyph(this.symbolOf(cell.icon))
              .fontSize('24vp')
              .fontColor([CouliColors.textPrimary])
              .accessibilityLevel('no')
            Text(cell.label)
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
              .textAlign(TextAlign.Center)
          }
          .width((100 / columns) + '%')
          .constraintSize({ minHeight: 72 })
          .justifyContent(FlexAlign.Center)
          .padding({ top: CouliSpacing.space2, bottom: CouliSpacing.space2, left: 2, right: 2 })
          .id(gridId + '_' + (cell.route ?? 'cs'))
          .accessibilityGroup(true)
          .accessibilityText(cell.label)
          .accessibilityRole(AccessibilityRoleType.BUTTON)
          .focusable(true)
          .focusBox(CouliFocus.box)
          .onClick(() => this.tapCell(cell))
        }, (cell: GridCell) => cell.bound.id + '_' + columns)
      }
      .width('100%')
      .onAreaChange((_o: Area, n: Area) => {
        const w: number = (n.width as number);
        if (w > 0 && Math.abs(w - this.gridWidth) > 0.5) {
          this.gridWidth = w;
        }
      })
    }
    .id((gridId === 'me_grid' ? 'me_grid_group_' : 'me_guest_grid_group_') + group)
    .width('100%')
    .padding({ top: CouliSpacing.space4, bottom: CouliSpacing.space2, left: CouliSpacing.space2,
      right: CouliSpacing.space2 })
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
    .shadow(CouliShadow.card)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  guestCard() {
    // HM11：内边距 16、纵向 16。
    Column({ space: CouliSpacing.space4 }) {
      Row({ space: CouliSpacing.space3 }) {
        this.avatar('me_guest_avatar')
        Column({ space: CouliSpacing.space1 }) {
          Text(this.t('me.guest.title'))
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
              CouliFontWeight.semibold))
          Text(this.t('me.guest.desc'))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      CouliButton({
        text: this.t('me.guest.login'),
        fullWidth: true,
        buttonId: 'me_login',
        onTap: () => this.config.login()
      })
    }
    .id('me_guest_card')
    .width('100%')
    .padding(CouliSpacing.space4)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
    .shadow(CouliShadow.card)
  }

  @Builder
  skeletonBar(width: Length, height: number) {
    Column()
      .width(width)
      .height(height)
      .borderRadius(CouliRadius.small)
      .backgroundColor(CouliColors.backgroundMuted)
  }

  /** HM15 / H-M02：加载中静态骨架（身份卡块 → 主卡块 → 一组宫格块），整块读一次「加载中」；仍在 Refresh 外。 */
  @Builder
  skeleton() {
    Column({ space: CouliSpacing.space3 }) {
      Row({ space: CouliSpacing.space3 }) {
        Column()
          .id('me_skeleton_identity_avatar')
          .width(56)
          .height(56)
          .borderRadius(CouliRadius.pill)
          .backgroundColor(CouliColors.backgroundMuted)
        Column({ space: CouliSpacing.space2 }) {
          this.skeletonBar('50%', CouliTypography.body.size)
          this.skeletonBar('75%', CouliTypography.caption.size)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .id('me_skeleton_identity')
      .width('100%')
      .padding(CouliSpacing.space4)
      .borderRadius(CouliRadius.card)
      .backgroundColor(CouliColors.backgroundSurface)
      Column()
        .id('me_skeleton_balance')
        .width('100%')
        .height(184)
        .borderRadius(CouliRadius.card)
        .backgroundColor(CouliColors.backgroundMuted)
      Column({ space: CouliSpacing.space3 }) {
        this.skeletonBar('30%', CouliTypography.body.size)
        Row({ space: CouliSpacing.space4 }) {
          ForEach([0, 1, 2, 3], (_i: number) => {
            Column()
              .layoutWeight(1)
              .height(56)
              .borderRadius(CouliRadius.small)
              .backgroundColor(CouliColors.backgroundMuted)
          }, (i: number) => 'me_skeleton_cell_' + i)
        }
        .width('100%')
      }
      .id('me_skeleton_grid')
      .width('100%')
      .padding(CouliSpacing.space4)
      .borderRadius(CouliRadius.card)
      .backgroundColor(CouliColors.backgroundSurface)
      .alignItems(HorizontalAlign.Start)
    }
    .id('me_skeleton')
    .width('100%')
    .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space2 })
    .accessibilityGroup(true)
    .accessibilityText(this.t('me.loading'))
  }

  @Builder
  memberBody() {
    if (this.model.guideBar) {
      ForEach([new Bound(this.model.identity, this.model.version)], (b: Bound) => {
        this.guideBar(b)
      }, (b: Bound) => 'me_guide_' + b.id)
    }
    if (this.model.refreshError.length > 0) {
      MeNoticeBar({
        text: this.model.refreshError + '\n' + this.t('me.retry'),
        tone: 'error',
        barId: 'me_refresh_error',
        tappable: !this.model.blocked,
        onTap: () => {
          this.config.controller.retry();
        }
      })
    }
    ForEach([new Bound(this.model.identity, this.model.version, this.inviteCode() ?? '')], (b: Bound) => {
      this.identityCard(b)
    }, (b: Bound) => 'me_identity_' + b.id + '_' + this.model.nickname)
    // H-M06：键不含隐藏状态，切换时不整卡重建（读屏焦点留在眼睛上）。
    ForEach([new Bound(this.model.identity, this.model.version)], (b: Bound) => {
      this.balanceCard(b)
    }, (b: Bound) => 'me_balance_' + b.id)
    // H-M09：分组里没有格就整组不画（显隐规则仍在 MeView）。键带身份、版本与列数：数据或列数变了整卡按新值重建（@Builder 按值传参）。
    ForEach(MeGridGroups.visible(this.model.view, MeGridGroups.MEMBER_ORDER), (group: string) => {
      this.gridCard(group, this.cells(group), 'me_grid', this.gridColumns())
    }, (group: string) => 'me_grid_card_' + group + '_' + this.model.identity + '_' + this.model.version + '_' +
      this.gridColumns())
  }

  build() {
    Column() {
      this.header()
      if (this.member() && this.model.phase === MePhase.ERROR) {
        Column() {
          ErrorState({
            title: this.model.errorText,
            retryText: this.t('me.retry'),
            retryId: 'me_retry',
            retryDisabled: this.model.blocked,
            onRetry: () => {
              this.config.controller.retry();
            }
          })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.member() && this.model.phase !== MePhase.CONTENT) {
        Column() {
          this.skeleton()
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Start)
      } else {
        Refresh({ refreshing: this.model.refreshing }) {
          Scroll(this.scroller) {
            Column({ space: CouliSpacing.space3 }) {
              if (this.member()) {
                this.memberBody()
              } else {
                this.guestCard()
                ForEach(MeGridGroups.visible(this.model.view, [MeView.GROUP_MORE]), (group: string) => {
                  this.gridCard(group, this.cells(group), 'me_guest_grid', this.gridColumns())
                }, (group: string) => 'me_guest_grid_card_' + group + '_' + this.model.version + '_' + this.gridColumns())
              }
            }
            .width('100%')
            .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
            .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space2,
              bottom: CouliSpacing.space4 })
          }
          .id('me_scroll')
          .width('100%')
          .height('100%')
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        }
        .layoutWeight(1)
        .width('100%')
        .refreshOffset(64)
        .pullToRefresh(this.member() && !this.model.blocked)
        .onRefreshing(() => {
          this.model.refreshing = true;
          if (!this.config.controller.refresh()) {
            setTimeout(() => {
              this.model.refreshing = false;
            }, 0);
          }
        })
      }
    }
    .id('me_page')
    .width('100%')
    .height('100%')
    .backgroundColor(CouliColors.backgroundCanvas)
    .onAppear(() => {
      CouliFontScale.attach(this.getUIContext());
    })
  }
}
