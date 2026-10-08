/*
 * 实现前测试；只读输出，未编译运行。
 *
 * 接线约定：
 * - ../main/ets/login/OAuthLoginFlow 导出以下六个类型；
 *   纯逻辑放 Core，不让 common/core 反向依赖 Feature。
 * - new OAuthAttemptSession()：
 *   create(): string；launch(attempt: string)；
 *   callback(attempt: string, seq: number)；cancel()/leave()/timeout()；
 *   submit(attempt: string)。
 *   callback 只接收凭证，submit 是唯一提交边界；均为同步纯逻辑。
 *   submitted: string[]；dropped: {attempt: string, seq: number}[]。
 *   dropped 只记录被拒 callback；重复/失效 submit 不追加 submitted。
 *   a/b 是用例别名，绑定 create 返回值；seq 只是回调观测编号，
 *   不代表 nonce、时间或跨 attempt 的先后。
 * - OAuthLoginRoute.map(provider: string, response: Record<string, Object>)
 *   -> {routeRaw: string, saveSession: boolean, firstPurchaseTip?: boolean}。
 *   response 是完整外壳；只测 full、默认开启引导的候选分流。
 *   saveSession 是意图，原子保存与最终路由守卫另验。
 * - OAuthLoginErrorAction.map(provider: string, code: number,
 *   data: Record<string, Object>)
 *   -> {actionRaw: string, textKey?: string, showTrace6?: boolean}。
 *   接已有 ErrorActionMapper；reauthorize 由用户重新取尝试并授权；
 *   provider_unavailable 保留其他方式；二者不自动重试。
 * - ThirdPartyButtons.wechatVisible(platform: string, installed: boolean,
 *   adapterAvailable: boolean): boolean；
 *   ThirdPartyButtons.appleVisible(platform: string): boolean。
 *   adapterAvailable 表示已允许启用；正式微信实现为 false，
 *   true 行用于 Debug 假适配器/能力已获准的纯逻辑。
 * - BindPhoneAction.map(responseOrError: Record<string, Object>)
 *   -> {actionRaw: string, textKey?: string}。
 *   输入为本地包装 {operation, purpose?, body, headers?}；
 *   body 才是契约响应，purpose 为原请求上下文。
 *   retry_after 表示等待/交倒计时组件；发码成功不等于绑定完成。
 *   merge_confirm 只提示确认；done 后刷新 getMe 的执行另验。
 * - MergeDecision.apply(decision: string,
 *   response: Record<string, Object> | undefined)
 *   -> {resultRaw: string, saveSession: boolean}。
 *   cancelled=请求前取消；rejected=确认后收到 30411。
 *   并号成功 schema 缺失，见 gaps，不使用 LoginResponse 冒充。
 * - 可选返回字段允许 null/undefined；expect 缺字段不判定，
 *   显式 null 要求无值。raw 值是测试接线名，不是新增契约路由。
 * - gen.py 从 specs/oauth-login-vectors.json 生成 OAuthLoginVectorsData.ets，
 *   导出 OAUTH_LOGIN_VECTORS_JSON: string；--check 检查漂移；
 *   List.test.ets 导入并调用 oauthLoginVectorTest()。
 * - 每行独立状态；无 SDK、网络、真实时钟、令牌解码或持久化；无 any。
 */
import { describe, it, expect } from '@ohos/hypium';
import { OAUTH_LOGIN_VECTORS_JSON } from './OAuthLoginVectorsData';
import {
  OAuthAttemptSession,
  OAuthLoginRoute,
  OAuthLoginErrorAction,
  ThirdPartyButtons,
  BindPhoneAction,
  MergeDecision
} from '../main/ets/login/OAuthLoginFlow';

type OAuthJSON = Record<string, Object>;
type Scalar = string | number | boolean | null | undefined;

interface NamedVector {
  name: string;
}

interface AttemptStep {
  op: string;
  attempt?: string;
  seq?: number;
}

interface DroppedCallback {
  attempt: string;
  seq: number;
}

interface AttemptExpected {
  submitted: string[];
  dropped: DroppedCallback[];
}

interface AttemptVector extends NamedVector {
  steps: AttemptStep[];
  expect: AttemptExpected;
}

interface LoginExpected {
  routeRaw: string;
  saveSession: boolean;
  firstPurchaseTip?: boolean | null;
}

interface LoginVector extends NamedVector {
  provider: string;
  response: OAuthJSON;
  expect: LoginExpected;
}

interface ErrorExpected {
  actionRaw: string;
  textKey?: string | null;
  showTrace6?: boolean | null;
}

interface ErrorVector extends NamedVector {
  provider: string;
  code: number;
  data?: OAuthJSON;
  expect: ErrorExpected;
}

interface VisibleExpected {
  visible: boolean;
}

interface WechatVector extends NamedVector {
  platform: string;
  installed: boolean;
  adapterAvailable: boolean;
  expect: VisibleExpected;
}

