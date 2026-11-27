// FU-HM-BRIDGE-ORIGINS-VERIFY：ConfigStore 的「上次可用白名单」状态机（scope.md P4 ①–⑧；照安卓 ConfigStoreBridgeOriginsTest 11 条）。
// 写法照 Fx24ConfigRig 先例：内存 LKG 文件 + 假拉取 + 真 ConfigStore；验签闭包是桩 FakeCheck（真验签器由 BridgeOriginsRules /
// BridgeOriginsDevice 覆盖）。桩口径：bridge_origins = {"jws": "ok|<version>|<origin>,<origin>"} 且 version ≥ 上次可用才通过，其余拒。
// LKG 文件字段名 bridge_origins_last_good，形状 {"version": n, "origins": [...]}；没有上次可用时不写该键。
import { describe, it } from '@ohos/hypium';
import { BridgeOriginsCheck, BridgeOriginsLastGood, ConfigReply, ConfigSourceRaw, ConfigStore } from '../../Index';
import { BundledConfig } from 'generated';
import { check, same } from './BridgeOriginsTestSupport';

const KEY: string = 'bridge_origins_last_good';
const A: string = 'https://a.example.test';
const B: string = 'https://b.example.test';
const C: string = 'https://c.example.test';
const BUNDLED: string = '{"config_version":"bundled"}';

class CheckCall {
  readonly tag: string;
  readonly lastGoodVersion: number | null;

  constructor(tag: string, lastGoodVersion: number | null) {
    this.tag = tag;
    this.lastGoodVersion = lastGoodVersion;
  }
}

/** 桩验签：见文件头。记下每次调用的 (data.config_version, lastGoodVersion)。 */
class FakeCheck {
  readonly calls: CheckCall[] = [];

  verify(dataJson: string, lastGoodVersion: number | null): BridgeOriginsLastGood | null {
    const data: Record<string, Object> = JSON.parse(dataJson) as Record<string, Object>;
    const tag: Object | undefined = data['config_version'];
    this.calls.push(new CheckCall(typeof tag === 'string' ? tag as string : '', lastGoodVersion));
    const bridge: Object | undefined = data['bridge_origins'];
    if (bridge === undefined || bridge === null || Array.isArray(bridge) || typeof bridge !== 'object') {
      return null;
    }
    const jws: Object | undefined = (bridge as Record<string, Object>)['jws'];
    if (typeof jws !== 'string') {
      return null;
    }
    const parts: string[] = (jws as string).split('|');
    if (parts.length !== 3 || parts[0] !== 'ok') {
      return null;
    }
    const version: number = Number(parts[1]);
    if (lastGoodVersion !== null && version < lastGoodVersion) {
      return null;
    }
    return new BridgeOriginsLastGood(version, parts[2].split(','));
  }

  get last(): CheckCall {
    if (this.calls.length === 0) {
      throw new Error('验签闭包没有被调用');
    }
    return this.calls[this.calls.length - 1];
  }
}

class StoreRig {
  disk: string | null = null;
  readonly fake: FakeCheck = new FakeCheck();
  private callbacks: ((reply: ConfigReply) => void)[] = [];
  private sequence: number = 0;

  store(bundled: string = BUNDLED, verify: BridgeOriginsCheck | null = null): ConfigStore {
    const fake: FakeCheck = this.fake;
    const verifier: BridgeOriginsCheck = verify ?? ((dataJson: string, lastGoodVersion: number | null):
      BridgeOriginsLastGood | null => fake.verify(dataJson, lastGoodVersion));
    return new ConfigStore((): string | null => this.disk, (value: string | null): void => {
      this.disk = value;
    }, (_etag: string | null, done: (reply: ConfigReply) => void): void => {
      this.callbacks.push(done);
    }, (): number => 0, bundled, verifier);
  }

