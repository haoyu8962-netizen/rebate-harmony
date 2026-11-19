import { ConfigStore } from './ConfigStore';

/**
 * 埋点诊断字段（规划/03 §4.7「诊断字段」；events.yaml version 6 起 bridge_call、sdui_card_error 必带 schema_version /
 * bridge_version / config_version / h5_release）：所在层没有、或尚未取到时一律填固定值 UNKNOWN，不留空、不借用别的版本号
 * （LOCK-harmony 段 1，照安卓 EventDiagnostics 与 D10-1612 ④ (i)）。纯函数，单测在 core。
 */
export class EventDiagnostics {
  /** 取不到时的固定值（events.yaml 诊断字段的 note）。 */
  static readonly UNKNOWN: string = 'unknown';
  /** 生效配置里的键（openapi Config.config_version）。 */
  static readonly CONFIG_VERSION_KEY: string = 'config_version';

  /**
   * config_version（04 §10.1：= /v1/config 响应 ETag 去引号，随 LKG 保存）：参数是生效配置那一层里 config_version 的 JSON 文本
   * （见 configVersionOf）。包内默认配置没有它、/v1/config 还没拉到、不是非空字符串、
   * 解析不了时为 UNKNOWN。
   */
  static configVersion(valueJson: string | null): string {
    if (valueJson === null) {
      return EventDiagnostics.UNKNOWN;
    }
    try {
      const v: Object = JSON.parse(valueJson) as Object;
      if (typeof v === 'string' && (v as string).length > 0) {
        return v as string;
      }
    } catch (e) {
      // 不是合法 JSON 文本：按取不到。
    }
    return EventDiagnostics.UNKNOWN;
  }

  /**
   * 生效配置（AppClientCore.shared.config；组合前为 null）里的 config_version，规则同 configVersion。只读当前生效的那一层
   * （sourceRaw：current → lkg → 包内里第一个存在的层，与安卓 effective() 同），不跨层回落：新拉的配置缺这个键或为 null 时记
   * unknown，不借上一份配置的版本（评审 S2-1）。
   */
  static configVersionOf(store: ConfigStore | null): string {
    return EventDiagnostics.configVersion(store === null ? null
      : store.layerValue(store.sourceRaw, EventDiagnostics.CONFIG_VERSION_KEY));
  }

  /**
   * sdui_card_error 的 schema_version（events.yaml：首页配置化卡片填卡片自带 version 转成的字符串；正是因为取不到版本而解码
   * 失败时填 UNKNOWN）。
   */
  static cardSchemaVersion(cardVersion: number | null): string {
    return cardVersion === null ? EventDiagnostics.UNKNOWN : String(cardVersion);
  }
}
