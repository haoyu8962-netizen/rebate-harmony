// HM-L2-BUTTON-harmony 设备用例（测试作者 v1，先红；实现方不改本文件，有问题走「需要编排裁定」）。
// 共用套件 Ds02L2Ui（README ⑩ / D10-1177）：本文件由本单先建；CARD 单首次在 entry List.test.ets 注册 ds02L2UiTest()，
// 集成时把各单的段并进同一文件（本单的段 = ds02L2UiButtonCases()，自带 beforeAll / afterAll，助手都在 L2ButtonRig 里，不与别的段撞名）。
// 子集跑：COULI_HM_TEST_FILTER class=Ds02L2Ui（Hypium ClassFilter 按 describe 名精确相等，所以各单的 describe 都叫 'Ds02L2Ui'；
// 核对的是 SDK 自带 hypium 1.0.0 的 src/module/config/Filter.js，项目依赖 1.0.24，设备上未核）。
// 依据：NATIVE/HM-L2-BATCH1/brief-BUTTON.md §3「设备」四条；查找方式照 Ds02Ui.test.ets（open 直达 couli.ds02.component、
// sample 按 catalog-control / catalog-sample id、FlakeKit.captureChecked 取色、Ds02UiSession 任务队列）。
// 不写：页面取色、Hm07v* / Me12* 页面按钮（FREEZE 换值）。
//
// 本套件要的目录接口（实现方加，staging 目录，书 §2.5 + 交回 B9）：
//   ① CatalogManifest：BuyButton 增 m(['single'], ['off-shelf'])（样例 = BuyButton DISABLED + retryText「商品已下架」）；
//   ② CatalogDetail：CouliButton / BuyButton 详情页各有点按计数 Text，id 'catalog-events/CouliButton' / 'catalog-events/BuyButton'
//      （同 'catalog-events/OAuthButton' 写法），样例 onTap 里 +1。
// 现树上的红因：①② 都没有（off-shelf 样例与计数节点找不到）；CouliButton 尚无 buttonStyle 不影响本套件的几何 / 取色判据。
// 测试 v4（D10-1238）：l2button_04 禁用底改为「0.4 × 令牌 + 0.6 × 所在底色令牌」（接受鸿蒙系统禁用透明度）；
// node / find / open / buyButton 的断言与等待失败信息带上节点 id（只改诊断，判据不变）。
import { describe, it as hypiumIt, expect, beforeAll, afterAll, beforeEach, afterEach } from '@ohos/hypium';
import { abilityDelegatorRegistry, Driver, ON, On, Component, Rect } from '@kit.TestKit';
import { display } from '@kit.ArkUI';
import { EXPECTED_COLORS, ExpectedColor } from './Ds02Expected';
import { runUiTask, drainUiTasks, searchUiComponent } from './Ds02UiSession';
import { captureChecked, isNoCandidates, scene, Shot, trace } from './FlakeKit';

const COULI_BUTTON: string = 'CouliButton';
const BUY_BUTTON: string = 'BuyButton';
/** CatalogManifest 的 CouliButton 两组矩阵（目录现行写法，DS-02 inventory.tsv 第 4–5 行）。 */
const FULL_VARIANTS: string[] = ['primary-standard', 'primary-compact', 'primary-full', 'secondary-standard', 'secondary-compact',
  'secondary-full'];
const FULL_STATES: string[] = ['default', 'pressed', 'disabled', 'loading'];
const SHORT_VARIANTS: string[] = ['text-standard', 'text-compact', 'onSolid-compact'];
const SHORT_STATES: string[] = ['default', 'pressed', 'disabled'];
const BUY_VARIANTS: string[] = ['single', 'range', 'no-rebate'];
const BUY_STATES: string[] = ['default', 'loading', 'disabled', 'retry-later'];
/** 期望文字：目录样例的动词（PriceTerms.buyCoupon / buyNoRebate）与契约字典原文。 */
const VERB_COUPON: string = '领券购买';
const VERB_NO_REBATE: string = '去购买（无返利）';
const RETRY_LATER_TEXT: string = '稍后再试';
const OFF_SHELF_TEXT: string = '商品已下架';
const SINGLE_TITLE: string = '领券购买 · 预估返 ¥2.69';
/** 取色容差（书 §3：±8）。 */
const COLOR_TOLERANCE: number = 8;
/** 鸿蒙系统 Button 不可用时整体乘的透明度（ArkUI ButtonPattern::HandleEnabled → ButtonTheme::GetBgDisabledAlpha，
 *  impl-device-r2 实测 0.4）。D10-1238：禁用观感跟系统走，不再要求禁用底逐值等于令牌。 */
const DISABLED_ALPHA: number = 0.4;
/** 目录样例所在底色的令牌：CouliButton 样例直接画在目录页画布上（impl-device-r2 深色读数 35/32/29 = 0.4 × 禁用令牌 + 0.6 × 画布）。 */
const CATALOG_BASE_KEY: string = 'background.canvas';
const MIN_TARGET_VP: number = 48;

const driver: Driver = Driver.create();

function it(name: string, flags: number, body: () => Promise<void>): void {
  hypiumIt(name, flags, async (): Promise<void> => { await runUiTask(driver, body); });
}

class Rgb {
  r: number;
  g: number;
  b: number;

  constructor(r: number, g: number, b: number) {
    this.r = r;
    this.g = g;
    this.b = b;
  }
}

/** 本段的设备助手（集成时与别的段同文件，不用模块级同名函数）。 */
class L2ButtonRig {
  static async idle(): Promise<void> {
    expect(await driver.waitForIdle(200, 8000)).assertTrue();
  }

  static async node(id: string): Promise<Component> {
    let found: Component | null = null;
    try {
      found = await driver.waitForComponent(ON.id(id), 8000);
    } catch (e) {
      throw new Error('L2BUTTON_NODE_WAIT_FAILED id=' + id + ' ' + String(e));
    }
    const ok: boolean = found !== null && found !== undefined;
    expect('node id=' + id + ' found in 8000ms ' + ok).assertEqual('node id=' + id + ' found in 8000ms true');
    return found as Component;
  }

  static async click(id: string): Promise<void> {
    await (await L2ButtonRig.node(id)).click();
    await L2ButtonRig.idle();
  }

  static async setFont(scale: string): Promise<void> {
    await L2ButtonRig.click('catalog-font-' + scale);
    const label: string = scale === '200' ? '字号 ×2.00' : '字号 ×1.00';
    const shown: Component = await driver.waitForComponent(ON.text(label), 5000);
    expect(shown !== null && shown !== undefined).assertTrue();
    await L2ButtonRig.idle();
  }

  static async index(): Promise<void> {
    for (let attempt: number = 0; attempt < 5; attempt++) {
      const found: Component = await driver.findComponent(ON.id('catalog-index'));
      if (found !== null && found !== undefined) { return; }
      await driver.pressBack();
      await L2ButtonRig.idle();
      const back: Component = await driver.waitForComponent(ON.id('catalog-index'), 3000);
      if (back !== null && back !== undefined) { return; }
    }
    await L2ButtonRig.node('catalog-index');
  }

  /** 同 Ds02Ui.open：先直达（couli.ds02.component），拿不到再回索引有界搜索。 */
  static async open(component: string): Promise<void> {
    const current: Component = await driver.findComponent(ON.id('catalog-cases/' + component));
    if (current !== null && current !== undefined) { return; }
    await abilityDelegatorRegistry.getAbilityDelegator().startAbility({
      bundleName: 'com.couli.hm', moduleName: 'entry', abilityName: 'EntryAbility',
      parameters: { 'couli.ds02.component': component }
    });
    const direct: Component = await driver.waitForComponent(ON.id('catalog-cases/' + component), 8000);
    if (direct !== null && direct !== undefined) { await L2ButtonRig.idle(); return; }
    await L2ButtonRig.index();
    let entry: Component = await driver.findComponent(ON.id('catalog-entry/' + component));
    if (entry === null || entry === undefined) {
      entry = await searchUiComponent(driver, ON.id('catalog-index'), ON.id('catalog-entry/' + component));
    }
    const entryOk: boolean = entry !== null && entry !== undefined;
    expect('open entry id=catalog-entry/' + component + ' found ' + entryOk)
      .assertEqual('open entry id=catalog-entry/' + component + ' found true');
    await entry.click();
    await L2ButtonRig.node('catalog-cases/' + component);
  }

