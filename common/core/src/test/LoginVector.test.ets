/*
 * 实现前测试；只读输出，未编译运行。
 *
 * 接线约定：
 * - ../main/ets/login/LoginFlow 导出以下七个类型，纯逻辑放 Core，
 *   不让 common/core 反向依赖 Feature。
 * - PhoneNumber.normalize(raw: string)
 *   -> { valid: boolean, normalized?: string, reasonRaw?: string }。
 * - new AgreementState(clock: () => number)，默认未勾选；
 *   tapLogin()/check()/uncheck()/confirm(nowMillis: number)/cancel()；
 *   showConfirm、proceed: boolean，consentAtMillis: number | null | undefined。
 *   check 用注入时钟，confirm 用实参，时间为安全整数毫秒。
 * - SmsCountdown.after(code: number, retryAfterHeader: string | undefined,
 *   nowMillis: number)
 *   -> { countdownSec: number, canResend: boolean, stateRaw: string, textKey? }。
 *   code 是业务码，成功为 0，不是 HTTP 状态。
 * - CodeInput.accept(raw: string) -> { complete: boolean, digitsOnly: boolean }；
 *   报告原字符串形状：digitsOnly 表示没有非 ASCII 数字（空串为 true），
 *   complete 表示恰为六位 ASCII 数字，不测试 UI 清洗。
 * - LoginErrorMapper.map(op: string, code: number, data: Record<string, Object>)
 *   -> { stateRaw: string, textKey?, field?, route? }；
 *   接已有 ErrorActionMapper，不另造错误码表。
 * - InviteField.decide(raw: string, context: Record<string, Object>)
 *   -> { showInviteField: boolean, valid?: boolean, noticeKey? }；
 *   valid 只判注册输入语法，空值可省略，不决定能否登录。
 * - AfterLogin.plan(response: Record<string, Object>,
 *   state: Record<string, Object>): string[]；
 *   response 为向量投影，session_scope 来自实际 tokens.session_scope。
 *   返回完整会话/路由计划：save_session、resume_pending、
 *   discard_pending、enter_force_update；不排序、不去重。
 *   resume_pending 只委托 Router 守卫；实际保存、通知和邀请提示另验。
 * - 可选文本属性允许 string | null | undefined。
 *   expect 缺字段表示不判定；显式 null 表示必须无值。
 * - stateRaw 是测试接线名，不是契约枚举或路由：
 *   registration_blocked / deletion_processing / session_expired 分别对应
 *   LoginCodeBlocked / LoginDeletionProcessing / LoginSessionExpired。
 * - gen.py 从 specs/login-vectors.json 生成 LoginVectorsData.ets，
 *   --check 检查漂移；List.test.ets 导入并调用 loginVectorTest()。
 * - 每行新建状态；固定时钟，无真实网络/计时器；不使用 any。
 */
import { describe, it, expect } from '@ohos/hypium';
import { LOGIN_VECTORS_JSON } from './LoginVectorsData';
import {
  PhoneNumber,
  AgreementState,
  SmsCountdown,
  CodeInput,
  LoginErrorMapper,
  InviteField,
  AfterLogin
} from '../main/ets/login/LoginFlow';

type Scalar = string | number | boolean | null | undefined;

interface NamedVector {
  name: string;
}

interface PhoneExpected {
  valid: boolean;
  normalized?: string | null;
  reason?: string | null;
}

interface PhoneVector extends NamedVector {
  raw: string;
  expect: PhoneExpected;
}

interface AgreementStep {
  op: string;
}

interface AgreementExpected {
  showConfirm: boolean;
  proceed: boolean;
  consentRecorded: boolean;
}

interface AgreementVector extends NamedVector {
  steps: AgreementStep[];
  expect: AgreementExpected;
}

interface SmsResponse {
  code: number;
  headers?: Record<string, string>;
}

interface SmsExpected {
  countdownSec: number;
  canResend: boolean;
  stateRaw: string;
  textKey?: string | null;
}

interface SmsVector extends NamedVector {
  response: SmsResponse;
  nowMillis: number;
  expect: SmsExpected;
}

interface CodeExpected {
  complete: boolean;
  digitsOnly: boolean;
}

interface CodeVector extends NamedVector {
  input: string;
  expect: CodeExpected;
}

