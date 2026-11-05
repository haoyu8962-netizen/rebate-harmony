// Debug / Staging 专用：「我的」、设置、封禁 / 冻结说明与申诉的本机假数据（APP-12 冒烟与设计稿截图），以及契约还没有的改昵称与通知设置接口
// （G01、G02）的假实现、推送令牌的 Debug 假来源（G17）。只在 product=staging 编译，Release 没有本文件（tools/ci/release-scan.sh 查
// COULI_FAKE_ME_SERVER_APP12_8e4b27、couli_debug_me_scene、COULI_DEBUG_PUSH_TOKEN_APP12_3a9d52）。由 DebugFakeServer 在启动参数打开时调用，
// 不发任何网络请求，不做真实账号操作。数据照 design-hifi sample-data §0、§7、§11、§12.3（凑狸用户 / 小狸爱买买、K7M3QX、138****5678）。
// 场景（`--ps couli_debug_me_scene <scene>`）：缺省（正常、已绑定邀请人）/ unbound / minor（invite_code=null）/ error（getMe 50001）/
// bad（getMe 坏数据）/ frozen / frozen_none / frozen_appealing / frozen_upheld / banned / banned_appealing / banned_upheld / lifted /
// new_category / normal_10006。banned* 与 normal_10006 场景下钱包摘要回 10006（经真实网络层落到 RiskNotice）。
// 改昵称：含 sensitive → 20001 nickname_sensitive；本月第 4 次 → 30415。通知设置：notify_fail 场景的 PUT → 50001。
// APP-12v（「我的」视觉设备用例与截图，数值照 specs/me-vectors.json visualMe）：new_user（R8T4WN、未绑、0/0/0、可补填）/ negative
// （available −567、withdrawable 0）/ long（16 字昵称、9999999 / 99999999）/ slow（getMe 延迟 8 s，拍骨架；低于网络层 10 s 超时）/ offline（getMe 传输失败）/
// rate（getMe 42901 + Retry-After 60）/ refresh_fail（每次 reset 后第一次成功、之后 50001）/ earnings（/v1/config 收益看板开关开）。
// getMe 计数：每收到一次 GET /v1/me（任何场景、任何假服务答），preferences「couli_debug_fake」键 me.get_count 加 1（十进制字符串，
// flushSync；只记次数不记内容；与 HM-05r clipboard.auto_probes 同一文件同一写法）。Release 没有本文件。
// APP-12w-b（H-P15，只插入行）：about_filed（agent.filing_text = 画板占位句）/ about_unfiled（空串）/ cs_no_kf（不补 kf.url）/ cs_http
// （http 客服链接）/ consent_fail（POST /v1/consents 回 50001）。同意记录计数：每收到一次 POST /v1/consents（任何场景、不论成败），
// preferences「couli_debug_fake」键 me.consents_count 加 1，并把请求体 type 写进 me.consents_last_type（只记次数与 type）。
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ApiOutcome, ApiResult, LocalRejectReason, MeContractPort, PushTokenSource, TransportFailure
} from 'core';
import { FakeAnswer } from './DebugFakeSearch';
import { DebugFakeWallet } from './DebugFakeWallet';

export const DEBUG_FAKE_ME_MARKER: string = 'COULI_FAKE_ME_SERVER_APP12_8e4b27';
export const DEBUG_ME_SCENE_KEY: string = 'couli_debug_me_scene';
export const DEBUG_PUSH_TOKEN_MARKER: string = 'COULI_DEBUG_PUSH_TOKEN_APP12_3a9d52';
const FAKE_FILE: string = 'couli_debug_fake';
const GET_ME_COUNT_KEY: string = 'me.get_count';
const CONSENTS_COUNT_KEY: string = 'me.consents_count';
const CONSENTS_TYPE_KEY: string = 'me.consents_last_type';
// APP-12w-c-harmony H-R15 / D-3：申诉提交 / 列表计数与最近一次提交的请求体（设备红线 ① ② 数请求；只在 staging）。
const APPEAL_SUBMIT_COUNT_KEY: string = 'me.appeal_submit_count';
const APPEAL_LAST_BODY_KEY: string = 'me.appeal_last_body';
const APPEAL_LIST_COUNT_KEY: string = 'me.appeal_list_count';
const FILED_PLACEHOLDER: string = '[生成式 AI 服务公示文本：登记后由配置 agent.filing_text 下发，原样显示]';
const HTTP_KF_URL: string = 'http://kf.example.test/couli';
const LONG_NICKNAME: string = '一二三四五六七八九十一二三四五六';