  /** 同 Ds02Ui.sample：已在可视区就直接用，否则在样例列表里有界小步搜索。 */
  static async find(component: string, id: string): Promise<Component> {
    const list: Component = await L2ButtonRig.node('catalog-cases/' + component);
    const near: Component = await driver.findComponent(ON.id(id));
    if (near !== null && near !== undefined) {
      const view: Rect = await list.getBounds();
      const r: Rect = await near.getBounds();
      const cx: number = (r.left + r.right) / 2;
      const cy: number = (r.top + r.bottom) / 2;
      if (cx > view.left && cx < view.right && cy > view.top && cy < view.bottom && r.right > r.left && r.bottom > r.top) {
        return near;
      }
    }
    const found: Component = await searchUiComponent(driver, ON.id('catalog-cases/' + component), ON.id(id));
    const ok: boolean = found !== null && found !== undefined;
    expect('find id=' + id + ' in catalog-cases/' + component + ' found ' + ok)
      .assertEqual('find id=' + id + ' in catalog-cases/' + component + ' found true');
    return found;
  }

  /** 同 Ds02Ui.measureSample：量几何前把目标整块拉进列表可视区（bounds 只含可见部分）。 */
  static async fullyVisible(component: string, id: string): Promise<Component> {
    for (let attempt: number = 0; attempt < 8; attempt++) {
      const found: Component = await L2ButtonRig.find(component, id);
      const view: Rect = await (await L2ButtonRig.node('catalog-cases/' + component)).getBounds();
      const r: Rect = await found.getBounds();
      if (r.top > view.top && r.bottom < view.bottom && r.bottom > r.top) { return found; }
      const x: number = Math.floor(view.left + (view.right - view.left) * 0.02);
      const from: number = Math.floor((view.top + view.bottom) / 2);
      const limit: number = (view.bottom - view.top) * 0.35;
      const shift: number = Math.max(-limit, Math.min(limit, (r.top + r.bottom) / 2 - from));
      await driver.swipe(x, from, x, Math.floor(from - shift), 600);
      await L2ButtonRig.idle();
    }
    throw new Error('L2BUTTON_SAMPLE_NOT_FULLY_VISIBLE: ' + id);
  }

  static controlId(variant: string, state: string): string {
    return 'catalog-control/' + COULI_BUTTON + '/' + variant + '/' + state;
  }

  static textId(variant: string, state: string): string {
    return 'catalog-text/' + COULI_BUTTON + '/' + variant + '/' + state;
  }

  static buySampleId(variant: string, state: string): string {
    return 'catalog-sample/' + BUY_BUTTON + '/' + variant + '/' + state;
  }

  /** BuyButton 样例框里唯一的系统 Button。 */
  static async buyButton(variant: string, state: string): Promise<Component> {
    const sampleId: string = L2ButtonRig.buySampleId(variant, state);
    await L2ButtonRig.fullyVisible(BUY_BUTTON, sampleId);
    const buttons: Component[] = await driver.findComponents(ON.type('Button').within(ON.id(sampleId)));
    const n: number = buttons === null || buttons === undefined ? 0 : buttons.length;
    expect('buyButton id=' + sampleId + ' Button ' + n).assertEqual('buyButton id=' + sampleId + ' Button 1');
    return buttons[0];
  }

  /** BuyButton 样例框里的文字（去掉样例框标题「变体 · 状态」）。 */
  static async buyTexts(variant: string, state: string): Promise<string[]> {
    const nodes: Component[] = await driver.findComponents(ON.type('Text').within(ON.id(L2ButtonRig.buySampleId(variant, state))));
    const out: string[] = [];
    for (const n of (nodes ?? [])) {
      const t: string = await n.getText();
      if (t !== variant + ' · ' + state) { out.push(t); }
    }
    return out;
  }

  static async count(component: string): Promise<number> {
    const value: string = await (await L2ButtonRig.node('catalog-events/' + component)).getText();
    const n: number = Number(value);
    expect(Number.isInteger(n)).assertTrue();
    return n;
  }

  /** 计数轮询到 want 或超时，返回最后读到的值。 */
  static async countSoon(component: string, want: number, timeoutMs: number): Promise<number> {
    const end: number = Date.now() + timeoutMs;
    for (;;) {
      const n: number = await L2ButtonRig.count(component);
      if (n === want || Date.now() >= end) { return n; }
      await driver.delayMs(100);
    }
  }

  /** 连点 3 次（不等 idle，模拟快速连点），再留 500ms 给迟到的回调。 */
  static async tapThrice(target: Component): Promise<void> {
    const r: Rect = await target.getBounds();
    const x: number = Math.floor((r.left + r.right) / 2);
    const y: number = Math.floor((r.top + r.bottom) / 2);
    for (let i: number = 0; i < 3; i++) { await driver.click(x, y); }
    await L2ButtonRig.idle();
    await driver.delayMs(500);
  }

  static density(): number {
    return display.getDefaultDisplaySync().densityPixels;
  }

  static token(key: string, dark: boolean): Rgb {
    const rows: ExpectedColor[] = EXPECTED_COLORS.filter((row: ExpectedColor): boolean => row.key === key);
    expect(rows.length).assertEqual(1);
    const v: number = Number.parseInt((dark ? rows[0].dark : rows[0].light).substring(1), 16);
    return new Rgb((v >> 16) & 255, (v >> 8) & 255, v & 255);
  }

  static pixel(shot: Shot, x: number, y: number): Rgb {
    const o: number = (y * shot.width + x) * 4;
    return new Rgb(shot.bytes[o], shot.bytes[o + 1], shot.bytes[o + 2]);
  }

  static near(got: Rgb, want: Rgb): boolean {
    return Math.abs(got.r - want.r) <= COLOR_TOLERANCE && Math.abs(got.g - want.g) <= COLOR_TOLERANCE
      && Math.abs(got.b - want.b) <= COLOR_TOLERANCE;
  }

  static rgbText(c: Rgb): string {
    return c.r + '/' + c.g + '/' + c.b;
  }

  /** top 以不透明度 alpha 叠在 base 上的合成色（逐通道 alpha × top + (1 − alpha) × base，四舍五入到整数）。 */
  static over(top: Rgb, base: Rgb, alpha: number): Rgb {
    return new Rgb(Math.round(alpha * top.r + (1 - alpha) * base.r), Math.round(alpha * top.g + (1 - alpha) * base.g),
      Math.round(alpha * top.b + (1 - alpha) * base.b));
  }

  /** 按钮底色等于令牌 key（±8）。 */
  static async assertFill(target: Component, key: string, dark: boolean, tag: string): Promise<void> {
    await L2ButtonRig.assertFillRgb(target, key, L2ButtonRig.token(key, dark), tag);
  }

  /** 禁用底（D10-1238）：系统把不可用 Button 整体乘 DISABLED_ALPHA，期望 = 0.4 × key 令牌 + 0.6 × 所在底色令牌 baseKey（±8，同现行）。 */
  static async assertDisabledFill(target: Component, key: string, baseKey: string, dark: boolean, tag: string): Promise<void> {
    const want: Rgb = L2ButtonRig.over(L2ButtonRig.token(key, dark), L2ButtonRig.token(baseKey, dark), DISABLED_ALPHA);
    await L2ButtonRig.assertFillRgb(target, DISABLED_ALPHA + '×' + key + '+' + (1 - DISABLED_ALPHA) + '×' + baseKey, want, tag);
  }

  /** 按钮底色：取 (20%, 20%)（避开居中文字与圆角，同 Ds02Ui.assertButtonSurface 取点），与 want 逐通道比 ±8。 */
  static async assertFillRgb(target: Component, label: string, want: Rgb, tag: string): Promise<void> {
    expect(await target.getType()).assertEqual('Button');
    const shot: Shot = await captureChecked(driver, await target.getBounds(), 'l2button-' + tag);
    const got: Rgb = L2ButtonRig.pixel(shot, Math.floor(shot.width * 0.2), Math.floor(shot.height * 0.2));
    expect(tag + ' ' + label + ' got ' + L2ButtonRig.rgbText(got) + ' want ' + L2ButtonRig.rgbText(want) + ' ±' + COLOR_TOLERANCE + ' '
      + L2ButtonRig.near(got, want)).assertEqual(tag + ' ' + label + ' got ' + L2ButtonRig.rgbText(got) + ' want '
      + L2ButtonRig.rgbText(want) + ' ±' + COLOR_TOLERANCE + ' true');
  }

