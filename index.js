/**
 * dsh-notify — a persistent desktop card for DSH.
 *
 * Shows a small always-on-top card when:
 *   - a turn ends (task finished),
 *   - an approval is requested, or
 *   - the agent asks the user a question.
 *
 * The card is a plain WinForms window drawn by popup.ps1. Unlike a Windows
 * toast it never collapses, never re-appears and never moves: it sits in the
 * corner until the user clicks it (which also raises the DSH window), clicks
 * the X, or comes back to DSH.
 *
 * This runtime cannot require('electron') (Cannot find module 'electron'), so
 * everything outside the plugin is done through PowerShell.
 */
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import process from 'node:process'

export const name = 'dsh-notify'

const PLUGIN_DIR = dirname(fileURLToPath(import.meta.url))

const DEFAULTS = {
  enabled: true,
  onTurnEnd: true,
  onApproval: true,
  onQuestion: true,
  muteSubagents: true,
  skipWhenFocused: true,
  notifyOnLoad: true,
  minIntervalMs: 1200,
  autoCloseMs: 0,
  appPattern: '*DeepSeek*',
}

function normalize(raw) {
  const cfg = { ...DEFAULTS }
  if (raw && typeof raw === 'object') {
    for (const key of Object.keys(DEFAULTS)) {
      const value = raw[key]
      if (value !== undefined && value !== null) cfg[key] = value
    }
  }
  cfg.minIntervalMs = Math.max(0, Number(cfg.minIntervalMs) || 0)
  cfg.autoCloseMs = Math.max(0, Number(cfg.autoCloseMs) || 0)
  return cfg
}

function shellExecutable() {
  const winDir = process.env.WINDIR || process.env.SystemRoot
  if (winDir) return `${winDir}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe`
  return 'powershell.exe'
}

/* ------------------------------------------------------------------ *
 * Plugin
 * ------------------------------------------------------------------ */

export function apply(ctx, rawConfig) {
  const cfg = normalize(rawConfig)
  if (!cfg.enabled) return

  let lastShownAt = 0
  let popup = null
  const subagentSessions = new Set()

  function closePopup() {
    if (popup === null) return
    try {
      popup.kill()
    } catch {
      /* the window script may already be gone */
    }
    popup = null
  }

  function showCard(title, body) {
    closePopup()
    try {
      const child = spawn(
        shellExecutable(),
        ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', join(PLUGIN_DIR, 'popup.ps1')],
        {
          windowsHide: true,
          stdio: 'ignore',
          env: {
            ...process.env,
            DSH_POPUP_TITLE: title,
            DSH_POPUP_BODY: body,
            DSH_POPUP_SKIP_IF_FOCUSED: cfg.skipWhenFocused ? '1' : '0',
            DSH_POPUP_AUTOCLOSE_MS: String(cfg.autoCloseMs),
            DSH_POPUP_APP_PATTERN: String(cfg.appPattern || '*DeepSeek*'),
          },
        },
      )
      popup = child
      child.on('exit', () => {
        if (popup === child) popup = null
      })
      child.on('error', () => {
        if (popup === child) popup = null
      })
    } catch {
      popup = null
    }
  }

  function notify(title, body) {
    const now = Date.now()
    if (cfg.minIntervalMs > 0 && now - lastShownAt < cfg.minIntervalMs) return
    lastShownAt = now
    showCard(title, body)
  }

  function sessionTitle(session) {
    try {
      const service = typeof ctx.get === 'function' ? ctx.get('sessionTitle') : undefined
      if (service && typeof service.get === 'function' && session) {
        const snapshot = service.get(session)
        const text = typeof snapshot === 'string' ? snapshot : snapshot && (snapshot.title || snapshot.text)
        const value = String(text == null ? '' : text).trim()
        if (value) return value.slice(0, 120)
      }
    } catch {
      /* the service is optional */
    }
    try {
      if (!session || typeof session !== 'object') return ''
      const candidates = [session.name, session.title, session.label, session.meta && session.meta.title]
      for (const candidate of candidates) {
        const value = String(candidate == null ? '' : candidate).trim()
        if (value) return value.slice(0, 120)
      }
    } catch {
      /* ignore */
    }
    return ''
  }

  function rememberSubagent(info) {
    try {
      const id = info && info.id ? String(info.id) : ''
      if (!id) return
      if (subagentSessions.size > 400) subagentSessions.clear()
      subagentSessions.add(id)
    } catch {
      /* ignore */
    }
  }

  function describeTurn(reason) {
    if (!reason || typeof reason !== 'object') return ''
    const kind = String(reason.kind || reason.type || '')
    if (kind === 'error' || kind === 'failed') {
      const message = reason.error && reason.error.message ? String(reason.error.message) : String(reason.message || '')
      return message ? `（出错：${message.slice(0, 100)}）` : '（出错）'
    }
    if (kind === 'cancelled' || kind === 'aborted') return '（已取消）'
    return ''
  }

  function onSessionEvent(session, event) {
    try {
      if (!event || typeof event !== 'object') return
      const type = String(event.type || '')
      const data = event.data && typeof event.data === 'object' ? event.data : {}
      const sessionId = session && session.id ? String(session.id) : ''
      const isSubagent = sessionId !== '' && subagentSessions.has(sessionId)
      const title = sessionTitle(session)
      const suffix = title ? `\n${title}` : ''

      if (type === 'approval/asked') {
        if (!cfg.onApproval) return
        const tool = String(data.toolName || data.tool || '工具')
        const reason = data.reason ? String(data.reason).slice(0, 120) : ''
        notify('DSH · 需要授权', `工具「${tool}」请求授权${reason ? `：${reason}` : ''}${suffix}`)
        return
      }

      if (type === 'tool/call') {
        if (!cfg.onQuestion) return
        const toolName = String(data.name || data.toolName || '')
        if (toolName === 'ask_user_question') {
          notify('DSH · 需要你回答', `助手在等你回答一个问题${suffix}`)
        }
        return
      }

      if (type === 'turn/end') {
        if (!cfg.onTurnEnd) return
        if (isSubagent && cfg.muteSubagents) return
        notify('DSH · 任务完成', `本轮已结束${describeTurn(data.reason)}${suffix}`)
        return
      }

      if (type === 'turn/start') {
        // The user is back in the app: the card has done its job.
        closePopup()
      }
    } catch {
      /* never break the session event stream */
    }
  }

  ctx.effect(() => {
    const disposeStart = ctx.on('subagent/start', rememberSubagent)
    const disposeEnd = ctx.on('subagent/end', rememberSubagent)
    const disposeEvent = ctx.on('session/event', onSessionEvent)
    return () => {
      try {
        disposeStart && disposeStart()
      } catch {}
      try {
        disposeEnd && disposeEnd()
      } catch {}
      try {
        disposeEvent && disposeEvent()
      } catch {}
      closePopup()
    }
  }, 'dsh-notify: listeners')

  if (cfg.notifyOnLoad) {
    ctx.effect(() => {
      const timer = setTimeout(() => {
        showCard('DSH · 通知已开启', '任务结束或需要授权时，我会在这里提醒你；点一下就回到 DSH，回来自动消失。')
      }, 1500)
      return () => {
        clearTimeout(timer)
        closePopup()
      }
    }, 'dsh-notify: greeting')
  }
}
