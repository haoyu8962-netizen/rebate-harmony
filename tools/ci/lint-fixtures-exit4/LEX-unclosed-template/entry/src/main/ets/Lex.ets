// FU-HM-0723 第 3 项：模板插值到文件末尾仍未闭合——无法确认边界，lint 以 4 失败。
const t: string = `${ {k: 1}.k ;
import router from '@ohos.router';
