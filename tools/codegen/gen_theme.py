#!/usr/bin/env python3
"""DS-02 浅 / 深两套主题生成器（只用 Python 3 标准库）。

用法：
    python3 tools/codegen/gen_theme.py           # 重新生成
    python3 tools/codegen/gen_theme.py --check   # 只查漂移（有漂移退出 1 并列出文件）；tools/ci/lint.py 检查仓库时会调用

来源：锁定快照 contracts/snapshot/design/design-tokens.json（contract.lock 的 design_tokens，tools/contracts/sync.sh 产出）——
与 generated/DesignTokens 同一份、同一条链路（TOKENS-PIPE）。gen.py 的 build_outputs 原样纳入本模块全部产物，gen.py --check
一次覆盖；本模块保留 check() 供 tools/ci/lint.py 的 HM-LINT-11 调用。组件尺寸只在 DesignTokens.component 一份，这里不再输出。

产出：
    common/designsystem/src/main/resources/base/element/color.json   每个颜色令牌一项 color_<路径>，取 value（浅色）
    common/designsystem/src/main/resources/dark/element/color.json   同名，取 dark（深色）；八位 #RRGGBBAA 换成鸿蒙 #AARRGGBB
                                                                     另有阴影颜色 shadow_card / shadow_floating（颜色 × 不透明度）
    entry/src/main/resources/base/element/color.json                 启动窗口底色的浅色值（= background.canvas.value）
    entry/src/main/resources/dark/element/color.json                 启动窗口底色的深色值（= background.canvas.dark）
    common/designsystem/src/main/ets/theme/CouliThemeTokens.ets      颜色两套、阴影两套（鸿蒙 #AARRGGBB 派生；纯数据，无 $r）
"""

import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SOURCE = os.path.join("contracts", "snapshot", "design", "design-tokens.json")
DS_MAIN = os.path.join("common", "designsystem", "src", "main")
HEADER = "// 生成物，禁止手改；来源 contracts/snapshot/design/design-tokens.json（锁定快照；tools/codegen/gen_theme.py 生成）\n"


class GenError(Exception):
    pass


def leaves(node, prefix=""):
    for key, value in node.items():
        path = prefix + key
        if isinstance(value, dict) and "type" in value:
            yield path, value
        elif isinstance(value, dict):
            yield from leaves(value, path + ".")


def harmony_hex(value, where):
    if not isinstance(value, str) or not re.fullmatch(r"#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?", value):
        raise GenError("%s 不是 #RRGGBB / #RRGGBBAA：%r" % (where, value))
    value = value.upper()
    # 令牌源八位是 CSS 的 #RRGGBBAA；鸿蒙资源与 ResourceColor 字符串是 #AARRGGBB（tokens README「浅 / 深两套取值」）。
    return "#" + value[7:9] + value[1:7] if len(value) == 9 else value


def resource_name(path):
    return "color_" + path.replace(".", "_").replace("-", "_")


def ts(value):
    return json.dumps(value, ensure_ascii=False)