  /** 不传闭包的 store（缺省一律拒）。 */
  storeWithoutCheck(): ConfigStore {
    return new ConfigStore((): string | null => this.disk, (value: string | null): void => {
      this.disk = value;
    }, (_etag: string | null, done: (reply: ConfigReply) => void): void => {
      this.callbacks.push(done);
    }, (): number => 0, BUNDLED);
  }

  reply(kind: string, body: string | null = null): void {
    const done: ((reply: ConfigReply) => void) | undefined = this.callbacks.shift();
    if (done === undefined) {
      throw new Error('前提：有在途拉取');
    }
    this.sequence++;
    done(new ConfigReply(kind, body, kind === ConfigReply.OK ? '"etag-' + this.sequence + '"' : null));
  }

  ok(body: string): void {
    this.reply(ConfigReply.OK, body);
  }

  clearPending(): void {
    this.callbacks = [];
  }

  lastGoodOnDisk(): string | null {
    if (this.disk === null) {
      return null;
    }
    const root: Record<string, Object> = JSON.parse(this.disk) as Record<string, Object>;
    const value: Object | undefined = root[KEY];
    return value === undefined ? null : JSON.stringify(value);
  }

  diskHasKey(): boolean {
    if (this.disk === null) {
      return false;
    }
    return Object.keys(JSON.parse(this.disk) as Record<string, Object>).indexOf(KEY) >= 0;
  }
}

function token(version: number, origins: string[]): string {
  return 'ok|' + version + '|' + origins.join(',');
}

function body(jws: string, tag: string): string {
  const bridge: Record<string, Object> = {};
  bridge['jws'] = jws;
  const data: Record<string, Object> = {};
  data['config_version'] = tag;
  data['bridge_origins'] = bridge;
  return JSON.stringify(data);
}

function lastGood(version: number, origins: string[]): string {
  return '{"version":' + version + ',"origins":' + JSON.stringify(origins) + '}';
}

/** 手写一份 LKG 文件（format 1）；lastGoodRaw 为 null 时是升级前的旧 LKG（没有该字段）。 */
function lkg(data: string, lastGoodRaw: string | null = null): string {
  return '{"format":1,"saved_at":0,"data":' + data + (lastGoodRaw === null ? '' : ',"' + KEY + '":' + lastGoodRaw) + '}';
}

function assertTrusted(label: string, store: ConfigStore, version: number | null, origins: string[]): void {
  same(label + '：trustedOrigins', store.trustedOrigins(), origins);
  same(label + '：trustedOriginsVersion', store.trustedOriginsVersion(), version);
}

/** 冷启动（无 LKG）并收下一份验得过的 v3 [A]。 */
function storeTrustingA(rig: StoreRig): ConfigStore {
  const store: ConfigStore = rig.store();
  store.onColdStart();
  rig.ok(body(token(3, [A]), 'v3-a'));
  assertTrusted('前提：v3 [A] 通过', store, 3, [A]);
  return store;
}

