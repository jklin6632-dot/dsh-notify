# dsh-notify

[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A **persistent corner card** for [DeepSeek Harness](https://github.com/deepseek-ai) (DSH) on Windows: it tells you when a turn has finished, when a tool is asking for approval, or when the agent is waiting for your answer — and it **stays exactly where it is** until you deal with it.

> 中文摘要：DSH 跑完一轮 / 要求授权 / 等你回答时，在屏幕右下角弹一张**不会被折叠、不会重复弹、不会自己乱跑**的卡片；点它就把 DSH 提到前台，回到 DSH 后 1 秒自动消失。

```
┌────────────────────────────────────────┐
│ DSH · 任务完成                     ✕  │
│ 本轮已结束                             │
│ 权重初始化实验                         │
└────────────────────────────────────────┘
```

## Why not a normal Windows toast

Toasts in an unpackaged desktop app have three problems you cannot work around:

1. They **collapse into the notification centre** after a few seconds — `scenario="reminder"` does not keep them up.
2. Clicking one **dismisses the toast** but does not raise an already-running DSH window.
3. The only way to keep one "visible" is to re-send it every few seconds, which produces the familiar *collapse → pop up again* flicker.

So this plugin draws a plain always-on-top WinForms window (via PowerShell) instead: it stays as long as you like, and every click behaviour is under our control.

## Features

- **Stays put.** No auto-dismiss by default (`autoCloseMs: 0`), never re-shows, never moves.
- **Click = back to DSH.** Clicking the card body raises the DSH window and closes the card.
- **✕ = just close.** Does not touch window focus.
- **Auto-clears when you come back.** Once DSH has focus, the card closes within a second.
- **Quiet when you are already there** (`skipWhenFocused`): no card while DSH is in the foreground.
- **One card at a time.** A new notification closes the previous one instead of stacking.
- **Never steals focus.** `WS_EX_NOACTIVATE` + `ShowWithoutActivation`, so the card cannot interrupt your typing.

## Install

Requires **DSH desktop on Windows** and PowerShell 5.1 (shipped with Windows).

### A. Plugin manager (recommended)

1. Clone/copy this folder somewhere permanent, e.g. `D:\plugins\dsh-notify`.
2. In DSH: **插件 → 安装本地插件**, pick that folder.
3. **Restart DSH.** (Host modules are imported once; hot reload does not apply.)

### B. Manual (junction link)

```powershell
$src = "D:\plugins\dsh-notify"
$dst = "$env:USERPROFILE\.dsh\profiles\desktop\node_modules\dsh-notify"
New-Item -ItemType Junction -Path $dst -Target $src -Force
```

then add `dsh-notify` to `dsh.profile.bundles` in `%USERPROFILE%\.dsh\profiles\desktop\package.json`, and restart DSH.

## Configuration

Edit the `config:` block in [`cordis.patch.yml`](cordis.patch.yml), then restart DSH.

| key | default | meaning |
|---|---|---|
| `enabled` | `true` | master switch |
| `onTurnEnd` | `true` | notify when a turn ends |
| `onApproval` | `true` | notify when a tool asks for approval |
| `onQuestion` | `true` | notify when the agent calls `ask_user_question` |
| `muteSubagents` | `true` | ignore turn ends coming from sub-agents |
| `skipWhenFocused` | `true` | no card while DSH is already in the foreground |
| `notifyOnLoad` | `true` | show a "notifications enabled" card after startup |
| `minIntervalMs` | `1200` | minimum gap between two cards |
| `autoCloseMs` | `0` | auto-close after N ms; `0` = keep it until clicked |
| `appPattern` | `'*DeepSeek*'` | which process names count as "DSH is in front" |

> `appPattern` matters if your DSH desktop build has a different process name. Use anything PowerShell's `-like` accepts, e.g. `'*Harness*'` or `'electron*'`.

## How it works

- **`index.js`** — host half. Listens to `session/event`:
  - `turn/end` → "task finished" (with `（出错：…）` / `（已取消）` suffixes when the end reason says so)
  - `approval/asked` → "needs approval", including the tool name
  - `tool/call` with `ask_user_question` → "waiting for your answer"
  - `turn/start` → the user is back, drop the card
  It tracks `subagent/start` / `subagent/end` so sub-agent turns stay quiet, then `spawn`s `popup.ps1` with the title/body in environment variables.
- **`popup.ps1`** — the window. A borderless, topmost, non-activating WinForms form at the bottom-right corner (`380×104`, dark). A 1 s timer watches whether DSH is in front and closes itself when you are back; clicking calls `user32` to raise DSH and then closes.

## Limitations

- **Windows only.** The card is a PowerShell/WinForms window.
- If script execution is blocked by policy, the card cannot start.
- The card does not appear in the notification centre and makes no sound.
- Host code changes need a DSH restart.

## License

MIT — see [LICENSE](LICENSE).