def num(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise GenError("不是数字：%r" % (value,))
    return str(int(value)) if float(value).is_integer() else repr(value)


def load():
    path = os.path.join(ROOT, SOURCE)
    if not os.path.isfile(path):
        raise GenError("缺锁定快照 " + SOURCE + "（先跑 tools/contracts/sync.sh）")
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def colors(tokens):
    rows = []
    for path, leaf in leaves(tokens["color"]):
        if leaf.get("type") != "color":
            raise GenError("color.%s 的 type 不是 color" % path)
        if "dark" not in leaf:
            raise GenError("color.%s 缺 dark（不回落浅色）" % path)
        rows.append((path, harmony_hex(leaf["value"], "color." + path), harmony_hex(leaf["dark"], "color." + path + ".dark")))
    return rows


def dark_layers(name, leaf):
    """shadow.<名> 的深色层：有层的阴影必须带 dark（不回落浅色）；none 这类空数组取自己的 value。"""
    if leaf["value"] and "dark" not in leaf:
        raise GenError("shadow.%s 缺 dark（不回落浅色）" % name)
    return leaf.get("dark", leaf["value"])


def shadow_resources(tokens):
    """阴影颜色资源 shadow_<名>：颜色 × 不透明度合成 #AARRGGBB（只取第一层；令牌每个阴影都只有一层），两套各一份。
    阴影不是颜色令牌，资源名不带 color_ 前缀（DS-02 资源测试只核 color_*）。"""
    rows = []
    for name, leaf in tokens["shadow"].items():
        pair = []
        for layers in (leaf["value"], dark_layers(name, leaf)):
            if not layers:
                break
            layer = layers[0]
            alpha = round(float(layer["opacity"]) * 255)
            pair.append("#%02X%s" % (alpha, str(layer["color"]).upper()[1:]))
        if len(pair) == 2:
            rows.append(("shadow_" + name.replace("-", "_"), pair[0], pair[1]))
    return rows


def color_json(rows, index, extra=()):
    items = ['    {\n      "name": %s,\n      "value": %s\n    }' % (ts(resource_name(row[0])), ts(row[1 + index]))
             for row in rows]
    items += ['    {\n      "name": %s,\n      "value": %s\n    }' % (ts(row[0]), ts(row[1 + index])) for row in extra]
    return '{\n  "color": [\n' + ",\n".join(items) + "\n  ]\n}\n"


def shadow_layers(layers, where):
    if not isinstance(layers, list):
        raise GenError(where + " 不是数组")
    parts = []
    for layer in layers:
        if not re.fullmatch(r"#[0-9A-Fa-f]{6}", str(layer.get("color"))):
            raise GenError(where + ".color 不是 #RRGGBB")
        parts.append("new ThemeShadowLayer(%s, %s, %s, %s, %s, %s)" % (
            num(layer["x"]), num(layer["y"]), num(layer["blur"]), num(layer["spread"]), ts(layer["color"]),
            num(layer["opacity"])))
    return "[" + ", ".join(parts) + "]"


def gen_tokens_ets(data, rows):
    tokens = data["tokens"]
    out = [HEADER.rstrip("\n"),
           "// 浅色 = value、深色 = dark；颜色键为去掉 color. 的点分路径，取值是鸿蒙 #RRGGBB / #AARRGGBB。",
           "// 纯数据：不引用资源、不依赖 Context，主题映射与本机单测都从这里读（F-HM-57）。", "",
           "/** 一层阴影令牌（shadow.*：x / y / blur / spread 为逻辑单位，color 为 #RRGGBB，opacity 0–1）。 */",
           "export class ThemeShadowLayer {",
           "  readonly x: number;", "  readonly y: number;", "  readonly blur: number;", "  readonly spread: number;",
           "  readonly color: string;", "  readonly opacity: number;", "",
           "  constructor(x: number, y: number, blur: number, spread: number, color: string, opacity: number) {",
           "    this.x = x;", "    this.y = y;", "    this.blur = blur;", "    this.spread = spread;", "    this.color = color;",
           "    this.opacity = opacity;", "  }", "}", "",
           "/** 一个颜色令牌的两套取值。 */",
           "export class ThemeColorToken {",
           "  readonly key: string;", "  readonly light: string;", "  readonly dark: string;", "",
           "  constructor(key: string, light: string, dark: string) {",
           "    this.key = key;", "    this.light = light;", "    this.dark = dark;", "  }", "}", "",
           "/** 一个阴影令牌的两套取值（none 为空数组）。 */",
           "export class ThemeShadowToken {",
           "  readonly key: string;", "  readonly light: ThemeShadowLayer[];", "  readonly dark: ThemeShadowLayer[];", "",
           "  constructor(key: string, light: ThemeShadowLayer[], dark: ThemeShadowLayer[]) {",
           "    this.key = key;", "    this.light = light;", "    this.dark = dark;", "  }", "}", "",
           "export class CouliThemeTokens {",
           "  static readonly version: string = %s;" % ts(data["metadata"]["version"]),
           "  static readonly colors: ThemeColorToken[] = [",
           ]
    for path, light, dark in rows:
        out.append("    new ThemeColorToken(%s, %s, %s)," % (ts(path), ts(light), ts(dark)))
    out += ["  ];", "  static readonly shadows: ThemeShadowToken[] = ["]
    for name, leaf in tokens["shadow"].items():
        out.append("    new ThemeShadowToken(%s, %s, %s)," % (ts(name), shadow_layers(leaf["value"], "shadow." + name),
                                                            shadow_layers(dark_layers(name, leaf), "shadow." + name + ".dark")))
    out += ["  ];", "}", ""]
    return "\n".join(out)


def build_outputs():
    data = load()
    rows = colors(data["tokens"])
    shadows = shadow_resources(data["tokens"])
    canvas = [row for row in rows if row[0] == "background.canvas"]
    if len(canvas) != 1:
        raise GenError("缺 color.background.canvas")
    entry = '{\n  "color": [\n    {\n      "name": "start_window_background",\n      "value": %s\n    }\n  ]\n}\n'
    return {
        os.path.join(DS_MAIN, "resources", "base", "element", "color.json"): color_json(rows, 0, shadows),
        os.path.join(DS_MAIN, "resources", "dark", "element", "color.json"): color_json(rows, 1, shadows),
        os.path.join("entry", "src", "main", "resources", "base", "element", "color.json"): entry % ts(canvas[0][1]),
        os.path.join("entry", "src", "main", "resources", "dark", "element", "color.json"): entry % ts(canvas[0][2]),
        os.path.join(DS_MAIN, "ets", "theme", "CouliThemeTokens.ets"): gen_tokens_ets(data, rows),
    }


def check(root=ROOT):
    """返回漂移的文件（相对路径）；空表示一致。"""
    drift = []
    for rel, text in sorted(build_outputs().items()):
        path = os.path.join(root, rel)
        if not os.path.isfile(path):
            drift.append(rel + "（缺失）")
            continue
        with open(path, encoding="utf-8", newline="") as f:
            if f.read() != text:
                drift.append(rel)
    return drift


def main(argv):
    if len(argv) > 1 and argv[1] != "--check":
        print("用法：gen_theme.py [--check]", file=sys.stderr)
        return 2
    try:
        if len(argv) > 1:
            drift = check()
            if drift:
                print("gen_theme.py --check：生成物与锁定快照不一致（运行 python3 tools/codegen/gen_theme.py）：", file=sys.stderr)
                for rel in drift:
                    print("  " + rel, file=sys.stderr)
                return 1
            print("gen_theme.py --check：%d 个生成物与锁定快照一致" % len(build_outputs()))
            return 0
        outputs = build_outputs()
    except GenError as e:
        print("gen_theme.py: " + str(e), file=sys.stderr)
        return 1
    for rel, text in outputs.items():
        path = os.path.join(ROOT, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
    print("gen_theme.py：已生成 %d 个文件" % len(outputs))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
