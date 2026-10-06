import { LocalDataCleanerRegistry } from '../config/LocalDataCleaner';
import { UpdateState } from '../router/GuardState';
import { ApiClient, UpdatePort } from './ApiClient';
import { ErrorUpdateState } from './ErrorActionMapper';

/**
 * 强更模块 → 网络层的 UpdatePort（App 组合处用；harmony-review-r3 R3-04，lessons 35）。
 * state：App 内用户操作用的强更结论（AppUpdate.inAppUpdate / UpdateCheckCoordinator.inAppUpdate）：
 * ok、below_recommended → supported；below_min → below；unknown → unknown。
 * on10405：确需强更的 10405（及强更未知时拿到 deletion_only 按「低于」处理）交给强更模块（AppUpdate.on10405）。
 */
export class UpdateNetworkPort implements UpdatePort {
  private readonly current: () => UpdateState;
  private readonly forceUpdate: (minSupported: string | null) => void;

  constructor(current: () => UpdateState, forceUpdate: (minSupported: string | null) => void) {
    this.current = current;
    this.forceUpdate = forceUpdate;
  }

  state(): string {
    return UpdateNetworkPort.map(this.current());
  }

  on10405(minSupported: string | null): void {
    this.forceUpdate(minSupported);
  }

  static map(state: UpdateState): string {
    switch (state) {
      case UpdateState.OK:
      case UpdateState.BELOW_RECOMMENDED:
        return ErrorUpdateState.SUPPORTED;
      case UpdateState.BELOW_MIN:
        return ErrorUpdateState.BELOW;
      default:
        return ErrorUpdateState.UNKNOWN;
    }
  }
}

/**
 * 网络核心在 App 组合处的接线（EntryAbility 调用；Android 在 AppModule 里做同样的事）。
 * - ApiClient.invalidate 登记为清理注册表的「清理前第一步」：撤回同意（cleanOnly）与切换环境 / 覆盖安装对账
 *   （cleanAll）开始时最先执行，作废并取消在途请求、重试与刷新结果，然后才删令牌与设备身份（lessons 35）。
 * - 返回强更状态变更的处理函数：App 把它设为 AppUpdate.onChanged。每次强更结论变化先通知网络层
 *   （ApiClient.onUpdateStateChanged：由低于 / 未知恢复为不低于且本机会话是 deletion_only 时立即发起受限会话刷新屏障，
 *   R3-04、R2-02），再交给 next（AppRouting.stateChanged）。网络层通知出错不影响路由协调。
 */
export class NetworkComposition {
  static readonly INVALIDATE_STEP: string = 'network_in_flight';

  static install(client: ApiClient, cleaners: LocalDataCleanerRegistry, next: () => void): () => void {
    cleaners.setBeforeClear(NetworkComposition.INVALIDATE_STEP, (): void => client.invalidate());
    return (): void => {
      try {
        client.onUpdateStateChanged();
      } catch (e) {
        // 网络层不得抛出；万一抛出，路由照常协调。
      }
      next();
    };
  }
}
