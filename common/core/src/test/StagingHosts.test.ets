// FU-X-STAGING-HOSTS-harmony（staging 连真实主机；D10-598 ① stream 接线）测试作者 v1。
// 被测：
//   - common/core/src/staging/ets/config/EnvironmentCatalog.ets 的 STAGING 三个基址（api / h5 / stream）；LOCAL / TEST 仍 .invalid；
//   - common/core/src/main/ets/config/AppEnvironment.ets 的 EnvironmentEndpoints 新字段 streamBase（第三个构造参数，缺省 ''）与 PROD_ENDPOINTS 不变；
//   - common/core/src/main/ets/network/ApiClient.ets：streamBase 非空时 /v1/agent/* 发往 stream 入口（整包请求与 ApiClient.stream 都算），
//     空时与原行为一致（一律 apiBase），非 agent 路径永不走 stream（含刷新令牌、查询串里带 /v1/agent/ 的请求）；
//   - DeepLinkParser 认 staging 深链主机 l-stg（BuildVariant 的实际取值由 tools/ci/stghosts/check_staging_hosts.py 静态钉住）。
// 接口最小签名见 NATIVE/FU-X-STAGING-HOSTS/tests-harmony-handback.md §3。本机单测不连任何地址（主机名只是字符串，经替身传输层记录）。
// 无像密钥的字面量。tools/ci/stghosts/run-logic.cjs 用 node 执行本文件（真实产品源码）。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiClient, ApiClientDeps, ApiOperation, ApiOperations, ApiRequest, ApiResult, ApiStreamRequest, ApiStreamSink, AppEnvironment,
  DeepLinkConfig, DeepLinkParser, EnvironmentEndpoints, HttpStreamTransport, PROD_ENDPOINTS, RouteRequest, SessionTokenSet,
  TransportFailure, TransportRequest, TransportResponse, TransportStreamSink
} from '../../Index';
import { EnvironmentCatalog as ReleaseCatalog } from '../release/ets/config/EnvironmentCatalog';
import { EnvironmentCatalog as StagingCatalog } from '../staging/ets/config/EnvironmentCatalog';
import { envelope, FakeContext, flush, header, Rig, tokenPair } from './NetworkTestRig';

const STG_API: string = 'https://api-stg.couliapp.cn';
const STG_H5: string = 'https://h5-stg.couliapp.cn';
const STG_STREAM: string = 'https://stream-stg.couliapp.cn';
const STG_LINK_HOST: string = 'l-stg.couliapp.cn';
const PROD_API: string = 'https://api.prod.couli.invalid';
const PROD_H5: string = 'https://h5.prod.couli.invalid';
/** 测试自己的分流基址（不是任何真实主机）。 */
const UNIT_API: string = 'https://api.unit-stg.invalid';
const UNIT_STREAM: string = 'https://stream.unit-stg.invalid';
const AGENT_PREFIX: string = '/v1/agent/';
/** 契约 7 个 /v1/agent operation（锁定快照；多了少了都要回来核分流口径）。 */
const AGENT_OPS: string[] = ['createAgentSession', 'getCurrentAgentSession', 'listAgentSessionMessages', 'sendAgentMessage',
  'cancelAgentRun', 'setAgentMessageFeedback', 'reportAgentMessage'];
const SESSION_ID: string = '019a0000-0000-7000-8000-000000000021';

function endpointsOf(map: Map<AppEnvironment, EnvironmentEndpoints>, env: AppEnvironment): EnvironmentEndpoints {
  const found: EnvironmentEndpoints | undefined = map.get(env);
  if (found === undefined) {
    throw new Error('catalog has no ' + env);
  }
  return found;
}

function same(label: string, actual: Object | null | undefined, expected: Object | null | undefined): void {
  const a: string = JSON.stringify(actual);
  const e: string = JSON.stringify(expected);
  if (a !== e) {
    throw new Error(label + ': actual=' + a + ' expect=' + e);
  }
  expect(a).assertEqual(e);
}