  /** 次按钮描边：中线上从左边缘往里 1.5vp 内，有一个像素接近 border.control（抗锯齿取最近的一个）。 */
  static async assertBorder(target: Component, dark: boolean, tag: string): Promise<void> {
    const shot: Shot = await captureChecked(driver, await target.getBounds(), 'l2button-' + tag);
    const want: Rgb = L2ButtonRig.token('border.control', dark);
    const y: number = Math.floor(shot.height / 2);
    const span: number = Math.max(2, Math.ceil(L2ButtonRig.density() * 1.5));
    let best: Rgb = L2ButtonRig.pixel(shot, 0, y);
    let bestDiff: number = 1000;
    for (let x: number = 0; x < Math.min(span, shot.width); x++) {
      const c: Rgb = L2ButtonRig.pixel(shot, x, y);
      const d: number = Math.max(Math.abs(c.r - want.r), Math.abs(c.g - want.g), Math.abs(c.b - want.b));
      if (d < bestDiff) { bestDiff = d; best = c; }
    }
    expect(tag + ' border.control got ' + L2ButtonRig.rgbText(best) + ' want ' + L2ButtonRig.rgbText(want) + ' '
      + L2ButtonRig.near(best, want)).assertEqual(tag + ' border.control got ' + L2ButtonRig.rgbText(best) + ' want '
      + L2ButtonRig.rgbText(want) + ' true');
  }

  static assertTarget(r: Rect, tag: string): void {
    const d: number = L2ButtonRig.density();
    const w: number = (r.right - r.left) / d;
    const h: number = (r.bottom - r.top) / d;
    expect(tag + ' 命中 ' + w.toFixed(1) + 'x' + h.toFixed(1) + 'vp ≥48 ' + (w >= MIN_TARGET_VP && h >= MIN_TARGET_VP))
      .assertEqual(tag + ' 命中 ' + w.toFixed(1) + 'x' + h.toFixed(1) + 'vp ≥48 true');
  }

  static assertInside(inner: Rect, outer: Rect, tag: string): void {
    const ok: boolean = inner.left >= outer.left - 1 && inner.right <= outer.right + 1 && inner.top >= outer.top - 1
      && inner.bottom <= outer.bottom + 1 && inner.right > inner.left && inner.bottom > inner.top;
    expect(tag + ' 文字整块在按钮内 ' + ok).assertEqual(tag + ' 文字整块在按钮内 true');
  }

  /** 同 Ds02Ui beforeAll：有界重拉 → 首页「Debug panel」→「Component catalog」；隐私首启点「不同意」进基本模式。 */
  static async enterCatalog(): Promise<void> {
    const trail: string[] = [];
    let ready: boolean = false;
    for (let attempt: number = 0; attempt < 8 && !ready; attempt++) {
      await abilityDelegatorRegistry.getAbilityDelegator().startAbility({
        bundleName: 'com.couli.hm', moduleName: 'entry', abilityName: 'EntryAbility'
      });
      await driver.delayMs(500);
      await L2ButtonRig.idle();
      let list: Component | null = null;
      for (let poll: number = 0; poll < 16 && list === null; poll++) {
        for (const label of ['不同意', '仍不同意']) {
          const privacy: Component = await driver.findComponent(ON.text(label));
          if (privacy !== null && privacy !== undefined) { await privacy.click(); await L2ButtonRig.idle(); }
        }
        const already: Component = await driver.findComponent(ON.id('catalog-index'));
        if (already !== null && already !== undefined) { return; }
        const found: Component = await driver.findComponent(ON.id('home_list'));
        if (found !== null && found !== undefined) { list = found; } else { await driver.delayMs(500); }
      }
      if (list === null) { trail.push(attempt + ':no-home_list'); continue; }
      try {
        const entry: Component = await searchUiComponent(driver, ON.id('home_list'), ON.text('Debug panel'));
        if (entry !== null && entry !== undefined) { await entry.click(); ready = true; }
      } catch (e) {
        const text: string = String(e);
        if (!isNoCandidates(e as Object) && text.indexOf('DS02_UI_CONTAINER_GONE') < 0 && text.indexOf('DS02_UI_SEARCH_EXHAUSTED') < 0) {
          throw e as Error;
        }
        trail.push(attempt + ':miss');
      }
    }
    expect(ready ? 'ready' : 'L2BUTTON_NOT_READY ' + trail.join(' ') + ' ' + (await scene(driver))).assertEqual('ready');
    await L2ButtonRig.idle();
    const scroll: Component = await driver.waitForComponent(ON.type('Scroll'), 8000);
    expect(scroll !== null && scroll !== undefined).assertTrue();
    const catalog: Component = await searchUiComponent(driver, ON.type('Scroll'), ON.text('Component catalog'));
    expect(catalog !== null && catalog !== undefined).assertTrue();
    await catalog.click();
    trace('L2BUTTON_BEFOREALL_TRAIL ' + (trail.length === 0 ? '-' : trail.join(' ')));
    await L2ButtonRig.node('catalog-index');
  }
}

