#!/usr/bin/env python3
"""契约快照 → ArkTS 生成物（只用 Python 3 标准库）。

用法：
    python3 tools/codegen/gen.py           # 重新生成
    python3 tools/codegen/gen.py --check   # 在临时目录生成后逐字比较，有漂移退出 1 并列出文件

只读 contracts/snapshot/（由 tools/contracts/sync.sh 按 contract.lock 产出）。生成：
    common/generated/src/main/ets/*.ets                       枚举、错误码、路由、桥、文案、令牌
    common/generated/src/main/resources/rawfile/texts.default.json   文案原样副本（以后运行时热替换用）
    common/generated/src/staging/ets/DebugRoutes.ets          debug_only 路由（只进 Debug / Staging）
    common/generated/src/{staging,release}/ets/DebugOnly.ets  按 target 二选一，由 Index.ets 经 'generated/ets/DebugOnly' 导出
    common/generated/src/test/ContractSnapshotData.ets        一致性测试用的快照全文（只在 test 目录）
    common/generated/Index.ets                                模块统一导出
不生成 OpenAPI 客户端、事件（specs/events.yaml）与 apps.json 片段（归 HM-02 / HM-03 / HM-05）。
生成物不写时间戳，同一快照重复生成逐字相同。
"""

import json
import os
import re
import shutil
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SNAPSHOT = os.path.join(ROOT, "contracts", "snapshot")
MODULE = os.path.join("common", "generated")
HEADER = "// 生成物，禁止手改；来源 contract.lock（tools/codegen/gen.py 生成）\n"

# 生成物自身使用的类型名；契约枚举转换后与它们或 ArkTS 全局类型重名时加前缀 Contract。
RESERVED_TYPE_NAMES = {
    "ContractEnums", "RetryKind", "ErrorCodeInfo", "ErrorCodes", "RouteKind", "RouteSpec", "Routes",
    "DebugRoutes", "BridgeMethodSpec", "BridgeMethods", "BridgeErrors", "DefaultTexts", "DesignTokens",
    "Object", "Function", "String", "Number", "Boolean", "Symbol", "Array", "Map", "Set", "Date",
    "Error", "Promise", "JSON", "Math", "RegExp", "Record", "Partial", "Required", "Readonly",
    "BigInt", "Intl", "Reflect", "Proxy", "WeakMap", "WeakSet", "Color", "Resource", "Context",
}


class GenError(Exception):
    pass


def load(rel):
    path = os.path.join(SNAPSHOT, rel)
    if not os.path.isfile(path):
        raise GenError("快照缺文件：contracts/snapshot/" + rel + "（先跑 tools/contracts/sync.sh）")
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def read_text(rel):
    with open(os.path.join(SNAPSHOT, rel), encoding="utf-8") as f:
        return f.read()


def ts_str(value):
    """ArkTS 单引号字符串字面量。"""
    out = []
    for ch in value:
        code = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == "'":
            out.append("\\'")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif code < 0x20 or code in (0x2028, 0x2029, 0x7F):
            out.append("\\u%04x" % code)
        else:
            out.append(ch)
    return "'" + "".join(out) + "'"


def ts_nullable_str(value):
    return "null" if value is None else ts_str(value)


def upper_camel(snake):
    parts = [p for p in re.split(r"[^A-Za-z0-9]+", snake) if p]
    name = "".join(p[:1].upper() + p[1:] for p in parts)
    if not name or name[0].isdigit():
        name = "V" + name
    return name


def upper_snake(raw):
    name = re.sub(r"[^A-Za-z0-9]+", "_", raw).strip("_").upper()
    if not name:
        raise GenError("无法转换的枚举值 %r" % raw)
    if name[0].isdigit():
        name = "V_" + name
    return name


def enum_type_name(key):
    name = upper_camel(key)
    if name in RESERVED_TYPE_NAMES:
        name = "Contract" + name
    return name


# ---------------------------------------------------------------- 枚举


