// APP-11 首页文案草稿表（G28，需契约）：texts.default.json 没有任何 home.* 键。逐字照 Main / MainPopup 稿或标「代拟」。
// TODO(N-35)：契约补上 home.* 键后删掉本表，改走生成的 DefaultTexts。已在契约里的键（error.*、privacy.basic_mode.*、口径说明）一律取契约。
// HomePreview 的文字只在 Debug / Staging 的源码集（G24 ⑧），不在这里。
import { DefaultTexts } from 'generated';

export class HomeDraftTexts {
  private static readonly drafts: Map<string, string> = HomeDraftTexts.build();

  private static build(): Map<string, string> {
    const m: Map<string, string> = new Map<string, string>();
    // 公告条关闭按钮的读屏名（照 Main 稿）。
    m.set('home.notice.close', '关闭公告');
    // 弹窗：读屏名（代拟）、关闭按钮读屏（代拟）。
    m.set('home.popup.label', '活动弹窗');
    m.set('home.popup.close', '关闭');
    // banner / 金刚区 / 入口图片没有 alt 时的读屏名（代拟）。
    m.set('home.image.default_alt', '活动图片');
    // 横滑区「更多」（照 Main 稿「更多 ›」，箭头是图形不是文字）。
    m.set('home.more', '更多');
    // 顶部【问 AI】（照 Main 稿）。
    m.set('home.ask_ai', '问 AI');
    // 信息流底部：一页加载失败（代拟）+【重试】取契约 external_page.retry。
    m.set('home.feed.failed', '加载失败');
    m.set('home.feed.loading', '正在加载');
    // 轮播位置的读屏（代拟）：「第 {n} 张，共 {total} 张」。
    m.set('home.banner.position', '第 {n} 张，共 {total} 张');
    // 加载失败版式（StateLoadFailed）的标题（照设计稿）。
    m.set('home.load_failed.title', '加载失败');
    return m;
  }

  /** 先查契约字典（DefaultTexts），没有再查草稿。 */
  static text(key: string): string {
    return DefaultTexts.text(key) ?? HomeDraftTexts.drafts.get(key) ?? '';
  }

  static format(key: string, vars: Map<string, string>): string {
    let text: string = HomeDraftTexts.text(key);
    vars.forEach((v: string, k: string) => {
      text = text.split('{' + k + '}').join(v);
    });
    return text;
  }

  static keys(): string[] {
    return Array.from(HomeDraftTexts.drafts.keys());
  }
}
