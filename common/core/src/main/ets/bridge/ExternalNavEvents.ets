import {
  ClientEvent, ClientEvents, EventExternalPageBlockedNavFrame, EventExternalPageBlockedNavKind,
  EventExternalPageNavHostFrame, EventExternalPageUnionHostCategory, EventExternalPageUnionHostFrame,
  EventExternalPageUnionHostOutcome, EventExternalPageUnionHostUnionPlatform
} from 'generated';
import { ExternalNavDecision } from './ExternalNavPolicy';
import { ExternalNavFrame, ExternalUnionOutcome } from './ExternalPageNavigator';
import { LinkRule } from './LinkRules';

/**
 * ExternalNavHooks 的埋点出口 → events.yaml 的生成事件（03 §4.7；BR-ATTR-29；APP-04 R1-12、R2-08）。Core、纯函数：App 组合处
 * 只负责把返回的事件交给 Tracker。框架类型四种取值（initial / main / subframe / new_window）逐一映射，新窗口请求不会被记成主框架。
 * 只带平台、类别、注册域、框架类型与处理结果，不带路径、参数与完整 URL。
 */
export class ExternalNavEvents {
  /** external_page_union_host；规则不认识的平台、类别不记（返回 null）。 */
  static unionHost(page: string, decision: ExternalNavDecision, frame: string, outcome: string): ClientEvent | null {
    const rule: LinkRule | null = decision.rule;
    if (rule === null) {
      return null;
    }
    const platform: EventExternalPageUnionHostUnionPlatform | null = ExternalNavEvents.platformOf(rule.platform);
    const category: EventExternalPageUnionHostCategory | null = ExternalNavEvents.categoryOf(rule.category);
    if (platform === null || category === null) {
      return null;
    }
    return ClientEvents.externalPageUnionHost(page, platform, category, ExternalNavEvents.unionFrame(frame),
      ExternalNavEvents.unionOutcome(outcome));
  }

  /** external_page_nav_host。 */
  static navHost(page: string, registeredDomain: string, frame: string, hit: boolean): ClientEvent {
    return ClientEvents.externalPageNavHost(page, registeredDomain, ExternalNavEvents.navHostFrame(frame), hit);
  }

  /** external_page_blocked_nav。 */
  static blockedNav(page: string, kind: string, frame: string): ClientEvent {
    return ClientEvents.externalPageBlockedNav(page, ExternalNavEvents.blockedKind(kind),
      ExternalNavEvents.blockedFrame(frame));
  }

  static navHostFrame(raw: string): EventExternalPageNavHostFrame {
    switch (raw) {
      case ExternalNavFrame.INITIAL:
        return EventExternalPageNavHostFrame.INITIAL;
      case ExternalNavFrame.SUBFRAME:
        return EventExternalPageNavHostFrame.SUBFRAME;
      case ExternalNavFrame.NEW_WINDOW:
        return EventExternalPageNavHostFrame.NEW_WINDOW;
      default:
        return EventExternalPageNavHostFrame.MAIN;
    }
  }

  static unionFrame(raw: string): EventExternalPageUnionHostFrame {
    switch (raw) {
      case ExternalNavFrame.INITIAL:
        return EventExternalPageUnionHostFrame.INITIAL;
      case ExternalNavFrame.SUBFRAME:
        return EventExternalPageUnionHostFrame.SUBFRAME;
      case ExternalNavFrame.NEW_WINDOW:
        return EventExternalPageUnionHostFrame.NEW_WINDOW;
      default:
        return EventExternalPageUnionHostFrame.MAIN;
    }
  }

  static blockedFrame(raw: string): EventExternalPageBlockedNavFrame {
    switch (raw) {
      case ExternalNavFrame.INITIAL:
        return EventExternalPageBlockedNavFrame.INITIAL;
      case ExternalNavFrame.SUBFRAME:
        return EventExternalPageBlockedNavFrame.SUBFRAME;
      case ExternalNavFrame.NEW_WINDOW:
        return EventExternalPageBlockedNavFrame.NEW_WINDOW;
      default:
        return EventExternalPageBlockedNavFrame.MAIN;
    }
  }

  private static unionOutcome(raw: string): EventExternalPageUnionHostOutcome {
    switch (raw) {
      case ExternalUnionOutcome.PARSE_OK:
        return EventExternalPageUnionHostOutcome.PARSE_OK;
      case ExternalUnionOutcome.PARSE_FAILED:
        return EventExternalPageUnionHostOutcome.PARSE_FAILED;
      default:
        return EventExternalPageUnionHostOutcome.BLOCK;
    }
  }

  private static platformOf(raw: string): EventExternalPageUnionHostUnionPlatform | null {
    switch (raw) {
      case 'taobao':
        return EventExternalPageUnionHostUnionPlatform.TAOBAO;
      case 'jd':
        return EventExternalPageUnionHostUnionPlatform.JD;
      case 'pdd':
        return EventExternalPageUnionHostUnionPlatform.PDD;
      case 'meituan':
        return EventExternalPageUnionHostUnionPlatform.MEITUAN;
      case 'vip':
        return EventExternalPageUnionHostUnionPlatform.VIP;
      case 'douyin':
        return EventExternalPageUnionHostUnionPlatform.DOUYIN;
      case 'eleme':
        return EventExternalPageUnionHostUnionPlatform.ELEME;
      case 'kuaishou':
        return EventExternalPageUnionHostUnionPlatform.KUAISHOU;
      case 'suning':
        return EventExternalPageUnionHostUnionPlatform.SUNING;
      default:
        return null;
    }
  }

  private static categoryOf(raw: string): EventExternalPageUnionHostCategory | null {
    switch (raw) {
      case 'product':
        return EventExternalPageUnionHostCategory.PRODUCT;
      case 'promo':
        return EventExternalPageUnionHostCategory.PROMO;
      case 'union_host':
        return EventExternalPageUnionHostCategory.UNION_HOST;
      default:
        return null;
    }
  }

  private static blockedKind(raw: string): EventExternalPageBlockedNavKind {
    switch (raw) {
      case 'http':
        return EventExternalPageBlockedNavKind.HTTP;
      case 'intent':
        return EventExternalPageBlockedNavKind.INTENT;
      case 'market':
        return EventExternalPageBlockedNavKind.MARKET;
      case 'tel':
        return EventExternalPageBlockedNavKind.TEL;
      case 'sms':
        return EventExternalPageBlockedNavKind.SMS;
      case 'mailto':
        return EventExternalPageBlockedNavKind.MAILTO;
      case 'download':
        return EventExternalPageBlockedNavKind.DOWNLOAD;
      case 'app_scheme':
        return EventExternalPageBlockedNavKind.APP_SCHEME;
      default:
        return EventExternalPageBlockedNavKind.OTHER_SCHEME;
    }
  }
}
