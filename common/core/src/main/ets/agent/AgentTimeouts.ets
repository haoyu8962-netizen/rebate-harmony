// APP-10b §2 第 4 条（G16、G33）：StreamClient 实际使用的计时的向量接线入口（虚拟计时器同在测试源码集）。30 秒空闲从请求写出起算、只有完整的 SSE 行
// （含 `: ping` 与空行）重置；响应头、半行、JSON 正文分块不重置；另有单轮总时长上限 90 秒（代拟）。驱动 StreamClient 的脚本端口与帧数据只在
// 测试源码集（harmony-review-r1 R1-04）。
import { AgentJson, AgentJsonObject, AgentJsonValue } from './AgentJson';

/**
 * 计时向量（timeouts 组）的接线入口（harmony-review-r1 R1-04，S0）：驱动真实 StreamClient 的脚本端口、虚拟流与「正常结束」的 meta / done 帧
 * 只在测试源码集（common/core/src/test/AgentVectorWiring.ets，List.test.ets 启动时 install）；生产制品里没有假端口、没有硬编码帧。
 * 没有注入实现时返回空对象（生产代码不调用它）。
 */
export class AgentTimeoutPolicy {
  static wiring: ((input: AgentJsonObject, nowMs: number) => AgentJsonObject) | null = null;

  static of(input: AgentJsonObject, nowMs: number): AgentJsonObject {
    const w: ((input: AgentJsonObject, nowMs: number) => AgentJsonObject) | null = AgentTimeoutPolicy.wiring;
    return w === null ? {} : w(input, nowMs);
  }
}

/** JSON 值是数组时转成数字列表（向量接线共用的小工具）。 */
export function agentNumbers(v: AgentJsonValue | undefined): number[] {
  return (AgentJson.arrayOf(v) ?? []).map((x: AgentJsonValue): number => typeof x === 'number' ? x as number : 0);
}
