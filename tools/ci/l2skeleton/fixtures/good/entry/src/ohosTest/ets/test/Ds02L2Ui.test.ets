// REFERENCE_ONLY 参照件（摘要）：L2 批 1 共用设备套件 Ds02L2Ui，只留 describe 结构与 L2SKEL 段的登记形态。
import { describe, it as hypiumIt } from '@ohos/hypium';

export const L2SKEL_DEVICE_CASES: string[] = [
  'l2skel_01_catalog_shapes_render_kind_l2_and_reader_skips',
  'l2skel_02_blocks_background_muted_on_surface_light_and_dark',
  'l2skel_03_shimmer_moves_unless_reduced_motion',
  'l2skel_04_host_short_load_never_shows_skeleton',
  'l2skel_05_host_shows_after_300ms_and_stays_at_least_300ms',
  'l2skel_06_font200_skeleton_layout_unchanged'
];

function it(name: string, flags: number, body: () => Promise<void>): void {
  hypiumIt(name, flags, body);
}

export default function ds02L2UiTest() {
  describe('Ds02L2Ui', () => {
    it('l2card_01_catalog_kind_l2_and_ten_samples_render', 0, async (): Promise<void> => {
    });
    l2SkeletonDeviceCases();
  });
}

export function l2SkeletonDeviceCases(): void {
  it(L2SKEL_DEVICE_CASES[0], 0, async (): Promise<void> => {
    });
  it(L2SKEL_DEVICE_CASES[1], 0, async (): Promise<void> => {
    });
  it(L2SKEL_DEVICE_CASES[2], 0, async (): Promise<void> => {
    });
  it(L2SKEL_DEVICE_CASES[3], 0, async (): Promise<void> => {
    });
  it(L2SKEL_DEVICE_CASES[4], 0, async (): Promise<void> => {
    });
  it(L2SKEL_DEVICE_CASES[5], 0, async (): Promise<void> => {
  });
}
