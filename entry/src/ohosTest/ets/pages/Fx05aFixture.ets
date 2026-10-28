import { ConfigurationConstant } from '@kit.AbilityKit';
import {
  ClipboardPromptBar, CouliColors, PlatformBadge, PlatformIcon, PlatformIconSize, ProductCard, ProductCardData, ProductCardVariant
} from 'designsystem';
import { FX05A_CLIP_SAMPLES, Fx05aClipRow, fx05aClipFailures, fx05aClipRows } from '../test/Fx05aClipboardBadge';

// F-X-05a 设备用例宿主：只编入测试 HAP。组合真实 designsystem 组件，不加产品测试分支或 testTag。
// 每个被测件外包一个只按内容定尺寸的 Row（带 id），UiTest 以它为范围查询无障碍节点、截屏取像素。

/** 有图平台 / 暂缺 / 未知编码的徽标用例（id 后缀、显示名、编码、远程图地址）。 */
class BadgeCase {
  id: string;
  label: string;
  platform: string;
  remoteUrl: string;
  legacy: boolean;

  constructor(id: string, label: string, platform: string, remoteUrl: string = '', legacy: boolean = false) {
    this.id = id;
    this.label = label;
    this.platform = platform;
    this.remoteUrl = remoteUrl;
    this.legacy = legacy;
  }
}

class IconCase {
  id: string;
  platform: string;
  size: PlatformIconSize;
  remoteUrl: string;

  constructor(id: string, platform: string, size: PlatformIconSize, remoteUrl: string = '') {
    this.id = id;
    this.platform = platform;
    this.size = size;
    this.remoteUrl = remoteUrl;
  }
}

const REMOTE: string = 'https://media.couli.invalid/fx05a/remote.png';

const FX05A_BADGES: BadgeCase[] = [
  new BadgeCase('taobao', '淘宝', 'taobao'),
  new BadgeCase('jd', '京东', 'jd'),
  new BadgeCase('pdd', '拼多多', 'pdd'),
  new BadgeCase('taobao-remote', '淘宝', 'taobao', REMOTE),
  new BadgeCase('tmall', '天猫', 'tmall'),
  new BadgeCase('wechat', '微信', 'wechat'),
  // 未知编码配一个「有图平台」的显示名：不能按名字猜出淘宝图。
  new BadgeCase('xyz', '淘宝', 'xyz'),
  // 把文件名当编码：pinduoduo 不是标识键。
  new BadgeCase('pinduoduo', '拼多多', 'pinduoduo'),
  new BadgeCase('empty', '京东', ''),
  // 不传 platform 的旧调用（纯文字参照）：与上面暂缺 / 未知用例逐个比尺寸。
  new BadgeCase('legacy-天猫', '天猫', '', '', true),
  new BadgeCase('legacy-微信', '微信', '', '', true),
  new BadgeCase('legacy-淘宝', '淘宝', '', '', true),
  new BadgeCase('legacy-拼多多', '拼多多', '', '', true),
  new BadgeCase('legacy-京东', '京东', '', '', true)
];

const FX05A_ICONS: IconCase[] = [
  new IconCase('taobao-14', 'taobao', PlatformIconSize.BADGE),
  new IconCase('taobao-44', 'taobao', PlatformIconSize.GRID),
  new IconCase('jd-14', 'jd', PlatformIconSize.BADGE),
  new IconCase('jd-44', 'jd', PlatformIconSize.GRID),
  new IconCase('pdd-14', 'pdd', PlatformIconSize.BADGE),
  new IconCase('pdd-44', 'pdd', PlatformIconSize.GRID),
  new IconCase('pdd-44-remote', 'pdd', PlatformIconSize.GRID, REMOTE)
];

/** 缺图的 PlatformIcon 放在固定 60vp 的槽里：槽内必须只有底色（不画占位方块）。 */
const FX05A_EMPTY_ICONS: IconCase[] = [
  new IconCase('tmall-44', 'tmall', PlatformIconSize.GRID),
  new IconCase('xyz-44', 'xyz', PlatformIconSize.GRID),
  new IconCase('pinduoduo-14', 'pinduoduo', PlatformIconSize.BADGE),
  new IconCase('empty-44', '', PlatformIconSize.GRID)
];

const FX05A_CARDS: string[][] = [['jd', '京东'], ['pdd', '拼多多'], ['tmall', '天猫']];

