#!/usr/bin/env python3
"""APP-12w-c-harmony（账号状态 RiskNotice / 申诉 Appeal 视觉）宿主检查（测试作者 v1）。依据 NATIVE/APP-12w/brief-c-harmony.md §2、§2.1（处罚 /
申诉红线六条落点，S0）、§3（逻辑零改动证明、两视图守卫区、私有件静态规则）、§4.3、§6（H-R01–H-R22，裁定前照推荐）。照 tools/ci/me12wb/
check_privacy_visual.py 的写法；与 me12v / me12wa / me12wb 三份守卫共存（它们钉的文件这里也钉，基线各自独立，不互相改）。
只用 Python 3 标准库；不调 git（基线是仓库里的 fixture，其 sha256 钉在本文件里，改 fixture 即红）。

检查项：
  G0 fixture risk-baseline-30201f0.json 的 sha256 钉在本文件；从 fixture 抽不到守卫符号也报红
  G1 逻辑与边界文件 sha256 与 REV（30201f0）一致（§3.1）：Core 执行器 / 纯规则 / 会话 / JSON / 客服出口、entry 的 AppMe / MePages / AppCsSheet /
     AppMeTexts / AppClipboard / AccountPages / AppAccount、MeKit、contract.lock、specs/me-vectors.json；整树：core me/**（含 account）、
     core wallet/**、entry me/** / account/** / wallet/** / routing/**、features/me/**（只豁免两视图与新私有件 RiskAppealParts.ets；不许新增别的
     文件）、common/designsystem/**、contracts/**
  G2 只许插入行（REV 的每一行按原顺序仍在）：MeDraftTexts.ets（H-R04 三个新键）、staging DebugFakeMe.ets（H-R15 场景与提交计数）
  G4 两视图守卫区（§3.2，按符号）与 REV 逐字节一致：类、方法（noteKey / detailRows 只许 H-R03 的键串替换，upheldStateCard 同理）、content /
     footer 分支条件、回调体与关键表达式（主按钮去向、出口三链接、提交按钮三属性、onChange、ForEach 键、【再次申诉】、解除结果四个动作）、
     出口链接按 id 与动作配对且在原条件块内、静态调用集合不变、不在视图里比较 frozen_until 与当前时间、title() 只许 H-R06 两分支
  S1–S12 视觉与红线静态规则：私有件在 RiskAppealParts.ets（@ComponentV2、只收值与 @Event、无中文 / 色值字面量、不直用系统输入控件）；
     头部 RiskHero（Symbol lock / pause_circle / clock / checkmark_circle，标题 title 22 + TITLE_BAR）、信息行 RiskInfoRow、提示条
     RiskNoteStrip、出口分隔符 RiskExitSep 与后一链接同组（F-HM-74 ③）、块间 24；申诉卡 AppealInfoCard / InlineRow、输入框 placeholder /
     min 160、白底栏、状态卡胶囊 + 标题、时间线 AppealTimeline、「接下来可以」BulletCard、维持 SECONDARY；胶囊色映射纯函数只读 riskState；
     H-R03 退役草稿键不再被视图取用、H-R04 三个新键；红线：视图无 onClick / 手势、不读 CT-26e 字段、不接 SLA；设备用例依赖的 id；
     staging H-R15 场景与提交 / 列表计数键；risk-appeal-visual-vectors.json 与 Android 逐字节相同（H-R14）
  C1–C3 设备名单三处一致、describe 名；verify 主步排除 Me12wcUi、第九个 entry 设备步 entry-me12wc、本宿主步四条命令（排在 me12wb 之后）；
     check_device_result / device-test 认 me12wc；core / entry 两个 List 登记（entry 在 hm07vHomeUiTest 之前）

用法：
  check_risk_visual.py               本仓库
  check_risk_visual.py --self-test   层一：参考桩树（逻辑文件为合成件、基线随之合成；两视图用 REV 原文按 §3.2「允许改」打补丁成参考实现）
                                     全过 + 每种错误实现各自打红（定位串必须恰好一次）；层二：本仓库检查通过时把真实文件拷出再逐个变异
                                     （未通过时跳过并说明）
"""
import hashlib
import itertools
import json
import re
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
REV = '30201f0'
FIXTURE = 'tools/ci/me12wc/fixtures/risk-baseline-' + REV + '.json'
# fixture 指纹（NATIVE/APP-12w/tests-c-harmony-v1-aux/make_baseline_c.py 由 git show REV 生成；改 fixture 来迁就实现即红）。
FIXTURE_SHA256 = '00d90a7901ed03bbd1a4e9ed946cd63a998790f2a850bf1ff29a56c42e43c31a'

ME = 'features/me/src/main/ets/'
V_RISK = ME + 'RiskNoticeView.ets'
V_APPEAL = ME + 'AppealView.ets'
PARTS = ME + 'RiskAppealParts.ets'
DRAFT = 'common/core/src/main/ets/me/MeDraftTexts.ets'
FAKE_ME = 'entry/src/staging/ets/variant/DebugFakeMe.ets'
VECTORS = 'specs/risk-appeal-visual-vectors.json'
# H-R14：Android origin/main 6557750 的 specs/risk-appeal-visual-vectors.json（489 行）。
VECTORS_SHA256 = '2144a9a9cfbf7447f100d1367a053e21fb5bb4ed2f915df923921700a711a5f0'
SKIP_PARTS = {'build', '.test', 'oh_modules', '.hvigor', '.preview', 'node_modules'}
TREE_SKIP = ('src/test/', 'src/ohosTest/')

# H-R03（推荐）：守卫区里只许这几个键串按清单替换（其余逐字节）。每项（方法名, 旧键串, 新键串）；守卫按「任意子集已替换」比对。
KEY_SWAPS = {
    V_RISK: {
        'noteKey': [("'risk.banned_upheld.note'", "'risk_notice.banned.upheld'"),
                    ("'risk.frozen_upheld.note'", "'risk_notice.banned.upheld'"),
                    ("'risk.frozen.note_no_until'", "'risk_notice.frozen.hint_no_until'")],
        'detailRows': [("'risk.limit.long'", "'risk_notice.period_none'")],
    },
    V_APPEAL: {},
}
# H-R03 推荐方案下视图不再取用的草稿键（MeDraftTexts 已有行一字不动；用户看到的句子由契约键给出，= 夹具 drafts）。
RETIRED_KEYS = ["'risk.limit.long'", "'risk.banned_upheld.note'", "'risk.frozen_upheld.note'", "'risk.frozen.note_no_until'",
                "'appeal.next.again'", "'appeal.next.delete_logout'"]
NEW_KEYS = {
    V_RISK: ["'risk_notice.banned.upheld'", "'risk_notice.frozen.hint_no_until'", "'risk_notice.period_none'", "'risk.banned.desc.no_deletion'"],
    V_APPEAL: ["'appeal.result.next.resubmit'", "'appeal.next.logout.with_deletion'", "'appeal.placeholder'", "'risk_notice.period_none'"],
}
# H-R04：MeDraftTexts 只插入的三个三端同键（值 = 夹具 drafts，逐字）。
DRAFT_LINES = ["m.set('appeal.placeholder', '请说明情况，方便我们核实');",
               "m.set('risk.banned.desc.no_deletion', '限制期间只能查看本页、提交申诉、联系客服或退出登录。');",
               "m.set('appeal.next.logout.with_deletion', '不再使用，可以注销账号；也可以退出登录。');"]

GUARD = {
    V_RISK: {
        'classes': ['RiskNoticeConfig', 'RiskModel'],
        'methods': ['aboutToAppear', 't', 'apply', 'layout', 'showBack', 'str', 'banned', 'pendingRows', 'withdrawalText', 'noteKey',
                    'detailRows'],
        # content / footer 的分支条件（整行去缩进后逐字节）。
        'lines': ['if (this.model.phase === MePhase.ERROR) {', '} else if (this.model.view !== null) {',
                  'if (this.layout() !== RiskLayout.NORMAL) {', 'if (this.model.withdrawalsError.length > 0) {',
                  'if (this.model.view !== null) {', 'if (this.layout() === RiskLayout.NORMAL) {',
                  "} else if ((this.model.view as MeRecord)['primaryRaw'] === 'view_progress') {",
                  'if (this.banned() || (this.model.view === null && this.model.phase === MePhase.ERROR)) {',
                  'if (this.config.deleteAccountAvailable()) {'],
        # 去注释、去空白后必须出现的次数（None = 至少一次）。
        'calls': {
            'this.config.controller.retry();': 1,
            'retryDisabled: this.model.blocked,': 1,
            "retryId: 'risk_retry',": 1,
            'tappable: !this.model.blocked,': 1,
            'this.config.controller.retryWithdrawals();': 1,
            "barId: 'risk_withdrawals_error',": 1,
            "this.t('risk.withdrawals') + PriceTerms.comma + this.model.withdrawalsError + '\\n' + this.t('me.retry')": 1,
            "this.config.open('Appeal', {})": 2,
            'this.config.backHome()': 1,
            'this.config.customerService()': 1,
            'this.config.deleteAccount(this.config.controller.identity)': 1,
            'this.config.logout(this.config.controller.identity)': 1,
            'showBack: this.showBack(),': 1,
            "(row: string[]) => row[2] + '_' + row[1] + '_' + this.model.version)": 1,
            'ForEach(this.detailRows(), (row: string[], index: number) => {': 1,
            "this.t(this.noteKey())": 1,
            # R32 / H-R04：说明句与注销链接同一判据、同一调用。
            "this.config.deleteAccountAvailable() ? 'risk.banned.desc' : 'risk.banned.desc.no_deletion'": 1,
            'this.config.deleteAccountAvailable()': 2,
        },
        # 字面量 → 所在组件调用里必须有的表达式（id 与去向 / 动作配对）。
        'owners': [
            ("'risk_back_home'", ['CouliButton', "text: this.t('risk.normal.back_home'),", 'fullWidth: true,', 'onTap: () => this.config.backHome()']),
            ("'risk_view_progress'", ['CouliButton', "text: this.t('risk.view_progress'),", 'fullWidth: true,',
                                      "onTap: () => this.config.open('Appeal', {})"]),
            ("'risk_submit_appeal'", ['CouliButton', "text: this.t('risk.submit'),", 'fullWidth: true,',
                                      "onTap: () => this.config.open('Appeal', {})"]),
            ("'risk_contact_cs'", ['MeLink', "text: this.t('risk.contact_cs'),", 'onTap: () => this.config.customerService()']),
            ("'risk_delete_account'", ['MeLink', "text: this.t('settings.delete_account'),",
                                       'onTap: () => this.config.deleteAccount(this.config.controller.identity)']),
            ("'risk_logout'", ['MeLink', "text: this.t('risk.logout'),", 'onTap: () => this.config.logout(this.config.controller.identity)']),
        ],
        # （条件行, 字面量）：字面量必须在该条件块之内（出口与注销入口的显示条件不许被绕开）。
        'inside': [
            ('if (this.banned() || (this.model.view === null && this.model.phase === MePhase.ERROR)) {', "'risk_contact_cs'"),
            ('if (this.banned() || (this.model.view === null && this.model.phase === MePhase.ERROR)) {', "'risk_logout'"),
            ('if (this.banned() || (this.model.view === null && this.model.phase === MePhase.ERROR)) {', "'risk_delete_account'"),
            ('if (this.config.deleteAccountAvailable()) {', "'risk_delete_account'"),
            ('if (this.model.view !== null) {', "'risk_submit_appeal'"),
            ("} else if ((this.model.view as MeRecord)['primaryRaw'] === 'view_progress') {", "'risk_view_progress'"),
            ('if (this.layout() === RiskLayout.NORMAL) {', "'risk_back_home'"),
            ('if (this.model.withdrawalsError.length > 0) {', "'risk_withdrawals_error'"),
        ],
        # 静态调用集合（去重后与 REV 相等，防视图另起判定）。
        'callsets': [r'RiskReasonText\.\w+', r'RiskLayout\.\w+', r'RiskNoticeView\.\w+', r'PendingWithdrawals\.\w+', r'WithdrawalText\.\w+'],
    },
    V_APPEAL: {
        'classes': ['AppealConfig', 'AppealModel'],
        'methods': ['aboutToAppear', 't', 'apply', 'announce', 'str', 'reasonText', 'frozenUntilText', 'time', 'v', 'processingDesc',
                    'liftedNote', 'liftedAction', 'timeVars'],
        'lines': ['if (this.model.phase === MePhase.ERROR) {', '} else if (this.model.phase !== MePhase.CONTENT) {',
                  '} else if (this.model.layout === AppealRules.SUBMIT) {', '} else if (this.model.layout === AppealRules.PROGRESS) {',
                  '} else if (this.model.layout === AppealRules.RESULT_LIFTED) {',
                  'if (this.model.phase === MePhase.CONTENT) {', 'if (this.model.layout === AppealRules.SUBMIT) {',
                  '} else if (this.model.layout === AppealRules.RESULT_UPHELD) {',
                  'if (this.model.fieldError.length > 0) {', 'if (this.model.message.length > 0) {',
                  'if (this.model.currentStateKey !== null) {', 'if (this.reasonText() !== null) {', 'if (this.frozenUntilText() !== null) {',
                  'if (this.model.frozen && this.model.withdrawStateKey !== null) {',
                  '} else if (!this.model.frozen && this.model.currentStateKey !== null) {',
                  'if (this.model.currentBanned) {', '} else if (this.frozenUntilText() !== null) {',
                  "if (this.liftedAction('go_wallet')) {", "if (this.liftedAction('start')) {", "if (this.liftedAction('view_messages')) {",
                  "if (this.liftedAction('contact_cs')) {", 'if (!this.model.frozen) {', 'if (this.config.deleteAccountAvailable()) {',
                  'if (this.liftedNote().length > 0) {'],
        'calls': {
            'ForEach([new Bound(this.model.identity, 0)], (b: Bound) => {': 1,
            'this.submitPage(b)': 1,
            "}, (b: Bound) => 'appeal_submit_' + b.identity)": 1,
            'retryDisabled: this.model.readBlocked,': 1,
            "retryId: 'appeal_retry',": 1,
            'this.config.controller.retry();': 1,
            'this.progressPage()': 1,
            'this.liftedPage()': 1,
            'this.upheldPage()': 1,
            # 输入（红线①）：回调体、id、读屏名与错误描述、错误边色逐字原样；系统 TextArea 只此一处（H-R10）。
            'TextArea({ text: this.model.input': 1,
            '.onChange((value: string) => {': 1,
            'this.config.controller.setInput(value, bound.identity);': 1,
            ".id('appeal_input')": 1,
            ".accessibilityText(this.t('appeal.content_label'))": 1,
            '.accessibilityDescription(this.model.fieldError)': 1,
            '.border({ width: 1, color: this.model.fieldError.length > 0 ? CouliColors.statusErrorText : CouliColors.borderControl })': 1,
            "barId: 'appeal_message', focusTarget: true": 1,
            "this.t(AppealCopy.submitNote(this.model.frozen, this.model.riskState))": 1,
            # 提交按钮（红线①）。
            'this.config.controller.submit(this.config.controller.identity);': 1,
            'loading: this.model.submitting,': 1,
            'disabled: !this.model.submitEnabled || this.model.blocked,': 1,
            # 【再次申诉】（红线②）。
            'this.config.controller.submitAgain(this.config.controller.identity)': 1,
            # 解除结果四个动作。
            "this.config.open('Wallet', {})": 1,
            'this.config.home()': 1,
            "this.config.open('Messages', {})": 1,
            'this.config.customerService()': 3,
            'this.config.deleteAccount(this.config.controller.identity)': 1,
            'this.config.logout(this.config.controller.identity)': 1,
            # 状态卡 / 时间线 / 内容卡的取值原样（R16 / R17 / R18 / R20 / R22 / R23）。
            "this.t(AppealCopy.liftedTitle(this.model.frozen, this.model.riskState))": 1,
            "this.t(AppealCopy.liftedDesc(this.model.riskState))": 1,
            "this.time('created_at')": 1,
            "this.v('appeal.timeline.result_pending.banned', 'appeal.timeline.result_pending.frozen')": 1,
            "this.config.texts.format('appeal.upheld.result_line', this.timeVars(this.time('closed_at')))": 1,
            "this.v('appeal.progress.desc.banned', 'appeal.progress.desc.frozen')": 1,
            "this.str(this.model.latest, 'content') ?? ''": 1,
            'this.t(this.model.currentStateKey as string)': None,
            'this.t((this.model.frozen ? this.model.withdrawStateKey : this.model.currentStateKey) as string)': 1,
            "this.model.frozen ? this.t('appeal.withdraw') : this.t('appeal.state')": 1,
            "this.t(this.model.frozen ? 'appeal.current_frozen_state' : 'appeal.current_account_state')": 1,
            # 「接下来可以」（R25）：四个条件与键选择。
            'AppealCopy.upheldFrozenNext(this.model.frozen, this.model.riskState)': 1,
            "this.config.deleteAccountAvailable() ? 'appeal.next.logout.with_deletion' : 'appeal.next.logout'": 1,
            "this.t('appeal.next.frozen')": 1,
            "this.t('appeal.result.next.resubmit')": 1,
            "this.t('appeal.next.cs')": 1,
            'if (!this.model.frozen) {': 2,
            'this.config.deleteAccountAvailable()': 2,
            'title: this.title(),': 1,
        },
        'owners': [
            ("'appeal_submit'", ['CouliButton', "text: this.t('appeal.submit'),", 'fullWidth: true,', 'loading: this.model.submitting,',
                                 'disabled: !this.model.submitEnabled || this.model.blocked,',
                                 'this.config.controller.submit(this.config.controller.identity);']),
            ("'appeal_go_wallet'", ['CouliButton', "text: this.t('appeal.go_wallet'),", "onTap: () => this.config.open('Wallet', {})"]),
            ("'appeal_start'", ['CouliButton', "text: this.t('appeal.start'),", 'onTap: () => this.config.home()']),
            ("'appeal_view_messages'", ['MeLink', "text: this.t('appeal.view_messages'),", "onTap: () => this.config.open('Messages', {})"]),
            ("'appeal_lifted_cs'", ['MeLink', "text: this.t('appeal.contact_cs'),", 'onTap: () => this.config.customerService()']),
            ("'appeal_contact_cs'", ['MeLink', "text: this.t('appeal.contact_cs'),", 'onTap: () => this.config.customerService()']),
            ("'appeal_again'", ['CouliButton', "text: this.t('appeal.again'),", 'variant: CouliButtonVariant.SECONDARY,', 'fullWidth: true,',
                                'onTap: () => this.config.controller.submitAgain(this.config.controller.identity)']),
            ("'appeal_upheld_cs'", ['MeLink', "text: this.t('appeal.contact_cs'),", 'onTap: () => this.config.customerService()']),
            ("'appeal_delete_account'", ['MeLink', "text: this.t('settings.delete_account'),",
                                         'onTap: () => this.config.deleteAccount(this.config.controller.identity)']),
            ("'appeal_logout'", ['MeLink', "text: this.t('risk.logout'),", 'onTap: () => this.config.logout(this.config.controller.identity)']),
        ],
        'inside': [
            ('if (this.model.layout === AppealRules.SUBMIT) {', "'appeal_submit'"),
            ("if (this.liftedAction('go_wallet')) {", "'appeal_go_wallet'"),
            ("if (this.liftedAction('start')) {", "'appeal_start'"),
            ("if (this.liftedAction('view_messages')) {", "'appeal_view_messages'"),
            ("if (this.liftedAction('contact_cs')) {", "'appeal_lifted_cs'"),
            ('} else if (this.model.layout === AppealRules.RESULT_UPHELD) {', "'appeal_again'"),
            ('} else if (this.model.layout === AppealRules.RESULT_UPHELD) {', "'appeal_upheld_cs'"),
            ('} else if (this.model.layout === AppealRules.RESULT_UPHELD) {', "'appeal_logout'"),
            ('if (this.config.deleteAccountAvailable()) {', "'appeal_delete_account'"),
            ('if (this.model.fieldError.length > 0) {', ".id('appeal_field_error')"),
            ('if (this.model.message.length > 0) {', "'appeal_message'"),
            ('if (this.liftedNote().length > 0) {', "'appeal_lifted_note'"),
        ],
        # 出口行：注销 / 退出在 !frozen 条件块内（维持 · 冻结组只有客服，H-R09）。
        'inside_last': [('if (!this.model.frozen) {', "'appeal_delete_account'"), ('if (!this.model.frozen) {', "'appeal_logout'")],
        'callsets': [r'AppealCopy\.\w+', r'AppealRules\.\w+', r'RiskReasonText\.\w+'],
    },
}
# H-R06：title() 只许「SUBMIT → appeal.title，其余 → appeal.progress.title」。
TITLE_SQUASHED = ("privatetitle():string{if(this.model.layout===AppealRules.SUBMIT){returnthis.t('appeal.title');}"
                  "returnthis.t('appeal.progress.title');}")
