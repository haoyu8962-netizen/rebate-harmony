// HM-05r 设备用例（verify 单独一个 entry 设备步 entry-hm05r：class=Hm05rConsentUi，先卸载重装、从未同意隐私的冷启动开始、单独 1800 s）。
// 测试 v3（2026-10-30 默认开启：BR-ID-16 2026-10-30 版、docs/changes/20261030-剪贴板默认开启.md §2 / §3 / §6、任务书 FU-X-CLIP-DEFAULT-ON
// §1 C1–C8 / §2.1 / §3，编排 D10-423）：v1 的 9 条（用途说明半屏的首次拦截、三种系统关闭、版式、开启上报、版本变化重弹）随 §2 第 1、3、4、5 行
// 作废，改为 11 条：全新安装同意隐私后回前台自动任务（默认开启、不弹、不报）、手动首次直接读、设置行默认开启（品牌色轨道）、关闭后零自动任务
// （冷启动后仍关）、关闭时手动照常、再打开直接生效、升级迁移四种旧状态各一条、撤回隐私进基本模式无设置行且不读 / 重新同意保持关闭。
// 驱动真实应用：首页 PasteButton 由 UiTest 真点（安全控件），剪贴板样例由测试进程写系统剪贴板；设备级开关读写产品 preferences，上报读本机假服务
// 回执，自动任务读 staging 探测计数（设施说明见 Hm05rConsentRig.ets 头注释）。全程游客。生产默认不具备资格（D1：不声明 READ_PASTEBOARD），
// 所以回前台的自动任务在设备上止于资格这一步（降级为 PasteButton、读取 0 次）；「读取 1 次、出商品卡」由 core Hm05rIntegration 的 C1 用例守。
// 用例按顺序共享一份安装（状态单向）：首启 → 手动 → 设置（开 → 关 → 开）→ 四种旧状态迁移 → 撤回 / 重新同意。
import { describe, it, expect } from '@ohos/hypium';
import { ON, Component } from '@kit.TestKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { atLeast, hm07vDriver, idle, launch, maybe, node, tap } from './Hm07vHomeRig';
import { check, CLIP_UNREC, NOTICE_ID, screenTexts } from './Hm07vOverlayRig';
import {
  brandTrack, expectEq, foregroundRound, freshFull, guestLaunch, hitVp, noSheet, openSettings, probes, reports, ROW_ID, ROW_TITLE,
  scrollTo, seedLegacy, stored, storedOn, texts, TOGGLE_ID, toggleOn, toHome, treeNode, until
} from './Hm05rConsentRig';

/** 与 tools/ci/hm05r/fixtures/device-cases.txt、ds02/check_device_result.py --set hm05r 一致（check_hm05r.py C1 守）。 */
export const HM05R_DEVICE_CASES: string[] = [
  'hm05r_01_fresh_install_agree_privacy_default_on_foreground_auto_task_once_no_sheet_no_report',
  'hm05r_02_manual_first_paste_reads_directly_without_notice',
  'hm05r_03_settings_row_guest_default_on_brand_track_48vp_and_reader_label',
  'hm05r_04_switch_off_direct_no_sheet_zero_auto_task_after_foreground_and_cold_relaunch',
  'hm05r_05_switch_off_manual_paste_still_reads',
  'hm05r_06_switch_on_again_direct_no_sheet_no_report_auto_task_next_round',
  'hm05r_07_upgrade_r3_never_chosen_maps_on',
  'hm05r_08_upgrade_r3_not_now_seen_maps_off_and_user_on_survives_relaunch',
  'hm05r_09_upgrade_r3_settings_off_maps_off',
  'hm05r_10_upgrade_r3_enabled_with_queue_maps_on_queue_dropped_never_reported',
  'hm05r_11_withdraw_privacy_basic_mode_no_row_no_auto_task_reagree_keeps_off'
];

const PASTE_ID: string = 'home_paste_card_paste';
const PRODUCT_SAMPLE: string = '「hm05r 测试商品」https://e.tb.cn/h.Demo01?tk=sheet1';
const R3_QUEUE: string = '[{"type":"clipboard_auto_import","version":"hm05r-v1","accepted_at_ms":1799000000000}]';

