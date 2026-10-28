# 平台内置图标（F-X-05a）

本目录只放说明与机器清单，不在 `resources/` 下，**不进包**。图片本身在 `../src/main/resources/base/media/`。

- 来源：规划仓库 `couli` 的 `design/icons/platform/`（负责人提供的官方原图），来源提交 `5baa49cb89857d595c9ebc3ed87e0c032dc131fd`（2026-10-19，`origin/main` 736d24c 时仍未变）。
- 机器清单：`manifest.json`（`tools/ci/fx05a/check_platform_icons.py` 逐项核对）。
- 规则：用 `git show <commit>:design/icons/platform/<文件>` 原样拷入，**不改像素、不重新压缩、不放大**；鸿蒙不生成派生图，14vp / 44vp 两档由 `PlatformIcon` 从同一张 224×224 原图缩小显示。深色模式不放替身（不在 `dark/media/` 放同名图），图标原样、不反色、不着色。
- 只拷有平台标识键（BR-TEXT-24）的三家：

| 资源 | 标识键 | 源文件 | sha256 | 字节 | 尺寸 |
| --- | --- | --- | --- | --- | --- |
| `base/media/taobao.png` | `taobao` | `taobao.png` | `d987c0084948eeeada4da71bce00653a9eb2e5743149adb4b25587adb573a4ea` | 34046 | 224×224 |
| `base/media/jd.png` | `jd` | `jd.png` | `574f09c6bdfc99fa91e814a07e5fd569618060065fa723165059586b0e79766c` | 6565 | 224×224 |
| `base/media/pinduoduo.png` | `pdd` | `pinduoduo.png` | `6b9ff1c90ef7c168ecda69b56e5b33ab609a7883a910688aeeee8ca8ee07997d` | 9935 | 224×224 |

- 暂缺官方图（有标识键、couli 里没有图）：`tmall`、`wechat`、`wechat_pay`、`alipay`、`wecom`。徽标只显示文字，不画占位、不自己画、不找网图；负责人补图后按同一规则拷入并更新清单。
- 后续平台（vip、douyin、meituan、eleme、fliggy、didi）有图但没有标识键，本任务不拷；APP-11v 金刚区要用时再按同一规则拷入。
- 第三方登录圆钮（F-DS-01）：这批素材里没有微信 / 华为登录图标，继续挂起；购物平台图不得挪作登录图标。
