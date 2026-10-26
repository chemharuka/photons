#!/bin/bash
# photons dispatch —— 一次把「实现 session」的环境准备好，并打印可直接粘贴的开场 prompt。
#
#   scripts/dispatch.sh <NNN> <主题slug> "<一句目标>" --accept "<验收命令>" [--no-build] [--dry-run]
#   scripts/dispatch.sh review <NNN> <主题slug>
#
# 做的事：开 worktree（分支 feat/<slug>，基线 main）→ 播种 .build → 编译 → 写规格骨架 → 打印 prompt。
# 不碰主 checkout、不提交、不推远端的任何东西。
set -euo pipefail

ROOT=$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" rev-parse --show-toplevel)
BUS=~/.hermes/skills/photons/photons-session-bus/scripts/bus.py
WTBASE=/tmp

usage() { sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1; }
die() { echo "错误：$*" >&2; exit 1; }

[ $# -ge 1 ] || usage

# ---------------------------------------------------------------- review 模式
if [ "$1" = "review" ]; then
  [ $# -eq 3 ] || usage
  NNN=$2; SLUG=$3
  cat <<EOF
你是 Photons 的**审阅 session**，只审 feat/${SLUG}，不改功能代码。

1. skill_view('photons-code-review')，照它的五步走
2. python3 ${BUS} --path ${ROOT} sync   # 看交接：分支名 / 基线 commit / 规格 / 验收摘要
3. 自己在 ${WTBASE}/photons-rv-${SLUG} 建 worktree 并抢跑验收（别用别人的 worktree，也别在主 checkout 跑）：
   git -C ${ROOT} worktree add --detach ${WTBASE}/photons-rv-${SLUG} feat/${SLUG}
   然后按 photons-code-review §第二步 播种 .build 并 make verify
4. 结论写 ${ROOT}/docs/reviews/${NNN}-${SLUG}-review.md，三档之一（通过 / 有条件通过 / 退回）；阻塞问题必须带 文件:行号
5. 通过才合入：git -C ${ROOT} merge --no-ff feat/${SLUG} → 在 ${ROOT} 再跑一次 make verify → 删掉审阅与实现两个 worktree

汇报只回：结论 + 阻塞问题条数 + 你自己跑的验收摘要。别贴 diff。
EOF
  exit 0
fi

# ---------------------------------------------------------------- 实现模式
[ $# -ge 4 ] || usage
NNN=$1; SLUG=$2; GOAL=$3; shift 3
ACCEPT=""; BUILD=1; DRYRUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --accept) ACCEPT=${2:-}; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    --dry-run) DRYRUN=1; shift ;;
    *) die "未知参数 $1" ;;
  esac
done
[ -n "$ACCEPT" ] || die "必须给 --accept（没有验收命令的活不许开工）"

WT=${WTBASE}/photons-wt-${SLUG}
SPEC_REL=docs/tasks/${NNN}-${SLUG}.md

if [ "$DRYRUN" = 0 ]; then
  [ -d "$WT" ] && die "$WT 已存在（先处理旧的：git -C $ROOT worktree remove $WT）"
  git -C "$ROOT" rev-parse --verify --quiet "feat/${SLUG}" >/dev/null && die "分支 feat/${SLUG} 已存在"
fi

BASE=$(git -C "$ROOT" rev-parse --short main)

run() { if [ "$DRYRUN" = 1 ]; then echo "  [dry] $*"; else "$@"; fi; }

echo "== 1/4 开 worktree（基线 main@${BASE}）"
run git -C "$ROOT" worktree add --detach "$WT" main
run git -C "$WT" switch -c "feat/${SLUG}"

echo "== 2/4 播种 .build（GRDB 的 SQLiteCustom/src 一并带上）"
run mkdir -p "$WT/.build"
run cp -R "$ROOT/.build/checkouts" "$WT/.build/"
run cp -R "$ROOT/.build/repositories" "$WT/.build/"
run cp "$ROOT/.build/workspace-state.json" "$WT/.build/"

echo "== 3/4 编译（冷编约 80 s）"
if [ "$BUILD" = 1 ]; then
  run bash -c "cd '$WT' && swift build -c release --disable-automatic-resolution"
else
  echo "  （--no-build：留给实现 session 自己跑）"
fi

echo "== 4/4 写规格骨架 ${SPEC_REL}"
if [ "$DRYRUN" = 1 ]; then
  echo "  [dry] 写 $WT/$SPEC_REL"
else
  mkdir -p "$WT/docs/tasks"
  if [ -f "$WT/$SPEC_REL" ]; then
    echo "  已存在，不覆盖"
  else
    cat > "$WT/$SPEC_REL" <<EOF
# ${NNN} ${SLUG}

> 由 \`scripts/dispatch.sh\` 生成。开工前先补全「文件所有权 / 不变量 / 不做」三节。

## 目标
${GOAL}

## 验收（必须真跑；红了不许提交）
\`\`\`bash
${ACCEPT}
\`\`\`

## 文件所有权
- 可以改：（待补）
- 不要动：\`docs/architecture-decisions.md\`（只由主线写）、\`local/\`

## 不变量（必须逐字节/逐像素不变的东西）
- 中性文档 = 恒等（max error < 0.002）
- 不打算改渲染行为时：既有缓存键对应的输出逐字节不变
- （待补）

## 不做
- （待补）

## 交接
按 skill \`photons-feature-dev\` §7：\`post --kind handoff\` 写清分支名 + 基线 commit + 本文件路径 + 验收摘要。
EOF
  fi
  git -C "$WT" add "$SPEC_REL"
fi

cat <<EOF

────────────────────────────────────────────────────────────────
把下面整段粘到**新建的 Hermes session**里（复制从「你是 Photons」到结尾）：

你是 Photons 的**实现 session**，只做任务 ${NNN}（${SLUG}）。

第一步，按顺序做，别跳：
1. skill_view('photons-feature-dev')，照它执行
2. 读仓库 ${ROOT}/AGENTS.md（铁律；已在上下文里，确认口径即可）
3. python3 ${BUS} --path ${ROOT} sync
4. 读规格 ${WT}/${SPEC_REL}，先把「文件所有权 / 不变量 / 不做」三节补全再动手

环境已经备好，**不要重建、不要在 ${ROOT} 里改文件**：
- worktree：${WT}（分支 feat/${SLUG}，基线 main@${BASE}$([ "$BUILD" = 1 ] && echo "，已编译通过）" || echo "，未编译，先 swift build -c release --disable-automatic-resolution）")
- 验收命令：${ACCEPT}

纪律：
- 只在这个 worktree 里改；不 merge、不 push、不删 worktree
- \`make verify\` 绿了再 commit（消息首行 feat(${SLUG}): …，正文列证据）
- 完成后 \`post --kind handoff\`：分支名 + 基线 commit + 规格路径 + 验收摘要
- 汇报只回 \`git diff --stat\` + 验收输出最后 10 行 + 一句话结论

审阅准备好后，用这条命令生成审阅 session 的开场 prompt：
  scripts/dispatch.sh review ${NNN} ${SLUG}
────────────────────────────────────────────────────────────────
EOF
