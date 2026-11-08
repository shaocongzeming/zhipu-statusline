#!/bin/bash
# statusline-wrapper.sh — xiangrui-hud 外包一层：智谱 Coding Plan 额度显示
#
# v4（2026-11-09）——多账号：账号清单在 ~/.claude/zhipu-accounts.json
#   （[{"name":"主号","key":"xxx"},...]，改名字/加账号直接编辑这个文件）。
#   每个账号额度独立缓存（按 key 指纹隔离）；行尾显示所有账号的额度段，
#   当前账号（settings.json 里的 key）标 ★。谁有套餐显示谁的条，
#   没套餐的显示"无套餐"，接口异常显示"?"。切账号立即跟随、永不串号。
#   stdin 自带官方 rate_limits（Claude 订阅）时透传，不加智谱段。
# v3（2026-11-09）——缓存带 key 指纹，按账号隔离。
# v2（2026-10-11）——永不闪、永不阻塞：先渲染缓存，后台刷新；失败负缓存。
# 数据源: GET https://open.bigmodel.cn/api/monitor/usage/quota/limit (Bearer 裸key)
#   TOKENS_LIMIT unit=3 → 5h 窗口；unit=6 → 周窗口
#   percentage=已用%, nextResetTime=epoch ms
# 无套餐账号: quota/limit 返回 {"code":500,"msg":"当前用户不存在coding plan"}
# 缓存: ~/.claude/cache/zhipu-quota.<fp>.json（120s）；
# 负缓存: ...<fp>.neg.json（err 30s / noplan 1h）
# 回滚: cp statusline-wrapper.sh.bak-20261109-v3 statusline-wrapper.sh
SHOW_OTHER_ACCOUNTS=1   # 0 = 只显示当前账号，不列其他账号
BAR_LEN=10              # 额度条格数，嫌状态栏太宽改成 5

CACHE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/cache"
mkdir -p "$CACHE_DIR" 2>/dev/null
ACCOUNTS_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/zhipu-accounts.json"
HUD_PATH_FILE="$CACHE_DIR/xiangrui-hud.path"
CACHE_TTL=120
NEG_TTL_ERR=30
NEG_TTL_NOPLAN=3600

input=$(cat)

fp_of() { printf '%s' "$1" | shasum -a 256 | cut -c1-8; }

# 额度条（第2参数=格数，默认10）
bar_of() {
    local p=$1 len=${2:-10} n i b=""
    n=$(( (p * len + 50) / 100 )); (( n > len )) && n=$len; (( p > 0 && n == 0 )) && n=1
    for (( i=0; i<n; i++ )); do b+="█"; done
    for (( i=n; i<len; i++ )); do b+="░"; done
    printf '%s' "$b"
}

# 剩余秒数 → 2d20h / 3h27m / 45m
fmt_left() {
    local s=$1 d h m
    d=$(( s / 86400 )); h=$(( (s % 86400) / 3600 )); m=$(( (s % 3600) / 60 ))
    (( d > 0 )) && printf '%dd%dh' "$d" "$h" && return
    (( h > 0 )) && printf '%dh%02dm' "$h" "$m" || printf '%dm' "$m"
}

# 账号身份色：accounts.json 里配 "color":"cyan/magenta/blue/green/yellow/red/white"，
# 不配则按顺序自动分配
color_code() {  # $1=颜色名 $2=账号序号
    case "$1" in
        red) printf 31 ;; green) printf 32 ;; yellow) printf 33 ;;
        blue) printf 34 ;; magenta) printf 35 ;; cyan) printf 36 ;;
        white) printf 37 ;;
        "") case $(( $2 % 7 )) in
                0) printf 36 ;; 1) printf 35 ;; 2) printf 34 ;; 3) printf 32 ;;
                4) printf 33 ;; 5) printf 31 ;; *) printf 37 ;; esac ;;
        *) printf 36 ;;
    esac
}

# 已用%热度色代码：<50 绿 <80 黄 其余红
usage_code() {
    local p=$1
    (( p < 50 )) && printf 32 && return
    (( p < 80 )) && printf 33 && return
    printf 31
}