function cardData(code: string, label: string): ProductCardData {
  const d: ProductCardData = new ProductCardData();
  d.platformCode = code;
  d.platformLabel = label;
  d.title = 'FX05A 测试商品标题';
  d.imageLabel = '商品图';
  d.buyBase = '去购买';
  return d;
}

/**
 * v3（评审 r1 R1-01）：剪贴板分享提示条。每条的参数由真实识别链路 + 真实派生入口 ClipboardBadgeIcon.of 现场算出（与 AppClipboard.apply
 * 同源，见 ../test/Fx05aClipboardBadge.ets），交给真实 ClipboardPromptBar 渲染。tmall-legacy = 同一条天猫提示、不传 badgePlatform
 * （F-X-05a 之前的调用，纯文字参照）。
 */
const FX05A_CLIP_SHOWN: string[] = ['tmall', 'taobao', 'jd', 'pdd'];

class ClipBar {
  id: string;
  row: Fx05aClipRow;
  legacy: boolean;

  constructor(id: string, row: Fx05aClipRow, legacy: boolean) {
    this.id = id;
    this.row = row;
    this.legacy = legacy;
  }
}

function clipBars(): ClipBar[] {
  const out: ClipBar[] = [];
  try {
    const rows: Fx05aClipRow[] = fx05aClipRows();
    for (const id of FX05A_CLIP_SHOWN) {
      const hit: Fx05aClipRow[] = rows.filter((row: Fx05aClipRow): boolean => row.id === id);
      if (hit.length === 1) { out.push(new ClipBar(id, hit[0], false)); }
    }
    const tmall: Fx05aClipRow[] = rows.filter((row: Fx05aClipRow): boolean => row.id === 'tmall');
    if (tmall.length === 1) { out.push(new ClipBar('tmall-legacy', tmall[0], true)); }
  } catch (error) {
    // 链路抛错时不渲染提示条：设备用例先核 fx05a-clip-logic 的结果，会带着错误信息红。
  }
  return out;
}

/** 设备上（真实 ArkTS 运行时）跑一遍纯逻辑断言，结果交给 UiTest 读。 */
function clipLogic(): string {
  try {
    const failures: string[] = fx05aClipFailures();
    return failures.length === 0 ? 'FX05A_CLIP_LOGIC OK ' + FX05A_CLIP_SAMPLES.length : 'FX05A_CLIP_LOGIC FAIL ' + failures.join(' / ');
  } catch (error) {
    return 'FX05A_CLIP_LOGIC ERROR ' + (error as Error).message;
  }
}

function text(value: Object | undefined): string {
  if (value === undefined || value === null) { return '?'; }
  return String(value);
}

/** 组件树节点的属性表：$attrs（getInspectorTree / getFilteredInspectorTreeById 的常见形态），没有就用节点本身。 */
function attrsOf(node: Record<string, Object>): Record<string, Object> {
  return node['$attrs'] !== undefined ? node['$attrs'] as Record<string, Object> : node;
}

function typeOf(node: Record<string, Object>): string {
  return text(node['$type'] !== undefined ? node['$type'] : node['type']);
}

function childrenOf(node: Record<string, Object>): Record<string, Object>[] {
  const children: Object | undefined = node['$children'] !== undefined ? node['$children'] : node['children'];
  if (children === undefined || children === null || !Array.isArray(children)) { return []; }
  return (children as Object[]).map((child: Object): Record<string, Object> => child as Record<string, Object>);
}

/** 字符串属性；缺失记为空串（读屏模拟里「没设」与「设了空串」等价）。 */
function stringAttr(node: Record<string, Object>, key: string): string {
  const value: Object | undefined = attrsOf(node)[key];
  return value === undefined || value === null ? '' : String(value);
}

/** 在整棵组件树里按 id 找节点（v2：用 getInspectorTree 的全量属性，过滤版树可能不带无障碍属性）。 */
function findById(node: Record<string, Object>, id: string): Record<string, Object> | undefined {
  if (stringAttr(node, 'id') === id) { return node; }
  for (const child of childrenOf(node)) {
    const hit: Record<string, Object> | undefined = findById(child, id);
    if (hit !== undefined) { return hit; }
  }
  return undefined;
}

/**
 * 把 ArkUI 组件树压成「类型:无障碍级别:成组:祖先已隐藏」的序列，交给 UiTest 读。
 * 祖先已隐藏 = 某个祖先的 accessibilityLevel 是 no-hide-descendants。属性名缺失记为「?」，由用例判红（不当成通过）。
 */
