import { DefaultTexts } from 'generated';
import { SearchDraftTexts } from '../search/SearchDraftTexts';

/**
 * 购买流程、AuthSheet、JumpTip、AuthManage 里契约 texts.default.json 还没有的文案键（APP-06b rule-gaps，TODO(N-28)）。照设计稿
 * ProductBuyOpening、ProductBuyTimeout、ProductPriceChanged(+RebateGone、Cancelled)、ProductRebateGone(+Cancelled)、
 * ProductPriceCompareNoRebate(+Cancelled)、ProductAuthSheet、ProductAuthDeclined、ProductAuthFailed、ProductAuthUnavailable、ProductJumpTip、
 * ProductJumpNotInstalled、ProductJumpBrowser、ProductJumpSdkFailed、ProductJumpHarmonyH5、AuthManageBlocked 逐字集中放在这一处；三端同名
 * （键与 Android TradeDraftTexts 一致，鸿蒙另有 trade.harmony_h5_notice）。契约有的键（buy.*、error.*、auth_manage.*、
 * jump.taobao_sdk_unavailable、no_rebate.price_compare.*、share_page.copy_tpwd.done）一律读 DefaultTexts。平台名、返回等沿用
 * SearchDraftTexts。
 *
 * TODO(N-28) 整张表都是「待定稿，不得提审」：契约补键后删除本文件、改读 DefaultTexts。
 */
export class TradeDraftTexts {
  static readonly DRAFTS: Map<string, string> = TradeDraftTexts.build();

  private static build(): Map<string, string> {
    const m: Map<string, string> = new Map<string, string>();
    // ---- 浏览器打开（ProductJumpBrowser，BR-ATTR-27 京东行「将通过浏览器打开京东」）
    m.set('trade.browser_notice', '将通过浏览器打开{platform_name}');
    // ---- 价格变动 / 券失效 / 返利归零（BR-PRICE-13 / 14）
    m.set('trade.price_changed.title', '价格已变动');
    m.set('trade.price_changed.before', '之前（{price_label}）');
    m.set('trade.price_changed.now', '现在（{price_label}）');
    m.set('trade.price_changed.now_plain', '现在');
    // 原价口径未知（共性第 47 条）：「之前」不带口径词
    m.set('trade.price_changed.before_plain', '之前');
    m.set('trade.price_changed.ask', '继续购买？最终价格以下单页为准');
    // 券失效没有单独的画板（BR-PRICE-14「弹券失效确认」）：标题按规则原意
    m.set('trade.coupon_gone.title', '优惠券已失效，价格已变动');
    m.set('trade.rebate_gone.line', '该商品当前暂无返利');
    m.set('trade.rebate_gone.note', '继续购买不会获得返利');
    m.set('trade.rebate_gone.title', '该商品当前暂无返利，继续购买？');
    // 只在新旧价格相同时用（共性第 45 条）；新价不同（变动未达阈值）用 body_changed，{price_now} 是「现在（券后）」或券额未补齐时的「现在」
    m.set('trade.rebate_gone.body', '价格没有变化，{price_label} {price}。继续购买不会获得返利');
    m.set('trade.rebate_gone.body_changed', '{price_now} {price}。继续购买不会获得返利');
    // 价格没有变化但口径未知（共性第 47 条）：不默认「券后」
    m.set('trade.rebate_gone.body_plain', '价格没有变化，{price}。继续购买不会获得返利');
    m.set('trade.cancel', '取消');
    m.set('trade.continue', '继续购买');
    m.set('trade.cancelled.price', '已取消购买，价格已更新为最新');
    m.set('trade.cancelled.price_rebate', '已取消购买，价格和返利信息已更新');
    m.set('trade.cancelled.rebate', '已取消购买，返利信息已更新');
    // requote_failed（BR-PRICE-13「用返回链接外跳，同时提示价格以下单页为准」；没有画板）
    m.set('trade.requote_notice', '暂时无法确认最新价格，以下单页为准');
    // ---- 比价无返利（BR-PRICE-08）
    m.set('trade.compare.body', '继续购买不会获得返利，最终价格以下单页为准。');
    m.set('trade.compare.explain', '查看说明');
    m.set('trade.buy_no_rebate', '仍去购买（无返利）');
    // ---- AuthSheet / 关闭 / 失败 / 不可用（BR-ID-17 / 18 / 24）
    m.set('trade.close', '关闭');
    m.set('trade.auth.reason', '授权后，才能识别你在{platform_name}下的订单并计算返利');
    m.set('trade.auth.privacy', '只用于识别订单，不获取你的淘宝昵称、头像和账号名');
    m.set('trade.auth_declined.title', '未授权将无法获得返利');
    m.set('trade.auth_declined.body',
      '完成{platform_name}授权后购买，才能识别这笔订单并计算返利。也可以不授权直接去{platform_name}购买，这笔订单不计返利。');
    m.set('trade.auth_failed.body', '未授权将无法获得返利。可以重新授权，或不授权直接去{platform_name}购买（这笔订单不计返利）。');
    m.set('trade.auth_unavailable.body', '商品信息保留在本页，稍后可以再点购买。');
    m.set('trade.ok', '知道了');
    // ---- JumpTip（BR-ATTR-21；文案后台可配 jump_tip.<platform>，配置为空时用画板的两句）
    m.set('trade.jump_tip.title', '下单须知');
    m.set('trade.jump_tip.line1', '在打开的商品页直接下单');
    m.set('trade.jump_tip.line2', '不要加购后隔天再买');
    m.set('trade.jump_tip.go', '知道了，去{platform_name}');
    // ---- 外跳失败（BR-ATTR-27）
    m.set('trade.sdk_failed.body', '这次没有跳转，商品信息保留在本页，稍后可以再点购买。');
    m.set('trade.not_installed', '安装{platform_name}后下单才有返利');
    m.set('trade.not_installed.copied', '安装{platform_name}后下单才有返利，口令已复制');
    m.set('trade.jump_failed', '暂时无法打开{platform_name}，请稍后再试');
    // 跳转方案过了 expire_at（共性第 12 条；没有画板与文案键，草稿）
    m.set('trade.jump_expired', '购买链接已过期，请重新点购买');
    // ProductJumpHarmonyH5（仅鸿蒙：淘宝只能降级到网页时的提示）
    m.set('trade.harmony_h5_notice', '鸿蒙版可能影响返利跟踪，如未显示订单可申请找回');
    // ---- 联系客服（统一客服出口未接入，暂经 Router 打开帮助中心）
    m.set('trade.contact', '联系客服');
    // ---- 授权管理（AuthManage；标题、状态、去授权、改绑说明读契约）
    m.set('auth_manage.back', '返回');
    m.set('auth_manage.loading', '加载中');
    // 「我的」与设置页的入口行（共性第 14 条；入口行样式没有画板）
    m.set('auth_manage.entry', '授权管理');
    return m;
  }

