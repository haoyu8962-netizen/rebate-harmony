#!/usr/bin/env python3
"""entry_test 必须跑齐必跑名单；只有汇总或只跑了 HelloWorld 不能通过。

HM-07v-a（编排 D10-405 D4 / 测试 v2）：同一测试包分两个设备步（verify.sh），各自核对各自的必跑名单：
  --set main    原 entry 步：DS-02 160 + F-X-05a 9 + F-X-25 6 = 175 条，且不得混进 hm07va_ 用例（拆步后不在这一步跑）
                HM-L2-CARD（#24 只加，README ⑩ 不新增设备步）：目录加 CouliCard 浅 / 深 2 条 + 主步另跑 Ds02L2Ui 8 条，main 175 → 185 条
                HM-L2-SKELETON（#24 只加）：Ds02L2Ui 另加 L2SKEL 段 6 条（Skeleton 加 host × gated 一例，render_all 条数不变），main 185 → 191 条
                HM-L2-BUTTON 起 L2 共用套件 Ds02L2Ui 随主步跑（D10-1177 ⑩，不新增设备步）：+7 条 l2button_，main 191 → 198 条
                HM-L2-PRICE-TAG 同一套件 Ds02L2Ui 另一段随主步跑（D10-1177 ⑩，不新增设备步）：+5 条 l2price_，main 198 → 203 条
                HM-L2-STATE（#24 只加，README ⑩ 不新增设备步）：主步另跑 Ds02L2UiState 7 条，main 175 → 182 条
                HM-L2 批 1 集成 2（D10-1177 ⑨ 整合重出）：五段叠加，main 203 + l2state 7 = 210 条（STATE 段并入 Ds02L2Ui 唯一 describe）
                HM-L2-PRODUCT-CELL（#24 只加，README ⑩ 不新增设备步）：Ds02L2Ui 另加 cell 段 9 条（tools/ci/l2cell/device-cases.txt；目录不增行，render_all 条数不变），main 210 → 219 条
                HM-BATCH1-DEVFIX（#24，编排 D10-1279 ③）：Ds02L2Ui 42 条从主步摘出、单列设备步 entry-l2（--set l2 必跑），主步 notClass 加 Ds02L2Ui，
                main 219 → 177 条（= DS-02 162 + F-X-05a 9 + F-X-25 6）；主步混进任一条 l2 用例即红（套件过滤失效）
                LOCK-harmony 段 3（#24 只加，D10-2135 ④ / D10-2141 ④）：+ LockHarmonySeg3Fake 15 条（LOCKHM_SEG3_FAKE_CASES），main 177 → 192 条
                LOCK-harmony C3 修（#24 只加，D10-2181 (A)）：LockHarmonySeg3Fake 15 → 16 条，main 192 → 193 条
                FU-HM-PHONECHANGE-B120B（#24 只加，D10-2286）：LockHarmonySeg3Fake 16 → 17 条（+ pcb_9），main 193 → 194 条
  --set hm07va  首页视觉 a 段单独步：HM-07v-a 17 条（测试 v3 +2），且只能是这 17 条（套件过滤失效、混进别的套件都报红）
  --set hm07vb  首页视觉 b 段（弹窗与剪贴板浮层）单独步：HM-07v-b 11 条，且只能是这 11 条
  --set hm05r   剪贴板自动识别单独步（HM-05r；测试 v3 起 11 条：默认开启、关闭态、升级迁移、撤回与重新同意），且只能是这 11 条
  --set me12v   「我的」Tab 视觉单独步（APP-12v-harmony 测试 v1：14 条），且只能是这 14 条
  --set me12wa  设置一族视觉单独步（APP-12w-a-harmony 测试 v1：15 条），且只能是这 15 条
  --set me12wb  隐私中心 / 关于 / 客服半屏视觉单独步（APP-12w-b-harmony 测试 v1：17 条），且只能是这 17 条
  --set me12wc  账号状态 / 申诉视觉单独步（APP-12w-c-harmony 测试 v5：21 条），且只能是这 21 条
  --set tabbar  系统底栏单独步（FU-HM-TAB-BAR 测试 v1：7 条），且只能是这 7 条
  --set loginphone  绑定手机号 / 短信登录适配与出错读屏单独步（FU-HM-LOGIN-PHONE-LAYOUT 测试 v1：6 条 tools/ci/loginphone/device-cases.txt；FU-LOGIN-KEYBOARD-AVOID 加 1 条，7 条；FU-HM-LOGIN-BRAND 再加 1 条，8 条），且只能是这 8 条
  --set a11y    FU-HM-A11Y 共用套件 HmA11yUi 单独步（COMMON 段 5 条 tools/ci/a11ycommon/device-cases.txt + FUNDS 段 5 条
                tools/ci/a11yfunds/device-cases.txt；其余两单集成时并入），且只能是这些
                （HM-BATCH1-FREEZE 集成 2：+ AGENT 段 5 条 tools/ci/a11yagent/device-cases.txt，a11y 10 → 15）
                （HM-BATCH1-FREEZE 集成 3：+ HOME-SEARCH 段 5 条 tools/ci/a11yhome/device-cases.txt，a11y 15 → 20）
  --set l2      子集跑 COULI_HM_TEST_FILTER=class=Ds02L2Ui（HM-L2-CARD 8 条 tools/ci/l2card/device-cases.txt + HM-L2-SKELETON 6 条
                tools/ci/l2skeleton/device-cases.txt + HM-L2-BUTTON 7 条 + HM-L2-PRICE-TAG 5 条 + HM-L2-STATE 7 条），且只能是这 33 条；verify 不单列此步（⑩）
                （HM-BATCH1-DEVFIX，D10-1279 ③：verify 单列设备步 entry-l2 = class=Ds02L2Ui + --set l2，42 条必跑；上句「verify 不单列此步」自此作废）
                （HM-L2 批 1 集成：class=Ds02L2Ui 跑的是唯一 describe 里的全部段，所以 l2 = 四段并集 14 → 26）
                （HM-L2 批 1 集成 2：STATE 段并入唯一 describe，原 --set l2state 的子集过滤 class=Ds02L2UiState 不复存在，这 7 条 tools/ci/l2state/device-cases.txt 并入 l2，26 → 33）
                （HM-L2-PRODUCT-CELL：cell 段 9 条 tools/ci/l2cell/device-cases.txt 同在唯一 describe，并入 l2，33 → 42）
  --set all     不分步时的合集（323 条 = 288 + CouliCard 渲染 2 + Ds02L2Ui 33，允许以后增补用例）；缺省
                HM-L2-PRODUCT-CELL（#24 只加）：+ cell 段 9 条，合集 323 → 332（= 288 + CouliCard 渲染 2 + Ds02L2Ui 42）
                FU-HM-LOGIN-PHONE-LAYOUT（#24 只加）：+ 单独步 loginphone 6 条（tools/ci/loginphone/device-cases.txt），合集 332 → 338
                FU-HM-A11Y-COMMON（#24 只加）：+ 单独步 a11y 5 条（tools/ci/a11ycommon/device-cases.txt），合集 338 → 343
                FU-HM-A11Y-FUNDS（#24 只加）：+ a11y 步 FUNDS 段 5 条（tools/ci/a11yfunds/device-cases.txt），a11y 5 → 10，合集 343 → 348
                HM-BATCH1-FREEZE 集成 1（#24 只加）：DEVFIX（entry-l2 单列，main 219 → 177）与 A11Y（entry-a11y，a11y 10）叠加：
                main 177、l2 42、a11y 10，合集 348（l2 改单列只换步、不改合集）
                HM-BATCH1-FREEZE 集成 2（#24 只加）：+ a11y 步 AGENT 段 5 条（tools/ci/a11yagent/device-cases.txt），a11y 10 → 15，合集 348 → 353
                HM-BATCH1-FREEZE 集成 3（#24 只加）：+ a11y 步 HOME-SEARCH 段 5 条（tools/ci/a11yhome/device-cases.txt），a11y 15 → 20，合集 353 → 358
                LOCK-harmony 段 3（#24 只加）：+ 主步 LockHarmonySeg3Fake 15 条，main 177 → 192，合集 358 → 373
                LOCK-harmony C3 修（#24 只加，D10-2181 (A)）：LockHarmonySeg3Fake 15 → 16 条，main 192 → 193，合集 373 → 374
                FU-HM-PHONECHANGE-B120B（#24 只加，D10-2286）：LockHarmonySeg3Fake 16 → 17 条（+ pcb_9），main 193 → 194，合集 374 → 375
                FU-LOGIN-KEYBOARD-AVOID（#24 只加，D10-2460）：+ loginphone_07，loginphone 6 → 7，合集 375 → 376
                FU-HM-LOGIN-BRAND（#24 只加，D10-2730 / D10-2732）：+ loginphone_08，loginphone 7 → 8，合集 376 → 377
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
# LOCK-harmony 段 3（#24 只加，编排 D10-2135 ④ / D10-2141 ④）：假服务设备用例（LockHarmonySeg3Fake，在 entry List 登记、随主步跑）；
# 与 ds02/check-ui-facilities.cjs 的 FOREIGN_SUITES 名单一致，test_test_facilities.py 守。
LOCKHM_SEG3_FAKE_CASES = [
    's3f_1_step_up_sms_with_phone_20001_fields_phone',
    's3f_2_step_up_sms_without_authorization_10001',
    's3f_3_step_up_sms_phone_unbound_20001_fields_code',
    's3f_4_step_up_sms_member_bound_without_phone_succeeds',
    's3f_5_verify_payout_missing_or_malformed_summary_20001_fields_summary',
    's3f_6_verify_payout_with_valid_summary_issues_token',
    's3f_7_verify_other_actions_with_summary_20001_without_ok',
    's3f_8_save_payout_body_must_match_claim_mismatch_10003_not_consumed',
    's3f_9_save_payout_bank_card_matches_and_withdraw_token_rejected',
    's3f_10_save_payout_without_token_10003',
    's3f_11_withdraw_without_token_10003_with_withdraw_token_ok',
    's3f_12_get_me_masked_phone_bound_and_unbound',
    's3f_14_save_payout_success_consumes_token_new_key_same_token_10003',
    's3f_13_release_step_up_slot_is_digitless_placeholder_when_account_present',
    's3f_15_staging_step_up_slot_bound_when_fake_off_test_phone_when_fake_on',
    # LOCK-harmony C3 修（D10-2181 (A)，#24 只加）：+1 条，15 → 16。
    's3f_16_route_unavailable_override_wins_over_available_in_staging_release_ignores_it',
    # FU-HM-PHONECHANGE-B120B（D10-2286，#24 只加）：+1 条 pcb_9，16 → 17。
    'pcb_9_phone_change_available_release_false_staging_fake_gate_or_override_unavailable_wins',
]
SETS = ('main', 'hm07va', 'hm07vb', 'hm05r', 'me12v', 'me12wa', 'me12wb', 'me12wc', 'tabbar', 'loginphone', 'a11y', 'l2', 'all')


def hm07va_names():
    """HM-07v-a：首页视觉 a 段的设备用例（名单与 Hm07vHomeUi.test.ets 的 HM07VA_DEVICE_CASES 一致）。"""
    return {line.strip() for line in (Path(__file__).parents[1] / 'hm07v/fixtures/device-cases.txt').read_text().splitlines()
            if line.strip() and not line.startswith('#')}


def hm07vb_names():
    """HM-07v-b：首页视觉 b 段（弹窗与剪贴板浮层）的设备用例（名单与 Hm07vOverlayUi.test.ets 的 HM07VB_DEVICE_CASES 一致）。"""
    return {line.strip() for line in (Path(__file__).parents[1] / 'hm07v/fixtures/device-cases-b.txt').read_text().splitlines()
            if line.strip() and not line.startswith('#')}


def hm05r_names():
    """HM-05r：剪贴板自动识别与设置开关的设备用例（名单与 Hm05rConsentUi.test.ets 的 HM05R_DEVICE_CASES 一致）。"""
    return {line.strip() for line in (Path(__file__).parents[1] / 'hm05r/fixtures/device-cases.txt').read_text().splitlines()
            if line.strip() and not line.startswith('#')}


def me12v_names():
    """APP-12v-harmony：「我的」Tab 视觉的设备用例（名单与 Me12vUi.test.ets 的 ME12V_DEVICE_CASES 一致）。"""
    return {line.strip() for line in (Path(__file__).parents[1] / 'me12v/fixtures/device-cases.txt').read_text().splitlines()
            if line.strip() and not line.startswith('#')}


def me12wa_names():
    """APP-12w-a-harmony：设置一族视觉的设备用例（名单与 Me12waUi.test.ets 的 ME12WA_DEVICE_CASES 一致）。"""
    return {line.strip() for line in (Path(__file__).parents[1] / 'me12wa/fixtures/device-cases.txt').read_text().splitlines()
            if line.strip() and not line.startswith('#')}


def me12wb_names():
    """APP-12w-b-harmony：隐私中心 / 关于 / 客服半屏视觉的设备用例（名单与 Me12wbUi.test.ets 的 ME12WB_DEVICE_CASES 一致）。"""
    return {line.strip() for line in (Path(__file__).parents[1] / 'me12wb/fixtures/device-cases.txt').read_text().splitlines()
            if line.strip() and not line.startswith('#')}


def me12wc_names():
    """APP-12w-c-harmony：账号状态 / 申诉视觉的设备用例（名单与 Me12wcUi.test.ets 的 ME12WC_DEVICE_CASES 一致）。"""
    return {line.strip() for line in (Path(__file__).parents[1] / 'me12wc/fixtures/device-cases.txt').read_text().splitlines()
            if line.strip() and not line.startswith('#')}


def tabbar_names():
    """FU-HM-TAB-BAR：系统底栏的设备用例（名单与 TabBarShellUi.test.ets 的 TABBAR_DEVICE_CASES 一致）。"""
    return {line.strip() for line in (Path(__file__).parents[1] / 'tabbar/device-cases.txt').read_text().splitlines()
            if line.strip() and not line.startswith('#')}


def a11y_names():
    """FU-HM-A11Y：共用套件 HmA11yUi 的设备用例（COMMON 段名单与 HmA11yUi.test.ets 的 A11Y_COMMON_DEVICE_CASES 一致；其余三单集成时各加一份名单）。"""
    names = set()
    # FU-HM-A11Y-FUNDS（#24 只加）：FUNDS 段名单并入（与 HmA11yFundsCases.ets 的 A11Y_FUNDS_DEVICE_CASES 一致）。
    # HM-BATCH1-FREEZE 集成 2（#24 只加）：AGENT 段名单并入（与 A11yAgentSeg.ets 的 A11Y_AGENT_DEVICE_CASES 一致）。
    # HM-BATCH1-FREEZE 集成 3（#24 只加）：HOME-SEARCH 段名单并入（与 A11yHomeSearchSeg.ets 的 A11Y_HS_DEVICE_CASES 一致）。
    for rel in ('a11ycommon/device-cases.txt', 'a11yfunds/device-cases.txt', 'a11yagent/device-cases.txt',
                'a11yhome/device-cases.txt'):
        names |= {line.strip() for line in (Path(__file__).parents[1] / rel).read_text().splitlines()
                  if line.strip() and not line.startswith('#')}
    return names


def loginphone_names():
    """FU-HM-LOGIN-PHONE-LAYOUT：绑定手机号 / 短信登录的设备用例（名单与 LoginPhoneUi.test.ets 的 LOGINPHONE_DEVICE_CASES 一致）。"""
    return {line.strip() for line in (Path(__file__).parents[1] / 'loginphone/device-cases.txt').read_text().splitlines()
            if line.strip() and not line.startswith('#')}


def l2_names():
    """HM-L2-CARD：L2 批 1 共用设备套件 Ds02L2Ui 的设备用例（名单与 Ds02L2Ui.test.ets 的 L2CARD_DEVICE_CASES 一致，check_l2_card.py C7-cases 守）。主 entry 步里跑。"""
    return {line.strip() for line in (Path(__file__).parents[1] / 'l2card/device-cases.txt').read_text().splitlines()
            if line.strip() and not line.startswith('#')}


def l2skel_names():
    """HM-L2-SKELETON（#24 只加）：同一套件 Ds02L2Ui 的 L2SKEL 段设备用例（名单与 Ds02L2Ui.test.ets 的 L2SKEL_DEVICE_CASES 一致，check_l2_skeleton.py K8-cases 守）。主 entry 步里跑，子集跑并入 l2。"""
    return {line.strip() for line in (Path(__file__).parents[1] / 'l2skeleton/device-cases.txt').read_text().splitlines()
            if line.strip() and not line.startswith('#')}


