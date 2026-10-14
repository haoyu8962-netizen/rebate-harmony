// Debug / Staging 专用：Agent 的本机假服务接线（APP-10 §2、§3；APP-10b §2 第 12、13 条）。只在 product=staging 编译，Release 的同名文件
// （src/release/ets/agent/AgentVariant.ets）没有任何假服务。release-scan 查 COULI_AGENT_FAKE_APP10_7d3e15、couli_debug_agent_fixture。
// APP-10b：Release 与 Debug / Staging 都用真实端口 ApiAgentContractPort（AppAgent 组合）；本机假服务只是 ApiClient 下面的「服务端」——
// DebugFakeServer 在实际传输入口经 DebugMockTransport 同一道闸门（`--pd couli_debug_fake_server 1` 打开 + 当前环境允许调试假数据，prod 不允许）
// 把 /v1/agent/* 交给这里的 AgentFakeTransport，否则走真实 RCP。不连任何地址；数据是锁定契约的 15 个 fixture 与由它改出的构造样例。
// 启动参数（截图与冒烟）：
// - `--ps couli_debug_agent_fixture <名字>`：下一条消息回答哪个 fixture（normal、tool-failed、cancelled、disconnected（最后一行后挂起 30 秒）、
//   unknown-card、unknown-card-page-guide、error、error-search-fallback、fallback、normal-page-guide、normal-earnings、normal-earnings-history
//   （SSE 收到历史形状）、duplicate-*；构造：login_required、grid、relaxed、spec_unconfirmed、price_compare_risk、off_shelf、coupon_gone、
//   json_<错误码>（如 json_30502、json_42901、json_50401；json_30502_<next> 带 data.next）、seq_gap、limit_401、too_large、hang（meta 后挂起）、
//   slow_meta（meta 在 5 秒后才到，测「正在停止」））。
// - `--ps couli_debug_agent_consent 1`：AI 同意未记录（发消息回 10004 ai_third_party，弹 AgentConsent）。
// - `--ps couli_debug_agent_send <文字>`：外壳就绪后切到 AI 助手并发出这条消息（只在 Debug / Staging，截图用）。
// - `--ps couli_debug_agent_history <场景>`：进入页面时有当前会话并返回这一历史场景（active、expired、paged、bad_amount、unknown_card）。
// - `--ps couli_debug_agent_result <operation>:<码>`：反馈 / 举报 / 停止 / 历史的结果码（如 feedback:50001、report:20001、history:-1）。
// - `--ps couli_debug_agent_chunks 1,3,17`：SSE 字节切块尺寸（循环）。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Want } from '@kit.AbilityKit';
import {
  AGENT_FAKE_MARKER, AgentController, AgentFakeHistoryScenario, AgentFakeScript, AgentFakeTransport, AgentJson,
  AgentJsonObject, AgentJsonValue, AgentPhase, SystemAgentTimer
} from 'core';
import { AGENT_DEBUG_FIXTURES } from '../variant/AgentFixtures';

export const DEBUG_AGENT_FIXTURE_KEY: string = 'couli_debug_agent_fixture';
export const DEBUG_AGENT_SEND_KEY: string = 'couli_debug_agent_send';
/** 启动参数自动发送的实现标记（R1-11：只在 staging 源码集；release-scan 要求 Release 制品里找不到它）。 */
export const AGENT_LAUNCH_SEND_MARKER: string = 'COULI_AGENT_LAUNCH_SEND_APP10_2f9c4d';

/** fixture 名 → ndjson 原文（构造样例由 normal 改出，不冒充契约 fixture）。 */
function scriptOf(name: string, body: string): AgentFakeScript {
  const s: AgentFakeScript = new AgentFakeScript();
  if (name.startsWith('json_')) {
    s.ndjson = null;
    const parts: string[] = name.substring(5).split('_');
    s.errorCode = Number.parseInt(parts[0], 10);
    s.errorStatus = s.errorCode === 42901 ? 429 : (s.errorCode >= 50000 ? 503 : 422);
    s.retryAfter = s.errorCode === 42901 ? '12' : null;
    if (s.errorCode === 30502 && parts.length > 1) {
      // 30502 的 data.next（CT-LOCK-01 G08；构造）。
      const data: AgentJsonObject = {};
      data['next'] = parts.slice(1).join('_');
      data['reset_at'] = '2026-10-15T00:00:00+08:00';
      s.errorData = data;
    }
    return s;
  }
  if (name === 'seq_gap' || name === 'limit_401' || name === 'too_large' || name === 'hang' || name === 'slow_meta') {
    const normal: string = AGENT_DEBUG_FIXTURES.get('normal.ndjson') ?? '';
    s.ndjson = transportCase(normal, name);
    if (name === 'hang') {
      s.hangAfterLine = 1;
    }
    if (name === 'slow_meta') {
      s.headersDelayMs = 0;
      s.intervalMs = 5000;
      s.hangAfterLine = 1;
    }
    return s;
  }
  const raw: string | undefined = AGENT_DEBUG_FIXTURES.get(name + '.ndjson');
  if (raw !== undefined) {
    s.ndjson = name === 'normal-earnings-history' ? wrapHistory(raw) : raw;
    if (name === 'disconnected') {
      // 最后一行后挂起（不结束、不再发 ping）：30 秒后客户端判断线。
      s.hangAfterLine = raw.split('\n').filter((l: string): boolean => l.trim().length > 0).length;
    }
    return s;
  }
  const normal: string = AGENT_DEBUG_FIXTURES.get('normal.ndjson') ?? '';
  s.ndjson = constructed(normal, name);
  return s;
}

