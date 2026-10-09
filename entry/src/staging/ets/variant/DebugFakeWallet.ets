// Debug / Staging 专用：钱包、提现、提现记录、收款账号与二次验证的本机假数据（APP-09 冒烟与设计稿截图），以及契约还没有的实名提交与
// 劳务协议接口（G01、G02）的假实现。只在 product=staging 编译，Release 没有本文件（tools/ci/release-scan.sh 查
// COULI_FAKE_WALLET_SERVER_APP09_6b2f41、couli_debug_wallet_scene）。由 DebugFakeServer 在启动参数打开时调用，不发任何网络请求，不做真实提现。
// 数据照 design-hifi sample-data §0、§12.1–12.3（本机用户 138****5678 / **三；不出现完整身份证号、卡号、登录号）。金额是整数分；
// 估算、上限由假服务替服务端给（客户端不算）。
// 场景（`--ps couli_debug_wallet_scene <scene>`）：
// - 缺省：可提现 ¥12.34、冻结 ¥0、已提现 ¥5、预估 ¥56.78（已收货 ¥34.56、暂缓 ¥4.56、10 月）；rules 上限 ¥12、档位 ¥5 / ¥10；收款账号支付宝；
//   提现记录 10 月 ¥10 审核中、¥8 打款未成功，9 月 ¥5 已到账（流水号）、¥6 未通过。提交：不带 token → 10003，带 token → 成功。
// - frozen / negative / risk / disabled / offline（钱包摘要断网，截 WalletStale）/ overdue / earnings（收益看板开关）。
// - realname（本机认为已实名、rules 回 30304，截 WithdrawRealName）/ realname_none（getMe 未实名：守卫先进 RealName）/ unbound（未绑收款账号，rules 30305）/ labor（rules 10004）/ condition（30303 below_min）。
// - pending（提交结果未知：断连）/ pending_busy（放弃得到 40901）/ pending_done（放弃得到 completed 成功）/ blocked（44001）/
//   estimate_fail（带金额的 rules → 50001）/ slow_estimate（带金额的 rules 晚 3 秒）/ empty_records / payout_pending（保存结果未知）/
//   payout_bank（已绑银行卡）。
// - 二次验证码：123456 成功；200020 → 20002；其余 20002。实名：身份证号末尾 406X → 30406，其余成功。
import { ApiOutcome, ApiResult, TransportFailure, WalletContractPort } from 'core';
import { FakeAnswer } from './DebugFakeSearch';

export const DEBUG_FAKE_WALLET_MARKER: string = 'COULI_FAKE_WALLET_SERVER_APP09_6b2f41';
export const DEBUG_WALLET_SCENE_KEY: string = 'couli_debug_wallet_scene';
/** 假服务里当前账号的测试手机号（只给二次验证发码；G31 本机取不到真实号码）。 */
export const DEBUG_STEP_UP_PHONE: string = '13800005678';

class FakeWithdrawal {
  id: string;
  status: string;
  review: string | null;
  amount: number;
  fee: number;
  tax: number;
  net: number;
  reason: string | null;
  failAction: string | null;
  createdAt: string;
  channelOrderId: string | null;

  constructor(id: string, status: string, review: string | null, amount: number, net: number, reason: string | null,
    failAction: string | null, createdAt: string, channelOrderId: string | null) {
    this.id = id;
    this.status = status;
    this.review = review;
    this.amount = amount;
    this.fee = 0;
    this.tax = 0;
    this.net = net;
    this.reason = reason;
    this.failAction = failAction;
    this.createdAt = createdAt;
    this.channelOrderId = channelOrderId;
  }

