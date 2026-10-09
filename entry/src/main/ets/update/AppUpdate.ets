import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  PreferencesUpdateStore, PrivacyState, StoreChoice, UpdateCheckCoordinator, UpdateCheckOutcome, UpdateChecker,
  UpdateCheckResult, UpdateCheckStatus, UpdateGate, UpdateGateState, UpdateRouting, UpdateState, UpdateStatusRaw, UpdateStore
} from 'core';
import { HARMONY_CHANNEL, HARMONY_PLATFORM, HarmonyStoreAccess, StoreAccess } from './HarmonyStoreAccess';

const DOMAIN: number = 0x0000;
const TAG: string = 'CouliUpdate';

/**
 * App 的强更检查接线（APP-02c；03 §4.1、§4.4）：UpdateGate 的结论 → Router 的 update 状态源（AppRouting.readiness 读
 * routerStatus()）与界面（强更页、可关闭提示观察这里的 @Trace 字段）。
 *
 * - 检查时机与 Router 状态源在 Core 的 UpdateCheckCoordinator（有单测）：只在环境 SETTLED 且已同意当前隐私政策时发
 *   检查（同意前只允许请求协议文本与配置，BR-ID-11；基本模式不发、保留已知强更，其余按 unknown，03 §4.4）；冷启动与每次
 *   离开基本模式（重新同意）都立即检查（R1-03），且在恢复待办之前发出（AppPrivacy.publish 先调 syncPrivacy，R1-01）；
 *   回前台按间隔复查，复查在途时 Router 拿到 checking（R1-02）。
 * - 检查失败不拦用户自己的操作（Gate 保持上次已知结论或 unknown）。
 * - on10405 给网络层（APP-03）调用：直接进 below_min。
 * - 【去更新】按 Gate 选店，逐家打开，打开失败接着下一家；都不行 → 强更页显示 unavailable 与【重试】；【重试】重新检查再选。
 * - 检查开始、结束与结论变化时调 onChanged（EntryAbility 接 AppRouting.stateChanged：启动协调、below_min 进强更页、删待办）。
 * 单线程（UI 线程）使用。
 */
@ObservedV2
export class AppUpdate {
  private static instance: AppUpdate | null = null;

  /** 惰性创建（@ObservedV2 类的静态实例须在第一次取用时创建才可观察，见 AppPrivacy.shared）。 */
  static get shared(): AppUpdate {
    if (AppUpdate.instance === null) {
      AppUpdate.instance = new AppUpdate();
    }
    return AppUpdate.instance;
  }

  /** Gate 的当前结论（UpdateStatusRaw）。 */
  @Trace statusRaw: string = UpdateStatusRaw.UNKNOWN;
  /** 该弹可关闭更新提示。 */
  @Trace showPrompt: boolean = false;
  /** below_min：最低支持版本；below_recommended：提示时的 latest_version。 */
  @Trace targetVersion: string | null = null;
  /** 最近一次成功检查的结果（标题、更新内容；选店用它的商店列表）。 */
  @Trace result: UpdateCheckResult | null = null;
  /** 强更页【去更新】没有可去的商店：显示 app_update.unavailable 与【重试】，不给任何下载地址。 */
  @Trace forceUnavailable: boolean = false;
  /** 可关闭提示【去更新】时来源商店打不开（BR-ID-01：可选更新不改去别家）。 */
  @Trace promptUnavailable: boolean = false;
  /** 正在重试检查（按钮防连点）。 */
  @Trace working: boolean = false;

  /** 环境闸门 SETTLED（EntryAbility 接上）。 */
  environmentSettled: () => boolean = () => false;
  /** 隐私闸门当前结论（EntryAbility 接上 AppRouting.privacyState）。 */
  privacy: () => PrivacyState = () => PrivacyState.NOT_DECIDED;
  /** 结论或检查进度变化（EntryAbility 接上 AppRouting.stateChanged）。 */
  onChanged: () => void = () => {
  };

  private gate: UpdateGate | null = null;
  private store: UpdateStore | null = null;
  private coordinator: UpdateCheckCoordinator | null = null;
  private access: StoreAccess = new HarmonyStoreAccess();

