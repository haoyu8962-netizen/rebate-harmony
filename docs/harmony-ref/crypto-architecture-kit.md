# Crypto Architecture Kit（cryptoFramework）使用的 API 子集

2026-11-27，离线核对本机 DevEco 6.1.1 自带 SDK 6.1.1.125（目标 API 24、最低 API 20）。单号 FU-HM-BRIDGE-ORIGINS-VERIFY，依据 D10-3512「docs/harmony-ref 先补登密码学一页」。
本页登记本单新增依赖的接口，并补登仓库已在用、此前没登记的接口；不复制官方文档。

- 权威声明：`/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/api/@ohos.security.cryptoFramework.d.ts`（共 9457 行，下文「d.ts :N」均指此文件行号）。
  Kit 入口 `ets/kits/@kit.CryptoArchitectureKit.d.ts` 只是把 `cryptoFramework` 再导出。
- 导入方式：`import { cryptoFramework } from '@kit.CryptoArchitectureKit';`（仓库先例 `common/core/src/main/ets/network/RequestSigner.ets:1`）。

## @since 与错误码的取法

d.ts 里同一声明前常叠着几段注释（`@since 9` / `11` / `12` …，后几段补 `@crossplatform`、`@atomicservice` 与细分 syscap）。
下表「@since」写**首次出现**的版本，括号里是紧贴声明那一段的版本；错误码一律取紧贴声明那一段的 `@throws` 原文。
逐条核对结果：本页所列接口的 @since 全部 ≤ 20，**没有超过 20 的条目**；等于 20 的只有 `SignatureUtils`、`EccSignatureSpec` 和错误码 17620003（本单都不用）。

错误码（d.ts `enum Result`，:55）与 `@throws` 原文：

| 码 | 枚举名（d.ts 行） | `@throws` 原文 |
| --- | --- | --- |
| 401 | `INVALID_PARAMS`（:70） | invalid parameters. Possible causes: 1. Mandatory parameters are left unspecified; 2. Incorrect parameter types; 3. Parameter verification failed. |
| 801 | `NOT_SUPPORT`（:92） | this operation is not supported. |
| 17620001 | `ERR_OUT_OF_MEMORY`（:107） | memory operation failed. |
| 17620002 | `ERR_RUNTIME_ERROR`（:129） | failed to convert parameters between arkts and c. |
| 17620003 | `ERR_PARAMETER_CHECK_FAILED`（:138，@since 20） | parameter check failed. |
| 17630001 | `ERR_CRYPTO_OPERATION`（:153） | crypto operation error. |

## 一、本单新增依赖（ECC P-256 验签）

用法：`createAsyKeyGenerator('ECC256').convertKeySync({ data: SPKI DER 公钥 }, null).pubKey` → `createVerify('ECC256|SHA256')` →
`initSync(pubKey)` → `verifySync({ data: 被签字节 }, { data: DER 签名 })`。只用同步接口。

| 接口 | 签名 | @since | `@throws` | d.ts 行 |
| --- | --- | --- | --- | --- |
| `createAsyKeyGenerator` | `function createAsyKeyGenerator(algName: string): AsyKeyGenerator` | 9（末段 12） | 401 invalid parameters；801 this operation is not supported；17620001 memory operation failed | :2075 |
| `AsyKeyGenerator` | `interface AsyKeyGenerator` | 9（末段 12） | — | :1458 |
| `AsyKeyGenerator.convertKeySync` | `convertKeySync(pubKey: DataBlob \| null, priKey: DataBlob \| null): KeyPair` | 12 | 401 invalid parameters；17620001 memory operation failed；17630001 crypto operation error | :1731 |
| `createVerify` | `function createVerify(algName: string): Verify` | 9（末段 12） | 401 invalid parameters；801 this operation is not supported；17620001 memory operation failed | :5553 |
| `Verify` | `interface Verify` | 9（末段 12） | — | :4883 |
| `Verify.initSync` | `initSync(pubKey: PubKey): void` | 12 | 401 invalid parameters；17620001 memory operation failed；17620002 failed to convert parameters between arkts and c；17630001 crypto operation error | :4984 |
| `Verify.verifySync` | `verifySync(data: DataBlob \| null, signatureData: DataBlob): boolean` | 12 | 401 invalid parameters；17620001 memory operation failed；17620002 failed to convert parameters between arkts and c；17630001 crypto operation error | :5286 |
| `DataBlob` | `interface DataBlob { data: Uint8Array }` | 9（末段 11） | — | :171（`data` :188） |
| `KeyPair` | `interface KeyPair { readonly priKey: PriKey; readonly pubKey: PubKey }` | 9（末段 12） | — | :1126（`pubKey` :1182） |
| `PubKey` | `interface PubKey extends Key` | 9（末段 12） | —（本单不调它的方法） | :1027 |

