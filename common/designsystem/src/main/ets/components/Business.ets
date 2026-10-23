import { CouliColors } from '../CouliColors';
import { CouliComponentMetrics, CouliRadius, CouliSpacing } from '../CouliMetrics';
import { CouliTypography } from '../CouliTypography';
import { CouliCheckbox, CouliCheckboxRow } from './Controls';
import { DisclosureRow } from './Display';
import { CouliIcon } from './CouliIcon';
import { CouliTextModifier } from './CouliText';

/**
 * DS-02 新增业务组件（清单 §4）：价格走势、分享选图、分享文案。文案与数据由调用方给；组件不请求服务。
 */

export enum TrendState {
  COLLAPSED = 'collapsed',
  EXPANDED = 'expanded',
  LOADING = 'loading'
}

/** 价格走势里的一个点（分）。 */
export class TrendPoint {
  readonly label: string;
  readonly cents: number;

  constructor(label: string, cents: number) {
    this.label = label;
    this.cents = cents;
  }
}

/**
 * 价格走势（清单 §4 PriceTrendPanel）：折叠行（展开时才由调用方请求）+ 折线（Polyline）+ 文字摘要（读屏读摘要，图形本身装饰）。
 * 无记录显示 emptyText；加载中转圈。
 */
@ComponentV2
export struct PriceTrendPanel {
  @Param title: string = '';
  @Param state: TrendState = TrendState.COLLAPSED;
  @Param points: TrendPoint[] = [];
  @Param summary: string = '';
  @Param emptyText: string = '';
  @Param expandedText: string = '';
  @Param collapsedText: string = '';
  @Event onToggle: (expanded: boolean) => void = (_e: boolean) => {
  };

  private polyline(): number[][] {
    if (this.points.length < 2) {
      return [];
    }
    let min: number = this.points[0].cents;
    let max: number = this.points[0].cents;
    for (const p of this.points) {
      min = Math.min(min, p.cents);
      max = Math.max(max, p.cents);
    }
    const span: number = Math.max(1, max - min);
    const out: number[][] = [];
    this.points.forEach((p: TrendPoint, i: number) => {
      out.push([i * 280 / (this.points.length - 1), 8 + (max - p.cents) * 64 / span]);
    });
    return out;
  }

  @Builder
  body() {
    Column({ space: CouliSpacing.space2 }) {
      if (this.state === TrendState.LOADING) {
        LoadingProgress().width(CouliSpacing.space8).height(CouliSpacing.space8).color(CouliColors.textSecondary)
      } else if (this.points.length < 2) {
        Text(this.emptyText)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
      } else {
        Polyline({ width: 280, height: 80 })
          .points(this.polyline())
          .fillOpacity(0)
          .stroke(CouliColors.brandPrimary)
          .strokeWidth(2)
          .strokeLineJoin(LineJoinStyle.Round)
          .accessibilityLevel('no')
        Text(this.summary)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ bottom: CouliSpacing.space3 })
  }

  build() {
    Column() {
      DisclosureRow({
        title: this.title,
        expanded: this.state !== TrendState.COLLAPSED,
        stateText: this.state !== TrendState.COLLAPSED ? this.expandedText : this.collapsedText,
        content: () => {
          this.body()
        },
        onToggle: (e: boolean) => {
          this.onToggle(e);
        }
      })
    }
    .width('100%')
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4 })
    .backgroundColor(CouliColors.backgroundSurface)
    .borderRadius(CouliRadius.card)
  }
}

/** 分享选图的列数（清单 §4「4 列方格」）。 */
const SHARE_GRID_COLUMNS: number = 4;

/** 分享选图里的一张图。 */
export class ShareMaterial {
  readonly label: string;
  readonly qr: boolean;
  readonly selected: boolean;

  constructor(label: string, qr: boolean, selected: boolean) {
    this.label = label;
    this.qr = qr;
    this.selected = selected;
  }
}