function summarize(node: Record<string, Object>, hiddenByAncestor: boolean, out: string[]): void {
  const attrs: Record<string, Object> = attrsOf(node);
  const level: string = text(attrs['accessibilityLevel']);
  out.push(typeOf(node) + ':' + level + ':' + text(attrs['accessibilityGroup']) + ':' + String(hiddenByAncestor));
  for (const child of childrenOf(node)) {
    summarize(child, hiddenByAncestor || level === 'no-hide-descendants', out);
  }
}

/** 成组节点没设 accessibilityText 时，读屏合并朗读的子孙文字（跳过 level no / no-hide-descendants 的节点本身）。 */
function groupText(node: Record<string, Object>, out: string[]): void {
  for (const child of childrenOf(node)) {
    const level: string = stringAttr(child, 'accessibilityLevel');
    if (level === 'no-hide-descendants') { continue; }
    if (level !== 'no') {
      const label: string = stringAttr(child, 'accessibilityText');
      if (label.length > 0) { out.push(label); continue; }
      if (typeOf(child) === 'Text' && stringAttr(child, 'content').length > 0) { out.push(stringAttr(child, 'content')); }
    }
    groupText(child, out);
  }
}

/**
 * v2 读屏单元：按组件树上声明的无障碍属性，模拟屏幕朗读会停留并读出的单元（UiTest 的 getText / getDescription
 * 读不到 accessibilityText，见 tests-harmony-handback v2 节）。规则：
 *  - no-hide-descendants：整棵子树不读；no：自身不读，子孙照常；
 *  - accessibilityGroup(true)：整组一个单元，读 accessibilityText，没有就合并子孙文字，子孙不再单独成单元；
 *  - 其他节点：有 accessibilityText 读它，否则 Text 读 content；未隐藏的 Image 也是一个可聚焦单元（记 IMAGE）。
 * 每个单元记「类型=文字」，文字 encodeURIComponent。属性键缺失时按「没设」处理，读不出平台名即红（不放行）。
 */
function announce(node: Record<string, Object>, out: string[]): void {
  const level: string = stringAttr(node, 'accessibilityLevel');
  if (level === 'no-hide-descendants') { return; }
  const type: string = typeOf(node);
  if (level !== 'no') {
    const label: string = stringAttr(node, 'accessibilityText');
    if (stringAttr(node, 'accessibilityGroup') === 'true') {
      const parts: string[] = [];
      if (label.length === 0) { groupText(node, parts); }
      out.push(type + '=' + encodeURIComponent(label.length > 0 ? label : parts.join('')));
      return;
    }
    if (label.length > 0) {
      out.push(type + '=' + encodeURIComponent(label));
    } else if (type === 'Text' && stringAttr(node, 'content').length > 0) {
      out.push(type + '=' + encodeURIComponent(stringAttr(node, 'content')));
    } else if (type === 'Image') {
      out.push('Image=IMAGE');
    }
  }
  for (const child of childrenOf(node)) {
    announce(child, out);
  }
}

@Entry
@ComponentV2
struct Fx05aFixture {
  @Local mode: string = 'badges';
  @Local inspected: string = '';
  private clips: ClipBar[] = clipBars();
  private clipResult: string = clipLogic();

  private wrapperIds(): string[] {
    if (this.mode === 'badges') { return FX05A_BADGES.map((row: BadgeCase): string => 'fx05a-badge-' + row.id); }
    if (this.mode === 'icons') { return FX05A_ICONS.map((row: IconCase): string => 'fx05a-icon-' + row.id); }
    if (this.mode === 'clips') { return this.clips.map((bar: ClipBar): string => 'fx05a-clip-' + bar.id); }
    return FX05A_CARDS.map((row: string[]): string => 'fx05a-card-' + row[0]);
  }

  /** 包裹节点的组件树：优先全量树（getInspectorTree，带全部属性），找不到再用过滤版（v1 写法）。 */
  private wrapperTree(id: string): Record<string, Object> {
    const raw: Object = getInspectorTree();
    const tree: Record<string, Object> = (typeof raw === 'string' ? JSON.parse(raw as string) : raw) as Record<string, Object>;
    const found: Record<string, Object> | undefined = findById(tree, id);
    if (found !== undefined) { return found; }
    return JSON.parse(this.getUIContext().getFilteredInspectorTreeById(id, 0)) as Record<string, Object>;
  }

  private inspect(): void {
    const parts: string[] = [];
    for (const id of this.wrapperIds()) {
      const nodes: string[] = [];
      try {
        summarize(this.wrapperTree(id), false, nodes);
      } catch (error) {
        nodes.push('ERROR:' + (error as Error).message);
      }
      parts.push(id + '=' + nodes.join(';'));
    }
    this.inspected = parts.join('|');
  }