export default function configStoreBridgeOriginsTest() {
  describe('ConfigStoreBridgeOrigins', () => {
    it('cfg_01_without_a_check_closure_the_whitelist_is_always_empty', 0, () => {
      const rig: StoreRig = new StoreRig();
      const store: ConfigStore = rig.storeWithoutCheck();
      store.onColdStart();
      rig.ok(body(token(3, [A]), 'v3'));
      same('配置本身照常生效', store.sourceRaw, ConfigSourceRaw.CURRENT);
      assertTrusted('缺省一律拒', store, null, []);
      check('LKG 不写 ' + KEY, rig.disk !== null && !rig.diskHasKey());
    });

    it('cfg_02_accepted_config_becomes_last_good_and_is_persisted_with_the_lkg', 0, () => {
      const rig: StoreRig = new StoreRig();
      const store: ConfigStore = rig.store();
      store.onColdStart();
      assertTrusted('还没有服务端配置', store, null, []);
      rig.ok(body(token(3, [A, B]), 'v3-ab'));
      assertTrusted('验过', store, 3, [A, B]);
      same('随 LKG 落盘', rig.lastGoodOnDisk(), lastGood(3, [A, B]));
      same('验的是这次 200 的 data', rig.fake.last.tag, 'v3-ab');
      same('没有上次可用时 lastGoodVersion = null', rig.fake.last.lastGoodVersion, null);
    });

    it('cfg_03_rejected_config_keeps_the_last_good_and_the_lkg_never_stores_the_failed_value', 0, () => {
      const rig: StoreRig = new StoreRig();
      const store: ConfigStore = storeTrustingA(rig);
      const cases: string[][] = [[body('bad|3|' + B, 'bad-signature'), '验不过'], [body(token(2, [B]), 'rollback'), '版本回退'],
        ['{"config_version":"array","bridge_origins":["' + B + '"]}', '旧的数组形状'], ['{"config_version":"none"}', '没有 bridge_origins']];
      for (const c of cases) {
        store.onForeground();
        rig.ok(c[0]);
        same(c[1] + '：这份配置本身照常生效', store.sourceRaw, ConfigSourceRaw.CURRENT);
        assertTrusted(c[1], store, 3, [A]);
        same(c[1] + '：用上次可用的 version 验', rig.fake.last.lastGoodVersion, 3);
        same(c[1] + '：LKG 照旧写原上次可用', rig.lastGoodOnDisk(), lastGood(3, [A]));
      }
      const restarted: ConfigStore = rig.store();
      restarted.onColdStart();
      assertTrusted('重启后仍是原上次可用', restarted, 3, [A]);
    });

    it('cfg_04_first_rejected_config_writes_no_last_good_field', 0, () => {
      const rig: StoreRig = new StoreRig();
      const store: ConfigStore = rig.store();
      store.onColdStart();
      rig.ok(body('bad|1|' + A, 'bad'));
      same('闭包验了这次 200', rig.fake.last.tag, 'bad');
      assertTrusted('验不过', store, null, []);
      check('LKG 照常写了 data，但没有 ' + KEY, rig.disk !== null && !rig.diskHasKey());
    });

    it('cfg_05_equal_version_is_not_a_rollback_and_higher_replaces', 0, () => {
      const rig: StoreRig = new StoreRig();
      const store: ConfigStore = storeTrustingA(rig);
      store.onForeground();
      rig.ok(body(token(3, [B]), 'v3-b'));
      same('用上次可用的 version 3 验', rig.fake.last.lastGoodVersion, 3);
      assertTrusted('版本相等通过', store, 3, [B]);
      same('替换并落盘', rig.lastGoodOnDisk(), lastGood(3, [B]));
      store.onForeground();
      rig.ok(body(token(4, [C]), 'v4-c'));
      assertTrusted('更高版本通过', store, 4, [C]);
    });

    it('cfg_06_cold_start_uses_the_stored_last_good_directly', 0, () => {
      const rig: StoreRig = new StoreRig();
      rig.disk = lkg('{"config_version":"old","bridge_origins":{"jws":"bad|9|' + B + '"}}', lastGood(7, [A]));
      const store: ConfigStore = rig.store();
      store.onColdStart();
      assertTrusted('拉取结算前就可用', store, 7, [A]);
      same('带字段的 LKG 直接用、不再验', rig.fake.calls.length, 0);
      rig.reply(ConfigReply.FAILURE);
      assertTrusted('拉取失败不变', store, 7, [A]);
      store.onForeground();
      rig.ok(body(token(6, [C]), 'v6'));
      same('读到的上次可用 version 参与回退判定', rig.fake.last.lastGoodVersion, 7);
      assertTrusted('v6 < v7 不替换', store, 7, [A]);
    });

    it('cfg_07_last_good_written_by_one_process_is_read_by_the_next', 0, () => {
      const rig: StoreRig = new StoreRig();
      storeTrustingA(rig);
      rig.clearPending();
      const restarted: ConfigStore = rig.store();
      restarted.onColdStart();
      assertTrusted('重启', restarted, 3, [A]);
    });

    it('cfg_08_old_lkg_without_the_field_is_verified_once_at_cold_start', 0, () => {
      const rig: StoreRig = new StoreRig();
      rig.disk = lkg(body(token(4, [A]), 'old-ok'));
      const store: ConfigStore = rig.store();
      store.onColdStart();
      assertTrusted('旧 LKG 现验通过', store, 4, [A]);
      same('只验一次', rig.fake.calls.length, 1);
      same('验的是 LKG 的 data', rig.fake.last.tag, 'old-ok');
      same('旧 LKG 现验 lastGoodVersion = null', rig.fake.last.lastGoodVersion, null);
    });

    it('cfg_09_old_lkg_that_fails_or_a_broken_field_falls_back_to_verifying_the_data', 0, () => {
      for (const data of [body('bad|4|' + A, 'old-bad'), '{"config_version":"old-array","bridge_origins":["' + A + '"]}']) {
        const rig: StoreRig = new StoreRig();
        rig.disk = lkg(data);
        const store: ConfigStore = rig.store();
        store.onColdStart();
        same('旧 LKG 现验过：' + data, rig.fake.calls.length, 1);
        assertTrusted('旧 LKG 验不过：' + data, store, null, []);
      }
      // 字段在但形状不完整：按没有该字段处理（用 data 现验一次）。
      for (const broken of ['{"version":"3","origins":["' + B + '"]}', '{"version":-1,"origins":["' + B + '"]}',
        '{"version":3,"origins":[]}', '{"version":3,"origins":["' + B + '",1]}', '{"version":3}', '{"origins":["' + B + '"]}',
        '["' + B + '"]', 'null']) {
        const rig: StoreRig = new StoreRig();
        rig.disk = lkg(body(token(5, [C]), 'data-ok'), broken);
        const store: ConfigStore = rig.store();
        store.onColdStart();
        same('坏字段 ' + broken + '：改用 data 现验', rig.fake.calls.length, 1);
        same('坏字段 ' + broken + '：lastGoodVersion = null', rig.fake.last.lastGoodVersion, null);
        assertTrusted('坏字段 ' + broken, store, 5, [C]);
      }
    });

    it('cfg_10_not_modified_and_failure_leave_the_last_good_unchanged', 0, () => {
      const rig: StoreRig = new StoreRig();
      const store: ConfigStore = storeTrustingA(rig);
      const calls: number = rig.fake.calls.length;
      const before: string | null = rig.disk;
      store.onForeground();
      rig.reply(ConfigReply.NOT_MODIFIED);
      assertTrusted('304', store, 3, [A]);
      store.onForeground();
      rig.reply(ConfigReply.FAILURE);
      assertTrusted('拉取失败', store, 3, [A]);
      same('304 / 失败不再验签', rig.fake.calls.length, calls);
      same('304 / 失败不写 LKG', rig.disk, before);
    });

    it('cfg_11_environment_switch_clears_the_last_good', 0, () => {
      const rig: StoreRig = new StoreRig();
      const store: ConfigStore = storeTrustingA(rig);
      store.clearForEnvironmentSwitch();
      assertTrusted('切环境后', store, null, []);
      same('LKG 已删', rig.disk, null);
      rig.clearPending();
      store.onColdStart();
      assertTrusted('新环境冷启动（无 LKG）', store, null, []);
      rig.ok(body(token(1, [C]), 'new-env-v1'));
      same('旧环境的 version 不再参与回退判定', rig.fake.last.lastGoodVersion, null);
      assertTrusted('新环境的 v1 通过', store, 1, [C]);
    });

    it('cfg_12_a_throwing_closure_counts_as_rejection', 0, () => {
      const rig: StoreRig = new StoreRig();
      let throwing: boolean = false;
      let seen: number = 0;
      const fake: FakeCheck = rig.fake;
      const store: ConfigStore = rig.store(BUNDLED, (dataJson: string, lastGoodVersion: number | null):
        BridgeOriginsLastGood | null => {
        seen++;
        if (throwing) {
          throw new Error('verifier failure');
        }
        return fake.verify(dataJson, lastGoodVersion);
      });
      store.onColdStart();
      throwing = true;
      rig.ok(body(token(1, [A]), 'first-throws'));
      same('闭包被调用', seen, 1);
      same('抛错不影响配置本身', store.sourceRaw, ConfigSourceRaw.CURRENT);
      assertTrusted('第一次就抛：为空', store, null, []);
      check('没有上次可用时不写 ' + KEY, !rig.diskHasKey());
      throwing = false;
      store.onForeground();
      rig.ok(body(token(2, [B]), 'v2'));
      assertTrusted('恢复后通过', store, 2, [B]);
      throwing = true;
      store.onForeground();
      rig.ok(body(token(3, [C]), 'throws-again'));
      assertTrusted('再抛：保留上次可用', store, 2, [B]);
      same('LKG 仍是上次可用', rig.lastGoodOnDisk(), lastGood(2, [B]));
    });

    it('cfg_13_backstop_rejects_empty_origins_or_a_lower_version_from_the_closure', 0, () => {
      const rig: StoreRig = new StoreRig();
      let answer: BridgeOriginsLastGood | null = new BridgeOriginsLastGood(3, [A]);
      const store: ConfigStore = rig.store(BUNDLED, (_dataJson: string, _lastGoodVersion: number | null):
        BridgeOriginsLastGood | null => answer);
      store.onColdStart();
      rig.ok(body('anything', 'v3'));
      assertTrusted('闭包给 v3 [A]', store, 3, [A]);
      answer = new BridgeOriginsLastGood(2, [B]);
      store.onForeground();
      rig.ok(body('anything', 'lower'));
      assertTrusted('闭包给出更低版本：兜底拒', store, 3, [A]);
      answer = new BridgeOriginsLastGood(5, []);
      store.onForeground();
      rig.ok(body('anything', 'empty'));
      assertTrusted('闭包给出空 origins：兜底拒', store, 3, [A]);
      same('LKG 仍是上次可用', rig.lastGoodOnDisk(), lastGood(3, [A]));
    });

    it('cfg_14_bundled_layer_is_never_trusted', 0, () => {
      // 包内 bridge_origins 是占位 jws：ConfigStore 不对包内层验签、不把它当白名单。闭包故意「什么都放行」，证明结果来自不调用。
      const rig: StoreRig = new StoreRig();
      const parsed: Record<string, Object> = JSON.parse(BundledConfig.DATA_JSON) as Record<string, Object>;
      check('包内带 bridge_origins 占位（生成物）', typeof parsed['bridge_origins'] === 'object');
      let seen: number = 0;
      const store: ConfigStore = rig.store(BundledConfig.DATA_JSON, (_dataJson: string, _lastGoodVersion: number | null):
        BridgeOriginsLastGood | null => {
        seen++;
        return new BridgeOriginsLastGood(1, [A]);
      });
      assertTrusted('构造后', store, null, []);
      store.onColdStart();
      rig.reply(ConfigReply.FAILURE);
      same('只有包内配置', store.sourceRaw, ConfigSourceRaw.BUNDLED);
      assertTrusted('只有包内配置', store, null, []);
      same('包内层从不交给闭包', seen, 0);
    });

    it('cfg_15_trusted_origins_is_a_copy', 0, () => {
      const rig: StoreRig = new StoreRig();
      const store: ConfigStore = storeTrustingA(rig);
      const got: string[] = store.trustedOrigins();
      got.push(B);
      assertTrusted('改调用方手里的数组不影响上次可用', store, 3, [A]);
    });
  });
}
