#!/usr/bin/env python3
"""FU-X-HOME-PAGE-API-harmony 测试作者 v1：首页走契约 getPage + listPageSectionItems 的生产入口静态检查（core 行为见 HomePageApi.test.ets）。

  H1 Release BuildVariant.homeContract(real: HomeContractPort): HomeContractPort 原样返回 real（正式构建走真实端口，不再是 null）。
  H2 Staging BuildVariant.homeContract(real) 恰为 HomeDebugSources.select(DebugFakeServer.mockGate, BuildVariant.fakeHome, real)
     （假服务只在测试参数打开且环境允许时替换；每次调用判断由 core 套件 s01–s05 钉住）。
  H3 AppHome 只有一处 deps.contract 赋值，且为 BuildVariant.homeContract(new ApiClientHomeContractPort((): ApiClient | null => AppNetwork.client))；
     ApiClientHomeContractPort 从 'core' 导入。
  H4 假服务默认关闭：DebugFakeServer.enabled 初值 false；启动参数只有 1 / '1' / true 才打开；偏好缺省与读失败都按关；
     entry/src/staging 里除 BuildVariant.applyLaunchOptions 外没有别处调 DebugFakeServer.setEnabled。
  H5 core Index 导出 ApiClientHomeContractPort（来自 ./src/main/ets/home/HomeController）。
  H6 契约快照与生成物：openapi.json 有 GET /v1/pages/{page_key}（getPage）与 GET /v1/pages/{page_key}/sections/{section_id}/items
     （listPageSectionItems）；生成的 ApiOperations 登记两者（contract.lock 已升到含 listPageSectionItems 的提交并重新生成）。
  H7 过时说法删掉：HomeController 的「契约还没有的两个接口」「TODO(N-35)」、staging BuildVariant 首页那段的「G02、G03，契约没有」、AppHome 的
     「BuildVariant.homeContract 为 null」、NetworkPolicy 的「首页内容接口在锁定契约里还没有 operationId」。
  H8 基本模式匿名白名单（RequestHeaderPolicy.BASIC_MODE_ALLOWLIST）含 getPage 与 listPageSectionItems（BR-ID-11 细则：首页）。
  （测试 v4，P1 取 B：契约已登记、本端没有承载者的原生路由按不可用，回落升级提示，不进开发占位页）
  H9  entry/src/main/ets/routing/NativeRouteHostNames.ets 的 NATIVE_ROUTE_HOSTS 与「本端实际承载者」双向一致：RootPage.routeMap 里
      `name === X` 的各分支（X 为字面量、RoutePolicy.X 或 RootPage 本文件的常量；不含升级提示页与 RouteTable.has 的占位分支）∪
      TabRoots.ets 的 ShellTab 路由。多了（名单里有、却没有承载者）或少了都算违反。
  H10 AppRouting 的 Router 查表恰为 new NativeRouteHosts(NATIVE_ROUTE_HOSTS).guard((name: string): RouteSpec | undefined =>
      BuildVariant.routeSpec(name))，并从 './NativeRouteHostNames' 导入名单；core Index 导出 NativeRouteHosts。
  H11 不硬编码名单：路由守卫相关文件（RoutePolicy、EntryGuard、Router、AppRouting、NativeRouteHostNames、两个 BuildVariant）的代码
      （去掉注释）里不出现 'InviteBackfill' / 'InviteLink' 字面量。

用法：check_home_page_api.py [--root <树>]     检查（缺省本仓库）
      check_home_page_api.py --self-test       用内置合成参考件跑一遍（应 0 违反），再逐个打错误实现（每个必须命中指定项）
"""
import json
import os
import re
import shutil
import sys
import tempfile

