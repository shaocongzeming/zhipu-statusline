# zhipu-statusline

**Claude Code 状态栏显示智谱 GLM Coding Plan 额度** —— 5 小时窗口 + 周窗口的已用百分比和重置倒计时，由 [xiangrui-hud](https://github.com/xiangruiai/vantasma-toolkit)（或上游 [claude-hud](https://github.com/jarrodwatts/claude-hud)）原版渲染。

用智谱 Coding Plan 跑 Claude Code 后，状态栏的额度段会消失——因为额度数据是 Claude Code 官方订阅登录时才注入的。本脚本把智谱的额度按**同一份官方 schema** 注回去，HUD 怎么画Claude 额度，就怎么画智谱额度，一字不差。

## 效果

```
[GLM-5.3] │ my-project
上下文 ░░░░░░░░░░ 32%
用量 █░░░░░░░░░ 13% (重置剩余 1h 56m)
本周 ████░░░░░░ 43% (重置剩余 5d)
```

## 前提

- [Claude Code](https://claude.com/claude-code) + 智谱 GLM Coding Plan（`ANTHROPIC_BASE_URL` 指向 `open.bigmodel.cn` 那种配置）
- 已安装 HUD 插件（二选一）：
  - xiangrui-hud：`/plugin marketplace add xiangruiai/vantasma-toolkit` → `/plugin install xiangrui-hud`
  - claude-hud（上游原版）：见其 [README](https://github.com/jarrodwatts/claude-hud)
- `jq`、`curl`、`node`（HUD 本身需要 node）

## 安装

```bash
mkdir -p ~/.claude/scripts
curl -o ~/.claude/scripts/zhipu-statusline.sh \
  https://raw.githubusercontent.com/shaocongzeming/zhipu-statusline/main/zhipu-statusline.sh
chmod +x ~/.claude/scripts/zhipu-statusline.sh
```

然后在 `~/.claude/settings.json` 里把状态栏指向它：

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/scripts/zhipu-statusline.sh",
    "padding": 0
  }
}
```

重启 Claude Code 生效。

## 工作原理

1. 调智谱额度接口 `GET open.bigmodel.cn/api/monitor/usage/quota/limit`（Bearer 鉴权，API Key 自动从你 settings.json 的 `ANTHROPIC_AUTH_TOKEN` 读取，不落地任何配置）
2. 把返回的 5 小时 / 周窗口数据（已用百分比 + 重置时间）按 Claude Code 官方 statusline 的 `rate_limits` schema 写进 stdin
3. HUD 拿到后用它自己的原版逻辑渲染——颜色阈值、进度条、倒计时格式跟 Claude 订阅时代完全一致

细节行为：

- **缓存 120 秒**（`~/.claude/cache/zhipu-quota.json`），状态栏刷新频繁，不会每次都打 API；可用 `ZHIPU_STATUSLINE_TTL` 调整
- **API 失败回退旧缓存**，额度数字变化慢，旧值仍有参考价值；完全无数据时状态栏正常显示其余部分
- **切回 Claude 官方订阅零配置**：stdin 自带 `rate_limits` 时脚本原样透传，绝不覆盖

## 注意

- 额度接口是智谱官方订阅页在用的**未公开文档接口**（`users/balance` 已下线），智谱后续可能调整；失效时状态栏自动降级，不影响正常使用
- 脚本只把 API Key 发往 `open.bigmodel.cn`，不经过任何第三方

## License

[MIT](LICENSE) © 2026 孙韶聪 · [Zecrew](https://github.com/shaocongzeming)
