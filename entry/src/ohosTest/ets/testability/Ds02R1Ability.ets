import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { CouliTheme } from 'designsystem';

// 只编入测试 HAP；不往产品入口增加测试分支。
export default class Ds02R1Ability extends UIAbility {
  onWindowStageCreate(stage: window.WindowStage): void {
    CouliTheme.install(this.context);
    stage.loadContent('pages/Ds02R1Fixture');
  }
}
