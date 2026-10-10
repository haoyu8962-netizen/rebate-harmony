import {
  MeLevel, MeMessage, MeRecord, NicknameController, NicknameSnapshot, NotifySettingsController, NotifySnapshot,
  SettingsItems
} from 'core';
import {
  CouliAnnounce, CouliButton, CouliButtonVariant, CouliColors, CouliDialog, CouliDialogOptions, CouliFocus,
  CouliFocusReturn, CouliIcon, CouliInteraction, CouliSheetPanel, CouliSpacing, CouliTextModifier, CouliToast,
  CouliTypography, PriceTerms
} from 'designsystem';
import {
  Bound, DraftMeTexts, fmt1, MeCard, MeSheetPanel, MeGroupTitle, MeNoticeBar, MePageFrame, MeRow, MeSwitchRow, MeTexts,
  switchSpoken
} from './MeKit';

type JSONValue = Object | null;

/** 设置页的出口（entry 接 Router、已有的 logout()、清除缓存、resetTip、通知设置的系统状态与待定接口）。 */
export class SettingsPageConfig {
  texts: MeTexts = new DraftMeTexts();
  /** 身份档：basic / guest / member。 */
  level: () => string = () => MeLevel.GUEST;
  /** SettingsItems.of 的结果（entry 按端、phone_bound、待定接口是否可用算好）。 */
  items: () => MeRecord = () => SettingsItems.of(MeLevel.GUEST, 'harmony', null, false, false, false);
  /** 当前账号的昵称（Me 快照；没有为空串）。 */
  nickname: () => string = () => '';
  phoneBound: () => boolean | null = () => null;
  /** 渲染时的会话归属（按钮回调携带）。 */
  identity: () => string = () => '';
  /** 缓存大小（字节）；取不到为 null。 */
  cacheSize: () => Promise<number | null> = () => Promise.resolve(null);
  /** 只清图片与 WebView 缓存（不清会话、设备注册、配置 LKG、未决记录、pending_action、本机偏好）。 */
  clearCache: () => Promise<boolean> = () => Promise.resolve(false);
  open: (route: string, params: Record<string, Object>, identity: string) => void =
    (_r: string, _p: Record<string, Object>, _i: string) => {
    };
  onBack: () => void = () => {
  };
  login: () => void = () => {
  };
  /** 基本模式【开启完整功能】：重新展示首启弹窗。 */
  enableFull: () => void = () => {
  };
  /** 重新显示下单须知（resetTip jump_tip）：返回要提示的消息。identity 渲染时捕获，permit 发起时固定（R1-06、R1-08）。 */
  resetTip: (identity: string, permit: () => boolean) => Promise<MeMessage | null> =
    (_i: string, _p: () => boolean) => Promise.resolve(null);
  /** 「重新显示下单须知」42901 禁用中（会话共享闸门，R1-11）：入口置灰，到期恢复。 */
  tipBlocked: () => boolean = () => false;
  /** 订阅闸门变化；返回退订函数（出栈时释放）。 */
  subscribeTip: (listener: () => void) => () => void = (_l: () => void) => () => {
  };
  /** 发起时固定的页面许可（同一页面实例仍可见、没离开过、没进过页内子页）。 */
  permit: () => () => boolean = () => () => true;
  /**
   * 页内进入了子页（修改昵称、通知设置、协议半屏；F-HM-27）：同步作废此前固定的全部导航许可（MePageLife.subPageEntered），
   * 返回设置主页也不恢复。子页切换不触发 NavDestination.onHidden，所以由视图在切换的同一同步区里调用。
   */
  subPageEntered: () => void = () => {
  };
  /** 【退出登录】确认后：只调已有的 logout()；返回是否已经 Router 回「我的」（R1-09）。 */
  logout: (identity: string, permit: () => boolean) => Promise<boolean> =
    (_i: string, _p: () => boolean) => Promise.resolve(false);
  /**
   * 修改昵称子页的执行器（Release 待定接口不可用时为 null：昵称行不可点）。identity 是设置行渲染时捕获的归属：工厂只比较，
   * 不是已登录或归属已变返回 null（R2-02，旧回调不能重新绑定当前会话）。
   */
  nicknameController: (identity: string) => NicknameController | null = (_i: string) => null;
  notifyController: (identity: string) => NotifySettingsController | null = (_i: string) => null;
  /** 通知设置【去设置】：跳系统里本 App 的通知设置（用户主动，不受 48 小时限制）。 */
  openSystemNotificationSettings: () => void = () => {
  };
  /** 文案键（LoginDraftTexts 已有的 settings.logout.*）由 entry 的 texts 提供。 */
  /** 页面系统返回：子页打开时先关子页（返回 true 表示已处理）。由视图设置。 */
  backHandler: () => boolean = () => false;
  /** Debug 截图：打开时直接进入的子页（nickname / notify / agreement / clear_cache / logout）。 */
  initialSub: string = '';
  /** 回到可见、回前台、会话变化：按新身份重画（通知设置子页重查系统状态）。由视图设置。 */
  refresh: () => void = () => {
  };
  /** 页面出栈：关子页（清空草稿、释放订阅）、退订闸门（R1-01）。由视图设置。 */
  dispose: () => void = () => {
  };
  /**
   * APP-10 G18：【撤回 AI 服务同意】的文字（[行名, 确认框标题, 正文, 确认, 取消]）；空数组不显示（Release / Agent 不可用的环境）。
   */
  aiWithdrawTexts: () => string[] = () => [];
  /**
   * 确认后：recordConsent{ai_third_party, accepted=false, privacy_center}；返回要提示的文字（成功或统一错误）。identity 渲染时捕获；
   * permit 是确认时固定的导航许可（本页 MePageLife.permit，R3-02），只用来决定能否打开前置页。
   */
  aiWithdraw: (identity: string, permit: () => boolean) => Promise<string> =
    (_i: string, _p: () => boolean) => Promise.resolve('');
}

