// Debug / Staging（core 模块 staging target）：随包的配置签名公钥表 = staging 钥 + prod 钥（N-22，D10-3507；scope.md P6）。
// staging 项：kid config-staging-2026-11b，SPKI DER = NATIVE/N22-VECTORS/es256.pub.pem（公钥，sha256 前 16 位 07ba14efc5908e5c）。
// prod 项与 Release 同（现为空，上线清单再填）。向量测试钥（env test）只在测试里注入，不进这里。
// 格式见 ConfigSignKeys.parse：空白或逗号分隔的若干项 `env:kid:<SPKI DER 十六进制>`。
// kid 字面量也登记在 tools/ci/release-scan.sh 的 markers 表：Release 制品命中即阻断，Staging / Debug 自测必须命中。

export const CONFIG_SIGN_KEYS_BUNDLED: string =
  'staging:config-staging-2026-11b:3059301306072a8648ce3d020106082a8648ce3d03010703420004ae883f464888bece2a33c015a42e8' +
    '97e07672c37b43a244f556678f595417dbcf359128f1ee420e841b4b286d06e487882b7d4a1a92abd5e7e81db5715462af0';
