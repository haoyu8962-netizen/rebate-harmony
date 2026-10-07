// F-ALL-08（APP-03b 共性第 21–23 条，iOS 第 1 轮 I-R1-01..03 的三端核对）在鸿蒙的回归测试。
// 21：10402 后被拒凭据立刻从可读凭据中隔离，注册请求不带旧设备头，注册请求自己的失败不递归进入它所在的注册窗口；
// 22：复用、入队、结算在同一个同步区内完成，窗口结束时先有不可变结果、再解除在途、最后唤醒等待者，退避通知只发一次；
// 23：埋点队列清理项在启动环境对账之前登记（EntryAbility.onCreate 里 AppClientCore.compose 先于 AppConfig.start，属于
//     App 组合处，本文件只验清理项本身能删掉正式文件与临时文件）；
// 24：注册 flight 绑定清理世代，清理时摘掉旧 flight，旧等待者按已取消结算；
// 25：有效世代的 10402 一律隔离所用凭据（重放里再收到也一样），恢复只走一条退避链；
// 26：埋点异步上报的票据：sink 同步拒收或批次已结束（成功、失败、取消）时立刻结束并移除，只保留确实还在发送中的。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiResult, ClientEvents, FileOps, FileSlot, NetworkHeaders, PrivacyStateRaw, TrackerQueue, TrackerQueueCleaner,
  TransportRequest, TransportResponse, UploadTicket
} from '../../Index';
import { RegistryRig, SIGN_SECRET, registered } from './ClientCoreIntegration.test';
import { Deferred, envelope, flush, header, openLinkRequest } from './NetworkTestRig';

class PromiseHolder {
  value: Promise<boolean> | null = null;
}

/** 内存文件系统（含临时文件）。 */
class MemoryOps implements FileOps {
  readonly files: Map<string, string> = new Map<string, string>();

  exists(path: string): boolean {
    return this.files.has(path);
  }

  readText(path: string): string {
    return this.files.get(path) ?? '';
  }

  writeDurable(path: string, value: string): void {
    this.files.set(path, value);
  }

  rename(from: string, to: string): void {
    const v: string = this.files.get(from) ?? '';
    this.files.delete(from);
    this.files.set(to, v);
  }

  remove(path: string): void {
    this.files.delete(path);
  }
}

class TicketBox {
  tickets: UploadTicket[] = [];
}

function consentedQueue(): TrackerQueue {
  return new TrackerQueue((): string | null => null, (_v: string | null): void => {
  }, (_e: string[]): boolean => true, PrivacyStateRaw.CONSENTED, (): string | null => null, 'dev-1', 'harmony', '1.2.0',
    'session-1', (): number => 0, (): boolean => true);
}

