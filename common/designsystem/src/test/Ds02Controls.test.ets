import { describe, it, expect } from '@ohos/hypium';
// 生产纯逻辑入口；组件必须实际消费这些结果，接线另由 UiTest 检验。
import { CheckboxMetrics, ChoiceState, SingleSelection, LoginRowModel, OAuthAction, SheetDismissPolicy }
  from '../main/ets/components/ControlModels';
import { PlatformIconSource } from '../main/ets/components/PlatformIconSource';

export default function ds02ControlsTest() {
  describe('Ds02Controls', () => {
    it('checkbox_circle_scale_cap_and_48vp_target', 0, () => {
      for (const scale of [1, 1.3, 1.5, 2]) {
        for (const imageBadge of [false, true]) {
          const metric: CheckboxMetrics = CheckboxMetrics.compute(scale, imageBadge);
          const diameter: number = (imageBadge ? 22 : 18) * Math.min(scale, 1.5);
          expect(metric.shape).assertEqual('circle');
          expect(metric.diameter).assertEqual(diameter);
          expect(metric.hitWidth >= 48 && metric.hitHeight >= 48).assertTrue();
          expect(metric.strokeWidth >= 1.5 * Math.min(scale, 1.5)).assertTrue();
          expect(metric.strokeWidth <= 2 * Math.min(scale, 1.5)).assertTrue();
        }
      }
    });

    it('checkbox_agreement_and_switch_toggle_both_values_disable_blocks_callbacks', 0, () => {
      for (const initial of [false, true]) {
        for (const enabled of [false, true]) {
          let calls: number = 0;
          let emitted: boolean = initial;
          const state: ChoiceState = new ChoiceState(initial, enabled, 'Accept terms', (value: boolean): void => {
            calls++; emitted = value;
          });
          expect(state.accessibilityName).assertEqual('Accept terms');
          expect(state.checked).assertEqual(initial);
          expect(state.enabled).assertEqual(enabled);
          state.toggle();
          expect(state.checked).assertEqual(enabled ? !initial : initial);
          expect(calls).assertEqual(enabled ? 1 : 0);
          expect(emitted).assertEqual(enabled ? !initial : initial);
          state.toggle();
          expect(state.checked).assertEqual(initial);
          expect(calls).assertEqual(enabled ? 2 : 0);
        }
      }
    });

    it('radio_and_segment_single_selection_disable_and_unknown_option', 0, () => {
      for (const enabled of [false, true]) {
        let calls: number = 0;
        let emitted: string = '';
        const state: SingleSelection = new SingleSelection('a', ['a', 'b', 'c'], (value: string): void => {
          calls++; emitted = value;
        }, enabled);
        state.select('a');
        state.select('unknown');
        expect(calls).assertEqual(0);
        state.select('b');
        expect(state.value).assertEqual(enabled ? 'b' : 'a');
        expect(emitted).assertEqual(enabled ? 'b' : '');
        expect(calls).assertEqual(enabled ? 1 : 0);
        state.select('b');
        expect(calls).assertEqual(enabled ? 1 : 0);
        state.select('c');
        expect(state.value).assertEqual(enabled ? 'c' : 'a');
        expect(calls).assertEqual(enabled ? 2 : 0);
      }
    });

    it('harmony_login_provider_order_capability_and_equal_sizes', 0, () => {
      for (const quickAvailable of [false, true]) {
        for (const wechatInstalled of [false, true]) {
          const row: LoginRowModel = LoginRowModel.create(quickAvailable, wechatInstalled);
          const expected: string[] = [];
          if (!quickAvailable) { expected.push('huawei'); }
          if (wechatInstalled) { expected.push('wechat'); }
          expect(row.providers.join(',')).assertEqual(expected.join(','));
          expect(row.showDivider).assertEqual(expected.length > 0);
          expect(row.showHelp).assertTrue();
          expect(row.buttonDiameter).assertEqual(48);
          expect(row.gap).assertEqual(32);
          expect(row.hitWidth >= 48 && row.hitWidth <= row.buttonDiameter + row.gap).assertTrue();
        }
      }
    });

    it('standalone_oauth_authorizing_blocks_activation_with_enabled_default', 0, () => {
      for (const provider of ['huawei', 'wechat']) {
        for (const busy of [false, true]) {
          let calls: number = 0;
          const action: OAuthAction = new OAuthAction(provider, (): void => { calls++; }, busy);
          expect(action.enabled).assertEqual(!busy);
          action.activate();
          expect(calls).assertEqual(busy ? 0 : 1);
        }
        let calls: number = 0;
        const disabled: OAuthAction = new OAuthAction(provider, (): void => { calls++; }, false, false);
        disabled.activate();
        expect(disabled.enabled).assertFalse();
        expect(calls).assertEqual(0);
      }
    });

    it('sheet_protected_blocks_swipe_and_mask_but_allows_back_and_close', 0, () => {
      for (const protectedSheet of [false, true]) {
        expect(SheetDismissPolicy.allows('swipe', protectedSheet)).assertEqual(!protectedSheet);
        expect(SheetDismissPolicy.allows('mask', protectedSheet)).assertEqual(!protectedSheet);
        expect(SheetDismissPolicy.allows('back', protectedSheet)).assertTrue();
        expect(SheetDismissPolicy.allows('close', protectedSheet)).assertTrue();
      }
    });

    it('platform_icons_only_three_approved_builtins_and_pdd_alias', 0, () => {
      expect(PlatformIconSource.builtin('taobao')).assertEqual('taobao.png');
      expect(PlatformIconSource.builtin('jd')).assertEqual('jd.png');
      expect(PlatformIconSource.builtin('pdd')).assertEqual('pinduoduo.png');
      for (const key of ['tmall', 'douyin', 'vip', 'unknown', '']) {
        expect(PlatformIconSource.builtin(key)).assertEqual('');
      }
    });
  });
}
