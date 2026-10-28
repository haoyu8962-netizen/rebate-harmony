#!/usr/bin/env python3
"""entry_test 必须跑齐必跑名单；只有汇总或只跑了 HelloWorld 不能通过。

HM-07v-a（编排 D10-405 D4 / 测试 v2）：同一测试包分两个设备步（verify.sh），各自核对各自的必跑名单：
  --set main    原 entry 步：DS-02 158 + F-X-05a 9 + F-X-25 6 = 173 条，且不得混进 hm07va_ 用例（拆步后不在这一步跑）
  --set hm07va  首页视觉 a 段单独步：HM-07v-a 17 条（测试 v3 +2），且只能是这 17 条（套件过滤失效、混进别的套件都报红）
  --set all     不分步时的合集（190 条，允许以后增补用例）；缺省
"""
import collections
import csv
from pathlib import Path
import re
import sys


# F-X-25 设备用例（AuthChangeDevice_FX25；与 ds02/check-ui-facilities.cjs 的 FOREIGN_SUITES 名单一致，test_test_facilities.py 守）。
FX25_DEVICE_CASES = [
    'E01_real_trusted_storage_is_gone_after_account_switch_and_old_document_received_event',
    'E02_I6_only_external_real_arkweb_http_cache_survives_auth_cleanup',
    'E04_I6_no_arg_cookie_clear_keeps_incognito_external_cookie',
    'E05_R3_04_production_sandbox_owner_mismatch_cleans_before_first_trusted_load',
    'E06_covered_host_tears_down_while_covered_and_shows_clean_new_document_after_pop',
    'E07_NR1_01_old_document_beacon_and_keepalive_late_set_cookie_never_reaches_new_account',
]
SETS = ('main', 'hm07va', 'all')


def hm07va_names():
    """HM-07v-a：首页视觉 a 段的设备用例（名单与 Hm07vHomeUi.test.ets 的 HM07VA_DEVICE_CASES 一致）。"""
    return {line.strip() for line in (Path(__file__).parents[1] / 'hm07v/fixtures/device-cases.txt').read_text().splitlines()
            if line.strip() and not line.startswith('#')}


def expected_names(set_name='all'):
    if set_name not in SETS:
        raise ValueError('未知必跑名单 ' + str(set_name))
    if set_name == 'hm07va':
        return hm07va_names()
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
    # F-X-05a：平台内置图标的设备用例（名单与 entry/src/ohosTest/ets/test/Fx05aUi.test.ets 的 FX05A_DEVICE_CASES 一致）。
    names.update(line.strip() for line in (Path(__file__).parents[1] / 'fx05a/fixtures/device-cases.txt').read_text().splitlines()
                 if line.strip() and not line.startswith('#'))
    # F-X-25：此前只按 check-ui-facilities.cjs 核对注册名，设备结果里未逐条要求；拆步后 main 名单把这 6 条也列为必跑（只加不减）。
    names.update(FX25_DEVICE_CASES)
    if set_name == 'all':
        names.update(hm07va_names())
    return names


def validate(text, set_name='all'):
    expected = expected_names(set_name)
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
        raise ValueError(f'entry_test({set_name}) 不完整: missing={missing}, failed={failed}, duplicate={duplicates}, '
                         f'summary={summaries[-1]}')
    ran = set(passed.keys()) | set(failed)
    if set_name == 'main':
        leaked = sorted(name for name in ran if name in hm07va_names())
        if leaked:
            raise ValueError(f'entry_test(main) 混进了 HM-07v-a 单独步的用例（套件过滤失效）: {leaked}')
    if set_name == 'hm07va':
        extra = sorted(ran - expected)
        if extra:
            raise ValueError(f'entry_test(hm07va) 跑了 HM-07v-a 以外的用例（套件过滤失效）: {extra}')
    if not re.search(r'^OHOS_REPORT_CODE: 0\s*$', text, re.M) or not re.search(r'^TestFinished-ResultCode: 0\s*$', text, re.M):
        raise ValueError('entry_test 缺成功结束标记')
    return len(expected)


if __name__ == '__main__':
    args = sys.argv[1:]
    chosen = 'all'
    if '--set' in args:
        at = args.index('--set')
        chosen = args[at + 1] if at + 1 < len(args) else ''
        del args[at:at + 2]
    try:
        if len(args) != 1:
            raise ValueError('用法：check_device_result.py <aa-test 结果> [--set main|hm07va|all]')
        count = validate(Path(args[0]).read_text(), chosen)
        print(f'DS02_DEVICE_COMPLETE set={chosen} required={count} all_passed')
    except (ValueError, OSError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