export default function clientCoreFollowupTest() {
  describe('ClientCoreFollowupFALL08', () => {
    it('item21_joining_in_flight_window_isolates_rejected_credential_at_once', 0, async () => {
      const rr: RegistryRig = new RegistryRig();
      rr.store.deviceId = 'dev-old';
      rr.store.installSecret = SIGN_SECRET;
      // 普通注册在途（开始时旧凭据还读得到，它不会换凭据）。
      const plain: Promise<boolean> = rr.registry.register();
      const joined: Promise<boolean> = rr.registry.reregister('dev-old');
      // 隔离立刻生效：之后的请求（含注册请求）都不再带被拒的 device_id。
      expect(rr.registry.deviceId() === null).assertTrue();
      expect(await plain).assertTrue();
      // 窗口没有带来新凭据：这个被拒凭据的结果是失败，交给退避一次；没有另发注册。
      expect(await joined).assertFalse();
      expect(rr.lost).assertEqual(1);
      expect(rr.devicesSent().length).assertEqual(0);
      // 同一凭据晚到的 10402 复用这次结果，不再通知退避。
      expect(await rr.registry.reregister('dev-old')).assertFalse();
      expect(rr.lost).assertEqual(1);
    });

    it('item21_registration_request_never_carries_rejected_device_header', 0, async () => {
      const rr: RegistryRig = new RegistryRig();
      rr.store.deviceId = 'dev-old';
      rr.store.installSecret = SIGN_SECRET;
      rr.rig.server.handler = (request: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(request.url.indexOf('/v1/devices') >= 0 ? registered('dev-new') :
        header(request, NetworkHeaders.DEVICE_ID) === 'dev-old' ? envelope(10402, '{}') : envelope(0, '{}'));
      const result: ApiResult = await rr.rig.client.request(openLinkRequest());
      expect(result.ok).assertTrue();
      expect(rr.devicesSent().length).assertEqual(1);
      expect(header(rr.devicesSent()[0], NetworkHeaders.DEVICE_ID) === undefined).assertTrue();
    });

    it('item22_waiter_woken_after_window_end_reuses_immutable_result', 0, async () => {
      const rr: RegistryRig = new RegistryRig();
      rr.store.deviceId = 'dev-old';
      rr.store.installSecret = SIGN_SECRET;
      const registration: Deferred = new Deferred();
      rr.rig.server.handler = (request: TransportRequest): Promise<TransportResponse> =>
      request.url.indexOf('/v1/devices') >= 0 ? registration.promise : Promise.resolve(envelope(0, '{}'));
      const first: Promise<boolean> = rr.registry.reregister('dev-old');
      // 窗口在途时第二个同凭据 10402：同步复用同一结果（不另发）。
      const second: Promise<boolean> = rr.registry.reregister('dev-old');
      const holder: PromiseHolder = new PromiseHolder();
      // 等待者被唤醒时再来一个同凭据 10402：窗口已结束、在途已解除，必须拿到保存好的结果，而不是新开窗口或并入旧窗口。
      second.then((): void => {
        holder.value = rr.registry.reregister('dev-old');
      });
      await flush();
      expect(rr.devicesSent().length).assertEqual(1);
      registration.resolve(envelope(50001, '{}'));
      expect(await first).assertFalse();
      expect(await second).assertFalse();
      await flush();
      const late: Promise<boolean> | null = holder.value;
      expect(late !== null).assertTrue();
      if (late !== null) {
        expect(await late).assertFalse();
      }
      expect(rr.devicesSent().length).assertEqual(1);
      // 退避通知只发一次。
      expect(rr.lost).assertEqual(1);
    });

    it('item24_clear_detaches_old_flight_and_old_waiters_settle_as_cancelled', 0, async () => {
      const rr: RegistryRig = new RegistryRig();
      rr.store.deviceId = 'dev-old';
      rr.store.installSecret = SIGN_SECRET;
      const registrations: Deferred[] = [new Deferred(), new Deferred()];
      let index: number = 0;
      rr.rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        if (request.url.indexOf('/v1/devices') >= 0) {
          const d: Deferred = registrations[index];
          index++;
          return d.promise;
        }
        return Promise.resolve(envelope(0, '{}'));
      };
      const oldWaiter: Promise<boolean> = rr.registry.reregister('dev-old');
      await flush();
      expect(rr.devicesSent().length).assertEqual(1);
      // 撤回同意 / 切换环境的清理：摘掉旧 flight。
      rr.registry.clear();
      // 新世代的注册不并入旧 flight，自己发一次。
      const fresh: Promise<boolean> = rr.registry.register();
      await flush();
      expect(rr.devicesSent().length).assertEqual(2);
      // 旧 flight 晚到成功：按原始票据核对后作废，旧等待者按失败（已取消）结算，不保存旧世代的凭据。
      registrations[0].resolve(registered('dev-stale'));
      expect(await oldWaiter).assertFalse();
      expect(rr.store.deviceId === null).assertTrue();
      registrations[1].resolve(registered('dev-new'));
      expect(await fresh).assertTrue();
      expect(rr.store.deviceId).assertEqual('dev-new');
    });

    it('item25_replay_10402_still_isolates_credential_and_uses_single_backoff', 0, async () => {
      const rr: RegistryRig = new RegistryRig();
      rr.store.deviceId = 'dev-old';
      rr.store.installSecret = SIGN_SECRET;
      // 重新注册成功拿到 dev-new，但重放（带 dev-new）仍收到 10402。
      rr.rig.server.handler = (request: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(request.url.indexOf('/v1/devices') >= 0 ? registered('dev-new') : envelope(10402, '{}'));
      const result: ApiResult = await rr.rig.client.request(openLinkRequest());
      expect(result.ok).assertFalse();
      expect(rr.devicesSent().length).assertEqual(1);
      // 重放所用的 dev-new 也被隔离，恢复交给退避链（只通知一次）；不在这次调用里再注册。
      expect(rr.registry.deviceId() === null).assertTrue();
      expect(rr.lost).assertEqual(1);
      const second: ApiResult = await rr.rig.client.request(openLinkRequest());
      expect(second.ok).assertFalse();
    });

    it('item23_tracker_cleaner_removes_queue_and_temp_file_without_a_queue', 0, async () => {
      const ops: MemoryOps = new MemoryOps();
      const slot: FileSlot = new FileSlot('/sandbox/couli_tracker_queue.json', ops);
      ops.files.set('/sandbox/couli_tracker_queue.json', '{"format":1,"events":[]}');
      ops.files.set(FileSlot.tempOf('/sandbox/couli_tracker_queue.json'), 'half');
      const cleaner: TrackerQueueCleaner = new TrackerQueueCleaner((): void => slot.write(null));
      await cleaner.clean();
      expect(ops.files.size).assertEqual(0);
    });
    it('item26_sink_sync_reject_ends_and_removes_ticket_at_once', 0, async () => {
      const queue: TrackerQueue = consentedQueue();
      const box: TicketBox = new TicketBox();
      queue.asyncSink = (_events: string[], ticket: UploadTicket): Promise<boolean> => {
        box.tickets.push(ticket);
        throw new Error('sink refused');
      };
      queue.track(ClientEvents.appLaunch('Home'));
      queue.flush();
      expect(box.tickets.length).assertEqual(1);
      // 同步拒收：不等微任务，票据已结束并移除，不再算「发送中」。
      expect(box.tickets[0].valid).assertFalse();
      expect(box.tickets[0].sending).assertFalse();
      expect(queue.uploadInFlight === null).assertTrue();
      // 事件留在队列，下一次上报换新票据。
      expect(queue.queueSize).assertEqual(1);
      queue.asyncSink = (_events: string[], ticket: UploadTicket): Promise<boolean> => {
        box.tickets.push(ticket);
        return Promise.resolve(true);
      };
      queue.flush();
      expect(box.tickets.length).assertEqual(2);
    });

    it('item26_finished_batch_ticket_is_ended_and_only_sending_one_kept', 0, async () => {
      const queue: TrackerQueue = consentedQueue();
      const box: TicketBox = new TicketBox();
      const pending: Deferred = new Deferred();
      let call: number = 0;
      queue.asyncSink = (_events: string[], ticket: UploadTicket): Promise<boolean> => {
        box.tickets.push(ticket);
        call++;
        return call === 1 ? Promise.resolve(false) : pending.promise.then((): boolean => true);
      };
      queue.track(ClientEvents.appLaunch('Home'));
      queue.flush();
      expect(queue.uploadInFlight === box.tickets[0]).assertTrue();
      expect(box.tickets[0].valid).assertTrue();
      await flush();
      // 失败结束的批次：票据结束并移除（同一世代里也不再有效）。
      expect(box.tickets[0].valid).assertFalse();
      expect(queue.uploadInFlight === null).assertTrue();
      queue.flush();
      expect(box.tickets.length).assertEqual(2);
      expect(queue.uploadInFlight === box.tickets[1]).assertTrue();
      expect(box.tickets[1].sending).assertTrue();
      // 撤回同意取消在途批次：票据立刻结束并移除。
      queue.onPrivacyChanged(PrivacyStateRaw.BASIC_MODE);
      expect(box.tickets[1].sending).assertFalse();
      expect(queue.uploadInFlight === null).assertTrue();
      pending.resolve(envelope(0, '{}'));
      await flush();
      expect(queue.uploadInFlight === null).assertTrue();
    });
  });
}
