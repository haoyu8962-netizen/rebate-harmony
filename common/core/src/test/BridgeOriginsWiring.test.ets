// FU-HM-BRIDGE-ORIGINS-VERIFY：生产验签闭包 BridgeOriginsWiring.check（scope.md E1；照安卓 AppConfig.bridgeOriginsVerifier 与
// N22R1RuntimeEnvironmentWiringTest）。entry 没有本机单测源码集（只有 src/ohosTest，进 entry 设备名单要改冻结件），所以闭包放在 core、
// 在这里测；entry 的 AppClientCore 只把 `() => AppConfig.environment()?.current`、APP_ID、ConfigSignKeys.bundled()、CryptoKitEs256
// 传进来（那一行接线与 E2 / E3 本机测不了，见交回）。端口是桩 RecordingEs256。
import { describe, it } from '@ohos/hypium';
import {
  BridgeOriginsCheck, BridgeOriginsLastGood, BridgeOriginsWiring, ConfigReply, ConfigSignKeys, ConfigStore
} from '../../Index';
import {
  APP_ID, check, dataWithJws, GOOD_ORIGIN, headerJson, jwsOf, payloadJson, RecordingEs256, same, synthSpkiHex, UNIT_KID
} from './BridgeOriginsTestSupport';

const ORIGINS: string = '["' + GOOD_ORIGIN + '"]';

/** 只有 staging 下有 unit-key-1 的表。 */
function stagingKeys(): ConfigSignKeys {
  return ConfigSignKeys.parse('staging:' + UNIT_KID + ':' + synthSpkiHex('11'));
}

/** env staging、version 给定的 data。 */
function stagingData(version: string = '0', kid: string = UNIT_KID): string {
  return dataWithJws(jwsOf(headerJson('ES256', kid), payloadJson(version, ORIGINS, '1', '"' + APP_ID + '"', '"staging"')));
}

class EnvBox {
  value: string | undefined = 'staging';
  reads: number = 0;

  read(): string | undefined {
    this.reads++;
    return this.value;
  }
}

function originsOf(result: BridgeOriginsLastGood | null): string {
  return result === null ? 'null' : result.version + ' ' + JSON.stringify(result.origins);
}