class FakeAppeal {
  readonly id: string;
  status: string;
  readonly content: string;
  readonly createdAt: string;
  closedAt: string | null;

  constructor(id: string, status: string, content: string, createdAt: string, closedAt: string | null) {
    this.id = id;
    this.status = status;
    this.content = content;
    this.createdAt = createdAt;
    this.closedAt = closedAt;
  }

  json(): Record<string, Object | null> {
    const r: Record<string, Object | null> = {};
    r['appeal_id'] = this.id;
    r['target_type'] = 'account';
    r['target_id'] = null;
    r['status'] = this.status;
    r['content'] = this.content;
    r['created_at'] = this.createdAt;
    r['closed_at'] = this.closedAt;
    return r;
  }
}

export class DebugFakeMe implements MeContractPort {
  static scene: string = '';
  static readonly marker: string = DEBUG_FAKE_ME_MARKER;
  static nickname: string = '凑狸用户';
  private static saves: number = 0;
  private static serviceOn: boolean = true;
  private static appeals: FakeAppeal[] = [];
  private static serial: number = 0;
  /** 记下的撤回 / 个性化记录条数与推送上报条数（冒烟核对；不含令牌）。 */
  static consents: number = 0;
  static pushReports: number = 0;
  /** 写 getMe 计数用的应用上下文（BuildVariant.applyLaunchOptions 记下）。 */
  private static context: common.Context | null = null;
  /** refresh_fail：本次 reset 后已答过的 getMe 次数。 */
  private static meAnswers: number = 0;

  static bindContext(context: common.Context): void {
    DebugFakeMe.context = context;
  }

  /** 每收到一次 GET /v1/me 计数加 1（DebugFakeServer.fakeSend 在分派前调；只记次数）。 */
  static countGet(url: string, method: string): void {
    if (method !== 'GET' || !url.split('?')[0].endsWith('/v1/me')) {
      return;
    }
    const context: common.Context | null = DebugFakeMe.context;
    if (context === null) {
      return;
    }
    try {
      const prefs: preferences.Preferences = preferences.getPreferencesSync(context, { name: FAKE_FILE });
      const old: preferences.ValueType = prefs.getSync(GET_ME_COUNT_KEY, '');
      const n: number = typeof old === 'string' && (old as string).length > 0 ? Number(old as string) : 0;
      prefs.putSync(GET_ME_COUNT_KEY, String(Number.isInteger(n) ? n + 1 : 1));
      prefs.flushSync();
    } catch (e) {
      hilog.warn(0x0000, 'Couli', '%{public}s', 'fake getMe count not written');
    }
  }

  /** 每收到一次 POST /v1/consents 计数加 1，并记下请求体的 type（APP-12w-b 设备用例数 recordConsent；只记次数与 type）。 */
  static countConsent(body: string | null): void {
    const context: common.Context | null = DebugFakeMe.context;
    if (context === null) {
      return;
    }
    let type: string = '';
    try {
      const parsed: Record<string, Object> = JSON.parse(body ?? '{}') as Record<string, Object>;
      type = typeof parsed['type'] === 'string' ? parsed['type'] as string : '';
    } catch (e) {
      type = '';
    }
    try {
      const prefs: preferences.Preferences = preferences.getPreferencesSync(context, { name: FAKE_FILE });
      const old: preferences.ValueType = prefs.getSync(CONSENTS_COUNT_KEY, '');
      const n: number = typeof old === 'string' && (old as string).length > 0 ? Number(old as string) : 0;
      prefs.putSync(CONSENTS_COUNT_KEY, String(Number.isInteger(n) ? n + 1 : 1));
      prefs.putSync(CONSENTS_TYPE_KEY, type);
      prefs.flushSync();
    } catch (e) {
      hilog.warn(0x0000, 'Couli', '%{public}s', 'fake consents count not written');
    }
  }

