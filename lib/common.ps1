# device-lab: общие функции для phone.ps1, panel.ps1, run.ps1
# PowerShell 5.1, без внешних зависимостей.

$script:AdbPath = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
if (-not (Test-Path $script:AdbPath)) { $script:AdbPath = 'adb' }

$script:DevToolsPort = 9224
$script:WebViewOffsetX = 0
$script:WebViewOffsetY = 0

function Get-LabRoot {
  return (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
}

# Вызов adb. -Bin: вернуть сырой stdout как байты (для screencap).
function Invoke-Adb {
  param(
    [Parameter(Mandatory = $true)][string[]]$Args,
    [switch]$Quiet
  )
  $out = & $script:AdbPath @Args 2>&1
  if ($LASTEXITCODE -ne 0 -and -not $Quiet) {
    Write-Warning ("adb " + ($Args -join ' ') + " -> " + ($out -join ' '))
  }
  return $out
}

function Get-ScreenSize {
  <# Физический размер экрана как @{w=;h=}.
     При `wm size 1080x2400` вывод содержит и Override, и Physical: брать надо
     Override, иначе всё, что шире 720 px, ошибочно считается вылетом за экран.

     В альбомной ориентации ширину и высоту меняем местами: `wm size` всегда
     отдаёт размеры «как у портрета», а узлы uiautomator уже лежат в
     повёрнутой системе координат. Без этого весь альбомный прогон
     наполняется ложными «выходит за экран». #>
  $out = (Invoke-Adb -Args @('shell', 'wm', 'size') -Quiet) -join ' '
  $size = $null
  if ($out -match 'Override size:\s*(\d+)x(\d+)') {
    $size = @{ w = [int]$Matches[1]; h = [int]$Matches[2]; override = $true }
  } elseif ($out -match 'Physical size:\s*(\d+)x(\d+)') {
    $size = @{ w = [int]$Matches[1]; h = [int]$Matches[2]; override = $false }
  } elseif ($out -match '(\d+)x(\d+)') {
    $size = @{ w = [int]$Matches[1]; h = [int]$Matches[2]; override = $false }
  } else {
    $size = @{ w = 720; h = 1612; override = $false }
  }
  $rot = (Invoke-Adb -Args @('shell', 'settings', 'get', 'system', 'user_rotation') -Quiet |
    Select-Object -First 1)
  if ("$rot".Trim() -eq '1') {
    $tmp = $size.w; $size.w = $size.h; $size.h = $tmp
  }
  return $size
}

function Save-Screenshot {
  <# Скриншот в файл. Через .NET Process, а не cmd: не портится двоичный
     вывод и не нужен промежуточный cmd.exe — заметно быстрее. #>
  param([Parameter(Mandatory = $true)][string]$Path)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  if (Test-Path $Path) { Remove-Item $Path -Force -ErrorAction SilentlyContinue }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $script:AdbPath
  $psi.Arguments = 'exec-out screencap -p'
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $proc = [System.Diagnostics.Process]::Start($psi)
  $fs = [System.IO.File]::Create($Path)
  $proc.StandardOutput.BaseStream.CopyTo($fs)
  $fs.Close()
  $proc.WaitForExit()
  $len = 0
  if (Test-Path $Path) { $len = (Get-Item $Path).Length }
  if ($len -lt 2000) {
    Invoke-Adb -Args @('shell', 'screencap', '-p', '/sdcard/__lab_shot.png') -Quiet | Out-Null
    Invoke-Adb -Args @('pull', '/sdcard/__lab_shot.png', $Path) -Quiet | Out-Null
    Invoke-Adb -Args @('shell', 'rm', '-f', '/sdcard/__lab_shot.png') -Quiet | Out-Null
  }
  if (-not (Test-Path $Path)) { throw 'Скриншот не сохранён: ' + $Path }
  return $Path
}

# ---- WebView DevTools: свой клиент, чтобы не зависеть от temp-хелперов ----

function Get-PackageForPid {
  param([Parameter(Mandatory = $true)][string]$ProcId)
  $out = Invoke-Adb -Args @('shell', 'ps', '-A') -Quiet
  foreach ($l in $out) {
    # ps -A: USER PID PPID VSZ RSS WCHAN ADDR S NAME — берём последний столбец
    if ("$l" -match '^\S+\s+' + [regex]::Escape($ProcId) + '\s+.*\s+(\S+)\s*$') { return $Matches[1] }
  }
  return ''
}

function Get-ForegroundPackage {
  $out = Invoke-Adb -Args @('shell', 'dumpsys', 'activity', 'activities') -Quiet
  foreach ($l in $out) {
    if ("$l" -match 'ResumedActivity:.*?([a-zA-Z0-9_.]+)/[a-zA-Z0-9_.]+') { return $Matches[1] }
  }
  return ''
}

function Assert-AppForeground {
  <# Перед тапом проверяем, что приложение действительно на экране.
     Иначе тапы уходят мимо, а JS продолжает отвечать — выглядит как «всё сломалось». #>
  param([string]$Package, [switch]$AutoFix)
  if (-not $Package) { return $true }
  $fg = Get-ForegroundPackage
  if ($fg -eq $Package) { return $true }
  Write-Warning "на экране '$fg', а не '$Package' — тап ушёл бы мимо"
  if (-not $AutoFix) { return $false }
  Invoke-Adb -Args @('shell', 'am', 'start', '-n', "$Package/$($Package).MainActivity") -Quiet | Out-Null
  for ($i = 0; $i -lt 12; $i++) {
    Start-Sleep -Milliseconds 500
    if ((Get-ForegroundPackage) -eq $Package) {
      Start-Sleep -Milliseconds 800
      Write-Host '  приложение возвращено на экран'
      return $true
    }
  }
  throw "не удалось вывести $Package на экран (сейчас на экране '$(Get-ForegroundPackage)')"
}

function Get-ApkInfo {
  <# Имя пакета и версии из APK через aapt (нужно, чтобы остановить
     приложение перед установкой: иначе после install -r продолжает работать
     старый процесс, и правка в коде не видна). #>
  param([Parameter(Mandatory = $true)][string]$Apk)
  $sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
  $aapt = Get-ChildItem (Join-Path $sdk 'build-tools') -Filter 'aapt.exe' -Recurse -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1
  if (-not $aapt) { return @{ package = ''; versionCode = ''; versionName = '' } }
  $out = & $aapt.FullName dump badging $Apk 2>$null
  $info = @{ package = ''; versionCode = ''; versionName = ''; label = '' }
  foreach ($l in $out) {
    if ($l -match "^package: name='([^']+)'") { $info.package = $Matches[1] }
    elseif ($l -match "versionCode='(\d+)'") { $info.versionCode = $Matches[1] }
    elseif ($l -match "versionName='([^']+)'") { $info.versionName = $Matches[1] }
    elseif ($l -match "^application-label:'([^']+)'") { $info.label = $Matches[1] }
  }
  return $info
}

