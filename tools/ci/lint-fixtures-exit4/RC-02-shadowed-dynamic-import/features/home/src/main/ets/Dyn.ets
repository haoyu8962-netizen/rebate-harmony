// FU-HM-0723 末轮窄修二 RC-02：参数 M 遮蔽了外层安全的 const M——原实现按名字取外层值 './local' 放行，实际调用方传的是 'search'
// （跨 feature 导入）。不做作用域分析时有其他同名绑定就按确定不了处理，lint 以 4 失败。
const M: string = './local';
export function load(M: string) {
  return import(M);
}
load('search');
