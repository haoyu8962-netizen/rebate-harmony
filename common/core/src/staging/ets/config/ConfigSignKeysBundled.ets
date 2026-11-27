// Debug / Staging（core 模块 staging target）：随包的配置签名公钥表 = staging 钥 + prod 钥（N-22，D10-3507；scope.md P6）。
// 写测步的桩：空串。实现步填 staging 项（kid config-staging-2026-11b，SPKI DER = NATIVE/N22-VECTORS/es256.pub.pem，
// sha256 前 16 位 07ba14efc5908e5c）；prod 项与 Release 同（现为空）。向量测试钥（env test）只在测试里注入，不进这里。
// 格式见 ConfigSignKeys.parse：空白或逗号分隔的若干项 `env:kid:<SPKI DER 十六进制>`。

export const CONFIG_SIGN_KEYS_BUNDLED: string = '';
