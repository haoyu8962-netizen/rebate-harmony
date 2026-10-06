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
    common/designsystem/src/test/FormatVectorsData.ets        specs/format-vectors.json 全文（DS-01，格式向量单测用）
    common/core/src/test/RouterVectorsData.ets                specs/router-vectors.json 全文（APP-02a，Router 向量单测用）
    common/core/src/test/TestDebugRoutes.ets                  debug_only 路由表的测试副本（APP-02a，core 单测注册调试路由用）
    common/core/src/test/PrivacyGateVectorsData.ets           specs/privacy-gate-vectors.json 全文（APP-02b，隐私闸门向量单测用）
    common/generated/src/main/ets/AppStores.ets               商店对照表 specs/app-stores.yaml（APP-02c；值为 null 的商店视为本机打不开）
    common/generated/src/staging/ets/AppVersionCheckExample.ets
                                                              openapi GET /v1/app-versions/check 的 200 响应示例 data（APP-02c 调试假数据，
                                                              只进 Debug / Staging，release-scan 查它的 MARKER）
    common/core/src/test/UpdateGateVectorsData.ets            specs/update-vectors.json 全文（APP-02c，UpdateGate 向量单测用）
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
    "DebugRoutes", "AppStoreSpec", "AppStores", "AppVersionCheckExample", "BridgeMethodSpec", "BridgeMethods", "BridgeErrors", "DefaultTexts", "DesignTokens",
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
    agent_guide_accounts = agent_guide_account_values()
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
        agent_guide = route.get("agent_guide", False)
        if not isinstance(agent_guide, bool):
            raise GenError("路由 %s 的 agent_guide 不是布尔" % name)
        account = route.get("agent_guide_account")
        if account is not None and account not in agent_guide_accounts:
            raise GenError("路由 %s 的 agent_guide_account %r 不在契约取值 %r 里" % (name, account, agent_guide_accounts))
        if account is not None and agent_guide:
            raise GenError("路由 %s 同时声明 agent_guide 与 agent_guide_account" % name)
        params, required, additional = route_params(name, route.get("params"))
        out.append("    all.set(%s, new RouteSpec(%s, RouteKind.%s, %s, %s, [%s], %s, %s, %s, %s,\n"
                   "      [%s], [%s], %s));" % (
            ts_str(name), ts_str(name), upper_snake(kind), ts_str(auth), ts_nullable_str(since.get("harmony")),
            entry_src, ts_nullable_str(route.get("h5_path")), "true" if debug_only else "false",
            "true" if agent_guide else "false", ts_nullable_str(account),
            ", ".join(params), ", ".join(ts_str(r) for r in required), "true" if additional else "false"))
    return out


# routes.json params 用到的 JSON Schema 关键字；出现别的关键字时报错，免得生成物悄悄漏掉约束。
PARAM_TYPES = ("string", "integer", "number", "boolean", "object", "array")
PARAM_KEYWORDS = {"type", "enum", "minLength", "maxLength", "pattern", "description", "additionalProperties"}


def agent_guide_account_values():
    """agent_guide_account 的契约取值：从 routes.json $comment 里「agent_guide_account (a | b | c)」读出。"""
    comment = load("contracts/routes.json").get("$comment", "")
    m = re.search(r"agent_guide_account \(([a-z_ |]+)\)", comment)
    if not m:
        raise GenError("routes.json $comment 里找不到 agent_guide_account 的取值说明")
    return [v.strip() for v in m.group(1).split("|") if v.strip()]