function Get-LaunchComponent {
  <# Компонент запуска пакета. У debug-сборок applicationId с суффиксом .debug,
     а класс Activity остаётся прежним, поэтому "$pkg/$pkg.MainActivity" неверно —
     спрашиваем систему. #>
  param([Parameter(Mandatory = $true)][string]$Package)
  $out = (Invoke-Adb -Args @('shell', 'cmd', 'package', 'resolve-activity', '--brief', '-c', 'android.intent.category.LAUNCHER', $Package) -Quiet) -join ' '
  $out = ($out -replace '.*\r?\n', '')
  if ($out -match '([A-Za-z0-9_.]+/[A-Za-z0-9_.]+)') { return $Matches[1] }
  return "$Package/$Package.MainActivity"
}

function Invoke-Launch {
  param([Parameter(Mandatory = $true)][string]$Package)
  $comp = Get-LaunchComponent -Package $Package
  Invoke-Adb -Args @('shell', 'am', 'start', '-n', $comp) | Out-Null
  return $comp
}

function Get-UiNodes {
  <# Дерево доступности нативного экрана (uiautomator).
     Для WebView-приложений оно пустое — там работают js/tapel. #>
  param([switch]$Refresh, [int]$MaxAgeSec = 15)
  $local = Join-Path (Get-LabRoot) 'lab-state\ui.xml'
  $fresh = (Test-Path $local) -and (((Get-Date) - (Get-Item $local).LastWriteTime).TotalSeconds -lt $MaxAgeSec)
  if ($Refresh -or -not $fresh) {
    Invoke-Adb -Args @('shell', 'uiautomator', 'dump', '/sdcard/__lab_ui.xml') -Quiet | Out-Null
    Invoke-Adb -Args @('pull', '/sdcard/__lab_ui.xml', $local) -Quiet | Out-Null
  }
  [xml]$x = [System.IO.File]::ReadAllText($local, [System.Text.Encoding]::UTF8)
  $nodes = New-Object System.Collections.Generic.List[object]
  foreach ($n in $x.SelectNodes('//node')) {
    $t = $n.GetAttribute('text'); $d = $n.GetAttribute('content-desc')
    $cls = $n.GetAttribute('class')
    # Поля ввода у Compose приходят без текста, но нам до них нужно тапать
    if (-not $t -and -not $d -and $cls -notlike '*EditText*') { continue }
    $b = $n.GetAttribute('bounds')
    $x1 = 0; $y1 = 0; $x2 = 0; $y2 = 0
    if ($b -match '\[(\d+),(\d+)\]\[(\d+),(\d+)\]') {
      $x1 = [int]$Matches[1]; $y1 = [int]$Matches[2]; $x2 = [int]$Matches[3]; $y2 = [int]$Matches[4]
    }
    $clickable = ($n.GetAttribute('clickable') -eq 'true')
    # Compose отдаёт подпись отдельным узлом с нулевыми границами, а кликабельный
    # родитель — без текста. Поэтому берём ближайшего предка с реальной рамкой.
    $cur = $n.ParentNode
    while ($cur -and ($x2 -le $x1 -or $y2 -le $y1)) {
      $ab = $cur.GetAttribute('bounds')
      if ($ab -match '\[(\d+),(\d+)\]\[(\d+),(\d+)\]') {
        $ax1 = [int]$Matches[1]; $ay1 = [int]$Matches[2]; $ax2 = [int]$Matches[3]; $ay2 = [int]$Matches[4]
        if ($ax2 -gt $ax1 -and $ay2 -gt $ay1) {
          $x1 = $ax1; $y1 = $ay1; $x2 = $ax2; $y2 = $ay2
          if (-not $clickable -and $cur.GetAttribute('clickable') -eq 'true') { $clickable = $true }
        }
      }
      $cur = $cur.ParentNode
    }
    $nodes.Add(@{
        text = $t; desc = $d; cls = $cls; clickable = $clickable
        bounds = "[$x1,$y1][$x2,$y2]"; x1 = $x1; y1 = $y1; x2 = $x2; y2 = $y2
        x = [int](($x1 + $x2) / 2); y = [int](($y1 + $y2) / 2)
      })
  }
  return $nodes
}