  json(detail: boolean): string {
    const r: Record<string, Object | null> = {};
    r['withdrawal_id'] = this.id;
    r['status'] = this.status;
    r['review_mode'] = this.review;
    r['amount_fen'] = this.amount;
    r['fee_fen'] = this.fee;
    r['tax_fen'] = this.tax;
    r['net_fen'] = this.net;
    r['payout_channel'] = 'alipay';
    r['payout_channel_name'] = '支付宝';
    r['masked_account'] = '138****5678';
    r['reason_code'] = this.reason;
    r['fail_action'] = this.failAction;
    r['created_at'] = this.createdAt;
    if (detail) {
      r['channel_order_id'] = this.channelOrderId;
    }
    return JSON.stringify(r);
  }
}

export class DebugFakeWallet implements WalletContractPort {
  static scene: string = '';
  static readonly marker: string = DEBUG_FAKE_WALLET_MARKER;
  private static serial: number = 0;
  private static readonly records: FakeWithdrawal[] = DebugFakeWallet.initialRecords();

  private static initialRecords(): FakeWithdrawal[] {
    return [
      new FakeWithdrawal('W2026100800003', 'FAILED', 'manual', 800, 800, 'PAYEE_ACCOUNT_STATUS_ERROR',
        'change_payout_account', '2026-10-08T11:30:00+08:00', null),
      new FakeWithdrawal('W2026092700002', 'PAID_API', 'auto', 500, 500, null, null, '2026-09-27T15:20:00+08:00',
        '20260928200040011100'),
      new FakeWithdrawal('W2026092500001', 'REJECTED', 'manual', 600, 600, 'USER_REQUEST', null,
        '2026-09-25T10:00:00+08:00', null)
    ];
  }

  /** 钱包类接口（/v1/wallet、/v1/withdrawals、/v1/me/payout-account、/v1/auth/step-up、step_up 发码、/v1/idempotency-keys）；其余为 null。 */
  static answer(url: string, method: string, body: string | null, stepUpToken: string | undefined): FakeAnswer | null {
    const path: string = url.split('?')[0];
    const scene: string = DebugFakeWallet.scene;
    if (path.endsWith('/v1/wallet/summary')) {
      return scene === 'offline' ? new FakeAnswer(-1, '', 300) : new FakeAnswer(0, DebugFakeWallet.summary(), 300);
    }
    if (path.endsWith('/v1/withdrawals/rules')) {
      return DebugFakeWallet.rules(url);
    }
    if (path.endsWith('/v1/withdrawals') && method === 'POST') {
      return DebugFakeWallet.create(body, stepUpToken);
    }
    if (path.endsWith('/v1/withdrawals')) {
      return DebugFakeWallet.list();
    }
    if (path.indexOf('/v1/withdrawals/') >= 0) {
      const id: string = decodeURIComponent(path.substring(path.indexOf('/v1/withdrawals/') + 16));
      const w: FakeWithdrawal | undefined = DebugFakeWallet.all().find((x: FakeWithdrawal) => x.id === id);
      return w === undefined ? new FakeAnswer(30701, '{}', 300) : new FakeAnswer(0, w.json(true), 300);
    }
    if (path.endsWith('/v1/me/payout-account')) {
      return method === 'PUT' ? DebugFakeWallet.savePayout(body, stepUpToken) : DebugFakeWallet.payout();
    }
    if (path.endsWith('/v1/auth/step-up')) {
      return DebugFakeWallet.stepUp(body);
    }
    if (path.endsWith('/v1/auth/sms-codes') && body !== null && body.indexOf('"step_up"') >= 0) {
      return new FakeAnswer(0, '{"resend_after_sec":60,"expires_in_sec":300}', 300);
    }
    if (path.endsWith('/v1/idempotency-keys/abandon')) {
      return DebugFakeWallet.abandon();
    }
    if (path.endsWith('/v1/me')) {
      return new FakeAnswer(0, '{"user_id":"debug-stub-user","phone_bound":true,"realname_status":"'
        + (scene === 'realname_none' && !DebugFakeWallet.realnameDone ? 'none' : 'verified') + '"}', 200);
    }
    return null;
  }

  private static realnameDone: boolean = false;
  private static laborSigned: boolean = false;
  private static payoutBound: boolean = true;
  private static submitted: FakeWithdrawal | null = null;

