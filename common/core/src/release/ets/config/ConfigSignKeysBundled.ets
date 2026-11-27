// Release（core 模块 default target；ohosTest 也编译这一份）：随包的配置签名公钥表只放 prod 钥（N-22，D10-3507）。
// 生产 kid 与公钥还没给（上线清单），现为空串：Release 的可信 H5 白名单为空，WebPage 不打开。
// 格式见 ConfigSignKeys.parse：空白或逗号分隔的若干项 `env:kid:<SPKI DER 十六进制>`。
// Debug / Staging 的同名文件在 src/staging/ets/config/，由 hvigor 按 target 二选一编译（同 DevOrigins / EnvironmentCatalog）。
// 本文件只许出现 prod 项（core 单测 BridgeOriginsKeys.test 的 keys_06 断言）。

export const CONFIG_SIGN_KEYS_BUNDLED: string = '';