async function writeClip(text: string): Promise<void> {
  const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
  await pasteboard.getSystemPasteboard().setData(data);
  await hm07vDriver.delayMs(300);
}

async function tapPasteButton(): Promise<void> {
  const end: number = Date.now() + 15000;
  while (Date.now() < end) {
    const b: Component | null = await maybe(ON.id(PASTE_ID), 1000);
    if (b !== null && await b.isEnabled()) {
      await b.click();
      await hm07vDriver.delayMs(600);
      return;
    }
    await hm07vDriver.delayMs(200);
  }
  check(false, 'HM05R_PASTE_DISABLED 首页 PasteButton 15 秒不可点', await screenTexts());
}

async function resultCardShown(timeoutMs: number): Promise<boolean> {
  return (await maybe(ON.id(NOTICE_ID), timeoutMs)) !== null;
}

/** 首页手动粘贴一次：PasteButton 授权成功后直接读、出结果 ①，不出用途说明。 */
async function manualPasteReads(what: string): Promise<void> {
  await toHome();
  await writeClip(CLIP_UNREC);
  await tapPasteButton();
  check(await resultCardShown(8000), 'HM05R_MANUAL_NO_RESULT ' + what + '：手动粘贴应直接读取出结果', await screenTexts());
  await noSheet(what, 300);
}

/** 基本模式首页（退出子页，直到看到【开启完整功能】）：自动任务的目标页是首页根页，基本模式也要站在这里量才有意义。 */
async function basicHome(): Promise<void> {
  for (let i: number = 0; i < 5; i++) {
    if ((await maybe(ON.id('couli-basic-enable'), 1500)) !== null) {
      return;
    }
    await hm07vDriver.pressBack();
    await hm07vDriver.delayMs(800);
  }
  check((await maybe(ON.id('couli-basic-enable'), 3000)) !== null, 'HM05R_NOT_BASIC_HOME', await screenTexts());
}

/** 升级迁移一条：清空产品本机文件写入 r3 旧键 → 进程内冷启动（执行层装配时迁移）→ 量这一轮自动任务、设置行显示与落盘值。 */
async function migrate(what: string, legacy: string[][], expectOn: boolean): Promise<void> {
  await toHome();
  await hm07vDriver.pressHome();
  await hm07vDriver.delayMs(1000);
  seedLegacy(legacy);
  const delta: number = await foregroundRound(guestLaunch(), true);
  await noSheet(what);
  expectEq(what + ' auto task this round', delta, expectOn ? 1 : 0);
  expectEq(what + ' stored switch', storedOn(), expectOn);
  if (!expectOn) {
    expectEq(what + ' off written', stored('enabled'), 'off');
  }
  expectEq(what + ' queue dropped (C3)', stored('pending_consents'), null);
  const toggle: Component = await openSettings(guestLaunch());
  expectEq(what + ' settings row', await toggle.isChecked(), expectOn);
  expectEq(what + ' never reported', reports(), 0);
}