  /**
   * APP-12w-c-harmony H-R15：每收到一次 POST /v1/me/appeals，me.appeal_submit_count 加 1 并记下请求体原文（me.appeal_last_body）；每收到一次
   * GET /v1/me/appeals，me.appeal_list_count 加 1。与 me.get_count 同一文件、同一写法（十进制字符串，flushSync）。不论场景、成败都计。
   */
  static countAppeals(method: string, body: string | null): void {
    const context: common.Context | null = DebugFakeMe.context;
    if (context === null) {
      return;
    }
    const key: string = method === 'POST' ? APPEAL_SUBMIT_COUNT_KEY : APPEAL_LIST_COUNT_KEY;
    try {
      const prefs: preferences.Preferences = preferences.getPreferencesSync(context, { name: FAKE_FILE });
      const old: preferences.ValueType = prefs.getSync(key, '');
      const n: number = typeof old === 'string' && (old as string).length > 0 ? Number(old as string) : 0;
      prefs.putSync(key, String(Number.isInteger(n) ? n + 1 : 1));
      if (method === 'POST') {
        prefs.putSync(APPEAL_LAST_BODY_KEY, body ?? '');
      }
      prefs.flushSync();
    } catch (e) {
      hilog.warn(0x0000, 'Couli', '%{public}s', 'fake appeals count not written');
    }
  }

  /**
   * APP-12w-c-harmony H-R15 视觉场景（值取 specs/risk-appeal-visual-vectors.json）：rv_* 画板数据；banned_lifted（risk normal + revoked，
   * 钱包摘要回 10006）；rv_lifted_history（risk banned + revoked）。命中时返回 true（申诉列表已按场景重置）。
   */
  private static resetVisual(s: string): boolean {
    const content: string = DebugFakeMe.SAMPLE_CONTENT;
    if (s === 'rv_banned_appealing') {
      DebugFakeMe.appeals = [new FakeAppeal('appeal-visual-b1', 'processing', content, '2026-11-02T15:00:00+08:00', null)];
    } else if (s === 'rv_banned_upheld') {
      DebugFakeMe.appeals = [new FakeAppeal('appeal-visual-b1', 'upheld', content, '2026-11-02T15:00:00+08:00',
        '2026-11-04T16:30:00+08:00')];
    } else if (s === 'rv_frozen_appealing') {
      DebugFakeMe.appeals = [new FakeAppeal('appeal-visual-f1', 'processing', content, '2026-11-03T09:20:00+08:00', null)];
    } else if (s === 'rv_frozen_upheld') {
      DebugFakeMe.appeals = [new FakeAppeal('appeal-visual-f1', 'upheld', content, '2026-11-03T09:20:00+08:00',
        '2026-11-05T15:10:00+08:00')];
    } else if (s === 'banned_lifted' || s === 'rv_lifted_history') {
      DebugFakeMe.appeals = [new FakeAppeal('appeal-visual-b1', 'revoked', content, '2026-11-02T15:00:00+08:00',
        '2026-11-04T16:30:00+08:00')];
    } else if (s === 'rv_banned' || s === 'rv_frozen' || s === 'rv_frozen_no_until' || s === 'rv_submit_normal') {
      DebugFakeMe.appeals = [];
    } else {
      return false;
    }
    return true;
  }

  static readonly SAMPLE_CONTENT: string = '这几笔订单都是我自己正常购买的，收货后没有退款，请帮忙核实。';

