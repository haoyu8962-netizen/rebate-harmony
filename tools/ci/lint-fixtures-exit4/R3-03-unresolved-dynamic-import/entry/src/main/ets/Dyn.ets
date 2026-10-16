// FU-HM-0723 末轮窄修 R3-03：import() 的模块名是变量，静态确定不了，判不了是不是 @ohos.router / 另一个 feature —— lint 以 4 失败，不静默跳过。
export function load(name: string) {
  return import(name);
}