RELEASE_BV = 'entry/src/release/ets/variant/BuildVariant.ets'
STAGING_BV = 'entry/src/staging/ets/variant/BuildVariant.ets'
APP_HOME = 'entry/src/main/ets/home/AppHome.ets'
FAKE_SERVER = 'entry/src/staging/ets/variant/DebugFakeServer.ets'
CORE_INDEX = 'common/core/Index.ets'
CONTROLLER = 'common/core/src/main/ets/home/HomeController.ets'
POLICY = 'common/core/src/main/ets/network/NetworkPolicy.ets'
OPENAPI = 'contracts/snapshot/contracts/openapi.json'
GEN_OPS = 'common/generated/src/main/ets/ApiOperations.ets'
ROOT_PAGE = 'entry/src/main/ets/pages/RootPage.ets'
TAB_ROOTS = 'entry/src/main/ets/shell/TabRoots.ets'
HOST_NAMES = 'entry/src/main/ets/routing/NativeRouteHostNames.ets'
APP_ROUTING = 'entry/src/main/ets/routing/AppRouting.ets'
ROUTE_POLICY = 'common/core/src/main/ets/router/RoutePolicy.ets'
ENTRY_GUARD = 'common/core/src/main/ets/router/EntryGuard.ets'
ROUTER = 'common/core/src/main/ets/router/Router.ets'
STAGING_DIR = 'entry/src/staging'


def read(root, rel):
    with open(os.path.join(root, rel), encoding='utf-8') as fh:
        return fh.read()


def strip_comments(text):
    """去掉 // 与 /* */ 注释（字符串里的不动）。"""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c in '\'"`':
            j = i + 1
            while j < n and text[j] != c:
                j += 2 if text[j] == '\\' else 1
            out.append(text[i:j + 1])
            i = j + 1
        elif text.startswith('//', i):
            j = text.find('\n', i)
            i = n if j < 0 else j
        elif text.startswith('/*', i):
            j = text.find('*/', i + 2)
            i = n if j < 0 else j + 2
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def norm(s):
    return re.sub(r'\s+', ' ', s).strip()


def method_body(code, signature_re):
    """取 static 方法体（花括号配对）；没有返回 None。"""
    m = re.search(signature_re, code)
    if not m:
        return None
    i = code.find('{', m.end() - 1)
    depth, j = 0, i
    while j < len(code):
        if code[j] == '{':
            depth += 1
        elif code[j] == '}':
            depth -= 1
            if depth == 0:
                return code[i + 1:j]
        j += 1
    return None


