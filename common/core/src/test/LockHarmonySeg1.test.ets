// LOCK-harmony 段 1 测试写手（D10-2108 / D10-2110；实现交回 seg1-impl-handback.md §5 的 1–6 条）：升锁 d47f660e5 后的机械适配。
// 钉的点：① link_jump 结果映射 LinkJumpEvents.toContract（Q8，core 纯函数）；② bridge_call 四项诊断字段的取值来源（Q9、D10-1612 ④ (i)）；
// ③ EventDiagnostics 纯函数；④ 首页 sdui_card_error 的诊断字段；⑤ 「系统权限」一节按类型过滤（D10-1606 ①、D10-1612 S2）；
// ⑥ MeJson.maskedPhone 与 parse 对 masked_phone 的宽容（H4）。
// 每条用例上方的「先红」一句写的是：没有本段产品改动（含升锁生成物与手写改动）时这条怎样红。本文件引用的 toContract、
// LinkJumpContractResult、EventDiagnostics、BridgeHost.SCHEMA_VERSION、BridgeContract.SCHEMA_VERSION、PrivacyCenterView.PERMISSION_KINDS、
// MeJson.maskedPhone、EventLinkJumpFailureReason 在改动前都不存在，所以整个文件（连同 core 测试模块）先是编译不过；下面另写假如能编译时
// 哪条断言值不同。
import { describe, it, expect } from '@ohos/hypium';
import {
  BridgeContract, BundledConfig, ClientEvent, ClientEvents, EventLinkJumpFailureReason, EventLinkJumpInstalled, EventLinkJumpPhase,
  EventLinkJumpResult, EventLinkJumpStep, EventLinkJumpUnionPlatform
} from 'generated';
import { SNAPSHOT_JSON } from 'generated/src/test/ContractSnapshotData';
import {
  BridgeHost, EventDiagnostics, HomeController, HomeDeps, HomeSnapshot, JumpTypes, LinkJumpContractResult, LinkJumpEvents, MeJson,
  MeLevel, MePlatform, MeRecord, PrivacyCenterView
} from '../../Index';
import { ConfigReply, ConfigStore } from '../main/ets/clientcore/ConfigStore';
import { PermissionTypeRaw } from '../main/ets/clientcore/PermissionRequester';
import { FakeState, MAIN_TAP, ManualClock, req } from './BridgeHost.test';
import { ACTIVITY, HomeFixture, ok as homeOk, page, settle } from './HomeIntegration.test';
import { meJson } from './MeIntegration.test';
import { ME_PERMISSIONS_JSON } from './MeVectorsData';

const UNKNOWN: string = 'unknown';
const BRIDGE_CALL_KEYS: string[] = ['method', 'code', 'schema_version', 'bridge_version', 'config_version', 'h5_release'];
const DIAGNOSTIC_KEYS: string[] = ['schema_version', 'bridge_version', 'config_version', 'h5_release'];

// ---------------------------------------------------------------- 公共小工具

/** 锁定快照里某个事件的字段名（specs/events.json，经 gen.py 生成的测试数据）。 */
function contractFields(eventName: string): string[] {
  const root: Record<string, Object> = JSON.parse(SNAPSHOT_JSON.get('specs/events.json') as string) as Record<string, Object>;
  const events: Record<string, Object> = root['events'] as Record<string, Object>;
  const event: Record<string, Object> = events[eventName] as Record<string, Object>;
  return Object.keys(event['fields'] as Record<string, Object>);
}

/** 锁定快照 contracts/bridge.schema.json 的顶层 version。 */
function bridgeSchemaVersion(): number {
  const root: Record<string, Object> = JSON.parse(SNAPSHOT_JSON.get('contracts/bridge.schema.json') as string) as
    Record<string, Object>;
  return root['version'] as number;
}

function sorted(values: string[]): string {
  return JSON.stringify(values.slice().sort());
}

function field(event: ClientEvent, key: string): Object | undefined {
  return event.fields.get(key) as Object | undefined;
}

/** 走真实 BridgeHost.handle：未实现方法被拒（90001），记一条 bridge_call。 */
async function refuse(host: BridgeHost, id: string): Promise<void> {
  await host.handle(req(id, 'withdrawal'), MAIN_TAP);
}

/** 包内默认配置的文本；configVersion 非 null 时另加顶层 config_version（真实包内默认配置没有这个键）。 */
function bundledWith(configVersion: string | null): string {
  if (configVersion === null) {
    return BundledConfig.DATA_JSON;
  }
  const body: Record<string, Object> = JSON.parse(BundledConfig.DATA_JSON) as Record<string, Object>;
  body['config_version'] = configVersion;
  return JSON.stringify(body);
}

