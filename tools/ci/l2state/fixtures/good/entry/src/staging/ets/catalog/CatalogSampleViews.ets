// HM-L2-STATE 参照件（节选）：目录 FeedbackSample 里的 ErrorState 样例，形状同产品文件。
import { ErrorState } from 'designsystem';

@ObservedV2
export class CatalogEvents {
  @Trace errorRetryCount: number = 0;
}

@ComponentV2
struct FeedbackSample {
  @Param component: string = '';
  @Param variant: string = '';
  @Param state: string = '';
  @Param events: CatalogEvents = new CatalogEvents();

  build() {
    Column() {
      if (this.component === 'ErrorState') {
        ErrorState({
          title: this.variant === 'offline' ? '网络不可用' : '加载失败',
          message: this.variant === 'offline' ? '请检查网络后重试' : '错误编号 7F3A9C',
          retryText: '重试', retryId: 'catalog-error-retry-' + this.variant + '-' + this.state,
          retrying: this.state === 'retrying',
          onRetry: () => {
            this.events.errorRetryCount++;
          }
        })
      }
    }
  }
}
