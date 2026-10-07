// APP-06a 鸿蒙第 3 轮评审（harmony-review-r3.md）的复现测试。
// R3-01：条件请求返回 304 = 服务端重新确认当前配置。ConfigStore 把本次拉取记为已应用并通知订阅者，
// search_disabled 分界之后的 304 能恢复明确为 on 的平台；禁用前已在途的拉取带回的 304 不提前恢复。
import { describe, it, expect } from '@ohos/hypium';
import { ConfigReply, ConfigSnapshot, ConfigStore, SearchConfigPort, SearchController } from '../../Index';
import { flush } from './NetworkTestRig';
import { LeakyPort } from './SearchReviewR1.test';

const DISABLED_JD: string = '{"platform":"jd","reason":"search_disabled"}';
const BUNDLED: string = '{"features":{"search_status":{"taobao":"on","jd":"on"}}}';
const JD_ON: string = '{"features":{"search_status":{"taobao":"on","jd":"on"}}}';

/** 手动结算的配置拉取器：记录每次带的 If-None-Match，按顺序回复 ok / 304 / 失败。 */
class ManualFetcher {
  sentEtags: (string | null)[] = [];
  pending: ((reply: ConfigReply) => void)[] = [];

  fetch(etag: string | null, done: (reply: ConfigReply) => void): void {
    this.sentEtags.push(etag);
    this.pending.push(done);
  }

  get calls(): number {
    return this.sentEtags.length;
  }

  private next(reply: ConfigReply): void {
    const done: ((reply: ConfigReply) => void) | undefined = this.pending.shift();
    if (done !== undefined) {
      done(reply);
    }
  }

  ok(bodyJson: string, etag: string | null): void {
    this.next(new ConfigReply(ConfigReply.OK, bodyJson, etag));
  }

  notModified(etag: string | null): void {
    this.next(new ConfigReply(ConfigReply.NOT_MODIFIED, null, etag));
  }

  fail(): void {
    this.next(new ConfigReply(ConfigReply.FAILURE, null, null));
  }
}

/** 与 entry AppSearchConfigPort 同一接线。 */
class StoreConfigPort implements SearchConfigPort {
  private readonly store: ConfigStore;

  constructor(store: ConfigStore) {
    this.store = store;
  }

  refresh(): void {
    this.store.requestFresh();
  }

  issuedMark(): number {
    return this.store.issuedFetchId;
  }

  appliedMark(): number {
    return this.store.appliedFetchId;
  }

  subscribe(listener: () => void): () => void {
    return this.store.subscribe((): void => listener());
  }
}

class Disk {
  value: string | null = null;
  writes: number = 0;
}

function makeStore(fetcher: ManualFetcher, disk: Disk): ConfigStore {
  return new ConfigStore((): string | null => disk.value, (v: string | null): void => {
    disk.writes++;
    disk.value = v;
  }, (etag: string | null, done: (reply: ConfigReply) => void): void => fetcher.fetch(etag, done), (): number => 0,
    BUNDLED);
}

