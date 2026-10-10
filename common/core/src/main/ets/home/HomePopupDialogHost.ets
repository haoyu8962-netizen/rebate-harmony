// APP-11 首页弹窗的系统模态实例管理（鸿蒙第 2 轮评审 R2-02 / R2-03，跨端共性第 17、18 条）。首页与 HomePreview 同一套（HomeTabRoot）。
// - 每个对话框实例在打开时绑定它自己的弹窗票据（HomePopupTicket）；系统关闭回调（返回键、点遮罩，onWillDismiss）只提交这张票据、
//   只收起这一个实例，不经出口去取「当前控制器」，旧实例的迟到回调关不掉后来控制器的弹窗。
// - 打开是异步的：打开失败只清掉自己（当前句柄仍是它才清）；打开完成前就被要求关闭的，打开完成后立即关闭，不留孤儿弹窗。
// - 真正打开模态之前再复核一次（beforeOpen：票据仍是此刻显示的那一个、页面可见、没有其他弹层），不满足就不打开（R2-03）。
// 本文件不依赖 ArkUI：界面层实现 HomePopupPresenter（openCustomDialog / closeCustomDialog），单测用替身。
import { HomePopupTicket } from './HomeTickets';

/** 系统模态的承载（界面层实现）。 */
export interface HomePopupPresenter {
  /**
   * 打开一个对话框实例（instance 由宿主分配，唯一）。打开成功 resolve，失败 reject。
   * onWillDismiss：这个实例收到系统关闭请求（返回键、点遮罩）时调用；调用之后承载方自行收起这一个实例。
   */
  present(instance: number, ticket: HomePopupTicket, onWillDismiss: () => void): Promise<void>;

  /** 关闭这个已打开的实例（只关它）。不得抛出。 */
  dismiss(instance: number): void;
}

class DialogHandle {
  readonly id: number;
  readonly ticket: HomePopupTicket;
  opened: boolean = false;
  closing: boolean = false;

  constructor(id: number, ticket: HomePopupTicket) {
    this.id = id;
    this.ticket = ticket;
  }
}

export class HomePopupDialogHost {
  private readonly presenter: HomePopupPresenter;
  private readonly closePopup: (t: HomePopupTicket) => void;
  private readonly beforeOpen: (t: HomePopupTicket) => boolean;
  private serial: number = 0;
  private current: DialogHandle | null = null;
  private disposed: boolean = false;

  /**
   * closePopup：系统关闭请求时提交本实例的票据（执行层按票据比较，只关对应的那一个弹窗）。
   * beforeOpen：真正打开前的复核（false 不打开；执行层自行把弹窗退回等待或按已关闭处理）。
   */
  constructor(presenter: HomePopupPresenter, closePopup: (t: HomePopupTicket) => void,
    beforeOpen: (t: HomePopupTicket) => boolean) {
    this.presenter = presenter;
    this.closePopup = closePopup;
    this.beforeOpen = beforeOpen;
  }

  /** 当前（已请求打开、未关闭）的实例绑定的票据键；没有为空串。 */
  get currentKey(): string {
    return this.current === null ? '' : this.current.ticket.key;
  }

  /** 按快照里的弹窗票据开 / 关：票据变了先关旧实例，再（复核通过后）开新实例；null 关掉当前实例。 */
  sync(t: HomePopupTicket | null): void {
    if (this.disposed) {
      return;
    }
    if (t === null) {
      this.closeCurrent();
      return;
    }
    const cur: DialogHandle | null = this.current;
    if (cur !== null && cur.ticket.key === t.key) {
      return;
    }
    this.closeCurrent();
    let allowed: boolean = false;
    try {
      allowed = this.beforeOpen(t);
    } catch (e) {
      allowed = false;
    }
    // 复核可能让执行层发布新快照（重入 sync）：此时以重入后的状态为准。
    if (!allowed || this.disposed || this.current !== null) {
      return;
    }
    this.serial++;
    const h: DialogHandle = new DialogHandle(this.serial, t);
    this.current = h;
    let opening: Promise<void>;
    try {
      opening = this.presenter.present(h.id, t, (): void => this.willDismiss(h));
    } catch (e) {
      opening = Promise.reject(new Error('present failed'));
    }
    opening.then((): void => {
      h.opened = true;
      if (h.closing) {
        // 打开完成前已被要求关闭（票据换了、页面离开）：现在关掉，不留孤儿弹窗。
        this.presenter.dismiss(h.id);
      }
    }).catch((): void => {
      // 打开失败：只清掉自己（当前句柄已是后来的实例时不动它）。
      h.closing = true;
      if (this.current === h) {
        this.current = null;
      }
    });
  }

  /** 系统关闭请求（返回键、点遮罩）：只提交本实例的票据、只收起本实例（承载方自己收起）。 */
  private willDismiss(h: DialogHandle): void {
    h.closing = true;
    if (this.current === h) {
      this.current = null;
    }
    try {
      this.closePopup(h.ticket);
    } catch (e) {
      // 执行层出错不影响收起。
    }
  }

  private closeCurrent(): void {
    const h: DialogHandle | null = this.current;
    this.current = null;
    if (h === null || h.closing) {
      return;
    }
    h.closing = true;
    if (h.opened) {
      this.presenter.dismiss(h.id);
    }
  }

  /** 页面销毁：关掉当前实例，之后不再打开。 */
  dispose(): void {
    this.closeCurrent();
    this.disposed = true;
  }
}
