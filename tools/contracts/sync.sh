#!/bin/bash
# 按 contract.lock 锁定的两个提交重建 contracts/snapshot/，并刷新 lock 里的 files 哈希。
#
# 用法：tools/contracts/sync.sh
#       tools/contracts/sync.sh --check   只核对（CT-LOCK-01）：按 lock 的提交在临时目录重建快照，与 contracts/snapshot/
#                                        逐字节比较，并核对 lock 的 files 哈希与快照一致；不写任何文件。
#                                        一致退出 0，不一致退出 1（列出差异），取不到仓库 / 提交退出 1。
#       tools/contracts/sync.sh --check-hashes-only   只核对 lock 的 files 哈希与快照一致（不需要上游仓库，
#                                        不核对锁定提交号；改了提交号而没重建快照查不出来）。不是完整一致性检查，
#                                        verify.sh 不用它（CT-LOCK-01 R1-02）。
#   仓库路径取 lock 里的相对路径（相对本仓库根）；在 worktree 等路径不成立的地方，
#   用环境变量 REBATE_PLATFORM_DIR、COULI_DIR 覆盖：
#   REBATE_PLATFORM_DIR=/path/to/rebate-platform COULI_DIR=/path/to/couli tools/contracts/sync.sh
#
# 约定（与 iOS / Android 端 APP-01 一致，快照逐字节相同）：
#   - 只用 `git -C <repo> show <commit>:<path>` 读取，不读工作区。
#   - YAML 用 /usr/bin/ruby（YAML.safe_load）转 JSON；转换后出现非字符串映射键即报错退出
#     （Ruby 按 YAML 1.1 会把未加引号的 on/off/yes/no 当布尔，契约按 1.2 写）。
#   - 输出 UTF-8、2 空格缩进、末尾换行；保持源文件里的键顺序（枚举取值顺序即契约顺序）。
# 兼容 macOS 自带 bash 3.2；路径一律加引号（含中文）。
set -euo pipefail

CHECK=0
HASHES_ONLY=0
if [ "${1:-}" = "--check" ]; then
    CHECK=1
elif [ "${1:-}" = "--check-hashes-only" ]; then
    HASHES_ONLY=1
elif [ -n "${1:-}" ]; then
    echo "用法：sync.sh [--check | --check-hashes-only]" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOCK="$ROOT/contract.lock"
SNAPSHOT="$ROOT/contracts/snapshot"
RUBY="/usr/bin/ruby"

die() {
    echo "sync.sh: $*" >&2
    exit 1
}

[ -f "$LOCK" ] || die "找不到 $LOCK"

if [ "$HASHES_ONLY" -eq 1 ]; then
    python3 - "$LOCK" "$SNAPSHOT" <<'PY'
import hashlib, json, os, sys
lock = json.load(open(sys.argv[1], encoding="utf-8")).get("files", {})
have = {}
for dirpath, _, names in os.walk(sys.argv[2]):
    for name in names:
        full = os.path.join(dirpath, name)
        with open(full, "rb") as fh:
            have[os.path.relpath(full, sys.argv[2]).replace(os.sep, "/")] = hashlib.sha256(fh.read()).hexdigest()
bad = sorted(k for k in set(lock) | set(have) if lock.get(k) != have.get(k))
if bad:
    sys.stderr.write("sync.sh --check-hashes-only：contract.lock files 哈希与快照不一致：\n")
    for k in bad:
        sys.stderr.write("  " + k + "\n")
    sys.exit(1)
print("sync.sh --check-hashes-only：%d 个快照文件与 lock files 哈希一致（未核对锁定提交，不是完整一致性检查）" % len(have))
PY
    exit $?
fi

lock_get() {
    python3 - "$LOCK" "$1" <<'PY'
import json, sys
node = json.load(open(sys.argv[1], encoding="utf-8"))
for part in sys.argv[2].split("."):
    node = node[part]
print(node)
PY
}

resolve_repo() {
    # $1 = lock 里的相对路径，$2 = 覆盖用的环境变量值
    if [ -n "$2" ]; then
        printf '%s\n' "$2"
    else
        (cd "$ROOT" && cd "$1" 2>/dev/null && pwd) || die "仓库 $1 不存在（相对 ${ROOT}），请用环境变量覆盖"
    fi
}