function Find-UiNode {
  <# Поиск по подписи: сначала точное совпадение, потом начало строки, потом
     вхождение — иначе запрос «Замер» находит «нужно 14 корректных замеров». #>
  param([Parameter(Mandatory = $true)][string]$Text, [switch]$Exact, [switch]$ClickableOnly, [string]$Class, [switch]$Refresh)
  $nodes = @(Get-UiNodes -Refresh:$Refresh | Where-Object { $_.x2 -gt $_.x1 -and $_.y2 -gt $_.y1 })
  $q = $Text.ToLower()
  $cands = @($nodes | Where-Object {
      $label = ("$($_.text) $($_.desc)").Trim()
      if (-not $label) { return $false }
      if ($ClickableOnly -and -not $_.clickable) { return $false }
      if ($Class -and $_.cls -notlike "*$Class*") { return $false }
      return $true
    })
  $res = @()
  if ($Exact) {
    $res = @($cands | Where-Object { $_.text -eq $Text -or $_.desc -eq $Text })
  } else {
    $res = @($cands | Where-Object { ("$($_.text)$($_.desc)").ToLower() -eq $q })
    if (-not $res) { $res = @($cands | Where-Object { ("$($_.text)$($_.desc)").ToLower().StartsWith($q) }) }
    if (-not $res) { $res = @($cands | Where-Object { ("$($_.text) $($_.desc)").ToLower() -like "*$q*" }) }
  }
  if ($res.Count -gt 1) {
    $clickable = @($res | Where-Object { $_.clickable })
    if ($clickable.Count -gt 0) { $res = $clickable }
  }
  return $res
}