  /** 换场景：重置昵称、申诉与计数。 */
  static reset(scene: string): void {
    DebugFakeMe.scene = scene;
    DebugFakeMe.nickname = '凑狸用户';
    DebugFakeMe.saves = 0;
    DebugFakeMe.serviceOn = true;
    DebugFakeMe.meAnswers = 0;
    const s: string = scene;
    if (DebugFakeMe.resetVisual(s)) {
      return;
    }
    if (s === 'frozen_appealing' || s === 'banned_appealing') {
      DebugFakeMe.appeals = [new FakeAppeal('AP2026100900001', 'processing', DebugFakeMe.SAMPLE_CONTENT,
        '2026-10-09T15:00:00+08:00', null)];
    } else if (s === 'banned_upheld' || s === 'frozen_upheld') {
      DebugFakeMe.appeals = [new FakeAppeal('AP2026100800001', 'upheld', DebugFakeMe.SAMPLE_CONTENT,
        '2026-10-08T15:00:00+08:00', '2026-10-09T16:30:00+08:00')];
    } else if (s === 'lifted') {
      DebugFakeMe.appeals = [new FakeAppeal('AP2026100800002', 'revoked', DebugFakeMe.SAMPLE_CONTENT,
        '2026-10-08T15:00:00+08:00', '2026-10-09T16:30:00+08:00')];
    } else {
      DebugFakeMe.appeals = [];
    }
  }

  private static risk(): string {
    switch (DebugFakeMe.scene) {
      case 'frozen':
        return '{"state":"frozen","reason_category":"abnormal_trade","frozen_until":"2026-10-15T00:00:00+08:00"}';
      case 'frozen_none':
        return '{"state":"frozen","reason_category":null,"frozen_until":null}';
      case 'rv_frozen':
      case 'rv_frozen_upheld':
      case 'frozen_upheld':
        return '{"state":"frozen","reason_category":"abnormal_trade","frozen_until":"2026-11-30T00:00:00+08:00"}';
      case 'rv_frozen_no_until':
        return '{"state":"frozen","reason_category":"abnormal_trade","frozen_until":null}';
      case 'rv_frozen_appealing':
        return '{"state":"appealing","reason_category":"abnormal_trade","frozen_until":"2026-11-30T00:00:00+08:00"}';
      case 'frozen_appealing':
        return '{"state":"appealing","reason_category":"abnormal_trade","frozen_until":null}';
      case 'rv_banned':
      case 'rv_banned_upheld':
      case 'rv_lifted_history':
      case 'banned':
      case 'banned_upheld':
        return '{"state":"banned","reason_category":"malicious_rights","frozen_until":null}';
      case 'rv_banned_appealing':
      case 'banned_appealing':
        return '{"state":"appealing","reason_category":"malicious_rights","frozen_until":null}';
      case 'new_category':
        return '{"state":"frozen","reason_category":"new_category","frozen_until":null}';
      default:
        return '{"state":"normal","reason_category":null,"frozen_until":null}';
    }
  }