interface AppleVector extends NamedVector {
  platform: string;
  expect: VisibleExpected;
}

interface BindExpected {
  actionRaw: string;
  textKey?: string | null;
}

interface BindVector extends NamedVector {
  response?: OAuthJSON;
  error?: OAuthJSON;
  expect: BindExpected;
}

interface MergeExpected {
  resultRaw: string;
  saveSession: boolean;
}

interface MergeVector extends NamedVector {
  decision: string;
  response?: OAuthJSON;
  expect: MergeExpected;
}

interface OAuthVectors {
  version: number;
  sources: string[];
  attempt: AttemptVector[];
  loginResult: LoginVector[];
  loginError: ErrorVector[];
  wechatButton: WechatVector[];
  appleButton: AppleVector[];
  bindPhone: BindVector[];
  merge: MergeVector[];
  gaps: string[];
}

function assertScalar(label: string, actual: Scalar, wanted: Scalar): void {
  expect(label + ' = ' + typeof actual + ':' + JSON.stringify(actual))
    .assertEqual(label + ' = ' + typeof wanted + ':' + JSON.stringify(wanted));
}

function assertText(
  label: string,
  actual: string | null | undefined,
  wanted: string | null | undefined
): void {
  if (wanted === undefined) {
    return;
  }
  const normalized: string | null = actual === undefined ? null : actual;
  assertScalar(label, normalized, wanted);
}

function assertBoolean(
  label: string,
  actual: boolean | null | undefined,
  wanted: boolean | null | undefined
): void {
  if (wanted === undefined) {
    return;
  }
  const normalized: boolean | null = actual === undefined ? null : actual;
  assertScalar(label, normalized, wanted);
}

function checkNames(group: string, rows: NamedVector[]): void {
  assertScalar(group + '.nonempty', rows.length > 0, true);
  const names: Set<string> = new Set<string>();
  for (let index: number = 0; index < rows.length; index++) {
    const name: string = rows[index].name;
    assertScalar(group + '.name present', name.length > 0, true);
    assertScalar(group + '.' + name + '.unique', names.has(name), false);
    names.add(name);
  }
}

function requireAlias(alias: string | undefined, label: string): string {
  if (alias === undefined || alias.length === 0) {
    throw new Error(label + ': 缺少 attempt 别名');
  }
  return alias;
}

function handleFor(
  alias: string | undefined,
  handles: Record<string, string>,
  label: string
): string {
  const key: string = requireAlias(alias, label);
  const handle: string = handles[key];
  if (handle === undefined) {
    throw new Error(label + ': 未创建的 attempt 别名 ' + key);
  }
  return handle;
}

function checkAttempt(row: AttemptVector): void {
  const label: string = 'attempt.' + row.name;
  const session: OAuthAttemptSession = new OAuthAttemptSession();
  const handles: Record<string, string> = {};
  const created: string[] = [];
  assertScalar(label + '.steps.nonempty', row.steps.length > 0, true);

  for (let index: number = 0; index < row.steps.length; index++) {
    const step: AttemptStep = row.steps[index];
    const context: string = label + '.steps[' + index + '].' + step.op;

    switch (step.op) {
      case 'create': {
        const alias: string = requireAlias(step.attempt, context);
        assertScalar(context + '.alias.unique', handles[alias] === undefined, true);
        const handle: string = session.create();
        assertScalar(context + '.handle.nonempty', handle.length > 0, true);
        assertScalar(context + '.handle.unique', created.indexOf(handle), -1);
        handles[alias] = handle;
        created.push(handle);
        break;
      }
      case 'launch':
        session.launch(handleFor(step.attempt, handles, context));
        break;
      case 'callback': {
        const seq: number | undefined = step.seq;
        if (seq === undefined) {
          throw new Error(context + ': 缺少 seq');
        }
        session.callback(handleFor(step.attempt, handles, context), seq);
        break;
      }
      case 'submit':
        session.submit(handleFor(step.attempt, handles, context));
        break;
      case 'cancel':
        session.cancel();
        break;
      case 'leave':
        session.leave();
        break;
      case 'timeout':
        session.timeout();
        break;
      default:
        throw new Error(context + ': 未知操作');
    }
  }

  const submitted: string[] = row.expect.submitted.map((alias: string): string => {
    return handleFor(alias, handles, label);
  });
  assertScalar(
    label + '.submitted：内容、次数、顺序',
    JSON.stringify(session.submitted),
    JSON.stringify(submitted)
  );

  assertScalar(label + '.dropped.count', session.dropped.length, row.expect.dropped.length);
  const count: number = Math.min(session.dropped.length, row.expect.dropped.length);
  for (let index: number = 0; index < count; index++) {
    const wanted: DroppedCallback = row.expect.dropped[index];
    assertScalar(
      label + '.dropped[' + index + '].attempt',
      session.dropped[index].attempt,
      handleFor(wanted.attempt, handles, label)
    );
    assertScalar(
      label + '.dropped[' + index + '].seq',
      session.dropped[index].seq,
      wanted.seq
    );
  }
}