说明：

- **公钥格式**：d.ts :708 的「The public key must be in DER encoding format and comply with the ASN.1 syntax and X.509 specifications.」写在
  `Key.getEncoded()`（:720）的注释里，说的是公钥导出格式；`convertKeySync` 自身的注释（:1716-1730）没写入参格式。本单按与 `getEncoded`
  对称、传 X.509 SubjectPublicKeyInfo（SPKI）DER 公钥，`priKey` 传 `null`。
- **签名格式**：`verifySync` 的注释没写 `signatureData` 的编码。JWS ES256 的签名是 64 字节 R‖S，本单自己转成 DER（ASN.1 `SEQUENCE { INTEGER r, INTEGER s }`）再传入。
- `verifySync` 的 `data` 可为 `null`（先 `updateSync` 喂数据的用法）；本单一次性传入，不用 `updateSync`。
- 列出但**本单不用**：`SignatureUtils.genEccSignature`——`static genEccSignature(spec: EccSignatureSpec): Uint8Array`，**@since 20**，d.ts :9454
  （类 :9420、`EccSignatureSpec { r: bigint; s: bigint }` :9390，均 @since 20），`@throws` 17620001 memory operation failed；17620002 failed to convert
  parameters between arkts and c；17620003 parameter check failed（The r or s value of the spec parameter is 0 or too large）；17630001 crypto operation error。
  本单不依赖它，R‖S → DER 由本单纯 ArkTS 实现，可在本机单测里按向量验。

## 二、仓库已在用、此前未登记（补登）

| 接口 | 签名 | @since | `@throws` | d.ts 行 | 仓库用处 |
| --- | --- | --- | --- | --- | --- |
| `createMd` | `function createMd(algName: string): Md` | 9（末段 12） | 401 invalid parameters；17620001 memory operation failed | :2876 | `RequestSigner.ets:13`（`'SHA256'`）；ohosTest `Fx05aUi.test.ets:281`（`testing-fx05a.md` 已登记） |
| `Md.updateSync` | `updateSync(input: DataBlob): void` | 12 | 401 invalid parameters；17620001 memory operation failed；17630001 crypto operation error | :2705 | `RequestSigner.ets:17` |
| `Md.digestSync` | `digestSync(): DataBlob` | 12 | 401 invalid parameters；17620001 memory operation failed；17620002 failed to convert parameters between arkts and c；17630001 crypto operation error | :2782 | `RequestSigner.ets:19` |
| `createSymKeyGenerator` | `function createSymKeyGenerator(algName: string): SymKeyGenerator` | 9（末段 12） | 401 invalid parameters；801 this operation is not supported | :2112 | `RequestSigner.ets:23`（`'HMAC'`） |
| `SymKeyGenerator.convertKeySync` | `convertKeySync(key: DataBlob): SymKey` | 12 | 401 invalid parameters；17620001 memory operation failed | :2006 | `RequestSigner.ets:24` |
| `createMac` | `function createMac(algName: string): Mac` | 9（末段 12） | 401 invalid parameters；17620001 memory operation failed | :2569 | `RequestSigner.ets:25`（`'SHA256'`） |
| `Mac.initSync` | `initSync(key: SymKey): void` | 12 | 401 invalid parameters；17620001 memory operation failed；17630001 crypto operation error | :2304 | `RequestSigner.ets:26` |
| `Mac.updateSync` | `updateSync(input: DataBlob): void` | 12 | 401 invalid parameters；17620001 memory operation failed；17630001 crypto operation error | :2398 | `RequestSigner.ets:27` |
| `Mac.doFinalSync` | `doFinalSync(): DataBlob` | 12 | 401 invalid parameters；17620001 memory operation failed；17620002 failed to convert parameters between arkts and c；17630001 crypto operation error | :2475 | `RequestSigner.ets:28` |
| `createRandom` | `function createRandom(): Random` | 9（末段 12） | 17620001 memory operation failed | :1433 | `network/ApiClient.ets:145`；`clipboard/ClipboardRecords.ets:69` |
| `Random.generateRandomSync` | `generateRandomSync(len: number): DataBlob` | 10（末段 12） | 401 invalid parameters；17620001 memory operation failed；17630001 crypto operation error | :1332 | `ApiClient.ets:146`（16 字节 nonce）；`ClipboardRecords.ets:70`（32 字节盐） |

