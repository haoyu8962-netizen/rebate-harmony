// FU-HM-0723 第 3 项：未闭合的块注释——原来的 strip 吞到文件末尾、静默放行其后的导入；现在边界无法确认，lint 以 4 失败。
const a: number = 1; /* note
import router from '@ohos.router';
