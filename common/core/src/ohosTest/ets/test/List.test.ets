import fileSlotDeviceTest from './FileSlotDevice.test';
import bridgeOriginsDeviceTest from './BridgeOriginsDevice.test';

export default function testsuite() {
  fileSlotDeviceTest();
  // FU-HM-BRIDGE-ORIGINS-VERIFY（D10-3512 (a)）：33 条 N-22 向量走真 cryptoFramework、公钥 sha16、非 P-256 / 坏 SPKI、staging 实测。
  bridgeOriginsDeviceTest();
}
