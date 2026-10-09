#!/bin/bash
# zhipu-statusline.sh — Claude Code statusline 显示智谱 GLM Coding Plan 额度
#
# 原理：把智谱的 5 小时 / 周额度按 Claude Code 官方 statusline stdin schema
# 注入 rate_limits 字段，交由 xiangrui-hud / claude-hud 原版渲染——
# 字体、颜色、进度条长度、重置倒计时与 Claude 订阅时代完全一致。
#
# 数据源: GET https://open.bigmodel.cn/api/monitor/usage/quota/limit (Bearer 裸 API Key)
#   TOKENS_LIMIT unit=3 → 5 小时窗口 (percentage=已用%, nextResetTime=epoch ms)
#   TOKENS_LIMIT unit=6 → 周窗口
# 该接口官方未公开文档，智谱后续可能调整；失效时状态栏自动降级为不显示额度。
#
# 依赖: bash, jq, curl, node（xiangrui-hud 需要）
# 环境变量:
#   ZHIPU_STATUSLINE_TTL   缓存秒数，默认 120
#   ZHIPU_STATUSLINE_NODE  node 可执行文件路径，默认自动查找
#
# stdin 自带 rate_limits 时（Claude 官方订阅登录）原样透传，本脚本不覆盖。

set -u

CACHE_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/cache/zhipu-quota.json"
CACHE_TTL="${ZHIPU_STATUSLINE_TTL:-120}"
CLAUDE_SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

input=$(cat)

# ── 1) 智谱额度：缓存新鲜直接用；否则请求；失败回退旧缓存 ────────────────
now=$(date +%s)
need_fetch=1
if [[ -s "$CACHE_FILE" ]]; then
    ts=$(jq -r '.ts // 0' "$CACHE_FILE" 2>/dev/null)
    (( now - ts < CACHE_TTL )) && need_fetch=0
fi

if (( need_fetch )); then
    # API Key 从 Claude Code settings.json 读，轮换 key 无需改本脚本
    api_key=$(jq -r '.env.ANTHROPIC_AUTH_TOKEN // empty' "$CLAUDE_SETTINGS" 2>/dev/null)
    if [[ -n "$api_key" ]]; then
        data=$(curl -s -m 3 -H "Authorization: Bearer $api_key" \
            "https://open.bigmodel.cn/api/monitor/usage/quota/limit" 2>/dev/null)
        row=$(printf '%s' "$data" | jq -r '
            .data as $d |
            ($d.limits[]? | select(.type=="TOKENS_LIMIT" and .unit==3)) as $h5 |
            ($d.limits[]? | select(.type=="TOKENS_LIMIT" and .unit==6)) as $wk |
            [ ($h5.percentage // "-"), ($h5.nextResetTime // 0),
              ($wk.percentage // "-"), ($wk.nextResetTime // 0) ] | @tsv' 2>/dev/null)
        # 第一个字段必须是数字，才算拿到有效数据
        if [[ "$row" =~ ^[0-9]+ ]]; then
            IFS=$'\t' read -r h5_pct h5_reset wk_pct wk_reset <<< "$row"
            # 原子写缓存（mktemp + mv，多会话并发不会写坏）
            tmp=$(mktemp "${CACHE_FILE}.XXXXXX") && {
                printf '{"ts":%d,"h5_pct":%s,"h5_reset":%s,"wk_pct":%s,"wk_reset":%s}\n' \
                    "$now" "${h5_pct:-0}" "${h5_reset:-0}" "${wk_pct:-0}" "${wk_reset:-0}" > "$tmp"
                mv -f "$tmp" "$CACHE_FILE"
            } 2>/dev/null
        fi
    fi
fi

# ── 2) 注入 rate_limits 再喂给 HUD ────────────────────────────────────
# resets_at 必须是 epoch 秒数字：ISO 字符串会丢重置倒计时，毫秒会溢出显示
if [[ -s "$CACHE_FILE" ]] && jq -e '(.h5_pct != null) and (.h5_reset != null)' "$CACHE_FILE" >/dev/null 2>&1; then
    h5_pct=$(jq -r '.h5_pct' "$CACHE_FILE")
    h5_reset=$(jq -r '.h5_reset' "$CACHE_FILE")
    wk_pct=$(jq -r '.wk_pct' "$CACHE_FILE")
    wk_reset=$(jq -r '.wk_reset' "$CACHE_FILE")

    h5_reset_s=$(( h5_reset / 1000 )); (( h5_reset_s <= 0 )) && h5_reset_s=null
    wk_reset_s=$(( wk_reset / 1000 )); (( wk_reset_s <= 0 )) && wk_reset_s=null

    final_input=$(printf '%s' "$input" | jq \
        --argjson p5 "${h5_pct:-0}" --argjson p7 "${wk_pct:-0}" \
        --argjson r5 "$h5_reset_s" --argjson r7 "$wk_reset_s" '
        if .rate_limits.five_hour.used_percentage != null then .
        else . + {rate_limits: {five_hour:  {used_percentage: $p5, resets_at: $r5},
                                 seven_day: {used_percentage: $p7, resets_at: $r7}}}
        end')
else
    # 拿不到智谱数据：不注入，状态栏照常显示其余部分
    final_input=$input
fi

# ── 3) 交给 HUD 渲染（取已安装的最新版本）─────────────────────────────
NODE_BIN="${ZHIPU_STATUSLINE_NODE:-$(command -v node 2>/dev/null || echo /opt/homebrew/bin/node)}"
HUD_CACHE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache"
# 插件缓存布局: cache/<marketplace>/<plugin>/<版本>（部分安装方式会多一层）
find_hud() {
    local name=$1
    ls -d "$HUD_CACHE"/*/"$name"/*/ "$HUD_CACHE"/*/*/"$name"/*/ 2>/dev/null \
        | awk -F/ '{ print $(NF-1) "\t" $0 }' \
        | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1 | cut -f2-
}
hud_dir=$(find_hud xiangrui-hud)
[[ -z "$hud_dir" ]] && hud_dir=$(find_hud claude-hud)

if [[ -n "$hud_dir" && -f "${hud_dir}dist/index.js" ]]; then
    printf '%s' "$final_input" | exec "$NODE_BIN" "${hud_dir}dist/index.js"
else
    # HUD 不存在：兜底裸输出，保证状态栏不空白
    printf '%s' "$final_input" | jq -r '
        "□ \(.model.display_name // .model.id // "?") │ \(.workspace.current_dir // .cwd // "?" | split("/") | last)
        上下文 ?%（未检测到 xiangrui-hud / claude-hud 插件）"'
fi
