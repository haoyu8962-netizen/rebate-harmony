// 生成物，禁止手改；来源 contract.lock（tools/codegen/gen.py 生成）

// 桥方法与桥错误码：contracts/bridge.schema.json。缺省：timeoutMs null、gestureRequired false、sinceHarmony null。

export class BridgeMethodSpec {
  readonly name: string;
  readonly level: string;
  readonly timeoutMs: number | null;
  readonly sinceHarmony: string | null;
  readonly gestureRequired: boolean;

  constructor(name: string, level: string, timeoutMs: number | null, sinceHarmony: string | null,
    gestureRequired: boolean) {
    this.name = name;
    this.level = level;
    this.timeoutMs = timeoutMs;
    this.sinceHarmony = sinceHarmony;
    this.gestureRequired = gestureRequired;
  }
}

export class BridgeMethods {
  static readonly all: Map<string, BridgeMethodSpec> = BridgeMethods.build();

  static spec(name: string): BridgeMethodSpec | undefined {
    return BridgeMethods.all.get(name);
  }

  private static build(): Map<string, BridgeMethodSpec> {
    const all: Map<string, BridgeMethodSpec> = new Map<string, BridgeMethodSpec>();
    all.set('app.getEnv', new BridgeMethodSpec('app.getEnv', 'L0', null, '1.0.0', false));
    all.set('app.getConfig', new BridgeMethodSpec('app.getConfig', 'L0', null, '1.0.0', false));
    all.set('auth.getUser', new BridgeMethodSpec('auth.getUser', 'L1', 10000, '1.0.0', false));
    all.set('auth.login', new BridgeMethodSpec('auth.login', 'L0', null, '1.0.0', false));
    all.set('auth.getH5Token', new BridgeMethodSpec('auth.getH5Token', 'L1', 10000, '1.0.0', false));
    all.set('net.signedRequest', new BridgeMethodSpec('net.signedRequest', 'L2', 15000, '1.0.0', false));
    all.set('ui.toast', new BridgeMethodSpec('ui.toast', 'L0', null, '1.0.0', false));
    all.set('ui.showLoading', new BridgeMethodSpec('ui.showLoading', 'L0', null, '1.0.0', false));
    all.set('ui.hideLoading', new BridgeMethodSpec('ui.hideLoading', 'L0', null, '1.0.0', false));
    all.set('ui.setNavBar', new BridgeMethodSpec('ui.setNavBar', 'L0', null, '1.0.0', false));
    all.set('nav.open', new BridgeMethodSpec('nav.open', 'L0', 10000, '1.0.0', false));
    all.set('nav.close', new BridgeMethodSpec('nav.close', 'L0', null, '1.0.0', false));
    all.set('trade.openProduct', new BridgeMethodSpec('trade.openProduct', 'L0', 10000, '1.0.0', false));
    all.set('trade.convertAndOpen', new BridgeMethodSpec('trade.convertAndOpen', 'L2', null, '1.0.0', false));
    all.set('trade.authorize', new BridgeMethodSpec('trade.authorize', 'L2', null, '1.0.0', false));
    all.set('trade.openUnionActivity', new BridgeMethodSpec('trade.openUnionActivity', 'L2', null, null, false));
    all.set('share.open', new BridgeMethodSpec('share.open', 'L1', null, '1.0.0', false));
    all.set('media.saveImage', new BridgeMethodSpec('media.saveImage', 'L1', null, '1.0.0', false));
    all.set('media.previewImage', new BridgeMethodSpec('media.previewImage', 'L0', null, '1.0.0', false));
    all.set('clipboard.write', new BridgeMethodSpec('clipboard.write', 'L0', null, '1.0.0', true));
    all.set('clipboard.read', new BridgeMethodSpec('clipboard.read', 'L2', 5000, null, false));
    all.set('clipboard.setAutoDetect', new BridgeMethodSpec('clipboard.setAutoDetect', 'L0', null, '1.0.0', false));
    all.set('ext.openApp', new BridgeMethodSpec('ext.openApp', 'L1', 10000, '1.0.0', false));
    all.set('ext.openBrowser', new BridgeMethodSpec('ext.openBrowser', 'L0', null, '1.0.0', false));
    all.set('ext.openMiniProgram', new BridgeMethodSpec('ext.openMiniProgram', 'L1', 10000, null, false));
    all.set('cs.open', new BridgeMethodSpec('cs.open', 'L0', 10000, '1.0.0', false));
    all.set('perm.getPushStatus', new BridgeMethodSpec('perm.getPushStatus', 'L0', 5000, '1.0.0', false));
    all.set('perm.request', new BridgeMethodSpec('perm.request', 'L1', null, '1.0.0', false));
    all.set('track.event', new BridgeMethodSpec('track.event', 'L0', null, '1.0.0', false));
    all.set('media.scan', new BridgeMethodSpec('media.scan', 'L1', null, null, false));
    all.set('media.uploadImage', new BridgeMethodSpec('media.uploadImage', 'L1', null, null, false));
    return all;
  }
}

export class BridgeErrors {
  static readonly all: Map<number, string> = BridgeErrors.build();

  private static build(): Map<number, string> {
    const all: Map<number, string> = new Map<number, string>();
    all.set(90001, 'Method does not exist or is not supported');
    all.set(90002, 'Invalid params');
    all.set(90003, 'Timeout');
    all.set(90004, 'Cancelled by the user');
    all.set(90401, 'Not logged in');
    all.set(90403, 'Origin or frame not allowed, method + path outside signed_paths, or the method\'s own whitelist rejection (methods with whitelist_90403: ext.openApp trade_only targets, ext.openBrowser addresses matching link_patterns, share.open links outside the allowed range; 03 §5.3)');
    all.set(90404, 'User gesture missing');
    all.set(90500, 'Native internal error; also for calls not executed under the force-update guard (03 §4.4)');
    return all;
  }
}
