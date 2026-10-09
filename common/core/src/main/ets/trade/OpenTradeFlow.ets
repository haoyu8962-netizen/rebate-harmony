import { ErrorActionMapper } from '../network/ErrorActionMapper';
import { TradeJson } from './TradeJson';

/*
 * APP-06b 购买流程的纯逻辑（三端同名；向量 specs/open-trade-vectors.json，测试 OpenTradeVector.test.ets）。执行器
 * （OpenPurchaseController、TradeJumpExecutor）直接调用这些函数，向量测到的就是生产判定。规则空白按保守处理
 * （不外跳、不放行），标 TODO(N-28)。
 */

/**
 * 一次购买尝试的 Idempotency-Key 生命周期（拍板第二批 TRADE-22、BR-ID-10 细则「恢复执行时用哪个幂等键」）：
 * - start：一次新的点击（含取消、离开后再点）→ 新键；
 * - timeout / retry：8 秒超时后的【重试】是同一次点击的重发 → 原键；
 * - authRequired（30101 / 30102 / 30111）后 resendAfterAuth：授权后再发是新请求 → 新键（3xxxx 已写入幂等记录）；
 * - 10001 登录后的重放沿用原键（1xxxx 不写幂等记录），用 retry；
 * - abandon / cancel 只是本机放弃：open 不属于作废接口的四类 step-up 操作，不调 abandonIdempotencyKey（abandonCalled 恒为 false）。
 */
export class OpenAttempt {
  private readonly keyGenerator: () => string;
  private key: string | null = null;
  /** 被授权码拦下、等授权完成（之后 resendAfterAuth 换新键）。 */
  awaitingAuth: boolean = false;

  constructor(keyGenerator: () => string) {
    this.keyGenerator = keyGenerator;
  }

  /** 当前（最近一次发送用的）键；还没点过为 null。 */
  get currentKey(): string | null {
    return this.key;
  }

  /** 是否调了服务端作废接口：open 不在作废接口的四类操作里，恒为 false（向量 abandon_open_is_local_only）。 */
  get abandonCalled(): boolean {
    return false;
  }

  /** 新的点击：新键。 */
  start(): string {
    return this.fresh();
  }

  /** 8 秒没有响应：键不变（等用户点【重试】）。 */
  timeout(): void {
  }

  /** 同一请求的重发（超时【重试】、登录后的重放）：沿用原键；还没有键时等同 start。 */
  retry(): string {
    return this.key ?? this.fresh();
  }

  /** 被 30101 / 30102 / 30111 拦下。 */
  authRequired(_code: number): void {
    this.awaitingAuth = true;
  }

  /** 授权完成后重新发起同一 link 的 open：新请求、新键。 */
  resendAfterAuth(): string {
    this.awaitingAuth = false;
    return this.fresh();
  }

  /** 用户取消：只挡本机外跳，服务端的点击证据与幂等结果照常保留（03 §4.5），不作废键。 */
  cancel(): void {
  }

  /** 本机放弃（超时后不重试）：不调作废接口。 */
  abandon(): void {
  }

  private fresh(): string {
    const k: string = this.keyGenerator();
    this.key = k;
    return k;
  }
}

/** open 响应动作标签（三端统一的接线标签）。 */
export class OpenActions {
  static readonly JUMP: string = 'jump';
  static readonly CONFIRM_PRICE: string = 'confirm_price';
  static readonly CONFIRM_REBATE_GONE: string = 'confirm_rebate_gone';
  static readonly CONFIRM_COUPON: string = 'confirm_coupon';
  static readonly COMPARE_NO_REBATE: string = 'compare_no_rebate';
  /** availability=off_shelf：不外跳、卡片置灰（30141 同义；向量未覆盖，G07）。 */
  static readonly OFF_SHELF: string = 'off_shelf';
}