interface ErrorExpected {
  stateRaw: string;
  textKey?: string | null;
  field?: string | null;
  route?: string | null;
}

interface ErrorVector extends NamedVector {
  op: string;
  code: number;
  data?: Record<string, Object>;
  expect: ErrorExpected;
}

interface InviteExpected {
  showInviteField: boolean;
  valid?: boolean;
  noticeKey?: string | null;
}

interface InviteVector extends NamedVector {
  raw: string;
  context: Record<string, Object>;
  expect: InviteExpected;
}

interface AfterExpected {
  actions: string[];
}

interface AfterVector extends NamedVector {
  response: Record<string, Object>;
  state: Record<string, Object>;
  expect: AfterExpected;
}

interface LoginVectors {
  version: number;
  sources: string[];
  phone: PhoneVector[];
  agreement: AgreementVector[];
  smsSend: SmsVector[];
  code: CodeVector[];
  loginError: ErrorVector[];
  invite: InviteVector[];
  afterLogin: AfterVector[];
  gaps: string[];
}

class LoginVectorClock {
  nowMillis: number = 0;
}

function assertScalar(label: string, actual: Scalar, expected: Scalar): void {
  expect(label + ' = ' + typeof actual + ':' + JSON.stringify(actual))
    .assertEqual(label + ' = ' + typeof expected + ':' + JSON.stringify(expected));
}

