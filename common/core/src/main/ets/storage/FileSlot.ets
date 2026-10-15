import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** FileSlot 用到的文件操作（生产是 fileIo；单测注入内存实现，模拟残留临时文件与删除失败）。失败一律抛出。 */
export interface FileOps {
  exists(path: string): boolean;

  readText(path: string): string;

  /** 写临时文件并落盘（fsync）。 */
  writeDurable(path: string, value: string): void;

  rename(from: string, to: string): void;

  remove(path: string): void;
}

/**
 * 查一个路径的状态（SystemFileOps.exists 用；生产是 fileIo.statSync）：存在则正常返回；不存在、或任何查询失败都抛出
 * （BusinessError，带 code）。单独成接口是为了本机单测能把「目录不可查询、路径中间不是目录、I/O 错误」注入到生产的判定里
 * （Local Test 里 fileIo 是空实现）。生产的 SystemFileProbe（真实 fileIo.statSync）由设备测试 src/ohosTest 覆盖（FU-HM-0718 R1-01：
 * 模拟器 API 20 实测不存在 13900002、普通文件下的子路径 13900018、无搜索权限的目录下 13900012；标记位置是目录时读取报 13900019）。
 */
export interface FileProbe {
  stat(path: string): void;
}

class SystemFileProbe implements FileProbe {
  stat(path: string): void {
    fileIo.statSync(path);
  }
}

/**
 * 生产实现：fileIo 同步接口（statSync / readTextSync / openSync / writeSync / fsyncSync / closeSync / renameSync / unlinkSync，
 * 均为 API 12 及以下；statSync 已在 entry 使用、过 api-compat）。
 */
export class SystemFileOps implements FileOps {
  /** fileIo 的「没有这个文件或目录」（ENOENT）。 */
  static readonly NO_SUCH_FILE: number = 13900002;
  private readonly probe: FileProbe;

  constructor(probe: FileProbe = new SystemFileProbe()) {
    this.probe = probe;
  }

  exists(path: string): boolean {
    return SystemFileOps.existsVia(this.probe, path);
  }

  /**
   * 存在性判定（FU-HM-0718 第 2 项，对应 Android FU-AND-0715 R1-02）：只有明确「没有这个文件或目录」（13900002）才算不存在；
   * 目录不可查询（权限 13900012）、路径中间不是目录（13900018）、I/O 错误（13900005）等一律抛出——FileSlot.read 跟着抛出，
   * 撤销标记读不出 → 会话按读不出（不放行、不缓存，下次再读）。以前用 accessSync 的布尔结果：文档只写「不存在返回 false」，
   * 没有保证别的失败不会同样回成 false（Android 的 File.exists() 正是这样把 /dev/null/x 回成 false）。
   */
  static existsVia(probe: FileProbe, path: string): boolean {
    try {
      probe.stat(path);
      return true;
    } catch (e) {
      if ((e as BusinessError).code === SystemFileOps.NO_SUCH_FILE) {
        return false;
      }
      throw e as Error;
    }
  }

  readText(path: string): string {
    return fileIo.readTextSync(path);
  }

  writeDurable(path: string, value: string): void {
    const file: fileIo.File = fileIo.openSync(path,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
    try {
      fileIo.writeSync(file.fd, value);
      fileIo.fsyncSync(file.fd);
    } finally {
      fileIo.closeSync(file);
    }
  }

  rename(from: string, to: string): void {
    fileIo.renameSync(from, to);
  }

  remove(path: string): void {
    fileIo.unlinkSync(path);
  }
}

/**
 * 应用沙盒里的一个文本文件（03 §3.3 存储表「Preferences + 文件」：LKG 配置、埋点离线队列、权限节流记录，APP-03b）。
 * 不放 CSB-05 的内容（令牌、install_secret 只进安全存储）。
 * - read：文件明确不存在为 null；存在性查询失败（目录不可查询、路径中间不是目录、I/O 错误）与读取失败都抛出（调用方区分「没有」
 *   与「读不出」，lessons 38；FU-HM-0718 第 2 项）。
 * - write：先写同目录临时文件并 fsync，再改名覆盖（中途被打断不会留下半份文件）；null 删除文件。失败抛出。
 * - 删除（write(null)，撤回同意、切换环境的清理走这里）：正式文件与临时文件（.tmp：上次写到一半、改名前进程被回收留下的
 *   旧内容）都删；两个都尝试，任一删不掉就抛出，调用方保留「待清理」并重试（cross-platform-lessons 1）。
 */
export class FileSlot {
  readonly path: string;
  private readonly ops: FileOps;

  constructor(path: string, ops: FileOps = new SystemFileOps()) {
    this.path = path;
    this.ops = ops;
  }

  /** 沙盒目录 + 文件名。 */
  static at(directory: string, name: string): FileSlot {
    return new FileSlot(directory + '/' + name);
  }

  /** 原子写用的临时文件路径。 */
  static tempOf(path: string): string {
    return path + '.tmp';
  }

  /**
   * 正式文件或临时文件任一存在（临时文件：已写入并 fsync、但改名失败或改名前进程被回收留下的）。用于「有没有标记」这类只看存在与否的
   * 判断（订单缓存「待清理」，FU-HM-0709 R1-01）：只看正式文件会漏掉改名失败的那次写入。核对失败抛出（调用方按无法确认处理）。
   */
  existsAny(): boolean {
    return this.ops.exists(this.path) || this.ops.exists(FileSlot.tempOf(this.path));
  }

  read(): string | null {
    if (!this.ops.exists(this.path)) {
      return null;
    }
    return this.ops.readText(this.path);
  }

  /** 临时文件的内容（已写入并 fsync、但改名没完成的那次写入；不存在为 null，读取失败抛出）。F-HM-34 撤销标记核对用。 */
  readTemp(): string | null {
    const temp: string = FileSlot.tempOf(this.path);
    if (!this.ops.exists(temp)) {
      return null;
    }
    return this.ops.readText(temp);
  }

  write(value: string | null): void {
    const temp: string = FileSlot.tempOf(this.path);
    if (value === null) {
      let failure: Error | null = null;
      for (const path of [this.path, temp]) {
        try {
          if (this.ops.exists(path)) {
            this.ops.remove(path);
          }
        } catch (e) {
          failure = failure ?? e as Error;
        }
      }
      if (failure !== null) {
        throw failure;
      }
      return;
    }
    this.ops.writeDurable(temp, value);
    this.ops.rename(temp, this.path);
  }
}
