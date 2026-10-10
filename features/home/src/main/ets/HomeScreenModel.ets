import {
  HomeNoticeCloseTicket, HomePopupImageTicket, HomePopupTicket, HomeRenderTicket, HomeSectionTicket, HomeSnapshot, HomeTap
} from 'core';
import { ProductCardData } from 'designsystem';

/**
 * 首页页面的执行出口（entry 的 AppHome / HomePreview 实现；本模块不 import entry）。所有回调只交回渲染时生成的不可变票据
 * （HomeTap、HomeNoticeCloseTicket、HomeRenderTicket、HomeSectionTicket、HomePopupImageTicket、HomePopupTicket），执行层只比较；
 * 界面不在回调执行时重新读当前快照（鸿蒙第 1 轮评审 R1-02，APP-09 第 63 条，FU-CLIP 第 3 条）。
 */
export interface HomeScreenPort {
  open(t: HomeTap): void;

  closeNotice(t: HomeNoticeCloseTicket): void;

  /** 下拉刷新；Promise 完成时结束本次刷新动画，值为「替换了这个票据所属控制器的内容」（才回到顶部）。 */
  refresh(t: HomeRenderTicket): Promise<boolean>;

  retry(t: HomeRenderTicket): void;

  interacted(t: HomeRenderTicket): void;

  loadMore(t: HomeSectionTicket): void;

  retrySection(t: HomeSectionTicket): void;

  popupImageLoaded(t: HomePopupImageTicket): void;

  popupImageFailed(t: HomePopupImageTicket): void;

  popupShown(t: HomePopupTicket): void;

  closePopup(t: HomePopupTicket): void;

  /** 点弹窗图片：关弹窗并按图片动作打开（执行即关闭）。 */
  openPopup(t: HomePopupTicket): void;

  /**
   * 真正打开弹窗模态之前的复核（R2-03）：票据仍是此刻显示的那一个、页面可见、没有其他弹层才返回 true。
   * 系统模态的关闭回调（返回键、点遮罩）只经 closePopup(本实例的票据)，没有「关当前弹窗」的入口（R2-02）。
   */
  popupBeforeOpen(t: HomePopupTicket): boolean;

  /** 商品项（契约 ProductCard JSON）→ 卡片显示数据（DesignSystem 的同一映射，不做计算）。 */
  productCard(json: Record<string, Object>): ProductCardData;

  /** 【问 AI】（经 Router 打开 AgentChat，入口 in_app）。 */
  askAi(): void;

  /** 图片地址（Release 原样；Debug 截图可换成包内样例图）。 */
  image(url: string): string;
}

class NoopPort implements HomeScreenPort {
  open(_t: HomeTap): void {
  }

  closeNotice(_t: HomeNoticeCloseTicket): void {
  }

  refresh(_t: HomeRenderTicket): Promise<boolean> {
    return Promise.resolve(false);
  }

  retry(_t: HomeRenderTicket): void {
  }

  interacted(_t: HomeRenderTicket): void {
  }

  loadMore(_t: HomeSectionTicket): void {
  }

  retrySection(_t: HomeSectionTicket): void {
  }

  popupImageLoaded(_t: HomePopupImageTicket): void {
  }

  popupImageFailed(_t: HomePopupImageTicket): void {
  }

  popupShown(_t: HomePopupTicket): void {
  }

  closePopup(_t: HomePopupTicket): void {
  }

  openPopup(_t: HomePopupTicket): void {
  }

  popupBeforeOpen(_t: HomePopupTicket): boolean {
    return false;
  }

  productCard(_json: Record<string, Object>): ProductCardData {
    return new ProductCardData();
  }

  askAi(): void {
  }

  image(url: string): string {
    return url;
  }
}

/** 首页页面的可观察状态（entry 在控制器 onChange 时整体替换快照）。首页一份（HomeActions.model），每个 HomePreview 实例各一份。 */
@ObservedV2
export class HomeScreenModel {
  @Trace snapshot: HomeSnapshot = new HomeSnapshot();
  /** ui.grayscale（只作用于首页根视图，G27）。 */
  @Trace grayscale: boolean = false;
  /** 读屏开启：banner 不自动轮播、公告不自动滚动（WCAG 2.2.2）。 */
  @Trace screenReader: boolean = false;
  /** 首页 Tab 选中且在前台：切走时暂停自动播放（不重发拉取）。 */
  @Trace active: boolean = true;
  /** 真实隐私状态是基本模式（R1-08：固定区与基本模式提示只看它，不看只读）。 */
  @Trace basicMode: boolean = false;
  port: HomeScreenPort = new NoopPort();
}