/** open 成功响应 → 客户端动作（03 §7.4 表）。 */
export class OpenResponseOutcome {
  actionRaw: string = OpenActions.JUMP;
  /** 带 new_link_id 时立即替换卡片（不等确认 / 取消，BR-PRICE-12）。 */
  replaceLinkId: string | null = null;
  /** requote_failed=true：照常外跳，同时提示价格以下单页为准（BR-PRICE-13）。 */
  requoteNotice: boolean = false;
  /** 返利由 > 0 变为 0（new_rebate_max_fen = 0，BR-PRICE-13）：改价 / 券失效的确认框里追加无返利说明。 */
  rebateGone: boolean = false;
  oldFinalFen: number | null = null;
  newFinalFen: number | null = null;
}

/**
 * open 成功响应 → 动作（03 §7.4、BR-PRICE-08 / 12 / 13 / 14）。多种同时成立时 off_shelf > coupon_gone > price_changed（03 §7.4），
 * 返利归零与改价、券失效合并在同一个确认框里（rebateGone）；没有改价只有返利归零时：no_rebate_cause=price_compare 弹比价无返利
 * （BR-PRICE-08，替代通用无返利确认），其余（含未知原因，按 null）弹无返利确认。amount_unknown（context.amountUnknown=true）不做
 * 价格复核提示（BR-PRICE-08）。金额 null 保持未知、不补 0。
 * context：{ currentPriceFen, currentRebateMaxFen, amountUnknown }（点击时卡片的值）。
 */
export class OpenResponseAction {
  static map(response: Record<string, Object>, context: Record<string, Object>): OpenResponseOutcome {
    const data: Record<string, Object> = TradeJson.object(response, 'data') ?? {};
    const out: OpenResponseOutcome = new OpenResponseOutcome();
    out.replaceLinkId = TradeJson.text(data, 'new_link_id');
    out.requoteNotice = TradeJson.flag(data, 'requote_failed');
    out.oldFinalFen = TradeJson.fen(data, 'old_final_price_fen');
    out.newFinalFen = TradeJson.fen(data, 'new_final_price_fen');
    const availability: string | null = TradeJson.text(data, 'availability');
    if (availability === 'off_shelf') {
      out.actionRaw = OpenActions.OFF_SHELF;
      return out;
    }
    if (TradeJson.flag(context, 'amountUnknown')) {
      return out;
    }
    const before: number | null = TradeJson.fen(context, 'currentRebateMaxFen');
    const after: number | null = TradeJson.fen(data, 'new_rebate_max_fen');
    const rebateGone: boolean = before !== null && before > 0 && after === 0;
    const compare: boolean = rebateGone && TradeJson.text(data, 'no_rebate_cause') === 'price_compare';
    if (availability === 'coupon_gone') {
      out.actionRaw = OpenActions.CONFIRM_COUPON;
      out.rebateGone = rebateGone;
    } else if (TradeJson.flag(data, 'price_changed')) {
      out.actionRaw = OpenActions.CONFIRM_PRICE;
      out.rebateGone = rebateGone;
    } else if (compare) {
      out.actionRaw = OpenActions.COMPARE_NO_REBATE;
      out.rebateGone = true;
    } else if (rebateGone) {
      out.actionRaw = OpenActions.CONFIRM_REBATE_GONE;
      out.rebateGone = true;
    }
    return out;
  }
}

/** open 错误动作标签。 */
export class OpenErrorActions {
  static readonly LOGIN: string = 'login';
  static readonly AUTH_SHEET: string = 'auth_sheet';
  static readonly AUTH_JUMP: string = 'auth_jump';
  static readonly NOTICE: string = 'notice';
  static readonly ERROR: string = 'error';
  static readonly RETRY_AFTER: string = 'retry_after';
  /** 30143：引导重新搜索（向量未覆盖，G08）。 */
  static readonly RESEARCH: string = 'research';
  /** 30144：按卡片 product_key + item_ref 重取卡片，之后仍须用户再点（G08）。 */
  static readonly REFETCH: string = 'refetch';
  /** 10405：强更 / 受限会话刷新由网络层与外壳处理，页面只结束加载（G08）。 */
  static readonly FORCE_UPDATE: string = 'force_update';
}

