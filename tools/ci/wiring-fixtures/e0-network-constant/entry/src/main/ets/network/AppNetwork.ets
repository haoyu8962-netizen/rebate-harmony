// 接线检查样例（满足 E0）。
export class AppNetwork {
  static sessionIdentity(): SessionIdentity {
    const client: ApiClient | null = AppNetwork.instance;
    return new SessionIdentity(false, null, null);
  }
}