  private static all(): FakeWithdrawal[] {
    const s: FakeWithdrawal | null = DebugFakeWallet.submitted;
    const pending: FakeWithdrawal = s ?? new FakeWithdrawal('W2026101200001', 'PENDING_REVIEW', 'manual', 1000, 1000,
      null, null, '2026-10-12T10:00:00+08:00', null);
    return [pending].concat(DebugFakeWallet.records);
  }

  private static summary(): string {
    const scene: string = DebugFakeWallet.scene;
    const r: Record<string, Object | null> = {};
    r['available_fen'] = 1234;
    r['withdrawable_fen'] = 1234;
    r['negative_fen'] = 0;
    r['frozen_fen'] = 0;
    r['estimated_total_fen'] = 5678;
    r['estimated_fen'] = 2222;
    r['pending_credit_fen'] = 3456;
    r['pending_credit_paused_fen'] = 456;
    r['next_credit_period'] = '2026-10';
    r['credit_overdue'] = false;
    r['withdrawn_fen'] = 500;
    r['risk_paused_reason'] = null;
    r['withdraw_enabled'] = true;
    if (scene === 'frozen') {
      r['available_fen'] = 234;
      r['withdrawable_fen'] = 234;
      r['frozen_fen'] = 1000;
      r['pending_credit_paused_fen'] = 0;
    } else if (scene === 'negative') {
      r['available_fen'] = -567;
      r['withdrawable_fen'] = 0;
      r['negative_fen'] = 567;
      r['pending_credit_paused_fen'] = 0;
    } else if (scene === 'risk') {
      r['risk_paused_reason'] = 'abnormal_trade';
    } else if (scene === 'disabled') {
      r['withdraw_enabled'] = false;
    } else if (scene === 'overdue') {
      r['next_credit_period'] = null;
      r['credit_overdue'] = true;
    }
    return JSON.stringify(r);
  }

  private static param(url: string, name: string): string | null {
    const q: number = url.indexOf('?');
    if (q < 0) {
      return null;
    }
    for (const part of url.substring(q + 1).split('&')) {
      const eq: number = part.indexOf('=');
      if (eq > 0 && part.substring(0, eq) === name) {
        return decodeURIComponent(part.substring(eq + 1));
      }
    }
    return null;
  }

  private static rules(url: string): FakeAnswer {
    const scene: string = DebugFakeWallet.scene;
    const amountRaw: string | null = DebugFakeWallet.param(url, 'amount_fen');
    const amount: number | null = amountRaw === null ? null : Number.parseInt(amountRaw, 10);
    if (amount !== null && scene === 'estimate_fail') {
      return new FakeAnswer(50001, '{}', 300);
    }
    const r: Record<string, Object | null> = {};
    let block: number | null = null;
    let reason: string | null = null;
    if (scene === 'realname' && !DebugFakeWallet.realnameDone) {
      block = 30304;
    } else if (scene === 'unbound' && !DebugFakeWallet.payoutBound) {
      block = 30305;
    } else if (scene === 'labor' && !DebugFakeWallet.laborSigned) {
      block = 10004;
    } else if (scene === 'condition') {
      block = 30303;
      reason = 'below_min';
    } else if (scene === 'negative') {
      block = 30302;
    } else if (scene === 'disabled') {
      block = 30306;
    } else if (scene === 'risk') {
      // G11 更正：风控冻结时钱包【提现】可点，进提现页由 rules 的 30303 account_frozen 提示。
      block = 30303;
      reason = 'account_frozen';
    }
    const can: boolean = block === null;
    // 假服务替服务端算上限与估算（¥12 上限、无手续费与个税）；客户端只显示。
    const max: number = can ? 1200 : 0;
    r['can_withdraw'] = can;
    r['block_code'] = block;
    r['block_reason'] = reason;
    r['max_withdrawable_fen'] = max;
    r['withdrawable_fen'] = scene === 'negative' ? 0 : 1234;
    r['daily_remaining'] = 1;
    r['monthly_remaining'] = 10;
    const est: boolean = can && amount !== null && !Number.isNaN(amount) && amount > 0 && amount <= max;
    r['est_fee_fen'] = est ? 0 : null;
    r['est_tax_fen'] = est ? 0 : null;
    r['est_net_fen'] = est ? amount : null;
    r['quick_amounts_fen'] = can ? [500, 1000] : [];
    return new FakeAnswer(0, JSON.stringify(r), amount !== null && scene === 'slow_estimate' ? 3000 : 300);
  }