def l2button_names():
    """HM-L2-BUTTON（D10-1177 ⑩）：同一套件 Ds02L2Ui 的 ds02L2UiButtonCases 段设备用例（带 mode 的按 light / dark 展开；test_test_facilities.py 与 it('l2button_…') 比对）。
    主 entry 步里跑；HM-L2 批 1 集成：名单原样从 expected_names 挪到这里（只换定位），子集跑并入 l2。"""
    names = set()
    names.update('l2button_01_couli_button_all_variants_states_render_system_button_' + mode for mode in ['light', 'dark'])
    names.update({'l2button_02_buy_button_states_text_and_enabled', 'l2button_03_font_200_no_truncation_and_hit_target_48',
                  'l2button_05_rapid_taps_on_inactive_buttons_fire_zero_callbacks'})
    names.update('l2button_04_token_roles_primary_secondary_disabled_' + mode for mode in ['light', 'dark'])
    return names


def l2price_names():
    """HM-L2-PRICE-TAG（D10-1177 ⑩）：同一套件 Ds02L2Ui 的 ds02L2UiPriceTagCases 段设备用例（带 mode 的按 light / dark 展开；test_test_facilities.py 与 it('l2price_…') 比对）。
    主 entry 步里跑；HM-L2 批 1 集成：名单原样从 expected_names 挪到这里（只换定位），子集跑并入 l2。"""
    names = set()
    names.update({'l2price_01_price_tag_variants_amount_whole_at_100_and_200', 'l2price_02_rebate_tag_states_whole_at_100_and_200',
                  'l2price_04_amount_toggle_replaces_value_in_place_without_flash'})
    names.update('l2price_03_token_roles_price_text_rebate_text_background_' + mode for mode in ['light', 'dark'])
    return names