# 响应 → tsv 行（个人=TOKENS_LIMIT，团队=CREDIT_LIMIT，窗口靠 unit 区分：3=5h，6=周）
row_of() {
    printf '%s' "$1" | jq -r '
        .data as $d |
        ($d.limits[]? | select(.unit==3)) as $h5 |
        ($d.limits[]? | select(.unit==6)) as $wk |
        [ ($h5.percentage // "-"), ($h5.nextResetTime // 0),
          ($wk.percentage // "-"), ($wk.nextResetTime // 0) ] | @tsv' 2>/dev/null
}

# 取某账号的额度行：团队配置优先走团队接口（?type=2 + org/project 头 + 裸key），
# 团队席位没窗口（比如 key 其实是个人账号的）→ 自动回落个人接口
LAST_MSG=""
fetch_row() {
    local key=$1 org=$2 proj=$3 data row
    LAST_MSG=""
    if [[ -n "$org" && -n "$proj" ]]; then
        data=$(curl -s -m 3 "https://open.bigmodel.cn/api/monitor/usage/quota/limit?type=2" \
            -H "Authorization: $key" \
            -H "bigmodel-organization: $org" \
            -H "bigmodel-project: $proj" \
            -H "Accept-Language: en-US,en" 2>/dev/null)
        row=$(row_of "$data")
        [[ "$row" =~ ^[0-9]+ ]] && { printf '%s' "$row"; return 0; }
    fi
    data=$(curl -s -m 3 -H "Authorization: Bearer $key" \
        "https://open.bigmodel.cn/api/monitor/usage/quota/limit" 2>/dev/null)
    LAST_MSG=$(printf '%s' "$data" | jq -r '.msg // ""' 2>/dev/null)
    row_of "$data"
}

# ── 0) 当前账号 + 账号清单 ────────────────────────────────────────────
active_key=$(jq -r '.env.ANTHROPIC_AUTH_TOKEN // empty' \
    "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null)
active_fp=""
[[ -n "$active_key" ]] && active_fp=$(fp_of "$active_key")

accounts=""
if [[ -s "$ACCOUNTS_FILE" ]]; then
    accounts=$(jq -c '.[]' "$ACCOUNTS_FILE" 2>/dev/null)
fi
[[ -n "$accounts" ]] || accounts=$(printf '{"name":"当前","key":"%s"}\n' "$active_key")

# stdin 来自 Claude 官方订阅（自带 rate_limits）→ 全透传，不掺智谱数据
official=$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)

now=$(date +%s)

# ── 1) 后台刷新：任何账号缓存过期且无有效负缓存 → 刷全部 ──────────────
need=0
if [[ -z "$official" ]]; then   # stdin 已有官方数据时不刷智谱
while IFS= read -r acc && [[ -n "$acc" ]]; do
    key=$(jq -r '.key // ""' <<<"$acc" 2>/dev/null)
    [[ -n "$key" ]] || continue
    fp=$(fp_of "$key")
    cf="$CACHE_DIR/zhipu-quota.$fp.json"; nf="$CACHE_DIR/zhipu-quota.$fp.neg.json"
    fresh=0; neg=0
    if [[ -s "$cf" ]] && jq -e '.h5_pct != null' "$cf" >/dev/null 2>&1; then
        ts=$(jq -r '.ts // 0' "$cf" 2>/dev/null)
        (( now - ts < CACHE_TTL )) && fresh=1
    fi
    if [[ -s "$nf" && "$(jq -r '.fp // ""' "$nf" 2>/dev/null)" == "$fp" ]]; then
        nts=$(jq -r '.ts // 0' "$nf" 2>/dev/null)
        reason=$(jq -r '.reason // "err"' "$nf" 2>/dev/null)
        ttl=$NEG_TTL_ERR; [[ "$reason" == "noplan" ]] && ttl=$NEG_TTL_NOPLAN
        (( now - nts < ttl )) && neg=1
    fi
    (( ! fresh && ! neg )) && need=1 && break
done <<< "$accounts"
fi
if (( need )); then
    {
        while IFS= read -r acc; do
            key=$(jq -r '.key // ""' <<<"$acc" 2>/dev/null)
            [[ -n "$key" ]] || continue
            fp=$(fp_of "$key")
            cf="$CACHE_DIR/zhipu-quota.$fp.json"; nf="$CACHE_DIR/zhipu-quota.$fp.neg.json"
            fresh=0; neg=0
            if [[ -s "$cf" ]] && jq -e '.h5_pct != null' "$cf" >/dev/null 2>&1; then
                ts=$(jq -r '.ts // 0' "$cf" 2>/dev/null)
                (( now - ts < CACHE_TTL )) && fresh=1
            fi
            if [[ -s "$nf" && "$(jq -r '.fp // ""' "$nf" 2>/dev/null)" == "$fp" ]]; then
                nts=$(jq -r '.ts // 0' "$nf" 2>/dev/null)
                reason=$(jq -r '.reason // "err"' "$nf" 2>/dev/null)
                ttl=$NEG_TTL_ERR; [[ "$reason" == "noplan" ]] && ttl=$NEG_TTL_NOPLAN
                (( now - nts < ttl )) && neg=1
            fi
            (( fresh || neg )) && continue
            org=$(jq -r '.team.org // ""' <<<"$acc" 2>/dev/null)
            proj=$(jq -r '.team.project // ""' <<<"$acc" 2>/dev/null)
            row=$(fetch_row "$key" "$org" "$proj")
            if [[ "$row" =~ ^[0-9]+ ]]; then
                IFS=$'\t' read -r h5_pct h5_reset wk_pct wk_reset <<< "$row"
                tmp=$(mktemp "$cf.XXXXXX") && {
                    printf '{"ts":%d,"fp":"%s","h5_pct":%s,"h5_reset":%s,"wk_pct":%s,"wk_reset":%s}\n' \
                        "$(date +%s)" "$fp" "${h5_pct:-0}" "${h5_reset:-0}" "${wk_pct:-0}" "${wk_reset:-0}" > "$tmp"
                    mv -f "$tmp" "$cf"
                } 2>/dev/null
                rm -f "$nf" 2>/dev/null
            else
                reason="err"; [[ "$LAST_MSG" == *"不存在coding plan"* ]] && reason="noplan"
                tmp=$(mktemp "$nf.XXXXXX") && {
                    printf '{"ts":%d,"fp":"%s","reason":"%s"}\n' "$(date +%s)" "$fp" "$reason" > "$tmp"
                    mv -f "$tmp" "$nf"
                } 2>/dev/null
            fi
        done <<< "$accounts"
    } >/dev/null 2>&1 </dev/null &
    disown
fi

# ── 2) 组装所有账号的额度段 ───────────────────────────────────────────
suffix=""
if [[ "$SHOW_OTHER_ACCOUNTS" == 1 && -n "$official" ]] || [[ "$SHOW_OTHER_ACCOUNTS" != 1 ]]; then
    suffix=""   # 官方数据或关闭开关 → 不显示
else
    idx=0
    while IFS= read -r acc && [[ -n "$acc" ]]; do
        name=$(jq -r '.name // "?"' <<<"$acc" 2>/dev/null)
        key=$(jq -r '.key // ""' <<<"$acc" 2>/dev/null)
        [[ -n "$key" ]] || continue
        fp=$(fp_of "$key")
        cf="$CACHE_DIR/zhipu-quota.$fp.json"; nf="$CACHE_DIR/zhipu-quota.$fp.neg.json"
        star=""; isact=0
        [[ "$fp" == "$active_fp" ]] && { star="★"; isact=1; }
        acode=$(color_code "$(jq -r '.color // ""' <<<"$acc" 2>/dev/null)" "$idx")
        (( idx += 1 ))
        # 身份色名字：当前账号加粗+亮色变体，其他账号正常亮度（不压暗，只靠粗细/亮差聚焦）
        if (( isact )); then
            nm="\033[1;$(( acode + 60 ))m${name}${star}\033[0m"
        else
            nm="\033[${acode}m${name}${star}\033[0m"
        fi
        seg=""
        if [[ -s "$cf" ]] && jq -e '.h5_pct != null' "$cf" >/dev/null 2>&1; then
            h5=$(jq -r '.h5_pct' "$cf" 2>/dev/null); wk=$(jq -r '.wk_pct' "$cf" 2>/dev/null)
            h5r=$(jq -r '.h5_reset // 0' "$cf" 2>/dev/null)
            wkr=$(jq -r '.wk_reset // 0' "$cf" 2>/dev/null)
            u1=$(usage_code "$h5"); u2=$(usage_code "$wk")
            seg="${nm} \033[2m5h\033[0m \033[${u1}m$(bar_of "$h5" "$BAR_LEN") ${h5}%\033[0m"
            rs=$(( h5r / 1000 )); left=$(( rs - now ))
            (( rs > 0 && left > 0 )) && seg+=" \033[2m$(fmt_left "$left")\033[0m"
            seg+=" \033[2m周\033[0m \033[${u2}m$(bar_of "$wk" "$BAR_LEN") ${wk}%\033[0m"
            wkl=$(( wkr / 1000 - now ))
            (( wkr > 0 && wkl > 0 )) && seg+=" \033[2m$(fmt_left "$wkl")\033[0m"
        elif [[ -s "$nf" && "$(jq -r '.fp // ""' "$nf" 2>/dev/null)" == "$fp" ]] \
             && [[ "$(jq -r '.reason // ""' "$nf" 2>/dev/null)" == "noplan" ]]; then
            note=$(jq -r '.note // ""' <<<"$acc" 2>/dev/null)
            if [[ -n "$note" ]]; then seg="${nm} \033[2m${note}\033[0m"; else seg="${nm} \033[2m无套餐\033[0m"; fi
        else
            seg="${nm} \033[2m?\033[0m"
        fi
        suffix+="${suffix:+\033[2m  │  \033[0m}$seg"
    done <<< "$accounts"
fi

# ── 3) 找 xiangrui-hud：优先用缓存路径，插件更新瞬间不崩 ──────────────
plugin_dir=""
if [[ -s "$HUD_PATH_FILE" ]]; then
    d=$(cat "$HUD_PATH_FILE" 2>/dev/null)
    [[ -n "$d" && -f "${d}dist/index.js" ]] && plugin_dir="$d"
fi
if [[ -z "$plugin_dir" ]]; then
    plugin_dir=$(ls -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/plugins/cache/vantasma-toolkit/xiangrui-hud/*/ 2>/dev/null \
        | awk -F/ '{ print $(NF-1) "\t" $0 }' \
        | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1 | cut -f2-)
    if [[ -n "$plugin_dir" && -f "${plugin_dir}dist/index.js" ]]; then
        printf '%s' "$plugin_dir" > "$HUD_PATH_FILE.tmp" && mv -f "$HUD_PATH_FILE.tmp" "$HUD_PATH_FILE"
    else
        plugin_dir=""
    fi
fi

# ── 4) 渲染 + 兜底：HUD 崩了也必须有一行输出、exit 0 ──────────────────
out=""
if [[ -n "$plugin_dir" ]]; then
    node_bin=$(command -v node || printf '/opt/homebrew/bin/node')
    out=$(printf '%s' "$input" | "$node_bin" "${plugin_dir}dist/index.js" 2>/dev/null)
fi
if [[ -z "$out" ]]; then
    model=$(printf '%s' "$input" | jq -r '.model.display_name // .model.id // "?"' 2>/dev/null)
    out="[${model:-?}]"
fi
# 额度段放到"上下文"那一行（跟上下文同行显示）；找不到该行就退回追加到末尾
if [[ -n "$suffix" ]]; then
    placed=0; new_out=""
    while IFS= read -r line; do
        if (( ! placed )) && [[ "$line" == *上下文* || "$line" == *Context* ]]; then
            new_out+="${line} ${suffix}"$'\n'; placed=1
        else
            new_out+="${line}"$'\n'
        fi
    done <<< "$out"
    if (( placed )); then out="${new_out%$'\n'}"; else out="$out $suffix"; fi
fi
printf '%b\n' "$out"
exit 0