/** open 错误码 → 动作。 */
export class OpenErrorOutcome {
  actionRaw: string = OpenErrorActions.NOTICE;
  textKey: string | null = null;
  showTrace6: boolean = false;
  /** 50301 not_launched：购买按钮置灰、不弹提示（error-codes 50301）。 */
  silent: boolean = false;
  /** 给【仍去购买（无返利）】（30103、30121、30151、30153、50303，BR-ID-18、BR-PRICE-08）。 */
  offerNoRebate: boolean = false;
  /** 给【联系客服】（30103、30151、30153）。 */
  offerContact: boolean = false;
  /** 给【重试】（50303 主按钮）。 */
  offerRetry: boolean = false;

  static of(actionRaw: string, textKey: string | null, showTrace6: boolean): OpenErrorOutcome {
    const o: OpenErrorOutcome = new OpenErrorOutcome();
    o.actionRaw = actionRaw;
    o.textKey = textKey;
    o.showTrace6 = showTrace6;
    return o;
  }
}

/**
 * open 错误码 → 动作（error-codes.yaml、03 §7.4、BR-ID-17 / 18 / 22 / 24）。文案键 error.<code>.<reason> 回落 error.<code>
 * （BR-TEXT-14，ErrorActionMapper.textKey）；5xxxx 带 trace6。auth_unavailable 只提示，不拉起授权、不给无返利购买（BR-ID-24）。
 */
export class OpenErrorAction {
  static map(code: number, data: Record<string, Object>): OpenErrorOutcome {
    const reason: string | null = TradeJson.text(data, 'reason');
    const key: string | null = ErrorActionMapper.textKey(code, reason);
    const serverError: boolean = code >= 50000 && code <= 59999;
    switch (code) {
      case 10001:
        return OpenErrorOutcome.of(OpenErrorActions.LOGIN, key, false);
      case 30101:
      case 30102:
        return OpenErrorOutcome.of(reason === 'auth_unavailable' ? OpenErrorActions.NOTICE : OpenErrorActions.AUTH_SHEET,
          key, false);
      case 30111:
        return OpenErrorOutcome.of(OpenErrorActions.AUTH_JUMP, key, false);
      case 30103:
      case 30151:
      case 30153: {
        const o: OpenErrorOutcome = OpenErrorOutcome.of(OpenErrorActions.NOTICE, key, false);
        o.offerNoRebate = true;
        o.offerContact = true;
        return o;
      }
      case 30121: {
        const o: OpenErrorOutcome = OpenErrorOutcome.of(OpenErrorActions.NOTICE, key, false);
        o.offerNoRebate = true;
        return o;
      }
      case 30141:
        return OpenErrorOutcome.of(OpenErrorActions.ERROR, key, false);
      case 30143:
        return OpenErrorOutcome.of(OpenErrorActions.RESEARCH, key, false);
      case 30144:
        return OpenErrorOutcome.of(OpenErrorActions.REFETCH, key, false);
      case 10405:
        return OpenErrorOutcome.of(OpenErrorActions.FORCE_UPDATE, null, false);
      case 50301: {
        const o: OpenErrorOutcome = OpenErrorOutcome.of(OpenErrorActions.NOTICE, key, true);
        o.silent = reason === 'not_launched';
        return o;
      }
      case 50303: {
        const o: OpenErrorOutcome = OpenErrorOutcome.of(OpenErrorActions.ERROR, key, true);
        o.offerNoRebate = true;
        o.offerRetry = true;
        return o;
      }
      case 42901:
        return OpenErrorOutcome.of(OpenErrorActions.RETRY_AFTER, key, false);
      default:
        return OpenErrorOutcome.of(serverError ? OpenErrorActions.ERROR : OpenErrorActions.NOTICE, key, serverError);
    }
  }
}

/** 迟到响应的处理：是否允许继续外跳流程、是否用它更新卡片。 */
export class LateDecision {
  readonly jump: boolean;
  readonly updateCard: boolean;

  constructor(jump: boolean, updateCard: boolean) {
    this.jump = jump;
    this.updateCard = updateCard;
  }
}

/**
 * 取消、离开发起页、App 进入后台之后才到达的 open 响应：只更新卡片（新价格、new_link_id、无返利状态），不外跳、不弹确认、
 * 不上报 link_jump（03 §4.5）。这里只判「仍属于最近一次点击」的响应；更早点击的响应由执行器按点击编号直接丢弃。
 */