export default function searchReviewR3Test() {
  describe('SearchReviewR3', () => {
    it('r3_01_disabled_then_refresh_fails_then_reopened_304_restores_tab', 0, async () => {
      // 京东 on 的配置及 ETag → 搜索 search_disabled，Tab 隐藏 → 自动刷新失败 → 京东恢复原值 → 回前台 304 → 恢复。
      const fetcher: ManualFetcher = new ManualFetcher();
      const store: ConfigStore = makeStore(fetcher, new Disk());
      store.onColdStart();
      fetcher.ok(JD_ON, '"e1"');
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => store.searchStatusLayers(),
        new StoreConfigPort(store));
      c.open('milk', 'jd');
      port.calls[0].fail(50304, DISABLED_JD);
      await flush();
      expect(JSON.stringify(c.snapshot.tabs)).assertEqual('["taobao"]');
      // 自动刷新（requestFresh 立即发出第 2 次）失败：继续隐藏。
      expect(fetcher.calls).assertEqual(2);
      fetcher.fail();
      expect(JSON.stringify(c.snapshot.tabs)).assertEqual('["taobao"]');
      // 回前台：条件请求带原 ETag，服务端配置已恢复原值 → 304 → 京东 Tab 恢复，选中仍是淘宝。
      store.onForeground();
      expect(fetcher.calls).assertEqual(3);
      expect(fetcher.sentEtags[2]).assertEqual('"e1"');
      fetcher.notModified('"e1"');
      expect(JSON.stringify(c.snapshot.tabs)).assertEqual('["taobao","jd"]');
      expect(c.snapshot.platform).assertEqual('taobao');
      expect(c.selectTab('jd')).assertTrue();
      expect(port.calls[port.calls.length - 1].request.query).assertEqual('q=milk&platform=jd&sort=relevance');
      c.leave();
    });

    it('r3_01_in_flight_304_issued_before_disable_does_not_restore_until_next_fetch', 0, async () => {
      const fetcher: ManualFetcher = new ManualFetcher();
      const store: ConfigStore = makeStore(fetcher, new Disk());
      store.onColdStart();
      fetcher.ok(JD_ON, '"e1"');
      // 回前台的第 2 次拉取在途（禁用前发出）。
      store.onForeground();
      expect(fetcher.calls).assertEqual(2);
      const port: LeakyPort = new LeakyPort();
      const c: SearchController = new SearchController(port, () => store.searchStatusLayers(),
        new StoreConfigPort(store));
      c.open('milk', 'jd');
      port.calls[0].fail(50304, DISABLED_JD);
      await flush();
      expect(JSON.stringify(c.snapshot.tabs)).assertEqual('["taobao"]');
      expect(fetcher.calls).assertEqual(2);
      // 在途的第 2 次带回 304：编号不大于分界，不提前恢复；结算后补发第 3 次。
      fetcher.notModified('"e1"');
      expect(store.appliedFetchId).assertEqual(2);
      expect(JSON.stringify(c.snapshot.tabs)).assertEqual('["taobao"]');
      expect(fetcher.calls).assertEqual(3);
      expect(fetcher.sentEtags[2]).assertEqual('"e1"');
      // 补发的第 3 次 304 确认：恢复。
      fetcher.notModified('"e1"');
      expect(store.appliedFetchId).assertEqual(3);
      expect(JSON.stringify(c.snapshot.tabs)).assertEqual('["taobao","jd"]');
      c.leave();
    });

    it('r3_01_config_store_304_advances_applied_id_and_notifies_failure_does_not', 0, () => {
      const fetcher: ManualFetcher = new ManualFetcher();
      const disk: Disk = new Disk();
      const store: ConfigStore = makeStore(fetcher, disk);
      const seen: ConfigSnapshot[] = [];
      store.subscribe((s: ConfigSnapshot): void => {
        seen.push(s);
      });
      store.onColdStart();
      // 没有当前配置时（冷启动不带 If-None-Match）收到的 304：不改任何内容、不推进、不通知。
      const coldCount: number = seen.length;
      expect(fetcher.sentEtags[0]).assertNull();
      fetcher.notModified('"x"');
      expect(store.appliedFetchId).assertEqual(0);
      expect(seen.length).assertEqual(coldCount);
      expect(store.sourceRaw).assertEqual('bundled');
      // 成功：编号 2。
      store.onForeground();
      fetcher.ok(JD_ON, '"e1"');
      expect(store.appliedFetchId).assertEqual(2);
      const writes: number = disk.writes;
      const saved: string | null = disk.value;
      const json: string = store.snapshotJson;
      const count: number = seen.length;
      // 失败：不推进、不通知。
      store.onForeground();
      fetcher.fail();
      expect(store.appliedFetchId).assertEqual(2);
      expect(seen.length).assertEqual(count);
      // 304：推进到本次编号并通知一次；内容、来源层、LKG 文件不变。
      store.onForeground();
      expect(fetcher.sentEtags[3]).assertEqual('"e1"');
      fetcher.notModified('"e2"');
      expect(store.appliedFetchId).assertEqual(4);
      expect(seen.length).assertEqual(count + 1);
      expect(seen[seen.length - 1].dataJson).assertEqual(json);
      expect(seen[seen.length - 1].sourceRaw).assertEqual('current');
      expect(store.snapshotJson).assertEqual(json);
      expect(disk.writes).assertEqual(writes);
      expect(disk.value).assertEqual(saved);
      // ETag 不被 304 改写：下一次条件请求仍带最近一次成功响应的 ETag。
      store.onForeground();
      expect(fetcher.sentEtags[4]).assertEqual('"e1"');
      fetcher.fail();
      expect(store.appliedFetchId).assertEqual(4);
      // 环境切换后晚到的 304 丢弃（不推进）。
      store.onForeground();
      store.clearForEnvironmentSwitch();
      fetcher.notModified('"e1"');
      expect(store.appliedFetchId).assertEqual(0);
    });
  });
}