  /** GET /v1/me：13 个字段齐全（实名状态与是否绑手机沿用钱包与登录假服务的值）。 */
  private static me(): FakeAnswer {
    const scene: string = DebugFakeMe.scene;
    DebugFakeMe.meAnswers++;
    if (scene === 'error') {
      return new FakeAnswer(50001, '{}', 300);
    }
    if (scene === 'offline') {
      return new FakeAnswer(-1, '{}', 300);
    }
    if (scene === 'rate') {
      return new FakeAnswer(42901, '{}', 300, '60');
    }
    if (scene === 'refresh_fail' && DebugFakeMe.meAnswers > 1) {
      return new FakeAnswer(50001, '{}', 300);
    }
    if (scene === 'bad') {
      return new FakeAnswer(0, '{"user_id":"debug-stub-user","nickname":"' + DebugFakeMe.nickname + '"}', 300);
    }
    let realname: string = 'verified';
    const wallet: FakeAnswer | null = DebugFakeWallet.answer('/v1/me', 'GET', null, undefined);
    if (wallet !== null && wallet.data.indexOf('"none"') >= 0) {
      realname = 'none';
    }
    const r: Record<string, Object | null> = {};
    r['user_id'] = 'debug-stub-user';
    r['nickname'] = scene === 'long' ? LONG_NICKNAME : DebugFakeMe.nickname;
    r['avatar_url'] = 'https://example.test/default-avatar.png';
    r['invite_code'] = scene === 'minor' ? null : (scene === 'new_user' ? 'R8T4WN' : 'K7M3QX');
    r['inviter_bound'] = scene !== 'unbound' && scene !== 'new_user';
    const backfill: Record<string, Object | null> = {};
    backfill['eligible'] = scene === 'unbound' || scene === 'new_user';
    backfill['deadline_at'] = scene === 'unbound' ? '2026-10-12T00:00:00+08:00' :
      (scene === 'new_user' ? '2026-10-19T10:00:00+08:00' : null);
    r['invite_backfill'] = backfill;
    r['identity_level'] = 'phone';
    r['phone_bound'] = true;
    const balance: Record<string, Object | null> = {};
    balance['available_fen'] = 1234;
    balance['withdrawable_fen'] = 1234;
    balance['estimated_total_fen'] = 5678;
    if (scene === 'new_user') {
      balance['available_fen'] = 0;
      balance['withdrawable_fen'] = 0;
      balance['estimated_total_fen'] = 0;
    } else if (scene === 'negative') {
      balance['available_fen'] = -567;
      balance['withdrawable_fen'] = 0;
    } else if (scene === 'long') {
      balance['available_fen'] = 9999999;
      balance['withdrawable_fen'] = 9999999;
      balance['estimated_total_fen'] = 99999999;
    }
    r['balance'] = balance;
    r['union_bindings'] = [];
    r['realname_status'] = realname;
    r['need_reconsent'] = false;
    r['risk'] = JSON.parse(DebugFakeMe.risk()) as Object;
    return new FakeAnswer(0, JSON.stringify(r), scene === 'slow' ? 8000 : 300);
  }

  private static appealList(): FakeAnswer {
    const items: Object[] = DebugFakeMe.appeals.map((a: FakeAppeal): Object => a.json());
    const data: Record<string, Object | null> = {};
    data['items'] = items;
    data['next_cursor'] = null;
    return new FakeAnswer(0, JSON.stringify(data), 300);
  }

  /** 提交：处理中的账户申诉再次提交返回原单；否则新建一条处理中。 */
  private static submit(body: string | null): FakeAnswer {
    const processing: FakeAppeal | undefined = DebugFakeMe.appeals.find((a: FakeAppeal) => a.status === 'processing');
    if (processing !== undefined) {
      return new FakeAnswer(0, JSON.stringify(processing.json()), 500);
    }
    let content: string = '';
    try {
      const parsed: Record<string, Object> = JSON.parse(body ?? '{}') as Record<string, Object>;
      content = typeof parsed['content'] === 'string' ? parsed['content'] as string : '';
    } catch (e) {
      content = '';
    }
    if (content.indexOf('20001') >= 0) {
      return new FakeAnswer(20001, '{"fields":["content"]}', 300);
    }
    // APP-12w-c-harmony H-R15：正文含「50001」→ 50001（应答带 trace_id，错误条显示 trace6）；含「42901」→ 42901 + Retry-After 30。
    if (content.indexOf('50001') >= 0) {
      return new FakeAnswer(50001, '{}', 300);
    }
    if (content.indexOf('42901') >= 0) {
      return new FakeAnswer(42901, '{}', 300, '30');
    }
    DebugFakeMe.serial++;
    const a: FakeAppeal = new FakeAppeal('AP20261010' + (100 + DebugFakeMe.serial), 'processing', content,
      '2026-10-10T12:00:00+08:00', null);
    DebugFakeMe.appeals = [a].concat(DebugFakeMe.appeals);
    return new FakeAnswer(0, JSON.stringify(a.json()), 500);
  }