export class LateResponsePolicy {
  static readonly NONE: string = 'none';
  static readonly CANCEL: string = 'cancel';
  static readonly LEAVE: string = 'leave';
  static readonly BACKGROUND: string = 'background';

  static decide(interrupt: string): LateDecision {
    return new LateDecision(interrupt === LateResponsePolicy.NONE, true);
  }
}

/** 跳转方案步骤类型与结果（契约 jump_type、events.yaml link_jump.result）。 */
export class JumpTypes {
  static readonly SDK: string = 'sdk';
  static readonly SCHEME: string = 'scheme';
  static readonly UNIVERSAL_LINK: string = 'universal_link';
  static readonly H5: string = 'h5';
  static readonly COPY_TPWD: string = 'copy_tpwd';
  static readonly KNOWN: string[] = ['sdk', 'scheme', 'universal_link', 'h5', 'copy_tpwd'];

  static readonly LAUNCHED: string = 'launched';
  static readonly FAILED: string = 'failed';
  static readonly SDK_INIT_FAILED: string = 'sdk_init_failed';
  static readonly COPIED: string = 'copied';

  static readonly FINAL_OPENED: string = 'opened';
  static readonly FINAL_BROWSER: string = 'browser';
  static readonly FINAL_COPIED: string = 'copied';
  static readonly FINAL_NOT_INSTALLED: string = 'not_installed';
  static readonly FINAL_FAILED: string = 'failed';
}

/** 跳转方案的执行结果。 */
export class JumpRun {
  /** 实际执行到的步骤类型（按顺序，含初始化失败的 sdk）。 */
  readonly executed: string[];
  /** opened（拉起 App）/ browser（系统浏览器）/ copied / not_installed（未装、复制口令后仍提示安装）/ failed。 */
  readonly final: string;

  constructor(executed: string[], final: string) {
    this.executed = executed;
    this.final = final;
  }
}

/**
 * 按 primary、fallbacks 顺序执行（03 §4.5、BR-ATTR-27；客户端不自行拼 scheme、不追加兜底）：
 * - 某步 launched → 停：h5 为 browser（系统浏览器），其余 opened；
 * - copy_tpwd copied → 停：明确未安装（installed=false）时 not_installed（复制口令后仍提示安装，BR-ATTR-27 未安装列），否则 copied；
 * - failed / sdk_init_failed → 下一步；全部失败 → failed。
 * 不读时钟、不按 expire_at 判过期（G14；过期由执行器 TradeJumpExecutor 判）。stopFinal 是执行器与向量共用的同一个判定。
 */
export class JumpPlanRunner {
  /** 方案里的步骤（primary + fallbacks），保留 value 给执行器。 */
  static steps(plan: Record<string, Object>): Record<string, Object>[] {
    const out: Record<string, Object>[] = [];
    const primary: Record<string, Object> | null = TradeJson.object(plan, 'primary');
    if (primary !== null) {
      out.push(primary);
    }
    return out.concat(TradeJson.objects(plan, 'fallbacks'));
  }

  /** 某一步的结果 → 是否停下、停下时的 final；继续下一步为 null。installedApp：true / false / null（unknown）。 */
  static stopFinal(type: string, result: string, installedApp: boolean | null): string | null {
    if (result === JumpTypes.LAUNCHED) {
      return type === JumpTypes.H5 ? JumpTypes.FINAL_BROWSER : JumpTypes.FINAL_OPENED;
    }
    if (result === JumpTypes.COPIED) {
      return installedApp === false ? JumpTypes.FINAL_NOT_INSTALLED : JumpTypes.FINAL_COPIED;
    }
    return null;
  }