# 「接下来可以」四个条目的源码顺序（R25 逐字原样：冻结句 → 再次申诉 → 客服 → 注销 / 退出）。
NEXT_ORDER = ['AppealCopy.upheldFrozenNext(this.model.frozen, this.model.riskState)', "this.t('appeal.next.frozen')",
              "this.t('appeal.result.next.resubmit')", "this.t('appeal.next.cs')",
              "this.config.deleteAccountAvailable() ? 'appeal.next.logout.with_deletion' : 'appeal.next.logout'"]

PARTS_STRUCTS = ['RiskHero', 'RiskInfoRow', 'RiskNoteStrip', 'RiskExitSep', 'AppealInfoCard', 'InlineRow', 'AppealTimeline', 'BulletCard']
PARTS_FUNCS = ['appealStateChipTone', 'appealStateChipIcon', 'riskRowChipTone', 'riskRowChipIcon', 'timelineStates']
# 私有件不得读 / 调的（只收渲染时的值与 @Event，§3.2）。
PARTS_FORBIDDEN = ['config', 'controller', 'Controller', 'AppMe', 'AppAccount', 'Router', 'openInApp', 'CouliToast', 'showToast',
                   'DeleteAccount', 'submit', 'setInput', 'logout', 'this.model', "from './RiskNoticeView'", "from './AppealView'",
                   'getUIContext().getRouter']
PARTS_SYMBOLS = ["sys.symbol.lock'", "sys.symbol.pause_circle'", "sys.symbol.clock'", "sys.symbol.checkmark_circle'",
                 "sys.symbol.exclamationmark_triangle'", "sys.symbol.info_circle'"]
# 红线：视图与私有件都不得出现（CT-26e 字段仍不读 H-R02；SLA 副文案不接 H-R05；视图不另起时间判定）。
RED_FORBIDDEN = ['can_resubmit', 'attempt_no', 'prev_risk_state', 'slaText', 'sla_text', 'showsDeadline', 'deadline', 'Deadline']
NEW_DIRECT = {'TextArea(': 1, 'Toggle(': 0, 'TextInput(': 0, '.bindSheet(': 0, 'showToast(': 0}
DEVICE_IDS = {
    V_RISK: ['risk_scroll', 'risk_title', 'risk_reason', 'risk_limit', 'risk_frozen_until', 'risk_appeal', 'risk_upheld', 'risk_withdrawal_',
             'risk_note', 'risk_retry', 'risk_back_home', 'risk_view_progress', 'risk_submit_appeal', 'risk_contact_cs', 'risk_delete_account',
             'risk_logout', 'risk_hero_icon', 'risk_info_card', 'risk_exits'],
    V_APPEAL: ['appeal_scroll', 'appeal_input', 'appeal_field_error', 'appeal_message', 'appeal_note', 'appeal_submit', 'appeal_progress_heading',
               'appeal_content', 'appeal_contact_cs', 'appeal_result_title', 'appeal_lifted_note', 'appeal_go_wallet', 'appeal_start',
               'appeal_view_messages', 'appeal_lifted_cs', 'appeal_upheld_title', 'appeal_again', 'appeal_upheld_cs', 'appeal_delete_account',
               'appeal_logout', 'appeal_retry', 'appeal_state_chip', 'appeal_badge_chip', 'appeal_passed_chip', 'appeal_timeline',
               'appeal_target_card', 'appeal_input_card', 'appeal_content_card', 'appeal_status_card', 'appeal_current_card', 'appeal_next_card',
               'appeal_result_icon', 'appeal_bar', 'appeal_exits'],
}
# 私有件视觉节点 id 后缀：<valueId>_row（信息行容器）、<valueId>_chip、<barId>_icon、appeal_timeline_<n>_line（tests-c-harmony-handback §3.2）。
PARTS_IDS = ["'_chip'", "'_icon'", "'_row'", "'_line'"]
STAGING_SCENES = ["'rv_banned'", "'rv_banned_appealing'", "'rv_banned_upheld'", "'rv_frozen'", "'rv_frozen_no_until'", "'rv_frozen_appealing'",
                  "'rv_frozen_upheld'", "'rv_submit_normal'", "'banned_lifted'", "'rv_lifted_history'"]
STAGING_COUNTERS = ["'me.appeal_submit_count'", "'me.appeal_last_body'", "'me.appeal_list_count'"]
STAGING_MARKERS = ["'50001'", "'42901'"]
SUITE = 'entry/src/ohosTest/ets/test/Me12wcUi.test.ets'
CASES = 'tools/ci/me12wc/fixtures/device-cases.txt'


# ---------------------------------------------------------------- 读取与抽取

def read(root, rel):
    p = root / rel
    return p.read_text(encoding='utf-8') if p.is_file() else ''


def sha(data):
    return hashlib.sha256(data).hexdigest()


def line_key(line):
    return sha(line.encode('utf-8'))[:16]