RP_REPO="$(resolve_repo "$(lock_get rebate_platform.repo)" "${REBATE_PLATFORM_DIR:-}")"
RP_COMMIT="$(lock_get rebate_platform.commit)"
DT_REPO="$(resolve_repo "$(lock_get design_tokens.repo)" "${COULI_DIR:-}")"
DT_COMMIT="$(lock_get design_tokens.commit)"
DT_PATH="$(lock_get design_tokens.path)"

git -C "$RP_REPO" cat-file -e "$RP_COMMIT^{commit}" 2>/dev/null || die "$RP_REPO 里没有提交 $RP_COMMIT"
git -C "$DT_REPO" cat-file -e "$DT_COMMIT^{commit}" 2>/dev/null || die "$DT_REPO 里没有提交 $DT_COMMIT"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/couli-sync.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/snapshot"
mkdir -p "$OUT"

normalize_json() {
    python3 -c '
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as f:
    data = json.load(f)
with open(dst, "w", encoding="utf-8", newline="\n") as f:
    f.write(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
' "$1" "$2"
}

yaml_to_json() {
    "$RUBY" -ryaml -rjson -e '
def check(node, path)
  case node
  when Hash
    node.each do |k, v|
      unless k.is_a?(String)
        STDERR.puts "#{ARGV[0]}: #{path} 下出现非字符串映射键 #{k.inspect}（#{k.class}）；YAML 1.1 会把未加引号的 on/off/yes/no 当布尔，请在契约里给键加引号"
        exit 2
      end
      check(v, "#{path}.#{k}")
    end
  when Array
    node.each_with_index { |v, i| check(v, "#{path}[#{i}]") }
  end
end
data = YAML.safe_load(STDIN.read, permitted_classes: [], permitted_symbols: [], aliases: false)
check(data, "$")
STDOUT.write(JSON.generate(data))
' "$1"
}

# $1 仓库 $2 提交 $3 源路径 $4 快照内相对路径
take() {
    local repo="$1" commit="$2" src="$3" dst="$OUT/$4" raw="$TMP/raw"
    mkdir -p "$(dirname "$dst")"
    git -C "$repo" show "$commit:$src" >"$raw" || die "取不到 $commit:$src"
    case "$src" in
        *.yaml | *.yml)
            yaml_to_json "$src" <"$raw" >"$TMP/converted.json" || die "$src 转换失败"
            normalize_json "$TMP/converted.json" "$dst"
            ;;
        *.json)
            normalize_json "$raw" "$dst"
            ;;
        *.ndjson)
            # APP-10：Agent 流样例逐字节原样拷贝（逐行 JSON，整文件不是合法 JSON；
            # 原样拷贝让快照哈希与 rebate-platform 锁定提交里的文件哈希直接可比）。
            cp "$raw" "$dst"
            ;;
        *) die "不支持的文件类型 $src" ;;
    esac
    echo "  $4  <=  $src"
}

json_name() {
    printf '%s\n' "$1" | sed -E 's/\.(yaml|yml)$/.json/'
}

echo "rebate-platform $RP_COMMIT"
ENUM_FILES="$(git -C "$RP_REPO" ls-tree --name-only "$RP_COMMIT" contracts/enums/ | grep -E '\.ya?ml$' || true)"
[ -n "$ENUM_FILES" ] || die "contracts/enums/ 下没有 YAML"
OLDIFS="$IFS"
IFS='
'
for f in $ENUM_FILES; do
    take "$RP_REPO" "$RP_COMMIT" "$f" "$(json_name "$f")"
done
IFS="$OLDIFS"

# APP-02c 加入 openapi.yaml（GET /v1/app-versions/check 的响应示例给调试假数据；OpenAPI 客户端仍归 APP-03）
# 与 specs/app-stores.yaml（商店对照表，生成 AppStores 常量）。
# APP-03a 加入 specs/request-sign.vectors.json（BR-ID-09 三端共用签名向量；core 单测经 gen.py 生成的数据模块读取）。
# APP-03b 加入 specs/device-hash.vectors.json（BR-ID-09 device_hash 向量；events / system-permissions / client-security-baseline 已在列）。
for f in \
    contracts/error-codes.yaml \
    contracts/routes.json \
    contracts/bridge.schema.json \
    contracts/texts.default.json \
    contracts/apps.json \
    contracts/agent-stream.schema.json \
    specs/events.yaml \
    specs/client-public-ids.yaml \
    specs/client-security-baseline.yaml \
    specs/system-permissions.yaml \
    contracts/openapi.yaml \
    specs/app-stores.yaml \
    specs/request-sign.vectors.json \
    specs/device-hash.vectors.json; do
    take "$RP_REPO" "$RP_COMMIT" "$f" "$(json_name "$f")"