def check(root):
    v = []
    # H1
    rel_bv = strip_comments(read(root, RELEASE_BV))
    body = method_body(rel_bv, r'static\s+homeContract\s*\(\s*real\s*:\s*HomeContractPort\s*\)\s*:\s*HomeContractPort\s*\{')
    if body is None or norm(body) != 'return real;':
        v.append('H1 Release BuildVariant.homeContract(real: HomeContractPort): HomeContractPort 必须原样 return real;')
    # H2
    stg_bv = strip_comments(read(root, STAGING_BV))
    body = method_body(stg_bv, r'static\s+homeContract\s*\(\s*real\s*:\s*HomeContractPort\s*\)\s*:\s*HomeContractPort\s*\{')
    want = 'return HomeDebugSources.select(DebugFakeServer.mockGate, BuildVariant.fakeHome, real);'
    if body is None or norm(body) != want:
        v.append('H2 Staging BuildVariant.homeContract(real) 必须恰为 ' + want)
    if re.search(r'HomeDebugSources\.guarded\s*\(\s*DebugFakeServer\.mockGate\s*,\s*BuildVariant\.fakeHome', stg_bv):
        v.append('H2 Staging 普通首页仍用 HomeDebugSources.guarded（闸门关时为 null、不发请求）')
    # H3
    app = strip_comments(read(root, APP_HOME))
    assigns = re.findall(r'deps\.contract\s*=\s*([^;]*);', app)
    want3 = 'BuildVariant.homeContract(new ApiClientHomeContractPort((): ApiClient | null => AppNetwork.client))'
    if len(assigns) != 1 or norm(assigns[0]) != want3:
        v.append('H3 AppHome 必须只有一处 deps.contract = ' + want3 + '（现有 %d 处）' % len(assigns))
    imp = re.search(r'import\s*\{([^}]*)\}\s*from\s*\'core\'', app)
    if not imp or not re.search(r'\bApiClientHomeContractPort\b', imp.group(1)):
        v.append("H3 AppHome 必须从 'core' 导入 ApiClientHomeContractPort")
    # H4
    fake = strip_comments(read(root, FAKE_SERVER))
    if not re.search(r'private\s+static\s+enabled\s*:\s*boolean\s*=\s*false\s*;', fake):
        v.append('H4 DebugFakeServer.enabled 初值必须为 false（默认 staging 不拦截真实请求）')
    if "if (fake === '1' || fake === 1 || fake === true) {\n      on = true;" not in stg_bv:
        v.append("H4 启动参数只有 '1' / 1 / true 才打开假服务")
    if 'on = prefs !== null && prefs.getSync(DEBUG_FAKE_SERVER_KEY, false) === true;' not in stg_bv:
        v.append('H4 没带启动参数时只按偏好里明确存过的 true 打开（缺省 false）')
    callers = []
    for dirpath, _, names in os.walk(os.path.join(root, STAGING_DIR)):
        for name in names:
            if not name.endswith('.ets'):
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root).replace(os.sep, '/')
            if rel == FAKE_SERVER:
                continue
            code = strip_comments(open(full, encoding='utf-8').read())
            for m in re.finditer(r'DebugFakeServer\s*\.\s*setEnabled\s*\(([^)]*)\)', code):
                callers.append((rel, norm(m.group(1))))
    if callers != [(STAGING_BV, 'on')]:
        v.append('H4 DebugFakeServer.setEnabled 只许 BuildVariant.applyLaunchOptions 以 on 调用一次，现为 ' + repr(callers))
    # H5
    idx = strip_comments(read(root, CORE_INDEX))
    ok5 = any(re.search(r'\bApiClientHomeContractPort\b', m.group(1))
              for m in re.finditer(r'export\s*\{([^}]*)\}\s*from\s*\'\./src/main/ets/home/HomeController\'', idx))
    if not ok5:
        v.append('H5 core Index 必须从 ./src/main/ets/home/HomeController 导出 ApiClientHomeContractPort')
    # H6
    try:
        paths = json.loads(read(root, OPENAPI)).get('paths', {})
    except (OSError, ValueError):
        paths = {}
    gp = paths.get('/v1/pages/{page_key}', {}).get('get', {})
    li = paths.get('/v1/pages/{page_key}/sections/{section_id}/items', {}).get('get', {})
    if gp.get('operationId') != 'getPage':
        v.append('H6 契约快照缺 GET /v1/pages/{page_key} getPage')
    if li.get('operationId') != 'listPageSectionItems':
        v.append('H6 契约快照缺 GET /v1/pages/{page_key}/sections/{section_id}/items listPageSectionItems（contract.lock 需升级）')
    gen = read(root, GEN_OPS)
    if "new ApiOperation('getPage', 'GET', '/v1/pages/{page_key}'," not in gen:
        v.append('H6 生成的 ApiOperations 没有 getPage')
    if "new ApiOperation('listPageSectionItems', 'GET', '/v1/pages/{page_key}/sections/{section_id}/items'," not in gen:
        v.append('H6 生成的 ApiOperations 没有 listPageSectionItems（升 lock 后 gen.py 重新生成）')
    # H7
    stale = [
        (CONTROLLER, '契约还没有的两个接口'), (CONTROLLER, 'TODO(N-35)'), (STAGING_BV, 'G02、G03，契约没有'),
        (APP_HOME, 'BuildVariant.homeContract 为 null'), (POLICY, '首页内容接口在锁定契约里还没有 operationId'),
    ]
    for rel, words in stale:
        if words in read(root, rel):
            v.append('H7 %s 仍写着「%s」' % (rel, words))
    # H8
    pol = strip_comments(read(root, POLICY))
    m = re.search(r'BASIC_MODE_ALLOWLIST\s*:\s*string\[\]\s*=\s*\[([^\]]*)\]', pol)
    names = re.findall(r"'([A-Za-z]+)'", m.group(1)) if m else []
    for need in ('getPage', 'listPageSectionItems'):
        if need not in names:
            v.append('H8 基本模式匿名白名单缺 ' + need)
    v.extend(check_route_hosts(root))
    return v


def read_opt(root, rel):
    try:
        return read(root, rel)
    except OSError:
        return None