/** HM-L2-BUTTON 的段（集成时由 ds02L2UiTest() 调用）。 */
export function ds02L2UiButtonCases(): void {
  describe('Ds02L2Ui', () => {
    beforeEach(async (): Promise<void> => { await drainUiTasks(driver); });
    afterEach(async (): Promise<void> => { await drainUiTasks(driver); });
    beforeAll(async (): Promise<void> => {
      await runUiTask(driver, async (): Promise<void> => { await L2ButtonRig.enterCatalog(); });
    });
    afterAll(async (): Promise<void> => {
      await drainUiTasks(driver);
      await runUiTask(driver, async (): Promise<void> => {
        await L2ButtonRig.index();
        await L2ButtonRig.click('catalog-theme-light');
        await L2ButtonRig.setFont('100');
      });
    });

    // 书 §3 设备 ①：目录逐态渲染（CouliButton 全部变体 × 默认 / 按下 / 禁用 / 加载）。浅深两遍。
    // 判据：是系统 Button；默认 / 按下可用，禁用 / 加载不可用；加载内有系统 LoadingProgress、其余没有；文字节点有字。
    for (const mode of ['light', 'dark']) {
      it('l2button_01_couli_button_all_variants_states_render_system_button_' + mode, 0, async (): Promise<void> => {
        await L2ButtonRig.open(COULI_BUTTON);
        await L2ButtonRig.click('catalog-theme-' + mode);
        await L2ButtonRig.setFont('100');
        const groups: string[][][] = [[FULL_VARIANTS, FULL_STATES], [SHORT_VARIANTS, SHORT_STATES]];
        for (const group of groups) {
          for (const variant of group[0]) {
            for (const state of group[1]) {
              const tag: string = variant + '/' + state;
              const button: Component = await L2ButtonRig.find(COULI_BUTTON, L2ButtonRig.controlId(variant, state));
              expect(tag + ' type ' + (await button.getType())).assertEqual(tag + ' type Button');
              const inactive: boolean = state === 'disabled' || state === 'loading';
              expect(tag + ' enabled ' + (await button.isEnabled())).assertEqual(tag + ' enabled ' + !inactive);
              const spinners: Component[] = await driver.findComponents(ON.type('LoadingProgress')
                .within(ON.id(L2ButtonRig.controlId(variant, state))));
              const spinning: number = spinners === null || spinners === undefined ? 0 : spinners.length;
              expect(tag + ' LoadingProgress ' + spinning).assertEqual(tag + ' LoadingProgress ' + (state === 'loading' ? 1 : 0));
              const text: Component = await L2ButtonRig.node(L2ButtonRig.textId(variant, state));
              expect((await text.getText()).length > 0).assertTrue();
            }
          }
        }
      });
    }

    // 书 §3 设备 ①：BuyButton 默认 / 加载 / 禁用 / 稍后再试 / 下架（D10-907：下架 = 禁用 +「商品已下架」）。
    // 禁用（非下架）显示动词，不得出现「稍后再试」（ProductCard.ets:369 兜底去掉后的目录同口径）。
    it('l2button_02_buy_button_states_text_and_enabled', 0, async (): Promise<void> => {
      await L2ButtonRig.open(BUY_BUTTON);
      await L2ButtonRig.click('catalog-theme-light');
      await L2ButtonRig.setFont('100');
      for (const variant of BUY_VARIANTS) {
        const verb: string = variant === 'no-rebate' ? VERB_NO_REBATE : VERB_COUPON;
        for (const state of BUY_STATES) {
          const tag: string = variant + '/' + state;
          const button: Component = await L2ButtonRig.buyButton(variant, state);
          expect(tag + ' enabled ' + (await button.isEnabled())).assertEqual(tag + ' enabled ' + (state === 'default'));
          const texts: string[] = await L2ButtonRig.buyTexts(variant, state);
          let want: string = verb;
          if (state === 'retry-later') { want = RETRY_LATER_TEXT; }
          if (state === 'default' && variant === 'single') { want = SINGLE_TITLE; }
          expect(tag + ' texts ' + JSON.stringify(texts) + ' has ' + want + ' ' + (texts.indexOf(want) >= 0))
            .assertEqual(tag + ' texts ' + JSON.stringify(texts) + ' has ' + want + ' true');
          if (state !== 'retry-later') {
            expect(tag + ' 无稍后再试 ' + (texts.indexOf(RETRY_LATER_TEXT) < 0)).assertEqual(tag + ' 无稍后再试 true');
          }
        }
      }
      const off: Component = await L2ButtonRig.buyButton('single', 'off-shelf');
      expect(await off.isEnabled()).assertFalse();
      const offTexts: string[] = await L2ButtonRig.buyTexts('single', 'off-shelf');
      expect('off-shelf ' + JSON.stringify(offTexts) + ' ' + (offTexts.indexOf(OFF_SHELF_TEXT) >= 0
        && offTexts.indexOf(RETRY_LATER_TEXT) < 0)).assertEqual('off-shelf ' + JSON.stringify(offTexts) + ' true');
    });

    // 书 §3 设备 ②：200% 不截断、命中 ≥ 48（取 bounds，同 hit-target-check.py / Ds02R1Assertions 口径）。
    // 不截断的结构证据：文字节点整块在按钮内、200% 时文字高度 > 100% 的 1.5 倍（UiTest 读不到省略号，同 Ds02Ui 的说明）。
    it('l2button_03_font_200_no_truncation_and_hit_target_48', 0, async (): Promise<void> => {
      await L2ButtonRig.open(COULI_BUTTON);
      await L2ButtonRig.click('catalog-theme-light');
      await L2ButtonRig.setFont('100');
      const variants: string[] = FULL_VARIANTS.concat(SHORT_VARIANTS);
      const normal: number[] = [];
      for (const variant of variants) {
        const text: Component = await L2ButtonRig.fullyVisible(COULI_BUTTON, L2ButtonRig.textId(variant, 'default'));
        const r: Rect = await text.getBounds();
        normal.push(r.bottom - r.top);
      }
      await L2ButtonRig.setFont('200');
      for (let i: number = 0; i < variants.length; i++) {
        const tag: string = variants[i] + '/default@200%';
        const button: Component = await L2ButtonRig.fullyVisible(COULI_BUTTON, L2ButtonRig.controlId(variants[i], 'default'));
        const outer: Rect = await button.getBounds();
        L2ButtonRig.assertTarget(outer, tag);
        const inner: Rect = await (await L2ButtonRig.node(L2ButtonRig.textId(variants[i], 'default'))).getBounds();
        L2ButtonRig.assertInside(inner, outer, tag);
        expect(tag + ' 文字放大 ' + ((inner.bottom - inner.top) > normal[i] * 1.5)).assertEqual(tag + ' 文字放大 true');
      }
      await L2ButtonRig.open(BUY_BUTTON);
      for (const state of ['default', 'off-shelf']) {
        const button: Component = await L2ButtonRig.buyButton('single', state);
        const outer: Rect = await button.getBounds();
        L2ButtonRig.assertTarget(outer, 'BuyButton single/' + state + '@200%');
        const texts: Component[] = await driver.findComponents(ON.type('Text').within(ON.id(L2ButtonRig.buySampleId('single', state))));
        let checked: number = 0;
        for (const t of (texts ?? [])) {
          const value: string = await t.getText();
          if (value === SINGLE_TITLE || value === OFF_SHELF_TEXT) {
            L2ButtonRig.assertInside(await t.getBounds(), outer, 'BuyButton single/' + state + '@200%');
            checked++;
          }
        }
        expect('BuyButton single/' + state + ' 文字节点 ' + checked).assertEqual('BuyButton single/' + state + ' 文字节点 1');
      }
      await L2ButtonRig.setFont('100');
    });

    // 书 §3 设备 ③：深浅取色是令牌角色（主按钮底、次按钮底与描边、禁用底，±8；FlakeKit.captureChecked 重拍口径）。
    // 禁用底（D10-1238）：= 0.4 × button.primary.disabled.background + 0.6 × background.canvas（系统禁用透明度，仍由令牌推出）。
    for (const mode of ['light', 'dark']) {
      it('l2button_04_token_roles_primary_secondary_disabled_' + mode, 0, async (): Promise<void> => {
        const dark: boolean = mode === 'dark';
        await L2ButtonRig.open(COULI_BUTTON);
        await L2ButtonRig.click('catalog-theme-' + mode);
        await L2ButtonRig.setFont('100');
        await L2ButtonRig.assertFill(await L2ButtonRig.fullyVisible(COULI_BUTTON, L2ButtonRig.controlId('primary-standard', 'default')),
          'button.primary.default.background', dark, 'primary-' + mode);
        const secondary: Component = await L2ButtonRig.fullyVisible(COULI_BUTTON, L2ButtonRig.controlId('secondary-standard', 'default'));
        await L2ButtonRig.assertFill(secondary, 'background.surface', dark, 'secondary-' + mode);
        await L2ButtonRig.assertBorder(secondary, dark, 'secondary-border-' + mode);
        await L2ButtonRig.assertDisabledFill(await L2ButtonRig.fullyVisible(COULI_BUTTON,
          L2ButtonRig.controlId('primary-standard', 'disabled')), 'button.primary.disabled.background', CATALOG_BASE_KEY, dark,
          'disabled-' + mode);
      });
    }

    // 书 §3 设备 ④：加载中 / 禁用 / 下架时连点 3 次 → 回调 0 次；正对照：可用时点 1 次 → +1（证明计数真接在 onTap 上）。
    // 紧凑按钮视觉 44：在视觉下沿外 1vp（命中区上下各扩 2vp 之内）点按也 +1（命中 ≥ 48，书 §2.1 hitRegion 不动）。
    it('l2button_05_rapid_taps_on_inactive_buttons_fire_zero_callbacks', 0, async (): Promise<void> => {
      await L2ButtonRig.open(COULI_BUTTON);
      await L2ButtonRig.click('catalog-theme-light');
      await L2ButtonRig.setFont('100');
      for (const state of ['loading', 'disabled']) {
        const before: number = await L2ButtonRig.count(COULI_BUTTON);
        await L2ButtonRig.tapThrice(await L2ButtonRig.fullyVisible(COULI_BUTTON, L2ButtonRig.controlId('primary-standard', state)));
        expect('CouliButton ' + state + ' 连点后计数 ' + (await L2ButtonRig.count(COULI_BUTTON)))
          .assertEqual('CouliButton ' + state + ' 连点后计数 ' + before);
      }
      const base: number = await L2ButtonRig.count(COULI_BUTTON);
      await (await L2ButtonRig.fullyVisible(COULI_BUTTON, L2ButtonRig.controlId('primary-standard', 'default'))).click();
      await L2ButtonRig.idle();
      expect(await L2ButtonRig.countSoon(COULI_BUTTON, base + 1, 3000)).assertEqual(base + 1);
      const compact: Component = await L2ButtonRig.fullyVisible(COULI_BUTTON, L2ButtonRig.controlId('primary-compact', 'default'));
      const r: Rect = await compact.getBounds();
      const d: number = L2ButtonRig.density();
      expect((r.bottom - r.top) / d < MIN_TARGET_VP).assertTrue();
      await driver.click(Math.floor((r.left + r.right) / 2), Math.floor(r.bottom + d));
      await L2ButtonRig.idle();
      expect(await L2ButtonRig.countSoon(COULI_BUTTON, base + 2, 3000)).assertEqual(base + 2);

      await L2ButtonRig.open(BUY_BUTTON);
      for (const state of ['loading', 'disabled', 'retry-later', 'off-shelf']) {
        const before: number = await L2ButtonRig.count(BUY_BUTTON);
        await L2ButtonRig.tapThrice(await L2ButtonRig.buyButton('single', state));
        expect('BuyButton ' + state + ' 连点后计数 ' + (await L2ButtonRig.count(BUY_BUTTON)))
          .assertEqual('BuyButton ' + state + ' 连点后计数 ' + before);
      }
      const buyBase: number = await L2ButtonRig.count(BUY_BUTTON);
      await (await L2ButtonRig.buyButton('single', 'default')).click();
      await L2ButtonRig.idle();
      expect(await L2ButtonRig.countSoon(BUY_BUTTON, buyBase + 1, 3000)).assertEqual(buyBase + 1);
    });
  });
}