  private static create(body: string | null, token: string | undefined): FakeAnswer {
    const scene: string = DebugFakeWallet.scene;
    if (scene === 'pending' || scene === 'pending_busy' || scene === 'pending_done') {
      // 结果未知（断连）：客户端进入待确认，不换键、不自动重发。
      return new FakeAnswer(-1, '', 600);
    }
    if (token === undefined || token.length === 0) {
      return new FakeAnswer(10003, '{}', 400);
    }
    if (scene === 'blocked') {
      return new FakeAnswer(44001, '{}', 400);
    }
    let amount: number = 1000;
    try {
      const b: Record<string, Object> = JSON.parse(body ?? '{}') as Record<string, Object>;
      amount = typeof b['amount_fen'] === 'number' ? b['amount_fen'] as number : 1000;
    } catch (e) {
      amount = 1000;
    }
    DebugFakeWallet.serial++;
    const w: FakeWithdrawal = new FakeWithdrawal('W20261012' + (10000 + DebugFakeWallet.serial), 'PENDING_REVIEW',
      'manual', amount, amount, null, null, '2026-10-12T10:00:00+08:00', null);
    DebugFakeWallet.submitted = w;
    return new FakeAnswer(0, w.json(true), 600);
  }

  private static list(): FakeAnswer {
    if (DebugFakeWallet.scene === 'empty_records') {
      return new FakeAnswer(0, '{"items":[],"next_cursor":null}', 300);
    }
    const items: string[] = DebugFakeWallet.all().map((w: FakeWithdrawal): string => w.json(false));
    return new FakeAnswer(0, '{"items":[' + items.join(',') + '],"next_cursor":null}', 300);
  }

  private static payout(): FakeAnswer {
    const scene: string = DebugFakeWallet.scene;
    if (scene === 'unbound' && !DebugFakeWallet.payoutBound) {
      return new FakeAnswer(0, '{}', 300);
    }
    if (scene === 'payout_bank') {
      return new FakeAnswer(0, '{"payout_method":"bank_card","masked_account":"尾号 1234","bank_name":"招商银行",'
        + '"masked_payee_name":"**三","change_remaining_this_month":2}', 300);
    }
    return new FakeAnswer(0, '{"payout_method":"alipay","masked_account":"138****5678","masked_payee_name":"**三",'
      + '"change_remaining_this_month":2}', 300);
  }

  private static savePayout(body: string | null, token: string | undefined): FakeAnswer {
    if (DebugFakeWallet.scene === 'payout_pending') {
      return new FakeAnswer(-1, '', 600);
    }
    if (token === undefined || token.length === 0) {
      return new FakeAnswer(10003, '{}', 400);
    }
    DebugFakeWallet.payoutBound = true;
    let method: string = 'alipay';
    try {
      const b: Record<string, Object> = JSON.parse(body ?? '{}') as Record<string, Object>;
      method = b['payout_method'] === 'bank_card' ? 'bank_card' : 'alipay';
    } catch (e) {
      method = 'alipay';
    }
    return new FakeAnswer(0, method === 'bank_card'
      ? '{"payout_method":"bank_card","masked_account":"尾号 0009","bank_name":"示例银行","masked_payee_name":"**三",'
        + '"change_remaining_this_month":1}'
      : '{"payout_method":"alipay","masked_account":"zh***@example.com","masked_payee_name":"**三",'
        + '"change_remaining_this_month":1}', 600);
  }

