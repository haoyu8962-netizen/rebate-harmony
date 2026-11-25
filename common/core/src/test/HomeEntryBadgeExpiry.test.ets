// FU-HM-HOME-ENTRY-OBJECT-FIELDS 写测（控制器）：金刚区徽标 expire_at 到点隐藏、保留条目、不重拉页面（D10-2998「照公告条做法」、D10-3076）。
// 共用接口（NATIVE/FU-HM-HOME-ENTRY-OBJECT-FIELDS/brief-common.md）：HomeCardView.iconBadges: (string | null)[] 与 card.icons 一一对齐，
// 此刻（snapshot 的 now）可显示的徽标文字——kind = text 且在期（now < expireMs）为 text，其余为 null；snapshot 把未到期 text 徽标的
// expireMs 并进最近到期时刻（nextExpiry → scheduleNoticeExpiry → publish）。iconBadges 是新符号，经 Reflect 读，保证在 1ae0473 上能编译、靠断言红。
// 装配照 HomeIntegration：假时钟 = ManualTimer.now（T0 = 2026-10-10T10:00:00+08:00），假计时 = ManualTimer，publish 计数 = f.snapshots，
// 拉取计数 = f.contract.pages / items。安卓对照 rebate-android 1f87039 HomeEntryBadgeControllerTest.kt；安卓评审 S3-2 的缺口（两个徽标先后到期）这里补上。
// 先红：1ae0473 上 HomeCardView 没有 iconBadges（读到 undefined → badges() 返回 '<无 iconBadges>'），且对象 badge 整条丢；以下每条都在第一条
// badges 断言红。
import { describe, it, expect } from '@ohos/hypium';
import { HomeCardView, HomeController, HomeDeps, HomeIconItem, HomeSnapshot, HomeTimer } from '../../Index';
import { HomeFixture, notice, ok, page, settle, T0 } from './HomeIntegration.test';

const ICON: string = 'https://img.example.com/i.png';
const MIN: number = 60 * 1000;
const HOUR: number = 60 * MIN;

function q(s: string): string {
  return JSON.stringify(s);
}

function cell(title: string, badge: string | null): string {
  return '{"icon":' + q(ICON) + ',"title":' + q(title) + ',"action":{"route":"Help"}'
    + (badge === null ? '' : ',"badge":' + badge) + '}';
}

function text(t: string, expireAt: string | null): string {
  return '{"kind":"text","text":' + q(t) + (expireAt === null ? '' : ',"expire_at":' + q(expireAt)) + '}';
}

function grid(cells: string[]): string {
  return '{"id":"icons","type":"icon_grid","version":1,"props":{"columns":4},"data_source":{"kind":"static","items":['
    + cells.join(',') + ']}}';
}

/** 此刻快照里金刚区每格的可显示徽标：text → 文字，null → '-'。 */
function badges(f: HomeFixture): string {
  const v: HomeCardView = f.card('icons');
  const raw: Object | null | undefined = Reflect.get(v, 'iconBadges') as Object | null | undefined;
  if (raw === undefined || raw === null || !Array.isArray(raw)) {
    return '<无 iconBadges>';
  }
  return (raw as (string | null)[]).map((b: string | null): string => b === null ? '-' : b).join(',');
}

function titles(f: HomeFixture): string {
  return f.card('icons').card.icons.map((i: HomeIconItem): string => i.title).join(',');
}

/** 走网络：起控制器、首个 getPage 返回 sections。 */
async function startWithNetwork(f: HomeFixture, sections: string[]): Promise<HomeController> {
  const c: HomeController = f.controller();
  c.start();
  f.contract.pages[0].resolve(ok(page(7, sections)));
  await settle();
  return c;
}

/** 不走网络（Release 口径：没有数据源，直接显示 LKG）：没有 1.5 秒等待计时，publish 次数只来自到期重算。 */
function startFromLkg(f: HomeFixture, sections: string[]): HomeController {
  f.withContract = false;
  f.lkg.save(f.identity.scope, page(7, sections));
  const c: HomeController = f.controller();
  c.start();
  return c;
}

// ---------------------------------------------------------------- 评审 r1 F1 / F4：setTimeout 延时上限
// HarmonyOS SDK global.d.ts（setTimeout 的 delay 第 3 条）：「If it exceeds 2^31 - 1, an overflow will occur and the delay value will be set to 0」。
// ManualTimer 没有这个上限，所以另写一个记录 ms 的计时器：照记 schedule 的入参，再按真机口径（> 2147483647 → 0）转交 f.timer；
// 时钟仍是 f.timer.now。控制器按 HomeFixture.controller() 的接线自己组装（只换 deps.timer；不走网络，与 startFromLkg 同口径）。

