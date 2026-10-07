#!/usr/bin/env python3
"""桥一致性页结果断言（APP-04 共性 44 / 55，I-R2-05，03 §5.5；F-HM-07，harmony-review-r1 R1-12）。只用 Python 3 标准库。

一致性 UI 测试不能只截图：把一致性页 window.__RESULT__ 导出的 JSON（schema couli.bridge-conformance/1，cases 数组，每条有
id、method、category、trigger、expect、outcome、pass）交给本脚本，按具体用例和它的预期结果逐条判定：

- 先按 expect 与 outcome 重新算一次结论（与一致性页 result.ts passes() 同一规则：{code} 要求失败且错误码相同，{ok} 只比成败），
  页面报的 pass 与之不符 → 失败（不信任页面自报）；
- 结论为通过：通过；
- 结论为不通过：只有「本端暂不支持」名单里的方法、category 为 normal 的那一条（<method>/normal）且回了规定的错误码（90001），
  按「未实现」断言通过。同一方法的 bad_params、no_gesture、negative（登录、白名单 trade_only 等）、timeout 用例不豁免——
  未实现的方法也要先做参数、登录、手势、白名单检查，这些用例不通过一律失败；
  登记在 environment_limited 的确切用例 id（受环境限制，写明原因）→ 未完成；其余一律失败；
- 没有结论（pass 为 null / 缺失，如要点击而没点、要 harness 触发）：登记在 environment_limited（确切 id 或通配模式）→ 未完成；
  否则失败；
- 结果集本身：schema 不对、cases 为空、有重复 id、页面报告了未知用例（unknown_cases）→ 输入出错（退出 2）；按契约快照算出的
  必测用例（每个本端方法的 normal / bad_params / no_gesture / negative/logged_out / timeout、本端未发布方法的 unsupported、未知
  方法、trade_only 白名单、平台链接与分享域名负面用例、子框架探测）缺任何一条 → 失败。

用法：
    python3 tools/ci/conformance-assert.py <result.json> [--expectations <json>]   退出 0 = 无失败；1 = 有失败；2 = 输入出错
    python3 tools/ci/conformance-assert.py --self-test                               用内置样例证明断言有牙齿
期望文件（缺省 tools/ci/conformance-expectations.json）：
    {"unsupported": {"methods": [...], "code": 90001},
     "environment_limited": {"<case id 或 fnmatch 模式>": "<原因>"}}
    通配模式（含 * ? [）只用于「没有结论」的用例；有结论但失败的用例只能按确切 id 登记。
"""

import fnmatch
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
DEFAULT_EXPECTATIONS = os.path.join(HERE, "conformance-expectations.json")
SNAPSHOT = os.path.join(ROOT, "contracts", "snapshot", "contracts")
RESULT_SCHEMA = "couli.bridge-conformance/1"
PLATFORM = "harmony"
PLATFORMS = ("ios", "android", "harmony")

# 一致性页 cases.ts（rebate-platform 9cd1e6f apps/h5/src/entries/conformance/cases.ts）里的探测常量。
UNKNOWN_METHOD = "conformance.notAMethod"
FRAME_CASE_ID = "frame/negative/subframe"
PLATFORM_LINK_SAMPLE_HOSTS = ("taobao.example.test",)
SHARE_DOMAIN_SAMPLE_HOSTS = ("s.example.test",)
PLATFORM_LINK_VARIANTS = ("base", "host_case", "trailing_dot", "default_port", "percent_host", "percent_path")


class InputError(ValueError):
    pass