// ================================================================ HM-L2-PRICE-TAG 的段（测试作者 v1，先红；实现方不改本段）
// 依据：NATIVE/HM-L2-BATCH1/brief-PRICE-TAG.md §3「设备」三条、§7 录屏；README 末节 D10-1177 ④⑤；03 §10.4（价格、返利金额 200% 不截断、
// 不重叠、不缩字号、不省略金额）。查找方式同上面 BUTTON 段（open 直达 couli.ds02.component、样例按 catalog-sample id、取色只经
// FlakeKit.captureChecked）。本段助手都在 L2PriceRig 里，不用 BUTTON 段的 L2ButtonRig（两段互不依赖）；共用的只有本文件模块级的
// driver / it / Rgb。
// 金额节点的找法与 README ⑤ 的两种结局无关：样例框里文字包含期望金额的 Text 节点，取文字最短的一个（拆成独立 Text 时就是金额本身；
// 探针不过、金额留在 Span 里时是「口径词 + 金额」那一个 Text）。只在节点文字恰好等于金额时才加判「金额一行、没被拆」。
// 数字过渡本身 UiTest 看不到（目视 / 录屏）；本段在两种结局下都只证状态：换值后原节点替换、过程中节点一直在、每张连拍都有字（不闪）。
// 减弱动态开关要改系统设置（API ≥ 23），设备上不切；策略由 Hypium L2PriceTag p3 + 宿主 check_l2_price.py P1-reduced / P1-policy 钉。
//
// 本段要的目录接口（实现方加，staging 目录；宿主 check_l2_price.py P8 钉前两条）：
//   ① CatalogManifest：RebateTag 增 m(['block'], ['normal'])（样例 = RebateTag tagSize BLOCK、RebateTagModel.make('normal', 269, 269, false)，
//      放在宽 160vp 的窄容器里，同首页网格窄卡 GUIDE §6「宽 < 180」）；DS-02 清单只加这 1 行（README ⑨，#24）。
//   ② CatalogDetail：PriceTag 与 RebateTag 详情页各有一个动作按钮 this.action('catalog-amount-toggle', '切换金额', …)，每点一次翻转
//      CatalogEvents 新增的 @Trace amountAlt: boolean。
//   ③ BusinessSample：amountAlt 为真时只改 state === 'normal' 的样例金额——PriceTag 主价（券后价）减 100 分（有券的券额 +100、无券的
//      券前价同减），RebateTag single / large / block 的 269 换成 369；其余样例（long-price、amount-hidden、range、wrap-at-dash 等）不变。
// 现树红因：②③ 没有（找不到 catalog-amount-toggle）、① 没有（找不到 block 样例）；01 / 03 的 PriceTag 部分与 RebateTag 既有行现树预期绿。

const PRICE_TAG: string = 'PriceTag';
const REBATE_TAG: string = 'RebateTag';
/** CatalogManifest 的 PriceTag 12 个变体（DS-02 inventory.tsv 第 49 行）。 */
const PRICE_VARIANTS: string[] = ['coupon-list', 'coupon-ai', 'coupon-detail', 'no-coupon-list', 'no-coupon-ai', 'no-coupon-detail',
  'pdd-list', 'pdd-ai', 'pdd-detail', 'presale-list', 'presale-ai', 'presale-detail'];
/** 金额隐藏防御态（D10-1177 ④ 原样保留）与不带金额的两种返利文字（契约字典 rebate_amount_unknown / rebate_login_to_view）。 */
const MASK_TEXT: string = '****';
const AMOUNT_UNKNOWN_TEXT: string = '可返利，金额以订单为准';
const LOGIN_TEXT: string = '登录查看返利';
/** 单值返利：目录 269 分，切换后 369 分（L2PriceTag p2 钉同一组字面量）。 */
const REBATE_SINGLE: string = '¥2.69';
const REBATE_SINGLE_ALT: string = '¥3.69';
/**
 * 金额 Text 在 200% 下：不缩字号（高 > 100% 的 1.5 倍）；金额一行没被拆（高 < 100% 的 2.6 倍，拆成两行至少约 3.5 倍）——
 * 只有放得下时才要求一行：100% 的单行宽 × 1.8（200% 下单行宽的保守下限）已超过样例框宽时，折行是 03 §10.4 允许的「放不下时换行」。
 */
const GROW_MIN: number = 1.5;
const ONE_LINE_MAX: number = 2.6;
const FIT_SCALE: number = 1.8;
const PRICE_COLOR_TOLERANCE: number = 8;
/** 连拍「有字」：框内至少有一个像素与左上角底色相差超过 40（任一通道）。 */
const INK_DELTA: number = 40;

class AmountHit {
  node: Component;
  text: string;
  rect: Rect;
  /** 所在样例框（amount() 填）。 */
  box: Rect | null = null;

  constructor(node: Component, text: string, rect: Rect) {
    this.node = node;
    this.text = text;
    this.rect = rect;
  }
}

class PriceCase {
  component: string;
  variant: string;
  state: string;
  amount: string;
  /** 只核「在样例框内」（区间在破折号处折行等，不核一行）。 */
  wrapAllowed: boolean;

  constructor(component: string, variant: string, state: string, amount: string, wrapAllowed: boolean) {
    this.component = component;
    this.variant = variant;
    this.state = state;
    this.amount = amount;
    this.wrapAllowed = wrapAllowed;
  }
}

/** PriceTag 样例的主价（CatalogSampleViews.BusinessSample.price()；L2PriceTag p1 钉同一组字面量）。alt = 切换金额后的主价。 */
function priceAmount(variant: string, state: string, alt: boolean): string {
  const long: boolean = state === 'long-price';
  if (variant.startsWith('no-coupon')) { return long ? '¥100999.99' : (alt ? '¥38.9' : '¥39.9'); }
  if (variant.startsWith('pdd')) { return long ? '¥100996.99' : (alt ? '¥15.9' : '¥16.9'); }
  if (variant.startsWith('presale')) { return long ? '¥99999.99' : (alt ? '¥45.78' : '¥46.78'); }
  return long ? '¥99999.99' : (alt ? '¥12.45' : '¥13.45');
}

function priceCases(): PriceCase[] {
  const out: PriceCase[] = [];
  for (const v of PRICE_VARIANTS) {
    for (const s of ['normal', 'long-price']) { out.push(new PriceCase(PRICE_TAG, v, s, priceAmount(v, s, false), false)); }
  }
  return out;
}

