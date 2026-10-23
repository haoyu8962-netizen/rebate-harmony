#!/usr/bin/env python3
"""entry_test 必须跑齐 DS-02；只有汇总或只跑了 HelloWorld 不能通过。"""
import collections
import csv
from pathlib import Path
import re
import sys


def expected_names():
    inventory = Path(__file__).parent / 'fixtures/inventory.tsv'
    rows = csv.DictReader((line for line in inventory.read_text().splitlines()
                           if not line.startswith('#')), delimiter='\t')
    names = set()
    for row in rows:
        suffixes = row['variants'].split(',') if row['component'] == 'ProductCard' else ['']
        for variant in suffixes:
            for mode in ['light', 'dark']:
                suffix = variant + '_' + mode if variant else mode
                names.add('render_all_declared_states_' + row['component'] + '_' + suffix)
    names.update({
        'all_inventory_components_variants_states_and_kinds',
        'real_secondary_button_renders_light_dark_and_restored_tokens',
        'third_party_row_real_order_sizes_and_no_overlap',
        'system_switch_radio_segment_and_navigation_back',
        'agreement_links_do_not_toggle_and_confirmation_updates_same_checkbox',
        'large_font_changes_real_component_and_restores',
    })
    names.update('real_checkbox_toggle_disabled_accessibility_hit_region_' + name
                 for name in ['CouliCheckbox', 'AgreementCheckRow'])
    names.update('real_sheet_mask_swipe_back_close_' + name for name in ['false', 'true'])
    names.update('large_font_reaches_real_window_' + name for name in ['Dialog', 'Sheet', 'AlertDialog', 'ActionMenu'])
    names.update('standalone_oauth_busy_is_disabled_' + name for name in ['huawei', 'wechat'])
    names.update('real_semantic_resources_' + name for name in ['light', 'dark', 'restored'])
    names.update({'r1_readonly_blocks_focused_keyboard_paste_and_clear', 'r1_tabbar_system_tabs_selection_changes', 'r1_share_six_materials_four_columns_at_320vp', 'r1_navbar_system_nodes_and_host_back_interception', 'r1_filterchip_48vp_disjoint_and_edge_tap', 'r1_segment_same_instance_light_dark_light_pixels'})
    names.add('r2_tabbar_click_veto_sync_and_replaced_selected_entry')
    return names


def validate(text):
    expected = expected_names()
    passed = collections.Counter()
    failed = []
    name = None
    for line in text.splitlines():
        match = re.fullmatch(r'OHOS_REPORT_STATUS: test=(.*)', line.strip())
        if match:
            name = match[1]
        match = re.fullmatch(r'OHOS_REPORT_STATUS_CODE: (-?\d+)', line.strip())
        if match and name is not None and match[1] != '1':
            if match[1] == '0':
                passed[name] += 1
            else:
                failed.append(name)
            name = None
    missing = sorted(expected - passed.keys())
    duplicates = sorted(name for name, count in passed.items() if count != 1)
    summaries = re.findall(r'Tests run: (\d+), Failure: (\d+), Error: (\d+), Pass: (\d+)', text)
    if not summaries:
        raise ValueError('entry_test 无汇总')
    total, failures, errors, successes = map(int, summaries[-1])
    # 允许以后增补用例，但报告中的通过数必须与逐例记录完全一致。
    if missing or failed or duplicates or failures or errors or total != successes or successes != sum(passed.values()):
        raise ValueError(f'entry_test 不完整: missing={missing}, failed={failed}, duplicate={duplicates}, summary={summaries[-1]}')
    if not re.search(r'^OHOS_REPORT_CODE: 0\s*$', text, re.M) or not re.search(r'^TestFinished-ResultCode: 0\s*$', text, re.M):
        raise ValueError('entry_test 缺成功结束标记')
    return len(expected)


if __name__ == '__main__':
    try:
        count = validate(Path(sys.argv[1]).read_text())
        print(f'DS02_DEVICE_COMPLETE required={count} all_passed')
    except (ValueError, OSError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