def collect_enums():
    enum_dir = os.path.join(SNAPSHOT, "contracts", "enums")
    if not os.path.isdir(enum_dir):
        raise GenError("快照缺 contracts/enums/")
    result = []  # [(key, [raw...])]
    seen = {}
    for fname in sorted(os.listdir(enum_dir)):
        if not fname.endswith(".json"):
            continue
        rel = "contracts/enums/" + fname
        data = load(rel)
        for key, definition in data["enums"].items():
            if key in seen:
                raise GenError("枚举 %s 在 %s 与 %s 重复定义" % (key, seen[key], rel))
            seen[key] = rel
            values = definition.get("values")
            if not isinstance(values, dict) or not values:
                raise GenError("%s:%s 没有 values" % (rel, key))
            result.append((key, list(values.keys())))
    return result


def gen_enums(enums):
    lines = [HEADER, "// 契约枚举：contracts/enums/*.yaml。未知取值由 parseXxx 返回 undefined（不抛错），即 ArkTS 侧的 unknown。\n"]
    type_names = {}
    for key, values in enums:
        tname = enum_type_name(key)
        if tname in type_names.values():
            raise GenError("枚举类型名冲突：%s" % tname)
        type_names[key] = tname
        members = []
        used = set()
        for raw in values:
            member = upper_snake(raw)
            if member in used:
                raise GenError("枚举 %s 的成员名冲突：%s" % (key, member))
            used.add(member)
            members.append((member, raw))
        lines.append("")
        lines.append("/** 契约枚举 %s */" % key)
        lines.append("export enum %s {" % tname)
        lines.append(",\n".join("  %s = %s" % (m, ts_str(r)) for m, r in members))
        lines.append("}")
        lines.append("")
        lines.append("export function parse%s(raw: string): %s | undefined {" % (tname, tname))
        lines.append("  switch (raw) {")
        for m, r in members:
            lines.append("    case %s:" % ts_str(r))
            lines.append("      return %s.%s;" % (tname, m))
        lines.append("    default:")
        lines.append("      return undefined;")
        lines.append("  }")
        lines.append("}")
    lines.append("")
    lines.append("/** 全部契约枚举：蛇形原名 → 契约顺序的 raw 值。 */")
    lines.append("export class ContractEnums {")
    lines.append("  static readonly all: Map<string, string[]> = ContractEnums.build();")
    lines.append("")
    lines.append("  private static build(): Map<string, string[]> {")
    lines.append("    const all: Map<string, string[]> = new Map<string, string[]>();")
    for key, values in enums:
        lines.append("    all.set(%s, [%s]);" % (ts_str(key), ", ".join(ts_str(v) for v in values)))
    lines.append("    return all;")
    lines.append("  }")
    lines.append("}")
    return "\n".join(lines) + "\n", type_names


# ---------------------------------------------------------------- 错误码

RETRY_KINDS = ["never", "after_action", "later", "immediate", "not_applicable"]


