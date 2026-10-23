#!/usr/bin/env python3
"""源级 NavBar 变异：只在读入时替换，不写产品文件、不冒充编译/设备通过。"""
from pathlib import Path
from unittest.mock import patch
import unittest
from test_host import Ds02Host, ROOT

TARGET = ROOT / 'common/designsystem/src/main/ets/components/Navigation.ets'
original = Path.read_text
source = original(TARGET)
start = source.index('  build() {', source.index('export struct NavBar'))
end = source.index('\n}\n', start)
mutant = source[:start] + '''  build() {
    Row() {
      CouliIcon({ name: 'back' })
      Text(this.title)
    }
  }''' + source[end:]
assert mutant != source

for changed in [False, True]:
    def read(path, *args, **kwargs):
        return mutant if changed and path == TARGET else original(path, *args, **kwargs)
    result = unittest.TestResult()
    with patch.object(Path, 'read_text', read):
        Ds02Host('test_r1_same_navigation_component_in_catalog_and_pages').run(result)
    assert not result.errors, result.errors
    assert len(result.failures) == (1 if changed else 0), result.failures
    print('KILLED M-R1-01 selfdrawn NavBar (real source, host wiring assertion)' if changed else 'PASS NavBar baseline')
    if changed:
        assert 'Navigation' in result.failures[0][1]