  private static stepUp(body: string | null): FakeAnswer {
    let code: string = '';
    let action: string = 'withdraw';
    try {
      const b: Record<string, Object> = JSON.parse(body ?? '{}') as Record<string, Object>;
      code = typeof b['code'] === 'string' ? b['code'] as string : '';
      action = typeof b['action'] === 'string' ? b['action'] as string : 'withdraw';
    } catch (e) {
      code = '';
    }
    if (code === '123456') {
      DebugFakeWallet.serial++;
      return new FakeAnswer(0, '{"step_up_token":"debug-stub-step-up-' + action + '-' + DebugFakeWallet.serial
        + '","expire_at":"2099-01-01T00:00:00+08:00"}', 400);
    }
    return new FakeAnswer(code === '200030' ? 20003 : 20002, '{}', 400);
  }

  private static abandon(): FakeAnswer {
    const scene: string = DebugFakeWallet.scene;
    if (scene === 'pending_busy') {
      return new FakeAnswer(40901, '{}', 600);
    }
    if (scene === 'pending_done') {
      DebugFakeWallet.serial++;
      const w: FakeWithdrawal = new FakeWithdrawal('W2026101200001', 'PENDING_REVIEW', 'manual', 1000, 1000, null,
        null, '2026-10-12T10:00:00+08:00', null);
      DebugFakeWallet.submitted = w;
      return new FakeAnswer(0, '{"outcome":"completed","original":{"code":0,"msg":"","data":' + w.json(true) + '}}', 600);
    }
    return new FakeAnswer(0, '{"outcome":"abandoned","original":null}', 600);
  }

  // ---------------------------------------------------------------- G01、G02 的待定接口（只在 Debug 假服务）

  private static result(code: number, data: Record<string, Object>): ApiResult {
    return new ApiResult(code === 0 ? ApiOutcome.SUCCESS : ApiOutcome.BUSINESS_ERROR, code, '', data,
      'debug-stub-trace-0a1b2c', code === 0 ? 200 : 400, TransportFailure.NONE, null, null, null);
  }

  private static later(result: ApiResult): Promise<ApiResult> {
    return new Promise<ApiResult>((resolve: (r: ApiResult) => void) => {
      setTimeout(() => resolve(result), 500);
    });
  }

  submitRealname(_name: string, idNo: string): Promise<ApiResult> {
    if (idNo.endsWith('406X')) {
      return DebugFakeWallet.later(DebugFakeWallet.result(30406, {}));
    }
    DebugFakeWallet.realnameDone = true;
    return DebugFakeWallet.later(DebugFakeWallet.result(0, {}));
  }

  getLaborAgreement(): Promise<ApiResult> {
    const data: Record<string, Object> = {};
    data['version'] = 'v1';
    data['text'] = '协议正文（待法务提供）\n\n法务定稿后，全文放在这里，可上下滚动阅读。\n\n'
      + '本页是 Debug 假服务的演示文本，不是正式协议。';
    data['text_sha256'] = 'debug-stub-sha256-v1';
    data['need_sign'] = !DebugFakeWallet.laborSigned;
    return DebugFakeWallet.later(DebugFakeWallet.result(0, data));
  }

  signLaborAgreement(_version: string, _textSha256: string): Promise<ApiResult> {
    DebugFakeWallet.laborSigned = true;
    return DebugFakeWallet.later(DebugFakeWallet.result(0, {}));
  }

  /** 场景切换时重置假服务的进度（实名、签署、绑卡）。 */
  static reset(scene: string): void {
    DebugFakeWallet.scene = scene;
    DebugFakeWallet.realnameDone = false;
    DebugFakeWallet.laborSigned = false;
    DebugFakeWallet.payoutBound = scene !== 'unbound';
    DebugFakeWallet.submitted = null;
  }
}