function Get-WebViewTarget {
  param([switch]$Refresh)
  # Ищем процесс приложения на экране: так лаборатория работает с любым
  # приложением с WebView, а не только с двумя «своими».
  $pid_ = ''
  $fg = Get-ForegroundPackage
  if ($fg) { $pid_ = "$(Invoke-Adb -Args @('shell', 'pidof', $fg) -Quiet | Select-Object -First 1)".Trim() }
  if (-not $pid_) {
    foreach ($pkg in @('ru.mooddiary', 'ru.chronicnotebook', 'ru.drevo.yazyka')) {
      $p = "$(Invoke-Adb -Args @('shell', 'pidof', $pkg) -Quiet | Select-Object -First 1)".Trim()
      if ($p) { $pid_ = $p; break }
    }
  }
  if (-not $pid_) { throw 'Приложение не запущено: WebView-таргет не найден' }
  Invoke-Adb -Args @('forward', '--remove', "tcp:$($script:DevToolsPort)") -Quiet | Out-Null
  Invoke-Adb -Args @('forward', "tcp:$($script:DevToolsPort)", "localabstract:webview_devtools_remote_$pid_") -Quiet | Out-Null
  Start-Sleep -Milliseconds 400
  try {
    $pages = Invoke-RestMethod -Uri "http://127.0.0.1:$($script:DevToolsPort)/json" -TimeoutSec 8
  } catch {
    throw "DevTools не отвечает: $($_.Exception.Message)"
  }
  $page = $pages | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
  if (-not $page) { throw 'Страница WebView не найдена в /json' }
  return @{ url = $page.webSocketDebuggerUrl; title = $page.title; pid = $pid_; pkg = (Get-PackageForPid -ProcId $pid_) }
}

function Invoke-Eval {
  <# Выполнить JS в WebView и вернуть значение последнего выражения. #>
  param(
    [Parameter(Mandatory = $true)][string]$Expr,
    [int]$TimeoutSec = 20
  )
  $target = Get-WebViewTarget
  $ws = [System.Net.WebSockets.ClientWebSocket]::new()
  $cts = [System.Threading.CancellationTokenSource]::new($TimeoutSec * 1000)
  try {
    $null = $ws.ConnectAsync([Uri]$target.url, $cts.Token).GetAwaiter().GetResult()
    $payload = @{
      id = 1
      method = 'Runtime.evaluate'
      params = @{
        expression = $Expr
        returnByValue = $true
        awaitPromise = $true
        userGesture = $true
      }
    } | ConvertTo-Json -Depth 8 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $null = $ws.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult()

    $acc = New-Object System.Collections.Generic.List[byte]
    $buf = New-Object byte[] 131072
    do {
      $r = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), $cts.Token).GetAwaiter().GetResult()
      for ($i = 0; $i -lt $r.Count; $i++) { $acc.Add($buf[$i]) }
    } while (-not $r.EndOfMessage)
    $text = [System.Text.Encoding]::UTF8.GetString($acc.ToArray())
  } finally {
    $ws.Dispose()
  }
  $o = $text | ConvertFrom-Json
  if ($o.result.exceptionDetails) {
    throw ('JS: ' + $o.result.exceptionDetails.text + ' ' + $(if ($o.result.exceptionDetails.exception) { $o.result.exceptionDetails.exception.description } else { '' }))
  }
  $res = $o.result.result
  if ($null -eq $res.value) {
    if ($res.description) { return $res.description }
    return 'undefined'
  }
  if ($res.value -is [bool]) { return $(if ($res.value) { 'true' } else { 'false' }) }
  return "$($res.value)"
}

