# device-lab / panel.ps1
# Живая панель телефона в браузере: кадры экрана, клик = тап, перетаскивание =
# свайп, колесо = прокрутка, плюс консоль JS в WebView, logcat, shell и
# управление приложениями. Локальный сервер, наружу ничего не отдаёт.
#
#   .\panel.ps1 -Action start [-Port 8099]
#   .\panel.ps1 -Action stop | status | open | run

[CmdletBinding()]
param(
  [string]$Action = 'start',
  [int]$Port = 8099,
  [switch]$Run,
  [switch]$NoBrowser
)

. (Join-Path $PSScriptRoot 'lib\common.ps1')

$Lab = Get-LabRoot
$State = Join-Path $Lab 'lab-state'
if (-not (Test-Path $State)) { New-Item -ItemType Directory -Force -Path $State | Out-Null }
$PidFile = Join-Path $State 'panel.pid'
$PortFile = Join-Path $State 'panel.port'
$Shots = Join-Path $Lab 'shots'

function Panel-Url { return "http://127.0.0.1:$Port/" }

function Panel-Status {
  try {
    $r = Invoke-WebRequest -Uri (Panel-Url) -UseBasicParsing -TimeoutSec 3
    return ($r.StatusCode -eq 200)
  } catch { return $false }
}

if ($Action -eq 'status') {
  $ok = Panel-Status
  Write-Host ("панель: " + (Panel-Url) + "  " + $(if ($ok) { 'работает' } else { 'не работает' }))
  if (Test-Path $PidFile) { Write-Host ('pid: ' + (Get-Content $PidFile -ErrorAction SilentlyContinue)) }
  exit $(if ($ok) { 0 } else { 1 })
}

if ($Action -eq 'stop') {
  # Убиваем все процессы панели, а не только тот, что записан в pid-файле:
  # иначе после ручного перезапуска остаётся «призрак», который держит порт
  # и отвечает старым кодом.
  $killed = 0
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*panel.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; $killed++ }
  Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
  Write-Host "панель остановлена (процессов: $killed)"
  exit 0
}

if ($Action -eq 'open') { Start-Process (Panel-Url); exit 0 }

if ($Action -eq 'start' -and -not $Run) {
  if (Panel-Status) { Write-Host ('панель уже работает: ' + (Panel-Url)); exit 0 }
  $self = '"' + (Join-Path $PSScriptRoot 'panel.ps1') + '"'
  $p = Start-Process powershell -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
      '-File', $self, '-Run', '-Port', $Port
    ) -RedirectStandardOutput (Join-Path $State 'panel.log') -RedirectStandardError (Join-Path $State 'panel.err') -WindowStyle Hidden -PassThru
  Set-Content -Path $PidFile -Value $p.Id
  Set-Content -Path $PortFile -Value $Port
  $ready = $false
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    if (Panel-Status) { $ready = $true; break }
  }
  if ($ready) {
    Write-Host ('панель: ' + (Panel-Url) + '  pid ' + $p.Id)
    if (-not $NoBrowser) { Start-Process (Panel-Url) }
  } else {
    Write-Host 'панель не поднялась: смотри лог ' (Join-Path $State 'panel.log')
  }
  exit $(if ($ready) { 0 } else { 1 })
}

# ---------------- сервер ----------------

if (-not $Run) { Write-Host 'укажите -Action start или -Run'; exit 1 }

$HtmlPath = Join-Path $PSScriptRoot 'panel.html'
if (-not (Test-Path $HtmlPath)) { throw 'Нет panel.html' }
$script:Html = [System.IO.File]::ReadAllText($HtmlPath, [System.Text.Encoding]::UTF8)

$script:ShotCache = @{ bytes = $null; at = [datetime]::MinValue }
$script:ShotPath = Join-Path $State 'live.png'

function Get-LiveBytes {
  $now = [datetime]::UtcNow
  if ($script:ShotCache.bytes -and ($now - $script:ShotCache.at).TotalMilliseconds -lt 220) {
    return $script:ShotCache.bytes
  }
  try {
    Save-Screenshot -Path $script:ShotPath | Out-Null
    $b = [System.IO.File]::ReadAllBytes($script:ShotPath)
    $script:ShotCache = @{ bytes = $b; at = $now }
    return $b
  } catch {
    return $null
  }
}