/** 历史形状的收益卡只有一行 card 帧：截图时包成一轮流（meta + card + done），按 SSE 来源的「恰好合历史形状 → 历史渲染」显示（G13）。 */
function wrapHistory(raw: string): string {
  const meta: string = '{"event":"meta","id":1,"data":{"session_id":"019a0000-0000-7000-8000-000000000001",'
    + '"run_id":"019a0000-0000-7000-8000-000000000109","message_id":"019a0000-0000-7000-8000-000000000209",'
    + '"prompt_version":"demo-prompt-v1","model_label":"演示模型","ai_label":"内容由 AI 生成，仅供参考"}}';
  const done: string = '{"event":"done","id":9,"data":{"finish_reason":"stop","quota_left":20}}';
  return meta + '\n' + raw.trim() + '\n' + done + '\n';
}

/** APP-10b 传输构造（标「构造」）：缺号（去掉 id=3 那一帧）、401 条 1 字的 text.delta、70 KiB 单帧、meta 后挂起。 */
function transportCase(normal: string, name: string): string {
  const lines: string[] = normal.split('\n').filter((l: string): boolean => l.trim().length > 0);
  if (name === 'seq_gap') {
    return lines.filter((l: string): boolean => {
      const o: AgentJsonObject | null = AgentJson.objectOf(AgentJson.parse(l));
      return o === null || o['id'] !== 3;
    }).join('\n') + '\n';
  }
  const meta: string = lines[0];
  if (name === 'limit_401') {
    const out: string[] = [meta];
    for (let i: number = 2; i <= 402; i++) {
      out.push('{"event":"text.delta","id":' + String(i) + ',"data":{"seq":' + String(i) + ',"delta":"字"}}');
    }
    out.push('{"event":"done","id":403,"data":{"finish_reason":"stop","quota_left":20}}');
    return out.join('\n') + '\n';
  }
  if (name === 'too_large') {
    const big: string = 'x'.repeat(71680);
    return meta + '\n{"event":"text.delta","id":2,"data":{"seq":2,"delta":"' + big + '"}}\n'
      + '{"event":"done","id":3,"data":{"finish_reason":"stop","quota_left":20}}\n';
  }
  return meta + '\n';
}

/** 构造样例（向量里的构造形态，标「构造」）：改 normal 第一张 product_list 卡的第一件商品。 */
function constructed(normal: string, name: string): string {
  const lines: string[] = normal.split('\n').filter((l: string): boolean => l.trim().length > 0);
  const out: string[] = [];
  let done: boolean = false;
  for (const line of lines) {
    const o: AgentJsonObject | null = AgentJson.objectOf(AgentJson.parse(line));
    const data: AgentJsonObject | null = o === null ? null : AgentJson.objectOf(o['data']);
    if (!done && o !== null && o['event'] === 'card' && data !== null && data['type'] === 'product_list') {
      const inner: AgentJsonObject = data['data'] as AgentJsonObject;
      const items: AgentJsonValue[] = AgentJson.arrayOf(inner['items']) ?? [];
      if (items.length > 0) {
        const p: AgentJsonObject = items[0] as AgentJsonObject;
        switch (name) {
          case 'login_required':
            p['rebate_basis'] = 'login_required';
            p['rebate_min_fen'] = null;
            p['rebate_max_fen'] = null;
            break;
          case 'price_compare_risk':
            p['rebate_basis'] = 'price_compare_risk';
            p['rebate_min_fen'] = 120;
            p['rebate_max_fen'] = 260;
            break;
          case 'relaxed':
            p['match_tag'] = 'relaxed';
            break;
          case 'spec_unconfirmed':
            p['match_tag'] = 'spec_unconfirmed';
            p['spec_text'] = null;
            break;
          case 'grid':
            inner['layout'] = 'grid';
            break;
          case 'off_shelf':
            p['availability'] = 'off_shelf';
            break;
          case 'coupon_gone':
            p['availability'] = 'coupon_gone';
            break;
          default:
            break;
        }
      }
      done = true;
      out.push(JSON.stringify(o));
      continue;
    }
    out.push(line);
  }
  return out.join('\n') + '\n';
}