/** setTimeout 的延时上限 2^31 − 1。 */
const TIMER_MAX: number = 2147483647;
const DAY: number = 24 * HOUR;

class RecordingTimer implements HomeTimer {
  readonly inner: HomeTimer;
  readonly waits: number[] = [];

  constructor(inner: HomeTimer) {
    this.inner = inner;
  }

  schedule(ms: number, run: () => void): number {
    this.waits.push(ms);
    return this.inner.schedule(ms > TIMER_MAX ? 0 : ms, run);
  }

  cancel(id: number): void {
    this.inner.cancel(id);
  }

  last(): number {
    return this.waits[this.waits.length - 1];
  }

  /** 交给计时器的等待时长里不在 1..2147483647 的（空串 = 全部合规）。 */
  outOfRange(): string {
    return this.waits.filter((ms: number): boolean => ms < 1 || ms > TIMER_MAX).join(',');
  }
}

/** 不走网络、从 LKG 起控制器（同 startFromLkg），deps.timer 换成 RecordingTimer。 */
function startFromLkgRecording(f: HomeFixture, sections: string[]): RecordingTimer {
  f.withContract = false;
  f.lkg.save(f.identity.scope, page(7, sections));
  const t: RecordingTimer = new RecordingTimer(f.timer);
  const deps: HomeDeps = new HomeDeps(f.identity, (): string => f.identity.key, f.lkg, f.local, f.gate);
  deps.contract = null;
  deps.clock = (): number => f.timer.now;
  deps.timer = t;
  deps.appVersion = '1.10.0';
  deps.dedupe = f.dedupe;
  deps.defaultJson = (): string | null => f.defaultJson;
  deps.blockers = (): string[] => f.blockers;
  deps.coldStartShown = (): boolean => f.shownThisRun;
  deps.markColdStartShown = (): void => {
    f.shownThisRun = true;
  };
  const c: HomeController = new HomeController(deps);
  c.onChange = (s: HomeSnapshot): void => {
    f.snapshots.push(s);
  };
  f.currentCtl = c;
  c.start();
  return t;
}