def strip_comments(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return re.sub(r'(?m)(^|[^:])//.*$', r'\1', text)


def squash(text):
    return re.sub(r'\s+', '', text)


def skipped(rel):
    parts = rel.split('/')
    return any(p in SKIP_PARTS for p in parts) or any(s in rel for s in TREE_SKIP)


def match_close(text, start, open_ch='{', close_ch='}'):
    """text[start] 是 open_ch；返回配对 close_ch 的下标（跳过字符串与行注释）。找不到为 -1。"""
    depth = 0
    i = start
    quote = None
    while i < len(text):
        c = text[i]
        if quote:
            if c == '\\':
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in '\'"`':
            quote = c
        elif text.startswith('//', i):
            nl = text.find('\n', i)
            i = len(text) if nl < 0 else nl
            continue
        elif c == open_ch:
            depth += 1
        elif c == close_ch:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def class_text(text, name):
    m = re.search(r'(?m)^(?:export\s+)?class\s+' + name + r'\b[^{]*\{', text)
    if not m:
        return None
    end = match_close(text, m.end() - 1)
    return None if end < 0 else text[m.start():end + 1]


def method_text(text, name):
    m = re.search(r'(?m)^[ \t]*(?:(?:private|public|protected|static|async)\s+)*' + re.escape(name) +
                  r'\s*\([^)]*\)\s*(?::\s*[^{;]+)?\{', text)
    if not m:
        return None
    end = match_close(text, m.end() - 1)
    return None if end < 0 else text[m.start():end + 1]


def struct_text(text, name):
    m = re.search(r'(?m)^(?:export\s+)?struct\s+' + name + r'\b[^{]*\{', text)
    if not m:
        return None
    end = match_close(text, m.end() - 1)
    return None if end < 0 else text[m.start():end + 1]


def func_text(text, name):
    m = re.search(r'(?m)^export\s+function\s+' + name + r'\s*\([^)]*\)\s*(?::\s*[^{;]+)?\{', text)
    if not m:
        return None
    end = match_close(text, m.end() - 1)
    return None if end < 0 else text[m.start():end + 1]


def guard_symbols(view, spec):
    out = {}
    for name in spec['classes']:
        out['class.' + name] = class_text(view, name)
    for name in spec['methods']:
        out['method.' + name] = method_text(view, name)
    return out


def swap_variants(text, swaps):
    """text 按 swaps（旧串 → 新串，各在 text 里出现恰好一次）的任意子集替换后的全部写法。"""
    out = set()
    for k in range(len(swaps) + 1):
        for subset in itertools.combinations(swaps, k):
            t = text
            for old, new in subset:
                t = t.replace(old, new, 1)
            out.add(t)
    return out


def owner_chunk(src, at):
    """下标 at 处字面量所在的组件调用（往前找最近的「大写开头名字({」，到配对的「)」）：(组件名, 调用全文)；找不到为 (None, '')。"""
    best = None
    for m in re.finditer(r'\b([A-Z]\w*)\s*\(\s*\{', src[:at]):
        end = match_close(src, m.end() - 2, '(', ')')
        if end > at:
            best = (m.group(1), src[m.start():end + 1])
    return best if best else (None, '')


def literal_owners(src, literal):
    return [owner_chunk(src, m.start()) for m in re.finditer(re.escape(literal), src)]


def blocks_of(src, line):
    """条件行（去缩进逐字节）后面那对花括号覆盖的 [起, 止] 列表。"""
    out = []
    for m in re.finditer(r'(?m)^[ \t]*' + re.escape(line) + r'[ \t]*$', src):
        brace = m.end() - 1
        while brace >= 0 and src[brace] != '{':
            brace -= 1
        end = match_close(src, brace)
        if end > 0:
            out.append((brace, end))
    return out


def inside_block(src, line, literal):
    blocks = blocks_of(src, line)
    hits = [m.start() for m in re.finditer(re.escape(literal), src)]
    return bool(hits) and bool(blocks) and all(any(a < h < b for a, b in blocks) for h in hits)


def load_fixture(root):
    p = root / FIXTURE
    if not p.is_file():
        return None, 'G0 fixture 缺失 ' + FIXTURE
    data = p.read_bytes()
    if sha(data) != FIXTURE_SHA256:
        return None, 'G0 fixture 被改 ' + FIXTURE + '（sha256 ' + sha(data)[:12] + ' ≠ 钉住的 ' + FIXTURE_SHA256[:12] + '）'
    return json.loads(data.decode('utf-8')), None


# ---------------------------------------------------------------- 检查

def check_logic(root, base):
    v = []
    for want, rel in base['strict']:
        p = root / rel
        if not p.is_file():
            v.append('G1 逻辑文件缺失 ' + rel)
        elif sha(p.read_bytes()) != want:
            v.append('G1 逻辑 / 边界文件被改 ' + rel + '（§3.1 合入前后 sha256 必须一致；红线①–⑥的执行器 / 接线 / 确认框都在这里）')
    tree = {rel: s for s, rel in base['tree']}
    exempt = set(base['tree_exempt']) | set(base['append_only'].keys()) | {rel for _, rel in base['strict']}
    for top in base['trees']:
        base_dir = root / top
        now = {}
        if base_dir.is_dir():
            for p in base_dir.rglob('*'):
                rel = p.relative_to(root).as_posix()
                if p.is_file() and not skipped(rel) and rel not in exempt:
                    now[rel] = sha(p.read_bytes())
        want = {rel: s for rel, s in tree.items() if rel.startswith(top + '/')}
        for rel in sorted(set(want) | set(now)):
            if want.get(rel) != now.get(rel):
                kind = '新增' if rel not in want else ('删除' if rel not in now else '改动')
                hint = {'features/me': '（H-R01：私有件只放 RiskAppealParts.ets，MeKit / 其余 features/me 文件不动）',
                        'common/designsystem': '（D10-600 / D10-615：DS 一字不动）',
                        'contracts': '（契约快照与锁不动）'}.get(top, '（§3.1 逻辑零改动）')
                v.append('G1 ' + top + ' 有' + kind + '：' + rel + hint)
    for rel, keys in sorted(base['append_only'].items()):
        now = [line_key(l) for l in read(root, rel).split('\n')]
        i = 0
        for k in now:
            if i < len(keys) and k == keys[i]:
                i += 1
        if i < len(keys):
            v.append('G2 ' + rel + ' 只许插入行：' + REV + ' 的第 %d 行被改 / 删 / 挪位' % (i + 1))
    return v


def check_guard(root, base):
    v = []
    for rel, spec in GUARD.items():
        view = read(root, rel)
        name = rel.rsplit('/', 1)[1]
        if not view:
            v.append('G4 缺 ' + rel)
            continue
        want = guard_symbols(base['views'][rel], spec)
        for sym, text in sorted(want.items()):
            if text is None:
                v.append('G0 fixture 里抽不到守卫符号 ' + name + ' ' + sym + '（抽取规则与基线不符）')
        now = guard_symbols(view, spec)
        for sym, text in sorted(want.items()):
            if text is None:
                continue
            allowed = swap_variants(text, KEY_SWAPS[rel].get(sym.split('.', 1)[1], []))
            if now.get(sym) not in allowed:
                v.append('G4 ' + name + ' 守卫区被改：' + sym + '（§3.2 与 ' + REV + ' 逐字节一致；只许 H-R03 清单里的键串替换）')
        flat = [line.strip() for line in view.split('\n')]
        for line in spec['lines']:
            if line not in flat:
                v.append('G4 ' + name + ' 分支条件被改（缺这一行：' + line + '）')
        clean = strip_comments(view)
        body = squash(clean)
        for call, n in spec['calls'].items():
            got = body.count(squash(call))
            if (n is None and got < 1) or (n is not None and got != n):
                v.append('G4 ' + name + ' 回调体 / 关键表达式被改或挪出视图：' + call + '（应 ' + ('≥1' if n is None else str(n)) +
                         ' 处，现 %d 处）' % got)
        for literal, needs in spec['owners']:
            owners = [o for o in literal_owners(clean, literal) if o[0] is not None]
            if not owners:
                v.append('G4 ' + name + ' 缺挂在控件上的 ' + literal)
            for comp, chunk in owners:
                flat_chunk = squash(chunk)
                for need in needs:
                    if need in ('CouliButton', 'MeLink'):
                        if comp != need:
                            v.append('G4 ' + name + ' ' + literal + ' 应仍挂在 ' + need + ' 上（§3.2 逐字原样），现在 ' + str(comp))
                    elif squash(need) not in flat_chunk:
                        v.append('G4 ' + name + ' ' + literal + ' 所在控件缺 ' + need + '（去向 / 动作与 id 配对被改）')
        for line, literal in spec['inside'] + spec.get('inside_last', []):
            if not inside_block(clean, line, literal):
                v.append('G4 ' + name + ' ' + literal + ' 不在条件块「' + line + '」之内（显示条件被绕开 / 改动）')
        for pattern in spec['callsets']:
            was = set(re.findall(pattern, strip_comments(base['views'][rel])))
            got = set(re.findall(pattern, clean))
            if was != got:
                v.append('G4 ' + name + ' 纯规则调用集合变了：' + pattern + ' 多 ' + str(sorted(got - was)) + ' 少 ' + str(sorted(was - got)) +
                         '（视图不另起判定，§3.2）')
    risk = strip_comments(read(root, V_RISK))
    no_cfg = risk.replace(class_text(risk, 'RiskNoticeConfig') or '', '')
    if re.search(r"['\"]frozen_until['\"]", risk) or re.search(r'Date\.now|\bnow\(\)', no_cfg):
        v.append('G4 RiskNoticeView 里出现 frozen_until / 当前时间（视图不比较期限与现在，§3.2 / 红线③）')
    appeal = strip_comments(read(root, V_APPEAL))
    title = method_text(appeal, 'title')
    if title is None or squash(title) != TITLE_SQUASHED:
        v.append('G4 AppealView.title() 只许「SUBMIT → appeal.title，其余 → appeal.progress.title」（H-R06 / G-R12）')
    at = [squash(appeal).find(squash(x)) for x in NEXT_ORDER]
    if any(i < 0 for i in at) or at != sorted(at):
        v.append('G4 AppealView「接下来可以」四个条件 / 键的顺序被改（冻结句 → 再次申诉 → 客服 → 注销 / 退出，R25）')
    return v


def check_static(root):
    v = []
    risk = strip_comments(read(root, V_RISK))
    appeal = strip_comments(read(root, V_APPEAL))
    parts = strip_comments(read(root, PARTS))
    views = risk + '\n' + appeal
    everything = views + '\n' + parts
    # S1 私有件（H-R01）：新文件、@ComponentV2、八个私有件、五个纯函数、只收值与 @Event、无中文 / 色值字面量。
    if not parts:
        v.append('S1 缺 ' + PARTS + '（H-R01：本组私有件放新文件，MeKit / DS 一字不动）')
    else:
        if '@ComponentV2' not in parts or re.search(r'@Component\b(?!V2)|@State\b|@Prop\b|@Link\b', parts):
            v.append('S1 RiskAppealParts 私有件须是 @ComponentV2（状态管理只用 V2）')
        for s in PARTS_STRUCTS:
            if not re.search(r'\bstruct\s+' + s + r'\b', parts):
                v.append('S1 RiskAppealParts 里没有 ' + s)
        for f in PARTS_FUNCS:
            if func_text(parts, f) is None:
                v.append('S1 RiskAppealParts 缺纯函数 export function ' + f + '（胶囊色 / 时间线步态映射，宿主与 run-logic 按取值表断言）')
        for bad in PARTS_FORBIDDEN:
            if bad in parts:
                v.append('S1 私有件读 / 调了 ' + bad + '（只收渲染时的值与 @Event 回调，§3.2）')
        if re.search(r"'[^'\n]*[一-鿿][^'\n]*'", parts) or re.search(r'"[^"\n]*[一-鿿][^"\n]*"', parts):
            v.append('S1 私有件写了中文字面量（HM-LINT-1：文案经字典取键，由页面传入）')
        if re.search(r"#[0-9A-Fa-f]{6,8}\b|\brgba?\(|Color\.(?!Transparent\b)[A-Z]\w*", parts):
            v.append('S1 私有件写了色值字面量（颜色一律取 CouliColors 令牌）')
        tone = func_text(parts, 'appealStateChipTone') or ''
        if re.search(r'this\.|config|controller|layout|model', tone):
            v.append('S1 胶囊色映射 appealStateChipTone 只许读参数 riskState（§3.2：只读 this.model.riskState 的值）')
    # S2 账号状态（R1 / R2 / R3 / R6 / R32）。
    if risk.count('RiskHero(') != 1 or 'CouliIcon(' in risk or 'CouliTypography.heading' in risk:
        v.append('S2 账号状态头部应是私有 RiskHero（Symbol 32、标题 22/600，R2），不再是 CouliIcon 48 / heading 28')
    hero = struct_text(parts, 'RiskHero') or ''
    for need in ['SymbolGlyph(', 'CouliTypography.title', 'AccessibilityRoleType.TITLE_BAR', "accessibilityLevel('no')", '96']:
        if need not in hero:
            v.append('S2 RiskHero 缺 ' + need + '（图标块 96、Symbol 读屏不读、标题 22 + 标题角色，R2）')
    if 'MeKeyValue(' in risk or risk.count('RiskInfoRow(') != 1:
        v.append('S2 信息卡行应是私有 RiskInfoRow（14 / 14-500 右对齐、min 48，R3），不再是 MeKeyValue')
    row = struct_text(parts, 'RiskInfoRow') or ''
    for need in ['CouliTypography.footnote', 'TextAlign.End', 'flexShrink(1)', 'accessibilityGroup(true)', 'minTouchTarget', 'CouliChip(']:
        if need not in row:
            v.append('S2 RiskInfoRow 缺 ' + need + '（R3 / R4：14 号、值右对齐可折行、整行读一次、min 48、胶囊用 DS CouliChip）')
    if risk.count('RiskNoteStrip(') != 1 or risk.count('MeNoticeBar(') != 1:
        v.append('S2 提示条应是 RiskNoteStrip（info 20，R6）；MeNoticeBar 只留提现错误条一处')
    if 'riskRowChipTone(row[2])' not in squash(risk) or 'riskRowChipIcon(row[2])' not in squash(risk):
        v.append('S2 申诉行胶囊按 row[2] 的 id 选件（riskRowChipTone(row[2]) / riskRowChipIcon(row[2])，R4：不改 detailRows）')
    if 'CouliSpacing.space6' not in (method_text(risk, 'content') or ''):
        v.append('S2 账号状态内容块间应为 24（content 外包 Column space6，R1）')
    # S3 出口行（R8 / F-HM-74 ③）：分隔符私有 RiskExitSep，与后一个链接同组（Row 里先分隔、后链接）。
    for rel, text in [(V_RISK, risk), (V_APPEAL, appeal)]:
        name = rel.rsplit('/', 1)[1]
        if "Text('|')" in text:
            v.append('S3 ' + name + ' 出口分隔符仍是独立的 Text(\'|\')（F-HM-74 ③：200% 折行时挂在行尾）')
        seps = [m.start() for m in re.finditer(r'RiskExitSep\(', text)]
        if len(seps) != 2:
            v.append('S3 ' + name + ' 出口行应有 2 个 RiskExitSep（注销前、退出前各一），现 %d 个' % len(seps))
        for at in seps:
            rows = [m for m in re.finditer(r'\bRow\(\)\s*\{', text[:at])]
            grouped = False
            for m in rows:
                end = match_close(text, m.end() - 1)
                if end > at:
                    block = text[m.end():end]
                    grouped = block.count('MeLink(') == 1 and block.find('RiskExitSep(') < block.find('MeLink(')
            if not grouped:
                v.append('S3 ' + name + ' 出口分隔符没有和后一个链接同组（Row { RiskExitSep() MeLink(…) }，F-HM-74 ③）')
                break
    sep = struct_text(parts, 'RiskExitSep') or ''
    if "Text('|')" not in sep or "accessibilityLevel('no')" not in sep:
        v.append('S3 RiskExitSep 应是读屏不读的 Text(\'|\')')
    # S4 申诉（R12–R27）。
    if 'MeKeyValue(' in appeal or appeal.count('AppealInfoCard(') < 3 or 'InlineRow(' not in appeal:
        v.append('S4 申诉卡应是 AppealInfoCard（卡内标题 17/600）+ InlineRow（R12 / R18 / R24），不再是卡外 caption + MeKeyValue')
    card = struct_text(parts, 'AppealInfoCard') or ''
    if 'AccessibilityRoleType.TITLE_BAR' not in card or 'CouliTypography.body' not in card:
        v.append('S4 AppealInfoCard 卡内标题 body 17/600 + 标题角色（R12）')
    flat_appeal = squash(appeal)
    for need, what in [("placeholder:this.t('appeal.placeholder')", '占位 appeal.placeholder（R13 / H-R04）'),
                       ('.placeholderColor(CouliColors.textSecondary)', '占位次文字色'), ('minHeight:160', '输入框 min 160'),
                       ('left:12', '内边距 8/12')]:
        if need not in flat_appeal:
            v.append('S4 申诉输入框缺 ' + what)
    if 'minHeight:120' in flat_appeal:
        v.append('S4 申诉输入框仍是 min 120（R13：160）')
    if appeal.count('RiskNoteStrip(') != 2 or appeal.count('MeNoticeBar(') != 1:
        v.append('S4 申诉提示条（appeal_note / appeal_lifted_note）应是 RiskNoteStrip；MeNoticeBar 只留 appeal_message 错误条')
    footer = method_text(appeal, 'footer') or ''
    if 'CouliColors.backgroundSurface' not in footer or 'CouliColors.borderSubtle' not in footer or "'appeal_bar'" not in footer:
        v.append('S4 申诉底栏应是白底 + 上沿 1px border.subtle（appeal_bar，R15 / R27）')
    if 'CouliChipTone.OUTLINE' in appeal:
        v.append('S4 处理中 / 已处理胶囊仍是 OUTLINE（R16 / R22：MUTED + 时钟 / WARNING + 三角，在白卡内）')
    for need, what in [("tone:CouliChipTone.MUTED,icon:'clock'", '处理中胶囊 MUTED + clock（R16）'),
                       ("tone:CouliChipTone.WARNING,icon:'alert'", '已处理胶囊 WARNING + alert（R22）'),
                       ("CouliChipTone.SUCCESS", '已通过结论胶囊 SUCCESS（R20）'),
                       ('appealStateChipTone(this.model.riskState)', '当前状态胶囊按 riskState（R12 / R24）'),
                       ('appealStateChipIcon(this.model.riskState)', '当前状态胶囊图标按 riskState')]:
        if need not in flat_appeal:
            v.append('S4 申诉页缺 ' + what)
    for fn in ['appealStateChipTone', 'appealStateChipIcon']:
        args = re.findall(fn + r'\(([^)]*)\)', appeal)
        if not args or any(a.strip() != 'this.model.riskState' for a in args):
            v.append('S4 ' + fn + ' 只许以 this.model.riskState 调用（§3.2：胶囊色只读本次 getMe 的 riskState，不读版式 / 推断），现 ' + str(args))
    if appeal.count('CouliTypography.heading') > 0 or appeal.count('CouliTypography.title') < 2:
        v.append('S4 申诉状态卡标题应为 title 22/600（R16 / R20 / R22），不再是 heading 28')
    if 'AppealTimeline(' not in appeal or 'Circle(' in appeal or 'timelineStates(' not in appeal:
        v.append('S4 时间线应是私有 AppealTimeline（图标列 20、连线撑满，R17），步态取 timelineStates(…)')
    if 'BulletCard(' not in appeal or 'CouliColors.backgroundMuted' in appeal:
        v.append('S4 「接下来可以」应是白卡 BulletCard（R25），不再是 muted 圆角块')
    if 'RiskHero(' not in (method_text(appeal, 'liftedPage') or ''):
        v.append('S4 已解除结果头部应有 RiskHero 图标块（success + 圆勾，R20 / H-R22 推荐：只按版式显示）')
    if squash(appeal).count(squash("this.t('appeal.closed_at')")) < 2:
        v.append('S4 维持状态卡缺「处理时间」行（R22）')
    # S5 草稿键（H-R03 / H-R04）：退役键不再被视图取用；新键齐全；MeDraftTexts 插入三行原文。
    for rel, text in [(V_RISK, risk), (V_APPEAL, appeal)]:
        name = rel.rsplit('/', 1)[1]
        for key in RETIRED_KEYS:
            if key in text:
                v.append('S5 ' + name + ' 仍取草稿键 ' + key + '（H-R03 推荐改取契约定稿键 / H-R04 三端同键）')
        for key in NEW_KEYS[rel]:
            if key not in text:
                v.append('S5 ' + name + ' 没取用 ' + key + '（H-R03 / H-R04）')
    draft = read(root, DRAFT)
    for line in DRAFT_LINES:
        if draft.count(line) != 1:
            v.append('S5 MeDraftTexts 缺（或重复）插入行 ' + line + '（H-R04，值 = 夹具 drafts 逐字）')
    # S6 红线静态（S0）：视图无点击 / 手势（申诉行不是入口、提现行不可点、说明句不可点）；不读 CT-26e；不接 SLA；不比较时间。
    for token in ['.onClick(', '.gesture(', 'TapGesture', '.bindPopup(', '.onTouch(']:
        if token in everything:
            v.append('S6 视图 / 私有件里出现 ' + token + '（红线⑥：行与胶囊不是入口，点击只经组件 onTap）')
    for bad in RED_FORBIDDEN:
        if bad in everything:
            v.append('S6 出现 ' + bad + '（H-R02：CT-26e 字段仍不读 / H-R05：SLA 副文案本单不接 / 红线③不显示时限）')
    if re.search(r'Date\.now|\bnow\(\)', parts):
        v.append('S6 私有件读当前时间（不推算、不显示处理时限，红线③）')
    # S7 新功能图标用 HarmonyOS Symbol（H-R13）。
    for sym in PARTS_SYMBOLS:
        if sym not in parts:
            v.append("S7 私有件缺 SymbolGlyph($r('" + sym[:-1] + "'))（H-R13 / D10-559）")
    # S8 不新增系统控件直用（DS-02 G1 警告持平；TextArea 只允许申诉输入那一处，H-R10）。
    for token, limit in NEW_DIRECT.items():
        n = len(re.findall(re.escape(token) if token.startswith('.') else r'(?<!\w)' + re.escape(token), everything))
        if n > limit:
            v.append('S8 ' + token + ' 直用 %d 处（> %d：DS-02 G1 持平）' % (n, limit))
    # S9 设备用例依赖的 id。
    for rel, ids in DEVICE_IDS.items():
        src = strip_comments(read(root, rel))
        for did in ids:
            if "'" + did + "'" not in src and "'" + did not in src:
                v.append('S9 缺设备用例依赖的 id ' + did)
    for did in PARTS_IDS:
        if did not in parts:
            v.append('S9 私有件缺视觉节点 id 后缀 ' + did + '（<valueId>_row / _chip、<id>_icon、时间线 _line）')
    # S10 staging：H-R15 场景、提交正文标记与提交 / 列表计数键（只插入行，G2 守）。
    fake = strip_comments(read(root, FAKE_ME))
    for scene in STAGING_SCENES:
        if scene not in fake:
            v.append('S10 DebugFakeMe 缺场景 ' + scene + '（H-R15）')
    for key in STAGING_COUNTERS:
        if key not in fake:
            v.append('S10 DebugFakeMe 缺计数键 ' + key + '（设备红线①②按它数提交与列表请求）')
    for mark in STAGING_MARKERS:
        if mark not in fake:
            v.append('S10 DebugFakeMe 缺提交正文标记 ' + mark + '（H-R15：50001 带 trace、42901 带 Retry-After）')
    if "startsWith('rv_banned')" not in squash(fake) and "'rv_banned'" in fake:
        v.append("S10 DebugFakeMe rv_banned* 场景的钱包摘要要回 10006（插入 startsWith('rv_banned') 分支；经真实网络层置 enteredBy10006）")
    # S12 窗口键盘避让（测试 v5，D10-633 (a)）：只在申诉页显示期间 RESIZE、隐藏即还原；设 / 还原跟随页面显示 / 隐藏回调，
    # 不在 onDidBuild / aboutToDisappear / aboutToAppear 这种「页面存在期」上设或还原（会带到上层页）。
    v += check_avoid(appeal, risk)
    # S11 risk-appeal-visual-vectors.json 三端同一份（H-R14）。
    p = root / VECTORS
    if not p.is_file() or sha(p.read_bytes()) != VECTORS_SHA256:
        v.append('S11 ' + VECTORS + ' 与 Android 不是逐字节同一份（H-R14：鸿蒙差异在测试里映射，不改文件）')
    return v


AVOID_LIFECYCLE = ['onDidBuild', 'aboutToDisappear', 'aboutToAppear', 'aboutToReuse', 'aboutToRecycle']
AVOID_HOOKS = [("'navDestinationUpdate'", 'NavDestinationState.ON_SHOWN', 'NavDestinationState.ON_HIDDEN')]


def strip_lambdas(text):
    """去掉 `=> {…}` 箭头函数体（注册的回调是延后执行的，不算生命周期方法体本身）。"""
    out = text
    while True:
        m = re.search(r'=>\s*\{', out)
        if not m:
            return out
        end = match_close(out, m.end() - 1)
        if end < 0:
            return out
        out = out[:m.start()] + '=> CALLBACK' + out[end + 1:]


def check_avoid(appeal, risk):
    v = []
    if 'setKeyboardAvoidMode(' in risk:
        v.append('S12 RiskNoticeView 不应改窗口键盘避让（本单只允许申诉页，D10-633）')
    calls = len(re.findall(r'setKeyboardAvoidMode\(', appeal))
    if calls == 0:
        v.append('S12 AppealView 缺键盘避让（H-R21 / D10-633：本页显示期间 RESIZE、隐藏即还原）')
        return v
    if 'setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE)' not in squash(appeal):
        v.append('S12 AppealView 没有在显示时设 KeyboardAvoidMode.RESIZE')
    restores = [m for m in re.findall(r'setKeyboardAvoidMode\(([^)]*)\)', appeal) if squash(m) != 'KeyboardAvoidMode.RESIZE']
    if not restores:
        v.append('S12 AppealView 页面隐藏时没有还原键盘避让（只设不还原会带到上层页，D10-633）')
    helpers = set()
    for m in re.finditer(r'(?m)^[ \t]*(?:(?:private|public|protected)\s+)*(\w+)\s*\([^)]*\)\s*(?::\s*[^{;]+)?\{', appeal):
        body = method_text(appeal, m.group(1)) or ''
        if 'setKeyboardAvoidMode(' in body and m.group(1) not in AVOID_LIFECYCLE:
            helpers.add(m.group(1))
    for name in AVOID_LIFECYCLE:
        body = method_text(appeal, name)
        if body is None:
            continue
        flat = strip_lambdas(body)
        if 'setKeyboardAvoidMode(' in flat or any(re.search(r'this\.' + h + r'\s*\(', flat) for h in helpers):
            v.append('S12 AppealView.' + name + ' 里设 / 还原了窗口键盘避让（D10-633：必须跟随页面显示 / 隐藏，不在页面存在期上设）')
    if not any(all(tok in appeal for tok in hook) for hook in AVOID_HOOKS):
        v.append("S12 AppealView 缺页面显示 / 隐藏挂钩（UIObserver 'navDestinationUpdate' + NavDestinationState.ON_SHOWN / ON_HIDDEN）")
    return v


def check_registration(root):
    v = []
    suite = read(root, SUITE)
    listed = re.findall(r"'(me12wc_\d\d_[a-z0-9_]+)'", suite.split('];')[0]) if suite else []
    its = len(re.findall(r'\bit\(ME12WC_DEVICE_CASES\[\d+\]', suite))
    fixture = [l.strip() for l in read(root, CASES).splitlines() if l.strip() and not l.startswith('#')]
    if not listed or listed != fixture or len(set(listed)) != len(listed) or its != len(listed):
        v.append('C1 设备名单三处不一致（ME12WC_DEVICE_CASES / device-cases.txt / it 数）')
    if "describe('Me12wcUi'" not in suite:
        v.append('C1 describe 名必须是 Me12wcUi（verify 按 class 过滤）')
    verify = read(root, 'tools/ci/verify.sh')
    tails = [line.split()[-3:] for line in verify.splitlines() if line.strip().startswith('run_device_tests entry ')]
    main_ok = any(t[0] == 'entry' and t[2] == 'main' and t[1].startswith('notClass=') and 'Me12wcUi' in t[1].split('=', 1)[1].split(',')
                  for t in tails)
    if not main_ok:
        v.append('C2 verify 主 entry 步必须排除 Me12wcUi')
    if ['entry-me12wc', 'class=Me12wcUi', 'me12wc'] not in tails:
        v.append('C2 verify 缺单独设备步 entry-me12wc class=Me12wcUi me12wc')
    for cmd in ['me12wc/check_risk_visual.py" --self-test', 'me12wc/check_risk_visual.py" ||', 'me12wc/run-logic.cjs"',
                'me12wc/check-arkts.cjs" --real']:
        if cmd not in verify:
            v.append('C2 verify 缺 APP-12w-c 宿主检查步命令：' + cmd)
    a, b = verify.find('me12wb/check-arkts.cjs" --real'), verify.find('me12wc/check_risk_visual.py" --self-test')
    if a < 0 or b < 0 or b < a:
        v.append('C2 APP-12w-c 宿主检查步应排在 me12wb 宿主步之后')
    if 'me12wc/fixtures/device-cases.txt' not in read(root, 'tools/ci/ds02/check_device_result.py'):
        v.append('C2 check_device_result.py 缺 me12wc 名单')
    if not re.search(r'main\|hm07va\|hm07vb\|hm05r\|(?:[a-z0-9]+\|)*me12wc\|(?:[a-z0-9]+\|)*all\)', read(root, 'tools/ci/device-test.sh')):
        v.append('C2 device-test.sh 不认 COULI_HM_DEVICE_SET=me12wc')
    if not re.search(r'^\s*me12wcRiskTest\(\);', strip_comments(read(root, 'common/core/src/test/List.test.ets')), flags=re.M):
        v.append('C3 core List.test.ets 未登记 me12wcRiskTest()')
    entry_list = strip_comments(read(root, 'entry/src/ohosTest/ets/test/List.test.ets'))
    a, b = entry_list.find('me12wcUiTest();'), entry_list.find('hm07vHomeUiTest();')
    if a < 0 or b < 0 or a > b:
        v.append('C3 entry List.test.ets 须登记 me12wcUiTest()，且在 hm07vHomeUiTest() 之前（HM-07v-a C3 最后注册）')
    return v


def check_source(root, base=None):
    v = []
    if base is None:
        base, err = load_fixture(root)
        if err:
            v.append(err)
    if base is not None:
        v += check_logic(root, base)
        v += check_guard(root, base)
    v += check_static(root)
    v += check_registration(root)
    return v


# ---------------------------------------------------------------- 自测：参考实现（REV 原文按 §3.2「允许改」打补丁；只给静态检查用，不可编译）

def replace_method(text, name, new):
    old = method_text(text, name)
    if old is None or text.count(old) != 1:
        raise SystemExit('ME12WC_SELF_TEST_FAIL 参考实现找不到方法 ' + name)
    return text.replace(old, new)


def patch(text, old, new, n=1):
    if text.count(old) != n:
        raise SystemExit('ME12WC_SELF_TEST_FAIL 参考实现补丁定位串次数不对：' + old[:80])
    return text.replace(old, new)


REF_RISK_IMPORT = ("import { DraftMeTexts, MeCard, MeKeyValue, MeLink, MeNoticeBar, MePageFrame, MeTexts } from './MeKit';\n",
                   "import { DraftMeTexts, MeCard, MeLink, MeNoticeBar, MePageFrame, MeTexts } from './MeKit';\n"
                   "import { RiskExitSep, RiskHero, RiskInfoRow, RiskNoteStrip, riskRowChipIcon, riskRowChipTone } from './RiskAppealParts';\n")
REF_RISK_HERO = """  hero() {
    RiskHero({
      symbol: this.layout() === RiskLayout.NORMAL ? 'clock' : this.banned() ? 'lock' : 'pause_circle',
      title: this.t(this.layout() === RiskLayout.NORMAL ? 'risk.normal.title' :
        this.banned() ? 'risk.banned.title' : 'risk.frozen.title'),
      desc: this.layout() === RiskLayout.NORMAL ? '' : this.t(this.banned() ?
        (this.config.deleteAccountAvailable() ? 'risk.banned.desc' : 'risk.banned.desc.no_deletion') : 'risk.frozen.desc'),
      iconId: 'risk_hero_icon',
      titleId: 'risk_title'
    })
  }"""
REF_RISK_DETAILS = """  details() {
    ForEach(this.detailRows(), (row: string[], index: number) => {
      RiskInfoRow({ label: row[0], value: row[1], valueId: row[2], divider: index < this.detailRows().length - 1,
        chipTone: riskRowChipTone(row[2]), chipIcon: riskRowChipIcon(row[2]) })
    }, (row: string[]) => row[2] + '_' + row[1] + '_' + this.model.version)
  }"""
REF_RISK_CONTENT = """  content() {
    if (this.model.phase === MePhase.ERROR) {
      ErrorState({
        title: this.model.errorText,
        retryText: this.t('me.retry'),
        retryId: 'risk_retry',
        retryDisabled: this.model.blocked,
        onRetry: () => {
          this.config.controller.retry();
        }
      })
    } else if (this.model.view !== null) {
      Column({ space: CouliSpacing.space6 }) {
        this.hero()
        if (this.layout() !== RiskLayout.NORMAL) {
          MeCard({
            cardId: 'risk_info_card',
            content: () => {
              this.details()
            }
          })
          if (this.model.withdrawalsError.length > 0) {
            MeNoticeBar({
              text: this.t('risk.withdrawals') + PriceTerms.comma + this.model.withdrawalsError + '\\n' + this.t('me.retry'),
              tone: 'error',
              barId: 'risk_withdrawals_error',
              tappable: !this.model.blocked,
              onTap: () => {
                this.config.controller.retryWithdrawals();
              }
            })
          }
          RiskNoteStrip({ text: this.t(this.noteKey()), barId: 'risk_note' })
        }
      }
      .width('100%')
      .padding({ top: CouliSpacing.space4 })
    } else {
      Column() {
        LoadingProgress().width(40).height(40).color(CouliColors.textSecondary)
      }
      .width('100%')
      .padding({ top: CouliSpacing.space12 })
    }
  }"""
REF_RISK_EXITS_OLD = """          MeLink({ text: this.t('risk.contact_cs'), linkId: 'risk_contact_cs', onTap: () => this.config.customerService() })
          Text('|')
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.borderSubtle))
            .accessibilityLevel('no')
          // 控制器与它的身份在打开页面时固定（readonly），不读可观察状态（APP-09 第 63 条）。
          if (this.config.deleteAccountAvailable()) {
            MeLink({ text: this.t('settings.delete_account'), linkId: 'risk_delete_account',
              onTap: () => this.config.deleteAccount(this.config.controller.identity) })
            Text('|')
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.borderSubtle))
              .accessibilityLevel('no')
          }
          MeLink({ text: this.t('risk.logout'), linkId: 'risk_logout',
            onTap: () => this.config.logout(this.config.controller.identity) })
        }
        .width('100%')
"""
REF_RISK_EXITS_NEW = """          MeLink({ text: this.t('risk.contact_cs'), linkId: 'risk_contact_cs', onTap: () => this.config.customerService() })
          if (this.config.deleteAccountAvailable()) {
            Row() {
              RiskExitSep()
              MeLink({ text: this.t('settings.delete_account'), linkId: 'risk_delete_account',
                onTap: () => this.config.deleteAccount(this.config.controller.identity) })
            }
          }
          Row() {
            RiskExitSep()
            MeLink({ text: this.t('risk.logout'), linkId: 'risk_logout',
              onTap: () => this.config.logout(this.config.controller.identity) })
          }
        }
        .width('100%')
        .id('risk_exits')
"""

REF_APPEAL_IMPORT = ("import { Bound, DraftMeTexts, MeCard, MeKeyValue, MeLink, MeNoticeBar, MePageFrame, MeTexts } from './MeKit';\n",
                     "import { Bound, DraftMeTexts, MeCard, MeLink, MeNoticeBar, MePageFrame, MeTexts } from './MeKit';\n"
                     "import { AppealInfoCard, AppealTimeline, appealStateChipIcon, appealStateChipTone, BulletCard, InlineRow, RiskExitSep, "
                     "RiskHero, RiskNoteStrip, timelineStates } from './RiskAppealParts';\n")
REF_APPEAL = {
    'targetCard': """  targetCard() {
    InlineRow({ label: this.t('appeal.type'), value: this.t('appeal.type.account') })
    if (this.model.currentStateKey !== null) {
      InlineRow({ label: this.t('appeal.current_state'), value: this.t(this.model.currentStateKey as string),
        chipTone: appealStateChipTone(this.model.riskState), chipIcon: appealStateChipIcon(this.model.riskState),
        chipId: 'appeal_state_chip' })
    }
    if (this.reasonText() !== null) {
      InlineRow({ label: this.t('appeal.reason'), value: this.reasonText() as string })
    }
    if (this.frozenUntilText() !== null) {
      InlineRow({ label: this.t('appeal.frozen_until'), value: this.frozenUntilText() as string })
    }
  }""",
    'submitPage': """  submitPage(bound: Bound) {
    AppealInfoCard({
      title: this.t('appeal.target'),
      cardId: 'appeal_target_card',
      content: () => {
        this.targetCard()
      }
    })
    AppealInfoCard({
      title: this.t('appeal.content_label'),
      cardId: 'appeal_input_card',
      content: () => {
        TextArea({ text: this.model.input, placeholder: this.t('appeal.placeholder') })
          .id('appeal_input')
          .width('100%')
          .constraintSize({ minHeight: 160 })
          .padding({ top: 8, bottom: 8, left: 12, right: 12 })
          .fontSize(CouliTypography.body.fontSize)
          .placeholderColor(CouliColors.textSecondary)
          .backgroundColor(CouliColors.backgroundSurface)
          .borderRadius(12)
          .border({ width: 1, color: this.model.fieldError.length > 0 ? CouliColors.statusErrorText :
            CouliColors.borderControl })
          .accessibilityText(this.t('appeal.content_label'))
          .accessibilityDescription(this.model.fieldError)
          .onChange((value: string) => {
            this.config.controller.setInput(value, bound.identity);
          })
        if (this.model.fieldError.length > 0) {
          Text(this.model.fieldError)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText))
            .id('appeal_field_error')
            .focusable(true)
            .focusBox(CouliFocus.box)
        }
      }
    })
    if (this.model.message.length > 0) {
      MeNoticeBar({ text: this.model.message, tone: 'error', barId: 'appeal_message', focusTarget: true })
    }
    RiskNoteStrip({ text: this.t(AppealCopy.submitNote(this.model.frozen, this.model.riskState)), barId: 'appeal_note' })
  }""",
    'contentCard': """  contentCard() {
    InlineRow({ label: this.t('appeal.type'), value: this.t('appeal.type.account') })
    if (this.reasonText() !== null) {
      InlineRow({ label: this.t('appeal.reason'), value: this.reasonText() as string })
    }
    InlineRow({ label: this.t('appeal.content'), value: this.str(this.model.latest, 'content') ?? '', valueId: 'appeal_content' })
  }""",
    'timelineCard': """  timelineCard(resultText: string, upheld: boolean) {
    AppealTimeline({
      timelineId: 'appeal_timeline',
      titles: [this.t('appeal.timeline.submitted'), this.t('appeal.timeline.processing'), this.t('appeal.timeline.result')],
      descs: [this.time('created_at'), this.processingDesc(), resultText],
      states: timelineStates(upheld)
    })
  }""",
    'progressPage': """  progressPage() {
    MeCard({
      cardId: 'appeal_status_card',
      vertical: CouliSpacing.space4,
      content: () => {
        Column({ space: CouliSpacing.space2 }) {
          CouliChip({ label: this.t('appeal.progress.badge'), tone: CouliChipTone.MUTED, icon: 'clock' })
            .id('appeal_badge_chip')
          Text(this.t('appeal.progress.heading'))
            .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary, CouliFontWeight.semibold))
            .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
            .id('appeal_progress_heading')
          Text(this.v('appeal.progress.desc.banned', 'appeal.progress.desc.frozen'))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
    })
    MeCard({
      content: () => {
        this.timelineCard(this.v('appeal.timeline.result_pending.banned', 'appeal.timeline.result_pending.frozen'), false)
      }
    })
    AppealInfoCard({
      title: this.t('appeal.content_section'),
      cardId: 'appeal_content_card',
      content: () => {
        this.contentCard()
      }
    })
    Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center, justifyContent: FlexAlign.Center }) {
      Text(this.t('appeal.footer'))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
      MeLink({ text: this.t('appeal.contact_cs'), linkId: 'appeal_contact_cs', onTap: () => this.config.customerService() })
    }
    .width('100%')
  }""",
    'liftedPage': """  liftedPage() {
    RiskHero({
      symbol: 'checkmark_circle',
      tone: 'success',
      title: this.t(AppealCopy.liftedTitle(this.model.frozen, this.model.riskState)),
      desc: this.t(AppealCopy.liftedDesc(this.model.riskState)),
      iconId: 'appeal_result_icon',
      titleId: 'appeal_result_title'
    })
    MeCard({
      content: () => {
        this.liftedCard()
      }
    })
    if (this.liftedNote().length > 0) {
      RiskNoteStrip({ text: this.liftedNote(), barId: 'appeal_lifted_note' })
    }
  }""",
    'liftedCard': """  liftedCard() {
    InlineRow({ label: this.t('appeal.conclusion'), value: this.t('appeal.passed'), chipTone: CouliChipTone.SUCCESS, chipIcon: 'check',
      chipId: 'appeal_passed_chip' })
    InlineRow({ label: this.t('appeal.closed_at'), value: this.time('closed_at') })
    if (this.model.frozen && this.model.withdrawStateKey !== null) {
      InlineRow({ label: this.t('appeal.withdraw'), value: this.t(this.model.withdrawStateKey as string) })
    } else if (!this.model.frozen && this.model.currentStateKey !== null) {
      InlineRow({ label: this.t('appeal.account_state'), value: this.t(this.model.currentStateKey as string) })
    }
  }""",
    'upheldStateCard': """  upheldStateCard() {
    if (this.model.currentStateKey !== null) {
      InlineRow({
        label: this.model.frozen ? this.t('appeal.withdraw') : this.t('appeal.state'),
        value: this.t((this.model.frozen ? this.model.withdrawStateKey : this.model.currentStateKey) as string),
        chipTone: appealStateChipTone(this.model.riskState),
        chipIcon: appealStateChipIcon(this.model.riskState),
        chipId: 'appeal_state_chip'
      })
    }
    if (this.reasonText() !== null) {
      InlineRow({ label: this.t('appeal.reason'), value: this.reasonText() as string })
    }
    if (this.model.currentBanned) {
      InlineRow({ label: this.t('risk.limit'), value: this.t('risk_notice.period_none') })
    } else if (this.frozenUntilText() !== null) {
      InlineRow({ label: this.t('appeal.frozen_until'), value: this.frozenUntilText() as string })
    }
  }""",
    'upheldPage': """  upheldPage() {
    MeCard({
      cardId: 'appeal_status_card',
      vertical: CouliSpacing.space4,
      content: () => {
        Column({ space: CouliSpacing.space2 }) {
          CouliChip({ label: this.t('appeal.upheld.badge'), tone: CouliChipTone.WARNING, icon: 'alert' })
            .id('appeal_badge_chip')
          Text(this.t('appeal.upheld.title'))
            .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary, CouliFontWeight.semibold))
            .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
            .id('appeal_upheld_title')
          Text(this.t('appeal.upheld.desc'))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          InlineRow({ label: this.t('appeal.closed_at'), value: this.time('closed_at') })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
    })
    MeCard({
      content: () => {
        this.timelineCard(this.config.texts.format('appeal.upheld.result_line',
          this.timeVars(this.time('closed_at'))), true)
      }
    })
    AppealInfoCard({
      title: this.t(this.model.frozen ? 'appeal.current_frozen_state' : 'appeal.current_account_state'),
      cardId: 'appeal_current_card',
      content: () => {
        this.upheldStateCard()
      }
    })
    BulletCard({ title: this.t('appeal.next'), cardId: 'appeal_next_card', lines: this.nextLines() })
    AppealInfoCard({
      title: this.t('appeal.content_section'),
      cardId: 'appeal_content_card',
      content: () => {
        this.contentCard()
      }
    })
  }

  private nextLines(): string[] {
    const lines: string[] = [];
    if (AppealCopy.upheldFrozenNext(this.model.frozen, this.model.riskState)) {
      lines.push(this.t('appeal.next.frozen'));
    }
    lines.push(this.t('appeal.result.next.resubmit'));
    lines.push(this.t('appeal.next.cs'));
    if (!this.model.frozen) {
      lines.push(this.t(this.config.deleteAccountAvailable() ? 'appeal.next.logout.with_deletion' : 'appeal.next.logout'));
    }
    return lines;
  }""",
    'footer': """  footer() {
    if (this.model.phase === MePhase.CONTENT) {
      Column({ space: CouliSpacing.space2 }) {
        if (this.model.layout === AppealRules.SUBMIT) {
          CouliButton({
            text: this.t('appeal.submit'),
            fullWidth: true,
            loading: this.model.submitting,
            disabled: !this.model.submitEnabled || this.model.blocked,
            buttonId: 'appeal_submit',
            onTap: () => {
              this.config.controller.submit(this.config.controller.identity);
            }
          })
        } else if (this.model.layout === AppealRules.RESULT_LIFTED) {
          if (this.liftedAction('go_wallet')) {
            CouliButton({
              text: this.t('appeal.go_wallet'),
              fullWidth: true,
              buttonId: 'appeal_go_wallet',
              onTap: () => this.config.open('Wallet', {})
            })
          }
          if (this.liftedAction('start')) {
            CouliButton({
              text: this.t('appeal.start'),
              fullWidth: true,
              buttonId: 'appeal_start',
              onTap: () => this.config.home()
            })
          }
          if (this.liftedAction('view_messages')) {
            MeLink({ text: this.t('appeal.view_messages'), linkId: 'appeal_view_messages',
              onTap: () => this.config.open('Messages', {}) })
          }
          if (this.liftedAction('contact_cs')) {
            MeLink({ text: this.t('appeal.contact_cs'), linkId: 'appeal_lifted_cs',
              onTap: () => this.config.customerService() })
          }
        } else if (this.model.layout === AppealRules.RESULT_UPHELD) {
          CouliButton({
            text: this.t('appeal.again'),
            variant: CouliButtonVariant.SECONDARY,
            fullWidth: true,
            buttonId: 'appeal_again',
            onTap: () => this.config.controller.submitAgain(this.config.controller.identity)
          })
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center, alignItems: ItemAlign.Center }) {
            MeLink({ text: this.t('appeal.contact_cs'), linkId: 'appeal_upheld_cs',
              onTap: () => this.config.customerService() })
            if (!this.model.frozen) {
              if (this.config.deleteAccountAvailable()) {
                Row() {
                  RiskExitSep()
                  MeLink({ text: this.t('settings.delete_account'), linkId: 'appeal_delete_account',
                    onTap: () => this.config.deleteAccount(this.config.controller.identity) })
                }
              }
              Row() {
                RiskExitSep()
                MeLink({ text: this.t('risk.logout'), linkId: 'appeal_logout',
                  onTap: () => this.config.logout(this.config.controller.identity) })
              }
            }
          }
          .width('100%')
          .id('appeal_exits')
        }
      }
      .width('100%')
      .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space3,
        bottom: CouliSpacing.space5 })
      .backgroundColor(this.model.layout === AppealRules.SUBMIT || this.model.layout === AppealRules.RESULT_UPHELD ?
        CouliColors.backgroundSurface : Color.Transparent)
      .border({ width: { top: 1 }, color: { top: CouliColors.borderSubtle } })
      .id('appeal_bar')
    }
  }""",
    'title': """  private title(): string {
    if (this.model.layout === AppealRules.SUBMIT) {
      return this.t('appeal.title');
    }
    return this.t('appeal.progress.title');
  }""",
}
REF_PARTS = """// 参考件（自测用，不可编译）：本组私有件只收值与 @Event。
import { CouliButtonVariant, CouliChip, CouliChipTone, CouliColors, CouliInteraction, CouliTypography } from 'designsystem';

export function appealStateChipTone(riskState: string | null): CouliChipTone {
  if (riskState === 'banned') {
    return CouliChipTone.ERROR;
  }
  if (riskState === 'frozen') {
    return CouliChipTone.WARNING;
  }
  return CouliChipTone.MUTED;
}

export function appealStateChipIcon(riskState: string | null): string {
  return riskState === 'banned' || riskState === 'frozen' ? 'alert' : '';
}

export function riskRowChipTone(rowId: string): CouliChipTone | null {
  return rowId === 'risk_appeal' ? CouliChipTone.MUTED : rowId === 'risk_upheld' ? CouliChipTone.WARNING : null;
}

export function riskRowChipIcon(rowId: string): string {
  return rowId === 'risk_appeal' ? 'clock' : rowId === 'risk_upheld' ? 'alert' : '';
}

export function timelineStates(upheld: boolean): string[] {
  return upheld ? ['done', 'done', 'warning'] : ['done', 'current', 'pending'];
}

@ComponentV2
export struct RiskHero {
  @Param symbol: string = '';
  build() {
    Column() {
      Column() {
        if (this.symbol === 'lock') {
          SymbolGlyph($r('sys.symbol.lock')).fontSize(32)
        } else if (this.symbol === 'pause_circle') {
          SymbolGlyph($r('sys.symbol.pause_circle')).fontSize(32)
        } else if (this.symbol === 'checkmark_circle') {
          SymbolGlyph($r('sys.symbol.checkmark_circle')).fontSize(32)
        } else {
          SymbolGlyph($r('sys.symbol.clock')).fontSize(32)
        }
      }
      .width(96).height(96).accessibilityLevel('no').id(this.iconId)
      Text(this.title).attributeModifier(new CouliTextModifier(CouliTypography.title)).accessibilityRole(AccessibilityRoleType.TITLE_BAR)
    }
  }
}
@ComponentV2
export struct RiskInfoRow {
  build() {
    Row() {
      Text(this.label).attributeModifier(new CouliTextModifier(CouliTypography.footnote))
      if (this.chipTone !== null) {
        CouliChip({ label: this.value, tone: this.chipTone, icon: this.chipIcon }).id(this.valueId + '_chip')
      } else {
        Text(this.value).textAlign(TextAlign.End).flexShrink(1).id(this.valueId)
      }
    }
    .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
    .accessibilityGroup(true)
    .id(this.valueId + '_row')
  }
}
@ComponentV2
export struct RiskNoteStrip {
  build() {
    Row() {
      SymbolGlyph($r('sys.symbol.info_circle')).fontSize(20).id(this.barId + '_icon')
    }
  }
}
@ComponentV2
export struct RiskExitSep {
  build() {
    Text('|').accessibilityLevel('no')
  }
}
@ComponentV2
export struct AppealInfoCard {
  build() {
    Column() {
      Text(this.title).attributeModifier(new CouliTextModifier(CouliTypography.body)).accessibilityRole(AccessibilityRoleType.TITLE_BAR)
    }
  }
}
@ComponentV2
export struct InlineRow {
  build() {
    Row()
  }
}
@ComponentV2
export struct AppealTimeline {
  build() {
    Column() {
      SymbolGlyph($r('sys.symbol.checkmark_circle'))
      SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
      Row().id(this.timelineId + '_' + 0)
      Column().id(this.timelineId + '_' + 0 + '_line')
    }
  }
}
@ComponentV2
export struct BulletCard {
  build() {
    Column()
  }
}
"""
STUB_FAKE_ME_BASE = "export class DebugFakeMe {\n  static scene: string = '';\n}\n"
STUB_FAKE_ME = ("export class DebugFakeMe {\n  static scene: string = '';\n"
                "  static readonly C_SCENES: string[] = ['rv_banned', 'rv_banned_appealing', 'rv_banned_upheld', 'rv_frozen', 'rv_frozen_no_until',\n"
                "    'rv_frozen_appealing', 'rv_frozen_upheld', 'rv_submit_normal', 'banned_lifted', 'rv_lifted_history'];\n"
                "  static readonly C_KEYS: string[] = ['me.appeal_submit_count', 'me.appeal_last_body', 'me.appeal_list_count'];\n"
                "  static readonly C_MARKS: string[] = ['50001', '42901'];\n"
                "  static wallet(scene: string): boolean {\n    return scene.startsWith('rv_banned');\n  }\n}\n")
STUB_DRAFT_BASE = "export class MeDraftTexts {\n    m.set('risk.limit.long', '长期，直到解除');\n}\n"
STUB_DRAFT = ("export class MeDraftTexts {\n    m.set('risk.limit.long', '长期，直到解除');\n" +
              ''.join('    ' + l + '\n' for l in DRAFT_LINES) + "}\n")


REF_AVOID_ANCHOR = '  private t(key: string): string {\n'
REF_AVOID = """  /** D10-633 (a)：本页显示期间 RESIZE，隐藏（被上层页盖住或退出）即还原。 */
  onDidBuild(): void {
    this.getUIContext().getUIObserver().on('navDestinationUpdate', (info: NavDestinationInfo) => {
      if (info.uniqueId !== this.queryNavDestinationInfo()?.uniqueId) {
        return;
      }
      if (info.state === NavDestinationState.ON_SHOWN) {
        this.pageShown();
      } else if (info.state === NavDestinationState.ON_HIDDEN) {
        this.pageHidden();
      }
    });
  }

  private pageShown(): void {
    const ui: UIContext = this.getUIContext();
    this.savedAvoid = ui.getKeyboardAvoidMode();
    ui.setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
  }

  private pageHidden(): void {
    if (this.savedAvoid !== null) {
      this.getUIContext().setKeyboardAvoidMode(this.savedAvoid);
      this.savedAvoid = null;
    }
  }

"""


def reference_views(views):
    rk = views[V_RISK]
    rk = patch(rk, *REF_RISK_IMPORT)
    for old, new in KEY_SWAPS[V_RISK]['noteKey'] + KEY_SWAPS[V_RISK]['detailRows']:
        rk = patch(rk, old, new)
    rk = replace_method(rk, 'hero', REF_RISK_HERO)
    rk = replace_method(rk, 'details', REF_RISK_DETAILS)
    rk = replace_method(rk, 'content', REF_RISK_CONTENT)
    rk = patch(rk, REF_RISK_EXITS_OLD, REF_RISK_EXITS_NEW)
    ap = patch(views[V_APPEAL], *REF_APPEAL_IMPORT)
    ap = patch(ap, REF_AVOID_ANCHOR, REF_AVOID + REF_AVOID_ANCHOR)
    ap = patch(ap, '  CouliAnnounce, CouliButton, CouliButtonVariant, CouliChip, CouliChipTone, CouliColors, CouliFocus, CouliFontWeight,\n'
                   '  CouliFormat, CouliRadius, CouliSpacing,', '  CouliAnnounce, CouliButton, CouliButtonVariant, CouliChip, CouliChipTone, '
                   'CouliColors, CouliFocus, CouliFontWeight,\n  CouliFormat, CouliSpacing,')
    timeline_item = method_text(ap, 'timelineItem')
    ap = ap.replace('  @Builder\n' + timeline_item + '\n\n', '')
    for name, new in REF_APPEAL.items():
        ap = replace_method(ap, name, new)
    return {V_RISK: rk, V_APPEAL: ap}


R, A = V_RISK, V_APPEAL
MUTANTS = [
    # ---- 红线 ①：提交申诉（只在 SUBMIT；去空白后非空；闸门；一次点击一次提交；按身份重建）
    ('红线①提交改读可观察身份', A, '              this.config.controller.submit(this.config.controller.identity);\n',
     '              this.config.controller.submit(this.model.identity);\n'),
    ('红线①提交中仍可点（丢 disabled 闸门）', A, '            disabled: !this.model.submitEnabled || this.model.blocked,\n', ''),
    ('红线①限流期仍可点（disabled 少 blocked）', A, '            disabled: !this.model.submitEnabled || this.model.blocked,\n',
     '            disabled: !this.model.submitEnabled,\n'),
    ('红线①提交中不显示 loading', A, '            loading: this.model.submitting,\n', ''),
    ('红线①输入回调改读当前身份', A, '            this.config.controller.setInput(value, bound.identity);\n',
     '            this.config.controller.setInput(value, this.config.controller.identity);\n'),
    ('红线①输入回调先 trim 再交', A, '            this.config.controller.setInput(value, bound.identity);\n',
     '            this.config.controller.setInput(value.trim(), bound.identity);\n'),
    ('红线①ForEach 键不再按身份（换号不重建）', A, "      }, (b: Bound) => 'appeal_submit_' + b.identity)", "      }, (b: Bound) => 'appeal_submit')"),
    ('红线①提交按钮在处理中版式也出现', A, "        if (this.model.layout === AppealRules.SUBMIT) {\n          CouliButton({\n            text: this.t('appeal.submit'),",
     "        if (this.model.layout === AppealRules.SUBMIT || this.model.layout === AppealRules.PROGRESS) {\n          CouliButton({\n"
     "            text: this.t('appeal.submit'),"),
    ('红线①字段错误显示条件改', A, '        if (this.model.fieldError.length > 0) {\n', '        if (this.model.fieldError !== undefined) {\n'),
    ('红线①错误边色表达式改', A, '          .border({ width: 1, color: this.model.fieldError.length > 0 ? CouliColors.statusErrorText :\n',
     '          .border({ width: 1, color: this.model.message.length > 0 ? CouliColors.statusErrorText :\n'),
    ('红线①申诉执行器被改', 'common/core/src/main/ets/me/MeControllers.ets', 'export const X: number = 1;', 'export const X: number = 2;'),
    ('红线①输入框换成 DS CouliTextArea 又直用一处 TextInput', A, "        TextArea({ text: this.model.input, placeholder: this.t('appeal.placeholder') })\n",
     "        TextInput({ text: this.model.input })\n        TextArea({ text: this.model.input, placeholder: this.t('appeal.placeholder') })\n"),
    # ---- 红线 ②：【再次申诉】零请求、回提交版式、总是显示
    ('红线②再次申诉改成重新读取', A, '            onTap: () => this.config.controller.submitAgain(this.config.controller.identity)\n',
     '            onTap: () => this.config.controller.retry()\n'),
    ('红线②再次申诉读 CT-26e can_resubmit', A, "          CouliButton({\n            text: this.t('appeal.again'),",
     "          if (this.model.latest !== null && this.model.latest['can_resubmit'] !== false) {\n          }\n          CouliButton({\n"
     "            text: this.t('appeal.again'),"),
    ('红线②再次申诉改读可观察身份', A, '            onTap: () => this.config.controller.submitAgain(this.config.controller.identity)\n',
     '            onTap: () => this.config.controller.submitAgain(this.model.identity)\n'),
    # ---- 账号状态主按钮：去向只 Appeal / Home
    ('主按钮查看进度去错页', R, "            buttonId: 'risk_view_progress',\n            onTap: () => this.config.open('Appeal', {})",
     "            buttonId: 'risk_view_progress',\n            onTap: () => this.config.open('Messages', {})"),
    ('主按钮选择条件改（不按 primaryRaw）', R, "        } else if ((this.model.view as MeRecord)['primaryRaw'] === 'view_progress') {\n",
     "        } else if (this.layout() === RiskLayout.BANNED_APPEALING) {\n"),
    ('返回首页改成返回', R, '            onTap: () => this.config.backHome()\n', '            onTap: () => this.config.onBack()\n'),
    # ---- 红线 ③：原因 / 期限 / 不显示处理时限
    ('红线③说明卡加处理时限行', R, "    const pending: MeRecord[] = this.pendingRows();\n",
     "    rows.push([this.t('risk.appeal'), this.t('appeal.sla'), 'risk_sla']);\n    const pending: MeRecord[] = this.pendingRows();\n"),
    ('红线③提现行接入 SLA 副文案', R, '    const view: MeRecord = WithdrawalText.of(item, null) as MeRecord;\n',
     '    const view: MeRecord = WithdrawalText.of(item, this.config.now()) as MeRecord;\n'),
    ('红线③配置加 slaText 出口', R, '  deleteAccountAvailable: () => boolean = () => false;\n',
     '  deleteAccountAvailable: () => boolean = () => false;\n  slaText: () => string | null = () => null;\n'),
    ('红线③视图自己比 frozen_until 与现在', R, "      iconId: 'risk_hero_icon',\n",
     "      iconId: (this.str('frozen_until') ?? '') < String(Date.now()) ? 'x' : 'risk_hero_icon',\n"),
    ('红线③原因改显原始编码', R, "      rows.push([this.t('risk.reason'), this.t(reason), 'risk_reason']);\n",
     "      rows.push([this.t('risk.reason'), reason, 'risk_reason']);\n"),
    ('红线③提示句键选择改', R, "      case RiskLayout.BANNED_APPEALING:\n        return 'risk.banned_appealing.note';",
     "      case RiskLayout.BANNED_APPEALING:\n        return 'risk.banned.note';"),
    ('红线③期限句仍旧草稿「长期，直到解除」', R, "this.t('risk_notice.period_none'), 'risk_limit'", "this.t('risk.limit.long'), 'risk_limit'"),
    ('红线③维持说明仍旧草稿「如有新的情况」', R, "      case RiskLayout.BANNED_UPHELD:\n        return 'risk_notice.banned.upheld';",
     "      case RiskLayout.BANNED_UPHELD:\n        return 'risk.banned_upheld.note';"),
    ('红线③申诉页冻结预计恢复改用当前时间推算', A, "    return Number.isNaN(ms) ? null : futureTimeText(ms, this.config.now());",
     "    return Number.isNaN(ms) ? null : futureTimeText(ms, Date.now());"),
    ('红线③草稿改已有行（加处理时限）', DRAFT, "    m.set('risk.limit.long', '长期，直到解除');", "    m.set('risk.limit.long', '3 个工作日内处理');"),
    ('红线③纯规则被改（showsDeadline）', 'common/core/src/main/ets/me/MePresentation.ets', 'export const X: number = 1;', 'export const X: number = 2;'),
    ('红线③视图读 showsDeadline', R, "      iconId: 'risk_hero_icon',\n", "      iconId: this.model.view !== null && this.model.view['showsDeadline'] ? 'x' : 'risk_hero_icon',\n"),
    # ---- 红线 ④：退出登录
    ('红线④退出改读可观察身份', R, "            onTap: () => this.config.logout(this.config.controller.identity) })\n          }\n        }\n        .width('100%')\n        .id('risk_exits')",
     "            onTap: () => this.config.logout(this.model.view as string) })\n          }\n        }\n        .width('100%')\n        .id('risk_exits')"),
    ('红线④出口行显示条件改（读取失败兜底丢了）', R, 'if (this.banned() || (this.model.view === null && this.model.phase === MePhase.ERROR)) {',
     'if (this.banned()) {'),
    ('红线④维持 · 冻结组也出退出', A, "              Row() {\n                RiskExitSep()\n                MeLink({ text: this.t('risk.logout'), linkId: 'appeal_logout',\n"
     "                  onTap: () => this.config.logout(this.config.controller.identity) })\n              }\n            }\n",
     "            }\n              Row() {\n                RiskExitSep()\n                MeLink({ text: this.t('risk.logout'), linkId: 'appeal_logout',\n"
     "                  onTap: () => this.config.logout(this.config.controller.identity) })\n              }\n"),
    ('红线④确认框接线被改（MePages）', 'entry/src/main/ets/me/MePages.ets', 'export const X: number = 1;', 'export const X: number = 2;'),
    ('红线④退出链接改成直接注销', A, "                MeLink({ text: this.t('risk.logout'), linkId: 'appeal_logout',\n                  onTap: () => this.config.logout(this.config.controller.identity) })",
     "                MeLink({ text: this.t('risk.logout'), linkId: 'appeal_logout',\n                  onTap: () => this.config.deleteAccount(this.config.controller.identity) })"),
    # ---- 红线 ⑤：注销入口只在路由可用时
    ('红线⑤注销链接不看路由可用', R, "          if (this.config.deleteAccountAvailable()) {\n            Row() {\n              RiskExitSep()\n              MeLink({ text: this.t('settings.delete_account'), linkId: 'risk_delete_account',",
     "          if (true) {\n            Row() {\n              RiskExitSep()\n              MeLink({ text: this.t('settings.delete_account'), linkId: 'risk_delete_account',"),
    ('红线⑤说明句恒提注销（与链接判据不同）', R, "(this.config.deleteAccountAvailable() ? 'risk.banned.desc' : 'risk.banned.desc.no_deletion')", "'risk.banned.desc'"),
    ('红线⑤注销改读可观察身份', A, "                    onTap: () => this.config.deleteAccount(this.config.controller.identity) })",
     "                    onTap: () => this.config.deleteAccount(this.model.identity) })"),
    ('红线⑤维持页注销句恒用公开版', A, "this.config.deleteAccountAvailable() ? 'appeal.next.logout.with_deletion' : 'appeal.next.logout'",
     "'appeal.next.logout.with_deletion'"),
    ('红线⑤注销接线被改（AppAccount）', 'entry/src/main/ets/account/AppAccount.ets', 'export const Q: number = 1;', 'export const Q: number = 2;'),
    # ---- 联系客服
    ('联系客服去向改', R, "linkId: 'risk_contact_cs', onTap: () => this.config.customerService() })", "linkId: 'risk_contact_cs', onTap: () => this.config.onBack() })"),
    ('处理中底部链接去向改', A, "linkId: 'appeal_contact_cs', onTap: () => this.config.customerService() })", "linkId: 'appeal_contact_cs', onTap: () => this.config.home() })"),
    # ---- 进行中的提现
    ('提现行状态过滤被改', R, '    const ids: string[] = PendingWithdrawals.filter(items);\n', '    const ids: string[] = items.map((i: MeRecord): string => i[\'withdrawal_id\'] as string);\n'),
    ('提现错误条重试去向改', R, '                this.config.controller.retryWithdrawals();\n', '                this.config.controller.retry();\n'),
    # ---- 红线 ⑥：申诉行 / 胶囊不是入口
    ('红线⑥信息行可点', PARTS, "    .id(this.valueId + '_row')\n", "    .id(this.valueId + '_row')\n    .onClick(() => {})\n"),
    ('红线⑥申诉行胶囊挂手势', R, "        chipTone: riskRowChipTone(row[2]), chipIcon: riskRowChipIcon(row[2]) })\n",
     "        chipTone: riskRowChipTone(row[2]), chipIcon: riskRowChipIcon(row[2]) })\n        .gesture(TapGesture())\n"),
    ('红线⑥私有件自己跳路由', PARTS, '@ComponentV2\nexport struct BulletCard {', 'function go(): void { openInApp(); }\n@ComponentV2\nexport struct BulletCard {'),
    # ---- 账号状态视觉（R1–R8、R32）
    ('头部仍 CouliIcon 48', R, '    RiskHero({\n      symbol:', "    CouliIcon({ name: 'shield', iconSize: 48 })\n    RiskHero({\n      symbol:"),
    ('头部 Symbol 读屏要读', PARTS, ".width(96).height(96).accessibilityLevel('no').id(this.iconId)", '.width(96).height(96).id(this.iconId)'),
    ('标题仍 heading 28', PARTS, 'new CouliTextModifier(CouliTypography.title)', 'new CouliTextModifier(CouliTypography.heading)'),
    ('信息行仍 MeKeyValue', R, '      RiskInfoRow({ label: row[0],', '      MeKeyValue({ label: row[0],'),
    ('信息行值不右对齐', PARTS, '.textAlign(TextAlign.End).flexShrink(1)', '.flexShrink(1)'),
    ('信息行不到 48', PARTS, '    .constraintSize({ minHeight: CouliInteraction.minTouchTarget })\n    .accessibilityGroup(true)', '    .accessibilityGroup(true)'),
    ('信息行容器缺 _row id', PARTS, "    .id(this.valueId + '_row')\n", ''),
    ('申诉行胶囊不按行 id', R, 'chipTone: riskRowChipTone(row[2]), chipIcon: riskRowChipIcon(row[2])', "chipTone: null, chipIcon: ''"),
    ('提示条仍 MeNoticeBar（info 18）', R, "          RiskNoteStrip({ text: this.t(this.noteKey()), barId: 'risk_note' })",
     "          MeNoticeBar({ text: this.t(this.noteKey()), tone: 'info', barId: 'risk_note' })"),
    ('块间仍 12（无 space6）', R, '      Column({ space: CouliSpacing.space6 }) {\n        this.hero()', '      Column({ space: CouliSpacing.space3 }) {\n        this.hero()'),
    ('出口分隔符仍独立子项', R, "          Row() {\n            RiskExitSep()\n            MeLink({ text: this.t('risk.logout'), linkId: 'risk_logout',\n"
     "              onTap: () => this.config.logout(this.config.controller.identity) })\n          }\n",
     "          RiskExitSep()\n          MeLink({ text: this.t('risk.logout'), linkId: 'risk_logout',\n"
     "            onTap: () => this.config.logout(this.config.controller.identity) })\n"),
    ('出口分隔符跟前一个链接同组', A, "                Row() {\n                  RiskExitSep()\n                  MeLink({ text: this.t('settings.delete_account'), linkId: 'appeal_delete_account',\n"
     "                    onTap: () => this.config.deleteAccount(this.config.controller.identity) })\n                }\n",
     "                Row() {\n                  MeLink({ text: this.t('settings.delete_account'), linkId: 'appeal_delete_account',\n"
     "                    onTap: () => this.config.deleteAccount(this.config.controller.identity) })\n                  RiskExitSep()\n                }\n"),
    ('分隔符读屏要读', PARTS, "    Text('|').accessibilityLevel('no')", "    Text('|')"),
    ('卡片 id 缺（risk_info_card）', R, "            cardId: 'risk_info_card',\n", ''),
    # ---- 申诉视觉（R12–R27、H-R06）
    ('申诉卡仍卡外 caption + MeKeyValue', A, "    InlineRow({ label: this.t('appeal.type'), value: this.t('appeal.type.account') })\n    if (this.model.currentStateKey",
     "    MeKeyValue({ label: this.t('appeal.type'), value: this.t('appeal.type.account') })\n    if (this.model.currentStateKey"),
    ('输入框仍 min 120', A, '          .constraintSize({ minHeight: 160 })\n', '          .constraintSize({ minHeight: 120 })\n'),
    ('输入框无占位', A, "TextArea({ text: this.model.input, placeholder: this.t('appeal.placeholder') })", 'TextArea({ text: this.model.input })'),
    ('申诉提示条仍 MeNoticeBar', A, "    RiskNoteStrip({ text: this.t(AppealCopy.submitNote(this.model.frozen, this.model.riskState)), barId: 'appeal_note' })",
     "    MeNoticeBar({ text: this.t(AppealCopy.submitNote(this.model.frozen, this.model.riskState)), tone: 'info', barId: 'appeal_note' })"),
    ('底栏无白底', A, "        CouliColors.backgroundSurface : Color.Transparent)\n", '        Color.Transparent : Color.Transparent)\n'),
    ('处理中胶囊仍 OUTLINE', A, "tone: CouliChipTone.MUTED, icon: 'clock' })", 'tone: CouliChipTone.OUTLINE })'),
    ('状态卡标题仍 heading 28', A, "          Text(this.t('appeal.upheld.title'))\n            .attributeModifier(new CouliTextModifier(CouliTypography.title,",
     "          Text(this.t('appeal.upheld.title'))\n            .attributeModifier(new CouliTextModifier(CouliTypography.heading,"),
    ('时间线仍 Circle 圆点', A, '    AppealTimeline({\n', '    Circle({ width: 10, height: 10 })\n    AppealTimeline({\n'),
    ('时间线步态不走纯函数', A, '      states: timelineStates(upheld)\n', "      states: ['done', 'done', 'done']\n"),
    ('「接下来可以」仍 muted 块', A, "    BulletCard({ title: this.t('appeal.next'), cardId: 'appeal_next_card', lines: this.nextLines() })",
     "    Column().backgroundColor(CouliColors.backgroundMuted)"),
    ('「接下来可以」顺序改', A, "    lines.push(this.t('appeal.result.next.resubmit'));\n    lines.push(this.t('appeal.next.cs'));\n",
     "    lines.push(this.t('appeal.next.cs'));\n    lines.push(this.t('appeal.result.next.resubmit'));\n"),
    ('「接下来可以」冻结句条件改', A, '    if (AppealCopy.upheldFrozenNext(this.model.frozen, this.model.riskState)) {\n', '    if (this.model.frozen) {\n'),
    ('再次申诉仍主按钮', A, "            variant: CouliButtonVariant.SECONDARY,\n            fullWidth: true,\n            buttonId: 'appeal_again',",
     "            fullWidth: true,\n            buttonId: 'appeal_again',"),
    ('当前状态胶囊读版式不读 riskState', A, "        chipTone: appealStateChipTone(this.model.riskState), chipIcon: appealStateChipIcon(this.model.riskState),\n        chipId: 'appeal_state_chip' })",
     "        chipTone: appealStateChipTone(this.model.frozen ? 'frozen' : 'banned'), chipIcon: appealStateChipIcon(this.model.riskState),\n        chipId: 'appeal_state_chip' })"),
    ('胶囊映射纯函数读了别的', PARTS, "export function appealStateChipTone(riskState: string | null): CouliChipTone {\n  if (riskState === 'banned') {",
     "export function appealStateChipTone(riskState: string | null): CouliChipTone {\n  if (riskState === 'banned' || layout === 'x') {"),
    ('已解除无图标块', A, "    RiskHero({\n      symbol: 'checkmark_circle',", "    Column({\n      symbol: 'checkmark_circle',"),
    ('已解除结论仍纯文字', A, "chipTone: CouliChipTone.SUCCESS, chipIcon: 'check',", "chipTone: null, chipIcon: 'check',"),
    ('结果页标题仍按冻结组分支（H-R06）', A, "      return this.t('appeal.title');\n    }\n    return this.t('appeal.progress.title');",
     "      return this.t('appeal.title');\n    }\n    if (this.model.layout === AppealRules.RESULT_LIFTED && !this.model.frozen) {\n"
     "      return this.t('risk.title');\n    }\n    return this.t('appeal.progress.title');"),
    ('维持状态卡缺处理时间行', A, "          InlineRow({ label: this.t('appeal.closed_at'), value: this.time('closed_at') })\n        }\n", '        }\n'),
    ('「再次申诉」句仍旧草稿', A, "    lines.push(this.t('appeal.result.next.resubmit'));", "    lines.push(this.t('appeal.next.again'));"),
    ('维持页限制期限仍旧草稿', A, "value: this.t('risk_notice.period_none') })", "value: this.t('risk.limit.long') })"),
    ('卡片 id 缺（appeal_current_card）', A, "      cardId: 'appeal_current_card',\n", ''),
    ('解除动作去向改（开始使用去钱包）', A, "              buttonId: 'appeal_start',\n              onTap: () => this.config.home()",
     "              buttonId: 'appeal_start',\n              onTap: () => this.config.open('Wallet', {})"),
    ('解除动作条件改', A, "          if (this.liftedAction('view_messages')) {\n", '          if (true) {\n'),
    ('视图另起判定（多调 AppealCopy）', A, "      symbol: 'checkmark_circle',\n", "      symbol: AppealCopy.restored(this.model.riskState) ? 'checkmark_circle' : '',\n"),
    # ---- 键盘避让只在显示期间（测试 v5，D10-633）
    ('避让仍在 onDidBuild 直接设', A, "  onDidBuild(): void {\n    this.getUIContext().getUIObserver()",
     "  onDidBuild(): void {\n    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);\n    this.getUIContext().getUIObserver()"),
    ('避让在 onDidBuild 经辅助方法设', A, "  onDidBuild(): void {\n    this.getUIContext().getUIObserver()",
     "  onDidBuild(): void {\n    this.pageShown();\n    this.getUIContext().getUIObserver()"),
    ('避让在 aboutToDisappear 还原', A, "  private pageShown(): void {",
     "  aboutToDisappear(): void {\n    this.pageHidden();\n  }\n\n  private pageShown(): void {"),
    ('隐藏时不还原', A, "      this.getUIContext().setKeyboardAvoidMode(this.savedAvoid);\n", ''),
    ('没有显示 / 隐藏挂钩', A, "      } else if (info.state === NavDestinationState.ON_HIDDEN) {", "      } else if (info.state === 99) {"),
    ('账号状态页也改避让', R, "  private layout(): string {", "  private layoutAvoid(): void {\n    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);\n  }\n\n  private layout(): string {"),
    # ---- 私有件约束
    ('私有件读 config', PARTS, '@ComponentV2\nexport struct InlineRow {', '@ComponentV2\nexport struct InlineRow {\n  @Param config: Object = {};'),
    ('私有件自己弹 Toast', PARTS, '@ComponentV2\nexport struct InlineRow {', '@ComponentV2\nexport struct InlineRow {\n  t(): void { CouliToast.show(); }'),
    ('私有件写中文字面量', PARTS, "  @Param symbol: string = '';", "  @Param symbol: string = '锁';"),
    ('私有件写色值', PARTS, '@ComponentV2\nexport struct InlineRow {\n  build() {\n    Row()',
     "@ComponentV2\nexport struct InlineRow {\n  build() {\n    Row().backgroundColor('#33290F')"),
    ('私有件缺 BulletCard', PARTS, 'export struct BulletCard {', 'export struct BulletCardX {'),
    ('私有件用 V1 装饰器', PARTS, '@ComponentV2\nexport struct InlineRow {', '@Component\nexport struct InlineRow {'),
    ('新图标没用 Symbol（info 仍 CouliIcon）', PARTS, "      SymbolGlyph($r('sys.symbol.info_circle')).fontSize(20).id(this.barId + '_icon')",
     "      CouliIcon({ name: 'info' }).id(this.barId + '_icon')"),
    ('私有件新增 TextArea 直用', PARTS, '@ComponentV2\nexport struct InlineRow {\n  build() {\n    Row()',
     '@ComponentV2\nexport struct InlineRow {\n  build() {\n    TextArea()'),
    ('私有件缺纯函数 timelineStates', PARTS, 'export function timelineStates(', 'export function timelineStatesX('),
    # ---- 逻辑零改动 / 边界
    ('会话被改（enteredBy10006）', 'common/core/src/main/ets/me/MeSession.ets', 'export const X: number = 1;', 'export const X: number = 2;'),
    ('MeKit 被改', ME + 'MeKit.ets', 'export const X: number = 1;', 'export const X: number = 2;'),
    ('features/me 其余文件被改', ME + 'PrivacyAboutCsParts.ets', 'export const P: number = 1;', 'export const P: number = 2;'),
    ('features/me 新增文件', ME + 'PrivacyAboutCsParts.ets', 'export const P: number = 1;', 'export const P: number = 1;\n//'),
    ('designsystem 被改', 'common/designsystem/src/main/ets/components/Overlays.ets', 'export const D: number = 1;', 'export const D: number = 2;'),
    ('钱包文案被改（WalletDraftTexts）', 'common/core/src/main/ets/wallet/WalletDraftTexts.ets', 'export const W: number = 1;', 'export const W: number = 2;'),
    ('路由被改', 'entry/src/main/ets/routing/AppRouting.ets', 'export const G: number = 1;', 'export const G: number = 2;'),
    ('契约快照被改', 'contracts/snapshot/contracts/texts.default.json', '{"k": 1}', '{"k": 2}'),
    ('草稿缺新键 appeal.placeholder', DRAFT, "    m.set('appeal.placeholder', '请说明情况，方便我们核实');\n", ''),
    ('草稿新键值不是定稿句', DRAFT, "'请说明情况，方便我们核实'", "'请描述'"),
    ('staging 缺场景 banned_lifted', FAKE_ME, "'banned_lifted'", "'lifted_banned'"),
    ('staging 缺提交计数', FAKE_ME, "'me.appeal_submit_count'", "'me.count'"),
    ('staging rv_banned 不回 10006', FAKE_ME, "scene.startsWith('rv_banned')", "scene === 'rv_banned'"),
    ('staging 改已有行', FAKE_ME, "  static scene: string = '';\n", "  static scene: string = 'x';\n"),
    ('夹具被改', VECTORS, '"clock": "2026-11-05T16:00:00+08:00"', '"clock": "2026-11-05T16:01:00+08:00"'),
    # ---- 名单与设施
    ('主步不排除 Me12wcUi', 'tools/ci/verify.sh', 'Me12wbUi,Me12wcUi main', 'Me12wbUi main'),
    ('没有 me12wc 设备步', 'tools/ci/verify.sh', 'entry-me12wc class=Me12wcUi me12wc', 'entry-me12wc class=Me12wcUi all'),
    ('verify 没跑本宿主自测', 'tools/ci/verify.sh', 'me12wc/check_risk_visual.py" --self-test', 'me12wc/check_risk_visual.py" --help'),
    ('device-test 不认 me12wc', 'tools/ci/device-test.sh', 'me12wb|me12wc|all)', 'me12wb|all)'),
    ('名单少一条', CASES, 'me12wc_21_', 'me12wc_99_'),
    ('core 套件未登记', 'common/core/src/test/List.test.ets', '  me12wcRiskTest();\n', ''),
    ('entry 套件未登记', 'entry/src/ohosTest/ets/test/List.test.ets', '  me12wcUiTest();\n', ''),
    ('fixture 被改', FIXTURE, '"rev": "' + REV + '"', '"rev": "' + REV + ' "'),
]
COPY = [SUITE, CASES, 'tools/ci/verify.sh', 'tools/ci/ds02/check_device_result.py', 'tools/ci/device-test.sh',
        'common/core/src/test/List.test.ets', 'entry/src/ohosTest/ets/test/List.test.ets', FIXTURE, VECTORS]
STUB_STRICT = ['common/core/src/main/ets/me/MeControllers.ets', 'common/core/src/main/ets/me/MePresentation.ets',
               'common/core/src/main/ets/me/MeSession.ets', 'entry/src/main/ets/me/MePages.ets', ME + 'MeKit.ets', 'contract.lock']
STUB_TREE = {ME + 'PrivacyAboutCsParts.ets': 'export const P: number = 1;\n',
             'common/designsystem/src/main/ets/components/Overlays.ets': 'export const D: number = 1;\n',
             'common/core/src/main/ets/wallet/WalletDraftTexts.ets': 'export const W: number = 1;\n',
             'entry/src/main/ets/account/AppAccount.ets': 'export const Q: number = 1;\n',
             'entry/src/main/ets/routing/AppRouting.ets': 'export const G: number = 1;\n',
             'contracts/snapshot/contracts/texts.default.json': '{"k": 1}\n'}
STUB_TREES = ['features/me', 'common/designsystem', 'common/core/src/main/ets/wallet', 'entry/src/main/ets/account', 'entry/src/main/ets/routing',
              'contracts']


def build_stub_tree(tmp):
    base = json.loads((ROOT / FIXTURE).read_text(encoding='utf-8'))
    files = {rel: '// 参考桩：' + rel + '\nexport const X: number = 1;\n' for rel in STUB_STRICT}
    files.update(STUB_TREE)
    files.update(reference_views(base['views']))
    files[PARTS] = REF_PARTS
    files[FAKE_ME] = STUB_FAKE_ME
    files[DRAFT] = STUB_DRAFT
    for rel, text in files.items():
        p = tmp / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding='utf-8')
    for rel in COPY:
        p = tmp / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / rel, p)
    synth = dict(base)
    synth['strict'] = [[sha((tmp / rel).read_bytes()), rel] for rel in STUB_STRICT]
    synth['trees'] = STUB_TREES
    synth['tree'] = [[sha(text.encode('utf-8')), rel] for rel, text in sorted(STUB_TREE.items())]
    synth['append_only'] = {FAKE_ME: [line_key(l) for l in STUB_FAKE_ME_BASE.split('\n')],
                            DRAFT: [line_key(l) for l in STUB_DRAFT_BASE.split('\n')]}
    return synth


