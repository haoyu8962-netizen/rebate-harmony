#!/usr/bin/env python3
"""DS-02 浅 / 深两套主题生成器（只用 Python 3 标准库）。

用法：
    python3 tools/codegen/gen_theme.py           # 重新生成
    python3 tools/codegen/gen_theme.py --check   # 只查漂移（有漂移退出 1 并列出文件）；tools/ci/lint.py 检查仓库时会调用

来源：specs/design-tokens.v0.4.0.json——规划仓库 design/tokens/design-tokens.json v0.4.0（origin/main 49bb4ad，PR #144「深色令牌进唯一源」）
的逐字节副本。contract.lock 仍锁 v0.3.0（contracts/snapshot/design/design-tokens.json，generated/DesignTokens 继续由它生成）；
DS-02 不动契约锁，浅 / 深两套颜色、阴影与 T1–T12 组件令牌先从这份副本生成。契约锁升到含 v0.4.0 的提交后，把来源改成契约快照、删掉副本。
gen.py 与 verify.sh 属测试作者冻结的文件（DS-02 tests-harmony-v1.sha256），所以本生成器单列，--check 由 lint.py 带上。

产出：
    common/designsystem/src/main/resources/base/element/color.json   每个颜色令牌一项 color_<路径>，取 value（浅色）
    common/designsystem/src/main/resources/dark/element/color.json   同名，取 dark（深色）；八位 #RRGGBBAA 换成鸿蒙 #AARRGGBB
                                                                     另有阴影颜色 shadow_card / shadow_floating（颜色 × 不透明度）
    entry/src/main/resources/dark/element/color.json                 启动窗口底色的深色值（= background.canvas.dark）
    common/designsystem/src/main/ets/theme/CouliThemeTokens.ets      颜色两套、阴影两套、component.* 数值（纯数据，无 $r）
"""

import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SOURCE = os.path.join("specs", "design-tokens.v0.4.0.json")
DS_MAIN = os.path.join("common", "designsystem", "src", "main")
HEADER = "// 生成物，禁止手改；来源 specs/design-tokens.v0.4.0.json（tools/codegen/gen_theme.py 生成）\n"


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
        raise GenError("缺令牌源副本 " + SOURCE)
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if data.get("metadata", {}).get("version") != "0.4.0":
        raise GenError("令牌源副本不是 v0.4.0")
    return data


def colors(tokens):
    rows = []
    for path, leaf in leaves(tokens["color"]):
        if leaf.get("type") != "color":
            raise GenError("color.%s 的 type 不是 color" % path)
        if "dark" not in leaf:
            raise GenError("color.%s 缺 dark（v0.4.0 每个颜色令牌都有深色值）" % path)
        rows.append((path, harmony_hex(leaf["value"], "color." + path), harmony_hex(leaf["dark"], "color." + path + ".dark")))
    return rows


def shadow_resources(tokens):
    """阴影颜色资源 shadow_<名>：颜色 × 不透明度合成 #AARRGGBB（只取第一层；令牌每个阴影都只有一层），两套各一份。
    阴影不是颜色令牌，资源名不带 color_ 前缀（DS-02 资源测试只核 color_*）。"""
    rows = []
    for name, leaf in tokens["shadow"].items():
        pair = []
        for layers in (leaf["value"], leaf.get("dark", leaf["value"])):
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
                                                            shadow_layers(leaf.get("dark", leaf["value"]), "shadow." + name + ".dark")))
    out += ["  ];", "  /** component.*：键为去掉 component. 的点分路径（如 'checkbox.size'），dimension 按 vp、number 原样。 */",
            "  static readonly component: Map<string, number> = CouliThemeTokens.buildComponent();", "",
            "  private static buildComponent(): Map<string, number> {",
            "    const map: Map<string, number> = new Map<string, number>();"]
    for path, leaf in leaves(tokens["component"]):
        if leaf.get("type") not in ("dimension", "number"):
            raise GenError("component.%s 的 type 不是 dimension / number" % path)
        out.append("    map.set(%s, %s);" % (ts(path), num(leaf["value"])))
    out += ["    return map;", "  }", "}", ""]
    return "\n".join(out)


def build_outputs():
    data = load()
    rows = colors(data["tokens"])
    shadows = shadow_resources(data["tokens"])
    canvas = [row for row in rows if row[0] == "background.canvas"]
    if len(canvas) != 1:
        raise GenError("缺 color.background.canvas")
    entry_dark = '{\n  "color": [\n    {\n      "name": "start_window_background",\n      "value": %s\n    }\n  ]\n}\n' % ts(canvas[0][2])
    return {
        os.path.join(DS_MAIN, "resources", "base", "element", "color.json"): color_json(rows, 0, shadows),
        os.path.join(DS_MAIN, "resources", "dark", "element", "color.json"): color_json(rows, 1, shadows),
        os.path.join("entry", "src", "main", "resources", "dark", "element", "color.json"): entry_dark,
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
                print("gen_theme.py --check：生成物与令牌源副本不一致（运行 python3 tools/codegen/gen_theme.py）：", file=sys.stderr)
                for rel in drift:
                    print("  " + rel, file=sys.stderr)
                return 1
            print("gen_theme.py --check：%d 个生成物与令牌源副本一致" % len(build_outputs()))
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