def l2state_names():
    """HM-L2-STATE：L2 共用设备套件 Ds02L2Ui 的空态 / 错误态段 Ds02L2UiState（名单与 Ds02L2Ui.test.ets 的 L2STATE_DEVICE_CASES 一致）。"""
    return {line.strip() for line in (Path(__file__).parents[1] / 'l2state/device-cases.txt').read_text().splitlines()
            if line.strip() and not line.startswith('#')}


def l2cell_names():
    """HM-L2-PRODUCT-CELL（#24 只加）：同一套件 Ds02L2Ui 的 cell 段（ds02L2UiCellCases；名单与 L2CELL_DEVICE_CASES 一致，check_l2_cell.py P9-cases 守）。
    主 entry 步里跑，子集跑并入 l2。"""
    return {line.strip() for line in (Path(__file__).parents[1] / 'l2cell/device-cases.txt').read_text().splitlines()
            if line.strip() and not line.startswith('#')}


def expected_names(set_name='all'):
    if set_name not in SETS:
        raise ValueError('未知必跑名单 ' + str(set_name))
    if set_name == 'hm07va':
        return hm07va_names()
    if set_name == 'hm07vb':
        return hm07vb_names()
    if set_name == 'hm05r':
        return hm05r_names()
    if set_name == 'me12v':
        return me12v_names()
    if set_name == 'me12wa':
        return me12wa_names()
    if set_name == 'me12wb':
        return me12wb_names()
    if set_name == 'me12wc':
        return me12wc_names()
    if set_name == 'tabbar':
        return tabbar_names()
    if set_name == 'loginphone':
        return loginphone_names()
    if set_name == 'a11y':
        return a11y_names()
    if set_name == 'l2':
        return l2_names() | l2skel_names() | l2button_names() | l2price_names() | l2state_names() | l2cell_names()
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
    # LOCK-harmony 段 3（#24 只加，D10-2135 ④）：LockHarmonySeg3Fake 15 条随主步跑，main / all 都列为必跑（C3 修 D10-2181：15 → 16 条；FU-HM-PHONECHANGE-B120B D10-2286：16 → 17 条）。
    names.update(LOCKHM_SEG3_FAKE_CASES)
    # HM-L2-CARD（#24 只加；README ⑩：Ds02L2Ui 在主 entry 步跑，不新增设备步）：main / all 都列为必跑。
    names.update(l2_names())
    # HM-L2-SKELETON（#24 只加）：同一套件的 L2SKEL 段 6 条，main / all 同样列为必跑。
    names.update(l2skel_names())
    # HM-L2-BUTTON（D10-1177 ⑩）：L2 共用套件 Ds02L2Ui 随主步跑（名单与 Ds02L2Ui.test.ets 的 ds02L2UiButtonCases 一致；只加不减）。
    names.update(l2button_names())
    # HM-L2-PRICE-TAG（D10-1177 ⑩）：同一套件 Ds02L2Ui 的第二段随主步跑（名单与 Ds02L2Ui.test.ets 的 ds02L2UiPriceTagCases 一致；只加不减）。
    names.update(l2price_names())
    # HM-L2-STATE（#24 只加；README ⑩：Ds02L2Ui 在主 entry 步跑，不新增设备步）：main / all 都列为必跑。
    names.update(l2state_names())
    # HM-L2-PRODUCT-CELL（#24 只加；README ⑩：Ds02L2Ui 在主 entry 步跑，不新增设备步）：main / all 都列为必跑。
    names.update(l2cell_names())
    if set_name == 'all':
        names.update(hm07va_names())
        names.update(hm07vb_names())
        names.update(hm05r_names())
        names.update(me12v_names())
        names.update(me12wa_names())
        names.update(me12wb_names())
        names.update(me12wc_names())
        names.update(tabbar_names())
        names.update(loginphone_names())
        names.update(a11y_names())
    # HM-BATCH1-DEVFIX（#24，编排 D10-1279 ③）：Ds02L2Ui 摘出主步、单列 entry-l2（--set l2 必跑这 42 条）；main 不再要求，all 照旧含。
    if set_name == 'main':
        names -= expected_names('l2')
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
        leaked = sorted(name for name in ran if name in hm07va_names() | hm07vb_names() | hm05r_names() | me12v_names()
                        | me12wa_names() | me12wb_names() | me12wc_names() | tabbar_names() | loginphone_names() | a11y_names()
                        | expected_names('l2'))  # HM-BATCH1-DEVFIX（D10-1279 ③）：主步混进 Ds02L2Ui 用例也红
        if leaked:
            raise ValueError(f'entry_test(main) 混进了 HM-07v-a / HM-07v-b / HM-05r / APP-12v / APP-12w-a / APP-12w-b / APP-12w-c 单独步的用例（套件过滤失效）: {leaked}')
    if set_name in ('hm07va', 'hm07vb', 'hm05r', 'me12v', 'me12wa', 'me12wb', 'me12wc', 'tabbar', 'loginphone', 'a11y', 'l2'):
        extra = sorted(ran - expected)
        if extra:
            raise ValueError(f'entry_test({set_name}) 跑了本步名单以外的用例（套件过滤失效）: {extra}')
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
            raise ValueError('用法：check_device_result.py <aa-test 结果> [--set main|hm07va|hm07vb|hm05r|me12v|me12wa|me12wb|me12wc|tabbar|loginphone|a11y|l2|all]')
        # FU-NATIVE-SEG-LOCALE-FIXES（D10-1683 ②）：坏字节换成 U+FFFD 再判（与 fv.py _text 同读法）；名字对不上只会更严。
        count = validate(Path(args[0]).read_text(encoding='utf-8', errors='replace'), chosen)
        print(f'DS02_DEVICE_COMPLETE set={chosen} required={count} all_passed')
    except (ValueError, OSError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