function Get-BarInsets {
  <# Физические размеры системных полос из dumpsys window.
     У WebView innerHeight не учитывает полосы и меняется от клавиатуры,
     поэтому берём рамку окна StatusBar напрямую — она ни от чего не зависит. #>
  param([switch]$Refresh)

  $file = Join-Path (Get-LabRoot) 'lab-state\bars.json'
  if (-not $Refresh -and (Test-Path $file)) {
    try {
      $j = Get-Content $file -Raw | ConvertFrom-Json
      if ($j.top -gt 0) { return @{ top = [int]$j.top; bottom = [int]$j.bottom } }
    } catch { }
  }
  $size = Get-ScreenSize
  $all = Invoke-Adb -Args @('shell', 'dumpsys', 'window', 'windows') -Quiet
  $res = @{ top = 0; bottom = 0 }
  $cur = ''
  foreach ($line in $all) {
    if ("$line" -match 'Window\{[^}]*\s(StatusBar|NavigationBar)[^}]*\}') {
      $cur = $Matches[1]
    } elseif ($cur -and "$line" -match 'mFrame=\[(\d+),(\d+)\]\[(\d+),(\d+)\]') {
      # Статус-бар начинается с y=0, поэтому его «отступ сверху» — это высота рамки.
      if ($cur -eq 'StatusBar') { $res.top = [int]$Matches[4] - [int]$Matches[2] }
      if ($cur -eq 'NavigationBar') { $res.bottom = $size.h - [int]$Matches[2] }
      $cur = ''
    }
  }
  if ($res.top -gt 0) {
    if (-not (Test-Path (Split-Path -Parent $file))) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null }
    $res | ConvertTo-Json | Set-Content -Path $file
  }
  return $res
}

function Get-ElementCenter {
  <# Центр элемента в координатах экрана (тап-координаты для adb).
     Прокрутка может быть плавной (scroll-behavior: smooth), поэтому координаты
     читаем только после того, как прямоугольник перестал меняться: иначе тап
     уходит мимо. #>
  param([Parameter(Mandatory = $true)][string]$Selector)
  $sel = $Selector.Replace("'", "\'")
  $jsRect = "(function(){var e=document.querySelector('" + $sel + "') || document.getElementById('" + $sel + "'); if(!e) return 'null'; var b=e.getBoundingClientRect(); return JSON.stringify({x:b.left+b.width/2, y:b.top+b.height/2, w:b.width, h:b.height, top:b.top, vh:window.innerHeight, dpr:window.devicePixelRatio});})()"
  $pre = "(function(){var e=document.querySelector('" + $sel + "') || document.getElementById('" + $sel + "'); if(!e) return 'missing'; e.scrollIntoView({block:'center',inline:'center',behavior:'auto'}); return 'scrolled';})()"
  Invoke-Eval -Expr $pre | Out-Null

  $json = $null; $last = ''; $stable = 0
  for ($i = 0; $i -lt 14; $i++) {
    Start-Sleep -Milliseconds 220
    $json = Invoke-Eval -Expr $jsRect
    if ($json -eq $last -and $json -ne 'null') { $stable++ } else { $stable = 0 }
    $last = $json
    if ($stable -ge 2) { break }
  }
  if (-not $json -or $json -eq 'null') { throw 'Элемент не найден: ' + $Selector }
  $o = $json | ConvertFrom-Json
  if ($o.w -le 0 -or $o.h -le 0) { throw 'Элемент невидим: ' + $Selector }
  $bars = Get-BarInsets
  $x = [int][math]::Round($o.x * $o.dpr + $script:WebViewOffsetX)
  $y = [int][math]::Round($o.y * $o.dpr + $bars.top + $script:WebViewOffsetY)
  return @{ x = $x; y = $y; w = $o.w; h = $o.h; topBar = $bars.top; innerH = $o.vh }
}

