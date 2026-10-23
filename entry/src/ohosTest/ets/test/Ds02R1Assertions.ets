import { expect } from '@ohos/hypium';
import { Rect } from '@kit.TestKit';

export function assertTargets(a: Rect, b: Rect, density: number): void {
  expect(density > 0).assertTrue();
  for (const r of [a, b]) {
    expect((r.right - r.left) / density >= 48).assertTrue();
    expect((r.bottom - r.top) / density >= 48).assertTrue();
  }
  expect(Math.min(a.right, b.right) <= Math.max(a.left, b.left) ||
    Math.min(a.bottom, b.bottom) <= Math.max(a.top, b.top)).assertTrue();
}

export function assertFourColumns(cells: Rect[], parent: Rect, density: number): void {
  expect(cells.length >= 5).assertTrue();
  const first: Rect = cells[0];
  const width: number = first.right - first.left;
  expect(width > 0).assertTrue();
  let total: number = 0;
  for (let index: number = 0; index < cells.length; index++) {
    const r: Rect = cells[index];
    expect(Math.abs(r.right - r.left - width) <= 2).assertTrue();
    expect(Math.abs(r.bottom - r.top - width) <= 2).assertTrue();
    expect(r.left >= parent.left - 1 && r.right <= parent.right + 1).assertTrue();
    if (index < 4) {
      expect(Math.abs(r.top - first.top) <= 2).assertTrue();
      total += r.right - r.left;
      if (index > 0) { expect(r.left >= cells[index - 1].right).assertTrue(); }
    } else {
      expect(r.top > first.bottom).assertTrue();
      expect(Math.abs(r.left - cells[index - 4].left) <= 2).assertTrue();
    }
  }
  expect(total <= parent.right - parent.left + 2).assertTrue();
  expect(Math.abs((parent.right - parent.left) / density - 320) <= 1).assertTrue();
}
