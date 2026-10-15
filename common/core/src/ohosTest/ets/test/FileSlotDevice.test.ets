// FU-HM-0718 第 1 轮修复 R1-01：独立撤销标记（沙盒文件）的真实文件查询失败（设备测试，鸿蒙模拟器 / 真机）。
// 用生产默认的 SystemFileOps（SystemFileProbe → fileIo.statSync）与 FileSlot，在应用沙盒 filesDir 下实际制造查询失败：
// - 普通文件下的子路径（标记所在目录被换成普通文件）：statSync 报「不是目录」；
// - 不可查询的目录（应用无搜索权限）下的路径：statSync 报权限错误；
// - 标记位置是目录：statSync 成功、读取报「是目录」。
// 断言：只有明确不存在（13900002）算没有标记（FileSlot.read 为 null），其余上抛；会话按读不出（unreadable，世代 null），
// 不缓存成「没有标记」——恢复可读前后都不放行已撤销的会话。Local Test（src/test）里 fileIo 是空实现，那边的故障注入用例照留。
import { describe, it, expect, beforeAll, afterAll } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  FileSlot, MemorySecureStore, SecureSessionTokens, SessionReadStatus, SessionRevocation, SessionTokenSet, SystemFileOps
} from '../../../../Index';

const NO_SUCH_FILE: number = 13900002;
const PERMISSION_DENIED: number = 13900012;
const NOT_A_DIRECTORY: number = 13900018;
const MARK_NAME: string = 'couli_session.revoked';
const TOKENS_ALIAS: string = 'session_tokens';
const EPOCH: string = 'fhm0718-r1-epoch';

/**
 * 应用无权查询的目录下的路径（目录没有给应用 uid 搜索权限，statSync 报 13900012）。应用自己没有 chmod 接口（@ohos.file.fs 不提供），
 * 所以用系统里现成的这类目录：模拟器（API 20）上 /config 与 /data/storage/el1/bundle/misc 实测如此；用第一个在本机报权限错误的。
 * 沙盒外不可见的路径（/data/app、/proc/1/root 等）在沙盒里是「不存在」（13900002），不能用。
 */
const DENIED_CANDIDATES: string[] = ['/config/' + MARK_NAME, '/data/storage/el1/bundle/misc/' + MARK_NAME];

/** 写不进、删不掉的安全存储（撤销只落在独立文件里：FU-HM-0715 R1-02 的兜底路径）。 */
class LockedStore extends MemorySecureStore {
  locked: boolean = false;

  set(alias: string, value: string): void {
    if (this.locked) {
      throw new Error('asset add failed');
    }
    super.set(alias, value);
  }

  remove(alias: string): void {
    if (this.locked) {
      throw new Error('asset remove failed');
    }
    super.remove(alias);
  }
}

function filesDir(): string {
  return abilityDelegatorRegistry.getAbilityDelegator().getAppContext().filesDir;
}

function errorCode(action: () => void): number {
  try {
    action();
  } catch (e) {
    return (e as BusinessError).code ?? -1;
  }
  return 0;
}

function writeText(path: string, text: string): void {
  const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
  try {
    fileIo.writeSync(file.fd, text);
  } finally {
    fileIo.closeSync(file);
  }
}

function removeTree(path: string): void {
  let isDir: boolean = false;
  try {
    isDir = fileIo.statSync(path).isDirectory();
  } catch (e) {
    return;
  }
  if (isDir) {
    fileIo.rmdirSync(path);
  } else {
    fileIo.unlinkSync(path);
  }
}

/** DENIED_CANDIDATES 里第一个在本机报权限错误的（都不是则为空串，断言失败）。 */
function deniedPath(): string {
  for (const candidate of DENIED_CANDIDATES) {
    const code: number = errorCode(() => fileIo.statSync(candidate));
    console.info('fhm0718_r1 statSync ' + candidate + ' -> ' + code);
    if (code === PERMISSION_DENIED) {
      return candidate;
    }
  }
  return '';
}

function throwsCode(action: () => void): number {
  const code: number = errorCode(action);
  expect(code !== 0).assertTrue();
  return code;
}

/** 一种「查不了」的现场：break 让标记查不了，repair 恢复原样（原标记内容还在）。 */
class Fault {
  readonly name: string;
  readonly breakIt: (dir: string, mark: string) => void;
  readonly repair: (dir: string, mark: string) => void;

  constructor(name: string, breakIt: (dir: string, mark: string) => void, repair: (dir: string, mark: string) => void) {
    this.name = name;
    this.breakIt = breakIt;
    this.repair = repair;
  }
}

