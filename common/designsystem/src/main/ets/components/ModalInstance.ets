// 异步打开的系统模态（openCustomDialog）的实例管理（APP-10 harmony-review-r2 R2-05，跨端共性第 20 条）。不依赖 ArkUI，单测用替身。
// openCustomDialog 是异步的：打开完成之前调 closeCustomDialog 会因内容尚未打开而失败（103303），打开随后照样成功。所以：
// - 每个实例各有独立的取消标记（cancel 只标记这一个实例，不清别人的引用）；
// - 打开完成时，若这一实例已取消、已被替换（不再是承载方的当前实例）或已失效（stillValid=false），直接关闭这次捕获的 content——
//   不依赖它仍是当前实例，也不会误关替代它的新实例；
// - 已取消的实例之后的按钮、系统返回回调都不再执行业务（live=false）。

/** 一个实例的承载出口（界面层用捕获的 ComponentContent 实现；close 只关这一个实例，未打开时可能失败，不得抛出）。 */
export interface CouliModalPresenter {
  /** 打开这一个实例：打开完成 resolve，打开失败 reject。 */
  open(): Promise<void>;

  /** 关闭这一个实例（只关它）。 */
  close(): void;
}

/** 用两个函数给出的承载出口（界面层把捕获的 content 的 openCustomDialog / closeCustomDialog 包进来）。 */
export class CouliModalFns implements CouliModalPresenter {
  private readonly opener: () => Promise<void>;
  private readonly closer: () => void;

  constructor(opener: () => Promise<void>, closer: () => void) {
    this.opener = opener;
    this.closer = closer;
  }

  open(): Promise<void> {
    return this.opener();
  }

  close(): void {
    this.closer();
  }
}

export class CouliModalInstance {
  /** 承载方分配的编号（如弹窗票据序号；只用于比较与诊断）。 */
  readonly key: number;
  private readonly presenter: CouliModalPresenter;
  private cancelled: boolean = false;
  private opened: boolean = false;
  /** 已消失或打开失败（之后什么都不做）。 */
  private finished: boolean = false;

  constructor(key: number, presenter: CouliModalPresenter) {
    this.key = key;
    this.presenter = presenter;
  }

  /** 仍应显示且回调仍可执行：没取消、没消失。 */
  get live(): boolean {
    return !this.cancelled && !this.finished;
  }

  get isOpened(): boolean {
    return this.opened && !this.finished;
  }

  /**
   * 打开；打开完成时再核对一次 stillValid（承载方在这里比较「仍是当前实例」与票据、可见性、阻挡层），不满足或期间已取消 → 关闭这次捕获的
   * content。返回打开过程（失败不抛）。
   */
  start(stillValid: () => boolean): Promise<void> {
    let opening: Promise<void>;
    try {
      opening = this.presenter.open();
    } catch (e) {
      opening = Promise.reject(new Error('open failed'));
    }
    return opening.then((): void => {
      this.opened = true;
      if (this.finished) {
        return;
      }
      let valid: boolean = false;
      try {
        valid = !this.cancelled && stillValid();
      } catch (e) {
        valid = false;
      }
      if (!valid) {
        this.cancelled = true;
        this.safeClose();
      }
    }).catch((): void => {
      this.finished = true;
    });
  }

  /**
   * 由承载方关闭（页面作废、票据换了、不可见、有阻挡层）：只标记并关闭这一个实例。打开完成前调用时 close 可能失败（103303），
   * 打开完成后 start 里会按取消标记再关一次。
   */
  cancel(): void {
    if (this.cancelled || this.finished) {
      return;
    }
    this.cancelled = true;
    this.safeClose();
  }

  /** 系统通知这一实例已消失（onDidDisappear）。 */
  disappeared(): void {
    this.finished = true;
  }

  private safeClose(): void {
    try {
      this.presenter.close();
    } catch (e) {
      // 已关闭、尚未打开（103303）时忽略；打开完成后 start 会按取消标记再关。
    }
  }
}

/** 一个槽位同一时刻只有一个当前实例（同意弹窗等）：换实例时只取消旧实例，旧实例迟到的打开完成由它自己关掉，不碰新实例。 */
export class CouliModalSlot {
  private current: CouliModalInstance | null = null;

  /** 当前仍有效的实例编号（没有为 0）。 */
  get openKey(): number {
    const c: CouliModalInstance | null = this.current;
    return c === null || !c.live ? 0 : c.key;
  }

  get instance(): CouliModalInstance | null {
    return this.current;
  }

  /** 关掉旧实例（只它），打开新实例；打开完成时核对「仍是当前实例」与 stillValid。 */
  show(key: number, presenter: CouliModalPresenter, stillValid: () => boolean): CouliModalInstance {
    this.close();
    const inst: CouliModalInstance = new CouliModalInstance(key, presenter);
    this.current = inst;
    inst.start((): boolean => this.current === inst && stillValid()).then((): void => {
      if (!inst.live && this.current === inst) {
        this.current = null;
      }
    });
    return inst;
  }

  /** 关掉当前实例（不提交）。 */
  close(): void {
    const c: CouliModalInstance | null = this.current;
    this.current = null;
    if (c !== null) {
      c.cancel();
    }
  }

  /** 这一实例已消失或被系统关闭：是当前实例才清引用。 */
  release(inst: CouliModalInstance): void {
    if (this.current === inst) {
      this.current = null;
    }
  }
}
