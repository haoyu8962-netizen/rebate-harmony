export { WebFeature } from './src/main/ets/WebFeature';
// APP-04 / HM-03：两类 WebView 容器（03 §5.1）。WebView 的设置只写在这两个封装里（CSB-03）。
export {
  BridgeEnvInfo, TrustedWebConfig, TrustedWebState, BridgeNativeObject, BridgeTransport, TrustedWebView
} from './src/main/ets/TrustedWebView';
export { ExternalFrame, ExternalWebConfig, ExternalWebState, ExternalWebView } from './src/main/ets/ExternalWebView';
export { bridgeBootstrapScript } from './src/main/ets/BridgeBootstrapScript';