export default function hm05rConsentUiTest() {
  describe('Hm05rConsentUi', () => {
    it(HM05R_DEVICE_CASES[0], 0, async () => {
      // C1：首启 → 同意隐私（这一轮有首启隐私浮层：敏感浮层，本轮跳过，不弹不探测）
      await freshFull(guestLaunch());
      await hm07vDriver.delayMs(2500);
      await noSheet('首启隐私那一轮');
      expectEq('privacy round skipped: no probe', probes(), 0);
      // 复制商品链接，真实进后台再回前台：首页根页的自动任务按默认开启走到资格这一步（不具备资格 → PasteButton 降级，读取 0 次）
      await writeClip(PRODUCT_SAMPLE);
      const delta: number = await foregroundRound(guestLaunch());
      expectEq('default on: auto task once this round', delta, 1);
      await noSheet('同意隐私后回前台');
      check(!(await resultCardShown(300)), 'HM05R_FOREGROUND_READ 不具备资格（D1）回前台不得读取出结果');
      check((await maybe(ON.id('home_search_row'), 3000)) !== null, 'HM05R_LEFT_HOME 回前台不该离开首页', await screenTexts());
      check((await maybe(ON.id(PASTE_ID), 3000)) !== null, 'HM05R_NO_PASTE_BUTTON 降级入口 PasteButton 应在');
      expectEq('never chosen = on', storedOn(), true);
      expectEq('no clipboard_auto_import report', reports(), 0);
      // 同一轮里获焦 / 页面重显不再探测（每轮 1 次）
      await launch(guestLaunch());
      await hm07vDriver.delayMs(1500);
      expectEq('once per round', probes(), delta);
    });

    it(HM05R_DEVICE_CASES[1], 0, async () => {
      // C2：手动粘贴首次直接读取识别，不再要求看过用途说明
      const before: string | null = stored('enabled');
      await manualPasteReads('首次手动粘贴');
      expectEq('manual paste does not touch switch', stored('enabled'), before);
      expectEq('still on', storedOn(), true);
      expectEq('no report', reports(), 0);
    });

    it(HM05R_DEVICE_CASES[2], 0, async () => {
      // C8：游客设置页有开关行，默认开启（品牌色轨道），48vp 命中，读屏名含标题
      const toggle: Component = await openSettings(guestLaunch());
      const row: Record<string, Object> = await treeNode(ROW_ID);
      const all: string[] = [];
      texts(row, all);
      check(all.some((t: string): boolean => t.indexOf(ROW_TITLE) >= 0), 'HM05R_ROW_TITLE 开关行标题 / 读屏名', all.join('|'));
      expectEq('default on displayed', await toggle.isChecked(), true);
      expectEq('brand track', await brandTrack(), '');
      const hit: number[] = hitVp(await toggle.getBounds());
      const rowHit: number[] = hitVp(await (await node(ON.id(ROW_ID), '开关行')).getBounds());
      atLeast(Math.max(hit[1], rowHit[1]), 47.5, '开关命中高 vp');
      atLeast(Math.max(hit[0], rowHit[0]), 47.5, '开关命中宽 vp');
    });

    it(HM05R_DEVICE_CASES[3], 0, async () => {
      // C5：关闭直接生效、不出弹层、不上报；之后回前台（Home 键）与进程内冷启动都不再走自动任务
      await openSettings(guestLaunch());
      await tap(ON.id(TOGGLE_ID), '关闭剪贴板开关');
      await noSheet('关闭开关');
      expect(await until((): boolean => stored('enabled') === 'off', 3000)).assertTrue();
      expectEq('toggle off', await toggleOn(), false);
      expectEq('off: no report', reports(), 0);
      await toHome();
      await writeClip(PRODUCT_SAMPLE);
      expectEq('off: no auto task after foreground', await foregroundRound(guestLaunch()), 0);
      expectEq('off: no auto task after cold relaunch', await foregroundRound(guestLaunch(), true), 0);
      check(!(await resultCardShown(300)), 'HM05R_OFF_READ 关闭后回前台不得读取出结果');
      expectEq('off kept after relaunch', stored('enabled'), 'off');
      expectEq('settings still off after relaunch', await (await openSettings(guestLaunch())).isChecked(), false);
    });

    it(HM05R_DEVICE_CASES[4], 0, async () => {
      // C5：关闭后手动粘贴照常
      await manualPasteReads('关闭后手动粘贴');
      expectEq('manual does not reopen switch', stored('enabled'), 'off');
      expectEq('no report', reports(), 0);
    });

    it(HM05R_DEVICE_CASES[5], 0, async () => {
      // C8：再打开直接生效（不出弹层、不上报），下一轮回前台自动任务恢复
      await openSettings(guestLaunch());
      await tap(ON.id(TOGGLE_ID), '再打开剪贴板开关');
      await noSheet('再打开开关');
      expect(await until((): boolean => storedOn(), 3000)).assertTrue();
      expectEq('toggle on', await toggleOn(), true);
      expectEq('on: no report', reports(), 0);
      await toHome();
      expectEq('on: auto task next round', await foregroundRound(guestLaunch()), 1);
    });

    // ---------------------------------------------------------------- C6 升级迁移（r3 实际写过的键；映射见 specs/clipboard-harmony-vectors.json）
    it(HM05R_DEVICE_CASES[6], 0, async () => {
      // ① 从未作出选择（main 0f40137 的安装在这个文件里没有任何键）→ 开启
      await migrate('① never', [], true);
    });

    it(HM05R_DEVICE_CASES[7], 0, async () => {
      // ② 旧弹层【暂不开启】或下滑 / 遮罩 / 返回（记过已看、没开启）→ 关闭；迁移只做一次：之后用户在设置打开，冷启动后不被旧结论覆盖
      await migrate('② not now', [['import.notice_seen_version', 'hm05r-v1']], false);
      await tap(ON.id(TOGGLE_ID), '② 之后用户打开');
      expect(await until((): boolean => storedOn(), 3000)).assertTrue();
      await toHome();
      expectEq('② user on survives cold relaunch: auto task', await foregroundRound(guestLaunch(), true), 1);
      expectEq('② user on kept', storedOn(), true);
      expectEq('② settings on', await (await openSettings(guestLaunch())).isChecked(), true);
    });

    it(HM05R_DEVICE_CASES[8], 0, async () => {
      // ③ 旧版在设置里关闭过 → 关闭
      await migrate('③ settings off', [['import.enabled', 'off'], ['import.consent_version', 'hm05r-v1'],
        ['import.consented_at', '1799000000000'], ['import.notice_seen_version', 'hm05r-v1']], false);
    });

    it(HM05R_DEVICE_CASES[9], 0, async () => {
      // ④ 旧版已开启（带一条没报出去的同意记录）→ 开启；队列清掉、永不补报（C3）
      await migrate('④ enabled', [['import.enabled', 'on'], ['import.consent_version', 'hm05r-v1'],
        ['import.consented_at', '1799000000000'], ['import.notice_seen_version', 'hm05r-v1'], ['import.pending_consents', R3_QUEUE]],
        true);
      await toHome();
      await foregroundRound(guestLaunch());
      expectEq('④ still never reported after another round', reports(), 0);
    });

    it(HM05R_DEVICE_CASES[10], 0, async () => {
      // C7：先在设置关闭；撤回隐私同意 → 基本模式：设置页没有开关行、回前台不走自动任务；重新同意 → 之前关过的仍关
      await openSettings(guestLaunch());
      if (await toggleOn()) {
        await tap(ON.id(TOGGLE_ID), '撤回前先关闭');
      }
      expect(await until((): boolean => stored('enabled') === 'off', 3000)).assertTrue();
      await launch(guestLaunch().with('couli_debug_open_route', 'PrivacyCenter'));
      await (await scrollTo('privacy_withdraw', '隐私中心【撤回同意】')).click();
      await tap(ON.text('确认撤回'), '确认框【确认撤回】');
      await hm07vDriver.delayMs(2500);
      await idle();
      check((await maybe(ON.id('couli-basic-enable'), 6000)) !== null, 'HM05R_NOT_BASIC 撤回后应进入基本模式', await screenTexts());
      expectEq('withdraw keeps off on device', stored('enabled'), 'off');
      await launch(guestLaunch().with('couli_debug_open_route', 'Settings'));
      check((await maybe(ON.text('隐私中心'), 6000)) !== null, 'HM05R_BASIC_SETTINGS 基本模式设置页没打开', await screenTexts());
      check((await maybe(ON.id(ROW_ID), 1000)) === null, 'HM05R_BASIC_ROW 基本模式设置页不得显示剪贴板开关行');
      check((await maybe(ON.text(ROW_TITLE), 300)) === null, 'HM05R_BASIC_ROW_TEXT 基本模式设置页不得出现「' + ROW_TITLE + '」');
      await basicHome();
      expectEq('basic: no auto task', await foregroundRound(guestLaunch()), 0);
      await basicHome();
      // 重新同意隐私政策（基本模式【开启完整功能】→【同意】）
      await (await node(ON.id('couli-basic-enable'), '【开启完整功能】')).click();
      await idle();
      await tap(ON.text('同意'), '开启完整功能后【同意】');
      await hm07vDriver.delayMs(1500);
      check((await maybe(ON.id('home_search_row'), 6000)) !== null, 'HM05R_NOT_FULL 重新同意后应回到完整功能首页', await screenTexts());
      await noSheet('重新同意后');
      expectEq('re-agree keeps off: no auto task', await foregroundRound(guestLaunch()), 0);
      expectEq('re-agree: row back and still off', await (await openSettings(guestLaunch())).isChecked(), false);
      expectEq('never reported', reports(), 0);
    });
  });
}