def route_params(name, schema):
    if not isinstance(schema, dict) or schema.get("type") != "object":
        raise GenError("路由 %s 的 params 不是 object schema" % name)
    unknown = set(schema) - {"type", "additionalProperties", "properties", "required"}
    if unknown:
        raise GenError("路由 %s 的 params 有未支持的关键字 %r" % (name, sorted(unknown)))
    additional = schema.get("additionalProperties", True)
    if not isinstance(additional, bool):
        raise GenError("路由 %s 的 additionalProperties 不是布尔" % name)
    required = schema.get("required", [])
    props = schema.get("properties", {})
    for r in required:
        if r not in props:
            raise GenError("路由 %s 的必填参数 %s 没有定义" % (name, r))
    out = []
    for pname, p in props.items():
        extra = set(p) - PARAM_KEYWORDS
        if extra:
            raise GenError("路由 %s 参数 %s 有未支持的关键字 %r" % (name, pname, sorted(extra)))
        ptype = p.get("type")
        if ptype not in PARAM_TYPES:
            raise GenError("路由 %s 参数 %s 的 type 未知：%r" % (name, pname, ptype))
        enum = p.get("enum")
        if enum is not None and (not isinstance(enum, list) or not all(isinstance(v, str) for v in enum)):
            raise GenError("路由 %s 参数 %s 的 enum 只支持字符串" % (name, pname))
        for k in ("minLength", "maxLength"):
            if k in p and (not isinstance(p[k], int) or isinstance(p[k], bool)):
                raise GenError("路由 %s 参数 %s 的 %s 不是整数" % (name, pname, k))
        out.append("new RouteParamSpec(%s, RouteParamType.%s, %s, %s, %s, %s)" % (
            ts_str(pname), upper_snake(ptype),
            "null" if enum is None else "[" + ", ".join(ts_str(v) for v in enum) + "]",
            "null" if "minLength" not in p else str(p["minLength"]),
            "null" if "maxLength" not in p else str(p["maxLength"]),
            ts_nullable_str(p.get("pattern"))))
    return out, required, additional