  private announceAll(): void {
    const parts: string[] = [];
    for (const id of this.wrapperIds()) {
      const units: string[] = [];
      try {
        announce(this.wrapperTree(id), units);
      } catch (error) {
        units.push('ERROR=' + encodeURIComponent((error as Error).message));
      }
      parts.push(id + '=' + units.join(';'));
    }
    this.inspected = parts.join('|');
  }

  build() {
    Column({ space: 8 }) {
      // v2：按钮定宽 32vp、可换行（设备实测一行放 7 个默认宽度按钮时最后一个出屏，UiTest 找不到）。
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(['badges', 'icons', 'cards', 'clips'], (name: string) => {
          Button(name.substring(0, 1)).fontSize(12).width(32).height(32).padding(0).margin(2).id('fx05a-case-' + name).onClick(() => {
            this.mode = name;
            this.inspected = '';
          })
        })
        Button('浅').fontSize(12).width(32).height(32).padding(0).margin(2).id('fx05a-light').onClick(() => {
          this.getUIContext().getHostContext()?.getApplicationContext()
            .setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
        })
        Button('深').fontSize(12).width(32).height(32).padding(0).margin(2).id('fx05a-dark').onClick(() => {
          this.getUIContext().getHostContext()?.getApplicationContext()
            .setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
        })
        Button('树').fontSize(12).width(32).height(32).padding(0).margin(2).id('fx05a-inspect-run').onClick(() => { this.inspect(); })
        Button('读').fontSize(12).width(32).height(32).padding(0).margin(2).id('fx05a-announce-run').onClick(() => { this.announceAll(); })
      }
      Text(this.inspected).fontSize(8).maxLines(1).id('fx05a-inspect-out')
      if (this.mode === 'badges') {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(FX05A_BADGES, (row: BadgeCase) => {
            Row() {
              if (row.legacy) {
                PlatformBadge({ label: row.label })
              } else {
                PlatformBadge({ label: row.label, platform: row.platform, remoteUrl: row.remoteUrl })
              }
            }
            .margin(6)
            .id('fx05a-badge-' + row.id)
          }, (row: BadgeCase): string => row.id)
        }.width('100%')
      } else if (this.mode === 'icons') {
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
          ForEach(FX05A_ICONS, (row: IconCase) => {
            Row() {
              PlatformIcon({ platform: row.platform, iconSize: row.size, remoteUrl: row.remoteUrl })
            }
            .margin(6)
            .id('fx05a-icon-' + row.id)
          }, (row: IconCase): string => row.id)
          ForEach(FX05A_EMPTY_ICONS, (row: IconCase) => {
            Stack() {
              PlatformIcon({ platform: row.platform, iconSize: row.size })
            }
            .width(60)
            .height(60)
            .margin(6)
            .backgroundColor(CouliColors.backgroundCanvas)
            .id('fx05a-slot-' + row.id)
          }, (row: IconCase): string => row.id)
        }.width('100%')
      } else if (this.mode === 'clips') {
        Text(this.clipResult).fontSize(8).maxLines(1).id('fx05a-clip-logic')
        ForEach(this.clips, (bar: ClipBar) => {
          Column() {
            if (bar.legacy) {
              ClipboardPromptBar({
                text: bar.row.title, detail: bar.row.detail, badge: bar.row.badge, barLabel: bar.row.label,
                actionText: '查返利', actionLabel: '查返利', closeLabel: '关闭', barId: 'fx05a_clip_' + bar.id
              })
            } else {
              ClipboardPromptBar({
                text: bar.row.title, detail: bar.row.detail, badge: bar.row.badge, badgePlatform: bar.row.key,
                barLabel: bar.row.label, actionText: '查返利', actionLabel: '查返利', closeLabel: '关闭',
                barId: 'fx05a_clip_' + bar.id
              })
            }
          }
          .width('100%')
          .margin({ top: 4, bottom: 4 })
          .id('fx05a-clip-' + bar.id)
        }, (bar: ClipBar): string => bar.id)
      } else {
        ForEach(FX05A_CARDS, (row: string[]) => {
          Column() {
            ProductCard({ data: cardData(row[0], row[1]), variant: ProductCardVariant.LIST })
          }
          .width('100%')
          .id('fx05a-card-' + row[0])
        }, (row: string[]): string => row[0])
      }
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor(CouliColors.backgroundCanvas)
    .id('fx05a-fixture')
  }
}
