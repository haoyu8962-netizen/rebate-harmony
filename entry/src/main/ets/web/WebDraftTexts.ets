/**
 * WebView 容器的草稿文字：契约 texts.default.json 里还没有键的几处，放在这一处（与强更页 UpdateDraftTexts 同一做法）。
 * 有键的（external_page.*）一律读 DefaultTexts，不放这里。
 *
 * TODO(N-22) 待契约补「去搜索」按钮的文案键（如 external_page.go_search）后整文件删除，改读 DefaultTexts；提审前（QA-07）必须替换。
 */
export class WebDraftTexts {
  /** TODO(N-22) 不得提审：平台页面被拦提示里的「去搜索」按钮（BR-ATTR-29 ②(b)，APP-04 R2-09）。 */
  static readonly GO_SEARCH: string = '去搜索';
}