def gen_error_codes():
    data = load("contracts/error-codes.json")
    lines = [HEADER, "// 错误码表：contracts/error-codes.yaml（含废弃与 P1 码）。\n"]
    lines.append("export enum RetryKind {")
    lines.append(",\n".join("  %s = %s" % (upper_snake(k), ts_str(k)) for k in RETRY_KINDS))
    lines.append("}")
    lines.append("")
    lines.append("""export class ErrorCodeInfo {
  readonly code: number;
  readonly http: number;
  readonly retryKind: RetryKind;
  readonly retryKindByReason: Map<string, RetryKind>;
  readonly isDeprecated: boolean;
  readonly isP1: boolean;

  constructor(code: number, http: number, retryKind: RetryKind, retryKindByReason: Map<string, RetryKind>,
    isDeprecated: boolean, isP1: boolean) {
    this.code = code;
    this.http = http;
    this.retryKind = retryKind;
    this.retryKindByReason = retryKindByReason;
    this.isDeprecated = isDeprecated;
    this.isP1 = isP1;
  }
}

function reasons(keys: string[], kinds: RetryKind[]): Map<string, RetryKind> {
  const map: Map<string, RetryKind> = new Map<string, RetryKind>();
  for (let i: number = 0; i < keys.length; i++) {
    map.set(keys[i], kinds[i]);
  }
  return map;
}

export class ErrorCodes {
  static readonly all: Map<number, ErrorCodeInfo> = ErrorCodes.build();

  static info(code: number): ErrorCodeInfo | undefined {
    return ErrorCodes.all.get(code);
  }

  private static build(): Map<number, ErrorCodeInfo> {
    const all: Map<number, ErrorCodeInfo> = new Map<number, ErrorCodeInfo>();""")
    seen = set()

    def rk(value, where):
        if value not in RETRY_KINDS:
            raise GenError("错误码 %s 的 retry_kind 未知：%r" % (where, value))
        return "RetryKind." + upper_snake(value)

    for row in data["codes"]:
        code = row["code"]
        if not isinstance(code, int) or code in seen:
            raise GenError("错误码非法或重复：%r" % code)
        seen.add(code)
        by_reason = row.get("retry_kind_by_reason") or {}
        reason_keys = ", ".join(ts_str(k) for k in by_reason)
        reason_kinds = ", ".join(rk(v, code) for v in by_reason.values())
        lines.append("    all.set(%d, new ErrorCodeInfo(%d, %d, %s, reasons([%s], [%s]), %s, %s));" % (
            code, code, int(row["http"]), rk(row.get("retry_kind"), code), reason_keys, reason_kinds,
            "true" if row.get("deprecated") is True else "false",
            "true" if row.get("phase") == "P1" else "false"))
    lines.append("    return all;")
    lines.append("  }")
    lines.append("}")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------- 路由


def route_specs(route_entry_type, route_entry_values, debug_only):
    data = load("contracts/routes.json")
    out = []
    for name, route in data["routes"].items():
        if bool(route.get("debug_only")) != debug_only:
            continue
        kind = route.get("kind")
        if kind not in ("native", "h5"):
            raise GenError("路由 %s 的 kind 未知：%r" % (name, kind))
        auth = route.get("auth")
        if not isinstance(auth, str):
            raise GenError("路由 %s 缺 auth" % name)
        since = route.get("since") or {}
        entries = route.get("entry") or []
        for e in entries:
            if e not in route_entry_values:
                raise GenError("路由 %s 的 entry %r 不在 route_entry 枚举里" % (name, e))
        entry_src = ", ".join("%s.%s" % (route_entry_type, upper_snake(e)) for e in entries)
        out.append("    all.set(%s, new RouteSpec(%s, RouteKind.%s, %s, %s, [%s], %s, %s));" % (
            ts_str(name), ts_str(name), upper_snake(kind), ts_str(auth), ts_nullable_str(since.get("harmony")),
            entry_src, ts_nullable_str(route.get("h5_path")), "true" if debug_only else "false"))
    return out


def gen_routes(route_entry_type, route_entry_values):
    lines = [HEADER, "// 路由表：contracts/routes.json。debug_only 路由不在这里，只生成到 src/staging（DebugRoutes）。\n"]
    lines.append("import { %s } from './ContractEnums';" % route_entry_type)
    lines.append("")
    lines.append("""export enum RouteKind {
  NATIVE = 'native',
  H5 = 'h5'
}

export class RouteSpec {
  readonly name: string;
  readonly kind: RouteKind;
  readonly auth: string;
  readonly sinceHarmony: string | null;
  readonly entries: %(t)s[];
  readonly h5Path: string | null;
  readonly debugOnly: boolean;

  constructor(name: string, kind: RouteKind, auth: string, sinceHarmony: string | null, entries: %(t)s[],
    h5Path: string | null, debugOnly: boolean) {
    this.name = name;
    this.kind = kind;
    this.auth = auth;
    this.sinceHarmony = sinceHarmony;
    this.entries = entries;
    this.h5Path = h5Path;
    this.debugOnly = debugOnly;
  }
}

/** 非 debug_only 路由（三套构建配置都有）。 */
export class Routes {
  static readonly all: Map<string, RouteSpec> = Routes.build();

  static spec(name: string): RouteSpec | undefined {
    return Routes.all.get(name);
  }

  private static build(): Map<string, RouteSpec> {
    const all: Map<string, RouteSpec> = new Map<string, RouteSpec>();""" % {"t": route_entry_type})
    lines.extend(route_specs(route_entry_type, route_entry_values, False))
    lines.append("    return all;")
    lines.append("  }")
    lines.append("}")
    return "\n".join(lines) + "\n"