function faults(): Fault[] {
  return [
    // 标记所在目录被换成普通文件：标记路径成了「普通文件下的子路径」。
    new Fault('dir_replaced_by_plain_file', (dir: string, _mark: string): void => {
      fileIo.renameSync(dir, dir + '.aside');
      writeText(dir, 'not a directory');
    }, (dir: string, _mark: string): void => {
      fileIo.unlinkSync(dir);
      fileIo.renameSync(dir + '.aside', dir);
    }),
    // 标记位置是目录。
    new Fault('mark_is_directory', (_dir: string, mark: string): void => {
      fileIo.renameSync(mark, mark + '.aside');
      fileIo.mkdirSync(mark);
    }, (_dir: string, mark: string): void => {
      fileIo.rmdirSync(mark);
      fileIo.renameSync(mark + '.aside', mark);
    })
  ];
}

/** 进程 1：登录（令牌带登录世代）后退出登录，安全存储写不进、删不掉——撤销只落进真实沙盒文件。 */
function seedRevokedOnlyInFile(store: LockedStore, slot: FileSlot): void {
  const p1: SecureSessionTokens = new SecureSessionTokens(store, slot);
  p1.save(new SessionTokenSet('acc-1', 'ref-1', 'full', 'user-1', EPOCH));
  expect(p1.readStatus()).assertEqual(SessionReadStatus.PRESENT);
  store.locked = true;
  let threw: boolean = false;
  try {
    p1.clear();
  } catch (e) {
    threw = true;
  }
  expect(threw).assertTrue();
  expect(store.get(TOKENS_ALIAS) !== null).assertTrue();
  expect(slot.read()).assertEqual(SessionRevocation.encode('e:' + EPOCH));
}

/** 冷启动（同一份存储、默认 SystemFileOps 的 FileSlot）。 */
function rebuild(store: LockedStore, markPath: string): SecureSessionTokens {
  return new SecureSessionTokens(store, new FileSlot(markPath));
}

function expectNoSession(tokens: SecureSessionTokens, status: string): void {
  expect(tokens.accessToken()).assertNull();
  expect(tokens.loginEpoch()).assertNull();
  expect(tokens.readStatus()).assertEqual(status);
}

