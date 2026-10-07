import { fileIo } from '@kit.CoreFileKit';

/** FileSlot 用到的文件操作（生产是 fileIo；单测注入内存实现，模拟残留临时文件与删除失败）。失败一律抛出。 */
export interface FileOps {
  exists(path: string): boolean;

  readText(path: string): string;

  /** 写临时文件并落盘（fsync）。 */
  writeDurable(path: string, value: string): void;

  rename(from: string, to: string): void;

  remove(path: string): void;
}

/** 生产实现：fileIo 同步接口（accessSync / readTextSync / openSync / writeSync / fsyncSync / closeSync / renameSync / unlinkSync，均为 API 12 及以下）。 */
export class SystemFileOps implements FileOps {
  exists(path: string): boolean {
    return fileIo.accessSync(path);
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
 * - read：文件不存在为 null；读取失败抛出（调用方区分「没有」与「读不出」，lessons 38）。
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

  read(): string | null {
    if (!this.ops.exists(this.path)) {
      return null;
    }
    return this.ops.readText(this.path);
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
