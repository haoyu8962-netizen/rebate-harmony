// CT-LOCK-01：contract.lock 升版（9cd1e6f → 40cfc268）后的「新字段忽略、不报坏数据」与错误码回落测试。
// 只证明既有解析在新快照下行为不变：JumpStep.sdk、Config.platform_icons、OpenLinkResult 里 jump 步骤的 sdk、错误码 10008 / 10009、
// 30102 / 30111 的 data.reason=sharer_auth_invalid。不接新能力（百川打开指令归 F-X 百川任务、平台标识归 F-X-05）。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiOperation, ApiOperations, BundledConfig, ClientEvent, ClientEvents, ErrorCodeInfo, ErrorCodes,
  EventLinkJumpInstalled, EventLinkJumpPhase, EventLinkJumpResult, EventLinkJumpStep, EventLinkJumpUnionPlatform, RetryKind
} from 'generated';
import {
  BaichuanAdapter, BaichuanAuthResult, BaichuanOpenResult, ConfigStore, EffectKind, ErrorActionInput, ErrorActionMapper, ErrorActionState,
  ErrorEffect, LoginErrorMapper, LoginErrorResult, JumpOutcome, JumpPlanRunner, JumpPorts, JumpTypes, LinkJumpSink, OpenActions, OpenResponseAction,
  OpenResponseOutcome, PurchaseIdentity, ReplayKind, TradeJumpExecutor
} from '../../Index';
import { ConfigReply, ConfigSourceRaw } from '../main/ets/clientcore/ConfigStore';

const FUTURE: string = '2099-01-01T00:00:00Z';
const BAICHUAN_URL_SDK: string = '{"provider":"baichuan","open_by":"url","url":"https://s.click.taobao.com/t?e=abc"}';
const BAICHUAN_CODE_SDK: string = '{"provider":"baichuan","open_by":"code","page":"detail","item_id":"7a1b2c",' +
  '"taoke":{"pid":"mm_1_2_3","relation_id":"9988"}}';
const PLATFORM_ICONS: string = '{"taobao":{"url":"https://media.example.test/' + 'a'.repeat(64) + '.png","sha256":"' +
  'a'.repeat(64) + '","version":2},"jd":{"url":"https://media.example.test/' + 'b'.repeat(64) + '.svg","sha256":"' +
  'b'.repeat(64) + '","version":1}}';

/** 记下交给 SDK 的 value；按 launch 决定结果。 */
class RecordingBaichuan implements BaichuanAdapter {
  readonly opened: string[] = [];
  launch: boolean = true;

  isReady(): boolean {
    return true;
  }

  initialize(): boolean {
    return true;
  }

  retryInitIfFailed(): boolean {
    return true;
  }

  open(value: string): Promise<string> {
    this.opened.push(value);
    return Promise.resolve(this.launch ? BaichuanOpenResult.LAUNCHED : BaichuanOpenResult.FAILED);
  }

  supportsSdkToken(): boolean {
    return false;
  }

  authorize(): Promise<BaichuanAuthResult> {
    return Promise.resolve(new BaichuanAuthResult(BaichuanAuthResult.FAILED));
  }
}

class Ports implements JumpPorts {
  readonly launched: string[] = [];
  readonly opened: string[] = [];
  readonly copied: string[] = [];

  installed(_platform: string): string {
    return 'unknown';
  }

  launchApp(type: string, value: string): Promise<boolean> {
    this.launched.push(type + ':' + value);
    return Promise.resolve(false);
  }

  openBrowser(url: string): Promise<boolean> {
    this.opened.push(url);
    return Promise.resolve(true);
  }

  copy(text: string): Promise<boolean> {
    this.copied.push(text);
    return Promise.resolve(true);
  }
}

class Sink implements LinkJumpSink {
  readonly events: Record<string, Object>[] = [];

  report(fields: Record<string, Object>): void {
    this.events.push(fields);
  }
}

function plan(primaryJson: string, fallbacksJson: string = '[]', extra: string = ''): Record<string, Object> {
  return JSON.parse('{"primary":' + primaryJson + ',"fallbacks":' + fallbacksJson + ',"expire_at":"' + FUTURE + '"' +
    extra + '}') as Record<string, Object>;
}

async function run(p: Record<string, Object>, baichuan: RecordingBaichuan, ports: Ports, sink: Sink): Promise<JumpOutcome> {
  const executor: TradeJumpExecutor = new TradeJumpExecutor(ports, baichuan, sink, (): number => 0,
    (): number => Date.parse('2026-10-14T00:00:00Z'));
  return executor.execute(p, 'taobao', 'unknown', new PurchaseIdentity('att-1', 'lnk-1'));
}

function op(id: string): ApiOperation {
  return ApiOperations.byId(id) as ApiOperation;
}