function check(label: string, ok: boolean): void {
  if (!ok) {
    throw new Error(label);
  }
  expect(ok).assertTrue();
}

/** 恰好是 https://<host>：无端口、无路径、无结尾斜杠、无查询。 */
function bareHttpsOrigin(url: string): boolean {
  return /^https:\/\/[a-z0-9.-]+$/.test(url);
}

/** 可切换基址的网络上下文（Rig 的 FakeContext 恒为两参数端点）。 */
class SwitchableContext extends FakeContext {
  current: EnvironmentEndpoints;

  constructor(current: EnvironmentEndpoints) {
    super();
    this.current = current;
  }

  endpoints(): EnvironmentEndpoints | undefined {
    return this.settled ? this.current : undefined;
  }
}

/** 流式传输替身：只记录 admit 通过后实际写出的 URL，然后回一个空的 SSE（立即结束）。 */
class RecordingStream implements HttpStreamTransport {
  readonly urls: string[] = [];

  stream(request: TransportRequest, sink: TransportStreamSink): void {
    if (!request.admit()) {
      sink.onFailure(TransportFailure.CANCELLED);
      return;
    }
    this.urls.push(request.url);
    const headers: Record<string, string> = {};
    headers['content-type'] = 'text/event-stream; charset=utf-8';
    sink.onHeaders(200, headers);
    sink.onEnd();
  }

  cancelStream(_request: TransportRequest): void {
  }
}

class StreamOutcome implements ApiStreamSink {
  ended: boolean = false;
  result: ApiResult | null = null;

  onHeaders(_status: number, _headers: Record<string, string>): void {
  }

  onBytes(_chunk: ArrayBuffer): void {
  }

  onEnd(): void {
    this.ended = true;
  }

  onFailure(_failure: string): void {
  }

  onEnvelope(result: ApiResult): void {
    this.result = result;
  }
}

class Wired {
  readonly rig: Rig;
  readonly context: SwitchableContext;
  readonly streams: RecordingStream = new RecordingStream();

  constructor(endpoints: EnvironmentEndpoints) {
    this.context = new SwitchableContext(endpoints);
    const streams: RecordingStream = this.streams;
    this.rig = new Rig(new SessionTokenSet('old-access', 'old-refresh', 'full', 'user-1'), null, null, null, null, null, null,
      null, this.context, (deps: ApiClientDeps): ApiClient => {
        deps.streamTransport = streams;
        return new ApiClient(deps);
      });
  }

  /** 整包请求实际写出的全部 URL（含刷新等内部请求）。 */
  urls(): string[] {
    return this.rig.server.received.map((r: TransportRequest): string => r.url);
  }
}

function params(op: ApiOperation): Record<string, string> {
  const out: Record<string, string> = {};
  const names: RegExpMatchArray | null = op.pathTemplate.match(/\{[a-z_]+\}/g);
  if (names !== null) {
    for (const raw of names) {
      out[raw.slice(1, raw.length - 1)] = raw === '{platform}' ? 'taobao' : 'p1';
    }
  }
  return out;
}

function bodyOf(op: ApiOperation): string | null {
  return op.method === 'GET' || op.method === 'DELETE' ? null : '{}';
}

function agentOperations(): ApiOperation[] {
  return Array.from(ApiOperations.all.values()).filter((op: ApiOperation): boolean => op.pathTemplate.startsWith(AGENT_PREFIX));
}

function nonAgentOperations(): ApiOperation[] {
  return Array.from(ApiOperations.all.values()).filter((op: ApiOperation): boolean => !op.pathTemplate.startsWith(AGENT_PREFIX));
}

async function send(w: Wired, op: ApiOperation, query: string = ''): Promise<ApiResult> {
  return w.rig.client.request(new ApiRequest(op.operationId, params(op), query, bodyOf(op)));
}