def gen_routes(route_entry_type, route_entry_values):
    lines = [HEADER, "// 路由表：contracts/routes.json。debug_only 路由不在这里，只生成到 src/staging（DebugRoutes）。\n"]
    lines.append("import { %s } from './ContractEnums';" % route_entry_type)
    lines.append("")
    lines.append("""export enum RouteKind {
  NATIVE = 'native',
  H5 = 'h5'
}

export enum RouteParamType {
  STRING = 'string',
  INTEGER = 'integer',
  NUMBER = 'number',
  BOOLEAN = 'boolean',
  OBJECT = 'object',
  ARRAY = 'array'
}

/** routes.json params.properties 的一项（只含契约用到的 JSON Schema 关键字；缺省为 null）。 */
export class RouteParamSpec {
  readonly name: string;
  readonly type: RouteParamType;
  readonly enumValues: string[] | null;
  readonly minLength: number | null;
  readonly maxLength: number | null;
  readonly pattern: string | null;

  constructor(name: string, type: RouteParamType, enumValues: string[] | null, minLength: number | null,
    maxLength: number | null, pattern: string | null) {
    this.name = name;
    this.type = type;
    this.enumValues = enumValues;
    this.minLength = minLength;
    this.maxLength = maxLength;
    this.pattern = pattern;
  }
}

export class RouteSpec {
  readonly name: string;
  readonly kind: RouteKind;
  readonly auth: string;
  readonly sinceHarmony: string | null;
  readonly entries: %(t)s[];
  readonly h5Path: string | null;
  readonly debugOnly: boolean;
  /** Agent 页面引导卡可打开的目标（routes.json agent_guide，缺省 false）。 */
  readonly agentGuide: boolean;
  /** 账号安全类路由的引导拒答类别（routes.json agent_guide_account：phone | delete | fund；缺省 null）。 */
  readonly agentGuideAccount: string | null;
  /** params.properties（契约顺序）。 */
  readonly params: RouteParamSpec[];
  readonly requiredParams: string[];
  /** params.additionalProperties（契约里都是 false）。 */
  readonly additionalParams: boolean;

  constructor(name: string, kind: RouteKind, auth: string, sinceHarmony: string | null, entries: %(t)s[],
    h5Path: string | null, debugOnly: boolean, agentGuide: boolean = false, agentGuideAccount: string | null = null,
    params: RouteParamSpec[] = [], requiredParams: string[] = [], additionalParams: boolean = false) {
    this.name = name;
    this.kind = kind;
    this.auth = auth;
    this.sinceHarmony = sinceHarmony;
    this.entries = entries;
    this.h5Path = h5Path;
    this.debugOnly = debugOnly;
    this.agentGuide = agentGuide;
    this.agentGuideAccount = agentGuideAccount;
    this.params = params;
    this.requiredParams = requiredParams;
    this.additionalParams = additionalParams;
  }

  param(name: string): RouteParamSpec | undefined {
    for (const p of this.params) {
      if (p.name === name) {
        return p;
      }
    }
    return undefined;
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
    lines.append("import { RouteKind, RouteParamSpec, RouteParamType, RouteSpec } from '../../main/ets/Routes';")
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


def gen_core_test_debug_routes(route_entry_type, route_entry_values):
    """debug_only 路由表的测试副本（core 本机单测按 default target 编译，拿不到 generated 的 staging 源码）。
    与 DebugRoutes 同一生成函数产出；只在 core 的 src/test，不进任何产物。"""
    lines = [HEADER, "// debug_only 路由表的测试副本（APP-02a）：core 单测在 default target 下模拟 Debug / Staging 构建注册调试路由。\n"
             "// 只在 src/test，不进产物；内容与 generated/src/staging/ets/DebugRoutes.ets 同源。\n"]
    lines.append("import { %s, RouteKind, RouteParamSpec, RouteParamType, RouteSpec } from 'generated';" % route_entry_type)
    lines.append("")
    lines.append("export class TestDebugRoutes {")
    lines.append("  static readonly all: Map<string, RouteSpec> = TestDebugRoutes.build();")
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
    lines.append("  /** component.*（DS-01）：键为去掉 component. 的点分路径，如 'button.min-height'。 */")
    lines.append("  static readonly component: Map<string, number> = DesignTokens.buildComponent();")
    lines.append("  /** focus.*（DS-01）：width、offset。 */")
    lines.append("  static readonly focus: Map<string, number> = DesignTokens.buildFocus();")
    lines.append("  /** shadow.*（DS-01）：每层 x / y / blur / spread / color / opacity；none 为空数组。 */")
    lines.append("  static readonly shadows: Map<string, ShadowLayerToken[]> = DesignTokens.buildShadows();")
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
    component = []

    def walk_numbers(node, prefix):
        for key, child in node.items():
            path = key if not prefix else prefix + "." + key
            if isinstance(child, dict) and "value" in child:
                value = child["value"]
                if not isinstance(value, (int, float)) or isinstance(value, bool):
                    raise GenError("component.%s 不是数字" % path)
                component.append((path, value))
            elif isinstance(child, dict):
                walk_numbers(child, path)

    walk_numbers(tokens["component"], "")
    lines.append("")
    lines.append("  private static buildComponent(): Map<string, number> {")
    lines.append("    const map: Map<string, number> = new Map<string, number>();")
    for k, v in component:
        lines.append("    map.set(%s, %s);" % (ts_str(k), num(v)))
    lines.append("    return map;")
    lines.append("  }")
    lines.append("")
    lines.append("  private static buildFocus(): Map<string, number> {")
    lines.append("    const map: Map<string, number> = new Map<string, number>();")
    for k, v in numbers(tokens["focus"], "focus"):
        lines.append("    map.set(%s, %s);" % (ts_str(k), num(v)))
    lines.append("    return map;")
    lines.append("  }")
    lines.append("")
    lines.append("  private static buildShadows(): Map<string, ShadowLayerToken[]> {")
    lines.append("    const map: Map<string, ShadowLayerToken[]> = new Map<string, ShadowLayerToken[]>();")
    for name, leaf in tokens["shadow"].items():
        layers = leaf.get("value")
        if not isinstance(layers, list):
            raise GenError("shadow.%s 不是数组" % name)
        parts = []
        for layer in layers:
            for f in ("x", "y", "blur", "spread", "opacity"):
                if not isinstance(layer.get(f), (int, float)) or isinstance(layer.get(f), bool):
                    raise GenError("shadow.%s.%s 不是数字" % (name, f))
            if not re.fullmatch(r"#[0-9A-Fa-f]{6}", str(layer.get("color"))):
                raise GenError("shadow.%s.color 不是 #RRGGBB" % name)
            parts.append("new ShadowLayerToken(%s, %s, %s, %s, %s, %s)" % (
                num(layer["x"]), num(layer["y"]), num(layer["blur"]), num(layer["spread"]),
                ts_str(layer["color"]), num(layer["opacity"])))
        lines.append("    map.set(%s, [%s]);" % (ts_str(name), ", ".join(parts)))
    lines.append("    return map;")
    lines.append("  }")
    lines.append("}")
    shadow_class = [
        "",
        "/** 一层阴影令牌（design-tokens.json 的 shadow.* 原值；颜色 #RRGGBB + 不透明度 0–1）。 */",
        "export class ShadowLayerToken {",
        "  readonly x: number;",
        "  readonly y: number;",
        "  readonly blur: number;",
        "  readonly spread: number;",
        "  readonly color: string;",
        "  readonly opacity: number;",
        "",
        "  constructor(x: number, y: number, blur: number, spread: number, color: string, opacity: number) {",
        "    this.x = x;",
        "    this.y = y;",
        "    this.blur = blur;",
        "    this.spread = spread;",
        "    this.color = color;",
        "    this.opacity = opacity;",
        "  }",
        "}",
        "",
    ]
    # 类声明不提升：ShadowLayerToken 必须写在 DesignTokens 前面（DesignTokens 的静态初始化要用它）。
    at = lines.index("export class DesignTokens {")
    return "\n".join(lines[:at] + shadow_class[1:] + lines[at:]) + "\n"


# ---------------------------------------------------------------- 测试数据


FORMAT_VECTORS = os.path.join("specs", "format-vectors.json")
DS_MODULE = os.path.join("common", "designsystem")


def gen_format_vectors_data():
    """specs/format-vectors.json → designsystem 本机单测可 import 的字符串常量（Local Test 读不了文件）。"""
    path = os.path.join(ROOT, FORMAT_VECTORS)
    if not os.path.isfile(path):
        raise GenError("缺 " + FORMAT_VECTORS)
    with open(path, encoding="utf-8") as f:
        text = f.read()
    try:
        json.loads(text)
    except ValueError as e:
        raise GenError("%s 不是合法 JSON：%s" % (FORMAT_VECTORS, e))
    return (HEADER.replace("来源 contract.lock", "来源 specs/format-vectors.json")
            + "// 格式向量（DS-01）：specs/format-vectors.json 全文，供 FormatVector.test.ets 解析。只在 src/test，不进产物。\n\n"
            + "export const FORMAT_VECTORS_JSON: string = " + ts_str(text) + ";\n")


ROUTER_VECTORS = os.path.join("specs", "router-vectors.json")
CORE_MODULE = os.path.join("common", "core")


def gen_vectors_data(rel, const_name, comment):
    """specs/*.json → core 本机单测可 import 的字符串常量（Local Test 读不了文件）。"""
    path = os.path.join(ROOT, rel)
    if not os.path.isfile(path):
        raise GenError("缺 " + rel)
    with open(path, encoding="utf-8") as f:
        text = f.read()
    try:
        json.loads(text)
    except ValueError as e:
        raise GenError("%s 不是合法 JSON：%s" % (rel, e))
    return (HEADER.replace("来源 contract.lock", "来源 " + rel.replace(os.sep, "/"))
            + "// " + comment + "\n\n"
            + "export const " + const_name + ": string = " + ts_str(text) + ";\n")


def gen_router_vectors_data():
    """specs/router-vectors.json（APP-02a）。"""
    return gen_vectors_data(ROUTER_VECTORS, "ROUTER_VECTORS_JSON",
                            "Router 判定向量（APP-02a）：specs/router-vectors.json 全文，供 RouterVector.test.ets 解析。"
                            "只在 src/test，不进产物。")


PRIVACY_GATE_VECTORS = os.path.join("specs", "privacy-gate-vectors.json")


def gen_privacy_gate_vectors_data():
    """specs/privacy-gate-vectors.json（APP-02b）。"""
    return gen_vectors_data(PRIVACY_GATE_VECTORS, "PRIVACY_GATE_VECTORS_JSON",
                            "隐私闸门向量（APP-02b）：specs/privacy-gate-vectors.json 全文，供 PrivacyGateVector.test.ets 解析。"
                            "只在 src/test，不进产物。")


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


# ---------------------------------------------------------------- 商店对照表与版本检查示例（APP-02c）

# 版本检查假数据的唯一标记（三端同一串；release-scan.sh 查 Release 产物里不得出现它）。
UPDATE_EXAMPLE_MARKER = "COULI_UPDATE_CHECK_EXAMPLE_MARKER_5b7e3d91c2a4"
APP_VERSION_CHECK_PATH = "/v1/app-versions/check"


def gen_app_stores():
    """specs/app-stores.yaml → AppStores（规划/03 §4.1：商店对照表由契约生成，代码里不写死商店键与打开方式）。"""
    data = load("specs/app-stores.json")
    version = data.get("version")
    stores = data.get("stores")
    if not isinstance(version, str) or not isinstance(stores, list):
        raise GenError("app-stores.json 缺 version 或 stores")
    lines = [HEADER, "// 商店对照表：specs/app-stores.yaml（APP-02c；规划/03 §4.1、BR-ID-01）。\n"
             "// 值为 null 的商店一律视为「本机打不开」（needs N-17：商店键与打开方式待接入时按官方文档填）。\n"]
    lines.append("""export class AppStoreSpec {
  /** 商店键（与 GET /v1/app-versions/check 的 default_store、stores[].store 同一套）；未定时为 null。 */
  readonly key: string | null;
  readonly name: string;
  /** client_platform：ios / android / harmony。 */
  readonly platform: string;
  /** X-Channel 取值（鸿蒙为 agc）。 */
  readonly channels: string[];
  /** Android 安装来源包名。 */
  readonly installSourcePackages: string[];
  /** 详情页的打开方式；null = 本机打不开。 */
  readonly openMethod: string | null;
  /** 详情页的目标；null = 本机打不开。 */
  readonly target: string | null;

  constructor(key: string | null, name: string, platform: string, channels: string[], installSourcePackages: string[],
    openMethod: string | null, target: string | null) {
    this.key = key;
    this.name = name;
    this.platform = platform;
    this.channels = channels;
    this.installSourcePackages = installSourcePackages;
    this.openMethod = openMethod;
    this.target = target;
  }
}
""")
    lines.append("export class AppStores {")
    lines.append("  static readonly version: string = %s;" % ts_str(version))
    lines.append("  static readonly all: AppStoreSpec[] = [")
    for index, item in enumerate(stores):
        where = "app-stores.json stores[%d]" % index
        if not isinstance(item, dict):
            raise GenError(where + " 不是对象")
        name, platform = item.get("name"), item.get("platform")
        if not isinstance(name, str) or not isinstance(platform, str):
            raise GenError(where + " 缺 name 或 platform")
        key = item.get("key")
        if key is not None and (not isinstance(key, str) or not re.fullmatch(r"[a-z0-9_]+", key)):
            raise GenError("%s 的 key 不是小写字母、数字、下划线：%r" % (where, key))
        channels = item.get("channels") or []
        packages = item.get("install_source_packages") or []
        if not all(isinstance(v, str) for v in channels) or not all(isinstance(v, str) for v in packages):
            raise GenError(where + " 的 channels / install_source_packages 不是字符串列表")
        detail = item.get("detail_page") or {}
        open_method, target = detail.get("open_method"), detail.get("target")
        for label, value in (("open_method", open_method), ("target", target)):
            if value is not None and not isinstance(value, str):
                raise GenError("%s 的 detail_page.%s 不是字符串或 null" % (where, label))
        lines.append("    new AppStoreSpec(%s, %s, %s, [%s], [%s], %s, %s)%s" % (
            ts_nullable_str(key), ts_str(name), ts_str(platform), ", ".join(ts_str(v) for v in channels),
            ", ".join(ts_str(v) for v in packages), ts_nullable_str(open_method), ts_nullable_str(target),
            "," if index < len(stores) - 1 else ""))
    lines.append("  ];")
    lines.append("")
    lines.append("  /** 某一端（ios / android / harmony）的商店。 */")
    lines.append("  static forPlatform(platform: string): AppStoreSpec[] {")
    lines.append("    return AppStores.all.filter((s: AppStoreSpec) => s.platform === platform);")
    lines.append("  }")
    lines.append("}")
    return "\n".join(lines) + "\n"


def gen_app_version_check_example():
    """openapi GET /v1/app-versions/check 的 200 响应示例 data → 调试假数据（只进 Debug / Staging）。"""
    data = load("contracts/openapi.json")
    try:
        example = data["paths"][APP_VERSION_CHECK_PATH]["get"]["responses"]["200"]["content"]["application/json"]["example"]
    except (KeyError, TypeError) as e:
        raise GenError("openapi.json 里没有 GET %s 的 200 响应示例（%r）" % (APP_VERSION_CHECK_PATH, e))
    body = example.get("data") if isinstance(example, dict) else None
    if not isinstance(body, dict):
        raise GenError("GET %s 的响应示例没有 data 对象" % APP_VERSION_CHECK_PATH)
    text = json.dumps(body, ensure_ascii=False, separators=(",", ":"))
    lines = [HEADER, "// openapi GET %s 的 200 响应示例里的 data（AppVersionCheck），原样转写（APP-02c）。\n"
             "// 只在 generated 模块的 staging target（Debug / Staging）编译：调试面板的版本检查假数据；Release 里没有，\n"
             "// release-scan 查 MARKER。\n" % APP_VERSION_CHECK_PATH]
    lines.append("export class AppVersionCheckExample {")
    lines.append("  static readonly MARKER: string = %s;" % ts_str(UPDATE_EXAMPLE_MARKER))
    lines.append("  static readonly DATA_JSON: string = %s;" % ts_str(text))
    lines.append("}")
    return "\n".join(lines) + "\n"


UPDATE_GATE_VECTORS = os.path.join("specs", "update-vectors.json")


def gen_update_gate_vectors_data():
    """specs/update-vectors.json（APP-02c）。"""
    return gen_vectors_data(UPDATE_GATE_VECTORS, "UPDATE_GATE_VECTORS_JSON",
                            "UpdateGate 向量（APP-02c）：specs/update-vectors.json 全文，供 UpdateGateVector.test.ets 解析。"
                            "只在 src/test，不进产物。")



# ---------------------------------------------------------------- 汇总

INDEX = HEADER + """// generated 模块统一导出（import { … } from 'generated'）。
// 'generated/ets/DebugOnly' 由 hvigor 按 target 选目录：staging target（Debug / Staging）→ src/staging，导出 DebugRoutes；
// default target（Release）→ src/release，只导出一个 false 标记，Release 里没有 DebugRoutes、debug_only 路由名
// 与版本检查假数据 AppVersionCheckExample（APP-02c）。