  /** 「我的」类接口；其余为 null（交给钱包、订单等假服务）。 */
  static answer(url: string, method: string, body: string | null): FakeAnswer | null {
    const path: string = url.split('?')[0];
    const scene: string = DebugFakeMe.scene;
    if (path.endsWith('/v1/me') && method === 'GET') {
      return DebugFakeMe.me();
    }
    if (path.endsWith('/v1/me/appeals')) {
      DebugFakeMe.countAppeals(method, body);
      return method === 'POST' ? DebugFakeMe.submit(body) : DebugFakeMe.appealList();
    }
    if (path.endsWith('/v1/consents')) {
      DebugFakeMe.consents++;
      DebugFakeMe.countConsent(body);
      if (scene === 'consent_fail') {
        return new FakeAnswer(50001, '{}', 300);
      }
      return new FakeAnswer(0, '{}', 300);
    }
    if (path.endsWith('/v1/devices/push-token')) {
      DebugFakeMe.pushReports++;
      return scene === 'push_10405' ? new FakeAnswer(10405, '{}', 300) : new FakeAnswer(0, '{}', 300);
    }
    if (path.indexOf('/v1/me/tips/') >= 0 && method === 'DELETE') {
      return new FakeAnswer(0, '{}', 300);
    }
    if (path.endsWith('/v1/wallet/summary') && (scene.startsWith('rv_banned') || scene === 'rv_lifted_history')) {
      // APP-12w-c-harmony H-R15：rv_banned* / rv_lifted_history 也经钱包摘要 10006 落到 RiskNotice（置 enteredBy10006）。
      return new FakeAnswer(10006, '{}', 300);
    }
    if (path.endsWith('/v1/wallet/summary') && (scene.startsWith('banned') || scene === 'normal_10006')) {
      // 封禁场景：白名单外的请求得到 10006（经真实网络层统一落到 RiskNotice，G09）。
      return new FakeAnswer(10006, '{}', 300);
    }
    return null;
  }

  /** /v1/config 的假数据补上客服链接与 AI 公示（截图用；明显的测试值）。 */
  static patchConfig(answer: FakeAnswer | null): FakeAnswer | null {
    if (answer === null || answer.code !== 0) {
      return answer;
    }
    try {
      const data: Record<string, Object> = JSON.parse(answer.data) as Record<string, Object>;
      const kf: Record<string, Object> = {};
      kf['url'] = 'https://kf.example.test/couli';
      data['kf'] = kf;
      if (DebugFakeMe.scene === 'cs_http') {
        kf['url'] = HTTP_KF_URL;
      } else if (DebugFakeMe.scene === 'cs_no_kf') {
        const noKf: Record<string, Object> = {};
        data['kf'] = noKf;
      }
      const agent: Record<string, Object> = (data['agent'] ?? {}) as Record<string, Object>;
      agent['filing_text'] = 'AI 助手使用的模型：示例大模型\n登记编号：TEST-0000000000000000';
      if (DebugFakeMe.scene === 'about_filed') {
        agent['filing_text'] = FILED_PLACEHOLDER;
      } else if (DebugFakeMe.scene === 'about_unfiled') {
        agent['filing_text'] = '';
      }
      data['agent'] = agent;
      if (DebugFakeMe.scene === 'earnings') {
        // APP-12v：收益看板开关开（配合 couli_debug_route_available Earnings 拍 MeEarningsEntry）。
        const features: Record<string, Object> = (data['features'] ?? {}) as Record<string, Object>;
        const flags: Record<string, Object> = (features['flags'] ?? {}) as Record<string, Object>;
        flags['earnings.dashboard.visible'] = true;
        features['flags'] = flags;
        data['features'] = features;
      }
      return new FakeAnswer(0, JSON.stringify(data), answer.delayMillis);
    } catch (e) {
      return answer;
    }
  }