  /**
   * EntryAbility.onCreate 调一次。namespace / checker 由构建变体给（Release：couli_update + 永远失败的占位检查器；
   * Debug / Staging：couli_update_debug + 调试假数据检查器，见 BuildVariant）。同一进程里 Ability 重建时沿用已有的 Gate。
   */
  start(context: common.Context, appVersion: string, checker: UpdateChecker, namespace: string,
    access: StoreAccess = new HarmonyStoreAccess()): void {
    if (this.gate !== null) {
      return;
    }
    this.access = access;
    this.store = new PreferencesUpdateStore(context, namespace);
    const gate: UpdateGate = new UpdateGate(this.store, (): number => Date.now(), appVersion, HARMONY_PLATFORM,
      HARMONY_CHANNEL, access.installSource());
    const coordinator: UpdateCheckCoordinator = new UpdateCheckCoordinator(gate, checker, (): number => Date.now());
    coordinator.environmentSettled = (): boolean => this.environmentSettled();
    coordinator.privacy = (): PrivacyState => this.privacy();
    coordinator.changed = (notify: boolean): void => this.refresh(notify);
    coordinator.finished = (outcome: UpdateCheckOutcome, thenPickStore: boolean): void => {
      this.finished(outcome, thenPickStore);
    };
    this.gate = gate;
    this.coordinator = coordinator;
    this.refresh(false);
  }

  get belowMin(): boolean {
    return this.statusRaw === UpdateStatusRaw.BELOW_MIN;
  }

  /**
   * Router 的放行条件源（LaunchReadiness.update）：有检查在途时除已知 below_min 外一律为 checking（R1-02，
   * 回前台复查也一样），外部入口与待办恢复 defer update_checking、最多等 5 秒。
   */
  routerStatus(): UpdateCheckStatus {
    const coordinator: UpdateCheckCoordinator | null = this.coordinator;
    if (coordinator === null) {
      return UpdateRouting.status(new UpdateGateState(UpdateStatusRaw.UNKNOWN, false, null), 0);
    }
    return coordinator.routerStatus();
  }

  /** 埋点上报的强更前提（R3-01）：按 routerStatus，检查中、未知（含复查失败）为 false；还没接上协调器为 false。 */
  uploadReady(): boolean {
    const coordinator: UpdateCheckCoordinator | null = this.coordinator;
    return coordinator !== null && coordinator.uploadReady();
  }

  /** App 内用户自己的操作用的强更结论（不等待）：检查中保留本进程已知结论，没有结论为 unknown。 */
  inAppUpdate(): UpdateState {
    const coordinator: UpdateCheckCoordinator | null = this.coordinator;
    return coordinator === null ? UpdateState.UNKNOWN : coordinator.inAppUpdate();
  }

  /**
   * 隐私结论或环境闸门可能变化后调用（AppRouting.stateChanged 开头、AppPrivacy.publish 写入隐私结论后且在
   * consentHandled 之前，R1-01）：基本模式按 unknown（保留已知 below_min）；冷启动或离开基本模式（重新同意）后
   * 能查了就立即发检查（R1-03）。notify=false：调用方随后自己协调启动。
   */
  syncPrivacy(notify: boolean = false): void {
    const coordinator: UpdateCheckCoordinator | null = this.coordinator;
    if (coordinator !== null) {
      coordinator.syncPrivacy(notify);
    }
  }

  /** 回前台（EntryAbility.onForeground）：欠着的立即检查先补；否则距上次成功检查超过间隔才查。 */
  onForeground(): void {
    const coordinator: UpdateCheckCoordinator | null = this.coordinator;
    if (coordinator !== null) {
      coordinator.onForeground();
    }
  }