def gen_debug_routes(route_entry_type, route_entry_values):
    lines = [HEADER, "// debug_only 路由：只在 generated 模块的 staging target（Debug / Staging 配置）编译，Release 产物里没有。\n"]
    lines.append("import { %s } from '../../main/ets/ContractEnums';" % route_entry_type)
    lines.append("import { RouteKind, RouteSpec } from '../../main/ets/Routes';")
    lines.append("")
    lines.append("export class DebugRoutes {")
    lines.append("  static readonly all: Map<string, RouteSpec> = DebugRoutes.build();")
    lines.append("")
    lines.append("  static spec(name: string): RouteSpec | undefined {")
    lines.append("    return DebugRoutes.all.get(name);")
    lines.append("  }")
    lines.append("")
    lines.append("  private static build(): Map<string, RouteSpec> {")
    lines.append("    const all: Map<string, RouteSpec> = new Map<string, RouteSpec>();")
    lines.extend(route_specs(route_entry_type, route_entry_values, True))
    lines.append("    return all;")
    lines.append("  }")
    lines.append("}")
    return "\n".join(lines) + "\n"


def debug_route_names():
    data = load("contracts/routes.json")
    return [n for n, r in data["routes"].items() if r.get("debug_only")]


# ---------------------------------------------------------------- 桥


def gen_bridge():
    data = load("contracts/bridge.schema.json")
    lines = [HEADER, "// 桥方法与桥错误码：contracts/bridge.schema.json。缺省：timeoutMs null、gestureRequired false、sinceHarmony null。\n"]
    lines.append("""export class BridgeMethodSpec {
  readonly name: string;
  readonly level: string;
  readonly timeoutMs: number | null;
  readonly sinceHarmony: string | null;
  readonly gestureRequired: boolean;

  constructor(name: string, level: string, timeoutMs: number | null, sinceHarmony: string | null,
    gestureRequired: boolean) {
    this.name = name;
    this.level = level;
    this.timeoutMs = timeoutMs;
    this.sinceHarmony = sinceHarmony;
    this.gestureRequired = gestureRequired;
  }
}

export class BridgeMethods {
  static readonly all: Map<string, BridgeMethodSpec> = BridgeMethods.build();

  static spec(name: string): BridgeMethodSpec | undefined {
    return BridgeMethods.all.get(name);
  }

  private static build(): Map<string, BridgeMethodSpec> {
    const all: Map<string, BridgeMethodSpec> = new Map<string, BridgeMethodSpec>();""")
    for name, m in data["methods"].items():
        level = m.get("level")
        if not isinstance(level, str):
            raise GenError("桥方法 %s 缺 level" % name)
        timeout = m.get("timeout_ms")
        if timeout is not None and not isinstance(timeout, int):
            raise GenError("桥方法 %s 的 timeout_ms 不是整数" % name)
        since = m.get("since") or {}
        lines.append("    all.set(%s, new BridgeMethodSpec(%s, %s, %s, %s, %s));" % (
            ts_str(name), ts_str(name), ts_str(level), "null" if timeout is None else str(timeout),
            ts_nullable_str(since.get("harmony")), "true" if m.get("gesture_required") is True else "false"))
    lines.append("    return all;")
    lines.append("  }")
    lines.append("}")
    lines.append("")
    lines.append("export class BridgeErrors {")
    lines.append("  static readonly all: Map<number, string> = BridgeErrors.build();")
    lines.append("")
    lines.append("  private static build(): Map<number, string> {")
    lines.append("    const all: Map<number, string> = new Map<number, string>();")
    for code, desc in data["errors"].items():
        if not re.fullmatch(r"[0-9]+", code) or not isinstance(desc, str):
            raise GenError("桥错误码非法：%r" % code)
        lines.append("    all.set(%d, %s);" % (int(code), ts_str(desc)))
    lines.append("    return all;")
    lines.append("  }")
    lines.append("}")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------- 文案


