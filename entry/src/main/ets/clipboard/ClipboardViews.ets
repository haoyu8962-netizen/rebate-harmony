import {
  ClipboardNotice, ClipboardPromptBar, CouliColors, CouliLayout, CouliSheetPanel, CouliSpacing, PasteEntry,
  PasteEntryStyle, ProductCard, ProductCardData, ProductCardVariant
} from 'designsystem';
import { SearchPasteUi } from 'search';
import { AppClipboard, ClipboardCardRow, ClipboardUiModel } from './AppClipboard';
import { ClipboardDraftTexts } from './ClipboardDraftTexts';

const HOME_ENTRY: string = 'home';
const SEARCH_ENTRY: string = 'search_typing';

/** 多卡弹层（G09 没有专稿：按搜索卡样式列出；行内 error_code 的那条置灰并按码给动作，共性第 5 条）。 */
@ComponentV2
struct ClipboardCardListSheet {
  @Local model: ClipboardUiModel = AppClipboard.shared.uiModel;

  @Builder
  rows() {
    Column({ space: CouliSpacing.space3 }) {
      ForEach(this.model.rows, (row: ClipboardCardRow) => {
        if (row.data !== null) {
          Column() {
            // 共享 42901 禁用期（行内 42901 或之前的整体 42901）：购买按钮按禁用卡显示，整张卡不可点（共性第 31 条；执行层 openCard 另拦）
            ProductCard({ data: (this.model.blocked && row.limited !== null ? row.limited : row.data) as ProductCardData,
              variant: ProductCardVariant.LIST, onBuy: () => {
              // 购买按钮也先进详情（以这张卡为种子），在详情页再购买（rule-gaps A03）；经这一行渲染时绑定的结果转发（共性第 18 条）
              row.open();
            } })
          }
          .width('100%')
          .enabled(!this.model.blocked)
          .onClick(() => {
            row.open();
          })
        } else {
          ClipboardNotice({
            text: row.errorText,
            actionText: row.searchable ? ClipboardDraftTexts.text('clipboard.search_by_name') : '',
            actionDisabled: this.model.blocked,
            closeLabel: '',
            noticeId: 'clipboard_row_' + row.key,
            onAction: () => {
              row.searchByName();
            }
          })
        }
      }, (row: ClipboardCardRow) => row.key)
    }
    .width('100%')
  }

  build() {
    CouliSheetPanel({
      title: this.model.resultText,
      closeLabel: ClipboardDraftTexts.text('clipboard.card_list.close'),
      titleId: 'clipboard_card_list_title',
      content: () => {
        this.rows()
      },
      onClose: this.model.sheetCloseAction()
    })
  }
}

/** 发起入口下方的结果提示（30132 + 【用商品名搜索】、30131 / 42901 / 5xxxx 轻提示）。 */
@Builder
function resultNotice(model: ClipboardUiModel, id: string) {
  ClipboardNotice({
    text: model.resultText,
    actionText: model.resultSearchable ? ClipboardDraftTexts.text('clipboard.search_by_name') : '',
    // 共享 42901 禁用期内【用商品名搜索】置灰（共性第 31 条；执行层 searchByName 另拦）
    actionDisabled: model.blocked,
    closeLabel: ClipboardDraftTexts.text('clipboard.notice.close'),
    noticeId: id,
    // 渲染时取值：回调绑定的是这条提示所属的结果（共性第 18 条）
    onAction: model.noticeSearchAction(),
    onClose: model.noticeCloseAction()
  })
}

/**
 * 首页剪贴板区（HomeClipboard / HomeClipboardInvite、Main / HomeGuest 的「粘贴链接，先查返利」卡）：挂在首页 Tab 根页的固定位置
 * （首页 SDUI 在 APP-11）。鸿蒙没有自动提示条：粘贴卡是系统 PasteButton；读到邀请内容（游客）才出邀请确认条。大屏限宽 600 居中
 * （共性第 8 条；外层首页已是滚动容器）。
 */
@ComponentV2
export struct HomeClipboardArea {
  @Local model: ClipboardUiModel = AppClipboard.shared.uiModel;

  @Builder
  sheet() {
    ClipboardCardListSheet()
  }