  private static raw(key: string): string | null {
    return DefaultTexts.text(key) ?? TradeDraftTexts.DRAFTS.get(key) ?? SearchDraftTexts.DRAFTS.get(key) ?? null;
  }

  /** 先取契约字典，再取草稿；带 {变量} 的文案（没有给值）用 fallback。缺键返回空串。 */
  static text(key: string): string {
    const raw: string | null = TradeDraftTexts.raw(key);
    if (raw === null) {
      return DefaultTexts.fallback(key) ?? '';
    }
    if (/\{[a-z0-9_]+\}/.test(raw)) {
      return DefaultTexts.fallback(key) ?? raw.replace(/\{[a-z0-9_]+\}/g, '');
    }
    return raw;
  }

  /** 填 {变量}；值为空或仍有没填上的变量时用 fallback（BR-TEXT-14：缺变量回退）。 */
  static format(key: string, vars: Map<string, string>): string {
    let text: string | null = TradeDraftTexts.raw(key);
    if (text === null) {
      return TradeDraftTexts.text(key);
    }
    let out: string = text;
    vars.forEach((value: string, name: string) => {
      if (value.length > 0) {
        out = out.split('{' + name + '}').join(value);
      }
    });
    if (/\{[a-z0-9_]+\}/.test(out)) {
      return DefaultTexts.fallback(key) ?? out.replace(/\{[a-z0-9_]+\}/g, '');
    }
    return out;
  }

  /** 平台显示名。 */
  static platformName(platform: string): string {
    return TradeDraftTexts.text('platform.' + platform);
  }
}
