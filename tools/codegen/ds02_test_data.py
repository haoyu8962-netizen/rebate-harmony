"""DS-02 独立测试期望；不读取产品目录清单，不产出产品代码。"""
import csv
import hashlib
import json
from pathlib import Path


def leaves(node, prefix=""):
    for key, value in node.items():
        path = prefix + key
        if "type" in value:
            yield path, value
        else:
            yield from leaves(value, path + ".")


def argb(value):
    return "#" + value[7:9] + value[1:7] if len(value) == 9 else value


def build_test_outputs(root):
    fixtures = Path(root) / "tools/ci/ds02/fixtures"
    source = fixtures / "design-tokens.v0.4.0.json"
    tokens = json.loads(source.read_text())["tokens"]
    quote = lambda value: json.dumps(value, ensure_ascii=False)
    lines = ["// 生成物，禁止手改；tools/codegen/gen.py；仅测试数据。",
             "// v0.4.0 原件 SHA256: " + hashlib.sha256(source.read_bytes()).hexdigest(),
             "export class ExpectedColor {",
             "  key: string; light: string; dark: string;",
             "  constructor(key: string, light: string, dark: string) {",
             "    this.key = key; this.light = light; this.dark = dark;",
             "  }", "}", "export const EXPECTED_COLORS: ExpectedColor[] = ["]
    for key, token in leaves(tokens):
        if token["type"] == "color":
            lines.append("  new ExpectedColor(%s, %s, %s)," % (
                quote(key.removeprefix("color.")), quote(argb(token["value"])), quote(argb(token["dark"]))))
    lines += ["];", "export class ExpectedShadowLayer {",
              "  x: number; y: number; blur: number; spread: number; color: string; opacity: number;",
              "  constructor(x: number, y: number, blur: number, spread: number, color: string, opacity: number) {",
              "    this.x = x; this.y = y; this.blur = blur; this.spread = spread; this.color = color; this.opacity = opacity;",
              "  }", "}", "export class ExpectedShadow {",
              "  key: string; light: ExpectedShadowLayer[]; dark: ExpectedShadowLayer[];",
              "  constructor(key: string, light: ExpectedShadowLayer[], dark: ExpectedShadowLayer[]) {",
              "    this.key = key; this.light = light; this.dark = dark;", "  }", "}",
              "export const EXPECTED_SHADOWS: ExpectedShadow[] = ["]
    def shadow_array(layers):
        return "[" + ", ".join("new ExpectedShadowLayer(%s)" % ", ".join(quote(layer[k])
            for k in ("x", "y", "blur", "spread", "color", "opacity")) for layer in layers) + "]"
    for key, token in leaves(tokens):
        if token["type"] == "shadow":
            lines.append("  new ExpectedShadow(%s, %s, %s)," % (quote(key.removeprefix("shadow.")),
                shadow_array(token["value"]), shadow_array(token.get("dark", token["value"])) ))
    lines += ["];", "export class ExpectedCase {",
              "  component: string; variant: string; state: string; kinds: string[];",
              "  constructor(component: string, variant: string, state: string, kinds: string[]) {",
              "    this.component = component; this.variant = variant; this.state = state; this.kinds = kinds;",
              "  }", "}", "export const EXPECTED_CASES: ExpectedCase[] = ["]
    rows = csv.DictReader((line for line in (fixtures / "inventory.tsv").read_text().splitlines()
                           if not line.startswith("#")), delimiter="\t")
    for row in rows:
        for variant in row["variants"].split(","):
            for state in row["states"].split(","):
                lines.append("  new ExpectedCase(%s, %s, %s, %s)," % (
                    quote(row["component"]), quote(variant), quote(state), quote(row["kinds"].split("/"))))
    lines += ["];", ""]
    data = "\n".join(lines)
    # 同一份独立期望同时供 Local Test 和真机覆盖使用，均由 --check 管理。
    return {"common/designsystem/src/test/Ds02Expected.ets": data,
            "entry/src/ohosTest/ets/test/Ds02Expected.ets": data}