function mapCode(code: number, operationId: string, dataJson: string = '{}'): ErrorEffect {
  return ErrorActionMapper.map(new ErrorActionInput(code, JSON.parse(dataJson) as Record<string, Object>, op(operationId),
    {}, false, new ErrorActionState('supported', 'full', '1.2.0')));
}

function storeWith(bodyJson: string): ConfigStore {
  let file: string | null = null;
  const store: ConfigStore = new ConfigStore((): string | null => file, (v: string | null): void => {
    file = v;
  }, (_etag: string | null, done: (reply: ConfigReply) => void): void => {
    done(new ConfigReply(ConfigReply.OK, bodyJson, null));
  }, (): number => 1790661600000, BundledConfig.DATA_JSON);
  store.onColdStart();
  return store;
}

function configBody(withIcons: boolean): string {
  const body: Record<string, Object> = JSON.parse(BundledConfig.DATA_JSON) as Record<string, Object>;
  body['dict_version'] = '2026101401';
  if (withIcons) {
    body['platform_icons'] = JSON.parse(PLATFORM_ICONS) as Record<string, Object>;
  }
  return JSON.stringify(body);
}

export default function ctLock01Test() {
  describe('CtLock01', () => {
    // ---------------------------------------------------------------- JumpStep.sdk（BaichuanOpen）
    it('jump_step_sdk_object_is_ignored_and_value_still_executed', 0, async () => {
      const baichuan: RecordingBaichuan = new RecordingBaichuan();
      const ports: Ports = new Ports();
      const sink: Sink = new Sink();
      const p: Record<string, Object> = plan('{"type":"sdk","value":"https://s.click.taobao.com/t?e=abc","sdk":' +
        BAICHUAN_URL_SDK + '}');
      expect(JumpPlanRunner.steps(p).length).assertEqual(1);
      const out: JumpOutcome = await run(p, baichuan, ports, sink);
      // 与升版前相同：sdk 步骤只把 value 原样交给 SDK，sdk 对象不改变执行与结论
      expect(JSON.stringify(baichuan.opened)).assertEqual('["https://s.click.taobao.com/t?e=abc"]');
      expect(out.run.final).assertEqual(JumpTypes.FINAL_OPENED);
      expect(JSON.stringify(out.run.executed)).assertEqual('["sdk"]');
      expect(out.sdkUnavailable).assertFalse();
      expect(sink.events.length).assertEqual(1);
      expect(sink.events[0]['step'] as string).assertEqual('sdk');
      expect(sink.events[0]['result'] as string).assertEqual('launched');
      // 不上报 sdk_open_by / sdk_error_code（执行器尚未按 JumpStep.sdk 执行），也不把指令里的链接或 taoke 带进埋点
      expect(sink.events[0]['sdk_open_by'] === undefined).assertTrue();
      expect(sink.events[0]['sdk_error_code'] === undefined).assertTrue();
      expect(JSON.stringify(sink.events[0]).indexOf('s.click.taobao.com')).assertEqual(-1);
    });

    it('jump_step_sdk_code_instruction_falls_back_like_before', 0, async () => {
      const baichuan: RecordingBaichuan = new RecordingBaichuan();
      baichuan.launch = false;
      const ports: Ports = new Ports();
      const sink: Sink = new Sink();
      const withSdk: Record<string, Object> = plan('{"type":"sdk","value":"7a1b2c","sdk":' + BAICHUAN_CODE_SDK + '}',
        '[{"type":"copy_tpwd","value":"￥tpwd￥"}]');
      const out: JumpOutcome = await run(withSdk, baichuan, ports, sink);
      // 同一方案去掉 sdk 对象：结论逐项相同
      const baichuan2: RecordingBaichuan = new RecordingBaichuan();
      baichuan2.launch = false;
      const plain: Record<string, Object> = plan('{"type":"sdk","value":"7a1b2c"}', '[{"type":"copy_tpwd","value":"￥tpwd￥"}]');
      const out2: JumpOutcome = await run(plain, baichuan2, new Ports(), new Sink());
      expect(JSON.stringify(baichuan.opened)).assertEqual('["7a1b2c"]');
      expect(JSON.stringify(out.run.executed)).assertEqual(JSON.stringify(out2.run.executed));
      expect(out.run.final).assertEqual(out2.run.final);
      expect(out.run.final).assertEqual(JumpTypes.FINAL_COPIED);
      expect(JSON.stringify(ports.copied)).assertEqual('["￥tpwd￥"]');
      expect(sink.events.length).assertEqual(2);
    });

    // ---------------------------------------------------------------- OpenLinkResult（jump 里带 sdk 的步骤）
    it('open_link_result_with_sdk_steps_maps_to_same_action', 0, () => {
      const base: string = '"attempt_id":"att-1","requote_failed":true,"availability":"available"';
      const withSdk: Record<string, Object> = JSON.parse('{"code":0,"data":{' + base + ',"jump":{"primary":' +
        '{"type":"sdk","value":"7a1b2c","sdk":' + BAICHUAN_CODE_SDK + '},"fallbacks":[],"expire_at":"' + FUTURE +
        '"}}}') as Record<string, Object>;
      const plain: Record<string, Object> = JSON.parse('{"code":0,"data":{' + base + ',"jump":{"primary":' +
        '{"type":"sdk","value":"7a1b2c"},"fallbacks":[],"expire_at":"' + FUTURE + '"}}}') as Record<string, Object>;
      const ctx: Record<string, Object> = JSON.parse('{"currentPriceFen":1000,"currentRebateMaxFen":50}') as
      Record<string, Object>;
      const a: OpenResponseOutcome = OpenResponseAction.map(withSdk, ctx);
      const b: OpenResponseOutcome = OpenResponseAction.map(plain, ctx);
      expect(a.actionRaw).assertEqual(OpenActions.JUMP);
      expect(JSON.stringify(a)).assertEqual(JSON.stringify(b));
      expect(a.requoteNotice).assertTrue();
    });

    // ---------------------------------------------------------------- ConvertLinkRequest（无原生消费点）
    it('convert_link_operation_unchanged_and_not_bridge_signed', 0, () => {
      // 升版只改了 ConvertLinkRequest 的说明（淘宝 url 改答百川打开指令），没有新字段；原生不组请求体，H5 也不能经桥代发
      const convert: ApiOperation = op('convertLink');
      expect(convert.method).assertEqual('POST');
      expect(convert.pathTemplate).assertEqual('/v1/links/convert');
      expect(convert.signed).assertTrue();
      expect(convert.idempotent).assertTrue();
      expect(convert.auth).assertEqual('login');
      expect(ErrorActionMapper.map(new ErrorActionInput(30102, JSON.parse('{"reason":"sharer_auth_invalid"}') as
      Record<string, Object>, convert, {}, false, new ErrorActionState('supported', 'full', '1.2.0'))).replayRaw)
        .assertEqual(ReplayKind.NONE);
    });

    // ---------------------------------------------------------------- Config.platform_icons
    it('config_platform_icons_is_ignored_by_config_store', 0, () => {
      const withIcons: ConfigStore = storeWith(configBody(true));
      const plain: ConfigStore = storeWith(configBody(false));
      // 新字段不让这份配置被当成坏数据：照常成为当前配置
      expect(withIcons.sourceRaw).assertEqual(ConfigSourceRaw.CURRENT);
      expect(withIcons.value('dict_version')).assertEqual('"2026101401"');
      for (const platform of ['taobao', 'jd', 'pdd']) {
        expect(String(withIcons.searchStatus(platform))).assertEqual(String(plain.searchStatus(platform)));
      }
      expect(String(withIcons.linkPatterns())).assertEqual(String(plain.linkPatterns()));
      expect(withIcons.value('features')).assertEqual(plain.value('features'));
    });

    it('bundled_config_carries_no_platform_icons', 0, () => {
      // gen.py 把示例里的 platform_icons（示例媒体域名）与地址类字段一起去掉：包内没有替换图，客户端显示包内标识
      const bundled: Record<string, Object> = JSON.parse(BundledConfig.DATA_JSON) as Record<string, Object>;
      expect(bundled['platform_icons'] === undefined).assertTrue();
    });

    // ---------------------------------------------------------------- 错误码 10008 / 10009（只在后台）
    it('admin_only_codes_in_table_fall_back_to_generic_handling', 0, () => {
      const c10008: ErrorCodeInfo | undefined = ErrorCodes.info(10008);
      const c10009: ErrorCodeInfo | undefined = ErrorCodes.info(10009);
      expect(c10008 !== undefined && c10009 !== undefined).assertTrue();
      expect((c10008 as ErrorCodeInfo).http).assertEqual(401);
      expect((c10008 as ErrorCodeInfo).retryKind).assertEqual(RetryKind.NEVER);
      expect((c10009 as ErrorCodeInfo).retryKind).assertEqual(RetryKind.LATER);
      // 对照：表外 1xxxx（19999 不在表内）的通用回落——服务端 msg 兜底
      expect(ErrorCodes.info(19999) === undefined).assertTrue();
      const unlisted: ErrorEffect = mapCode(19999, 'getMe');
      expect(unlisted.effectKindRaw).assertEqual(EffectKind.FALLBACK_MESSAGE);
      const unlistedLogin: LoginErrorResult = LoginErrorMapper.map('loginBySms', 19999, {});
      for (const code of [10008, 10009]) {
        const effect: ErrorEffect = mapCode(code, 'getMe', code === 10009 ? '{"locked_until":"2026-10-14T10:00:00Z"}' : '{}');
        // R1-01：收录进表后仍沿用表外 1xxxx 的回落（fallback_message），与 19999 同一动作；不跳登录、不清会话、不重放、不登记
        expect(effect.effectKindRaw).assertEqual(EffectKind.FALLBACK_MESSAGE);
        expect(effect.effectKindRaw).assertEqual(unlisted.effectKindRaw);
        expect(effect.route === null).assertTrue();
        expect(effect.route === unlisted.route).assertTrue();
        expect(effect.replayRaw).assertEqual(unlisted.replayRaw);
        expect(effect.registerPending).assertEqual(unlisted.registerPending);
        expect(effect.textKey === null && unlisted.textKey === null).assertTrue();
        expect(effect.includeTrace6).assertEqual(unlisted.includeTrace6);
        // 登录页同样显示服务端 msg（message），与 19999 相同
        const login: LoginErrorResult = LoginErrorMapper.map('loginBySms', code, {});
        expect(login.stateRaw).assertEqual('message');
        expect(login.stateRaw).assertEqual(unlistedLogin.stateRaw);
        expect(login.textKey === null && login.route === null).assertTrue();
      }
      // 10001 新增的后台 reason（login_ticket_expired）不影响用户侧：仍是登录前置、沿用原键
      const login: ErrorEffect = mapCode(10001, 'getMe', '{"reason":"login_ticket_expired"}');
      expect(login.effectKindRaw).assertEqual(EffectKind.LOGIN);
      expect(login.replayRaw).assertEqual(ReplayKind.SAME_KEY);
    });

    // ---------------------------------------------------------------- 30102 / 30111 data.reason=sharer_auth_invalid
    it('sharer_auth_invalid_reason_parses_without_authorize', 0, () => {
      const r30102: ErrorCodeInfo = ErrorCodes.info(30102) as ErrorCodeInfo;
      const r30111: ErrorCodeInfo = ErrorCodes.info(30111) as ErrorCodeInfo;
      expect(r30102.retryKindByReason.get('sharer_auth_invalid')).assertEqual(RetryKind.NEVER);
      expect(r30111.retryKindByReason.get('sharer_auth_invalid')).assertEqual(RetryKind.NEVER);
      for (const code of [30102, 30111]) {
        const effect: ErrorEffect = mapCode(code, 'openLink', '{"reason":"sharer_auth_invalid"}');
        // 契约 retry_kind_by_reason=never：不弹授权、不重放（App 内 link_landing.invalid 的落地页处理归分享页任务）
        expect(effect.effectKindRaw).assertEqual(EffectKind.TOAST);
        expect(effect.route === null).assertTrue();
        expect(effect.replayRaw).assertEqual(ReplayKind.NONE);
        expect(effect.registerPending).assertFalse();
      }
      // 不带 reason 的 30102 / 30111 与升版前相同：授权前置
      expect(mapCode(30102, 'openLink', '{"auth_url":"https://oauth.example.test/x","state":"s"}').effectKindRaw)
        .assertEqual(EffectKind.AUTHORIZE);
      expect(mapCode(30111, 'openLink', '{"auth_jump":{"primary":{"type":"h5","value":"https://x.example.test"},' +
        '"fallbacks":[]}}').effectKindRaw).assertEqual(EffectKind.AUTHORIZE);
    });

    // ---------------------------------------------------------------- 生成物：后台接口不进 App、Agent 新接口只登记
    it('admin_operations_are_not_generated_and_agent_operations_are_registered', 0, () => {
      let admin: number = 0;
      ApiOperations.all.forEach((o: ApiOperation) => {
        if (o.pathTemplate.indexOf('/admin/') === 0) {
          admin++;
        }
      });
      expect(admin).assertEqual(0);
      for (const id of ['createAgentSession', 'getCurrentAgentSession', 'listAgentSessionMessages', 'sendAgentMessage',
        'cancelAgentRun', 'setAgentMessageFeedback', 'reportAgentMessage']) {
        expect(ApiOperations.byId(id) !== undefined).assertTrue();
      }
      // link_jump 新增可选字段在 link_id 之后：不传即不出现（AppTrade 显式传 null）
      const event: ClientEvent = ClientEvents.linkJump('purchase', EventLinkJumpPhase.PURCHASE, EventLinkJumpUnionPlatform.TAOBAO,
        EventLinkJumpStep.SDK, EventLinkJumpResult.LAUNCHED, 'att-1', 'lnk-1', null, null, 12, EventLinkJumpInstalled.UNKNOWN);
      expect(event.fields.has('sdk_open_by')).assertFalse();
      expect(event.fields.has('sdk_error_code')).assertFalse();
      expect(event.fields.get('duration_ms') as number).assertEqual(12);
      expect(event.fields.get('installed') as string).assertEqual('unknown');
    });
  });
}