  /**
   * 立即重新检查（强更页【重试】、调试面板切换假数据）。thenPickStore：检查后仍需强更就再选一次店。
   * 不能发检查时（基本模式保留已知强更）按已知结果再选一次店；已有检查在途时等它的结果（不重复发、不连点重试）。
   */
  recheck(thenPickStore: boolean = false): void {
    const coordinator: UpdateCheckCoordinator | null = this.coordinator;
    if (coordinator === null || coordinator.isRunning) {
      return;
    }
    this.working = thenPickStore;
    if (!coordinator.recheck(thenPickStore)) {
      this.working = false;
      if (thenPickStore) {
        this.goToStore();
      }
    }
  }

  /** 接口层收到 10405（APP-03 网络层调用，只送确需强更的，rule-gaps G07）。 */
  on10405(minSupported: string | null): void {
    const gate: UpdateGate | null = this.gate;
    if (gate === null) {
      return;
    }
    gate.on10405(minSupported, Date.now());
    this.refresh(true);
  }

  /**
   * 服务端已判定强更（APP-07：parse 外层成功、结果行 error_code=10405；共性第 21 条）：强制进 ForceUpdate，
   * 不按缓存的最低版本比较（UpdateGate.onServerForced）。
   */
  onServerForced(): void {
    const gate: UpdateGate | null = this.gate;
    if (gate === null) {
      return;
    }
    gate.onServerForced(Date.now());
    this.refresh(true);
  }

  /** 可关闭提示【暂不更新】：按提示时的目标版本（latest_version）记录。 */
  dismissPrompt(): void {
    const gate: UpdateGate | null = this.gate;
    if (gate === null) {
      return;
    }
    gate.dismissPrompt(Date.now());
    this.promptUnavailable = false;
    this.refresh(true);
  }

  /** 【去更新】：选店并打开；没有可去的商店时置 unavailable（强更页显示提示与【重试】，可关闭提示追加说明）。 */
  goToStore(): void {
    const gate: UpdateGate | null = this.gate;
    const store: UpdateStore | null = this.store;
    if (gate === null || store === null) {
      return;
    }
    const result: UpdateCheckResult | null = store.load().result;
    const status: string = gate.state(Date.now()).statusRaw;
    const opened: boolean = result !== null && this.openFirstStore(gate, result);
    this.forceUnavailable = status === UpdateStatusRaw.BELOW_MIN && !opened;
    this.promptUnavailable = status === UpdateStatusRaw.BELOW_RECOMMENDED && !opened;
  }

  /** 按 Gate 的顺序逐家试；能力检查通过但真正打开失败的，排除后再选下一家（rule-gaps G08）。 */
  private openFirstStore(gate: UpdateGate, result: UpdateCheckResult): boolean {
    const failed: string[] = [];
    for (let i: number = 0; i <= result.stores.length + 2; i++) {
      const choice: StoreChoice = gate.pickStore(result, Date.now(),
        (key: string): boolean => failed.indexOf(key) < 0 && this.access.canOpen(key));
      const key: string | null = choice.storeKey;
      if (key === null) {
        return false;
      }
      if (this.access.open(key)) {
        return true;
      }
      failed.push(key);
    }
    return false;
  }

  private finished(outcome: UpdateCheckOutcome, thenPickStore: boolean): void {
    const gate: UpdateGate | null = this.gate;
    if (gate === null) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'update check %{public}s → %{public}s', outcome.result !== null ? 'ok' : 'failed',
      gate.state(Date.now()).statusRaw);
    this.working = false;
    this.forceUnavailable = false;
    this.promptUnavailable = false;
    this.refresh(false);
    if (thenPickStore && this.belowMin) {
      this.goToStore();
    }
  }

  /** 从 Gate 刷新界面字段；notify 时回调 onChanged（检查开始、结束即使结论没变也要重新协调启动，R1-02）。 */
  private refresh(notify: boolean): void {
    const gate: UpdateGate | null = this.gate;
    const store: UpdateStore | null = this.store;
    if (gate === null || store === null) {
      return;
    }
    const state: UpdateGateState = gate.state(Date.now());
    this.statusRaw = state.statusRaw;
    this.showPrompt = state.showPrompt;
    this.targetVersion = state.targetVersion;
    this.result = store.load().result;
    if (notify) {
      this.onChanged();
    }
  }
}