  build() {
    Column({ space: CouliSpacing.space3 }) {
      if (this.model.promptId > 0 && this.model.promptEntry === HOME_ENTRY) {
        ClipboardPromptBar({
          text: this.model.promptText,
          actionText: ClipboardDraftTexts.text('clipboard.invite_prompt.action'),
          actionLabel: ClipboardDraftTexts.text('clipboard.invite_prompt.action_label'),
          closeLabel: ClipboardDraftTexts.text('clipboard.prompt.close'),
          disabled: this.model.blocked,
          barId: 'clipboard_invite_prompt',
          onAction: this.model.promptConfirmAction(),
          onClose: this.model.promptCloseAction()
        })
      }
      PasteEntry({
        entryStyle: PasteEntryStyle.CARD,
        title: ClipboardDraftTexts.text('clipboard.home_card.title'),
        subtitle: ClipboardDraftTexts.text('clipboard.home_card.subtitle'),
        disabled: this.model.blocked || this.model.busy,
        entryId: 'home_paste_card',
        onResult: (success: boolean) => {
          AppClipboard.shared.pasteHome(success);
        }
      })
      if (this.model.noticeFor(HOME_ENTRY)) {
        resultNotice(this.model, 'home_clipboard_notice')
      }
    }
    .width('100%')
    .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
    .bindSheet(this.model.sheetFor(HOME_ENTRY), this.sheet(), {
      height: SheetSize.LARGE,
      dragBar: false,
      showClose: false,
      backgroundColor: CouliColors.backgroundSurface,
      onDisappear: this.model.sheetCloseAction()
    })
  }
}

/**
 * SearchTyping「粘贴查返利」（SearchTyping 画板：白卡内上方说明文字 + 整行系统 PasteButton）。粘贴入口按 SearchPasteUi 显示（还没搜、
 * 没有可搜平台、search_disabled 回落后，共性第 11 条）；结果提示不随搜索 phase 隐藏（共性第 10 条）。30132【用商品名搜索】填进本页搜索框。
 */
@ComponentV2
export struct SearchPasteArea {
  @Param paste: SearchPasteUi = new SearchPasteUi();
  @Event fill: (q: string) => void = (_q: string) => {
  };
  @Local model: ClipboardUiModel = AppClipboard.shared.uiModel;

  @Builder
  sheet() {
    ClipboardCardListSheet()
  }

  build() {
    Column({ space: CouliSpacing.space3 }) {
      if (this.model.promptId > 0 && this.model.promptEntry === SEARCH_ENTRY) {
        ClipboardPromptBar({
          text: this.model.promptText,
          actionText: ClipboardDraftTexts.text('clipboard.invite_prompt.action'),
          actionLabel: ClipboardDraftTexts.text('clipboard.invite_prompt.action_label'),
          closeLabel: ClipboardDraftTexts.text('clipboard.prompt.close'),
          disabled: this.model.blocked,
          barId: 'search_invite_prompt',
          onAction: this.model.promptConfirmAction(),
          onClose: this.model.promptCloseAction()
        })
      }
      if (this.paste.entryVisible) {
        PasteEntry({
          entryStyle: PasteEntryStyle.ROW,
          caption: ClipboardDraftTexts.text('clipboard.paste_entry.hint'),
          disabled: this.model.blocked || this.model.busy,
          entryId: 'search_paste_entry',
          onResult: (success: boolean) => {
            AppClipboard.shared.pasteSearch(success, this.fill);
          }
        })
      }
      if (this.model.noticeFor(SEARCH_ENTRY)) {
        resultNotice(this.model, 'search_clipboard_notice')
      }
    }
    .width('100%')
    .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
    .padding(this.paste.entryVisible || this.model.noticeFor(SEARCH_ENTRY) || this.model.promptEntry === SEARCH_ENTRY
      ? { left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space4 } : 0)
    .bindSheet(this.model.sheetFor(SEARCH_ENTRY), this.sheet(), {
      height: SheetSize.LARGE,
      dragBar: false,
      showClose: false,
      backgroundColor: CouliColors.backgroundSurface,
      onDisappear: this.model.sheetCloseAction()
    })
  }
}

/** 首页 Tab 根页的剪贴板区（HomeActions.clipboardArea 用 wrapBuilder 登记）。 */
@Builder
export function homeClipboardBuilder() {
  HomeClipboardArea()
}
