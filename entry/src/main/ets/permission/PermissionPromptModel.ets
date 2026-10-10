import { PermissionRequester } from 'core';

/** 当前显示的权限弹窗。 */
export enum PermissionPromptKind {
  NONE = 'none',
  /** 用途说明（BR-TEXT-14 表 D 的用途键 + 【继续】）：点【继续】后才弹系统授权框。 */
  RATIONALE = 'rationale',
  /** 去设置引导（永久拒绝的 perm.<type>.denied_forever，或节流时的用途说明 + 【去设置】）。 */
  GUIDE = 'guide'
}

/**
 * 「暂不去设置」的关闭按钮文案键：契约字典没有通用的取消 / 关闭键，借用 external_page.close（关闭）。
 * TODO(N-10)：通用键补上后替换（同 F-ALL-01 借用通用键的做法）。
 */
export const GUIDE_DISMISS_KEY: string = 'external_page.close';

/**
 * 权限弹窗的界面状态（PermissionRequester 的 showRationale / showSettingsGuide 接到这里；RootPage 盖在最上层显示
 * PermissionPrompt）。只记文案键，文案由 PermissionPrompt 经字典取。同一时刻只有一个申请（PermissionRequester 排队）。
 */
@ObservedV2
export class PermissionPromptModel {
  private static instance: PermissionPromptModel | null = null;

  static get shared(): PermissionPromptModel {
    if (PermissionPromptModel.instance === null) {
      PermissionPromptModel.instance = new PermissionPromptModel();
    }
    return PermissionPromptModel.instance;
  }

  @Trace kind: PermissionPromptKind = PermissionPromptKind.NONE;
  @Trace titleKey: string = '';
  @Trace primaryKey: string = '';
  @Trace secondaryKey: string = '';
  /** 正在申请的权限类型（节流引导取它的用途键；去设置按它打开对应设置页）。 */
  currentPermission: string = '';
  /** 【去设置】：打开系统里本 App 的设置页（AppClientCore 接到 HarmonyPermissionSystem）。 */
  openSettings: () => void = () => {
  };
  private continueResolver: (() => void) | null = null;
  /** 显示状态写入后调用（AppHome 接到首页可见性广播：首页与预览弹窗复核，APP-11 R3-01）；缺省什么都不做。 */
  onOverlayChanged: () => void = () => {
  };

  get visible(): boolean {
    return this.kind !== PermissionPromptKind.NONE;
  }

  /** 用途说明：兑现 = 用户点了【继续】。 */
  showRationale(purposeKey: string, continueKey: string | null): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      this.continueResolver = resolve;
      this.titleKey = purposeKey;
      this.primaryKey = continueKey ?? PermissionRequester.CONTINUE;
      this.secondaryKey = '';
      this.kind = PermissionPromptKind.RATIONALE;
      this.onOverlayChanged();
    });
  }

  /** 去设置引导：永久拒绝时 messageKey 是 perm.<type>.denied_forever；节流时为 null，改显示该权限的用途说明。 */
  showSettingsGuide(messageKey: string | null, buttonKey: string): void {
    this.titleKey = messageKey ?? (PermissionRequester.purposeKey(this.currentPermission) ?? '');
    this.primaryKey = buttonKey;
    this.secondaryKey = GUIDE_DISMISS_KEY;
    this.kind = PermissionPromptKind.GUIDE;
    this.onOverlayChanged();
  }

  primary(): void {
    const kind: PermissionPromptKind = this.kind;
    this.kind = PermissionPromptKind.NONE;
    this.onOverlayChanged();
    if (kind === PermissionPromptKind.RATIONALE) {
      const resolve: (() => void) | null = this.continueResolver;
      this.continueResolver = null;
      if (resolve !== null) {
        resolve();
      }
    } else if (kind === PermissionPromptKind.GUIDE) {
      this.openSettings();
    }
  }

  secondary(): void {
    this.kind = PermissionPromptKind.NONE;
    this.onOverlayChanged();
  }
}