function rebateCases(): PriceCase[] {
  return [
    new PriceCase(REBATE_TAG, 'single', 'normal', REBATE_SINGLE, false),
    new PriceCase(REBATE_TAG, 'single', 'amount-hidden', MASK_TEXT, false),
    new PriceCase(REBATE_TAG, 'range', 'normal', '¥0.56–¥1.12', true),
    new PriceCase(REBATE_TAG, 'range', 'amount-hidden', MASK_TEXT, false),
    new PriceCase(REBATE_TAG, 'large', 'normal', REBATE_SINGLE, false),
    new PriceCase(REBATE_TAG, 'large', 'amount-hidden', MASK_TEXT, false),
    new PriceCase(REBATE_TAG, 'amount_unknown', 'normal', AMOUNT_UNKNOWN_TEXT, true),
    new PriceCase(REBATE_TAG, 'amount_unknown', 'amount-hidden', AMOUNT_UNKNOWN_TEXT, true),
    new PriceCase(REBATE_TAG, 'login_required', 'normal', LOGIN_TEXT, true),
    new PriceCase(REBATE_TAG, 'login_required', 'amount-hidden', LOGIN_TEXT, true),
    new PriceCase(REBATE_TAG, 'range', 'wrap-at-dash', '¥88888.88–¥99999.99', true),
    new PriceCase(REBATE_TAG, 'block', 'normal', REBATE_SINGLE, false)
  ];
}

/** 本段的设备助手（集成时与别的段同文件，不用模块级同名函数）。 */
class L2PriceRig {
  static async idle(): Promise<void> {
    expect(await driver.waitForIdle(200, 8000)).assertTrue();
  }

  static async node(id: string): Promise<Component> {
    const found: Component = await driver.waitForComponent(ON.id(id), 8000);
    expect(found !== null && found !== undefined).assertTrue();
    return found;
  }

  static async click(id: string): Promise<void> {
    await (await L2PriceRig.node(id)).click();
    await L2PriceRig.idle();
  }

  static async setFont(scale: string): Promise<void> {
    await L2PriceRig.click('catalog-font-' + scale);
    const label: string = scale === '200' ? '字号 ×2.00' : '字号 ×1.00';
    const shown: Component = await driver.waitForComponent(ON.text(label), 5000);
    expect(shown !== null && shown !== undefined).assertTrue();
    await L2PriceRig.idle();
  }

  static async index(): Promise<void> {
    for (let attempt: number = 0; attempt < 5; attempt++) {
      const found: Component = await driver.findComponent(ON.id('catalog-index'));
      if (found !== null && found !== undefined) { return; }
      await driver.pressBack();
      await L2PriceRig.idle();
      const back: Component = await driver.waitForComponent(ON.id('catalog-index'), 3000);
      if (back !== null && back !== undefined) { return; }
    }
    await L2PriceRig.node('catalog-index');
  }

  /** 同 Ds02Ui.open：先直达（couli.ds02.component），拿不到再回索引有界搜索。 */
  static async open(component: string): Promise<void> {
    const current: Component = await driver.findComponent(ON.id('catalog-cases/' + component));
    if (current !== null && current !== undefined) { return; }
    await abilityDelegatorRegistry.getAbilityDelegator().startAbility({
      bundleName: 'com.couli.hm', moduleName: 'entry', abilityName: 'EntryAbility',
      parameters: { 'couli.ds02.component': component }
    });
    const direct: Component = await driver.waitForComponent(ON.id('catalog-cases/' + component), 8000);
    if (direct !== null && direct !== undefined) { await L2PriceRig.idle(); return; }
    await L2PriceRig.index();
    let entry: Component = await driver.findComponent(ON.id('catalog-entry/' + component));
    if (entry === null || entry === undefined) {
      entry = await searchUiComponent(driver, ON.id('catalog-index'), ON.id('catalog-entry/' + component));
    }
    expect(entry !== null && entry !== undefined).assertTrue();
    await entry.click();
    await L2PriceRig.node('catalog-cases/' + component);
  }

  static sampleId(c: PriceCase): string {
    return 'catalog-sample/' + c.component + '/' + c.variant + '/' + c.state;
  }

  /** 同 Ds02Ui.measureSample：量几何前把样例框整块拉进列表可视区（bounds 只含可见部分）。 */
  static async fullyVisible(component: string, id: string): Promise<Component> {
    for (let attempt: number = 0; attempt < 8; attempt++) {
      const list: Component = await L2PriceRig.node('catalog-cases/' + component);
      let found: Component = await driver.findComponent(ON.id(id));
      if (found === null || found === undefined) {
        found = await searchUiComponent(driver, ON.id('catalog-cases/' + component), ON.id(id));
        expect(found !== null && found !== undefined).assertTrue();
      }
      const view: Rect = await list.getBounds();
      const r: Rect = await found.getBounds();
      if (r.top > view.top && r.bottom < view.bottom && r.bottom > r.top) { return found; }
      const x: number = Math.floor(view.left + (view.right - view.left) * 0.02);
      const from: number = Math.floor((view.top + view.bottom) / 2);
      const limit: number = (view.bottom - view.top) * 0.35;
      const shift: number = Math.max(-limit, Math.min(limit, (r.top + r.bottom) / 2 - from));
      await driver.swipe(x, from, x, Math.floor(from - shift), 600);
      await L2PriceRig.idle();
    }
    throw new Error('L2PRICE_SAMPLE_NOT_FULLY_VISIBLE: ' + id);
  }

  /** 去掉 rangeBreakable 插的零宽空格 / 词连接符再比文字。 */
  static plain(t: string): string {
    return t.split('\u200b').join('').split('\u2060').join('');
  }

  /** 样例框里文字包含 want 的 Text 节点（去掉框标题「变体 · 状态」），按文字长短排序。 */
  static async textsWith(sampleId: string, title: string, wants: string[]): Promise<AmountHit[]> {
    const nodes: Component[] = await driver.findComponents(ON.type('Text').within(ON.id(sampleId)));
    const out: AmountHit[] = [];
    for (const n of (nodes ?? [])) {
      const t: string = L2PriceRig.plain(await n.getText());
      if (t === title) { continue; }
      if (wants.some((w: string): boolean => t.indexOf(w) >= 0)) { out.push(new AmountHit(n, t, await n.getBounds())); }
    }
    out.sort((a: AmountHit, b: AmountHit): number => a.text.length - b.text.length);
    return out;
  }

  /** 样例框整块可见后找金额节点；找不到直接红（带样例框里全部文字）。 */
  static async amount(c: PriceCase, want: string): Promise<AmountHit> {
    const box: Component = await L2PriceRig.fullyVisible(c.component, L2PriceRig.sampleId(c));
    const hits: AmountHit[] = await L2PriceRig.textsWith(L2PriceRig.sampleId(c), c.variant + ' · ' + c.state, [want]);
    if (hits.length === 0) {
      const all: Component[] = await driver.findComponents(ON.type('Text').within(ON.id(L2PriceRig.sampleId(c))));
      const seen: string[] = [];
      for (const n of (all ?? [])) { seen.push(await n.getText()); }
      expect(L2PriceRig.sampleId(c) + ' 金额节点 ' + want + ' 找到 false ' + JSON.stringify(seen))
        .assertEqual(L2PriceRig.sampleId(c) + ' 金额节点 ' + want + ' 找到 true');
    }
    const inside: Rect = await box.getBounds();
    L2PriceRig.assertInside(hits[0].rect, inside, L2PriceRig.sampleId(c) + ' ' + want);
    hits[0].box = inside;
    return hits[0];
  }

  static assertInside(inner: Rect, outer: Rect, tag: string): void {
    const ok: boolean = inner.left >= outer.left - 1 && inner.right <= outer.right + 1 && inner.top >= outer.top - 1
      && inner.bottom <= outer.bottom + 1 && inner.right > inner.left && inner.bottom > inner.top;
    expect(tag + ' 整块在样例框内（不截断、不溢出）' + ok).assertEqual(tag + ' 整块在样例框内（不截断、不溢出）true');
  }