function assertText(
  label: string,
  actual: string | null | undefined,
  expected: string | null | undefined
): void {
  if (expected === undefined) {
    return;
  }
  const normalized: string | null = actual === undefined ? null : actual;
  assertScalar(label, normalized, expected);
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

function checkPhone(row: PhoneVector): void {
  const label: string = 'phone.' + row.name;
  const actual = PhoneNumber.normalize(row.raw);
  assertScalar(label + '.valid', actual.valid, row.expect.valid);
  assertText(label + '.normalized', actual.normalized, row.expect.normalized);
  assertText(label + '.reason', actual.reasonRaw, row.expect.reason);
}

function checkAgreement(row: AgreementVector): void {
  const label: string = 'agreement.' + row.name;
  const clock: LoginVectorClock = new LoginVectorClock();
  const state: AgreementState = new AgreementState((): number => clock.nowMillis);
  let acceptedAt: number | null = null;

  for (let index: number = 0; index < row.steps.length; index++) {
    const op: string = row.steps[index].op;
    const context: string = label + '.steps[' + index + '].' + op;
    clock.nowMillis = 1700000000000 + index * 1000;

    switch (op) {
      case 'tapLogin':
        state.tapLogin();
        break;
      case 'check':
        state.check();
        acceptedAt = clock.nowMillis;
        assertScalar(context + '.clickTime', state.consentAtMillis, acceptedAt);
        break;
      case 'uncheck':
        state.uncheck();
        // 不规定取消勾选后的历史时间存储表示。
        break;
      case 'confirmAgree':
        assertScalar(context + '.confirmation visible', state.showConfirm, true);
        state.confirm(clock.nowMillis);
        acceptedAt = clock.nowMillis;
        assertScalar(context + '.clickTime', state.consentAtMillis, acceptedAt);
        break;
      case 'cancelConfirm':
        state.cancel();
        break;
      default:
        throw new Error(context + ': 未知操作');
    }
  }

  const recorded: boolean =
    state.consentAtMillis !== null && state.consentAtMillis !== undefined;
  assertScalar(label + '.showConfirm', state.showConfirm, row.expect.showConfirm);
  assertScalar(label + '.proceed', state.proceed, row.expect.proceed);
  assertScalar(label + '.consentRecorded', recorded, row.expect.consentRecorded);
  if (row.expect.consentRecorded) {
    assertScalar(label + '.has consent step', acceptedAt !== null, true);
    assertScalar(label + '.original click time', state.consentAtMillis, acceptedAt);
  }
}

function checkSms(row: SmsVector): void {
  const label: string = 'smsSend.' + row.name;
  let retryAfter: string | undefined = undefined;
  const headers: Record<string, string> | undefined = row.response.headers;
  if (headers !== undefined) {
    retryAfter = headers['Retry-After'];
  }
  const actual = SmsCountdown.after(row.response.code, retryAfter, row.nowMillis);
  assertScalar(label + '.countdownSec', actual.countdownSec, row.expect.countdownSec);
  assertScalar(label + '.canResend', actual.canResend, row.expect.canResend);
  assertScalar(label + '.stateRaw', actual.stateRaw, row.expect.stateRaw);
  assertText(label + '.textKey', actual.textKey, row.expect.textKey);
}

function checkCode(row: CodeVector): void {
  const label: string = 'code.' + row.name;
  const actual = CodeInput.accept(row.input);
  assertScalar(label + '.complete', actual.complete, row.expect.complete);
  assertScalar(label + '.digitsOnly', actual.digitsOnly, row.expect.digitsOnly);
}

function checkError(row: ErrorVector): void {
  const label: string = 'loginError.' + row.name;
  const data: Record<string, Object> = row.data === undefined ? {} : row.data;
  const actual = LoginErrorMapper.map(row.op, row.code, data);
  assertScalar(label + '.stateRaw', actual.stateRaw, row.expect.stateRaw);
  assertText(label + '.textKey', actual.textKey, row.expect.textKey);
  assertText(label + '.field', actual.field, row.expect.field);
  assertText(label + '.route', actual.route, row.expect.route);
}

function checkInvite(row: InviteVector): void {
  const label: string = 'invite.' + row.name;
  const actual = InviteField.decide(row.raw, row.context);
  assertScalar(
    label + '.showInviteField',
    actual.showInviteField,
    row.expect.showInviteField
  );
  if (row.expect.valid !== undefined) {
    assertScalar(label + '.valid', actual.valid, row.expect.valid);
  }
  assertText(label + '.noticeKey', actual.noticeKey, row.expect.noticeKey);
}

function checkAfter(row: AfterVector): void {
  const label: string = 'afterLogin.' + row.name;
  const actual: string[] = AfterLogin.plan(row.response, row.state);
  // 比较完整数组，保留顺序与重复项，防止多次恢复或先恢复后保存。
  assertScalar(
    label + '.actions',
    JSON.stringify(actual),
    JSON.stringify(row.expect.actions)
  );
}

export default function loginVectorTest() {
  describe('LoginVectors', () => {
    const root: LoginVectors = JSON.parse(LOGIN_VECTORS_JSON) as LoginVectors;

    it('manifest', 0, () => {
      assertScalar('version', root.version, 1);
      assertScalar('sources present', root.sources.length > 0, true);
      assertScalar('gaps present', root.gaps.length > 0, true);
      checkNames('phone', root.phone);
      checkNames('agreement', root.agreement);
      checkNames('smsSend', root.smsSend);
      checkNames('code', root.code);
      checkNames('loginError', root.loginError);
      checkNames('invite', root.invite);
      checkNames('afterLogin', root.afterLogin);
    });

    for (let index: number = 0; index < root.phone.length; index++) {
      const row: PhoneVector = root.phone[index];
      it('phone.' + row.name, 0, () => {
        checkPhone(row);
      });
    }

    for (let index: number = 0; index < root.agreement.length; index++) {
      const row: AgreementVector = root.agreement[index];
      it('agreement.' + row.name, 0, () => {
        checkAgreement(row);
      });
    }

    for (let index: number = 0; index < root.smsSend.length; index++) {
      const row: SmsVector = root.smsSend[index];
      it('smsSend.' + row.name, 0, () => {
        checkSms(row);
      });
    }

    for (let index: number = 0; index < root.code.length; index++) {
      const row: CodeVector = root.code[index];
      it('code.' + row.name, 0, () => {
        checkCode(row);
      });
    }

    for (let index: number = 0; index < root.loginError.length; index++) {
      const row: ErrorVector = root.loginError[index];
      it('loginError.' + row.name, 0, () => {
        checkError(row);
      });
    }

    for (let index: number = 0; index < root.invite.length; index++) {
      const row: InviteVector = root.invite[index];
      it('invite.' + row.name, 0, () => {
        checkInvite(row);
      });
    }

    for (let index: number = 0; index < root.afterLogin.length; index++) {
      const row: AfterVector = root.afterLogin[index];
      it('afterLogin.' + row.name, 0, () => {
        checkAfter(row);
      });
    }
  });
}