涉及的类型：`Md`（:2611）、`Mac`（:2204）、`SymKeyGenerator`（:1851）、`SymKey`（:806）、`Random`（:1209），均 @since 9（末段 12）。
路径前缀均为 `common/core/src/main/ets/`（ohosTest 那条除外，在 `entry/src/ohosTest/ets/test/`）。

- `createMac` 另有 `createMac(macSpec: MacSpec): Mac` 重载（:2585，@since 18），仓库只用字符串重载 :2569。
- 已知行为（仓库实测，非 d.ts 所写）：零字节传给 `Md.updateSync` 会抛参数错误，`RequestSigner.ets:14-18` 零字节时跳过 update（APP-13a G49）。

## 三、算法串的出处

`'ECC256'`、`'ECC256|SHA256'`，以及仓库已用的 `'SHA256'`（Md、Mac）、`'HMAC'`（SymKeyGenerator），**都不在 d.ts 里**（对 d.ts 全文检索无命中，
`algName` 参数只声明为 `string`）。出处是官方开发指南的算法规格表（非对称密钥生成与转换规格的 ECC 一节、签名验签规格的 ECDSA 一节、消息摘要与
消息认证码规格）。**API 20 设备上的行为待 core 设备步实测确认。**

## 四、本机 Local Test 的限制与对策

本机 Local Test（Hypium 本机单测）里 `cryptoFramework` 是空实现，返回空字节。证据：`common/core/src/test/TestDigest.ets:2`、
`common/core/src/main/ets/clientcore/Sha256.ets:4-6`（另见 `clipboard/ClipboardRecords.ets:51`「返回 0 字节」）。所以 Local Test 里调验签得不到有意义的结果。

对策：验签做成可注入端口（先例：`RequestSigner.ets:4` 的 `DigestPort`，生产实现 `CryptoKitDigest`，单测注入 `TestDigest`）。本机单测注入替身，只验
管线（R‖S → DER、取公钥、错误分支）；真密码学只在设备步验。

## 五、待 core 设备步实测确认

1. `createAsyKeyGenerator('ECC256')` 与 `createVerify('ECC256|SHA256')` 在 API 20 设备上可用（算法串出处是开发指南，不是 d.ts）。
2. `'ECC256'` 生成器的 `convertKeySync` 接受 P-256 的 SPKI DER 公钥。
3. `'ECC256'` 生成器导入非 P-256 的 SPKI 会抛错（抛哪个码待实测）。
4. 本单自转的 DER 签名能被 `verifySync` 验过；篡改数据或签名时 `verifySync` 是返回 `false` 还是抛 17630001（d.ts 未写，调用方两种都按验签失败处理）。