def check_route_hosts(root):
    v = []
    # H9
    rp = read_opt(root, ROOT_PAGE)
    tabs = read_opt(root, TAB_ROOTS)
    hosts_src = read_opt(root, HOST_NAMES)
    policy = read_opt(root, ROUTE_POLICY) or ''
    if rp is None or tabs is None:
        v.append('H9 找不到 RootPage.ets 或 TabRoots.ets')
        return v
    code = strip_comments(rp)
    body = method_body(code, r'routeMap\s*\(\s*name\s*:\s*string\s*,\s*param\s*:\s*Object\s*\)\s*\{')
    consts = dict(re.findall(r"(?:const|static readonly)\s+([A-Z_][A-Z0-9_]*)\s*:\s*string\s*=\s*'([A-Za-z]+)'", code))
    pol = dict(re.findall(r"static readonly ([A-Z_][A-Z0-9_]*)\s*:\s*string\s*=\s*'([A-Za-z]+)'", strip_comments(policy)))
    hosted, unresolved = set(), []
    if body is None:
        v.append('H9 RootPage 找不到 routeMap(name: string, param: Object)')
    else:
        for m in re.finditer(r"name\s*===\s*('([A-Za-z]+)'|RoutePolicy\.([A-Z_0-9]+)|([A-Z_][A-Z0-9_]*))", body):
            if m.group(2):
                hosted.add(m.group(2))
            elif m.group(3):
                (hosted.add(pol[m.group(3)]) if m.group(3) in pol else unresolved.append('RoutePolicy.' + m.group(3)))
            elif m.group(4) in ('UPGRADE_PROMPT_PAGE',):
                continue
            elif m.group(4) in consts:
                hosted.add(consts[m.group(4)])
            else:
                unresolved.append(m.group(4))
    hosted |= set(re.findall(r"new ShellTab\('([A-Za-z]+)'", strip_comments(tabs)))
    if unresolved:
        v.append('H9 routeMap 里有解析不了的路由常量：' + ', '.join(unresolved))
    if hosts_src is None:
        v.append('H9 缺 ' + HOST_NAMES + '（NATIVE_ROUTE_HOSTS）')
    else:
        m = re.search(r'export\s+const\s+NATIVE_ROUTE_HOSTS\s*:\s*string\[\]\s*=\s*\[([^\]]*)\]', strip_comments(hosts_src))
        listed = set(re.findall(r"'([A-Za-z]+)'", m.group(1))) if m else set()
        if not m:
            v.append('H9 NativeRouteHostNames.ets 没有 export const NATIVE_ROUTE_HOSTS: string[] = [...]')
        extra, missing = sorted(listed - hosted), sorted(hosted - listed)
        if extra:
            v.append('H9 NATIVE_ROUTE_HOSTS 里有本端没有承载者的路由：' + ', '.join(extra))
        if missing:
            v.append('H9 NATIVE_ROUTE_HOSTS 漏了有承载者的路由：' + ', '.join(missing))
    # H10
    ar = read_opt(root, APP_ROUTING)
    want = 'new NativeRouteHosts(NATIVE_ROUTE_HOSTS).guard((name: string): RouteSpec | undefined => BuildVariant.routeSpec(name))'
    if ar is None or want not in norm(strip_comments(ar)) or 'new Router(' not in ar:
        v.append('H10 AppRouting 的 Router 查表必须是 ' + want)
    elif not re.search(r"import\s*\{[^}]*\bNATIVE_ROUTE_HOSTS\b[^}]*\}\s*from\s*'\./NativeRouteHostNames'", ar):
        v.append("H10 AppRouting 必须从 './NativeRouteHostNames' 导入 NATIVE_ROUTE_HOSTS")
    idx = strip_comments(read_opt(root, CORE_INDEX) or '')
    if not any(re.search(r'\bNativeRouteHosts\b', m.group(1))
               for m in re.finditer(r"export\s*\{([^}]*)\}\s*from\s*'\./src/main/ets/router/RoutePolicy'", idx)):
        v.append('H10 core Index 必须从 ./src/main/ets/router/RoutePolicy 导出 NativeRouteHosts')
    # H11
    for rel in (ROUTE_POLICY, ENTRY_GUARD, ROUTER, APP_ROUTING, HOST_NAMES, RELEASE_BV, STAGING_BV):
        text = read_opt(root, rel)
        if text is None:
            continue
        for name in ('InviteBackfill', 'InviteLink'):
            if re.search(r"['\"`]" + name + r"['\"`]", strip_comments(text)):
                v.append('H11 %s 硬编码了路由名 %s（判定要看页面注册表）' % (rel, name))
    return v