def run_mutants(tmp, layer, base, mutants, loose):
    failures = []
    for name, rel, old, new in mutants:
        p = tmp / rel
        if not p.is_file():
            failures.append('[%s] 变异目标缺失：%s（%s）' % (layer, name, rel))
            continue
        original = p.read_text(encoding='utf-8')
        n = original.count(old)
        if n == 0 or (not loose and n != 1):
            failures.append('[%s] 定位串在 %s 里出现 %d 次（须恰好 1 次）：%s' % (layer, rel, n, name))
            continue
        extra = None
        if name == 'features/me 新增文件':
            extra = tmp / (ME + 'RiskExtra.ets')
            extra.write_text('export const E: number = 1;\n', encoding='utf-8')
        else:
            p.write_text(original.replace(old, new, 1), encoding='utf-8')
        if rel == FIXTURE:
            _, err = load_fixture(tmp)
            got = [err] if err else []
        else:
            got = check_source(tmp, base) if base is not None else check_source(tmp)
        p.write_text(original, encoding='utf-8')
        if extra is not None:
            extra.unlink()
        print(('KILLED   ' if got else 'SURVIVED ') + '[' + layer + '] ' + name + ('  ← ' + got[0] if got else ''))
        if not got:
            failures.append('[%s] 未被拦下：%s' % (layer, name))
    return failures


