import { ClipboardResultView } from 'core';
import {
  ClipboardNotice, ClipboardPromptBar, CouliColors, CouliLayout, CouliSheetPanel, CouliSpacing, CouliTextModifier,
  CouliTypography, PasteEntry, PasteEntryStyle, ProductCard, ProductCardData, ProductCardVariant
} from 'designsystem';
import { SearchPasteUi } from 'search';
import { AppClipboard, ClipboardCardRow, ClipboardUiModel } from './AppClipboard';
import { ClipboardDraftTexts } from './ClipboardDraftTexts';

const HOME_ENTRY: string = 'home';
const SEARCH_ENTRY: string = 'search_typing';
/** 系统分享提示条（ClipboardPromptView.KIND_SHARE）。 */
const SHARE_KIND: string = 'share';

/** 多卡弹层（G09 没有专稿：按搜索卡样式列出；行内 error_code 的那条置灰并按码给动作，共性第 5 条）。 */
@ComponentV2
struct ClipboardCardListSheet {
  @Local model: ClipboardUiModel = AppClipboard.shared.uiModel;
  /** 承载的 bindSheet 用系统把手（首页 H19）时不再画自绘把手。 */
  @Param systemHandle: boolean = false;

  @Builder
  rows() {
    Column({ space: CouliSpacing.space3 }) {
      ForEach(this.model.rows, (row: ClipboardCardRow) => {
        if (row.data !== null) {
          Column() {
            // 共享 42901 禁用期（行内 42901 或之前的整体 42901）与共享 busy（读取或 parse 在途，§2.4、R1-04）：购买按钮按禁用卡显示，
            // 整张卡不可点（共性第 31 条；执行层 openCard 另拦）
            ProductCard({
              data: (this.model.resultActionsDisabled() && row.limited !== null ? row.limited : row.data) as ProductCardData,
              variant: ProductCardVariant.LIST, onBuy: () => {
              // 购买按钮也先进详情（以这张卡为种子），在详情页再购买（rule-gaps A03）；经这一行渲染时绑定的结果转发（共性第 18 条）
              row.open();
            } })
          }
          .width('100%')
          .enabled(!this.model.resultActionsDisabled())
          .onClick(() => {
            row.open();
          })
          // 卡下一句口径（HomeClipboardCard-v3；取这张卡 disclaimer_keys 的第一句，即价格口径）；卡内的口径 i 照旧可点开全文。
          if ((row.data as ProductCardData).disclaimerLines.length > 0) {
            Text((row.data as ProductCardData).disclaimerLines[0])
              .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
              .width('100%')
              .padding({ left: CouliSpacing.space1, right: CouliSpacing.space1 })
          }
        } else {
          ClipboardNotice({
            text: row.errorText,
            actionText: row.searchable ? ClipboardDraftTexts.text('clipboard.search_by_name') : '',
            actionDisabled: this.model.resultActionsDisabled(),
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

  /** 只有一张商品卡、没有行内结果（HomeClipboardCard-v3 单张）：不显示可见标题（画板无标题），标题只作读屏名与焦点落点。 */
  private single(): boolean {
    return this.model.rows.length === 1 && this.model.rows[0].data !== null;
  }

  build() {
    CouliSheetPanel({
      title: this.model.resultText,
      closeLabel: ClipboardDraftTexts.text('clipboard.card_list.close'),
      titleId: 'clipboard_card_list_title',
      closeKey: this.model.resultSerial,
      // H19：首页半屏用系统把手（bindSheet 的 dragBar 开），搜索页仍自绘；单张无可见标题，关闭有稳定 id。
      showHandle: !this.systemHandle,
      titleVisible: !this.single(),
      closeId: 'clipboard_card_list_close',
      fitContent: this.systemHandle,
      maxPanelHeight: CouliSheetPanel.maxHeight(this.getUIContext()),
      content: () => {
        this.rows()
      },
      onClose: this.model.sheetCloseAction()
    })
  }
}

/**
 * 发起入口下方的结果提示：① 30132（卡内版式 +【用商品名搜索】）、⑤ 网络失败（卡内版式 +【重试】，只重发本次已提取片段）、
 * 30131 / 42901 / 5xxxx 轻提示（错误底 + 关闭）。①⑤ 不设关闭（ClipboardResultView.closable；三端口径 2026-10-24 18:39）。
 */
@Builder
function resultNotice(model: ClipboardUiModel, id: string) {
  ClipboardNotice({
    text: model.resultText,
    actionText: model.resultSearchable ? ClipboardDraftTexts.text('clipboard.search_by_name')
      : (model.resultRetryable ? ClipboardDraftTexts.text('external_page.retry') : ''),
    // 共享 42901 禁用期与共享 busy（读取或 parse 在途，R1-04）内按钮置灰（共性第 31 条；执行层 searchByName / retryResult 另拦）
    actionDisabled: model.resultActionsDisabled(),
    closeLabel: ClipboardResultView.closable(model.resultKind) ? ClipboardDraftTexts.text('clipboard.notice.close') : '',
    noticeId: id,
    card: !ClipboardResultView.closable(model.resultKind),
    icon: model.resultKind === ClipboardResultView.NETWORK_FAILED ? 'alert' : 'info',
    // 渲染键：按钮回调在渲染时固定，结果换代时随之重新登记（R1-03）
    actionKey: model.resultSerial,
    // 渲染时取值：回调绑定的是这条提示所属的结果（共性第 18 条）；⑤ 的【重试】经 ClipboardResultBinding.retry()
    onAction: model.resultKind === ClipboardResultView.NETWORK_FAILED ? model.noticeRetryAction() : model.noticeSearchAction(),
    onClose: model.noticeCloseAction()
  })
}

/**
 * 首页剪贴板提示条行（HomeClipboardInvite / FU-CLIP C7 系统分享，HM-07v H6）：在固定搜索行下、游客价值卡上。鸿蒙没有自动提示条：
 * 读到邀请内容（游客）才出邀请确认条；系统分享到达出分享提示条。没有提示时这一行高 0、不留缝（有提示时自带下方 12 间距）。
 */
@ComponentV2
export struct HomeClipboardPrompt {
  @Local model: ClipboardUiModel = AppClipboard.shared.uiModel;

  private shown(): boolean {
    return this.model.promptId > 0 && this.model.promptEntry === HOME_ENTRY;
  }

  build() {
    Column() {
      if (this.model.promptId > 0 && this.model.promptEntry === HOME_ENTRY && this.model.promptKind === SHARE_KIND) {
        // FU-CLIP C6 / C7：系统分享提示条（平台标签 + 缩略候选，点了才 parse；共享 busy 与 42901 禁用期都置灰，执行层另拦）
        ClipboardPromptBar({
          text: this.model.promptText,
          detail: this.model.promptDetail,
          badge: this.model.promptBadge,
          badgePlatform: this.model.promptBadgePlatform,
          barLabel: this.model.promptLabel,
          actionText: ClipboardDraftTexts.text('clipboard.share_prompt.action'),
          actionLabel: ClipboardDraftTexts.text('clipboard.share_prompt.action'),
          closeLabel: ClipboardDraftTexts.text('clipboard.prompt.close'),
          disabled: this.model.resultActionsDisabled(),
          barId: 'clipboard_share_prompt',
          actionKey: this.model.promptId,
          onAction: this.model.promptConfirmAction(),
          onClose: this.model.promptCloseAction()
        })
      } else if (this.model.promptId > 0 && this.model.promptEntry === HOME_ENTRY) {
        ClipboardPromptBar({
          text: this.model.promptText,
          actionText: ClipboardDraftTexts.text('clipboard.invite_prompt.action'),
          actionLabel: ClipboardDraftTexts.text('clipboard.invite_prompt.action_label'),
          closeLabel: ClipboardDraftTexts.text('clipboard.prompt.close'),
          disabled: this.model.resultActionsDisabled(),
          barId: 'clipboard_invite_prompt',
          actionKey: this.model.promptId,
          onAction: this.model.promptConfirmAction(),
          onClose: this.model.promptCloseAction()
        })
      }
    }
    .width('100%')
    .padding({ bottom: this.shown() ? CouliSpacing.space3 : 0 })
  }
}

/**
 * 首页常驻粘贴卡行（Main-v3 / HomeGuest-v3「粘贴查返利」，HM-07v H5）：一张卡、一个系统 PasteButton（只调底色与圆角，文字图标由系统给）；
 * 卡标题即按钮说明（clipboard.paste_hint，BR-ID-16）；无副标题。卡下是结果内联提示；识别卡半屏（bindSheet）挂在这一行，
 * 状态由模型驱动（sheetFor(HOME_ENTRY)，onDisappear 交回 sheetCloseAction，列表按票据重建不改变这一口径）。
 */
@ComponentV2
export struct HomeClipboardPaste {
  @Local model: ClipboardUiModel = AppClipboard.shared.uiModel;

  @Builder
  sheet() {
    ClipboardCardListSheet({ systemHandle: true })
  }

  build() {
    Column({ space: CouliSpacing.space3 }) {
      PasteEntry({
        entryStyle: PasteEntryStyle.CARD,
        title: ClipboardDraftTexts.text('clipboard.paste_hint'),
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
    // H19（HomeClipboardCard-v3）：系统把手；单张贴内容高度（FIT_CONTENT），多张按大半屏可滚；关闭用面板右上自己的【关闭】
    // （有稳定 id 与读屏名）。下滑 / 点遮罩 / 返回 = 关闭（onDisappear 交回 sheetCloseAction，状态由模型驱动，不放行内 @Local）。
    .bindSheet(this.model.sheetFor(HOME_ENTRY), this.sheet(), {
      height: this.model.rows.length <= 1 ? SheetSize.FIT_CONTENT : SheetSize.LARGE,
      // 多张：MEDIUM / LARGE 两档（系统把手只在多档时显示）；单张一档 FIT_CONTENT（面板贴内容，系统不画把手）。
      detents: this.model.rows.length <= 1 ? [SheetSize.FIT_CONTENT] : [SheetSize.MEDIUM, SheetSize.LARGE],
      dragBar: true,
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
          disabled: this.model.resultActionsDisabled(),
          barId: 'search_invite_prompt',
          actionKey: this.model.promptId,
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

/** 首页列表里的剪贴板两行（HomeActions.clipboardPrompt / clipboardPaste 用 wrapBuilder 登记）。 */
@Builder
export function homeClipboardPromptBuilder() {
  HomeClipboardPrompt()
}

@Builder
export function homeClipboardPasteBuilder() {
  HomeClipboardPaste()
}