/** 真实 ConfigStore（不复制取值规则）：冷启动后 reply() 结算在途拉取；没有在途拉取时先走真实的 onForeground 入口再结算。 */
class ConfigVersionRig {
  file: string | null;
  done: ((reply: ConfigReply) => void) | null = null;
  readonly store: ConfigStore;

  constructor(file: string | null = null, bundled: string = BundledConfig.DATA_JSON) {
    this.file = file;
    this.store = new ConfigStore((): string | null => this.file, (value: string | null): void => {
      this.file = value;
    }, (_etag: string | null, done: (reply: ConfigReply) => void): void => {
      this.done = done;
    }, (): number => 1790661600000, bundled);
    this.store.onColdStart();
  }

  /**
   * 成功拉取：包内默认配置再加顶层 config_version（04 §10.1：= ETag 去引号）。configVersion 为 null 时写显式 null；
   * omit 为 true 时响应不带这个键（openapi Config.config_version 不在 required 里）。
   */
  reply(configVersion: string | null, omit: boolean = false): void {
    if (this.done === null) {
      this.store.onForeground();
    }
    const body: Record<string, Object | null> = JSON.parse(BundledConfig.DATA_JSON) as Record<string, Object | null>;
    if (!omit) {
      body['config_version'] = configVersion;
    }
    const done: ((reply: ConfigReply) => void) | null = this.done;
    if (done === null) {
      throw new Error('ConfigStore did not start a fetch');
    }
    this.done = null;
    done(new ConfigReply(ConfigReply.OK, JSON.stringify(body), '"' + (configVersion ?? 'no-version') + '"'));
  }
}

/** 同 HomeFixture.controller()，另可注入 HomeDeps.configVersion（null = 不注入，走缺省）。 */
function homeController(f: HomeFixture, configVersion: (() => string) | null): HomeController {
  const deps: HomeDeps = new HomeDeps(f.identity, (): string => f.identity.key, f.lkg, f.local, f.gate);
  deps.contract = f.contract;
  deps.clock = (): number => f.timer.now;
  deps.timer = f.timer;
  deps.appVersion = '1.10.0';
  deps.dedupe = f.dedupe;
  deps.defaultJson = (): string | null => f.defaultJson;
  deps.track = (e: ClientEvent): void => {
    f.events.push(e);
  };
  deps.blockers = (): string[] => f.blockers;
  deps.coldStartShown = (): boolean => f.shownThisRun;
  deps.markColdStartShown = (): void => {
    f.shownThisRun = true;
  };
  if (configVersion !== null) {
    deps.configVersion = configVersion;
  }
  const c: HomeController = new HomeController(deps);
  c.onChange = (s: HomeSnapshot): void => {
    f.snapshots.push(s);
  };
  f.currentCtl = c;
  return c;
}

const PAGE_VERSION: number = 13;
const STATIC_BANNER: string = '"props":{"height_ratio":0.4},"data_source":{"kind":"static","items":[]}';
/** 缺 version → missing_version（卡片版本取不到）。 */
const CARD_MISSING_VERSION: string = '{"id":"mv","type":"banner",' + STATIC_BANNER + '}';
/** version 2 → unsupported_version（卡片版本 2，与页面版本 13 不同）。 */
const CARD_V2: string = '{"id":"v2","type":"banner","version":2,' + STATIC_BANNER + '}';
/** version 1、缺 props → missing_field。 */
const CARD_MISSING_PROPS: string = '{"id":"mp","type":"banner","version":1,"data_source":{"kind":"static","items":[]}}';
/** version 0 → bad_value（卡片版本是 0：转成字符串是 "0"，不能被当成取不到）。 */
const CARD_V0: string = '{"id":"v0","type":"banner","version":0,' + STATIC_BANNER + '}';
/** version 是字符串 → bad_type（取不到整数版本）。 */
const CARD_VERSION_TEXT: string = '{"id":"vs","type":"banner","version":"1",' + STATIC_BANNER + '}';

async function homeEvents(f: HomeFixture, configVersion: (() => string) | null): Promise<ClientEvent[]> {
  homeController(f, configVersion).start();
  f.contract.pages[0].resolve(homeOk(page(PAGE_VERSION, [ACTIVITY, CARD_MISSING_VERSION, CARD_V2, CARD_MISSING_PROPS, CARD_V0,
    CARD_VERSION_TEXT])));
  await settle();
  return f.events.filter((e: ClientEvent): boolean => e.name === 'sdui_card_error');
}

function byReason(events: ClientEvent[], reason: string): ClientEvent {
  const e: ClientEvent | undefined = events.find((x: ClientEvent): boolean => x.fields.get('reason') === reason);
  if (e === undefined) {
    throw new Error('no sdui_card_error with reason ' + reason);
  }
  return e;
}