function Send-Bytes($ctx, [byte[]]$bytes, [string]$type) {
  if (-not $bytes -or $bytes.Length -eq 0) { $ctx.Response.StatusCode = 500; $ctx.Response.Close(); return }
  $ctx.Response.ContentType = $type
  $ctx.Response.AddHeader('Cache-Control', 'no-store, no-cache, must-revalidate')
  $ctx.Response.ContentLength64 = $bytes.Length
  $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $ctx.Response.OutputStream.Close()
}

function Send-Text($ctx, [string]$text, [string]$type = 'text/plain; charset=utf-8') {
  Send-Bytes $ctx ([System.Text.Encoding]::UTF8.GetBytes($text)) $type
}

function Send-Json($ctx, $obj) {
  Send-Text $ctx ($obj | ConvertTo-Json -Depth 6) 'application/json; charset=utf-8'
}

function Q($ctx, [string]$name, [string]$def = '') {
  $v = $ctx.Request.QueryString[$name]
  if ($v -and "$v" -ne '') { return "$v" }
  return $def
}

function Read-BodyText($ctx) {
  $sr = New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)
  $t = $sr.ReadToEnd()
  $sr.Close()
  return $t
}

function Read-BodyBytes($ctx) {
  $ms = New-Object System.IO.MemoryStream
  $ctx.Request.InputStream.CopyTo($ms)
  $b = $ms.ToArray()
  $ms.Close()
  return $b
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Set-Content -Path $PidFile -Value $PID
Set-Content -Path $PortFile -Value $Port
Write-Host ("device-lab panel on " + (Panel-Url))

while ($true) {
  $ctx = $null
  try {
    $ctx = $listener.GetContext()
    $path = $ctx.Request.Url.AbsolutePath
    $method = $ctx.Request.HttpMethod

    switch -Regex ($path) {

      '^/$' {
        Send-Text $ctx $script:Html 'text/html; charset=utf-8'
      }

      '^/api/shot\.png$' {
        $b = Get-LiveBytes
        Send-Bytes $ctx $b 'image/png'
      }

      '^/api/info$' {
        Send-Json $ctx (Get-DeviceInfo)
      }

      '^/api/packages$' {
        $sys = (Q $ctx 'system') -eq '1'
        Send-Json $ctx @{ packages = @(Get-Packages -System:$sys) }
      }

      '^/api/tap$' {
        Invoke-Adb -Args @('shell', 'input', 'tap', (Q $ctx 'x'), (Q $ctx 'y')) -Quiet | Out-Null
        Send-Text $ctx 'ok'
      }

      '^/api/press$' {
        $x = Q $ctx 'x'; $y = Q $ctx 'y'; $ms = Q $ctx 'ms' '800'
        Invoke-Adb -Args @('shell', 'input', 'swipe', $x, $y, $x, $y, $ms) -Quiet | Out-Null
        Send-Text $ctx 'ok'
      }

      '^/api/swipe$' {
        Invoke-Adb -Args @('shell', 'input', 'swipe', (Q $ctx 'x1'), (Q $ctx 'y1'), (Q $ctx 'x2'), (Q $ctx 'y2'), (Q $ctx 'ms' '350')) -Quiet | Out-Null
        Send-Text $ctx 'ok'
      }

      '^/api/key$' {
        $code = Q $ctx 'code'
        $map = @{ back = 4; home = 3; power = 26; recents = 187; menu = 82; enter = 66; del = 67; up = 19; down = 20; left = 21; right = 22 }
        if ($map.ContainsKey($code.ToLower())) { $code = $map[$code.ToLower()] }
        Invoke-Adb -Args @('shell', 'input', 'keyevent', $code) -Quiet | Out-Null
        Send-Text $ctx "key $code"
      }

      '^/api/shot-save$' {
        $name = Q $ctx 'name'
        if (-not $name) { $name = (Get-Date -Format 'yyyyMMdd-HHmmss') }
        $name = $name -replace '[^A-Za-z0-9._-]', '_'
        if (-not (Test-Path $Shots)) { New-Item -ItemType Directory -Force -Path $Shots | Out-Null }
        $p = Save-Screenshot -Path (Join-Path $Shots ($name + '.png'))
        Send-Text $ctx $p
      }

      '^/api/js$' {
        $expr = Read-BodyText $ctx
        try {
          $v = Invoke-Eval -Expr $expr
          Send-Text $ctx ("OK  " + $v)
        } catch {
          Send-Text $ctx ("ERR  " + $_.Exception.Message)
        }
      }

      '^/api/shell$' {
        $cmd = Read-BodyText $ctx
        $out = Invoke-Adb -Args (@('shell') + $cmd.Split(' '))
        Send-Text $ctx (($out -join "`n"))
      }

      '^/api/logs$' {
        $n = [int](Q $ctx 'n' '60')
        $f = Q $ctx 'filter'
        $args = @('logcat', '-d', '-t', '300')
        if ($f) { $args = @('logcat', '-d', '-t', '2000') }
        $out = Invoke-Adb -Args $args -Quiet
        if ($f) { $out = $out | Select-String -Pattern $f }
        Send-Text $ctx (($out | Select-Object -Last $n) -join "`n")
      }

      '^/api/app$' {
        $pkg = Q $ctx 'pkg'
        $op = Q $ctx 'op'
        switch ($op) {
          'launch' { Invoke-Adb -Args @('shell', 'am', 'start', '-n', "$pkg/$($pkg).MainActivity") -Quiet | Out-Null }
          'stop' { Invoke-Adb -Args @('shell', 'am', 'force-stop', $pkg) -Quiet | Out-Null }
          'clear' { Invoke-Adb -Args @('shell', 'pm', 'clear', $pkg) -Quiet | Out-Null }
          default { Send-Text $ctx 'unknown op'; break }
        }
        Send-Text $ctx 'ok'
      }

      '^/api/install$' {
        $name = (Q $ctx 'name' 'app.apk') -replace '[^A-Za-z0-9._-]', '_'
        $tmp = Join-Path $State $name
        [System.IO.File]::WriteAllBytes($tmp, (Read-BodyBytes $ctx))
        $out = Invoke-Adb -Args @('install', '-r', $tmp)
        Send-Text $ctx (($out -join "`n"))
      }

      '^/api/sys$' {
        $op = Q $ctx 'op'
        $v = Q $ctx 'v'
        switch ($op) {
          'unlock' {
            Invoke-Adb -Args @('shell', 'input', 'keyevent', '224') -Quiet | Out-Null
            Start-Sleep -Milliseconds 250
            Invoke-Adb -Args @('shell', 'input', 'swipe', '360', '1300', '360', '400', '250') -Quiet | Out-Null
            Invoke-Adb -Args @('shell', 'input', 'keyevent', '82') -Quiet | Out-Null
          }
          'anim' { foreach ($k in @('window_animation_scale', 'transition_animation_scale', 'animator_duration_scale')) { Invoke-Adb -Args @('shell', 'settings', 'put', 'global', $k, $v) -Quiet | Out-Null } }
          'font' { Invoke-Adb -Args @('shell', 'settings', 'put', 'system', 'font_scale', $v) -Quiet | Out-Null }
          'size' { Invoke-Adb -Args @('shell', 'wm', 'size', $v) -Quiet | Out-Null }
          'sizeReset' { Invoke-Adb -Args @('shell', 'wm', 'size', 'reset') -Quiet | Out-Null; Invoke-Adb -Args @('shell', 'wm', 'density', 'reset') -Quiet | Out-Null }
          'density' { Invoke-Adb -Args @('shell', 'wm', 'density', $v) -Quiet | Out-Null }
          'night' { Invoke-Adb -Args @('shell', 'cmd', 'uimode', 'night', $v) -Quiet | Out-Null }
          'pointer' { Invoke-Adb -Args @('shell', 'settings', 'put', 'system', 'pointer_location', $v) -Quiet | Out-Null; Invoke-Adb -Args @('shell', 'settings', 'put', 'system', 'show_touches', $v) -Quiet | Out-Null }
          'rotate' { Invoke-Adb -Args @('shell', 'settings', 'put', 'system', 'user_rotation', $v) -Quiet | Out-Null }
          'quiet' {
            $keep = @('ru.mooddiary', 'ru.chronicnotebook', 'com.android.adbkeyboard', 'com.android.systemui')
            foreach ($p in (Get-Packages)) {
              if ($keep -contains $p) { continue }
              if ($p -like 'com.android.*') { continue }
              Invoke-Adb -Args @('shell', 'am', 'force-stop', $p) -Quiet | Out-Null
            }
          }
          'reboot' { Invoke-Adb -Args @('shell', 'reboot') -Quiet | Out-Null }
          default { Send-Text $ctx 'unknown op'; break }
        }
        Send-Text $ctx 'ok'
      }

      default { Send-Text $ctx 'not found' }
    }
  } catch {
    try {
      if ($ctx) { $ctx.Response.StatusCode = 500; Send-Text $ctx ("ERR " + $_.Exception.Message) }
    } catch { }
  }
}