export class AgentVariant {
  static readonly marker: string = AGENT_FAKE_MARKER;
  static fixture: string = 'normal';
  private static sendOnLaunch: string | null = null;
  private static fake: AgentFakeTransport | null = null;

  /**
   * 7 个 /v1/agent operation 的本机假服务（只在 DebugFakeServer 的传输入口闸门放行时被调用）。惰性创建；不保存任何请求正文。
   */
  static fakeTransport(): AgentFakeTransport {
    if (AgentVariant.fake === null) {
      AgentVariant.fake = new AgentFakeTransport(new SystemAgentTimer(),
        (body: string): AgentFakeScript => scriptOf(AgentVariant.fixture, body));
    }
    return AgentVariant.fake as AgentFakeTransport;
  }

  private static entryOverride: boolean | null = null;

  /** 截图用：`--ps couli_debug_agent_entry hidden` 模拟 Config agent.entry.visible=false（只在 Debug / Staging）。 */
  static entryVisibleOverride(): boolean | null {
    return AgentVariant.entryOverride;
  }

  /** recordConsent(ai_third_party) 成功后告知本机假服务（之后不再回 10004）；撤回后恢复回 10004。 */
  static consentRecorded(accepted: boolean): void {
    AgentVariant.fakeTransport().consentGranted = accepted;
  }

  /** 启动参数（截图与冒烟）。 */
  static applyLaunch(want: Want): void {
    const fixture: Object | undefined = want.parameters?.[DEBUG_AGENT_FIXTURE_KEY];
    if (typeof fixture === 'string' && (fixture as string).length > 0) {
      AgentVariant.fixture = fixture as string;
      hilog.info(0x0000, 'Couli', 'agent fixture %{public}s %{public}s', fixture as string, AgentVariant.marker);
    }
    const fake: AgentFakeTransport = AgentVariant.fakeTransport();
    const consent: Object | undefined = want.parameters?.['couli_debug_agent_consent'];
    if (consent === '1') {
      fake.consentGranted = false;
    } else if (consent === '0') {
      fake.consentGranted = true;
    }
    const history: Object | undefined = want.parameters?.['couli_debug_agent_history'];
    if (typeof history === 'string' && (history as string).length > 0) {
      fake.historyScenario = history as string;
      fake.currentSessionId = history === AgentFakeHistoryScenario.NONE ? null : '019a0000-0000-7000-8000-000000000021';
    }
    const result: Object | undefined = want.parameters?.['couli_debug_agent_result'];
    if (typeof result === 'string') {
      for (const item of (result as string).split(',')) {
        const pair: string[] = item.split(':');
        const code: number = pair.length === 2 ? Number.parseInt(pair[1], 10) : 0;
        if (pair[0] === 'feedback') {
          fake.feedbackCode = code;
        } else if (pair[0] === 'report') {
          fake.reportCode = code;
        } else if (pair[0] === 'cancel') {
          fake.cancelCode = code;
        } else if (pair[0] === 'history') {
          fake.historyCode = code;
        }
      }
    }
    const entry: Object | undefined = want.parameters?.['couli_debug_agent_entry'];
    if (entry === 'hidden') {
      AgentVariant.entryOverride = false;
    }
    const chunks: Object | undefined = want.parameters?.['couli_debug_agent_chunks'];
    if (typeof chunks === 'string') {
      fake.chunkSizes = (chunks as string).split(',').map((v: string): number => Number.parseInt(v, 10))
        .filter((n: number): boolean => n > 0);
    }
    const send: Object | undefined = want.parameters?.[DEBUG_AGENT_SEND_KEY];
    if (typeof send === 'string' && (send as string).length > 0) {
      AgentVariant.sendOnLaunch = send as string;
    }
  }

  /**
   * AI 助手 Tab 显示后（截图与冒烟）：把启动参数给的一条消息发出一次（一次性；每 600 ms 看一次控制器是否就绪，最多 10 次）。
   * 整段实现只在 staging 源码集（R1-11）；Release 的同名方法是空实现。发送仍经控制器的票据与闸门（同意、可见性、限流）。
   */
  static onAgentShown(current: () => AgentController | null): void {
    const text: string | null = AgentVariant.sendOnLaunch;
    AgentVariant.sendOnLaunch = null;
    if (text === null) {
      return;
    }
    hilog.info(0x0000, 'Couli', 'agent launch send %{public}s', AGENT_LAUNCH_SEND_MARKER);
    AgentVariant.trySend(current, text, 10);
  }

  private static trySend(current: () => AgentController | null, text: string, left: number): void {
    setTimeout((): void => {
      const now: AgentController | null = current();
      if (now !== null && now.currentPhase === AgentPhase.READY) {
        now.send(now.snapshot().page, text);
      } else if (left > 0) {
        AgentVariant.trySend(current, text, left - 1);
      }
    }, 600);
  }
}
