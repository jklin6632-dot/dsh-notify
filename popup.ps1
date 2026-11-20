$ErrorActionPreference = 'SilentlyContinue'

# A small always-on-top card that behaves like a notification but simply stays
# where it is: nothing re-shows or re-positions it. It closes when the user
# clicks it (which also raises DSH), clicks the X, returns to DSH, or when the
# optional auto-close timer fires.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$title = $env:DSH_POPUP_TITLE
if ([string]::IsNullOrWhiteSpace($title)) { $title = 'DSH' }
$body = $env:DSH_POPUP_BODY
if ($null -eq $body) { $body = '' }

# Which windows count as "DSH is in front". The desktop build is DeepSeek Harness
# (process names contain "DeepSeek"); override with DSH_POPUP_APP_PATTERN if your
# build is named differently, e.g. "*Harness*" or "electron*".
$appPattern = $env:DSH_POPUP_APP_PATTERN
if ([string]::IsNullOrWhiteSpace($appPattern)) { $appPattern = '*DeepSeek*' }

$logDir = Join-Path $env:LOCALAPPDATA 'dsh-notify'
$null = New-Item -ItemType Directory -Force -Path $logDir
$log = Join-Path $logDir 'popup.log'
function Write-Log([string]$text) { Add-Content -LiteralPath $log -Value ((Get-Date -Format o) + ' ' + $text) }

$sig = @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
'@
$api = Add-Type -MemberDefinition $sig -Name 'DshNotifyPopup' -Namespace 'DshNotify' -PassThru

# A normal TopMost form steals the foreground when it appears, which would both
# interrupt typing and make the "am I back in DSH?" check see the popup itself.
# WS_EX_NOACTIVATE + ShowWithoutActivation keeps the card passive.
$noActivateSource = @'
using System;
using System.Windows.Forms;

public class DshNotifyCard : Form
{
    protected override bool ShowWithoutActivation
    {
        get { return true; }
    }

    protected override CreateParams CreateParams
    {
        get
        {
            const int WS_EX_NOACTIVATE = 0x08000000;
            const int WS_EX_TOOLWINDOW = 0x00000080;
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
            return cp;
        }
    }
}
'@
Add-Type -TypeDefinition $noActivateSource -ReferencedAssemblies System.Windows.Forms, System.Drawing

function Test-DshForeground {
  $handle = $api::GetForegroundWindow()
  if ($handle -eq [IntPtr]::Zero) { return $false }
  $procId = 0
  [void]$api::GetWindowThreadProcessId($handle, [ref]$procId)
  $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
  if ($null -eq $proc) { return $false }
  return ($proc.ProcessName -like $appPattern)
}

function Set-DshForeground {
  try {
    $target = Get-Process | Where-Object { $_.ProcessName -like $appPattern -and $_.MainWindowHandle -ne 0 } |
      Sort-Object -Property WorkingSet64 -Descending | Select-Object -First 1
    if ($null -eq $target) { return $false }
    [void]$api::ShowWindow($target.MainWindowHandle, 9)
    [void]$api::BringWindowToTop($target.MainWindowHandle)
    [void]$api::SetForegroundWindow($target.MainWindowHandle)
    try {
      $shell = New-Object -ComObject WScript.Shell
      [void]$shell.AppActivate($target.Id)
    } catch {}
    return $true
  } catch {
    return $false
  }
}

if ($env:DSH_POPUP_SKIP_IF_FOCUSED -eq '1' -and (Test-DshForeground)) {
  Write-Log 'skip-focused'
  exit 0
}

$form = New-Object DshNotifyCard
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 36)
$form.ForeColor = [System.Drawing.Color]::White

$area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$width = 380
$height = 104
$form.Size = New-Object System.Drawing.Size($width, $height)
$form.Location = New-Object System.Drawing.Point(($area.Right - $width - 18), ($area.Bottom - $height - 18))

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = $title
$titleLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5, [System.Drawing.FontStyle]::Bold)
$titleLabel.ForeColor = [System.Drawing.Color]::White
$titleLabel.Location = New-Object System.Drawing.Point(14, 12)
$titleLabel.Size = New-Object System.Drawing.Size(($width - 44), 22)
$titleLabel.AutoEllipsis = $true

$bodyLabel = New-Object System.Windows.Forms.Label
$bodyLabel.Text = $body
$bodyLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$bodyLabel.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 205)
$bodyLabel.Location = New-Object System.Drawing.Point(14, 36)
$bodyLabel.Size = New-Object System.Drawing.Size(($width - 44), 56)
$bodyLabel.AutoEllipsis = $true

$closeButton = New-Object System.Windows.Forms.Label
$closeButton.Text = [char]0x2715
$closeButton.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$closeButton.ForeColor = [System.Drawing.Color]::FromArgb(160, 160, 165)
$closeButton.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$closeButton.Location = New-Object System.Drawing.Point(($width - 34), 8)
$closeButton.Size = New-Object System.Drawing.Size(26, 26)
$closeButton.Cursor = [System.Windows.Forms.Cursors]::Hand

$form.Controls.Add($titleLabel)
$form.Controls.Add($bodyLabel)
$form.Controls.Add($closeButton)

$closeButton.Add_Click({ Write-Log 'close-button'; $form.Close() })
$titleLabel.Add_Click({ Write-Log 'title-click'; [void](Set-DshForeground); $form.Close() })
$bodyLabel.Add_Click({ Write-Log 'body-click'; [void](Set-DshForeground); $form.Close() })
$form.Add_Click({ Write-Log 'form-click'; [void](Set-DshForeground); $form.Close() })

# Close automatically once the user is back in DSH. DSH_POPUP_KEEP=1 disables
# that (self test only). DSH_POPUP_AUTOCLOSE_MS>0 closes it after that delay.
$keep = $env:DSH_POPUP_KEEP -eq '1'
if (-not $keep) {
  $focusTimer = New-Object System.Windows.Forms.Timer
  $focusTimer.Interval = 1000
  $focusTimer.Add_Tick({
    if (Test-DshForeground) {
      Write-Log 'dsh-foreground'
      $form.Close()
    }
  })
  $focusTimer.Start()
}

$autoCloseMs = 0
if (-not $keep) { [void][int]::TryParse($env:DSH_POPUP_AUTOCLOSE_MS, [ref]$autoCloseMs) }
if ($autoCloseMs -gt 0) {
  $autoTimer = New-Object System.Windows.Forms.Timer
  $autoTimer.Interval = $autoCloseMs
  $autoTimer.Add_Tick({ Write-Log 'autoclose'; $form.Close() })
  $autoTimer.Start()
}

Write-Log ("shown title=" + $title)
[void]$form.ShowDialog()
if ($focusTimer) { $focusTimer.Stop() }
if ($autoTimer) { $autoTimer.Stop() }
Write-Log 'closed'
