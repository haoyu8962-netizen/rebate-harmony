/*
 * 实现前测试；只读交付，未编译运行。
 *
 * 接线约定：
 * - ../main/ets/trade/OpenTradeFlow 导出以下七个生产类型。
 *   共用纯逻辑放 Core，不让 common/core 反向依赖 Feature。
 *   本文件不实现被测替身，不使用 any。
 * - 对象参数为 Record<string, Object>；response 是完整 open 成功 envelope。
 *   金额样例为安全整数分；保留 JSON null，不补 0。
 * - new OpenAttempt(keyGenerator: () => string)；
 *   start()/timeout()/retry()/authRequired(code: number)/
 *   resendAfterAuth()/cancel()/abandon()；
 *   currentKey: string | null | undefined，abandonCalled: boolean。
 *   每行从 k1 开始；只在 start/retry/resendAfterAuth 后采样键。
 *   cancel/abandon 后是否清空 currentKey 不判定。
 *   abandonCalled 是服务端 abandon 请求标记，不是 abandon() 的调用标记；
 *   open 不属于该接口四类 action，本组应始终为 false。
 * - OpenResponseAction.map(response, context)
 *   -> { actionRaw: string, replaceLinkId?: string | null, requoteNotice: boolean }。
 *   confirm_coupon 表示券失效确认；replaceLinkId 不等待确认/取消结果。
 * - OpenErrorAction.map(code: number, data: Record<string, Object>)
 *   -> { actionRaw: string, textKey?: string | null, showTrace6: boolean }。
 *   接已有错误映射；notice 为业务提示分类，error 为购买受阻错误态；
 *   按钮、路由、置灰等未表达效果见 gaps，不能视为已验收。
 * - LateResponsePolicy.decide(interrupt: string)
 *   -> { jump: boolean, updateCard: boolean }。
 *   只判最近一次点击；jump 是继续响应处理的许可，不越过确认框。
 * - JumpPlanRunner.simulate(plan, installed, stepResults: string[])
 *   -> { executed: string[], final: string }。
 *   installed.app 是注入的目标 App 检测结果，不访问设备。
 *   stepResults 按 primary + fallbacks 位置排列，未执行结果不消费。
 *   executed 包含初始化失败的 sdk；sdk_init_failed 是重试后仍失败。
 *   browser 是系统浏览器；not_installed 行是未安装复制口令后的安装提示。
 *   不读取系统时钟，不据示例 expire_at 判断过期。
 * - LinkJumpEvents.build(attemptId: string | null, linkId: string | null,
 *   steps: Record<string, Object>[], isAuthJump: boolean)
 *   -> Record<string, Object>[]。
 *   steps 为每步观测：phase/union_platform/step/result，
 *   purchase 另含 duration_ms、installed 字符串；value 不得上报。
 *   返回事件业务字段，不含 Tracker 公共外壳；完整比较、不排序事件、不去重。
 * - AuthMethodPicker.pick(platform: string, authMethods: string[],
 *   supported: string[]): string | null；platform 为联盟平台；
 *   supported 注入当前端能力，不表示三端 SDK 已验证。
 * - actionRaw/final 是接线标签；expect 缺字段不判定，null 必须无值。
 *   可选文本属性的 undefined 与 null 均表示无值；pick 无选择须返回 null。
 * - gen.py 从 specs/open-trade-vectors.json 生成 OpenTradeVectorsData.ets，
 *   导出 OPEN_TRADE_VECTORS_JSON；--check 检查漂移。
 *   List.test.ets 导入并调用 openTradeVectorTest()。
 */
import { describe, it, expect } from '@ohos/hypium';
import { OPEN_TRADE_VECTORS_JSON } from './OpenTradeVectorsData';
import {
  OpenAttempt,
  OpenResponseAction,
  OpenErrorAction,
  LateResponsePolicy,
  JumpPlanRunner,
  LinkJumpEvents,
  AuthMethodPicker
} from '../main/ets/trade/OpenTradeFlow';

type Scalar = string | number | boolean | null | undefined;

interface NamedVector {
  name: string;
}

interface AttemptStep {
  op: string;
  code?: number;
}

interface AttemptExpected {
  keys: string[];
  abandonCalled?: boolean;
}

interface AttemptVector extends NamedVector {
  steps: AttemptStep[];
  expect: AttemptExpected;
}

interface ResponseExpected {
  actionRaw: string;
  replaceLinkId?: string | null;
  requoteNotice?: boolean;
}

interface ResponseVector extends NamedVector {
  response: Record<string, Object>;
  context: Record<string, Object>;
  expect: ResponseExpected;
}

interface ErrorExpected {
  actionRaw: string;
  textKey?: string | null;
  showTrace6?: boolean;
}