def gen_texts():
    data = load("contracts/texts.default.json")
    lines = [HEADER, "// 包内默认文案：contracts/texts.default.json。同一份快照也原样复制到 resources/rawfile/texts.default.json，\n"
             "// 供以后运行时热替换；这里用常量表，单测不需要 Context。两者由 gen.py 同时产出、--check 保证一致。\n"]
    lines.append("export class DefaultTexts {")
    lines.append("  private static readonly texts: Map<string, string> = DefaultTexts.buildTexts();")
    lines.append("  private static readonly fallbacks: Map<string, string> = DefaultTexts.buildFallbacks();")
    lines.append("")
    lines.append("  static text(key: string): string | undefined {")
    lines.append("    return DefaultTexts.texts.get(key);")
    lines.append("  }")
    lines.append("")
    lines.append("  static fallback(key: string): string | undefined {")
    lines.append("    return DefaultTexts.fallbacks.get(key);")
    lines.append("  }")
    lines.append("")
    lines.append("  static allKeys(): string[] {")
    lines.append("    return Array.from(DefaultTexts.texts.keys());")
    lines.append("  }")
    for method, table in (("buildTexts", data["texts"]), ("buildFallbacks", data["fallbacks"])):
        lines.append("")
        lines.append("  private static %s(): Map<string, string> {" % method)
        lines.append("    const map: Map<string, string> = new Map<string, string>();")
        for k, v in table.items():
            if not isinstance(v, str):
                raise GenError("文案 %s 不是字符串" % k)
            lines.append("    map.set(%s, %s);" % (ts_str(k), ts_str(v)))
        lines.append("    return map;")
        lines.append("  }")
    lines.append("}")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------- 令牌


def gen_tokens():
    data = load("design/design-tokens.json")
    tokens = data["tokens"]
    colors = []

    def walk(node, prefix):
        for key, child in node.items():
            path = key if not prefix else prefix + "." + key
            if isinstance(child, dict) and "value" in child:
                value = child["value"]
                if not isinstance(value, str) or not re.fullmatch(r"#[0-9A-Fa-f]{6}", value):
                    raise GenError("颜色令牌 %s 不是 #RRGGBB：%r" % (path, value))
                colors.append((path, value))
            elif isinstance(child, dict):
                walk(child, path)

    walk(tokens["color"], "")

    def numbers(node, label):
        out = []
        for key, leaf in node.items():
            value = leaf.get("value")
            if not isinstance(value, (int, float)) or isinstance(value, bool):
                raise GenError("%s.%s 不是数字" % (label, key))
            out.append((key, value))
        return out

    def num(v):
        return str(int(v)) if float(v).is_integer() else repr(v)

    lines = [HEADER, "// 设计令牌原始值：design/tokens/design-tokens.json。颜色键为去掉 tokens.color. 的点分路径。\n"
             "// spacing / radius / fontSize 是任务书 §5.6 的约定接口；lineHeight、fontWeight、touchTarget 供 DesignSystem 映射用。\n"]
    lines.append("export class DesignTokens {")
    lines.append("  static readonly version: string = %s;" % ts_str(data["metadata"]["version"]))
    lines.append("  static readonly colors: Map<string, string> = DesignTokens.buildColors();")
    lines.append("  static readonly spacing: Map<string, number> = DesignTokens.buildSpacing();")
    lines.append("  static readonly radius: Map<string, number> = DesignTokens.buildRadius();")
    lines.append("  static readonly fontSize: Map<string, number> = DesignTokens.buildFontSize();")
    lines.append("  static readonly lineHeight: Map<string, number> = DesignTokens.buildLineHeight();")
    lines.append("  static readonly fontWeight: Map<string, number> = DesignTokens.buildFontWeight();")
    lines.append("  static readonly touchTarget: Map<string, number> = DesignTokens.buildTouchTarget();")
    lines.append("")
    lines.append("  private static buildColors(): Map<string, string> {")
    lines.append("    const map: Map<string, string> = new Map<string, string>();")
    for k, v in colors:
        lines.append("    map.set(%s, %s);" % (ts_str(k), ts_str(v)))
    lines.append("    return map;")
    lines.append("  }")
    for method, node, label in (("buildSpacing", tokens["space"], "space"), ("buildRadius", tokens["radius"], "radius"),
                                ("buildFontSize", tokens["font"]["size"], "font.size"),
                                ("buildLineHeight", tokens["font"]["line-height"], "font.line-height"),
                                ("buildFontWeight", tokens["font"]["weight"], "font.weight"),
                                ("buildTouchTarget", tokens["interaction"]["target"], "interaction.target")):
        lines.append("")
        lines.append("  private static %s(): Map<string, number> {" % method)
        lines.append("    const map: Map<string, number> = new Map<string, number>();")
        for k, v in numbers(node, label):
            lines.append("    map.set(%s, %s);" % (ts_str(k), num(v)))
        lines.append("    return map;")
        lines.append("  }")
    lines.append("}")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------- 测试数据