/** 设置行的渲染时绑定（R1-06：回调用渲染时捕获的身份，执行时只比较）。 */
class SettingsRowBinding {
  readonly row: MeRecord;
  readonly bound: Bound;

  constructor(row: MeRecord, bound: Bound) {
    this.row = row;
    this.bound = bound;
  }
}

/** 修改昵称子页的渲染时绑定：控制器、表单实例编号与身份（R1-06）。 */
class NicknameBinding {
  readonly controller: NicknameController;
  readonly form: number;
  readonly identity: string;
  readonly version: number;

  constructor(controller: NicknameController, form: number, identity: string, version: number) {
    this.controller = controller;
    this.form = form;
    this.identity = identity;
    this.version = version;
  }

  get id(): string {
    return this.form + '|' + this.identity + '|' + this.version;
  }
}

/** 通知设置子页的渲染时绑定。 */
class NotifyBinding {
  readonly controller: NotifySettingsController;
  readonly form: number;
  readonly identity: string;
  readonly flag: boolean;
  readonly version: number;

  constructor(controller: NotifySettingsController, form: number, identity: string, flag: boolean, version: number) {
    this.controller = controller;
    this.form = form;
    this.identity = identity;
    this.flag = flag;
    this.version = version;
  }

  get id(): string {
    return this.form + '|' + this.identity + '|' + this.flag + '|' + this.version;
  }
}

const SUB_MAIN: string = 'main';
const SUB_NICKNAME: string = 'nickname';
const SUB_NOTIFY: string = 'notify';

@ObservedV2
class SettingsModel {
  @Trace sub: string = SUB_MAIN;
  @Trace level: string = MeLevel.GUEST;
  @Trace items: MeRecord | null = null;
  @Trace nickname: string = '';
  @Trace phoneBound: boolean | null = null;
  @Trace cacheText: string = '';
  @Trace identity: string = '';
  @Trace version: number = 0;
  @Trace agreementSheet: boolean = false;
  @Trace busy: boolean = false;
  @Trace tipBlocked: boolean = false;
  @Trace nick: NicknameSnapshot | null = null;
  @Trace notify: NotifySnapshot | null = null;
}

/** 缓存大小显示（KB / MB 取整，AC-S1-137）。 */
export function cacheSizeText(bytes: number): string {
  if (bytes < 1024 * 1024) {
    return Math.round(bytes / 1024) + ' KB';
  }
  return Math.round(bytes / (1024 * 1024)) + ' MB';
}

/**
 * 设置页（设计稿 Settings、SettingsGuest、SettingsAgreementSheet、SettingsClearCache、SettingsCacheCleared、SettingsLogoutConfirm；G01、G02、G07、
 * G30、G32）。条目按 SettingsItems 的结论裁剪（基本模式五项 / 游客 / 已登录），游客与基本模式没有的条目不显示（不画成置灰）。
 * 修改昵称、通知设置、协议选择半屏是页内子页（不注册路由）；系统返回先关子页。
 */
@ComponentV2
export struct SettingsView {
  @Param @Require config: SettingsPageConfig;
  @Local model: SettingsModel = new SettingsModel();
  private nickController: NicknameController | null = null;
  private notifyCtl: NotifySettingsController | null = null;
  /** 子页表单实例编号：每次打开加 1。 */
  private formSeq: number = 0;
  private lastNickSeq: number = 0;
  private lastNotifySeq: number = 0;
  private tipUnsubscribe: () => void = () => {
  };
  private disposed: boolean = false;
  /** 打开着的退出登录确认框（绑定打开时的归属；R3-02：归属变化或页面出栈时同步关掉）。 */
  private closeLogoutConfirm: () => void = () => {
  };
  /** APP-10：撤回 AI 服务同意的确认框（一次性编号，APP-12 第 7、20 条）。 */
  private aiConfirmSerial: number = 0;
  private closeAiConfirm: () => void = () => {
  };

  aboutToAppear(): void {
    this.config.backHandler = (): boolean => this.systemBack();
    this.config.refresh = (): void => this.onForeground();
    this.config.dispose = (): void => this.dispose();
    this.tipUnsubscribe = this.config.subscribeTip((): void => {
      if (!this.disposed) {
        this.model.tipBlocked = this.config.tipBlocked();
        this.model.version++;
      }
    });
    this.reload();
    const sub: string = this.config.initialSub;
    if (sub === SUB_NICKNAME) {
      // Debug 截图直达：等 Me 快照到了再打开（预填当前昵称）。
      setTimeout(() => this.openNickname(this.currentBound()), 1500);
    } else if (sub === SUB_NOTIFY) {
      this.openNotify(this.currentBound());
    } else if (sub === 'agreement') {
      this.openAgreementSheet();
    } else if (sub === 'clear_cache') {
      setTimeout(() => this.confirmClearCache(), 300);
    } else if (sub === 'logout') {
      setTimeout(() => this.confirmLogout(this.model.identity), 300);
    }
  }

