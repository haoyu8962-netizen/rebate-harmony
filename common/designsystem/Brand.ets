// BRAND-01：品牌 Logo 取用入口（资源在本模块 resources/base|dark/media，组件里用 $r('app.media.couli_logo_*') 引用）。
// 单独成文件、不从 Index.ets 导出：$r 在编译期按「当前编译单元的资源表」校验。HAP 构建会合并本模块资源，没有问题；
// 但 core 的本机单测把 designsystem 当 devDependency 引入时只带 core 自己的资源，从 Index 一并导出会让 core 单测编译报
// 「Unknown resource type 'media'」。页面用：import { CouliLogo, CouliLogoVariant } from 'designsystem/Brand'。
export { CouliLogo, CouliLogoVariant, CouliLogoSpec } from './src/main/ets/components/CouliLogo';
