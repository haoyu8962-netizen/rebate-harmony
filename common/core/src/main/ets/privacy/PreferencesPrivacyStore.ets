import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { CouliPreferences } from '../config/PreferencesNamespaceCleaner';
import { PrivacyDecision, PrivacyStore } from './PrivacyGate';

/** 本机隐私决定的键（都在 CouliPreferences.PRIVACY_DECISION_NAMESPACE 里）。 */
export class PrivacyStoreKeys {
  static readonly DECISION: string = 'privacy.decision';
  static readonly CONSENTED_VERSION: string = 'privacy.consented_version';
  static readonly CONSENTED_AT: string = 'privacy.consented_at_millis';
  static readonly BASIC_MODE: string = 'privacy.basic_mode';
  static readonly WITHDRAWAL_CLEANUP_PENDING: string = 'privacy.withdrawal_cleanup_pending';
  /** 撤回意图（独立文件 CouliPreferences.PRIVACY_WITHDRAWAL_INTENT_NAMESPACE 里，两阶段写入的第一阶段）。 */
  static readonly WITHDRAWAL_INTENT: string = 'privacy.withdrawal_intent';
}

/**
 * Preferences 实现的本机隐私决定（BR-ID-11「基本模式状态保存在本地」、BR-ID-12「先本地记录」）。
 * 命名空间 couli_privacy_decision 不在 ALL_NAMESPACES 里、清理器主动跳过：切换环境不删，撤回同意改写为 basic_mode
 * 而不是删除（理由见 CouliPreferences.PRIVACY_DECISION_NAMESPACE）。
 * 闸门在首屏之前同步判定，所以用同步接口（getPreferencesSync / putSync API 11，flushSync API 14，均不高于 API 20）。
 * 读失败时按「从未决定」处理（重新提示，最保守）。
 */
export class PreferencesPrivacyStore implements PrivacyStore {
  decisionRaw: string = PrivacyDecision.NOT_DECIDED;
  consentedVersion: string | null = null;
  consentedAtMillis: number | null = null;
  basicMode: boolean = false;
  withdrawalCleanupPending: boolean = false;
  withdrawalIntent: boolean = false;
  private readonly prefs: preferences.Preferences | null;
  /** 撤回意图的独立文件（与决定记录分开 flush：任一个落盘成功都能挡住旧的 consented）。 */
  private readonly intentPrefs: preferences.Preferences | null;

  constructor(context: common.Context) {
    this.prefs = PreferencesPrivacyStore.open(context, CouliPreferences.PRIVACY_DECISION_NAMESPACE);
    this.intentPrefs = PreferencesPrivacyStore.open(context, CouliPreferences.PRIVACY_WITHDRAWAL_INTENT_NAMESPACE);
    this.load();
    this.loadIntent();
  }

  private static open(context: common.Context, name: string): preferences.Preferences | null {
    try {
      return preferences.getPreferencesSync(context, { name: name });
    } catch (e) {
      return null;
    }
  }

  /**
   * 撤回意图读不出（文件打不开、值不是布尔）时按「有撤回意图」：宁可按基本模式多清一次，
   * 也不在不确定时回到已同意、读凭据（fail-closed，R1-01）。键不存在是正常情况（从未撤回），按 false。
   */
  private loadIntent(): void {
    if (this.intentPrefs === null) {
      this.withdrawalIntent = true;
      return;
    }
    try {
      const intent: preferences.ValueType = this.intentPrefs.getSync(PrivacyStoreKeys.WITHDRAWAL_INTENT, false);
      this.withdrawalIntent = typeof intent === 'boolean' ? intent : true;
    } catch (e) {
      this.withdrawalIntent = true;
    }
  }

  private load(): void {
    if (this.prefs === null) {
      return;
    }
    try {
      const decision: preferences.ValueType = this.prefs.getSync(PrivacyStoreKeys.DECISION, '');
      const version: preferences.ValueType = this.prefs.getSync(PrivacyStoreKeys.CONSENTED_VERSION, '');
      const at: preferences.ValueType = this.prefs.getSync(PrivacyStoreKeys.CONSENTED_AT, -1);
      const basic: preferences.ValueType = this.prefs.getSync(PrivacyStoreKeys.BASIC_MODE, false);
      const cleanup: preferences.ValueType = this.prefs.getSync(PrivacyStoreKeys.WITHDRAWAL_CLEANUP_PENDING, false);
      this.decisionRaw = typeof decision === 'string' && decision.length > 0 ? decision : PrivacyDecision.NOT_DECIDED;
      this.consentedVersion = typeof version === 'string' && version.length > 0 ? version : null;
      this.consentedAtMillis = typeof at === 'number' && at >= 0 ? at : null;
      this.basicMode = typeof basic === 'boolean' ? basic : false;
      // 读不出布尔值时按「待清理」：宁可多清一次，也不在不确定时读凭据。
      this.withdrawalCleanupPending = typeof cleanup === 'boolean' ? cleanup : true;
    } catch (e) {
      // 记录损坏按未决（编排者 2026-10-06 三端统一）。
      this.decisionRaw = PrivacyDecision.NOT_DECIDED;
    }
  }

  /** 全部键一次 put 后只 flush 一次：撤回同意的「基本模式 + 清除同意记录 + 待清理」在同一次落盘里完成。 */
  persist(): void {
    if (this.prefs === null) {
      throw new Error('privacy preferences unavailable');
    }
    this.prefs.putSync(PrivacyStoreKeys.DECISION, this.decisionRaw);
    this.prefs.putSync(PrivacyStoreKeys.CONSENTED_VERSION, this.consentedVersion ?? '');
    this.prefs.putSync(PrivacyStoreKeys.CONSENTED_AT, this.consentedAtMillis ?? -1);
    this.prefs.putSync(PrivacyStoreKeys.BASIC_MODE, this.basicMode);
    this.prefs.putSync(PrivacyStoreKeys.WITHDRAWAL_CLEANUP_PENDING, this.withdrawalCleanupPending);
    this.prefs.flushSync();
  }

  /** 只写撤回意图（独立文件，put 后 flush）；失败抛出。 */
  persistWithdrawalIntent(): void {
    if (this.intentPrefs === null) {
      throw new Error('privacy withdrawal intent preferences unavailable');
    }
    this.intentPrefs.putSync(PrivacyStoreKeys.WITHDRAWAL_INTENT, this.withdrawalIntent);
    this.intentPrefs.flushSync();
  }
}