def gen_snapshot_data():
    rels = []
    for dirpath, _, names in os.walk(SNAPSHOT):
        for name in names:
            rel = os.path.relpath(os.path.join(dirpath, name), SNAPSHOT).replace(os.sep, "/")
            rels.append(rel)
    rels.sort()
    lines = [HEADER, "// 一致性测试数据：contracts/snapshot/ 下每个文件的全文（键为快照内相对路径）。只在 src/test，不进产物。\n"]
    lines.append("export const SNAPSHOT_JSON: Map<string, string> = buildSnapshotJson();")
    lines.append("")
    lines.append("function buildSnapshotJson(): Map<string, string> {")
    lines.append("  const map: Map<string, string> = new Map<string, string>();")
    for rel in rels:
        lines.append("  map.set(%s, %s);" % (ts_str(rel), ts_str(read_text(rel))))
    lines.append("  return map;")
    lines.append("}")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------- 汇总

INDEX = HEADER + """// generated 模块统一导出（import { … } from 'generated'）。
// 'generated/ets/DebugOnly' 由 hvigor 按 target 选目录：staging target（Debug / Staging）→ src/staging，导出 DebugRoutes；
// default target（Release）→ src/release，只导出一个 false 标记，Release 里没有 DebugRoutes 与 debug_only 路由名。

%s
export * from 'generated/ets/DebugOnly';
"""

RELEASE_DEBUG_ONLY = HEADER + """// Release（generated 模块 default target）：debug_only 路由不编译进来；DebugRoutes 只在 src/staging。

export const DEBUG_ROUTES_COMPILED: boolean = false;
"""

STAGING_DEBUG_ONLY = HEADER + """// Debug / Staging（generated 模块 staging target）：导出 debug_only 路由表。

export { DebugRoutes } from './DebugRoutes';

export const DEBUG_ROUTES_COMPILED: boolean = true;
"""