  /** 100% / 200% 各量一遍：都在框内；200% 不缩字号；节点就是金额本身时 200% 仍是一行。 */
  static async assertWholeAt200(cases: PriceCase[], component: string): Promise<void> {
    await L2PriceRig.open(component);
    await L2PriceRig.click('catalog-theme-light');
    await L2PriceRig.setFont('100');
    const normal: number[] = [];
    const normalW: number[] = [];
    for (const c of cases) {
      const hit: AmountHit = await L2PriceRig.amount(c, c.amount);
      normal.push(hit.rect.bottom - hit.rect.top);
      normalW.push(hit.rect.right - hit.rect.left);
    }
    await L2PriceRig.setFont('200');
    for (let i: number = 0; i < cases.length; i++) {
      const c: PriceCase = cases[i];
      const tag: string = L2PriceRig.sampleId(c) + '@200%';
      const hit: AmountHit = await L2PriceRig.amount(c, c.amount);
      const h: number = hit.rect.bottom - hit.rect.top;
      expect(tag + ' 不缩字号 ' + (h > normal[i] * GROW_MIN)).assertEqual(tag + ' 不缩字号 true');
      const boxW: number = hit.box === null ? 0 : hit.box.right - hit.box.left;
      if (!c.wrapAllowed && hit.text === c.amount && normalW[i] * FIT_SCALE < boxW) {
        expect(tag + ' 放得下的金额一行没被拆 h200=' + h + ' h100=' + normal[i] + ' w100=' + normalW[i] + ' box=' + boxW + ' '
          + (h < normal[i] * ONE_LINE_MAX))
          .assertEqual(tag + ' 放得下的金额一行没被拆 h200=' + h + ' h100=' + normal[i] + ' w100=' + normalW[i] + ' box=' + boxW + ' true');
      }
    }
    await L2PriceRig.setFont('100');
  }

  static token(key: string, dark: boolean): Rgb {
    const rows: ExpectedColor[] = EXPECTED_COLORS.filter((row: ExpectedColor): boolean => row.key === key);
    expect(rows.length).assertEqual(1);
    const v: number = Number.parseInt((dark ? rows[0].dark : rows[0].light).substring(1), 16);
    return new Rgb((v >> 16) & 255, (v >> 8) & 255, v & 255);
  }

  static pixel(shot: Shot, x: number, y: number): Rgb {
    const o: number = (y * shot.width + x) * 4;
    return new Rgb(shot.bytes[o], shot.bytes[o + 1], shot.bytes[o + 2]);
  }

  static diff(a: Rgb, b: Rgb): number {
    return Math.max(Math.abs(a.r - b.r), Math.abs(a.g - b.g), Math.abs(a.b - b.b));
  }

  static rgbText(c: Rgb): string {
    return c.r + '/' + c.g + '/' + c.b;
  }

  /** 框内离 want 最近的像素（字形实心处应落在令牌色 ±8 内）。 */
  static closest(shot: Shot, want: Rgb): Rgb {
    let best: Rgb = L2PriceRig.pixel(shot, 0, 0);
    let bestDiff: number = 1000;
    for (let y: number = 0; y < shot.height; y++) {
      for (let x: number = 0; x < shot.width; x++) {
        const c: Rgb = L2PriceRig.pixel(shot, x, y);
        const d: number = L2PriceRig.diff(c, want);
        if (d < bestDiff) { bestDiff = d; best = c; }
      }
    }
    return best;
  }

  static assertNear(tag: string, key: string, got: Rgb, want: Rgb): void {
    const ok: boolean = L2PriceRig.diff(got, want) <= PRICE_COLOR_TOLERANCE;
    expect(tag + ' ' + key + ' got ' + L2PriceRig.rgbText(got) + ' want ' + L2PriceRig.rgbText(want) + ' ±' + PRICE_COLOR_TOLERANCE + ' ' + ok)
      .assertEqual(tag + ' ' + key + ' got ' + L2PriceRig.rgbText(got) + ' want ' + L2PriceRig.rgbText(want) + ' ±' + PRICE_COLOR_TOLERANCE + ' true');
  }

  /** 连拍一张「有字」：框内有像素与左上角底色差 > INK_DELTA。 */
  static inked(shot: Shot): boolean {
    const bg: Rgb = L2PriceRig.pixel(shot, 0, 0);
    for (let y: number = 0; y < shot.height; y++) {
      for (let x: number = 0; x < shot.width; x++) {
        if (L2PriceRig.diff(L2PriceRig.pixel(shot, x, y), bg) > INK_DELTA) { return true; }
      }
    }
    return false;
  }

  /** 当前是不是切换后的值；是就点一次切回（上一轮失败留下的状态）。 */
  static async resetToggle(c: PriceCase, base: string, alt: string): Promise<void> {
    await L2PriceRig.fullyVisible(c.component, L2PriceRig.sampleId(c));
    const title: string = c.variant + ' · ' + c.state;
    if ((await L2PriceRig.textsWith(L2PriceRig.sampleId(c), title, [alt])).length > 0) {
      await L2PriceRig.click('catalog-amount-toggle');
    }
    await L2PriceRig.amount(c, base);
  }

  /**
   * 点「切换金额」：此后 1.5s 内每次轮询样例框里都有文字是旧值或新值的节点（节点没被拆掉，不闪）；3 张连拍都有字；
   * 3s 内新值出现、旧值消失；新值节点仍整块在框内；稳定后金额字形取色仍是 colorKey 令牌。
   */
  static async assertToggle(c: PriceCase, from: string, to: string, colorKey: string): Promise<void> {
    const sampleId: string = L2PriceRig.sampleId(c);
    const title: string = c.variant + ' · ' + c.state;
    const before: AmountHit = await L2PriceRig.amount(c, from);
    await (await L2PriceRig.node('catalog-amount-toggle')).click();
    const gaps: number[] = [];
    const inkless: string[] = [];
    const start: number = Date.now();
    let polls: number = 0;
    while (Date.now() - start < 1500) {
      polls++;
      if ((await L2PriceRig.textsWith(sampleId, title, [from, to])).length === 0) { gaps.push(Date.now() - start); }
      if (polls <= 3) {
        const shot: Shot = await captureChecked(driver, before.rect, 'l2price-burst-' + c.variant + '-' + polls);
        if (!L2PriceRig.inked(shot)) { inkless.push('#' + polls + '@' + (Date.now() - start) + 'ms'); }
      }
    }
    expect(sampleId + ' 换值过程中金额节点一直在（不闪），缺失于 ' + JSON.stringify(gaps)).assertEqual(sampleId + ' 换值过程中金额节点一直在（不闪），缺失于 []');
    expect(sampleId + ' 连拍每张都有字，空白 ' + JSON.stringify(inkless)).assertEqual(sampleId + ' 连拍每张都有字，空白 []');
    const end: number = Date.now() + 3000;
    let settled: boolean = false;
    while (!settled && Date.now() < end) {
      settled = (await L2PriceRig.textsWith(sampleId, title, [to])).length > 0
        && (await L2PriceRig.textsWith(sampleId, title, [from])).length === 0;
      if (!settled) { await driver.delayMs(100); }
    }
    expect(sampleId + ' ' + from + ' → ' + to + ' ' + settled).assertEqual(sampleId + ' ' + from + ' → ' + to + ' true');
    await L2PriceRig.idle();
    const after: AmountHit = await L2PriceRig.amount(c, to);
    const shot: Shot = await captureChecked(driver, after.rect, 'l2price-settled-' + c.variant);
    L2PriceRig.assertNear(sampleId + ' 换值后', colorKey, L2PriceRig.closest(shot, L2PriceRig.token(colorKey, false)),
      L2PriceRig.token(colorKey, false));
  }