interface ErrorVector extends NamedVector {
  code: number;
  data?: Record<string, Object>;
  expect: ErrorExpected;
}

interface LateExpected {
  jump: boolean;
  updateCard: boolean;
}

interface LateVector extends NamedVector {
  interrupt: string;
  expect: LateExpected;
}

interface JumpExpected {
  executed: string[];
  final: string;
}

interface JumpVector extends NamedVector {
  plan: Record<string, Object>;
  installed: Record<string, Object>;
  stepResults: string[];
  expect: JumpExpected;
}

interface EventsExpected {
  events: Record<string, Object>[];
}

interface EventsVector extends NamedVector {
  attemptId: string | null;
  linkId: string | null;
  steps: Record<string, Object>[];
  isAuthJump: boolean;
  expect: EventsExpected;
}

interface MethodsExpected {
  chosen: string | null;
}

interface MethodsVector extends NamedVector {
  platform: string;
  authMethods: string[];
  supported: string[];
  expect: MethodsExpected;
}

interface OpenTradeVectors {
  version: number;
  sources: string[];
  idempotency: AttemptVector[];
  openResponse: ResponseVector[];
  openError: ErrorVector[];
  lateResponse: LateVector[];
  jumpPlan: JumpVector[];
  linkJump: EventsVector[];
  authMethods: MethodsVector[];
  gaps: string[];
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

function assertFlag(
  label: string,
  actual: boolean,
  expected: boolean | undefined
): void {
  if (expected !== undefined) {
    assertScalar(label, actual, expected);
  }
}

function assertStrings(label: string, actual: string[], expected: string[]): void {
  assertScalar(label, JSON.stringify(actual), JSON.stringify(expected));
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

function checkAttempt(row: AttemptVector): void {
  const label: string = 'idempotency.' + row.name;
  let generated: number = 0;
  const attempt: OpenAttempt = new OpenAttempt((): string => {
    generated += 1;
    return 'k' + generated;
  });
  const keys: string[] = [];

  for (let index: number = 0; index < row.steps.length; index++) {
    const step: AttemptStep = row.steps[index];
    const stepLabel: string = label + '.steps[' + index + '].' + step.op;
    let sent: boolean = false;

    switch (step.op) {
      case 'start':
        attempt.start();
        sent = true;
        break;
      case 'timeout': {
        const before: string | null | undefined = attempt.currentKey;
        attempt.timeout();
        assertScalar(stepLabel, attempt.currentKey, before);
        break;
      }
      case 'retry':
        attempt.retry();
        sent = true;
        break;
      case 'authRequired': {
        const code: number | undefined = step.code;
        if (code === undefined) {
          throw new Error(stepLabel + ': 缺少 code');
        }
        attempt.authRequired(code);
        break;
      }
      case 'resendAfterAuth':
        attempt.resendAfterAuth();
        sent = true;
        break;
      case 'cancel':
        attempt.cancel();
        break;
      case 'abandon':
        attempt.abandon();
        break;
      default:
        throw new Error(stepLabel + ': 未知操作');
    }

    if (sent) {
      const key: string | null | undefined = attempt.currentKey;
      if (key === null || key === undefined) {
        throw new Error(stepLabel + ': 缺少发送键');
      }
      keys.push(key);
    }
  }

  assertStrings(label + '.keys', keys, row.expect.keys);
  const uniqueKeys: Set<string> = new Set<string>();
  for (let index: number = 0; index < row.expect.keys.length; index++) {
    uniqueKeys.add(row.expect.keys[index]);
  }
  assertScalar(label + '.generated', generated, uniqueKeys.size);
  assertFlag(label + '.abandonCalled', attempt.abandonCalled, row.expect.abandonCalled);
}

function checkResponse(row: ResponseVector): void {
  const label: string = 'openResponse.' + row.name;
  const actual = OpenResponseAction.map(row.response, row.context);
  assertScalar(label + '.actionRaw', actual.actionRaw, row.expect.actionRaw);
  assertText(label + '.replaceLinkId', actual.replaceLinkId, row.expect.replaceLinkId);
  assertFlag(label + '.requoteNotice', actual.requoteNotice, row.expect.requoteNotice);
}

function checkError(row: ErrorVector): void {
  const label: string = 'openError.' + row.name;
  const data: Record<string, Object> = row.data === undefined ? {} : row.data;
  const actual = OpenErrorAction.map(row.code, data);
  assertScalar(label + '.actionRaw', actual.actionRaw, row.expect.actionRaw);
  assertText(label + '.textKey', actual.textKey, row.expect.textKey);
  assertFlag(label + '.showTrace6', actual.showTrace6, row.expect.showTrace6);
}

function checkLate(row: LateVector): void {
  const label: string = 'lateResponse.' + row.name;
  const actual = LateResponsePolicy.decide(row.interrupt);
  assertScalar(label + '.jump', actual.jump, row.expect.jump);
  assertScalar(label + '.updateCard', actual.updateCard, row.expect.updateCard);
}

function checkJump(row: JumpVector): void {
  const label: string = 'jumpPlan.' + row.name;
  const fallbacks: Record<string, Object>[] =
    row.plan['fallbacks'] as Record<string, Object>[];
  assertScalar(label + '.fixture', row.stepResults.length, fallbacks.length + 1);

  const actual = JumpPlanRunner.simulate(row.plan, row.installed, row.stepResults);
  assertStrings(label + '.executed', actual.executed, row.expect.executed);
  assertScalar(label + '.final', actual.final, row.expect.final);
}

function assertEvent(
  label: string,
  actual: Record<string, Object>,
  expected: Record<string, Object>
): void {
  // 事件业务字段是平铺标量。比较完整键集合，检出额外 URL、口令等字段。
  const actualKeys: string[] = Object.keys(actual).sort();
  const expectedKeys: string[] = Object.keys(expected).sort();
  assertStrings(label + '.keys', actualKeys, expectedKeys);

  for (let index: number = 0; index < expectedKeys.length; index++) {
    const key: string = expectedKeys[index];
    // JSON 字符串保留数字、布尔和字符串的类型区别。
    assertScalar(
      label + '.' + key,
      JSON.stringify(actual[key]),
      JSON.stringify(expected[key])
    );
  }
}

function checkEvents(row: EventsVector): void {
  const label: string = 'linkJump.' + row.name;
  const actual: Record<string, Object>[] = LinkJumpEvents.build(
    row.attemptId,
    row.linkId,
    row.steps,
    row.isAuthJump
  );
  assertScalar(label + '.count', actual.length, row.expect.events.length);

  if (actual.length !== row.expect.events.length) {
    return;
  }
  // 不排序数组、不去重，逐步比较；授权跳转必须返回空数组。
  for (let index: number = 0; index < row.expect.events.length; index++) {
    assertEvent(label + '.events[' + index + ']', actual[index], row.expect.events[index]);
  }
}

function checkMethods(row: MethodsVector): void {
  const label: string = 'authMethods.' + row.name;
  const actual: string | null = AuthMethodPicker.pick(
    row.platform,
    row.authMethods,
    row.supported
  );
  assertScalar(label + '.chosen', actual, row.expect.chosen);
}

export default function openTradeVectorTest() {
  describe('OpenTradeVectors', () => {
    const root: OpenTradeVectors =
      JSON.parse(OPEN_TRADE_VECTORS_JSON) as OpenTradeVectors;

    it('manifest', 0, () => {
      assertScalar('version', root.version, 1);
      assertScalar('sources present', root.sources.length > 0, true);
      assertScalar('gaps present', root.gaps.length > 0, true);
      checkNames('idempotency', root.idempotency);
      checkNames('openResponse', root.openResponse);
      checkNames('openError', root.openError);
      checkNames('lateResponse', root.lateResponse);
      checkNames('jumpPlan', root.jumpPlan);
      checkNames('linkJump', root.linkJump);
      checkNames('authMethods', root.authMethods);
    });

    for (let index: number = 0; index < root.idempotency.length; index++) {
      const row: AttemptVector = root.idempotency[index];
      it('idempotency.' + row.name, 0, () => {
        checkAttempt(row);
      });
    }

    for (let index: number = 0; index < root.openResponse.length; index++) {
      const row: ResponseVector = root.openResponse[index];
      it('openResponse.' + row.name, 0, () => {
        checkResponse(row);
      });
    }

    for (let index: number = 0; index < root.openError.length; index++) {
      const row: ErrorVector = root.openError[index];
      it('openError.' + row.name, 0, () => {
        checkError(row);
      });
    }

    for (let index: number = 0; index < root.lateResponse.length; index++) {
      const row: LateVector = root.lateResponse[index];
      it('lateResponse.' + row.name, 0, () => {
        checkLate(row);
      });
    }

    for (let index: number = 0; index < root.jumpPlan.length; index++) {
      const row: JumpVector = root.jumpPlan[index];
      it('jumpPlan.' + row.name, 0, () => {
        checkJump(row);
      });
    }

    for (let index: number = 0; index < root.linkJump.length; index++) {
      const row: EventsVector = root.linkJump[index];
      it('linkJump.' + row.name, 0, () => {
        checkEvents(row);
      });
    }

    for (let index: number = 0; index < root.authMethods.length; index++) {
      const row: MethodsVector = root.authMethods[index];
      it('authMethods.' + row.name, 0, () => {
        checkMethods(row);
      });
    }
  });
}