def required_case_ids(snapshot_dir=SNAPSHOT, platform=PLATFORM):
    """按契约快照（bridge.schema.json、apps.json）复算一致性页在本端必然出现的用例 id（与 cases.ts methodEntries 同规则）。"""
    with open(os.path.join(snapshot_dir, "bridge.schema.json"), encoding="utf-8") as f:
        bridge = json.load(f)
    with open(os.path.join(snapshot_dir, "apps.json"), encoding="utf-8") as f:
        apps = json.load(f).get("apps", {})
    openable = any(not app.get("trade_only") for app in apps.values())
    ids = set()
    for method, meta in bridge["methods"].items():
        since = meta.get("since", {})
        missing = [p for p in PLATFORMS if since.get(p) is None]
        if len(missing) == len(PLATFORMS):
            ids.add("%s/unsupported" % method)
            continue
        if platform in missing:
            ids.add("%s/unsupported/%s" % (method, platform))
            continue
        gesture = meta.get("level") == "L2" or meta.get("gesture_required") is True
        if method != "ext.openApp" or openable:
            ids.add("%s/normal" % method)
        if meta.get("model") == "async" and meta.get("timeout_ms") is not None:
            ids.add("%s/timeout" % method)
        if (meta.get("params") or {}).get("properties"):
            ids.add("%s/bad_params" % method)
        if gesture:
            ids.add("%s/no_gesture" % method)
        if meta.get("level") in ("L1", "L2"):
            ids.add("%s/negative/logged_out" % method)
    ids.add("%s/unsupported" % UNKNOWN_METHOD)
    for target, app in apps.items():
        if app.get("trade_only"):
            ids.add("ext.openApp/negative/trade_only/%s" % target)
    for host in PLATFORM_LINK_SAMPLE_HOSTS:
        for variant in PLATFORM_LINK_VARIANTS:
            ids.add("ext.openBrowser/negative/platform_link/%s/%s" % (host, variant))
            ids.add("share.open/negative/platform_link/%s/%s" % (host, variant))
    for host in SHARE_DOMAIN_SAMPLE_HOSTS:
        ids.add("share.open/negative/share_domain/%s/not_share_page" % host)
    ids.add(FRAME_CASE_ID)
    return ids


def passes(expect, outcome):
    """一致性页 result.ts passes()：{code} 要求失败且错误码相同；{ok} 只比成败。"""
    if not isinstance(expect, dict) or not isinstance(outcome, dict):
        return False
    if "code" in expect:
        return outcome.get("ok") is False and outcome.get("code") == expect["code"]
    return outcome.get("ok") == expect.get("ok")


def _is_pattern(key):
    return any(ch in key for ch in "*?[")


def evaluate(result, expectations, required=None):
    """返回 (passed, unimplemented, not_done, failures)。结果集本身不合格抛 InputError。"""
    if not isinstance(result, dict) or result.get("schema") != RESULT_SCHEMA:
        raise InputError("schema 不是 %s" % RESULT_SCHEMA)
    cases = result.get("cases")
    if not isinstance(cases, list) or len(cases) == 0:
        raise InputError("result.cases 不是非空数组")
    unknown = result.get("unknown_cases") or []
    if unknown:
        raise InputError("页面报告了未知用例：%s" % ", ".join(map(str, unknown)))
    unsupported = expectations.get("unsupported", {})
    unsupported_methods = set(unsupported.get("methods", []))
    unsupported_code = unsupported.get("code", 90001)
    limited = expectations.get("environment_limited", {})
    exact_limited = {k: v for k, v in limited.items() if not _is_pattern(k)}
    pattern_limited = {k: v for k, v in limited.items() if _is_pattern(k)}

    passed, unimplemented, not_done, failures = [], [], [], []
    seen = set()
    for case in cases:
        if not isinstance(case, dict) or not isinstance(case.get("id"), str):
            raise InputError("用例缺 id：%r" % (case,))
        cid = case["id"]
        if cid in seen:
            raise InputError("重复的用例 id：%s" % cid)
        seen.add(cid)
        method = case.get("method")
        category = case.get("category")
        reported = case.get("pass")
        outcome = case.get("outcome")
        if reported is None or outcome is None:
            reason = exact_limited.get(cid)
            if reason is None:
                for pattern, why in pattern_limited.items():
                    if fnmatch.fnmatchcase(cid, pattern):
                        reason = why
                        break
            if reason is not None:
                not_done.append("%s（%s）" % (cid, reason))
            else:
                failures.append("%s：没有结论（trigger=%s），也没有登记为受环境限制" % (cid, case.get("trigger")))
            continue
        verdict = passes(case.get("expect"), outcome)
        if reported is not verdict:
            failures.append("%s：页面报 pass=%r，按 expect 与 outcome 应为 %r" % (cid, reported, verdict))
            continue
        if verdict:
            passed.append(cid)
        elif (category == "normal" and cid == "%s/normal" % method and method in unsupported_methods
              and outcome.get("ok") is False and outcome.get("code") == unsupported_code):
            unimplemented.append(cid)
        elif cid in exact_limited:
            not_done.append("%s（%s）" % (cid, exact_limited[cid]))
        else:
            failures.append("%s：期望 %s，实际 %s" % (cid, json.dumps(case.get("expect"), ensure_ascii=False),
                                                  json.dumps(outcome, ensure_ascii=False)))
    if required is not None:
        for cid in sorted(required - seen):
            failures.append("%s：必测用例缺失" % cid)
    return passed, unimplemented, not_done, failures