  aboutToDisappear(): void {
    this.dispose();
  }

  /** 出栈同步出口（R1-01）：关子页（控制器清空草稿与原昵称、释放订阅）、退订共享闸门。 */
  private dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.closeSub();
    this.dropLogoutConfirm();
    this.dropAiConfirm();
    this.tipUnsubscribe();
    this.tipUnsubscribe = () => {
    };
  }

  private t(key: string): string {
    return this.config.texts.text(key);
  }

  /** 按新身份重画（会话换代、回到可见）。 */
  reload(): void {
    const m: SettingsModel = this.model;
    const level: string = this.config.level();
    if ((m.level !== level || (m.identity.length > 0 && m.identity !== this.config.identity())) && m.sub !== SUB_MAIN) {
      // 身份或会话变了：需要登录的子页关掉（修改昵称、通知设置；输入已由执行器清空），不见旧账号的内容。
      this.closeSub();
    }
    if (m.identity.length > 0 && m.identity !== this.config.identity()) {
      // R3-02：绑定旧归属的退出登录确认框同步关掉（确认也只会被拒绝）。
      this.dropLogoutConfirm();
      this.dropAiConfirm();
    }
    m.level = level;
    m.items = this.config.items();
    m.nickname = this.config.nickname();
    m.phoneBound = this.config.phoneBound();
    m.identity = this.config.identity();
    m.tipBlocked = this.config.tipBlocked();
    m.version++;
    this.config.cacheSize().then((bytes: number | null): void => {
      this.model.cacheText = bytes === null ? '' : cacheSizeText(bytes);
    });
  }

  /** 系统返回：子页 → 回设置主页；半屏 → 关半屏；否则交给页面。 */
  systemBack(): boolean {
    if (this.model.agreementSheet) {
      this.model.agreementSheet = false;
      return true;
    }
    if (this.model.sub !== SUB_MAIN) {
      this.closeSub();
      return true;
    }
    return false;
  }

  /** 协议选择半屏（页内子页）：打开前同步作废已固定的导航许可（F-HM-27）。 */
  private openAgreementSheet(): void {
    this.config.subPageEntered();
    this.model.agreementSheet = true;
  }

  private closeSub(): void {
    const nick: NicknameController | null = this.nickController;
    if (nick !== null) {
      // 出栈同步出口：作废（写请求不取消，响应不改已关的子页）。
      nick.leave();
      this.nickController = null;
    }
    const notify: NotifySettingsController | null = this.notifyCtl;
    if (notify !== null) {
      notify.leave();
      this.notifyCtl = null;
    }
    const was: string = this.model.sub;
    this.model.sub = SUB_MAIN;
    this.model.nick = null;
    this.model.notify = null;
    if (was !== SUB_MAIN) {
      CouliFocusReturn.to(this.getUIContext(), was === SUB_NICKNAME ? 'settings_nickname' : 'settings_notify');
    }
  }

  /** 此刻的渲染绑定（只给 Debug 截图直达用；用户操作一律用渲染时捕获的绑定）。 */
  private currentBound(): Bound {
    return new Bound(this.model.identity, this.model.version);
  }

  /**
   * 渲染时捕获的绑定此刻是否仍有效（R2-02，共性第 13 条）：页面没出栈、渲染时的身份仍是当前页面与会话的身份、页面世代（model.version，
   * 每次按新身份重画、闸门变化都推进）没变。设置行、子页、开关、半屏与页脚的每个分支在执行任何动作之前都先过这一道。
   */
  private boundLive(bound: Bound): boolean {
    return !this.disposed && bound.identity === this.model.identity && bound.version === this.model.version
      && bound.identity === this.config.identity();
  }

  private openNickname(bound: Bound): void {
    if (!this.boundLive(bound)) {
      return;
    }
    const c: NicknameController | null = this.config.nicknameController(bound.identity);
    if (c === null) {
      return;
    }
    // F-HM-27：切到子页之前同步作废本页已固定的导航许可（撤回 AI 同意等迟到的前置码不再导航）。
    this.config.subPageEntered();
    this.closeSub();
    this.formSeq++;
    this.nickController = c;
    c.onChange = (s: NicknameSnapshot): void => this.applyNick(s);
    c.onSaved = (_n: string): void => {
      // 成功：只关掉发起的这一个子页（APP-09 第 50 条），回设置页，轻提示「昵称已修改」。
      if (this.nickController !== c) {
        return;
      }
      this.closeSub();
      this.reload();
      const ui: UIContext = this.getUIContext();
      CouliToast.show(ui, this.t('nickname.saved'));
    };
    this.model.sub = SUB_NICKNAME;
    this.applyNick(c.snapshot);
  }

  private applyNick(s: NicknameSnapshot): void {
    if (this.model.sub !== SUB_NICKNAME) {
      return;
    }
    // 换一个对象触发刷新（快照是同一个可变对象）。
    const copy: NicknameSnapshot = new NicknameSnapshot();
    copy.input = s.input;
    copy.check = s.check;
    copy.fieldError = s.fieldError;
    copy.message = s.message;
    copy.saving = s.saving;
    copy.blocked = s.blocked;
    copy.version = s.version;
    this.model.nick = copy;
    const ui: UIContext = this.getUIContext();
    if (s.fieldError !== null && s.fieldError.seq !== this.lastNickSeq) {
      // 字段错误即时播报一次，焦点移到错误提示，保留输入（APP-05b 第 6 条）。
      this.lastNickSeq = s.fieldError.seq;
      CouliAnnounce.say(ui, s.fieldError.text);
      setTimeout(() => {
        try {
          ui.getFocusController().requestFocus('nickname_error');
        } catch (e) {
          // 忽略。
        }
      }, 0);
    } else if (s.message !== null && s.message.seq !== this.lastNickSeq) {
      this.lastNickSeq = s.message.seq;
      CouliAnnounce.say(ui, s.message.text);
    }
  }

  private openNotify(bound: Bound): void {
    if (!this.boundLive(bound)) {
      return;
    }
    const c: NotifySettingsController | null = this.config.notifyController(bound.identity);
    if (c === null) {
      return;
    }
    // F-HM-27：同 openNickname。
    this.config.subPageEntered();
    this.closeSub();
    this.formSeq++;
    this.notifyCtl = c;
    c.onChange = (s: NotifySnapshot): void => this.applyNotify(s);
    this.model.sub = SUB_NOTIFY;
    c.load();
  }

  private applyNotify(s: NotifySnapshot): void {
    if (this.model.sub !== SUB_NOTIFY) {
      return;
    }
    const copy: NotifySnapshot = new NotifySnapshot();
    copy.systemRaw = s.systemRaw;
    copy.serviceOn = s.serviceOn;
    copy.switchAvailable = s.switchAvailable;
    copy.loading = s.loading;
    copy.saving = s.saving;
    copy.error = s.error;
    copy.message = s.message;
    copy.blocked = s.blocked;
    copy.version = s.version;
    this.model.notify = copy;
    if (s.message !== null && s.message.seq !== this.lastNotifySeq) {
      this.lastNotifySeq = s.message.seq;
      CouliToast.show(this.getUIContext(), s.message.text);
    }
  }

  /** 回前台：通知设置子页重新查询系统状态。 */
  onForeground(): void {
    const c: NotifySettingsController | null = this.notifyCtl;
    if (c !== null) {
      c.systemChanged();
    }
    this.reload();
  }

  private confirmClearCache(): void {
    const options: CouliDialogOptions = new CouliDialogOptions();
    options.title = this.t('settings.clear_cache');
    options.message = this.t('settings.clear_cache.confirm');
    options.primaryText = this.t('settings.clear_cache.confirm_ok');
    options.secondaryText = this.t('settings.clear_cache.confirm_cancel');
    options.returnFocusId = 'settings_clear_cache';
    options.onPrimary = (): void => {
      this.config.clearCache().then((ok: boolean): void => {
        this.reload();
        if (ok) {
          CouliToast.show(this.getUIContext(), this.t('settings.clear_cache.done'));
        }
      });
    };
    CouliDialog.open(this.getUIContext(), options);
  }

  private dropAiConfirm(): void {
    this.aiConfirmSerial++;
    const close: () => void = this.closeAiConfirm;
    this.closeAiConfirm = () => {
    };
    close();
  }

  /** 【撤回 AI 服务同意】确认框：绑定渲染时身份与一次性编号；确认时核对两者（APP-12 第 7、20 条）。 */
  private confirmAiWithdraw(bound: Bound): void {
    const texts: string[] = this.config.aiWithdrawTexts();
    if (texts.length < 5 || !this.boundLive(bound)) {
      return;
    }
    this.dropAiConfirm();
    const serial: number = this.aiConfirmSerial;
    const options: CouliDialogOptions = new CouliDialogOptions();
    options.title = texts[1];
    options.message = texts[2];
    options.primaryText = texts[3];
    options.secondaryText = texts[4];
    options.returnFocusId = 'settings_ai_withdraw';
    options.dismissOnMask = false;
    options.backDismisses = true;
    options.onPrimary = (): void => {
      if (serial !== this.aiConfirmSerial || !this.boundLive(bound)) {
        return;
      }
      this.aiConfirmSerial++;
      // R3-02：本次操作的导航许可在确认时固定（离页、被盖住、出栈后失效）。
      const permit: () => boolean = this.config.permit();
      this.config.aiWithdraw(bound.identity, permit).then((text: string): void => {
        if (!this.disposed && text.length > 0) {
          CouliToast.show(this.getUIContext(), text);
        }
      });
    };
    this.closeAiConfirm = CouliDialog.open(this.getUIContext(), options);
  }

  @Builder
  aiWithdrawRow(bound: Bound) {
    MeCard({
      content: () => {
        this.aiWithdrawRowInner(bound)
      }
    })
  }

  @Builder
  aiWithdrawRowInner(bound: Bound) {
    MeRow({
      label: this.config.aiWithdrawTexts()[0] ?? '',
      rowId: 'settings_ai_withdraw',
      divider: false,
      onTap: () => {
        this.confirmAiWithdraw(bound);
      }
    })
  }

  private dropLogoutConfirm(): void {
    const close: () => void = this.closeLogoutConfirm;
    this.closeLogoutConfirm = () => {
    };
    close();
  }

  /** identity：渲染时捕获（页脚按钮的绑定）；permit：打开确认框时固定（R1-06、R1-09）。 */
  private confirmLogout(identity: string): void {
    const permit: () => boolean = this.config.permit();
    const options: CouliDialogOptions = new CouliDialogOptions();
    options.title = this.t('settings.logout.confirm');
    options.primaryText = this.t('settings.logout.confirm_ok');
    options.secondaryText = this.t('settings.logout.confirm_cancel');
    options.returnFocusId = 'settings_logout';
    // 点遮罩不执行；系统返回走与【取消】相同的出口（APP-09 第 48 条）。
    options.dismissOnMask = false;
    options.backDismisses = true;
    options.onPrimary = (): void => {
      this.model.busy = true;
      this.config.logout(identity, permit).then((moved: boolean): void => {
        this.model.busy = false;
        if (!moved && !this.disposed) {
          this.reload();
        }
      });
    };
    this.dropLogoutConfirm();
    this.closeLogoutConfirm = CouliDialog.open(this.getUIContext(), options);
  }

  /** bound：渲染时捕获的身份（行绑定）；执行时只比较，不重新取当前身份。 */
  private tapItem(id: string, route: string | null, bound: Bound): void {
    // R2-02：任何分支之前先核对渲染时的身份与页面世代；失效的旧回调直接结束（不打开子页、不弹框、不发请求、不跳转）。
    if (this.model.busy || !this.boundLive(bound)) {
      return;
    }
    switch (id) {
      case SettingsItems.ID_NICKNAME:
        this.openNickname(bound);
        return;
      case SettingsItems.ID_NOTIFY:
        this.openNotify(bound);
        return;
      case SettingsItems.ID_AGREEMENT:
        this.openAgreementSheet();
        return;
      case SettingsItems.ID_CLEAR_CACHE:
        this.confirmClearCache();
        return;
      case SettingsItems.ID_RESET_TIP: {
        // R1-11：42901 禁用期内入口不可用（页面闸门；执行层另在每次发包前核对）。
        if (this.model.tipBlocked || this.config.tipBlocked()) {
          return;
        }
        const permit: () => boolean = this.config.permit();
        this.model.busy = true;
        this.config.resetTip(bound.identity, permit).then((m: MeMessage | null): void => {
          if (this.disposed) {
            return;
          }
          this.model.busy = false;
          this.model.tipBlocked = this.config.tipBlocked();
          this.model.version++;
          if (m !== null) {
            CouliToast.show(this.getUIContext(), m.text);
          }
        });
        return;
      }
      default:
        if (route !== null) {
          this.config.open(route, {}, bound.identity);
        }
    }
  }

  private label(id: string): string {
    switch (id) {
      case SettingsItems.ID_PRIVACY:
        return this.t('settings.privacy_center');
      case SettingsItems.ID_AGREEMENT:
        return this.t('settings.agreement');
      case SettingsItems.ID_ABOUT:
        return this.t('settings.about');
      case SettingsItems.ID_HELP:
        return this.t('settings.help');
      case SettingsItems.ID_CLEAR_CACHE:
        return this.t('settings.clear_cache');
      case SettingsItems.ID_NICKNAME:
        return this.t('settings.nickname');
      case SettingsItems.ID_PHONE:
        return this.t('settings.phone');
      case SettingsItems.ID_AUTH:
        return this.t('auth_manage.title');
      case SettingsItems.ID_NOTIFY:
        return this.t('settings.notify');
      case SettingsItems.ID_RESET_TIP:
        return this.t('settings.reset_tip');
      default:
        return '';
    }
  }

  private value(id: string): string {
    if (id === SettingsItems.ID_NICKNAME) {
      return this.model.nickname;
    }
    if (id === SettingsItems.ID_PHONE) {
      // G07：只按 phone_bound 显示「已绑定 / 未绑定」（不显示号码）。
      return this.model.phoneBound === true ? this.t('settings.phone.bound') :
        this.model.phoneBound === false ? this.t('settings.phone.unbound') : '';
    }
    if (id === SettingsItems.ID_CLEAR_CACHE) {
      return this.model.cacheText;
    }
    return '';
  }

  private rowId(id: string): string {
    switch (id) {
      case SettingsItems.ID_PRIVACY:
        return 'settings_privacy_center';
      case SettingsItems.ID_AGREEMENT:
        return 'settings_agreement';
      case SettingsItems.ID_ABOUT:
        return 'settings_about';
      case SettingsItems.ID_HELP:
        return 'settings_help';
      case SettingsItems.ID_CLEAR_CACHE:
        return 'settings_clear_cache';
      case SettingsItems.ID_NICKNAME:
        return 'settings_nickname';
      case SettingsItems.ID_PHONE:
        return 'settings_phone';
      case SettingsItems.ID_AUTH:
        return 'settings_auth_manage';
      case SettingsItems.ID_NOTIFY:
        return 'settings_notify';
      case SettingsItems.ID_RESET_TIP:
        return 'settings_reset_tip';
      default:
        return 'settings_row';
    }
  }

  private groupTitle(name: string): string {
    switch (name) {
      case SettingsItems.GROUP_ACCOUNT:
        return this.t('settings.group.account');
      case SettingsItems.GROUP_PRIVACY:
        return this.t('settings.group.privacy');
      case SettingsItems.GROUP_GENERAL:
        return this.t('settings.group.general');
      default:
        return '';
    }
  }

  private groups(): MeRecord[] {
    const items: MeRecord | null = this.model.items;
    if (items === null || !Array.isArray(items['groups'])) {
      return [];
    }
    return items['groups'] as MeRecord[];
  }

  private rows(group: MeRecord): MeRecord[] {
    return Array.isArray(group['items']) ? group['items'] as MeRecord[] : [];
  }

  private clickable(row: MeRecord): boolean {
    if (row['id'] === SettingsItems.ID_RESET_TIP && this.model.tipBlocked) {
      return false;
    }
    const c: JSONValue | undefined = row['clickable'];
    return c === undefined ? true : c === true;
  }

  /** 每行在渲染时捕获身份与版本（R1-06：不在点击时取）。 */
  private rowBindings(group: MeRecord): SettingsRowBinding[] {
    const bound: Bound = new Bound(this.model.identity, this.model.version);
    return this.rows(group).map((row: MeRecord): SettingsRowBinding => new SettingsRowBinding(row, bound));
  }

  @Builder
  groupCard(group: MeRecord) {
    Column({ space: CouliSpacing.space2 }) {
      if (this.groupTitle(group['group'] as string).length > 0) {
        MeGroupTitle({ text: this.groupTitle(group['group'] as string) })
      }
      MeCard({
        content: () => {
          this.groupRows(group)
        }
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  groupRows(group: MeRecord) {
    ForEach(this.rowBindings(group), (b: SettingsRowBinding, index: number) => {
      MeRow({
        label: this.label(b.row['id'] as string),
        value: this.value(b.row['id'] as string),
        rowId: this.rowId(b.row['id'] as string),
        clickable: this.clickable(b.row),
        divider: index < this.rows(group).length - 1,
        onTap: () => {
          this.tapItem(b.row['id'] as string, typeof b.row['route'] === 'string' ? b.row['route'] as string : null,
            b.bound);
        }
      })
    }, (b: SettingsRowBinding) => (b.row['id'] as string) + '_' + b.bound.id + '_' + this.model.cacheText
      + '_' + this.model.nickname + '_' + this.model.tipBlocked)
  }

  @Builder
  footer() {
    if (this.model.items !== null) {
      if (this.model.items['footer'] === SettingsItems.FOOTER_LOGOUT) {
        ForEach([new Bound(this.model.identity, this.model.version)], (b: Bound) => {
          CouliButton({
            text: this.t('settings.logout'),
            variant: CouliButtonVariant.SECONDARY,
            fullWidth: true,
            loading: this.model.busy,
            buttonId: 'settings_logout',
            onTap: () => {
              if (this.boundLive(b)) {
                this.confirmLogout(b.identity);
              }
            }
          })
        }, (b: Bound) => 'logout_' + b.id + '_' + this.model.busy)
      } else if (this.model.items['footer'] === SettingsItems.FOOTER_LOGIN) {
        Column({ space: CouliSpacing.space3 }) {
          Text(this.t('settings.guest_footer'))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
            .textAlign(TextAlign.Center)
            .width('100%')
          ForEach([new Bound(this.model.identity, this.model.version)], (b: Bound) => {
            CouliButton({
              text: this.t('settings.go_login'),
              fullWidth: true,
              buttonId: 'settings_login',
              onTap: () => {
                if (this.boundLive(b)) {
                  this.config.login();
                }
              }
            })
          }, (b: Bound) => 'login_' + b.id)
        }
        .width('100%')
      } else if (this.model.items['footer'] === SettingsItems.FOOTER_ENABLE_FULL) {
        ForEach([new Bound(this.model.identity, this.model.version)], (b: Bound) => {
          CouliButton({
            text: this.t('privacy.basic_mode.enable'),
            fullWidth: true,
            buttonId: 'settings_enable_full',
            onTap: () => {
              if (this.boundLive(b)) {
                this.config.enableFull();
              }
            }
          })
        }, (b: Bound) => 'enable_full_' + b.id)
      }
    }
  }

  @Builder
  mainContent() {
    ForEach(this.groups(), (group: MeRecord) => {
      this.groupCard(group)
    }, (group: MeRecord) => (group['group'] as string) + '_' + this.model.version)
    if (this.model.level !== MeLevel.BASIC && this.config.aiWithdrawTexts().length >= 5) {
      ForEach([new Bound(this.model.identity, this.model.version)], (b: Bound) => {
        this.aiWithdrawRow(b)
      }, (b: Bound) => 'ai_withdraw_' + b.id)
    }
    Column() {
      this.footer()
    }
    .width('100%')
    .padding({ top: CouliSpacing.space2 })
  }

  @Builder
  agreementSheet() {
    Column() {
      MeSheetPanel({
        title: this.t('settings.agreement'),
        closeLabel: this.t('me.close'),
        titleId: 'settings_agreement_sheet_title',
        content: () => {
          this.agreementChoices()
        },
        onClose: () => {
          this.model.agreementSheet = false;
        }
      })
    }
  }

  @Builder
  agreementChoices() {
    ForEach([new Bound(this.model.identity, this.model.version)], (b: Bound) => {
      this.agreementButtons(b)
    }, (b: Bound) => 'agreement_' + b.id)
  }

  @Builder
  agreementButtons(bound: Bound) {
    Column({ space: CouliSpacing.space3 }) {
      CouliButton({
        text: this.t('settings.agreement.user'),
        variant: CouliButtonVariant.SECONDARY,
        fullWidth: true,
        buttonId: 'settings_agreement_user',
        onTap: () => {
          this.model.agreementSheet = false;
          if (!this.boundLive(bound)) {
            return;
          }
          const p: Record<string, Object> = {};
          p['type'] = 'agreement';
          this.config.open('Agreement', p, bound.identity);
        }
      })
      CouliButton({
        text: this.t('settings.agreement.privacy'),
        variant: CouliButtonVariant.SECONDARY,
        fullWidth: true,
        buttonId: 'settings_agreement_privacy',
        onTap: () => {
          this.model.agreementSheet = false;
          if (!this.boundLive(bound)) {
            return;
          }
          const p: Record<string, Object> = {};
          p['type'] = 'privacy';
          this.config.open('Agreement', p, bound.identity);
        }
      })
    }
    .width('100%')
    .padding({ bottom: CouliSpacing.space2 })
  }

  // ---------------------------------------------------------------- 修改昵称子页

  /** 渲染时的昵称表单绑定（控制器、表单实例编号、身份）；没有子页为空数组。 */
  private nickBindings(): NicknameBinding[] {
    const c: NicknameController | null = this.nickController;
    if (c === null || this.model.nick === null) {
      return [];
    }
    return [new NicknameBinding(c, this.formSeq, c.identity, (this.model.nick as NicknameSnapshot).version)];
  }

  /** 执行时只比较：仍是渲染时那一个表单实例。 */
  private nickCurrent(b: NicknameBinding): boolean {
    return !this.disposed && this.nickController === b.controller && this.formSeq === b.form;
  }

  @Builder
  nicknameContent() {
    // 按表单实例与身份重建（@Builder 按值传参不随状态刷新）：回调捕获的是这一版渲染的控制器与身份。
    ForEach(this.nickBindings(), (b: NicknameBinding) => {
      this.nicknameForm(b)
    }, (b: NicknameBinding) => 'nick_' + b.form + '_' + b.identity)
  }

  @Builder
  nicknameForm(bound: NicknameBinding) {
    Column({ space: CouliSpacing.space2 }) {
      Text(this.t('nickname.label'))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
      Row({ space: CouliSpacing.space2 }) {
        TextInput({ text: (this.model.nick as NicknameSnapshot).input })
          .id('nickname_input')
          .layoutWeight(1)
          .fontSize(CouliTypography.body.fontSize)
          .backgroundColor(Color.Transparent)
          .accessibilityText(this.t('nickname.label'))
          .accessibilityDescription((this.model.nick as NicknameSnapshot).fieldError?.text ?? '')
          .onChange((value: string) => {
            // 输入回调携带渲染时的控制器与身份（APP-09 第 59 条，R1-06）。
            if (this.nickCurrent(bound)) {
              bound.controller.setInput(value, bound.identity);
            }
          })
        if ((this.model.nick as NicknameSnapshot).input.length > 0) {
          Button({ type: ButtonType.Normal, stateEffect: true }) {
            CouliIcon({ name: 'close', iconSize: 18, color: CouliColors.textSecondary })
          }
          .id('nickname_clear')
          .width(CouliInteraction.minTouchTarget)
          .height(CouliInteraction.minTouchTarget)
          .backgroundColor(Color.Transparent)
          .accessibilityText(this.t('nickname.clear'))
          .onClick(() => {
            if (this.nickCurrent(bound)) {
              bound.controller.setInput('', bound.identity);
            }
          })
        }
        Text(fmt1(this.config.texts, 'nickname.counter', 'n',
          String((this.model.nick as NicknameSnapshot).check['length'] ?? 0)))
          .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary,
            undefined, true))
          .id('nickname_counter')
      }
      .width('100%')
      .padding({ left: CouliSpacing.space3, right: CouliSpacing.space1 })
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
      .borderRadius(12)
      .border({ width: 1, color: (this.model.nick as NicknameSnapshot).fieldError !== null ?
        CouliColors.statusErrorText : CouliColors.borderControl })
      .backgroundColor(CouliColors.backgroundSurface)
      if ((this.model.nick as NicknameSnapshot).fieldError !== null) {
        Text(((this.model.nick as NicknameSnapshot).fieldError as MeMessage).text)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText))
          .id('nickname_error')
          .focusable(true)
          .focusBox(CouliFocus.box)
      } else if (this.nicknameHint().length > 0) {
        Text(this.nicknameHint())
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText))
          .id('nickname_local_hint')
      }
      if ((this.model.nick as NicknameSnapshot).message !== null) {
        MeNoticeBar({
          text: ((this.model.nick as NicknameSnapshot).message as MeMessage).text,
          tone: 'error',
          barId: 'nickname_message'
        })
      }
      Text(this.t('nickname.hint'))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 本地长度提示（代拟）：去首尾空白后为空或超过 16 字素。 */
  private nicknameHint(): string {
    const nick: NicknameSnapshot | null = this.model.nick;
    if (nick === null) {
      return '';
    }
    const length: number = typeof nick.check['length'] === 'number' ? nick.check['length'] as number : 0;
    if (length > 16) {
      return this.t('nickname.too_long');
    }
    if (length === 0 && nick.input.length > 0) {
      return this.t('nickname.empty');
    }
    return '';
  }

  @Builder
  nicknameFooter() {
    if (this.model.nick !== null) {
      Column() {
        ForEach(this.nickBindings(), (b: NicknameBinding) => {
          CouliButton({
            text: this.t('nickname.save'),
            fullWidth: true,
            loading: (this.model.nick as NicknameSnapshot).saving,
            disabled: (this.model.nick as NicknameSnapshot).check['saveEnabled'] !== true
              || (this.model.nick as NicknameSnapshot).blocked,
            buttonId: 'nickname_save',
            onTap: () => {
              // R1-06：用渲染时捕获的控制器与身份；执行时只比较，不读当前控制器重新取身份。
              if (this.nickCurrent(b)) {
                b.controller.save(b.identity);
              }
            }
          })
        }, (b: NicknameBinding) => 'nick_save_' + b.id)
      }
      .width('100%')
      .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space3,
        bottom: CouliSpacing.space5 })
    }
  }

  // ---------------------------------------------------------------- 通知设置子页

  private notifyBindings(): NotifyBinding[] {
    const c: NotifySettingsController | null = this.notifyCtl;
    if (c === null || this.model.notify === null) {
      return [];
    }
    const n: NotifySnapshot = this.model.notify as NotifySnapshot;
    return [new NotifyBinding(c, this.formSeq, c.identity, n.serviceOn === true, n.version)];
  }

  @Builder
  notifyContent() {
    ForEach(this.notifyBindings(), (b: NotifyBinding) => {
      this.notifyBody(b)
    }, (b: NotifyBinding) => 'notify_' + b.id)
  }

  @Builder
  notifyBody(bound: NotifyBinding) {
    if ((this.model.notify as NotifySnapshot).systemRaw !== 'granted') {
      // 系统通知未开启：perm.push.denied_forever +【去设置】（跳系统设置，不经 PermissionRequester 申请）。
      Column({ space: CouliSpacing.space2 }) {
        MeNoticeBar({ text: this.t('perm.push.denied_forever'), tone: 'warning', barId: 'notify_system_off' })
        CouliButton({
          text: this.t('perm.go_settings'),
          variant: CouliButtonVariant.SECONDARY,
          fullWidth: true,
          buttonId: 'notify_go_settings',
          onTap: () => this.config.openSystemNotificationSettings()
        })
      }
      .width('100%')
    }
    MeCard({
      vertical: CouliSpacing.space1,
      content: () => {
        this.notifySwitch(bound)
      }
    })
  }

  @Builder
  notifySwitch(bound: NotifyBinding) {
    if ((this.model.notify as NotifySnapshot).switchAvailable && (this.model.notify as NotifySnapshot).serviceOn !== null) {
      MeSwitchRow({
        label: this.t('notify.service'),
        desc: this.t('notify.service_desc'),
        on: bound.flag,
        disabled: (this.model.notify as NotifySnapshot).saving || (this.model.notify as NotifySnapshot).blocked,
        rowId: 'notify_service_switch',
        spoken: switchSpoken(this.config.texts, this.t('notify.service'), bound.flag),
        onToggle: (target: boolean) => {
          // R1-06：渲染时捕获的控制器与身份；执行时只比较。
          if (!this.disposed && this.notifyCtl === bound.controller && this.formSeq === bound.form) {
            bound.controller.toggle(target, bound.identity);
          }
        }
      })
    } else {
      // G02：Release 不显示开关行（不画成置灰），只保留说明句。
      Column({ space: CouliSpacing.space1 }) {
        Text(this.t('notify.service'))
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
        Text(this.t('notify.service_desc'))
          .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        if ((this.model.notify as NotifySnapshot).error !== null) {
          Text(((this.model.notify as NotifySnapshot).error as MeMessage).text)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText))
        }
      }
      .width('100%')
      .padding({ top: CouliSpacing.space3, bottom: CouliSpacing.space3 })
      .alignItems(HorizontalAlign.Start)
      .id('notify_service_desc')
    }
  }

  @Builder
  emptyFooter() {
  }

  build() {
    Stack() {
      if (this.model.sub === SUB_NICKNAME) {
        MePageFrame({
          title: this.t('nickname.title'),
          backLabel: this.t('me.back'),
          scrollId: 'nickname_scroll',
          content: () => {
            this.nicknameContent()
          },
          footer: () => {
            this.nicknameFooter()
          },
          onBack: () => this.closeSub()
        })
      } else if (this.model.sub === SUB_NOTIFY) {
        MePageFrame({
          title: this.t('notify.title'),
          backLabel: this.t('me.back'),
          scrollId: 'notify_scroll',
          content: () => {
            this.notifyContent()
          },
          onBack: () => this.closeSub()
        })
      } else {
        MePageFrame({
          title: this.t('settings.title'),
          backLabel: this.t('me.back'),
          scrollId: 'settings_scroll',
          content: () => {
            this.mainContent()
          },
          onBack: () => this.config.onBack()
        })
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet(this.model.agreementSheet, this.agreementSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: false,
      showClose: false,
      onDisappear: () => {
        this.model.agreementSheet = false;
        // 关闭后焦点回到触发控件（AdaptSheetRules）。
        CouliFocusReturn.to(this.getUIContext(), 'settings_agreement');
      }
    })
  }
}