# ---------------------------------------------------------------- 自测：合成参考件（= 实现后的最小形状）与错误实现

REFERENCE = {
    RELEASE_BV: """export class BuildVariant {
  /** Release：首页走真实端口。 */
  static homeContract(real: HomeContractPort): HomeContractPort {
    return real;
  }
}
""",
    STAGING_BV: """export class BuildVariant {
  private static readonly fakeHome: DebugFakeHome = new DebugFakeHome();

  /** 首页：假服务只在测试参数下替换（FU-X-HOME-PAGE-API）。 */
  static homeContract(real: HomeContractPort): HomeContractPort {
    return HomeDebugSources.select(DebugFakeServer.mockGate, BuildVariant.fakeHome, real);
  }

  static applyLaunchOptions(): void {
    const fake: Object | undefined = want.parameters?.[DEBUG_FAKE_SERVER_KEY];
    let on: boolean | null = null;
    if (fake === '1' || fake === 1 || fake === true) {
      on = true;
    } else if (fake === '0' || fake === 0 || fake === false) {
      on = false;
    }
    if (on === null) {
      try {
        on = prefs !== null && prefs.getSync(DEBUG_FAKE_SERVER_KEY, false) === true;
      } catch (e) {
        on = false;
      }
    }
    if (DebugFakeServer.setEnabled(on)) {
    }
  }
}
""",
    APP_HOME: """import {
  AgentEntryVisibility, ApiClient, ApiClientHomeContractPort, ApiClientHomeNoticePort, AppConfig
} from 'core';

export class AppHome {
  build(): void {
    deps.contract = BuildVariant.homeContract(new ApiClientHomeContractPort((): ApiClient | null => AppNetwork.client));
    deps.notices = new ApiClientHomeNoticePort((): ApiClient | null => AppNetwork.client);
  }
}
""",
    FAKE_SERVER: """export class DebugFakeServer {
  private static enabled: boolean = false;

  static setEnabled(on: boolean): boolean {
    DebugFakeServer.enabled = on;
    return on;
  }
}
""",
    CORE_INDEX: """export {
  HomeIdentity, HomeContractPort, ApiClientHomeContractPort, HomeNoticePort, ApiClientHomeNoticePort
} from './src/main/ets/home/HomeController';
export { NativeRouteHosts } from './src/main/ets/router/RoutePolicy';
""",
    CONTROLLER: """/** 首页的两个契约接口 getPage、listPageSectionItems（FU-X-HOME-PAGE-API）。 */
export interface HomeContractPort {
}
""",
    POLICY: """export class RequestHeaderPolicy {
  static readonly BASIC_MODE_ALLOWLIST: string[] = ['getConfig', 'searchProducts', 'getProduct', 'listArticles', 'getPage',
    'listPageSectionItems'];
}
""",
    OPENAPI: json.dumps({'paths': {
        '/v1/pages/{page_key}': {'get': {'operationId': 'getPage'}},
        '/v1/pages/{page_key}/sections/{section_id}/items': {'get': {'operationId': 'listPageSectionItems'}},
    }}),
    ROOT_PAGE: """const SETTINGS_ROUTE: string = 'Settings';
export struct RootPage {
  @Builder
  routeMap(name: string, param: Object) {
    if (name === RoutePolicy.LOGIN) {
      LoginPage()
    } else if (name === SETTINGS_ROUTE) {
      SettingsPage()
    } else if (name === 'Wallet') {
      WalletPage()
    } else if (name === UPGRADE_PROMPT_PAGE || RouteTable.has(name)) {
      RoutePlaceholderPage({ route: name })
    }
  }
}
""",
    TAB_ROOTS: """export const SHELL_TABS: ShellTab[] = [
  new ShellTab('Home', ShellDraftTexts.TAB_HOME, 'home'),
  new ShellTab('Me', ShellDraftTexts.TAB_ME, 'user')
];
""",
    HOST_NAMES: """// 本端有承载者的原生路由名。
export const NATIVE_ROUTE_HOSTS: string[] = ['Login', 'Settings', 'Wallet', 'Home', 'Me'];
""",
    APP_ROUTING: """import { NATIVE_ROUTE_HOSTS } from './NativeRouteHostNames';
export class AppRouting {
  get router(): Router {
    this.routerInstance = new Router(new PendingActionStore(this.backend), (): GuardState => this.guardState(),
      this.navigator, new NativeRouteHosts(NATIVE_ROUTE_HOSTS).guard((name: string): RouteSpec | undefined => BuildVariant.routeSpec(name)),
      (): LaunchReadiness => this.readiness());
    return this.routerInstance;
  }
}
""",
    ROUTE_POLICY: """export class RoutePolicy {
  static readonly LOGIN: string = 'Login';
}

export class NativeRouteHosts {
  constructor(names: string[]) {
  }
}
""",
    GEN_OPS: """    ApiOperations.put(all, new ApiOperation('getPage', 'GET', '/v1/pages/{page_key}', 'optional', false, false, null, [30701], ['full'], 'not_marked', false));
    ApiOperations.put(all, new ApiOperation('listPageSectionItems', 'GET', '/v1/pages/{page_key}/sections/{section_id}/items', 'optional', false, false, null, [20001, 30701], ['full'], 'not_marked', false));
""",
}