def build_outputs():
    enums = collect_enums()
    enum_src, type_names = gen_enums(enums)
    enum_values = dict(enums)
    if "route_entry" not in enum_values:
        raise GenError("契约缺 route_entry 枚举（RouteSpec.entries 依赖它）")
    route_entry_type = type_names["route_entry"]
    route_entry_values = set(enum_values["route_entry"])
    main = os.path.join(MODULE, "src", "main", "ets")
    outputs = {
        os.path.join(main, "ContractEnums.ets"): enum_src,
        os.path.join(main, "ErrorCodes.ets"): gen_error_codes(),
        os.path.join(main, "Routes.ets"): gen_routes(route_entry_type, route_entry_values),
        os.path.join(main, "BridgeMethods.ets"): gen_bridge(),
        os.path.join(main, "DefaultTexts.ets"): gen_texts(),
        os.path.join(main, "DesignTokens.ets"): gen_tokens(),
        os.path.join(MODULE, "src", "main", "resources", "rawfile", "texts.default.json"):
            read_text("contracts/texts.default.json"),
        os.path.join(MODULE, "src", "staging", "ets", "DebugRoutes.ets"):
            gen_debug_routes(route_entry_type, route_entry_values),
        os.path.join(MODULE, "src", "staging", "ets", "DebugOnly.ets"): STAGING_DEBUG_ONLY,
        os.path.join(MODULE, "src", "release", "ets", "DebugOnly.ets"): RELEASE_DEBUG_ONLY,
        os.path.join(MODULE, "src", "test", "ContractSnapshotData.ets"): gen_snapshot_data(),
    }
    outputs[os.path.join(MODULE, "Index.ets")] = INDEX % index_exports(outputs, main)
    return outputs


def index_exports(outputs, main):
    lines = []
    for name in ("ContractEnums", "ErrorCodes", "Routes", "BridgeMethods", "DefaultTexts", "DesignTokens"):
        src = outputs[os.path.join(main, name + ".ets")]
        names = re.findall(r"^export (?:enum|class|function|const) ([A-Za-z0-9_]+)", src, re.M)
        lines.append("export {\n%s\n} from './src/main/ets/%s';" % (",\n".join("  " + n for n in names), name))
    return "\n".join(lines)


# 由生成器完全拥有的目录：里面出现不是本次生成的文件也算漂移。
OWNED_DIRS = [
    os.path.join(MODULE, "src", "main", "ets"),
    os.path.join(MODULE, "src", "main", "resources", "rawfile"),
    os.path.join(MODULE, "src", "staging"),
    os.path.join(MODULE, "src", "release"),
]


def owned_files(base):
    found = set()
    for d in OWNED_DIRS:
        full = os.path.join(base, d)
        if not os.path.isdir(full):
            continue
        for dirpath, _, names in os.walk(full):
            for name in names:
                if name == ".DS_Store":
                    continue
                found.add(os.path.relpath(os.path.join(dirpath, name), base))
    return found


def write_outputs(base, outputs):
    for rel in owned_files(base) - set(outputs):
        os.remove(os.path.join(base, rel))
    for rel, text in outputs.items():
        path = os.path.join(base, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)


def check(outputs):
    drift = []
    tmp = tempfile.mkdtemp(prefix="couli-gen-")
    try:
        write_outputs(tmp, outputs)
        for rel in sorted(outputs):
            current = os.path.join(ROOT, rel)
            if not os.path.isfile(current):
                drift.append(rel + "（缺失）")
                continue
            with open(current, encoding="utf-8", newline="") as a, open(os.path.join(tmp, rel), encoding="utf-8", newline="") as b:
                if a.read() != b.read():
                    drift.append(rel)
        for rel in sorted(owned_files(ROOT) - set(outputs)):
            drift.append(rel + "（多余，不是生成物）")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return drift


def main(argv):
    if len(argv) > 1 and argv[1] not in ("--check",):
        print("用法：gen.py [--check]", file=sys.stderr)
        return 2
    try:
        outputs = build_outputs()
    except GenError as e:
        print("gen.py: " + str(e), file=sys.stderr)
        return 1
    if len(argv) > 1 and argv[1] == "--check":
        drift = check(outputs)
        if drift:
            print("gen.py --check：生成物与快照不一致（运行 python3 tools/codegen/gen.py 重新生成）：", file=sys.stderr)
            for rel in drift:
                print("  " + rel, file=sys.stderr)
            return 1
        print("gen.py --check：%d 个生成物与快照一致" % len(outputs))
        return 0
    write_outputs(ROOT, outputs)
    print("gen.py：已生成 %d 个文件" % len(outputs))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
