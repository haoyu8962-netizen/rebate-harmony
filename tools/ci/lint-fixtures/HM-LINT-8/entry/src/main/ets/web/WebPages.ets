// 违反样例 HM-LINT-8：承载 ExternalWebView 的 NavDestination 没有 onBackPressed，系统返回直接关闭容器、不先后退网页。
import { ExternalWebConfig, ExternalWebView } from 'web';

@ComponentV2
export struct AppExternalPage {
  @Param config: ExternalWebConfig | null = null;

  build() {
    NavDestination() {
      if (this.config !== null) {
        ExternalWebView({ config: this.config })
      }
    }
    .hideTitleBar(true)
  }
}
