import { describe, it, expect } from '@ohos/hypium';
import { ColorMetrics } from '@kit.ArkUI';
import { CouliFocus } from '../main/ets/CouliMetrics';
import { CouliColorMode } from '../main/ets/components/ColorMode';

function assertRing(value: ColorMetrics | undefined, dark: boolean): void {
  expect(value !== undefined).assertTrue();
  if (value === undefined) { throw new Error('missing focus stroke'); }
  expect(value.red).assertEqual(dark ? 93 : 38);
  expect(value.green).assertEqual(dark ? 187 : 115);
  expect(value.blue).assertEqual(dark ? 151 : 91);
}
export default function ds02FocusTest() {
  describe('Ds02Focus', () => {
    it('r1_focus_explicit_and_shared_mode_light_dark_light', 0, () => {
      const mode: CouliColorMode = CouliColorMode.shared();
      const original: boolean = mode.dark;
      try {
        for (const dark of [false, true, false]) {
          mode.dark = dark;
          assertRing(CouliColorMode.metrics('focus.ring', dark), dark);
          assertRing(CouliFocus.boxFor(dark).strokeColor, dark);
          assertRing(CouliFocus.box.strokeColor, dark);
        }
      } finally { mode.dark = original; }
    });
  });
}