%s
export * from 'generated/ets/DebugOnly';
"""

RELEASE_DEBUG_ONLY = HEADER + """// Release（generated 模块 default target）：debug_only 路由不编译进来；DebugRoutes 只在 src/staging。

export const DEBUG_ROUTES_COMPILED: boolean = false;
"""

STAGING_DEBUG_ONLY = HEADER + """// Debug / Staging（generated 模块 staging target）：导出 debug_only 路由表与版本检查假数据（APP-02c）。

export { DebugRoutes } from './DebugRoutes';
export { AppVersionCheckExample } from './AppVersionCheckExample';

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
        os.path.join(main, "AppStores.ets"): gen_app_stores(),
        os.path.join(MODULE, "src", "staging", "ets", "AppVersionCheckExample.ets"): gen_app_version_check_example(),
        os.path.join(MODULE, "src", "staging", "ets", "DebugOnly.ets"): STAGING_DEBUG_ONLY,
        os.path.join(MODULE, "src", "release", "ets", "DebugOnly.ets"): RELEASE_DEBUG_ONLY,
        os.path.join(MODULE, "src", "test", "ContractSnapshotData.ets"): gen_snapshot_data(),
        os.path.join(DS_MODULE, "src", "test", "FormatVectorsData.ets"): gen_format_vectors_data(),
        os.path.join(CORE_MODULE, "src", "test", "RouterVectorsData.ets"): gen_router_vectors_data(),
        os.path.join(CORE_MODULE, "src", "test", "PrivacyGateVectorsData.ets"): gen_privacy_gate_vectors_data(),
        os.path.join(CORE_MODULE, "src", "test", "UpdateGateVectorsData.ets"): gen_update_gate_vectors_data(),
        os.path.join(CORE_MODULE, "src", "test", "TestDebugRoutes.ets"):
            gen_core_test_debug_routes(route_entry_type, route_entry_values),
    }
    outputs[os.path.join(MODULE, "Index.ets")] = INDEX % index_exports(outputs, main)
    return outputs


def index_exports(outputs, main):
    lines = []
    for name in ("ContractEnums", "ErrorCodes", "Routes", "BridgeMethods", "DefaultTexts", "DesignTokens", "AppStores"):
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