export default function homeEntryBadgeExpiryTest() {
  describe('HomeEntryBadgeExpiry', () => {
    it('C01_before_expiry_text_shows_and_dot_none_are_null', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      await startWithNetwork(f, [grid([
        cell('甲', text('新', '2026-10-10T10:10:00+08:00')),
        cell('乙', '{"kind":"dot"}'),
        cell('丙', '{"kind":"none"}'),
        cell('丁', text('热', null)),
        cell('戊', null)
      ])]);
      expect(badges(f)).assertEqual('新,-,-,热,-');
      expect(titles(f)).assertEqual('甲,乙,丙,丁,戊');
      expect(f.ids().join(',')).assertEqual('icons');
    });

    it('C02_expiry_hides_badge_keeps_cells_and_does_not_refetch', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      await startWithNetwork(f, [grid([
        cell('甲', text('新', '2026-10-10T10:10:00+08:00')),
        cell('乙', '{"kind":"dot"}'),
        cell('丙', text('热', null))
      ])]);
      expect(badges(f)).assertEqual('新,-,热');
      // 到期前 1 毫秒仍显示（now < expireMs）。
      f.timer.advance(10 * MIN - 1);
      expect(badges(f)).assertEqual('新,-,热');
      const before: number = f.snapshots.length;
      // 时钟走到 expireMs、计时触发：重新发布一次，该位为 null，格子与条数不变，页面没有重拉。
      f.timer.advance(1);
      expect(f.snapshots.length).assertEqual(before + 1);
      expect(f.timer.now).assertEqual(T0 + 10 * MIN);
      expect(badges(f)).assertEqual('-,-,热');
      expect(titles(f)).assertEqual('甲,乙,丙');
      expect(f.card('icons').iconTaps.length).assertEqual(3);
      expect(f.ids().join(',')).assertEqual('icons');
      expect(f.contract.pages.length).assertEqual(1);
      expect(f.contract.items.length).assertEqual(0);
    });

    // 安卓 S3-2：两个徽标先后到期依次隐藏（每次到期后要按下一个到期时刻重排）。第二个带小数秒，钉到毫秒。
    it('C03_two_badges_expire_one_after_another', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      await startWithNetwork(f, [grid([
        cell('甲', text('新', '2026-10-10T10:05:00+08:00')),
        cell('乙', text('热', '2026-10-10T10:10:00.5+08:00')),
        cell('丙', text('惠', null))
      ])]);
      expect(badges(f)).assertEqual('新,热,惠');
      f.timer.advance(5 * MIN);
      expect(badges(f)).assertEqual('-,热,惠');
      expect(titles(f)).assertEqual('甲,乙,丙');
      f.timer.advance(5 * MIN);
      expect(badges(f)).assertEqual('-,热,惠');
      const before: number = f.snapshots.length;
      f.timer.advance(499);
      expect(f.snapshots.length).assertEqual(before);
      f.timer.advance(1);
      expect(f.snapshots.length).assertEqual(before + 1);
      expect(badges(f)).assertEqual('-,-,惠');
      expect(titles(f)).assertEqual('甲,乙,丙');
      expect(f.contract.pages.length).assertEqual(1);
      expect(f.contract.items.length).assertEqual(0);
    });

    // 已过期（含恰好等于此刻：now >= expireMs 即隐藏）的徽标一开始就不显示，条目照常。
    it('C04_already_expired_badge_never_shows', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      await startWithNetwork(f, [grid([
        cell('甲', text('旧', '2026-10-10T09:59:59.999+08:00')),
        cell('乙', text('临', '2026-10-10T10:00:00+08:00')),
        cell('丙', text('新', '2026-10-10T11:00:00+08:00'))
      ])]);
      expect(f.timer.now).assertEqual(T0);
      expect(badges(f)).assertEqual('-,-,新');
      expect(titles(f)).assertEqual('甲,乙,丙');
    });

    // 没有 expire_at 的徽标不排计时：时钟走很久也不重新发布、徽标照常。
    it('C05_badges_without_expire_at_schedule_nothing', 0, () => {
      const f: HomeFixture = new HomeFixture();
      startFromLkg(f, [grid([
        cell('甲', text('新', null)),
        cell('乙', text('热', null)),
        cell('丙', null)
      ])]);
      expect(badges(f)).assertEqual('新,热,-');
      const before: number = f.snapshots.length;
      f.timer.advance(7 * 24 * HOUR);
      expect(f.snapshots.length).assertEqual(before);
      expect(badges(f)).assertEqual('新,热,-');
    });

    // dot / none 本就不显示，带 expire_at 也不排计时（brief-common：只把未到期的 text 徽标并进最近到期时刻）。
    it('C06_dot_and_none_expire_at_schedule_nothing', 0, () => {
      const f: HomeFixture = new HomeFixture();
      startFromLkg(f, [grid([
        cell('甲', '{"kind":"dot","expire_at":"2026-10-10T11:00:00+08:00"}'),
        cell('乙', '{"kind":"none","expire_at":"2026-10-10T12:00:00+08:00"}'),
        cell('丙', text('惠', null))
      ])]);
      expect(badges(f)).assertEqual('-,-,惠');
      const before: number = f.snapshots.length;
      f.timer.advance(3 * HOUR);
      expect(f.snapshots.length).assertEqual(before);
      expect(titles(f)).assertEqual('甲,乙,丙');
    });

    // 与公告条共用最近到期时刻：公告先到期照常隐藏（徽标不受影响），之后徽标到期再隐藏；每次到期只重新发布一次。
    it('C07_notice_expiry_unaffected_and_badge_expiry_follows', 0, () => {
      const f: HomeFixture = new HomeFixture();
      startFromLkg(f, [notice('nb', 'N1', 1, false, '2026-10-10T10:05:00+08:00'), grid([
        cell('甲', text('新', '2026-10-10T10:10:00+08:00')),
        cell('乙', text('热', null))
      ])]);
      expect(f.ids().join(',')).assertEqual('nb,icons');
      expect(badges(f)).assertEqual('新,热');
      let before: number = f.snapshots.length;
      f.timer.advance(5 * MIN);
      expect(f.snapshots.length).assertEqual(before + 1);
      expect(f.ids().join(',')).assertEqual('icons');
      expect(badges(f)).assertEqual('新,热');
      before = f.snapshots.length;
      f.timer.advance(5 * MIN);
      expect(f.snapshots.length).assertEqual(before + 1);
      expect(badges(f)).assertEqual('-,热');
      expect(titles(f)).assertEqual('甲,乙');
      before = f.snapshots.length;
      f.timer.advance(24 * HOUR);
      expect(f.snapshots.length).assertEqual(before);
    });

    // 徽标先到期、公告后到期：徽标的到期不吞掉公告的计时（重排后仍按公告 end_at 再排一次）。
    it('C08_badge_first_then_notice_still_expires', 0, () => {
      const f: HomeFixture = new HomeFixture();
      startFromLkg(f, [notice('nb', 'N1', 1, false, '2026-10-10T10:10:00+08:00'), grid([
        cell('甲', text('新', '2026-10-10T10:05:00+08:00'))
      ])]);
      expect(f.ids().join(',')).assertEqual('nb,icons');
      expect(badges(f)).assertEqual('新');
      f.timer.advance(5 * MIN);
      expect(badges(f)).assertEqual('-');
      expect(f.ids().join(',')).assertEqual('nb,icons');
      f.timer.advance(5 * MIN);
      expect(f.ids().join(',')).assertEqual('icons');
      expect(titles(f)).assertEqual('甲');
    });

    // 评审 r1 F1（S1）。先红：c982108 上 scheduleNoticeExpiry 把 expire_at − now = 30 天 = 2592000000 ms 原样交给计时器，
    // 在第一条 outOfRange 断言红（读到 '2592000000'）。修后：等待时长 ≤ 2147483647；提前触发时重算、徽标仍显示，
    // 按 min(剩余, 2147483647) 再排（封顶取 2147483647 时为 2592000000 − 2147483647 = 444516353）；走到 expire_at 才隐藏、条目保留。
    it('C09_badge_expiring_in_30_days_waits_within_timer_max', 0, () => {
      const f: HomeFixture = new HomeFixture();
      const exp: number = T0 + 30 * DAY;
      const t: RecordingTimer = startFromLkgRecording(f, [grid([
        cell('甲', text('新', '2026-11-09T10:00:00+08:00')),
        cell('乙', text('热', null))
      ])]);
      expect(exp - T0).assertEqual(2592000000);
      expect(t.waits.length > 0).assertTrue();
      expect(t.outOfRange()).assertEqual('');
      expect(badges(f)).assertEqual('新,热');
      // 真机口径下超限会变成 0 立刻触发：此刻不应再发布（不空转）。
      let before: number = f.snapshots.length;
      f.timer.advance(0);
      expect(f.snapshots.length).assertEqual(before);
      // 走到这次计时的触发时刻：重新发布一次，徽标仍显示，按剩余时长再排一次（不超上限）。
      const w1: number = t.last();
      f.timer.advance(w1 - 1);
      expect(f.snapshots.length).assertEqual(before);
      const scheduled: number = t.waits.length;
      f.timer.advance(1);
      expect(f.snapshots.length).assertEqual(before + 1);
      expect(f.timer.now < exp).assertTrue();
      expect(badges(f)).assertEqual('新,热');
      expect(titles(f)).assertEqual('甲,乙');
      expect(t.waits.length > scheduled).assertTrue();
      expect(t.last()).assertEqual(Math.min(exp - f.timer.now, TIMER_MAX));
      expect(t.outOfRange()).assertEqual('');
      // 走到 expire_at：隐藏徽标、保留条目，之后不再排计时、不再发布。
      before = f.snapshots.length;
      f.timer.advance(exp - f.timer.now - 1);
      expect(f.snapshots.length).assertEqual(before);
      expect(badges(f)).assertEqual('新,热');
      f.timer.advance(1);
      expect(f.timer.now).assertEqual(exp);
      expect(f.snapshots.length).assertEqual(before + 1);
      expect(badges(f)).assertEqual('-,热');
      expect(titles(f)).assertEqual('甲,乙');
      before = f.snapshots.length;
      f.timer.advance(30 * DAY);
      expect(f.snapshots.length).assertEqual(before);
    });

    // 评审 r1 F4（与 F1 同根，1ae0473 起就有）：公告 end_at 在 30 天后。先红：c982108 上第一条 outOfRange 断言红（'2592000000'）。
    // 修后：等待时长 ≤ 2147483647；提前触发后公告仍显示，按 min(剩余, 2147483647) 再排；走到 end_at 才隐藏。
    it('C10_notice_ending_in_30_days_waits_within_timer_max', 0, () => {
      const f: HomeFixture = new HomeFixture();
      const end: number = T0 + 30 * DAY;
      const t: RecordingTimer = startFromLkgRecording(f, [notice('nb', 'N1', 1, false, '2026-11-09T10:00:00+08:00'), grid([
        cell('甲', text('热', null))
      ])]);
      expect(t.waits.length > 0).assertTrue();
      expect(t.outOfRange()).assertEqual('');
      expect(f.ids().join(',')).assertEqual('nb,icons');
      let before: number = f.snapshots.length;
      f.timer.advance(0);
      expect(f.snapshots.length).assertEqual(before);
      const w1: number = t.last();
      f.timer.advance(w1 - 1);
      expect(f.snapshots.length).assertEqual(before);
      f.timer.advance(1);
      expect(f.snapshots.length).assertEqual(before + 1);
      expect(f.timer.now < end).assertTrue();
      expect(f.ids().join(',')).assertEqual('nb,icons');
      expect(t.last()).assertEqual(Math.min(end - f.timer.now, TIMER_MAX));
      expect(t.outOfRange()).assertEqual('');
      before = f.snapshots.length;
      f.timer.advance(end - f.timer.now);
      expect(f.snapshots.length).assertEqual(before + 1);
      expect(f.ids().join(',')).assertEqual('icons');
      expect(badges(f)).assertEqual('热');
    });
  });
}
