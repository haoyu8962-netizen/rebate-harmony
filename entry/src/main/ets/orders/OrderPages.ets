import { RouteDestination } from 'core';
import { CouliColors } from 'designsystem';
import { OrderDetailPageConfig, OrderDetailView, OrderListPageConfig, OrderListView } from 'orders';
import { AppPrivacy } from '../privacy/AppPrivacy';
import { AppOrders, PendingTrackHost } from './AppOrders';
import { PendingTrackArea } from './PendingTrackViews';

/**
 * 订单 Tab 根（OrderList 路由）。Tab 被切走只是被覆盖：执行器整个进程一份（AppOrders），不作废；加载与会话变化由 AppOrders 处理。
 * 只读打开（基本模式）不会走到这里（OrderList 需要同意与登录）。
 */
@ComponentV2
export struct AppOrdersTab {
  @Param readonlyMode: boolean = false;
  private config: OrderListPageConfig | null = null;
  private pending: PendingTrackHost | null = null;

  aboutToAppear(): void {
    AppOrders.shared.attachUi(this.getUIContext());
    this.config = AppOrders.shared.listConfig();
    this.pending = AppOrders.shared.listPendingHost();
  }

  @Builder
  pendingSlot() {
    if (this.pending !== null) {
      PendingTrackArea({ ui: this.pending.ui })
    }
  }

  build() {
    Column() {
      if (this.config !== null) {
        OrderListView({
          config: this.config, pendingSlot: (): void => {
            this.pendingSlot()
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(CouliColors.backgroundCanvas)
  }
}

/** Tab 注册表用的入口（TabRootRegistry 以 wrapBuilder 登记到路由名 OrderList）。 */
@Builder
export function appOrdersTabBuilder(readonlyMode: boolean) {
  AppOrdersTab({ readonlyMode: readonlyMode })
}

/**
 * 路由 OrderDetail（order_id 必填）。页面一确定出栈（onWillDisappear，早于退场动画）就作废请求并取消传输，之后的响应不改任何状态；
 * 只被盖住（进商品详情、帮助页）不触发。
 */
@ComponentV2
export struct AppOrderDetailPage {
  @Param param: Object = new RouteDestination('OrderDetail');
  private config: OrderDetailPageConfig | null = null;

  aboutToAppear(): void {
    AppOrders.shared.attachUi(this.getUIContext());
    this.config = AppOrders.shared.detailConfig(this.param, (): void => {
      this.queryNavigationInfo()?.pathStack.pop();
    });
    if (this.config.orderId.length > 0) {
      this.config.controller.load(this.config.orderId);
    }
  }

  aboutToDisappear(): void {
    // onWillDisappear 已执行过时 leave 是幂等的；没走到它的销毁由这里兜底。
    if (this.config !== null) {
      AppOrders.shared.detailLeft(this.config.controller);
    }
  }

  build() {
    NavDestination() {
      if (this.config !== null) {
        OrderDetailView({ config: this.config })
      }
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
    .onBackPressed((): boolean => AppPrivacy.shared.blocksBack)
    .onWillDisappear((): void => {
      if (this.config !== null) {
        AppOrders.shared.detailLeft(this.config.controller);
      }
    })
  }
}