async function streamOnce(w: Wired): Promise<StreamOutcome> {
  const sinkParams: Record<string, string> = {};
  sinkParams['id'] = SESSION_ID;
  const outcome: StreamOutcome = new StreamOutcome();
  w.rig.client.stream(new ApiStreamRequest('sendAgentMessage', sinkParams,
    '{"client_msg_id":"019a0000-0000-7000-8000-000000000301","content":"hi"}'), outcome);
  await flush();
  await flush();
  return outcome;
}

function op(id: string): ApiOperation {
  const found: ApiOperation | undefined = ApiOperations.byId(id);
  if (found === undefined) {
    throw new Error('operation missing ' + id);
  }
  return found;
}

export default function stagingHostsTest() {
  describe('FuXStagingHostsHarmony', () => {
    // ---------------------------------------------------------------- E：环境端点表
    it('e01_staging_catalog_uses_the_real_staging_api_h5_and_stream_hosts', 0, () => {
      const staging: EnvironmentEndpoints = endpointsOf(StagingCatalog.endpoints(), AppEnvironment.STAGING);
      same('staging api', staging.apiBase, STG_API);
      same('staging h5', staging.h5Base, STG_H5);
      same('staging stream', staging.streamBase, STG_STREAM);
      check('staging bases are bare https origins',
        bareHttpsOrigin(staging.apiBase) && bareHttpsOrigin(staging.h5Base) && bareHttpsOrigin(staging.streamBase));
    });

    it('e02_staging_no_longer_uses_the_invalid_placeholder', 0, () => {
      const staging: EnvironmentEndpoints = endpointsOf(StagingCatalog.endpoints(), AppEnvironment.STAGING);
      for (const base of [staging.apiBase, staging.h5Base, staging.streamBase]) {
        check('staging base still a placeholder: ' + base, base.indexOf('.invalid') < 0 && base.indexOf('couli.invalid') < 0);
      }
    });

    it('e03_local_and_test_stay_invalid_placeholders', 0, () => {
      const map: Map<AppEnvironment, EnvironmentEndpoints> = StagingCatalog.endpoints();
      const local: EnvironmentEndpoints = endpointsOf(map, AppEnvironment.LOCAL);
      const test: EnvironmentEndpoints = endpointsOf(map, AppEnvironment.TEST);
      same('local', [local.apiBase, local.h5Base], ['https://api.local.couli.invalid', 'https://h5.local.couli.invalid']);
      same('test', [test.apiBase, test.h5Base], ['https://api.test.couli.invalid', 'https://h5.test.couli.invalid']);
      for (const e of [local, test]) {
        // stream 可以不设（''，不分流）；设了也只能是 .invalid 占位，不得指向任何真实主域。
        check('local/test stream must be empty or a .invalid placeholder: ' + e.streamBase,
          e.streamBase === '' || (bareHttpsOrigin(e.streamBase) && e.streamBase.endsWith('.couli.invalid')));
        for (const base of [e.apiBase, e.h5Base, e.streamBase]) {
          check('local/test must not point at couliapp: ' + base, base.indexOf('couliapp') < 0);
        }
      }
    });

    it('e04_prod_is_unchanged_and_sets_no_stream', 0, () => {
      same('prod', [PROD_ENDPOINTS.apiBase, PROD_ENDPOINTS.h5Base, PROD_ENDPOINTS.streamBase], [PROD_API, PROD_H5, '']);
      check('staging catalog prod is the shared PROD_ENDPOINTS',
        endpointsOf(StagingCatalog.endpoints(), AppEnvironment.PROD) === PROD_ENDPOINTS);
      const release: Map<AppEnvironment, EnvironmentEndpoints> = ReleaseCatalog.endpoints();
      same('release catalog keys', Array.from(release.keys()), [AppEnvironment.PROD]);
      check('release catalog prod is PROD_ENDPOINTS', endpointsOf(release, AppEnvironment.PROD) === PROD_ENDPOINTS);
    });

    it('e05_two_argument_endpoints_default_to_no_stream', 0, () => {
      const two: EnvironmentEndpoints = new EnvironmentEndpoints(UNIT_API, 'https://h5.unit-stg.invalid');
      same('default stream', two.streamBase, '');
      const three: EnvironmentEndpoints = new EnvironmentEndpoints(UNIT_API, 'https://h5.unit-stg.invalid', UNIT_STREAM);
      same('explicit stream', [three.apiBase, three.streamBase], [UNIT_API, UNIT_STREAM]);
    });

    // ---------------------------------------------------------------- S：stream 分流（D10-598 ①）
    it('s01_contract_has_exactly_the_seven_agent_operations', 0, () => {
      same('agent ops', agentOperations().map((o: ApiOperation): string => o.operationId).sort(), AGENT_OPS.slice().sort());
    });

    it('s02_with_stream_base_every_agent_request_goes_to_the_stream_entry', 0, async () => {
      const w: Wired = new Wired(new EnvironmentEndpoints(UNIT_API, 'https://h5.unit-stg.invalid', UNIT_STREAM));
      for (const id of AGENT_OPS) {
        if (id === 'sendAgentMessage') {
          continue;
        }
        const before: number = w.rig.server.received.length;
        await send(w, op(id));
        const sent: string[] = w.urls().slice(before);
        check(id + ' was not sent at all', sent.length > 0);
        for (const url of sent) {
          check(id + ' must go to stream entry, got ' + url, url.startsWith(UNIT_STREAM + AGENT_PREFIX));
        }
      }
    });

    it('s03_with_stream_base_the_sse_call_goes_to_the_stream_entry', 0, async () => {
      const w: Wired = new Wired(new EnvironmentEndpoints(UNIT_API, 'https://h5.unit-stg.invalid', UNIT_STREAM));
      const outcome: StreamOutcome = await streamOnce(w);
      same('stream urls', w.streams.urls, [UNIT_STREAM + '/v1/agent/sessions/' + SESSION_ID + '/messages']);
      check('stream ended', outcome.ended);
      same('no whole-body request for the stream', w.urls().length, 0);
    });

    it('s04_without_stream_base_agent_requests_keep_the_api_base', 0, async () => {
      const w: Wired = new Wired(new EnvironmentEndpoints(UNIT_API, 'https://h5.unit-stg.invalid'));
      for (const id of AGENT_OPS) {
        if (id === 'sendAgentMessage') {
          continue;
        }
        const before: number = w.rig.server.received.length;
        await send(w, op(id));
        const sent: string[] = w.urls().slice(before);
        check(id + ' was not sent at all', sent.length > 0);
        for (const url of sent) {
          check(id + ' must stay on api base, got ' + url, url.startsWith(UNIT_API + AGENT_PREFIX));
        }
      }
      await streamOnce(w);
      same('stream on api base', w.streams.urls, [UNIT_API + '/v1/agent/sessions/' + SESSION_ID + '/messages']);
    });

    it('s05_prod_endpoints_route_agent_calls_exactly_as_before', 0, async () => {
      const w: Wired = new Wired(PROD_ENDPOINTS);
      await send(w, op('createAgentSession'));
      same('prod agent url', w.urls(), [PROD_API + '/v1/agent/sessions']);
      await streamOnce(w);
      same('prod stream url', w.streams.urls, [PROD_API + '/v1/agent/sessions/' + SESSION_ID + '/messages']);
    });

    it('s06_non_agent_operations_never_use_the_stream_entry', 0, async () => {
      const w: Wired = new Wired(new EnvironmentEndpoints(UNIT_API, 'https://h5.unit-stg.invalid', UNIT_STREAM));
      const reached: string[] = [];
      for (const o of nonAgentOperations()) {
        const before: number = w.rig.server.received.length;
        await send(w, o);
        if (w.rig.server.received.length > before) {
          reached.push(o.operationId);
        }
      }
      for (const url of w.urls()) {
        check('non-agent request went to ' + url, url.startsWith(UNIT_API + '/') && url.indexOf(UNIT_STREAM) < 0);
      }
      same('stream transport untouched', w.streams.urls.length, 0);
      // 防空过：大多数非 agent 操作在这套替身下确实写出了请求。
      check('only ' + reached.length + ' non-agent operations reached the transport', reached.length >= 30);
      check('getConfig reached the transport', reached.indexOf('getConfig') >= 0);
      check('registerDevice reached the transport', reached.indexOf('registerDevice') >= 0);
    });

    it('s07_agent_text_in_a_query_string_does_not_divert_to_stream', 0, async () => {
      const w: Wired = new Wired(new EnvironmentEndpoints(UNIT_API, 'https://h5.unit-stg.invalid', UNIT_STREAM));
      await send(w, op('searchProducts'), 'q=/v1/agent/sessions');
      await send(w, op('listArticles'), 'category=agent');
      same('query lookalikes stay on api', w.urls(),
        [UNIT_API + '/v1/products/search?q=/v1/agent/sessions', UNIT_API + '/v1/articles?category=agent']);
    });

    it('s08_refresh_inside_an_agent_call_goes_to_api_and_the_replay_to_stream', 0, async () => {
      const w: Wired = new Wired(new EnvironmentEndpoints(UNIT_API, 'https://h5.unit-stg.invalid', UNIT_STREAM));
      w.rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        if (request.url.indexOf('/v1/auth/refresh') >= 0) {
          return Promise.resolve(envelope(0, tokenPair('new-access', 'new-refresh', 'full')));
        }
        if (header(request, 'Authorization') === 'Bearer new-access') {
          return Promise.resolve(envelope(0, '{"session":null}'));
        }
        return Promise.resolve(envelope(10002, '{}'));
      };
      const result: ApiResult = await send(w, op('getCurrentAgentSession'));
      same('outcome', result.outcome, 'success');
      same('wire', w.urls(), [UNIT_STREAM + '/v1/agent/sessions/current', UNIT_API + '/v1/auth/refresh',
        UNIT_STREAM + '/v1/agent/sessions/current']);
    });

    it('s09_switching_environment_switches_both_bases_together', 0, async () => {
      const w: Wired = new Wired(endpointsOf(StagingCatalog.endpoints(), AppEnvironment.STAGING));
      await send(w, op('createAgentSession'));
      await send(w, op('getConfig'));
      w.context.current = endpointsOf(StagingCatalog.endpoints(), AppEnvironment.TEST);
      const testBase: string = w.context.current.streamBase === '' ? 'https://api.test.couli.invalid' : w.context.current.streamBase;
      await send(w, op('createAgentSession'));
      await send(w, op('getConfig'));
      same('wire', w.urls(), [STG_STREAM + '/v1/agent/sessions', STG_API + '/v1/config',
        testBase + '/v1/agent/sessions', 'https://api.test.couli.invalid/v1/config']);
    });

    // ---------------------------------------------------------------- D：staging 深链主机（解析层；取值由宿主检查钉）
    it('d01_staging_link_host_parses_and_lookalikes_are_rejected', 0, () => {
      const config: DeepLinkConfig = new DeepLinkConfig(['couli-debug'], [STG_LINK_HOST]);
      const ok: RouteRequest | null = DeepLinkParser.parse('https://' + STG_LINK_HOST + '/r/Home', config);
      check('https l-stg link parses', ok !== null && ok.route === 'Home');
      const scheme: RouteRequest | null = DeepLinkParser.parse('couli-debug://r/Home', config);
      check('debug scheme kept', scheme !== null && scheme.route === 'Home');
      const rejected: string[] = ['http://' + STG_LINK_HOST + '/r/Home', 'https://x.' + STG_LINK_HOST + '/r/Home',
        'https://' + STG_LINK_HOST + '.evil.invalid/r/Home', 'https://' + STG_LINK_HOST + ':8443/r/Home',
        'https://s-stg.couliapp.cn/r/Home', 'https://l.couliapp.cn/r/Home'];
      for (const url of rejected) {
        check('must reject ' + url, DeepLinkParser.parse(url, config) === null);
      }
    });
  });
}
