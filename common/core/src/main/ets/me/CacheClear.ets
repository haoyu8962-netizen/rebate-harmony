// FU-HM-0720（APP-12 共性 39，iOS APP-12 第 3 轮）：清除缓存的成败口径——「清理动作完成且没有 I/O 错误」即成功，之后由页面重算显示大小。
// 不拿删完后的残留（目录是否为空、占用字节数）判成败：ArkWeb 网页缓存与图片缓存在 WebView / 图片加载在途时会立刻重建文件，没有任何 I/O
// 错误也会被误报成失败。单项删除时已不存在（被别处删掉，ENOENT）不算错；列目录失败、删除失败（文件仍在）按失败（APP-08 第 20 条）。
// 文件系统操作由 App 注入（entry 接 @kit.CoreFileKit 的 fileIo），Core 里只有判定，便于单测。

/** 清理用到的文件系统操作（同步；出错抛出）。 */
export interface CacheFs {
  exists(path: string): boolean;

  list(dir: string): string[];

  isDirectory(path: string): boolean;

  /** 递归删除目录。 */
  removeDirectory(path: string): void;

  removeFile(path: string): void;
}

export class CacheClear {
  /** 清掉 dir 下的全部内容（dir 本身保留）：目录不存在算已清；返回清理动作是否没有 I/O 错误地完成。 */
  static run(fs: CacheFs, dir: string): boolean {
    try {
      if (!fs.exists(dir)) {
        return true;
      }
      for (const name of fs.list(dir)) {
        const path: string = dir + '/' + name;
        try {
          if (fs.isDirectory(path)) {
            fs.removeDirectory(path);
          } else {
            fs.removeFile(path);
          }
        } catch (e) {
          if (CacheClear.stillThere(fs, path)) {
            return false;
          }
          // 已不存在（别处先删了）：这一项算清掉了。
        }
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  private static stillThere(fs: CacheFs, path: string): boolean {
    try {
      return fs.exists(path);
    } catch (e) {
      return true;
    }
  }
}