/**
 * 分享选图（清单 §4 ShareMaterialPicker）：组件库自绘 4 列方格（评审 r1 R1-06：按可用宽度均分四列、超过 4 张自动换行，
 * 不再固定 88 宽单行）；二维码首图在前；每格右上同一个圆形勾选框（图片角标 22，外层 48 命中区最多伸出 8vp 到列间距里，不压相邻格）；
 * 底部「已选 N 张」与保存按钮由调用方给。
 */
@ComponentV2
export struct ShareMaterialPicker {
  @Param materials: ShareMaterial[] = [];
  @Param countText: string = '';
  @Event onToggle: (index: number, selected: boolean) => void = (_i: number, _s: boolean) => {
  };

  build() {
    Column({ space: CouliSpacing.space2 }) {
      GridRow({ columns: SHARE_GRID_COLUMNS, gutter: { x: CouliSpacing.space2, y: CouliSpacing.space2 } }) {
        ForEach(this.materials, (item: ShareMaterial, index: number) => {
          GridCol({ span: 1 }) {
            Stack({ alignContent: Alignment.TopEnd }) {
              Column({ space: CouliSpacing.space1 }) {
                CouliIcon({ name: item.qr ? 'link' : 'image', iconSize: 24, color: CouliColors.textSecondary })
                Text(item.label)
                  .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
                  .maxLines(2)
                  .textAlign(TextAlign.Center)
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
              .backgroundColor(CouliColors.backgroundPlaceholder)
              .border({ width: CouliComponentMetrics.controlBorderWidth,
                color: item.selected ? CouliColors.controlChecked : CouliColors.borderSubtle })
              .borderRadius(CouliRadius.small)
              CouliCheckbox({
                checked: item.selected,
                imageBadge: true,
                accessibilityName: item.label,
                onChange: (v: boolean) => {
                  this.onToggle(index, v);
                }
              })
              // 角标贴近右上角：48 命中区向外让出 8（= 列间距），不压相邻格的命中区。
              .margin({ top: -CouliSpacing.space2, right: -CouliSpacing.space2 })
            }
            .width('100%')
            .aspectRatio(1)
          }
        }, (item: ShareMaterial, index: number) => index + item.label + item.selected)
      }
      .width('100%')
      if (this.countText.length > 0) {
        Text(this.countText)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/** 分享文案的一项（必选项置灰选中）。 */
export class ShareCopyItem {
  readonly label: string;
  readonly checked: boolean;
  readonly required: boolean;

  constructor(label: string, checked: boolean, required: boolean) {
    this.label = label;
    this.checked = checked;
    this.required = required;
  }
}

/**
 * 分享文案（清单 §4 ShareCopyEditor）：查看（只读文案）、编辑（多行输入由调用方放 CouliTextArea）、改勾选覆盖提示（NoticeBar 由调用方放）；
 * 勾选项用 CouliCheckboxRow，必选项禁用且选中。
 */
@ComponentV2
export struct ShareCopyEditor {
  @Param copy: string = '';
  @Param items: ShareCopyItem[] = [];
  @Param editing: boolean = false;
  @BuilderParam editor: () => void = emptyEditor;
  @BuilderParam notice: () => void = emptyEditor;
  @Event onToggle: (index: number, checked: boolean) => void = (_i: number, _c: boolean) => {
  };

  build() {
    Column({ space: CouliSpacing.space2 }) {
      this.notice()
      if (this.editing) {
        this.editor()
      } else {
        Text(this.copy)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
          .padding(CouliSpacing.space3)
          .width('100%')
          .backgroundColor(CouliColors.backgroundMuted)
          .borderRadius(CouliRadius.small)
      }
      ForEach(this.items, (item: ShareCopyItem, index: number) => {
        CouliCheckboxRow({
          checked: item.checked || item.required,
          disabled: item.required,
          label: item.label,
          onChange: (v: boolean) => {
            this.onToggle(index, v);
          }
        })
      }, (item: ShareCopyItem, index: number) => index + item.label + item.checked)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

@Builder
function emptyEditor() {
}

