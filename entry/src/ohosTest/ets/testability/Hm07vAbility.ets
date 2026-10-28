import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { CouliTheme } from 'designsystem';

// HM-07v-a 测试 v3（评审 r1 R1-01）：只编入测试 HAP 的宿主 Ability，加载 Hm07vTileFixture；产品入口不加测试分支。
export default class Hm07vAbility extends UIAbility {
  onWindowStageCreate(stage: window.WindowStage): void {
    CouliTheme.install(this.context);
    stage.loadContent('pages/Hm07vTileFixture');
  }
}
