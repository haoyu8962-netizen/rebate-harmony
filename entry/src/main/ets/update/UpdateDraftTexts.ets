/**
 * 强更页的草稿文字：契约 texts.default.json 里还没有键的几处（needs.md N-16），照设计稿 ForceUpdate 逐字放在这一处，
 * 三端同名（iOS / Android / 鸿蒙 UpdateDraftTexts）。有键的（app_update.*、error.10405）一律读 DefaultTexts，不放这里。
 *
 * TODO(N-16) 待契约补 app_update.title / app_update.notes_title 等键后整文件删除，改读 DefaultTexts；提审前（QA-07）必须替换。
 */
export class UpdateDraftTexts {
  /** TODO(N-16) 不得提审：强更页标题（ForceUpdate「发现新版本 2.1.0」），版本号取检查结果的 latest_version。 */
  static forceTitle(version: string | null): string {
    return version === null || version.length === 0 ? '发现新版本' : '发现新版本 ' + version;
  }

  /** TODO(N-16) 不得提审：更新内容卡片标题（ForceUpdate「更新内容」）。 */
  static readonly NOTES_TITLE: string = '更新内容';
}