export default function fileSlotDeviceTest() {
  describe('fileSlotDeviceTest', () => {
    let root: string = '';

    beforeAll(() => {
      root = filesDir() + '/fhm0718_r1_device';
      removeTree(root);
      fileIo.mkdirSync(root, true);
    });

    afterAll(() => {
      removeTree(root);
    });

    it('fhm0718_r1_device_statsync_only_no_such_file_is_absent', 0, () => {
      // G02 实机核对：不存在（含父目录也不存在）是 13900002。
      expect(errorCode(() => fileIo.statSync(root + '/missing'))).assertEqual(NO_SUCH_FILE);
      expect(errorCode(() => fileIo.statSync(root + '/missing_dir/' + MARK_NAME))).assertEqual(NO_SUCH_FILE);
      // 普通文件下的子路径：不是目录（13900018）。
      writeText(root + '/plain', 'x');
      expect(errorCode(() => fileIo.statSync(root + '/plain/' + MARK_NAME))).assertEqual(NOT_A_DIRECTORY);
      // 不可查询的目录下的路径：权限错误（13900012）。
      const denied: string = deniedPath();
      expect(errorCode(() => fileIo.statSync(denied))).assertEqual(PERMISSION_DENIED);

      const ops: SystemFileOps = new SystemFileOps();
      expect(ops.exists(root + '/missing')).assertFalse();
      expect(ops.exists(root + '/missing_dir/' + MARK_NAME)).assertFalse();
      expect(ops.exists(root + '/plain')).assertTrue();
      expect(ops.exists(root)).assertTrue();
      expect(throwsCode(() => ops.exists(root + '/plain/' + MARK_NAME))).assertEqual(NOT_A_DIRECTORY);
      expect(throwsCode(() => ops.exists(denied))).assertEqual(PERMISSION_DENIED);

      // FileSlot（默认 SystemFileOps）：明确不存在为 null；查不了 / 读不了一律上抛，不回成 null。
      const absent: FileSlot = FileSlot.at(root + '/missing_dir', MARK_NAME);
      expect(absent.read()).assertNull();
      expect(absent.readTemp()).assertNull();
      expect(absent.existsAny()).assertFalse();
      const underPlain: FileSlot = FileSlot.at(root + '/plain', MARK_NAME);
      expect(throwsCode(() => underPlain.read())).assertEqual(NOT_A_DIRECTORY);
      expect(throwsCode(() => underPlain.readTemp())).assertEqual(NOT_A_DIRECTORY);
      expect(throwsCode(() => underPlain.existsAny())).assertEqual(NOT_A_DIRECTORY);
      const deniedSlot: FileSlot = new FileSlot(denied);
      expect(throwsCode(() => deniedSlot.read())).assertEqual(PERMISSION_DENIED);
      expect(throwsCode(() => deniedSlot.readTemp())).assertEqual(PERMISSION_DENIED);
      fileIo.mkdirSync(root + '/dir_mark');
      fileIo.mkdirSync(root + '/dir_mark/' + MARK_NAME);
      const dirMark: FileSlot = FileSlot.at(root + '/dir_mark', MARK_NAME);
      const dirCode: number = throwsCode(() => dirMark.read());
      console.info('fhm0718_r1 readText(directory) -> ' + dirCode);
      expect(dirCode !== NO_SUCH_FILE).assertTrue();
      expect(dirMark.readTemp()).assertNull();
      // 写入照常：正式文件读回、临时文件不留；删除后又是明确不存在。
      const ok: FileSlot = FileSlot.at(root, MARK_NAME);
      ok.write('v1');
      expect(ok.read()).assertEqual('v1');
      expect(ok.readTemp()).assertNull();
      ok.write(null);
      expect(ok.read()).assertNull();
      expect(ok.existsAny()).assertFalse();
    });

    it('fhm0718_r1_device_unqueryable_real_mark_blocks_revoked_session_before_and_after_restore', 0, () => {
      for (const fault of faults()) {
        const dir: string = root + '/' + fault.name;
        const mark: string = dir + '/' + MARK_NAME;
        fileIo.mkdirSync(dir);
        const store: LockedStore = new LockedStore();
        seedRevokedOnlyInFile(store, new FileSlot(mark));
        // 对照：标记可查询时冷启动被阻断。
        expectNoSession(rebuild(store, mark), SessionReadStatus.ABSENT);
        // 查不了：按读不出（不放行、世代 null）；同一实例再读仍是读不出（没有把失败缓存成「没有标记」）。
        fault.breakIt(dir, mark);
        const p: SecureSessionTokens = rebuild(store, mark);
        expectNoSession(p, SessionReadStatus.UNREADABLE);
        expectNoSession(p, SessionReadStatus.UNREADABLE);
        expect(p.removalRetryPending).assertFalse();
        // 恢复可读：同一实例下次读取重新核对真实文件，被标记阻断。
        fault.repair(dir, mark);
        expectNoSession(p, SessionReadStatus.ABSENT);
        expect(p.removalRetryPending).assertTrue();
        // 再重建：仍被阻断；又查不了也不放行；再恢复照样阻断。
        expectNoSession(rebuild(store, mark), SessionReadStatus.ABSENT);
        fault.breakIt(dir, mark);
        expectNoSession(rebuild(store, mark), SessionReadStatus.UNREADABLE);
        fault.repair(dir, mark);
        expectNoSession(rebuild(store, mark), SessionReadStatus.ABSENT);
        // 旧令牌仍在安全存储里：挡住它的是真实文件里的标记。
        expect(store.get(TOKENS_ALIAS) !== null).assertTrue();
        expect(new FileSlot(mark).read()).assertEqual(SessionRevocation.encode('e:' + EPOCH));
        console.info('fhm0718_r1 fault ' + fault.name + ' ok');
      }
    });

    it('fhm0718_r1_device_denied_mark_path_never_releases_session', 0, () => {
      // 标记路径在应用无权查询的位置：每次冷启动都按读不出，不放行（也不删令牌）。
      const denied: string = deniedPath();
      expect(denied.length > 0).assertTrue();
      const store: LockedStore = new LockedStore();
      new SecureSessionTokens(store).save(new SessionTokenSet('acc-1', 'ref-1', 'full', 'user-1', EPOCH));
      for (let i: number = 0; i < 2; i++) {
        const p: SecureSessionTokens = rebuild(store, denied);
        expectNoSession(p, SessionReadStatus.UNREADABLE);
        expectNoSession(p, SessionReadStatus.UNREADABLE);
      }
      expect(store.get(TOKENS_ALIAS) !== null).assertTrue();
    });

    it('fhm0718_r1_device_unqueryable_mark_without_revocation_reads_again_once_repaired', 0, () => {
      // 对照：没有撤销这份会话时，查不了只是暂时读不出；恢复后同一实例照常给出同一世代（读不出不删令牌、不缓存）。
      for (const fault of faults()) {
        const dir: string = root + '/control_' + fault.name;
        const mark: string = dir + '/' + MARK_NAME;
        fileIo.mkdirSync(dir);
        const store: LockedStore = new LockedStore();
        new SecureSessionTokens(store).save(new SessionTokenSet('acc-1', 'ref-1', 'full', 'user-1', EPOCH));
        writeText(mark, SessionRevocation.encode('e:some-older-login'));
        expect(rebuild(store, mark).loginEpoch()).assertEqual(EPOCH);
        fault.breakIt(dir, mark);
        const p: SecureSessionTokens = rebuild(store, mark);
        expectNoSession(p, SessionReadStatus.UNREADABLE);
        fault.repair(dir, mark);
        expect(p.loginEpoch()).assertEqual(EPOCH);
        expect(p.readStatus()).assertEqual(SessionReadStatus.PRESENT);
        expect(store.get(TOKENS_ALIAS) !== null).assertTrue();
      }
    });
  });
}