function Get-WebViewCenter {
  <# То же, что Get-ElementCenter, но с проверкой, что приложение на экране. #>
  param([Parameter(Mandatory = $true)][string]$Selector)
  $t = Get-WebViewTarget
  Assert-AppForeground -Package $t.pkg -AutoFix | Out-Null
  $p = Get-ElementCenter -Selector $Selector
  $p.pkg = $t.pkg
  return $p
}

function Get-Packages {
  param([switch]$System)
  $args = @('shell', 'pm', 'list', 'packages')
  if (-not $System) { $args += '-3' }
  $out = Invoke-Adb -Args $args -Quiet
  return @($out | ForEach-Object { "$_" -replace '^package:', '' } | Where-Object { $_ })
}

function Get-DeviceInfo {
  $size = Get-ScreenSize
  $model = (Invoke-Adb -Args @('shell', 'getprop', 'ro.product.model') -Quiet | Select-Object -First 1)
  $rel = (Invoke-Adb -Args @('shell', 'getprop', 'ro.build.version.release') -Quiet | Select-Object -First 1)
  $sdk = (Invoke-Adb -Args @('shell', 'getprop', 'ro.build.version.sdk') -Quiet | Select-Object -First 1)
  $density = (Invoke-Adb -Args @('shell', 'wm', 'density') -Quiet | Select-Object -First 1)
  $font = (Invoke-Adb -Args @('shell', 'settings', 'get', 'system', 'font_scale') -Quiet | Select-Object -First 1)
  $night = (Invoke-Adb -Args @('shell', 'cmd', 'uimode', 'night') -Quiet | Select-Object -First 1)
  $batt = (Invoke-Adb -Args @('shell', 'dumpsys', 'battery') -Quiet)
  $level = ($batt | Select-String -Pattern 'level:\s*(\d+)').Matches.Groups[1].Value
  $temp = ($batt | Select-String -Pattern 'temperature:\s*(\d+)').Matches.Groups[1].Value
  $focus = (Invoke-Adb -Args @('shell', 'dumpsys', 'activity', 'activities') -Quiet | Select-String -Pattern 'ResumedActivity' | Select-Object -First 1)
$free = (Invoke-Adb -Args @('shell', 'df', '-k', '/data') -Quiet | Select-Object -Last 1)
$focusText = "$focus"
if ($focusText -match '([A-Za-z0-9_.]+)/([A-Za-z0-9_.]+)') { $focusText = $Matches[1] } elseif ($focusText) { $focusText = $focusText.Trim() }
$freeText = "$free".Trim()
  return [ordered]@{
    model = "$model".Trim(); android = "$rel".Trim(); sdk = "$sdk".Trim()
    width = $size.w; height = $size.h; density = ("$density" -replace '.*?(\d+)$', '$1')
    fontScale = "$font".Trim(); night = ("$night" -replace '.*?:\s*', '')
    battery = "$level"; tempC = [math]::Round(([int]$temp) / 10.0, 1)
    foreground = $focusText; data = $freeText
  }
}