def run(result_path, exp_path, required):
    """断言一份结果文件，返回退出码（0 无失败，1 有失败，2 输入出错）。"""
    try:
        with open(result_path, encoding="utf-8") as f:
            result = json.load(f)
        with open(exp_path, encoding="utf-8") as f:
            expectations = json.load(f)
        passed, unimplemented, not_done, failures = evaluate(result, expectations, required)
    except (OSError, ValueError) as e:
        print("conformance-assert：输入出错：%s" % e, file=sys.stderr)
        return 2
    for item in not_done:
        print("  未完成 " + item)
    for item in failures:
        print("  失败 " + item)
    print("conformance-assert：通过 %d、未实现按规定错误码 %d、未完成 %d、失败 %d" % (
        len(passed), len(unimplemented), len(not_done), len(failures)))
    return 1 if failures else 0


# ---------------------------------------------------------------- 自测

def _row(cid, ok=True, code=None, expect=None, verdict=None):
    method, category = cid.split("/")[0], cid.split("/")[1]
    if expect is None:
        expect = {"ok": True} if category == "normal" else ({"ok": False} if cid == FRAME_CASE_ID else {"code": 90002})
    outcome = {"ok": True} if ok else {"ok": False, "code": code}
    if verdict is None:
        verdict = passes(expect, outcome)
    return {"id": cid, "method": method, "category": category, "trigger": "auto", "expect": expect,
            "outcome": outcome, "pass": verdict}


def _all_passing(required):
    """每条必测用例都按预期通过的结果集（负面用例回各自的预期错误码）。"""
    rows = []
    for cid in sorted(required):
        category = cid.split("/")[1]
        if category == "normal":
            rows.append(_row(cid))
        elif cid == FRAME_CASE_ID:
            rows.append(_row(cid, ok=False, code=90403, expect={"ok": False}))
        else:
            code = {"bad_params": 90002, "no_gesture": 90404, "timeout": 90003, "unsupported": 90001}.get(category)
            if code is None:
                code = 90401 if cid.endswith("/logged_out") else 90403
            rows.append(_row(cid, ok=False, code=code, expect={"code": code}))
    return {"schema": RESULT_SCHEMA, "status": "done", "bridge_present": True, "cases": rows, "unknown_cases": []}


def _replace(result, cid, row):
    out = json.loads(json.dumps(result))
    out["cases"] = [row if c["id"] == cid else c for c in out["cases"]]
    return out