# (名称, 文件, 原文, 替换, 必须命中的检查项)
MUTANTS = [
    ('Release 仍为 null（仍只用包内默认）', RELEASE_BV, '    return real;', '    return null;', 'H1'),
    ('Release 签名没改', RELEASE_BV, 'homeContract(real: HomeContractPort): HomeContractPort', 'homeContract(): HomeContractPort | null', 'H1'),
    ('Staging 仍用 guarded（假服务关时为 null）', STAGING_BV,
     'return HomeDebugSources.select(DebugFakeServer.mockGate, BuildVariant.fakeHome, real);',
     'return HomeDebugSources.guarded(DebugFakeServer.mockGate, BuildVariant.fakeHome) ?? real;', 'H2'),
    ('Staging 一律用假实现（默认 staging 仍拦截）', STAGING_BV,
     'return HomeDebugSources.select(DebugFakeServer.mockGate, BuildVariant.fakeHome, real);',
     'return HomeDebugSources.select((): boolean => true, BuildVariant.fakeHome, real);', 'H2'),
    ('Staging 不看闸门直接真实（截图 / 设备用例的假服务失效）', STAGING_BV,
     'return HomeDebugSources.select(DebugFakeServer.mockGate, BuildVariant.fakeHome, real);', 'return real;', 'H2'),
    ('AppHome 没注入真实端口', APP_HOME,
     'BuildVariant.homeContract(new ApiClientHomeContractPort((): ApiClient | null => AppNetwork.client))',
     'BuildVariant.homeContract(null)', 'H3'),
    ('AppHome 另有一处覆盖 deps.contract', APP_HOME, '    deps.notices =', '    deps.contract = null;\n    deps.notices =', 'H3'),
    ('AppHome 没从 core 导入', APP_HOME, 'ApiClient, ApiClientHomeContractPort, ApiClientHomeNoticePort', 'ApiClient, ApiClientHomeNoticePort', 'H3'),
    ('假服务初值为开', FAKE_SERVER, 'enabled: boolean = false;', 'enabled: boolean = true;', 'H4'),
    ('偏好缺省按开', STAGING_BV, "prefs.getSync(DEBUG_FAKE_SERVER_KEY, false) === true;", "prefs.getSync(DEBUG_FAKE_SERVER_KEY, true) !== false;", 'H4'),
    ('任何参数值都打开', STAGING_BV, "if (fake === '1' || fake === 1 || fake === true) {", "if (fake !== undefined) {", 'H4'),
    ('别处偷偷打开假服务', STAGING_BV, '    if (DebugFakeServer.setEnabled(on)) {', '    DebugFakeServer.setEnabled(true);\n    if (DebugFakeServer.setEnabled(on)) {', 'H4'),
    ('Index 没导出', CORE_INDEX, 'HomeContractPort, ApiClientHomeContractPort,', 'HomeContractPort,', 'H5'),
    ('契约没升（快照缺 listPageSectionItems）', OPENAPI, '"listPageSectionItems"', '"listPageSectionItemsOld"', 'H6'),
    ('没重新生成', GEN_OPS, "new ApiOperation('listPageSectionItems',", "new ApiOperation('listSectionItems',", 'H6'),
    ('注释仍说契约没有', CONTROLLER, '/** 首页的两个契约接口', '/** 契约还没有的两个接口 TODO(N-35)', 'H7'),
    ('AppHome 注释仍说为 null', APP_HOME, 'export class AppHome {', '// Release 没有（BuildVariant.homeContract 为 null）\nexport class AppHome {', 'H7'),
    ('基本模式白名单没加首页', POLICY, ", 'getPage',\n    'listPageSectionItems'];", '];', 'H8'),
    ('名单多了没有页面的 InviteBackfill', HOST_NAMES, "'Home', 'Me'];", "'Home', 'Me', 'InviteBackfill'];", 'H9'),
    ('名单漏了有页面的 Wallet', HOST_NAMES, "'Settings', 'Wallet', ", "'Settings', ", 'H9'),
    ('名单漏了 Tab 根', HOST_NAMES, ", 'Me'];", "];", 'H9'),
    ('新接页面没登记进名单', ROOT_PAGE, "    } else if (name === UPGRADE_PROMPT_PAGE", "    } else if (name === 'Favorites') {\n      FavoritesPage()\n    } else if (name === UPGRADE_PROMPT_PAGE", 'H9'),
    ('routeMap 用了解析不了的常量', ROOT_PAGE, "name === 'Wallet'", "name === WALLET_ROUTE", 'H9'),
    ('仍进开发占位页（Router 没套守卫）', APP_ROUTING,
     "new NativeRouteHosts(NATIVE_ROUTE_HOSTS).guard((name: string): RouteSpec | undefined => BuildVariant.routeSpec(name))",
     "(name: string): RouteSpec | undefined => BuildVariant.routeSpec(name)", 'H10'),
    ('守卫用了别的名单', APP_ROUTING, "import { NATIVE_ROUTE_HOSTS } from './NativeRouteHostNames';",
     "const NATIVE_ROUTE_HOSTS: string[] = ['Login'];", 'H10'),
    ('Index 没导出 NativeRouteHosts', CORE_INDEX, "export { NativeRouteHosts } from './src/main/ets/router/RoutePolicy';\n", '', 'H10'),
    ('守卫硬编码两个名字', ROUTE_POLICY, "  constructor(names: string[]) {\n  }",
     "  constructor(names: string[]) {\n  }\n\n  static readonly BLOCKED: string[] = ['InviteBackfill', 'InviteLink'];", 'H11'),
    ('AppRouting 硬编码拦 InviteLink', APP_ROUTING, "    return this.routerInstance;",
     "    if (name === 'InviteLink') {\n    }\n    return this.routerInstance;", 'H11'),
]