  // ---------------------------------------------------------------- G01、G02 的待定接口（只在 Debug 假服务）

  private static result(code: number, data: Record<string, Object>): ApiResult {
    return new ApiResult(code === 0 ? ApiOutcome.SUCCESS : ApiOutcome.BUSINESS_ERROR, code, '', data,
      'debug-stub-trace-4d5e6f', code === 0 ? 200 : 400, TransportFailure.NONE, null, null, null);
  }

  private static later(result: ApiResult): Promise<ApiResult> {
    return new Promise<ApiResult>((resolve: (r: ApiResult) => void) => {
      setTimeout(() => resolve(result), 400);
    });
  }

  updateNickname(nickname: string, sendAllowed: () => boolean): Promise<ApiResult> {
    if (!sendAllowed()) {
      return Promise.resolve(ApiResult.rejected(LocalRejectReason.SEND_BLOCKED));
    }
    if (nickname.indexOf('sensitive') >= 0) {
      const data: Record<string, Object> = {};
      data['reason'] = 'nickname_sensitive';
      data['fields'] = ['nickname'];
      return DebugFakeMe.later(DebugFakeMe.result(20001, data));
    }
    if (DebugFakeMe.saves >= 3 || DebugFakeMe.scene === 'nickname_limit') {
      return DebugFakeMe.later(DebugFakeMe.result(30415, {}));
    }
    DebugFakeMe.saves++;
    DebugFakeMe.nickname = nickname;
    return DebugFakeMe.later(DebugFakeMe.result(0, {}));
  }

  getNotificationSettings(sendAllowed: () => boolean): Promise<ApiResult> {
    if (!sendAllowed()) {
      return Promise.resolve(ApiResult.rejected(LocalRejectReason.SEND_BLOCKED));
    }
    const data: Record<string, Object> = {};
    data['service'] = DebugFakeMe.serviceOn;
    return DebugFakeMe.later(DebugFakeMe.result(0, data));
  }

  putNotificationSettings(service: boolean, sendAllowed: () => boolean): Promise<ApiResult> {
    if (!sendAllowed()) {
      return Promise.resolve(ApiResult.rejected(LocalRejectReason.SEND_BLOCKED));
    }
    if (DebugFakeMe.scene === 'notify_fail') {
      return DebugFakeMe.later(DebugFakeMe.result(50001, {}));
    }
    DebugFakeMe.serviceOn = service;
    return DebugFakeMe.later(DebugFakeMe.result(0, {}));
  }
}

/**
 * 推送令牌的 Debug 假来源（G17）：本机假服务打开且隐私闸门已启动它时给测试令牌（不像密钥的明显测试值）；`--ps couli_debug_push_token_change 1`
 * 模拟令牌变化。没打开假服务时与 Release 一样无令牌。令牌值不进日志。
 */
export class DebugPushTokenSource implements PushTokenSource {
  static readonly marker: string = DEBUG_PUSH_TOKEN_MARKER;
  private started: boolean = false;
  private serial: number = 1;
  private listeners: (() => void)[] = [];
  private readonly enabled: () => boolean;

  constructor(enabled: () => boolean) {
    this.enabled = enabled;
  }

  start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.emit();
  }

  stop(): void {
    this.started = false;
  }

  current(): string | null {
    return this.started && this.enabled() ? 'debug-push-token-' + this.serial : null;
  }

  /** 模拟 SDK 通知令牌变了。 */
  change(): void {
    this.serial++;
    this.emit();
  }

  subscribe(listener: () => void): () => void {
    this.listeners.push(listener);
    return (): void => {
      this.listeners = this.listeners.filter((l: () => void): boolean => l !== listener);
    };
  }

  private emit(): void {
    for (const l of this.listeners.slice()) {
      try {
        l();
      } catch (e) {
        // 忽略。
      }
    }
  }
}