def self_test():
    required = required_case_ids()
    checks = []

    def check(name, got, want):
        checks.append((name, got, want))

    # 必测用例集要覆盖评审给的方法与类别。
    for cid in ("share.open/normal", "share.open/bad_params", "ext.openApp/negative/trade_only/taobao",
                "auth.getUser/negative/logged_out", FRAME_CASE_ID, "%s/unsupported" % UNKNOWN_METHOD):
        check("必测含 " + cid, cid in required, True)

    expectations = {"unsupported": {"methods": ["share.open"], "code": 90001},
                    "environment_limited": {"auth.getUser/normal": "本机没有后端", "*/timeout": "harness 触发"}}
    base = _all_passing(required)
    check("全部通过", len(evaluate(base, expectations, required)[3]), 0)

    # 未实现方法的 normal 回 90001：按未实现通过。
    unimpl = _replace(base, "share.open/normal", _row("share.open/normal", ok=False, code=90001))
    p, u, n, f = evaluate(unimpl, expectations, required)
    check("normal 回 90001 按未实现", (len(u), len(f)), (1, 0))

    # 评审反例（R1-12）：share.open/bad_params 期望 90002、实际 90001——不豁免，必须失败。
    bad = _replace(base, "share.open/bad_params", _row("share.open/bad_params", ok=False, code=90001,
                                                       expect={"code": 90002}))
    check("bad_params 回 90001 判失败", len(evaluate(bad, expectations, required)[3]), 1)

    # 其余负面用例同样不豁免；页面自报 pass 与 expect/outcome 不符也失败；harness 用例无结论按通配登记为未完成。
    trade = "ext.openApp/negative/trade_only/taobao"
    cases = [
        ("trade_only 回 90001", _replace(base, trade, _row(trade, ok=False, code=90001, expect={"code": 90403}))),
        ("normal 回 90500", _replace(unimpl, "share.open/normal", _row("share.open/normal", ok=False, code=90500))),
        ("自报 pass 不实", _replace(base, "app.getEnv/normal", _row("app.getEnv/normal", ok=False, code=90500,
                                                                verdict=True))),
        ("无结论未登记", _replace(base, "ui.toast/normal", dict(_row("ui.toast/normal"), **{"pass": None,
                                                                                         "outcome": None}))),
    ]
    for name, result in cases:
        check(name, len(evaluate(result, expectations, required)[3]), 1)
    timeout_id = sorted(c for c in required if c.endswith("/timeout"))[0]
    pending = _replace(base, timeout_id, dict(_row(timeout_id), **{"pass": None, "outcome": None}))
    check("harness 无结论按通配未完成", (len(evaluate(pending, expectations, required)[2]),
                                  len(evaluate(pending, expectations, required)[3])), (1, 0))
    # 通配只管没有结论的：有结论的失败不能被通配豁免。
    failed_timeout = _replace(base, timeout_id, _row(timeout_id, ok=True, expect={"code": 90003}))
    check("通配不豁免有结论的失败", len(evaluate(failed_timeout, expectations, required)[3]), 1)
    # 缺必测用例。
    missing = json.loads(json.dumps(base))
    missing["cases"] = [c for c in missing["cases"] if c["id"] != "share.open/bad_params"]
    check("缺必测用例判失败", len(evaluate(missing, expectations, required)[3]), 1)

    # 结果集本身不合格：空、schema 不对、重复 id、未知用例 → 输入出错。
    for name, broken in (("空结果集", dict(base, cases=[])), ("schema 不对", dict(base, schema="x")),
                         ("重复 id", dict(base, cases=base["cases"] + base["cases"][:1])),
                         ("未知用例", dict(base, unknown_cases=["nope/normal"]))):
        try:
            evaluate(broken, expectations, required)
            check(name, "没有报错", "InputError")
        except InputError:
            check(name, "InputError", "InputError")

    # 端到端：脚本本身对评审反例必须非零退出，对全部通过的结果集退出 0（子进程跑真正的命令行入口）。
    with tempfile.TemporaryDirectory(prefix="conformance-assert-") as tmp:
        exp_path = os.path.join(tmp, "exp.json")
        with open(exp_path, "w", encoding="utf-8") as f:
            json.dump(expectations, f)
        for name, result, want in (("命令行：评审反例非零退出", bad, 1), ("命令行：全部通过退出 0", base, 0),
                                   ("命令行：空结果集退出 2", dict(base, cases=[]), 2)):
            path = os.path.join(tmp, "result.json")
            with open(path, "w", encoding="utf-8") as f:
                json.dump(result, f)
            code = subprocess.run([sys.executable, os.path.abspath(__file__), path, "--expectations", exp_path],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
            check(name, code, want)

    wrong = [(n, g, w) for n, g, w in checks if g != w]
    if wrong:
        for name, got, want in wrong:
            print("conformance-assert 自测失败：%s：得到 %r，应为 %r" % (name, got, want), file=sys.stderr)
        return 1
    print("conformance-assert 自测：%d 项断言全部符合（必测用例 %d 条）" % (len(checks), len(required)))
    return 0


def main(argv):
    args = argv[1:]
    if args == ["--self-test"]:
        return self_test()
    if not args:
        print(__doc__, file=sys.stderr)
        return 2
    exp_path = DEFAULT_EXPECTATIONS
    if len(args) == 3 and args[1] == "--expectations":
        exp_path = args[2]
    elif len(args) != 1:
        print("用法：conformance-assert.py <result.json> [--expectations <json>]", file=sys.stderr)
        return 2
    try:
        required = required_case_ids()
    except (OSError, ValueError, KeyError) as e:
        print("conformance-assert：读契约快照出错：%s" % e, file=sys.stderr)
        return 2
    return run(args[0], exp_path, required)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
