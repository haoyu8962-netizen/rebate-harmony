// F-X-25 t1（R3-04，D10-279）：生产的「待清标记」与「Web 数据归属记录」本身（FileTrustedAuthJournal / FileTrustedWebOwnerRecord + FileSlot）。
// 只替换文件操作端口（FileOps：内存实现，可注入临时文件残留与读写删失败）；类本身、原子写、残留处理都是产品代码。
import { describe, it, expect } from '@ohos/hypium';
import { FileOps, FileSlot } from '../main/ets/storage/FileSlot';
import { FileTrustedAuthJournal, FileTrustedWebOwnerRecord } from '../main/ets/bridge/TrustedAuthSync';

class Fx25RecordFiles implements FileOps {
  readonly files: Map<string, string> = new Map<string, string>();
  failRead: boolean = false;
  failWrite: boolean = false;
  failExists: boolean = false;
  failRemove: string[] = [];

  exists(path: string): boolean {
    if (this.failExists) {
      throw new Error('stat failed');
    }
    return this.files.has(path);
  }

  readText(path: string): string {
    const value: string | undefined = this.files.get(path);
    if (this.failRead || value === undefined) {
      throw new Error('read failed');
    }
    return value;
  }

  writeDurable(path: string, value: string): void {
    if (this.failWrite) {
      throw new Error('write failed');
    }
    this.files.set(path, value);
  }

  rename(from: string, to: string): void {
    const value: string | undefined = this.files.get(from);
    if (value === undefined) {
      throw new Error('no such file');
    }
    this.files.delete(from);
    this.files.set(to, value);
  }

  remove(path: string): void {
    if (this.failRemove.indexOf(path) >= 0) {
      throw new Error('remove failed');
    }
    this.files.delete(path);
  }
}

const OWNER_PATH: string = '/sandbox/couli_trusted_web.owner';
const PENDING_PATH: string = '/sandbox/couli_trusted_web.pending';

function throws(run: () => void): boolean {
  try {
    run();
    return false;
  } catch (e) {
    return true;
  }
}

export default function trustedWebRecordsFx25Test() {
  describe('TrustedWebRecords_FX25', () => {
    it('R01_owner_record_missing_is_null_then_round_trips_atomically', 0, () => {
      const files: Fx25RecordFiles = new Fx25RecordFiles();
      const record: FileTrustedWebOwnerRecord = new FileTrustedWebOwnerRecord(new FileSlot(OWNER_PATH, files));
      expect(record.readOwner()).assertNull();
      record.writeOwner('account:user-a');
      expect(record.readOwner()).assertEqual('account:user-a');
      expect(files.files.has(FileSlot.tempOf(OWNER_PATH))).assertFalse();
      record.writeOwner('guest');
      expect(record.readOwner()).assertEqual('guest');
      // 另起一个实例（冷启动）读到的是盘上的内容，不是进程内状态。
      const reboot: FileTrustedWebOwnerRecord = new FileTrustedWebOwnerRecord(new FileSlot(OWNER_PATH, files));
      expect(reboot.readOwner()).assertEqual('guest');
    });
    it('R02_owner_record_temp_residue_counts_as_the_record', 0, () => {
      const files: Fx25RecordFiles = new Fx25RecordFiles();
      // 上次写到一半（临时文件已 fsync、改名前进程被回收）：按临时文件的内容，而不是当作「没有记录」。
      files.files.set(FileSlot.tempOf(OWNER_PATH), 'account:user-a');
      const record: FileTrustedWebOwnerRecord = new FileTrustedWebOwnerRecord(new FileSlot(OWNER_PATH, files));
      expect(record.readOwner()).assertEqual('account:user-a');
      files.files.set(OWNER_PATH, 'account:user-b');
      expect(record.readOwner()).assertEqual('account:user-b');
    });
    it('R03_owner_record_read_and_write_failures_throw_not_null', 0, () => {
      const files: Fx25RecordFiles = new Fx25RecordFiles();
      const record: FileTrustedWebOwnerRecord = new FileTrustedWebOwnerRecord(new FileSlot(OWNER_PATH, files));
      files.files.set(OWNER_PATH, 'account:user-a');
      files.failRead = true;
      expect(throws((): void => {
        record.readOwner();
      })).assertTrue();
      files.failRead = false;
      files.failExists = true;
      expect(throws((): void => {
        record.readOwner();
      })).assertTrue();
      files.failExists = false;
      files.failWrite = true;
      expect(throws((): void => record.writeOwner('account:user-b'))).assertTrue();
      expect(record.readOwner()).assertEqual('account:user-a');
    });
    it('R04_pending_journal_missing_mark_clear_round_trip', 0, () => {
      const files: Fx25RecordFiles = new Fx25RecordFiles();
      const journal: FileTrustedAuthJournal = new FileTrustedAuthJournal(new FileSlot(PENDING_PATH, files));
      expect(journal.readPending()).assertNull();
      journal.markPending('user-a');
      expect(journal.readPending()).assertEqual('user-a');
      journal.markPending('');
      // 游客 / 未知的归属是空串，仍是「有标记」。
      expect(journal.readPending()).assertEqual('');
      journal.clearPending();
      expect(journal.readPending()).assertNull();
      expect(files.files.size).assertEqual(0);
    });
    it('R05_pending_journal_temp_residue_is_a_marker', 0, () => {
      const files: Fx25RecordFiles = new Fx25RecordFiles();
      files.files.set(FileSlot.tempOf(PENDING_PATH), 'user-a');
      const journal: FileTrustedAuthJournal = new FileTrustedAuthJournal(new FileSlot(PENDING_PATH, files));
      expect(journal.readPending()).assertEqual('user-a');
      journal.clearPending();
      expect(journal.readPending()).assertNull();
      expect(files.files.has(FileSlot.tempOf(PENDING_PATH))).assertFalse();
    });
    it('R06_pending_journal_failures_throw_and_marker_survives_failed_clear', 0, () => {
      const files: Fx25RecordFiles = new Fx25RecordFiles();
      const journal: FileTrustedAuthJournal = new FileTrustedAuthJournal(new FileSlot(PENDING_PATH, files));
      files.failWrite = true;
      expect(throws((): void => journal.markPending('user-a'))).assertTrue();
      expect(journal.readPending()).assertNull();
      files.failWrite = false;
      journal.markPending('user-a');
      files.files.set(FileSlot.tempOf(PENDING_PATH), 'user-a');
      files.failRemove = [FileSlot.tempOf(PENDING_PATH)];
      expect(throws((): void => journal.clearPending())).assertTrue();
      // 临时文件删不掉：仍然报「有标记」，切号处理不得据此认为清理完成。
      expect(journal.readPending()).assertEqual('user-a');
      files.failRemove = [];
      files.failExists = true;
      expect(throws((): void => {
        journal.readPending();
      })).assertTrue();
    });
  });
}
