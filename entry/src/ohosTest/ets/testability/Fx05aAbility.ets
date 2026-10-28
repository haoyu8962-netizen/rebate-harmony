import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { CouliTheme } from 'designsystem';

// F-X-05a：只编入测试 HAP 的宿主 Ability，加载 Fx05aFixture；产品入口不加测试分支。
export default class Fx05aAbility extends UIAbility {
  onWindowStageCreate(stage: window.WindowStage): void {
    CouliTheme.install(this.context);
    stage.loadContent('pages/Fx05aFixture');
  }
}