def write_tree(base, files):
    for rel, text in files.items():
        p = os.path.join(base, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, 'w', encoding='utf-8') as fh:
            fh.write(text)


def self_test():
    tmp = tempfile.mkdtemp(prefix='homeapi-check-')
    bad = 0
    try:
        ref = os.path.join(tmp, 'ref')
        write_tree(ref, REFERENCE)
        got = check(ref)
        print('自测 参考件：%d 违反%s' % (len(got), '' if not got else ' ' + repr(got)))
        bad += 1 if got else 0
        for name, rel, old, new, want in MUTANTS:
            files = dict(REFERENCE)
            assert files[rel].count(old) == 1, (name, files[rel].count(old))
            files[rel] = files[rel].replace(old, new)
            d = os.path.join(tmp, 'mut')
            shutil.rmtree(d, ignore_errors=True)
            write_tree(d, files)
            got = check(d)
            hit = any(x.startswith(want + ' ') for x in got)
            print(('拦下 ' if hit else '漏过!') + ' %s（应命中 %s）' % (name, want))
            bad += 0 if hit else 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print('check_home_page_api --self-test：%d 个错误实现，%s' % (len(MUTANTS), '全部拦下' if bad == 0 else '%d 处失败' % bad))
    return 1 if bad else 0


def main():
    args = sys.argv[1:]
    if '--self-test' in args:
        return self_test()
    root = os.path.abspath(args[args.index('--root') + 1]) if '--root' in args else \
        os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
    got = check(root)
    for x in got:
        print(x)
    print('check_home_page_api：%d 处违反' % len(got))
    return 1 if got else 0


if __name__ == '__main__':
    sys.exit(main())