done

# APP-10 加入 contracts/fixtures/agent-streams/*.ndjson（三端 StreamReducer 单测与快照测试用，原样拷贝）。
AGENT_FIXTURES="$(git -C "$RP_REPO" ls-tree --name-only "$RP_COMMIT" contracts/fixtures/agent-streams/)" \
    || die "取不到 contracts/fixtures/agent-streams/ 列表"
AGENT_FIXTURES="$(printf '%s\n' "$AGENT_FIXTURES" | grep -E '\.ndjson$' || true)"
[ -n "$AGENT_FIXTURES" ] || die "contracts/fixtures/agent-streams/ 下没有 ndjson"
OLDIFS="$IFS"
IFS='
'
for f in $AGENT_FIXTURES; do
    take "$RP_REPO" "$RP_COMMIT" "$f" "$f"
done
IFS="$OLDIFS"

echo "design tokens $DT_COMMIT"
take "$DT_REPO" "$DT_COMMIT" "$DT_PATH" "design/design-tokens.json"

if [ "$CHECK" -eq 1 ]; then
    python3 - "$LOCK" "$OUT" "$SNAPSHOT" <<'PY'
import hashlib, json, os, sys
lock_path, rebuilt, snap = sys.argv[1], sys.argv[2], sys.argv[3]
def digests(base):
    out = {}
    if not os.path.isdir(base):
        return out
    for dirpath, _, names in os.walk(base):
        for name in names:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, base).replace(os.sep, "/")
            with open(full, "rb") as fh:
                out[rel] = hashlib.sha256(fh.read()).hexdigest()
    return out
with open(lock_path, encoding="utf-8") as f:
    locked = json.load(f).get("files", {})
want, have = digests(rebuilt), digests(snap)
problems = []
for rel in sorted(set(want) | set(have)):
    if rel not in have:
        problems.append("快照缺文件（锁定提交里有）：%s" % rel)
    elif rel not in want:
        problems.append("快照多出文件（锁定提交里没有）：%s" % rel)
    elif want[rel] != have[rel]:
        problems.append("快照与锁定提交重建结果不同：%s" % rel)
for rel in sorted(set(locked) | set(have)):
    if locked.get(rel) != have.get(rel):
        problems.append("contract.lock files 哈希与快照不一致：%s" % rel)
if problems:
    sys.stderr.write("sync.sh --check：契约快照与 contract.lock 不一致（运行 tools/contracts/sync.sh 重建）：\n")
    for p in problems:
        sys.stderr.write("  " + p + "\n")
    sys.exit(1)
print("sync.sh --check：%d 个快照文件与锁定提交、lock 哈希一致" % len(have))
PY
    exit $?
fi

rm -rf "$SNAPSHOT"
mkdir -p "$(dirname "$SNAPSHOT")"
mv "$OUT" "$SNAPSHOT"

python3 - "$LOCK" "$SNAPSHOT" <<'PY'
import hashlib, json, os, sys
lock_path, snap = sys.argv[1], sys.argv[2]
with open(lock_path, encoding="utf-8") as f:
    lock = json.load(f)
files = {}
for dirpath, _, names in os.walk(snap):
    for name in names:
        full = os.path.join(dirpath, name)
        rel = os.path.relpath(full, snap).replace(os.sep, "/")
        with open(full, "rb") as fh:
            files[rel] = hashlib.sha256(fh.read()).hexdigest()
lock["files"] = {k: files[k] for k in sorted(files)}
with open(lock_path, "w", encoding="utf-8", newline="\n") as f:
    f.write(json.dumps(lock, ensure_ascii=False, indent=2) + "\n")
PY
echo "已刷新 contract.lock（$(cd "$SNAPSHOT" && find . -type f | wc -l | tr -d ' ') 个文件）"