function checkLogin(row: LoginVector): void {
  const label: string = 'loginResult.' + row.name;
  const actual = OAuthLoginRoute.map(row.provider, row.response);
  assertScalar(label + '.routeRaw', actual.routeRaw, row.expect.routeRaw);
  assertScalar(label + '.saveSession', actual.saveSession, row.expect.saveSession);
  assertBoolean(label + '.firstPurchaseTip', actual.firstPurchaseTip, row.expect.firstPurchaseTip);
}

function checkError(row: ErrorVector): void {
  const label: string = 'loginError.' + row.name;
  const empty: OAuthJSON = {};
  const data: OAuthJSON = row.data === undefined ? empty : row.data;
  const actual = OAuthLoginErrorAction.map(row.provider, row.code, data);
  assertScalar(label + '.actionRaw', actual.actionRaw, row.expect.actionRaw);
  assertText(label + '.textKey', actual.textKey, row.expect.textKey);
  assertBoolean(label + '.showTrace6', actual.showTrace6, row.expect.showTrace6);
}

function checkWechat(row: WechatVector): void {
  const actual: boolean = ThirdPartyButtons.wechatVisible(
    row.platform, row.installed, row.adapterAvailable
  );
  assertScalar('wechatButton.' + row.name + '.visible', actual, row.expect.visible);
}

function checkApple(row: AppleVector): void {
  const actual: boolean = ThirdPartyButtons.appleVisible(row.platform);
  assertScalar('appleButton.' + row.name + '.visible', actual, row.expect.visible);
}

function checkBind(row: BindVector): void {
  const label: string = 'bindPhone.' + row.name;
  const hasResponse: boolean = row.response !== undefined;
  const hasError: boolean = row.error !== undefined;
  if (hasResponse === hasError) {
    throw new Error(label + ': response/error 必须且只能有一个');
  }
  const input: OAuthJSON | undefined = hasResponse ? row.response : row.error;
  if (input === undefined) {
    throw new Error(label + ': 缺少输入');
  }
  const actual = BindPhoneAction.map(input);
  assertScalar(label + '.actionRaw', actual.actionRaw, row.expect.actionRaw);
  assertText(label + '.textKey', actual.textKey, row.expect.textKey);
}

function checkMerge(row: MergeVector): void {
  const label: string = 'merge.' + row.name;
  const actual = MergeDecision.apply(row.decision, row.response);
  assertScalar(label + '.resultRaw', actual.resultRaw, row.expect.resultRaw);
  assertScalar(label + '.saveSession', actual.saveSession, row.expect.saveSession);
}

export default function oauthLoginVectorTest() {
  describe('OAuthLoginVectors', () => {
    const root: OAuthVectors = JSON.parse(OAUTH_LOGIN_VECTORS_JSON) as OAuthVectors;

    it('manifest', 0, () => {
      assertScalar('version', root.version, 1);
      assertScalar('sources present', root.sources.length > 0, true);
      assertScalar('gaps present', root.gaps.length > 0, true);
      checkNames('attempt', root.attempt);
      checkNames('loginResult', root.loginResult);
      checkNames('loginError', root.loginError);
      checkNames('wechatButton', root.wechatButton);
      checkNames('appleButton', root.appleButton);
      checkNames('bindPhone', root.bindPhone);
      checkNames('merge', root.merge);
    });

    for (let index: number = 0; index < root.attempt.length; index++) {
      const row: AttemptVector = root.attempt[index];
      it('attempt.' + row.name, 0, () => {
        checkAttempt(row);
      });
    }

    for (let index: number = 0; index < root.loginResult.length; index++) {
      const row: LoginVector = root.loginResult[index];
      it('loginResult.' + row.name, 0, () => {
        checkLogin(row);
      });
    }

    for (let index: number = 0; index < root.loginError.length; index++) {
      const row: ErrorVector = root.loginError[index];
      it('loginError.' + row.name, 0, () => {
        checkError(row);
      });
    }

    for (let index: number = 0; index < root.wechatButton.length; index++) {
      const row: WechatVector = root.wechatButton[index];
      it('wechatButton.' + row.name, 0, () => {
        checkWechat(row);
      });
    }

    for (let index: number = 0; index < root.appleButton.length; index++) {
      const row: AppleVector = root.appleButton[index];
      it('appleButton.' + row.name, 0, () => {
        checkApple(row);
      });
    }

    for (let index: number = 0; index < root.bindPhone.length; index++) {
      const row: BindVector = root.bindPhone[index];
      it('bindPhone.' + row.name, 0, () => {
        checkBind(row);
      });
    }

    for (let index: number = 0; index < root.merge.length; index++) {
      const row: MergeVector = root.merge[index];
      it('merge.' + row.name, 0, () => {
        checkMerge(row);
      });
    }
  });
}