export default function bridgeOriginsWiringTest() {
  describe('BridgeOriginsWiring', () => {
    it('wiring_01_environment_id_is_read_on_every_call', 0, () => {
      const env: EnvBox = new EnvBox();
      const port: RecordingEs256 = new RecordingEs256('true');
      const verify: BridgeOriginsCheck = BridgeOriginsWiring.check((): string | undefined => env.read(), APP_ID, stagingKeys(),
        port);
      const data: string = stagingData();
      same('staging：收下', originsOf(verify(data, null)), '0 ' + ORIGINS);
      env.value = 'test';
      same('切到 test：同一闭包按 test 取钥，不认', originsOf(verify(data, null)), 'null');
      env.value = 'prod';
      same('切到 prod：不认', originsOf(verify(data, null)), 'null');
      const portCalls: number = port.calls.length;
      env.value = undefined;
      same('环境闸门非 SETTLED（undefined）：拒', originsOf(verify(data, null)), 'null');
      same('环境未定时不调端口', port.calls.length, portCalls);
      env.value = 'staging';
      same('切回 staging：又收下', originsOf(verify(data, null)), '0 ' + ORIGINS);
      check('每次调用都现取环境（5 次调用至少 5 次读），实得 ' + env.reads, env.reads >= 5);
    });

    it('wiring_02_app_id_and_last_good_version_are_passed_through', 0, () => {
      const port: RecordingEs256 = new RecordingEs256('true');
      const env: () => string | undefined = (): string | undefined => 'staging';
      same('app_id 一致', originsOf(BridgeOriginsWiring.check(env, APP_ID, stagingKeys(), port)(stagingData('2'), null)),
        '2 ' + ORIGINS);
      same('app_id 不一致（与 X-App-Id 同源的值才认）',
        originsOf(BridgeOriginsWiring.check(env, 'couli-other', stagingKeys(), port)(stagingData('2'), null)), 'null');
      const verify: BridgeOriginsCheck = BridgeOriginsWiring.check(env, APP_ID, stagingKeys(), port);
      same('lastGoodVersion 2 = version 2', originsOf(verify(stagingData('2'), 2)), '2 ' + ORIGINS);
      same('lastGoodVersion 3 > version 2：回退', originsOf(verify(stagingData('2'), 3)), 'null');
      same('端口验不过', originsOf(BridgeOriginsWiring.check(env, APP_ID, stagingKeys(), new RecordingEs256('false'))(
        stagingData('2'), null)), 'null');
      same('端口抛错不抛出闭包', originsOf(BridgeOriginsWiring.check(env, APP_ID, stagingKeys(), new RecordingEs256('throw'))(
        stagingData('2'), null)), 'null');
    });

    it('wiring_03_config_store_with_an_old_lkg_follows_the_runtime_environment', 0, () => {
      // 旧格式 LKG（不带 bridge_origins_last_good）：每次冷启动都用同一个闭包现验一次；拉取失败不改 LKG。
      const env: EnvBox = new EnvBox();
      const verify: BridgeOriginsCheck = BridgeOriginsWiring.check((): string | undefined => env.read(), APP_ID, stagingKeys(),
        new RecordingEs256('true'));
      let disk: string | null = '{"format":1,"saved_at":0,"data":' + stagingData() + '}';
      const pending: ((reply: ConfigReply) => void)[] = [];
      const coldStart: () => ConfigStore = (): ConfigStore => {
        const store: ConfigStore = new ConfigStore((): string | null => disk, (value: string | null): void => {
          disk = value;
        }, (_etag: string | null, done: (reply: ConfigReply) => void): void => {
          pending.push(done);
        }, (): number => 0, '{}', verify);
        store.onColdStart();
        const done: ((reply: ConfigReply) => void) | undefined = pending.shift();
        if (done !== undefined) {
          done(new ConfigReply(ConfigReply.FAILURE, null, null));
        }
        return store;
      };
      same('staging：生产闭包收下', coldStart().trustedOrigins(), [GOOD_ORIGIN]);
      for (const name of ['test', 'prod']) {
        env.value = name;
        const store: ConfigStore = coldStart();
        same('切到 ' + name + '：同一份文档不认', store.trustedOrigins(), []);
        same('切到 ' + name + '：version', store.trustedOriginsVersion(), null);
      }
      env.value = 'staging';
      same('切回 staging：又收下', coldStart().trustedOrigins(), [GOOD_ORIGIN]);
      check('LKG 没被改写成带字段的新格式', disk !== null && (disk as string).indexOf('bridge_origins_last_good') < 0);
    });

    it('wiring_04_rejection_logs_reason_kid_and_env_once_without_jws_or_origins', 0, () => {
      const env: EnvBox = new EnvBox();
      const lines: string[] = [];
      const verify: BridgeOriginsCheck = BridgeOriginsWiring.check((): string | undefined => env.read(), APP_ID, stagingKeys(),
        new RecordingEs256('false'), (line: string): void => {
          lines.push(line);
        });
      const dirtyKid: string = 'kid with spaces\n<' + 'x'.repeat(80) + '>';
      const data: string = stagingData('0', dirtyKid);
      verify(data, null);
      same('拒绝记一行', lines.length, 1);
      const line: string = lines[0];
      check('含 reason（约定字符串之一）', line.indexOf('reason=') >= 0);
      check('含 env', line.indexOf('env=staging') >= 0);
      check('kid 只留 [A-Za-z0-9._-]、截断到 64', line.indexOf('kid=' + 'kidwithspacesx'.padEnd(64, 'x')) >= 0 &&
        line.indexOf('kid=' + 'kidwithspacesx'.padEnd(65, 'x')) < 0);
      const bridge: Record<string, Object> = (JSON.parse(data) as Record<string, Object>)['bridge_origins'] as
        Record<string, Object>;
      for (const segment of (bridge['jws'] as string).split('.')) {
        check('不写 jws 的任何一段', line.indexOf(segment) < 0);
      }
      check('不写 origins', line.indexOf(GOOD_ORIGIN) < 0 && line.indexOf('h5.example.test') < 0);
      check('不换行', line.indexOf('\n') < 0);
      verify(data, null);
      same('同一份文档、同一环境再来：不再记', lines.length, 1);
      env.value = 'prod';
      verify(data, null);
      same('换了环境：再记一条', lines.length, 2);
      check('新的一条写新环境', lines[1].indexOf('env=prod') >= 0);
      const throwing: BridgeOriginsCheck = BridgeOriginsWiring.check((): string | undefined => 'staging', APP_ID, stagingKeys(),
        new RecordingEs256('false'), (_line: string): void => {
          throw new Error('log sink failure');
        });
      same('日志出口抛错不影响判定', originsOf(throwing(data, null)), 'null');
    });
  });
}
