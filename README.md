# zhipu-statusline

**Claude Code 状态栏的智谱 GLM Coding Plan 额度显示条** —— 5 小时窗口 + 周窗口实时额度，多账号同屏，个人套餐与团队套餐都支持。

用智谱 Coding Plan 跑 Claude Code 后，状态栏的额度段会消失——因为额度数据是 Claude Code 官方订阅登录时才注入的。这套脚本把智谱的额度数据接回来，直接渲染在你的状态栏里。

## 效果

多账号同屏（青色=主号 / 品红=副号，★ 为当前账号，加粗高亮聚焦）：

```
上下文 ░░░░░░░░░░ 0% 主号 5h ██████████ 100% 2h56m 周 ███░░░░░░░ 33% 2d20h  │  副号★ 5h ███░░░░░░░ 31% 4h02m 周 █░░░░░░░░░ 9% 6h36m
```

- 每个账号：10 格额度条 + 已用百分比 + 5h/周重置倒计时
- 条的颜色随用量变化：<50% 绿 / 50–79% 黄 / ≥80% 红
- 名字颜色 = 账号身份色（可在配置里改），当前账号加粗亮色、其余正常亮度，切号即聚焦

## 两套方案

| | 方案一：wrapper 多账号版（推荐） | 方案二：独立单账号版 |
|---|---|---|
| 脚本 | `statusline-wrapper.sh` | `zhipu-statusline.sh` |
| 账号数 | 多账号同屏（个人 + 团队套餐） | 单账号（仅个人套餐） |
| 渲染 | 依赖 [xiangrui-hud](https://github.com/xiangruiai/vantasma-toolkit) 插件渲染上下文，额度段内嵌进"上下文"行 | 不依赖插件，注入官方 `rate_limits` schema 由任意 HUD 原版渲染；无插件时自画简版额度条 |
| 适合 | 多个智谱账号/团队席位来回切的人 | 只要一个账号的额度 |

## 方案一安装（多账号）

### 1. 装状态栏 HUD（渲染上下文长度）

Claude Code 里安装 xiangrui-hud 插件（本项目用它渲染"上下文"行，额度段会内嵌到该行尾）：

```
/plugin marketplace add xiangruiai/vantasma-toolkit
/plugin install xiangrui-hud@vantasma-toolkit
```

### 2. 放脚本

```bash
mkdir -p ~/.claude/scripts
curl -o ~/.claude/scripts/statusline-wrapper.sh \
  https://raw.githubusercontent.com/shaocongzeming/zhipu-statusline/main/statusline-wrapper.sh
chmod +x ~/.claude/scripts/statusline-wrapper.sh
```

### 3. 配账号清单 `~/.claude/zhipu-accounts.json`

```bash
curl -o ~/.claude/zhipu-accounts.json \
  https://raw.githubusercontent.com/shaocongzeming/zhipu-statusline/main/zhipu-accounts.example.json
chmod 600 ~/.claude/zhipu-accounts.json   # 里面有 key，收紧权限
```

然后编辑，把占位符换成你的智谱 API Key（[开放平台控制台](https://open.bigmodel.cn)生成）：

```json
[
  { "name": "主号", "color": "cyan",   "key": "你的APIKey" },
  { "name": "副号", "color": "magenta", "key": "你的APIKey2",
    "team": { "org": "org-xxxx", "project": "proj_xxxx" } }
]
```

字段说明：

| 字段 | 必填 | 说明 |
|---|---|---|
| `name` | ✓ | 状态栏里显示的账号名，随意起 |
| `key` | ✓ | 该账号的智谱 API Key |
| `color` | | 账号身份色：`red/green/yellow/blue/magenta/cyan/white`，不配则自动轮换 |
| `team.org` / `team.project` | 团队套餐才需要 | 团队组织/项目 ID，见下文"团队套餐" |
| `note` | | 该账号查不到额度时显示的备注文案（如 `"团队套餐"`），不配则显示"无套餐" |

不创建这个文件也能用：脚本自动降级为只显示 settings.json 里 `ANTHROPIC_AUTH_TOKEN` 那一个账号（名字显示"当前"）。

### 4. 状态栏指向脚本

`~/.claude/settings.json`：

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/scripts/statusline-wrapper.sh",
    "padding": 0,
    "refreshInterval": 60
  }
}
```

重启 Claude Code 生效。

## 团队套餐（Team Plan）

智谱团队 Coding Plan 的额度不挂在个人接口上，查询要用**三个差异**（官方无文档，从 [cc-switch](https://github.com/farion1231/cc-switch) 开源实现里确认）：

- 同一个端点，但带 `?type=2` 参数
- 请求头带 `bigmodel-organization: <org>` 和 `bigmodel-project: <project>`
- `Authorization` 用裸 key，**不带** `Bearer` 前缀

返回的窗口类型是 `CREDIT_LIMIT`（个人版是 `TOKENS_LIMIT`），窗口同样靠 `unit` 区分（3=5h，6=周）。org / 项目 ID 在智谱控制台的团队管理页能查到；如果你用 cc-switch 管理配置，它的数据库 `~/.cc-switch/cc-switch.db` 里 `providers.meta` 的 `usage_script` 字段直接存着这两个值。

脚本对每个账号**先走团队接口、查不到窗口自动回落个人接口**——所以一把 key 到底是什么身份（个人套餐/团队席位/纯按量付费）都能显示它真实拥有的额度：有套餐显示额度条，没有显示"无套餐"（或你配的 `note`）。

## 配色机制

三层各管一件事：

1. **身份色**（分清是谁）：名字的颜色，每个账号一个，`color` 字段配置
2. **聚焦**（切号时看哪）：当前账号名字加粗 + 亮色变体 + ★，其余账号正常亮度
3. **热度色**（用了多少）：额度条 <50% 绿 / 50–79% 黄 / ≥80% 红，倒计时暗灰

## 可调项（脚本顶部）

| 变量 | 默认 | 说明 |
|---|---|---|
| `BAR_LEN` | 10 | 额度条格数，状态栏太窄改 `5` |
| `SHOW_OTHER_ACCOUNTS` | 1 | 改 `0` 只显示当前账号 |

## 行为细节（方案一）

- **永不阻塞、永不闪**：额度数据走缓存（120 秒），状态栏刷新不等待网络；后台静默刷新，失败写负缓存不重试（接口异常 30s、确认无套餐 1h 后才重试）
- **按账号隔离**：缓存带 key 指纹，切账号（改 settings.json 的 `ANTHROPIC_AUTH_TOKEN`）后旧账号数据立即作废，永不串号；当前账号标 ★
- **切回 Claude 官方订阅零配置**：stdin 自带官方 `rate_limits` 时脚本全透传，不掺智谱数据
- **兜底**：HUD 崩了也保证有一行输出、exit 0，状态栏不会消失

## 数据源与稳定性声明

智谱的额度查询接口（个人版 `GET /api/monitor/usage/quota/limit` + Bearer；团队版 `?type=2` + 组织/项目头 + 裸 key）**官方未公开文档**，属于逆向实测产物，智谱随时可能调整。接口失效时状态栏自动降级为不显示额度段，不影响 Claude Code 其他功能。

## 方案二安装（单账号 legacy）

```bash
mkdir -p ~/.claude/scripts
curl -o ~/.claude/scripts/zhipu-statusline.sh \
  https://raw.githubusercontent.com/shaocongzeming/zhipu-statusline/main/zhipu-statusline.sh
chmod +x ~/.claude/scripts/zhipu-statusline.sh
```

`settings.json` 指向 `zhipu-statusline.sh` 即可（同上把 command 换掉）。原理是把个人套餐额度按官方 `rate_limits` schema 注入，交由任意状态栏 HUD 原版渲染——颜色阈值、进度条、倒计时格式与 Claude 订阅时代完全一致。依赖：`jq`、`curl`、`node`（配了 HUD 就有）。

## License

MIT

<div align="center">

**韶聪泽明 · 班底 Zecrew**

北京韶聪泽明智能科技有限责任公司

班底 ZECREW 桌面 AI 办公伙伴 · 员工与技能定制 · 企业 AI 服务（FDE）

WaytoAGI 模数OPC 社区

</div>