  /** 同步执行（向量与同步替身用）：execute 返回该步结果（launched / failed / sdk_init_failed / copied）。 */
  static run(steps: Record<string, Object>[], installedApp: boolean | null,
    execute: (index: number, step: Record<string, Object>) => string): JumpRun {
    const executed: string[] = [];
    for (let i: number = 0; i < steps.length; i++) {
      const type: string = TradeJson.text(steps[i], 'type') ?? '';
      executed.push(type);
      const final: string | null = JumpPlanRunner.stopFinal(type, execute(i, steps[i]), installedApp);
      if (final !== null) {
        return new JumpRun(executed, final);
      }
    }
    return new JumpRun(executed, JumpTypes.FINAL_FAILED);
  }

  /** 向量用：步骤结果按位置注入，未执行的结果不消费；installed.app 是注入的检测结果。 */
  static simulate(plan: Record<string, Object>, installed: Record<string, Object>, stepResults: string[]): JumpRun {
    const raw: Object | null | undefined = installed['app'];
    const app: boolean | null = typeof raw === 'boolean' ? raw as boolean : null;
    return JumpPlanRunner.run(JumpPlanRunner.steps(plan), app, (index: number, _s: Record<string, Object>): string =>
      index < stepResults.length ? stepResults[index] : JumpTypes.FAILED);
  }
}

/**
 * link_jump 的事件业务字段（specs/events.yaml；03 §4.5、§4.7）：每一步一条，不排序、不去重；phase=purchase 带本次 open 响应的
 * attempt_id 与（替换后的）link_id、duration_ms、installed；startup 只有 phase / union_platform / step / result。步骤的 value
 * （完整推广 URL、口令）一律不上报（02 §12.6）。auth_jump 不上报（AuthJumpPlan：不是购买外跳）。缺编号的 purchase 步骤不上报。
 */
export class LinkJumpEvents {
  static readonly PHASE_PURCHASE: string = 'purchase';
  static readonly PHASE_STARTUP: string = 'startup';
  private static readonly PURCHASE_FIELDS: string[] = ['union_platform', 'step', 'result', 'duration_ms', 'installed'];
  private static readonly STARTUP_FIELDS: string[] = ['union_platform', 'step', 'result'];

  static build(attemptId: string | null, linkId: string | null, steps: Record<string, Object>[],
    isAuthJump: boolean): Record<string, Object>[] {
    const out: Record<string, Object>[] = [];
    if (isAuthJump) {
      return out;
    }
    for (const step of steps) {
      const phase: string | null = TradeJson.text(step, 'phase');
      if (phase === LinkJumpEvents.PHASE_PURCHASE) {
        if (attemptId === null || linkId === null) {
          continue;
        }
        const fields: Record<string, Object> = {};
        fields['phase'] = LinkJumpEvents.PHASE_PURCHASE;
        fields['attempt_id'] = attemptId;
        fields['link_id'] = linkId;
        LinkJumpEvents.copyFields(step, fields, LinkJumpEvents.PURCHASE_FIELDS);
        out.push(fields);
      } else if (phase === LinkJumpEvents.PHASE_STARTUP) {
        const fields: Record<string, Object> = {};
        fields['phase'] = LinkJumpEvents.PHASE_STARTUP;
        LinkJumpEvents.copyFields(step, fields, LinkJumpEvents.STARTUP_FIELDS);
        out.push(fields);
      }
    }
    return out;
  }

  private static copyFields(from: Record<string, Object>, to: Record<string, Object>, keys: string[]): void {
    for (const key of keys) {
      const v: Object | null | undefined = from[key];
      if (v !== null && v !== undefined) {
        to[key] = v;
      }
    }
  }
}

/**
 * 淘宝授权方式（BR-ID-17 细则「授权方式」）：按服务端下发的 auth_methods 顺序取本端能执行的第一种，不自行增减；supported 是
 * 本端此刻的能力（web_code：系统浏览器 + 已登记的回跳；sdk_token：百川可用）。其余平台不走授权方式（拼多多走 auth_jump）。
 */
export class AuthMethodPicker {
  static readonly WEB_CODE: string = 'web_code';
  static readonly SDK_TOKEN: string = 'sdk_token';

  static pick(platform: string, authMethods: string[], supported: string[]): string | null {
    if (platform !== 'taobao') {
      return null;
    }
    for (const m of authMethods) {
      if (supported.indexOf(m) >= 0) {
        return m;
      }
    }
    return null;
  }
}