/** 系统权限快照（ME_PERMISSIONS_JSON 是 gen.py 从锁定快照 specs/system-permissions.json 生成的测试数据）。 */
function snapshotPermissions(): MeRecord[] {
  const root: Record<string, Object> = JSON.parse(ME_PERMISSIONS_JSON) as Record<string, Object>;
  return root['permissions'] as MeRecord[];
}

function rowTypes(view: MeRecord): string[] {
  const rows: MeRecord[] = view['permissionRows'] as MeRecord[];
  return rows.map((r: MeRecord): string => r['type'] as string);
}

function entry(type: string, platform: string, purposeKey: string | null): MeRecord {
  const r: MeRecord = {};
  r['type'] = type;
  r['platform'] = platform;
  r['purpose_key'] = purposeKey;
  return r;
}

function me(over: string): Object {
  return JSON.parse(meJson(over)) as Object;
}

export default function lockHarmonySeg1Test() {
  describe('LockHarmonySeg1', () => {
    // ================================================================ ① LinkJumpEvents.toContract（Q8）

    // 先红：toContract / LinkJumpContractResult / EventLinkJumpFailureReason 不存在，编译不过；旧生成物的 EventLinkJumpResult 是
    // launched / copied / failed / sdk_init_failed，假如能编译，launched 期望 'requested' 会得到 'launched'。
    it('LJ1_step_words_map_to_requested_or_failed_with_reason', 0, () => {
      const launched: LinkJumpContractResult | null = LinkJumpEvents.toContract(JumpTypes.LAUNCHED);
      const copied: LinkJumpContractResult | null = LinkJumpEvents.toContract(JumpTypes.COPIED);
      const failed: LinkJumpContractResult | null = LinkJumpEvents.toContract(JumpTypes.FAILED);
      const sdkInit: LinkJumpContractResult | null = LinkJumpEvents.toContract(JumpTypes.SDK_INIT_FAILED);
      expect(launched?.result as string).assertEqual('requested');
      expect(launched?.failureReason === null).assertTrue();
      expect(copied?.result as string).assertEqual('requested');
      expect(copied?.failureReason === null).assertTrue();
      expect(failed?.result as string).assertEqual('failed');
      expect(failed?.failureReason as string).assertEqual('step_failed');
      expect(sdkInit?.result as string).assertEqual('failed');
      expect(sdkInit?.failureReason as string).assertEqual('sdk_init_failed');
      // 两种失败的原因码不能互换（sdk_init_failed 只给百川初始化失败）。
      expect(failed?.failureReason === sdkInit?.failureReason).assertFalse();
    });

    // 先红：toContract 不存在，编译不过；没有映射时 'requested' / 'unknown' 这两个契约词无处可认。
    it('LJ2_contract_words_pass_through_and_everything_else_is_null', 0, () => {
      const requested: LinkJumpContractResult | null = LinkJumpEvents.toContract('requested');
      const unknown: LinkJumpContractResult | null = LinkJumpEvents.toContract('unknown');
      expect(requested?.result as string).assertEqual('requested');
      expect(requested?.failureReason === null).assertTrue();
      expect(unknown?.result as string).assertEqual('unknown');
      expect(unknown?.failureReason === null).assertTrue();
      // 不是步骤结果词、也不是契约词的一律不上报：含最终结论词 opened、大小写不同、原因码本身、带空格的值。
      const others: (string | null)[] = [null, '', 'opened', 'browser', 'LAUNCHED', 'Failed', 'step_failed', 'copied ', 'launch'];
      for (const raw of others) {
        expect(LinkJumpEvents.toContract(raw) === null).assertTrue();
      }
    });

    // 先红：toContract 不存在，编译不过。守的错法：失败映射成 requested、failed 不带原因、requested / unknown 带了原因。
    it('LJ3_failed_always_carries_reason_and_failure_never_becomes_requested', 0, () => {
      const inputs: string[] = [JumpTypes.LAUNCHED, JumpTypes.COPIED, JumpTypes.FAILED, JumpTypes.SDK_INIT_FAILED, 'requested',
        'unknown', 'opened', 'x'];
      let mapped: number = 0;
      for (const raw of inputs) {
        const r: LinkJumpContractResult | null = LinkJumpEvents.toContract(raw);
        if (r === null) {
          continue;
        }
        mapped++;
        if (r.result === EventLinkJumpResult.FAILED) {
          expect(r.failureReason !== null).assertTrue();
        } else {
          expect(r.failureReason === null).assertTrue();
        }
      }
      expect(mapped).assertEqual(6);
      for (const raw of [JumpTypes.FAILED, JumpTypes.SDK_INIT_FAILED]) {
        const r: LinkJumpContractResult | null = LinkJumpEvents.toContract(raw);
        expect(r !== null && r.result === EventLinkJumpResult.FAILED).assertTrue();
        expect(r !== null && r.result === EventLinkJumpResult.REQUESTED).assertFalse();
      }
    });

    // 先红：linkJump 旧签名没有 failureReason 参数、toContract 不存在，编译不过。
    it('LJ4_toContract_output_feeds_ClientEvents_linkJump', 0, () => {
      const failed: LinkJumpContractResult = LinkJumpEvents.toContract(JumpTypes.FAILED) as LinkJumpContractResult;
      let threw: boolean = false;
      let event: ClientEvent | null = null;
      try {
        event = ClientEvents.linkJump('purchase', EventLinkJumpPhase.PURCHASE, EventLinkJumpUnionPlatform.TAOBAO,
          EventLinkJumpStep.SCHEME, failed.result, 'att-1', 'lnk-1', failed.failureReason, null, null, 12,
          EventLinkJumpInstalled.TRUE);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertFalse();
      expect(field(event as ClientEvent, 'result') as string).assertEqual('failed');
      expect(field(event as ClientEvent, 'failure_reason') as string).assertEqual('step_failed');

      // 百川初始化失败（phase=startup，没有 link 与尝试）。
      const sdkInit: LinkJumpContractResult = LinkJumpEvents.toContract(JumpTypes.SDK_INIT_FAILED) as LinkJumpContractResult;
      const startup: ClientEvent = ClientEvents.linkJump('startup', EventLinkJumpPhase.STARTUP, EventLinkJumpUnionPlatform.TAOBAO,
        EventLinkJumpStep.SDK, sdkInit.result, null, null, sdkInit.failureReason);
      expect(field(startup, 'result') as string).assertEqual('failed');
      expect(field(startup, 'failure_reason') as string).assertEqual(EventLinkJumpFailureReason.SDK_INIT_FAILED as string);

      const launched: LinkJumpContractResult = LinkJumpEvents.toContract(JumpTypes.LAUNCHED) as LinkJumpContractResult;
      const ok: ClientEvent = ClientEvents.linkJump('purchase', EventLinkJumpPhase.PURCHASE, EventLinkJumpUnionPlatform.TAOBAO,
        EventLinkJumpStep.SDK, launched.result, 'att-1', 'lnk-1', launched.failureReason, null, null, 12,
        EventLinkJumpInstalled.UNKNOWN);
      expect(field(ok, 'result') as string).assertEqual('requested');
      expect(ok.fields.has('failure_reason')).assertFalse();

      // 对照：failed 不带原因，生成函数直接抛（所以映射必须给原因，否则这条埋点整条丢）。
      let bare: boolean = false;
      try {
        ClientEvents.linkJump('purchase', EventLinkJumpPhase.PURCHASE, EventLinkJumpUnionPlatform.TAOBAO, EventLinkJumpStep.SDK,
          EventLinkJumpResult.FAILED, 'att-1', 'lnk-1', null, null, null, 12, EventLinkJumpInstalled.UNKNOWN);
      } catch (e) {
        bare = true;
      }
      expect(bare).assertTrue();
    });

    // ================================================================ ② bridge_call 诊断字段的取值来源

    // 先红：BridgeContract.SCHEMA_VERSION、BridgeHost.SCHEMA_VERSION 不存在，编译不过；假如能编译，旧 bridge_call 只有
    // method、code 两项，schema_version 为 undefined。
    // 局限：锁定快照里 bridge.schema.json 的 version 与 BRIDGE_VERSION 现在都是 1，运行期分不出「schema_version 借了 BRIDGE_VERSION」，
    // 这里只能钉住 BridgeContract.SCHEMA_VERSION = 快照顶层 version、事件值 = 它的字符串；来源是否借用要靠评审读 BridgeHost.ets。
    it('BC1_schema_version_from_bridge_schema_and_bridge_version_from_BRIDGE_VERSION_as_strings', 0, async () => {
      const schema: number = bridgeSchemaVersion();
      expect(BridgeContract.SCHEMA_VERSION).assertEqual(schema);
      expect(typeof BridgeHost.SCHEMA_VERSION).assertEqual('string');
      expect(BridgeHost.SCHEMA_VERSION).assertEqual(String(schema));
      const events: ClientEvent[] = [];
      const host: BridgeHost = new BridgeHost(new FakeState(), new ManualClock());
      host.track = (e: ClientEvent): void => {
        events.push(e);
      };
      await refuse(host, 'a');
      expect(events.length).assertEqual(1);
      const e: ClientEvent = events[0];
      expect(e.name).assertEqual('bridge_call');
      expect(typeof field(e, 'schema_version')).assertEqual('string');
      expect(field(e, 'schema_version') as string).assertEqual(String(schema));
      expect(typeof field(e, 'bridge_version')).assertEqual('string');
      expect(field(e, 'bridge_version') as string).assertEqual(String(BridgeHost.BRIDGE_VERSION));
      // 字段名与顺序按生成函数，字段集合与锁定快照 events.json 的 bridge_call 一致。
      expect(JSON.stringify(Array.from(e.fields.keys()))).assertEqual(JSON.stringify(BRIDGE_CALL_KEYS));
      expect(sorted(Array.from(e.fields.keys()))).assertEqual(sorted(contractFields('bridge_call')));
    });

    // 先红：BridgeHost.configVersion 不存在，编译不过；假如能编译，config_version / h5_release 为 undefined。
    // 守的错法：注入值在构造时缓存（第二次仍是 cv-1）、config_version 借用别的版本号、h5_release 填了非 unknown。
    it('BC2_config_version_is_injected_per_call_defaults_unknown_and_h5_release_unknown', 0, async () => {
      const plain: ClientEvent[] = [];
      const bare: BridgeHost = new BridgeHost(new FakeState(), new ManualClock());
      bare.track = (e: ClientEvent): void => {
        plain.push(e);
      };
      await refuse(bare, 'a');
      expect(field(plain[0], 'config_version') as string).assertEqual(UNKNOWN);
      expect(field(plain[0], 'h5_release') as string).assertEqual(UNKNOWN);

      const events: ClientEvent[] = [];
      let current: string = 'cv-1';
      const host: BridgeHost = new BridgeHost(new FakeState(), new ManualClock());
      host.track = (e: ClientEvent): void => {
        events.push(e);
      };
      host.configVersion = (): string => current;
      await refuse(host, 'a');
      current = 'cv-2';
      await refuse(host, 'b');
      expect(events.length).assertEqual(2);
      expect(field(events[0], 'config_version') as string).assertEqual('cv-1');
      expect(field(events[1], 'config_version') as string).assertEqual('cv-2');
      for (const e of events) {
        expect(field(e, 'h5_release') as string).assertEqual(UNKNOWN);
        expect(field(e, 'schema_version') as string).assertEqual(BridgeHost.SCHEMA_VERSION);
        expect(field(e, 'bridge_version') as string).assertEqual(String(BridgeHost.BRIDGE_VERSION));
      }
    });

    // ================================================================ ③ EventDiagnostics 纯函数

    // 先红：EventDiagnostics 不存在，编译不过。守的错法：把 JSON 文本原样返回（'"abc"' 带引号）、空串 / 数字 / null 不回落 unknown。
    it('ED1_configVersion_takes_only_non_empty_json_strings', 0, () => {
      expect(EventDiagnostics.UNKNOWN).assertEqual('unknown');
      expect(EventDiagnostics.configVersion(null)).assertEqual(UNKNOWN);
      expect(EventDiagnostics.configVersion('"abc"')).assertEqual('abc');
      expect(EventDiagnostics.configVersion('"W/1a2b"')).assertEqual('W/1a2b');
      expect(EventDiagnostics.configVersion('""')).assertEqual(UNKNOWN);
      expect(EventDiagnostics.configVersion('1')).assertEqual(UNKNOWN);
      expect(EventDiagnostics.configVersion('null')).assertEqual(UNKNOWN);
      expect(EventDiagnostics.configVersion('true')).assertEqual(UNKNOWN);
      expect(EventDiagnostics.configVersion('{"v":"abc"}')).assertEqual(UNKNOWN);
      expect(EventDiagnostics.configVersion('["abc"]')).assertEqual(UNKNOWN);
      expect(EventDiagnostics.configVersion('abc')).assertEqual(UNKNOWN);
      expect(EventDiagnostics.configVersion('"abc')).assertEqual(UNKNOWN);
      expect(EventDiagnostics.configVersion('')).assertEqual(UNKNOWN);
    });

    // 先红：EventDiagnostics 不存在，编译不过。守的错法：包内默认配置被当成有版本、只认 current 层不认 LKG（冷启动未拉到时）、
    // 以及评审 S2-1 的「逐层回落」：新拉的配置缺 config_version 或为 null 时借用上一份配置 / 包内层的版本（应为 unknown）。
    it('ED2_configVersionOf_reads_only_the_effective_layer_without_fallback', 0, () => {
      expect(EventDiagnostics.configVersionOf(null)).assertEqual(UNKNOWN);
      const rig: ConfigVersionRig = new ConfigVersionRig();
      // 前提：包内默认配置没有 config_version（/v1/config 还没拉到）。
      expect(rig.store.value(EventDiagnostics.CONFIG_VERSION_KEY) === null).assertTrue();
      expect(EventDiagnostics.configVersionOf(rig.store)).assertEqual(UNKNOWN);
      rig.reply('cfg-7');
      expect(EventDiagnostics.configVersionOf(rig.store)).assertEqual('cfg-7');
      // 下一次冷启动、拉取未结算：取 LKG 里保存的 config_version。
      const next: ConfigVersionRig = new ConfigVersionRig(rig.file);
      expect(EventDiagnostics.configVersionOf(next.store)).assertEqual('cfg-7');

      // 评审 S2-1：新拉的配置 config_version 为 null。前提：上一份配置（内存 LKG 层）还有 cfg-7，逐层回落会取到它。
      rig.reply(null);
      expect(rig.store.value(EventDiagnostics.CONFIG_VERSION_KEY)).assertEqual('"cfg-7"');
      expect(EventDiagnostics.configVersionOf(rig.store)).assertEqual(UNKNOWN);
      // 当前层有合法值：取当前层。
      rig.reply('cfg-8');
      expect(EventDiagnostics.configVersionOf(rig.store)).assertEqual('cfg-8');
      // 新拉的配置不带 config_version。前提：上一份配置有 cfg-8。
      rig.reply(null, true);
      expect(rig.store.value(EventDiagnostics.CONFIG_VERSION_KEY)).assertEqual('"cfg-8"');
      expect(EventDiagnostics.configVersionOf(rig.store)).assertEqual(UNKNOWN);

      // 包内层有 config_version：只有包内层时它就是生效层，取它；拉到不带这个键的配置后不回落到包内层。
      const bundled: ConfigVersionRig = new ConfigVersionRig(null, bundledWith('bundled-1'));
      expect(EventDiagnostics.configVersionOf(bundled.store)).assertEqual('bundled-1');
      bundled.reply(null, true);
      expect(bundled.store.value(EventDiagnostics.CONFIG_VERSION_KEY)).assertEqual('"bundled-1"');
      expect(EventDiagnostics.configVersionOf(bundled.store)).assertEqual(UNKNOWN);
      bundled.reply('cfg-9');
      expect(EventDiagnostics.configVersionOf(bundled.store)).assertEqual('cfg-9');
    });

    // 先红：EventDiagnostics 不存在，编译不过。守的错法：用真假判断把版本 0 当成取不到。
    it('ED3_cardSchemaVersion_null_is_unknown_and_zero_is_kept', 0, () => {
      expect(EventDiagnostics.cardSchemaVersion(null)).assertEqual(UNKNOWN);
      expect(EventDiagnostics.cardSchemaVersion(2)).assertEqual('2');
      expect(EventDiagnostics.cardSchemaVersion(1)).assertEqual('1');
      expect(EventDiagnostics.cardSchemaVersion(0)).assertEqual('0');
    });

    // ================================================================ ④ 首页 sdui_card_error

    // 先红：HomeDeps.configVersion 不存在，编译不过；假如能编译，旧事件没有 schema_version 等四项（undefined）。
    // 守的错法：schema_version 借页面版本（会是 '13'）、bridge_version 填 BRIDGE_VERSION（'1'）、缺 version 时仍带 version 键。
    it('SC1_card_schema_version_from_card_version_unknown_when_missing_and_page_version_kept', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      const events: ClientEvent[] = await homeEvents(f, (): string => 'cv-home-1');
      expect(events.length).assertEqual(5);
      const missing: ClientEvent = byReason(events, 'missing_version');
      expect(field(missing, 'schema_version') as string).assertEqual(UNKNOWN);
      expect(missing.fields.has('version')).assertFalse();
      const v2: ClientEvent = byReason(events, 'unsupported_version');
      expect(field(v2, 'schema_version') as string).assertEqual('2');
      expect(field(v2, 'version') as number).assertEqual(2);
      const props: ClientEvent = byReason(events, 'missing_field');
      expect(field(props, 'schema_version') as string).assertEqual('1');
      const zero: ClientEvent = byReason(events, 'bad_value');
      expect(field(zero, 'schema_version') as string).assertEqual('0');
      const text: ClientEvent = byReason(events, 'bad_type');
      expect(field(text, 'schema_version') as string).assertEqual(UNKNOWN);
      expect(text.fields.has('version')).assertFalse();
      for (const e of events) {
        expect(field(e, 'page_version') as number).assertEqual(PAGE_VERSION);
        expect(field(e, 'schema_version') === String(PAGE_VERSION)).assertFalse();
        expect(field(e, 'bridge_version') as string).assertEqual(UNKNOWN);
        expect(field(e, 'h5_release') as string).assertEqual(UNKNOWN);
        expect(field(e, 'config_version') as string).assertEqual('cv-home-1');
        for (const k of DIAGNOSTIC_KEYS) {
          expect(typeof field(e, k)).assertEqual('string');
        }
      }
      // 带卡片版本的事件：字段集合与锁定快照 events.json 的 sdui_card_error 一致（首页 page_version 必带）。
      expect(sorted(Array.from(v2.fields.keys()))).assertEqual(sorted(contractFields('sdui_card_error')));
    });

    // 先红：同上（HomeDeps.configVersion 不存在，编译不过）。守的错法：没接配置时留空或填别的值。
    it('SC2_config_version_defaults_unknown_when_not_injected', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      const events: ClientEvent[] = await homeEvents(f, null);
      expect(events.length).assertEqual(5);
      for (const e of events) {
        expect(field(e, 'config_version') as string).assertEqual(UNKNOWN);
      }
    });

    // ================================================================ ⑤ 「系统权限」一节按类型过滤

    // 先红：PERMISSION_KINDS 不存在，编译不过；假如能编译，旧 of() 把本端条目全列出，harmony 会是 ["vibrate","network"]、android 会是
    // ["network","dynamic_receiver"]，断言 [] 不等。守的错法：按 purpose_key 是否为空判（vibrate 有 purpose_key 会被列出）、一律不列（ios 会空）。
    it('SP1_install_granted_snapshot_permissions_are_not_listed_and_user_requested_are', 0, () => {
      const entries: MeRecord[] = snapshotPermissions();
      const harmonyTypes: string[] = entries.filter((e: MeRecord): boolean => e['platform'] === MePlatform.HARMONY)
        .map((e: MeRecord): string => e['type'] as string);
      // 前提：锁定快照里鸿蒙确有 vibrate（VIBRATE）与 network（INTERNET）两条。
      expect(harmonyTypes.indexOf('vibrate') >= 0).assertTrue();
      expect(harmonyTypes.indexOf('network') >= 0).assertTrue();
      const status: MeRecord = {};
      expect(JSON.stringify(rowTypes(PrivacyCenterView.of(MeLevel.MEMBER, MePlatform.HARMONY, entries, status)))).assertEqual('[]');
      expect(JSON.stringify(rowTypes(PrivacyCenterView.of(MeLevel.MEMBER, MePlatform.ANDROID, entries, status)))).assertEqual('[]');
      expect(JSON.stringify(rowTypes(PrivacyCenterView.of(MeLevel.MEMBER, MePlatform.IOS, entries, status))))
        .assertEqual('["photos","push"]');
    });

    // 先红：PERMISSION_KINDS / KIND_* 不存在，编译不过。守的错法：快照出现新类型却没归类（应在这里报红）、把 vibrate 归成向用户申请。
    it('SP2_every_snapshot_permission_type_is_classified_once', 0, () => {
      const kinds: Map<string, string> = PrivacyCenterView.PERMISSION_KINDS;
      for (const e of snapshotPermissions()) {
        const type: string = e['type'] as string;
        const kind: string | undefined = kinds.get(type);
        expect('type ' + type + ' ' + (kind === undefined ? 'unclassified' : 'classified')).assertEqual('type ' + type + ' classified');
        expect(kind === PrivacyCenterView.KIND_USER_REQUESTED || kind === PrivacyCenterView.KIND_INSTALL_GRANTED).assertTrue();
      }
      expect(kinds.get('push')).assertEqual(PrivacyCenterView.KIND_USER_REQUESTED);
      expect(kinds.get('photos')).assertEqual(PrivacyCenterView.KIND_USER_REQUESTED);
      expect(kinds.get('vibrate')).assertEqual(PrivacyCenterView.KIND_INSTALL_GRANTED);
      expect(kinds.get('network')).assertEqual(PrivacyCenterView.KIND_INSTALL_GRANTED);
      expect(kinds.get('dynamic_receiver')).assertEqual(PrivacyCenterView.KIND_INSTALL_GRANTED);
      expect(PrivacyCenterView.KIND_USER_REQUESTED === PrivacyCenterView.KIND_INSTALL_GRANTED).assertFalse();
    });

    // 先红：PERMISSION_KINDS / userRequested 不存在，编译不过。评审 S3-2（照安卓 9f015b2 LockPermissionKindsTest 的
    // everyRequesterTypeIsUserRequested 与 userRequestedTypesAlignWithTheTable）：PermissionRequester 能申请的类型都归为向用户申请，
    // 归为向用户申请的也正是这些类型。ArkTS 不能反射类的静态字段，这里逐个列出 PermissionTypeRaw 的常量（新增常量时须同步加进 requester）。
    it('SP4_permission_requester_types_are_exactly_the_user_requested_kinds', 0, () => {
      const requester: string[] = [PermissionTypeRaw.PUSH, PermissionTypeRaw.PHOTOS];
      for (const type of requester) {
        expect('PermissionTypeRaw ' + type + ' userRequested=' + String(PrivacyCenterView.userRequested(type)))
          .assertEqual('PermissionTypeRaw ' + type + ' userRequested=true');
        expect(PrivacyCenterView.PERMISSION_KINDS.get(type)).assertEqual(PrivacyCenterView.KIND_USER_REQUESTED);
      }
      const userRequested: string[] = [];
      PrivacyCenterView.PERMISSION_KINDS.forEach((kind: string, type: string): void => {
        if (kind === PrivacyCenterView.KIND_USER_REQUESTED) {
          userRequested.push(type);
        }
      });
      expect(sorted(userRequested)).assertEqual(sorted(requester));
    });

    // 先红：userRequested 不存在，编译不过；假如能编译，旧 of() 三条都列出（["push","vibrate","camera"]）。
    // 守的错法：按 purpose_key 判（push 无 purpose_key 会被漏、vibrate 有 purpose_key 会被列）、未归类类型默认列出。
    it('SP3_filter_is_by_type_not_purpose_key_and_unclassified_is_hidden', 0, () => {
      const entries: MeRecord[] = [entry('push', MePlatform.HARMONY, null),
        entry('vibrate', MePlatform.HARMONY, 'perm.vibrate.system_purpose'), entry('camera', MePlatform.HARMONY, 'perm.camera.x')];
      const status: MeRecord = {};
      status['push'] = 'granted';
      const view: MeRecord = PrivacyCenterView.of(MeLevel.MEMBER, MePlatform.HARMONY, entries, status);
      expect(JSON.stringify(rowTypes(view))).assertEqual('["push"]');
      const row: MeRecord = (view['permissionRows'] as MeRecord[])[0];
      expect(row['purposeKey'] === null).assertTrue();
      expect(row['statusKey'] as string).assertEqual('privacy.system_permissions.status.granted');
      expect(PrivacyCenterView.userRequested('push')).assertTrue();
      expect(PrivacyCenterView.userRequested('vibrate')).assertFalse();
      expect(PrivacyCenterView.userRequested('camera')).assertFalse();
    });

    // ================================================================ ⑥ MeJson.maskedPhone 与 parse

    // 先红：只因同文件引用的 maskedPhone 等不存在而编译不过；逻辑上改动前 parse 本就不管多出来的键，这条是守「masked_phone 进必填 /
    // 格式不对就判坏数据」的错改，改动前后都应为绿。
    it('MP1_parse_does_not_reject_any_masked_phone_shape', 0, () => {
      for (const over of ['', '{"masked_phone":null}', '{"masked_phone":"13800138000"}', '{"masked_phone":123}',
        '{"masked_phone":"138****8000"}', '{"phone_bound":false,"masked_phone":"138****8000"}']) {
        const parsed: MeRecord | null = MeJson.parse(me(over));
        expect('parse ' + over + ' ' + (parsed === null ? 'null' : 'ok')).assertEqual('parse ' + over + ' ok');
        // parse 的副本只含 13 个必填字段，不带 masked_phone。
        expect(parsed !== null && Object.keys(parsed).length === 13).assertTrue();
        expect(parsed !== null && Object.keys(parsed).indexOf('masked_phone') < 0).assertTrue();
      }
    });

    // 先红：maskedPhone 不存在，编译不过。守的错法：不看 phone_bound、正则不锚定（前后多字符也过）、接受全角星号或非数字。
    it('MP2_maskedPhone_only_when_bound_and_exactly_3_digits_4_stars_4_digits', 0, () => {
      expect(MeJson.maskedPhone(me('{"masked_phone":"138****8000"}'))).assertEqual('138****8000');
      expect(MeJson.maskedPhone(me('{"phone_bound":false,"masked_phone":"138****8000"}')) === null).assertTrue();
      expect(MeJson.maskedPhone(me('{"phone_bound":"true","masked_phone":"138****8000"}')) === null).assertTrue();
      expect(MeJson.maskedPhone(me('')) === null).assertTrue();
      expect(MeJson.maskedPhone(me('{"masked_phone":null}')) === null).assertTrue();
      for (const bad of ['138****800', '13x****8000', '138＊＊＊＊8000', '13800138000', ' 138****8000', '138****8000 ',
        '138****80001', '1138****8000', '138***8000', '138*****8000', '']) {
        const over: string = '{"masked_phone":' + JSON.stringify(bad) + '}';
        expect('masked ' + bad + ' ' + String(MeJson.maskedPhone(me(over)))).assertEqual('masked ' + bad + ' null');
      }
      expect(MeJson.maskedPhone(me('{"masked_phone":123}')) === null).assertTrue();
      expect(MeJson.maskedPhone(me('{"masked_phone":["138****8000"]}')) === null).assertTrue();
      expect(MeJson.maskedPhone(null) === null).assertTrue();
      expect(MeJson.maskedPhone(undefined) === null).assertTrue();
      expect(MeJson.maskedPhone(['138****8000'] as Object) === null).assertTrue();
    });

    // 先红：只因同文件编译不过而红；逻辑上改动前后都是 13 项，这条守「把 masked_phone 加进 FIELDS」的错改。
    it('MP3_FIELDS_stays_13_without_masked_phone', 0, () => {
      expect(MeJson.FIELDS.length).assertEqual(13);
      expect(MeJson.FIELDS.indexOf('masked_phone') < 0).assertTrue();
    });
  });
}