def self_test():
    failures = []
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        base = build_stub_tree(tmp)
        got = check_source(tmp, base)
        if got:
            print('ME12WC_SELF_TEST_FAIL 参考桩树不该有违反项：', *got, sep='\n  ')
            return 1
        # 正向对照：只许插入的文件插入一行不误报；H-R03 只替换部分键串（备选方案）守卫区不误报（S5 另报，属方案选择）。
        for rel, old, new in [(FAKE_ME, 'export class DebugFakeMe {\n', "export class DebugFakeMe {\n  static readonly SHOT: string = 'x';\n"),
                              (DRAFT, '}\n', '    // 追加\n}\n')]:
            p = tmp / rel
            original = p.read_text(encoding='utf-8')
            p.write_text(original.replace(old, new, 1), encoding='utf-8')
            if check_source(tmp, base):
                failures.append('[参考桩] 只许插入的 ' + rel + ' 插入一行被误报')
            p.write_text(original, encoding='utf-8')
        p = tmp / V_RISK
        original = p.read_text(encoding='utf-8')
        p.write_text(original.replace("'risk_notice.frozen.hint_no_until'", "'risk.frozen.note_no_until'", 1), encoding='utf-8')
        if any(x.startswith('G4') for x in check_source(tmp, base)):
            failures.append('[参考桩] H-R03 键串只替换部分时守卫区被误报（G4 应只看键串清单外的改动）')
        p.write_text(original, encoding='utf-8')
        failures += run_mutants(tmp, '参考桩', base, MUTANTS, False)
    # 层二：真实实现（本仓库检查通过时）。
    if check_source(ROOT):
        print('SKIP [真实实现] 本仓库检查未通过（实现前预期如此；verify 下一步本仓库检查本来就红），层二跳过')
    else:
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            for top in ['common', 'entry/src', 'features', 'tools/ci', 'specs', 'contracts']:
                shutil.copytree(ROOT / top, tmp / top, ignore=shutil.ignore_patterns('build', '.test', 'oh_modules', '.hvigor', '.preview',
                                                                                     'node_modules'))
            shutil.copyfile(ROOT / 'contract.lock', tmp / 'contract.lock')
            real = [
                ('[真]提交改读可观察身份', V_APPEAL, 'submit(this.config.controller.identity)', 'submit(this.model.identity)'),
                ('[真]丢提交闸门', V_APPEAL, 'disabled: !this.model.submitEnabled || this.model.blocked', 'disabled: false'),
                ('[真]再次申诉改重读', V_APPEAL, 'this.config.controller.submitAgain(this.config.controller.identity)', 'this.config.controller.retry()'),
                ('[真]视图读 can_resubmit', V_APPEAL, "'appeal_again'", "'appeal_again' + String(this.model.latest?.['can_resubmit'])"),
                ('[真]说明卡加时限行', V_RISK, '    const pending: MeRecord[] = this.pendingRows();',
                 "    rows.push(['x', this.t('appeal.sla'), 'risk_sla']);\n    const pending: MeRecord[] = this.pendingRows();"),
                ('[真]退出改读可观察身份', V_RISK, 'this.config.logout(this.config.controller.identity)', 'this.config.logout(this.model.errorText)'),
                ('[真]注销不看路由可用', V_RISK, "this.config.deleteAccountAvailable() ? 'risk.banned.desc'", "true ? 'risk.banned.desc'"),
                ('[真]信息行可点', PARTS, '@ComponentV2', '// .onClick(\n@ComponentV2'.replace('// ', '')),
                ('[真]MeKit 被改', ME + 'MeKit.ets', 'export struct MeLink {', 'export struct MeLink  {'),
                ('[真]私有件读 controller', PARTS, '@ComponentV2', "import { AppealConfig } from './AppealView';\n@ComponentV2"),
                ('[真]标题回到旧分支', V_APPEAL, "return this.t('appeal.progress.title');", "return this.t('risk.title');"),
                ('[真]避让放进 onDidBuild', V_APPEAL, '  onDidBuild(): void {\n',
                 '  onDidBuild(): void {\n    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);\n'),
            ]
            failures += run_mutants(tmp, '真实实现', None, real, True)
    if failures:
        print('ME12WC_SELF_TEST_FAIL', *failures, sep='\n  ')
        return 1
    print('ME12WC_SELF_TEST_OK %d 种错误实现全部拦下（参考桩层；真实实现层见上）' % len(MUTANTS))
    return 0


def main(argv):
    if '--self-test' in argv:
        return self_test()
    found = check_source(ROOT)
    for f in found:
        print(f)
    print('ME12WC_HOST_OK' if not found else 'ME12WC_HOST_FAIL %d 项' % len(found))
    return 1 if found else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