  /** 同 Ds02Ui beforeAll：已在目录就直接用；否则有界重拉 → 首页「Debug panel」→「Component catalog」；隐私首启点「不同意」进基本模式。 */
  static async enterCatalog(): Promise<void> {
    const inCatalog: Component = await driver.findComponent(ON.id('catalog-index'));
    if (inCatalog !== null && inCatalog !== undefined) { return; }
    const trail: string[] = [];
    let ready: boolean = false;
    for (let attempt: number = 0; attempt < 8 && !ready; attempt++) {
      await abilityDelegatorRegistry.getAbilityDelegator().startAbility({
        bundleName: 'com.couli.hm', moduleName: 'entry', abilityName: 'EntryAbility'
      });
      await driver.delayMs(500);
      await L2PriceRig.idle();
      let list: Component | null = null;
      for (let poll: number = 0; poll < 16 && list === null; poll++) {
        for (const label of ['不同意', '仍不同意']) {
          const privacy: Component = await driver.findComponent(ON.text(label));
          if (privacy !== null && privacy !== undefined) { await privacy.click(); await L2PriceRig.idle(); }
        }
        const already: Component = await driver.findComponent(ON.id('catalog-index'));
        if (already !== null && already !== undefined) { return; }
        const found: Component = await driver.findComponent(ON.id('home_list'));
        if (found !== null && found !== undefined) { list = found; } else { await driver.delayMs(500); }
      }
      if (list === null) { trail.push(attempt + ':no-home_list'); continue; }
      try {
        const entry: Component = await searchUiComponent(driver, ON.id('home_list'), ON.text('Debug panel'));
        if (entry !== null && entry !== undefined) { await entry.click(); ready = true; }
      } catch (e) {
        const text: string = String(e);
        if (!isNoCandidates(e as Object) && text.indexOf('DS02_UI_CONTAINER_GONE') < 0 && text.indexOf('DS02_UI_SEARCH_EXHAUSTED') < 0) {
          throw e as Error;
        }
        trail.push(attempt + ':miss');
      }
    }
    expect(ready ? 'ready' : 'L2PRICE_NOT_READY ' + trail.join(' ') + ' ' + (await scene(driver))).assertEqual('ready');
    await L2PriceRig.idle();
    const scroll: Component = await driver.waitForComponent(ON.type('Scroll'), 8000);
    expect(scroll !== null && scroll !== undefined).assertTrue();
    const catalog: Component = await searchUiComponent(driver, ON.type('Scroll'), ON.text('Component catalog'));
    expect(catalog !== null && catalog !== undefined).assertTrue();
    await catalog.click();
    trace('L2PRICE_BEFOREALL_TRAIL ' + (trail.length === 0 ? '-' : trail.join(' ')));
    await L2PriceRig.node('catalog-index');
  }
}

/** HM-L2-PRICE-TAG 的段（集成时由 ds02L2UiTest() 调用）。 */
export function ds02L2UiPriceTagCases(): void {
  describe('Ds02L2Ui', () => {
    beforeEach(async (): Promise<void> => { await drainUiTasks(driver); });
    afterEach(async (): Promise<void> => { await drainUiTasks(driver); });
    beforeAll(async (): Promise<void> => {
      await runUiTask(driver, async (): Promise<void> => { await L2PriceRig.enterCatalog(); });
    });
    afterAll(async (): Promise<void> => {
      await drainUiTasks(driver);
      await runUiTask(driver, async (): Promise<void> => {
        await L2PriceRig.index();
        await L2PriceRig.click('catalog-theme-light');
        await L2PriceRig.setFont('100');
      });
    });

    // 书 §3 设备 ①：目录 PriceTag 全部 variant × normal / long-price，100% 与 200%：金额节点在、整块在样例框内（不截断、不溢出）、
    // 200% 不缩字号、金额 Text 一行没被拆（03 §10.4；Price.ets「金额本身不拆」；README ⑤ 探针「200% 折行不退化」的设备判据）。
    it('l2price_01_price_tag_variants_amount_whole_at_100_and_200', 0, async (): Promise<void> => {
      await L2PriceRig.assertWholeAt200(priceCases(), PRICE_TAG);
    });

    // 书 §3 设备 ①：RebateTag single / range / large / amount_unknown / login_required × normal / amount-hidden（④ 防御态原样）、
    // range 破折号折行、窄卡 block；同上判据（区间、长文字只核在框内）。
    it('l2price_02_rebate_tag_states_whole_at_100_and_200', 0, async (): Promise<void> => {
      await L2PriceRig.assertWholeAt200(rebateCases(), REBATE_TAG);
    });

    // 书 §3 设备 ②：深浅取色是令牌角色——价文字 price.text（PriceTag 金额字形）、返利字 rebate.text 与返利底 rebate.background
    // （RebateTag 金额字形与金额节点上沿角的底色；列表 single 与窄卡 block 各一）。取色只经 captureChecked，±8。
    for (const mode of ['light', 'dark']) {
      it('l2price_03_token_roles_price_text_rebate_text_background_' + mode, 0, async (): Promise<void> => {
        const dark: boolean = mode === 'dark';
        await L2PriceRig.open(PRICE_TAG);
        await L2PriceRig.click('catalog-theme-' + mode);
        await L2PriceRig.setFont('100');
        for (const v of ['coupon-list', 'coupon-detail']) {
          const c: PriceCase = new PriceCase(PRICE_TAG, v, 'normal', priceAmount(v, 'normal', false), false);
          const hit: AmountHit = await L2PriceRig.amount(c, c.amount);
          const shot: Shot = await captureChecked(driver, hit.rect, 'l2price-price-' + v + '-' + mode);
          const want: Rgb = L2PriceRig.token('price.text', dark);
          L2PriceRig.assertNear(v + '-' + mode, 'price.text', L2PriceRig.closest(shot, want), want);
        }
        await L2PriceRig.open(REBATE_TAG);
        await L2PriceRig.click('catalog-theme-' + mode);
        for (const v of ['single', 'block']) {
          const c: PriceCase = new PriceCase(REBATE_TAG, v, 'normal', REBATE_SINGLE, false);
          const hit: AmountHit = await L2PriceRig.amount(c, c.amount);
          const shot: Shot = await captureChecked(driver, hit.rect, 'l2price-rebate-' + v + '-' + mode);
          const fg: Rgb = L2PriceRig.token('rebate.text', dark);
          L2PriceRig.assertNear(v + '-' + mode, 'rebate.text', L2PriceRig.closest(shot, fg), fg);
          const bg: Rgb = L2PriceRig.token('rebate.background', dark);
          const left: Rgb = L2PriceRig.pixel(shot, 1, 1);
          const right: Rgb = L2PriceRig.pixel(shot, shot.width - 2, 1);
          L2PriceRig.assertNear(v + '-' + mode + ' 上沿角', 'rebate.background', L2PriceRig.diff(left, bg) <= L2PriceRig.diff(right, bg) ? left : right, bg);
        }
      });
    }

    // 书 §3 设备 ③ + §7「数字过渡」录屏段：目录内切换价格值 → 金额节点原位换值。两种结局（README ⑤）同一判据：换值过程中节点一直在、
    // 连拍每张有字（不闪）、3s 内到新值、换回原值；不在 normal 的样例不受切换影响。过渡本身目视（截图连拍只证状态）。
    it('l2price_04_amount_toggle_replaces_value_in_place_without_flash', 0, async (): Promise<void> => {
      await L2PriceRig.open(PRICE_TAG);
      await L2PriceRig.click('catalog-theme-light');
      await L2PriceRig.setFont('100');
      for (const v of ['coupon-list', 'no-coupon-ai', 'pdd-detail']) {
        const c: PriceCase = new PriceCase(PRICE_TAG, v, 'normal', priceAmount(v, 'normal', false), false);
        const base: string = priceAmount(v, 'normal', false);
        const alt: string = priceAmount(v, 'normal', true);
        await L2PriceRig.resetToggle(c, base, alt);
        await L2PriceRig.assertToggle(c, base, alt, 'price.text');
        const untouched: PriceCase = new PriceCase(PRICE_TAG, v, 'long-price', priceAmount(v, 'long-price', false), false);
        await L2PriceRig.amount(untouched, untouched.amount);
        await L2PriceRig.fullyVisible(PRICE_TAG, L2PriceRig.sampleId(c));
        await L2PriceRig.assertToggle(c, alt, base, 'price.text');
      }
      await L2PriceRig.open(REBATE_TAG);
      await L2PriceRig.click('catalog-theme-light');
      for (const v of ['single', 'large', 'block']) {
        const c: PriceCase = new PriceCase(REBATE_TAG, v, 'normal', REBATE_SINGLE, false);
        await L2PriceRig.resetToggle(c, REBATE_SINGLE, REBATE_SINGLE_ALT);
        await L2PriceRig.assertToggle(c, REBATE_SINGLE, REBATE_SINGLE_ALT, 'rebate.text');
        await L2PriceRig.amount(new PriceCase(REBATE_TAG, 'range', 'normal', '¥0.56–¥1.12', true), '¥0.56–¥1.12');
        await L2PriceRig.fullyVisible(REBATE_TAG, L2PriceRig.sampleId(c));
        await L2PriceRig.assertToggle(c, REBATE_SINGLE_ALT, REBATE_SINGLE, 'rebate.text');
      }
    });
  });
}

export default function ds02L2UiTest() {
  ds02L2UiButtonCases();
  ds02L2UiPriceTagCases();
}
