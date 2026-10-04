# device-lab / phone.ps1
# Единая точка управления телефоном: скриншоты, тапы, JS в WebView, логи,
# установка APK, имитация экранов/шрифтов/тем, метрики.
#
#   .\phone.ps1 help
#   .\phone.ps1 shot -Name home
#   .\phone.ps1 tapel '#saveBtn'
#   .\phone.ps1 js "JSON.parse(localStorage.getItem('mood_diary_v3')).length"
#   .\phone.ps1 logs -Filter mooddiary -Lines 40
#   .\phone.ps1 panel start

[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Command = 'help',
  [Parameter(Position = 1)][string]$Arg1,
  [Parameter(Position = 2)][string]$Arg2,
  [Parameter(Position = 3)][string]$Arg3,
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

# Иначе кириллица в выводе выглядит мусором и легко обманывает при отладке.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Lab = Get-LabRoot
$Shots = Join-Path $Lab 'shots'

function Say($m) { Write-Host $m }

# аргументы вида -Name значение / -Flag / -Name=значение -> хеш
$Opts = @{}
$Pos = @()
for ($i = 0; $i -lt $Rest.Count; $i++) {
  $a = $Rest[$i]
  if ($a -match '^-([A-Za-z][A-Za-z0-9]*)=(.*)$') {
    $Opts[$Matches[1].ToLower()] = $Matches[2]
  } elseif ($a -match '^-([A-Za-z][A-Za-z0-9]*)$') {
    $key = $Matches[1].ToLower()
    # Значение флага: короткое слово без пробелов либо путь/имя файла.
    # Фразы с пробелами остаются позиционными, иначе `-Clear "Привет, мир"`
    # проглотился бы как значение флага.
    $next = if ($i + 1 -lt $Rest.Count) { $Rest[$i + 1] } else { $null }
    $isValue = $next -and $next -notmatch '^-[A-Za-z]' -and (
      ($next -notmatch '\s') -or ($next -match '[\\/\.]')
    )
    if ($isValue) { $Opts[$key] = $next; $i++ } else { $Opts[$key] = $true }
  } else {
    $Pos += $a
  }
}
function OptVal($name, $def) { if ($Opts.ContainsKey($name)) { if ($Opts[$name] -eq $true) { return $true }; return $Opts[$name] }; return $def }

function New-ShotName($explicit) {
  if ($explicit -and $explicit -ne $true) { return "$explicit.png" }
  return (Get-Date -Format 'yyyyMMdd-HHmmss') + '.png'
}

function Get-LauncherPackage {
  $o = (Invoke-Adb -Args @('shell', 'cmd', 'package', 'resolve-activity', '-c', 'android.intent.category.HOME', '-a', 'android.intent.action.MAIN') -Quiet) -join ' '
  if ($o -match '([a-zA-Z0-9_.]+)/') { return $Matches[1] }
  return 'com.transsion.androidlauncher'
}

switch ($Command.ToLower()) {

  'doctor' {
    # Самопроверка лаборатории: что сломано, видно сразу, а не в середине теста.
    $checks = New-Object System.Collections.Generic.List[object]
    function Check($name, $ok, $detail) {
      $script:checks.Add(@{ name = $name; ok = $ok; detail = $detail })
    }
    $dev = (Invoke-Adb -Args @('devices') -Quiet | Select-String -Pattern '^(\S+)\s+device')
    Check 'adb и телефон' ([bool]$dev) ("$dev".Trim())
    if (-not $dev) { }
    $info = Get-DeviceInfo
    Check 'экран известен' ($info.width -gt 0) ("$($info.width)×$($info.height), density $($info.density)")
    $bars = Get-BarInsets -Refresh
    Check 'системные полосы определены' ($bars.top -gt 0) ("статус-бар $($bars.top)px, навигация $($bars.bottom)px")
    $ime = (Invoke-Adb -Args @('shell', 'settings', 'get', 'secure', 'default_input_method') -Quiet | Select-Object -First 1)
    Check 'клавиатура ADBKeyboard (кириллица)' ("$ime" -match 'adbkeyboard') "$ime"
    $anim = (Invoke-Adb -Args @('shell', 'settings', 'get', 'global', 'animator_duration_scale') -Quiet | Select-Object -First 1)
    Check 'анимации выключены' ("$anim" -eq '0') "scale=$anim (для быстрых тапов 0)"
    $stay = (Invoke-Adb -Args @('shell', 'settings', 'get', 'global', 'stay_on_while_plugged_in') -Quiet | Select-Object -First 1)
    Check 'экран не засыпает на зарядке' ([int]$stay -gt 0) "stay_on=$stay"
    $rot = (Invoke-Adb -Args @('shell', 'settings', 'get', 'system', 'user_rotation') -Quiet | Select-Object -First 1)
    Check 'ориентация зафиксирована' ("$rot" -ne '') "user_rotation=$rot"
    $lock = (Invoke-Adb -Args @('shell', 'locksettings', 'get-disabled') -Quiet | Select-Object -First 1)
    Check 'блокировка экрана отключена' ("$lock" -match 'true') "$lock"
    $fg = Get-ForegroundPackage
    Check 'на экране приложение' ($fg -match '^ru\.') "сейчас: $fg"
    foreach ($pkg in @('ru.mooddiary', 'ru.chronicnotebook', 'ru.drevo.yazyka', 'ru.speedmeter.app')) {
      $d = Invoke-Adb -Args @('shell', 'dumpsys', 'package', $pkg) -Quiet | Select-String -Pattern 'versionName=(\S+)' | Select-Object -First 1
      $vn = if ($d) { "$d".Trim() } else { 'не установлено' }
      Check "пакет $pkg" ($vn -ne 'не установлено') $vn
    }
    $panelOk = $false
    try { $panelOk = (Invoke-WebRequest -Uri 'http://127.0.0.1:8099/' -UseBasicParsing -TimeoutSec 3).StatusCode -eq 200 } catch { }
    Check 'панель поднята' $panelOk 'http://127.0.0.1:8099/'
    $parts = @($info.data -split '\s+' | Where-Object { $_ })
    $free = if ($parts.Count -ge 4) { $parts[3] } else { '?' }
    Check 'свободно на телефоне' ($free -ne '?') ("$free КБ из " + $(if ($parts.Count -ge 2) { $parts[1] } else { '?' }))

    Say ''
    foreach ($c in $checks) {
      Say ("  {0} {1,-38} {2}" -f $(if ($c.ok) { 'ОК  ' } else { 'МИМО' }), $c.name, $c.detail)
    }
    $bad = @($checks | Where-Object { -not $_.ok }).Count
    Say ''
    Say ("итого: {0} из {1} проверок пройдено" -f ($checks.Count - $bad), $checks.Count)
  }

  'help' {
    Say @"
device-lab — телефон как лаборатория

  Снимки и ввод
    shot [-Name имя] [-Dir папка]        снимок экрана -> shots/ (печатает путь)
    tap X Y                             тап по координатам экрана
    tapel SELECTOR                      тап по элементу WebView (CSS или id)
    swipe X1 Y1 X2 Y2 [-Ms 400]         свайп
    type "текст"                        ввод текста (кириллица — через ADBKeyboard)
    key CODE|NAME                       4=назад 3=домой 26=питание 187=обзор 82=меню
    unlock | wake | stayon on|off        экран и блокировка

  WebView (нужен запущенный андроид-клиент)
    js "expr"                           выполнить JS, вернуть значение
    jsfile script.js                    выполнить файл
    find SELECTOR                       координаты центра элемента (JSON)

  Приложения
    launch PKG [ACTIVITY]               запустить
    stop PKG | restart PKG              остановить / перезапустить
    clear PKG                           стереть данные (localStorage тоже)
    install [-r] path.apk               поставить APK
    uninstall PKG                       удалить
    packages [-System]                  список пакетов

  Условия (имитация без второго телефона)
    size [WxH]                          wm size  (без аргумента — текущий)
    density [DPI]                       wm density
    font SCALE                          масштаб шрифта, напр. 1.3
    night yes|no|auto                   системная тёмная тема
    rotate 0|90                         ориентация
    anim 0|1                            анимации (0 = быстрые автотесты)
    pointer on|off                      показ координат под пальцем (отладка)
    quiet | loud                        погасить/поднять фоновые приложения

  Наблюдение
    info                                сводка о телефоне
    logs [-Filter текст] [-Lines N] [-Follow]
    perf PKG                            кадры и память (gfxinfo)
    alarms [PKG] | notif [PKG]          что запланировано / что показано
    reboot

  Обслуживание
    prep [-Radio] [-Disable]            разовая подготовка телефона
    panel start|stop|open|status        живая панель управления в браузере
    run -Scenario путь.json             автопрогон сценария
"@
  }

  'info' { (Get-DeviceInfo) | ConvertTo-Json }

  'shot' {
    $dir = OptVal 'dir' $Shots
    $name = New-ShotName (OptVal 'name' $null)
    $path = Save-Screenshot -Path (Join-Path $dir $name)
    Say $path
  }

  'tap' {
    $x = [int]$Arg1; $y = [int]$Arg2
    Invoke-Adb -Args @('shell', 'input', 'tap', $x, $y) -Quiet | Out-Null
    Say "tap $x $y"
  }

  'tapel' {
    $p = Get-WebViewCenter -Selector $Arg1
    Invoke-Adb -Args @('shell', 'input', 'tap', $p.x, $p.y) -Quiet | Out-Null
    Say ("tap {0} {1}  (элемент {2})" -f $p.x, $p.y, $Arg1)
  }

  'find' {
    $p = Get-WebViewCenter -Selector $Arg1
    (Get-DeviceInfo) | Out-Null
    Say ("{0} {1}" -f $p.x, $p.y)
  }

  'swipe' {
    # Полная форма: swipe X1 Y1 X2 Y2 [-Ms 400]
    # Короткая:   swipe X Y  — свайп вверх от точки (листание страницы вниз)
    $ms = [int](OptVal 'ms' 400)
    $nums = @()
    foreach ($v in @($Arg1, $Arg2, $Arg3)) { if ($v -and "$v" -match '^-?\d+$') { $nums += [int]$v } }
    foreach ($v in $Pos) { if ($nums.Count -lt 4 -and "$v" -match '^-?\d+$') { $nums += [int]$v } }
    if ($nums.Count -ge 4) {
      $x1 = $nums[0]; $y1 = $nums[1]; $x2 = $nums[2]; $y2 = $nums[3]
    } elseif ($nums.Count -ge 2) {
      $x1 = $nums[0]; $y1 = $nums[1]; $x2 = $x1; $y2 = $y1 - 700
    } else {
      throw 'нужны координаты: swipe X Y  или  swipe X1 Y1 X2 Y2'
    }
    Invoke-Adb -Args @('shell', 'input', 'swipe', $x1, $y1, $x2, $y2, $ms) -Quiet | Out-Null
    Say "swipe $x1 $y1 -> $x2 $y2 (${ms}ms)"
  }

  'type' {
    $text = $null
    if ($Arg1) { $text = $Arg1 }
    elseif ($Pos.Count -gt 0) { $text = ($Pos -join ' ') }
    else {
      foreach ($k in @('clear', 'text', 'value')) {
        if ($Opts.ContainsKey($k) -and $Opts[$k] -ne $true) { $text = $Opts[$k]; break }
      }
    }
    if (-not $text) { throw 'Нет текста' }
    # PowerShell отдаёт аргументы нативным программам в windows-1251, поэтому
    # кириллица через ADB_INPUT_TEXT приходит битой. ADB_INPUT_B64 несёт
    # чистый ASCII и работает всегда.
    $hasAdb = (Invoke-Adb -Args @('shell', 'ime', 'list', '-s') -Quiet | Select-String -Pattern 'adbkeyboard')
    if ($hasAdb) {
      if ($Opts.ContainsKey('clear')) { Invoke-Adb -Args @('shell', 'am', 'broadcast', '-a', 'ADB_CLEAR_TEXT') -Quiet | Out-Null; Start-Sleep -Milliseconds 300 }
      $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($text))
      Invoke-Adb -Args @('shell', 'am', 'broadcast', '-a', 'ADB_INPUT_B64', '--es', 'msg', $b64) -Quiet | Out-Null
      Say ("введено символов: {0} (ADBKeyboard, base64)" -f $text.Length)
    } else {
      $ascii = ($text -replace '[^\x20-\x7E]', '')
      if ($ascii -ne $text) { Say 'ВНИМАНИЕ: ADBKeyboard не выбран, кириллица не передастся. Выполни: .\phone.ps1 setup-ime' }
      Invoke-Adb -Args @('shell', 'input', 'text', $ascii) -Quiet | Out-Null
      Say 'ok (input text, ASCII)'
    }
  }

  'key' {
    $code = $Arg1
    $map = @{ back = 4; home = 3; power = 26; recents = 187; menu = 82; enter = 66; del = 67; tab = 61; up = 19; down = 20; left = 21; right = 22; wakeup = 224 }
    if ($map.ContainsKey(("$code").ToLower())) { $code = $map["$code".ToLower()] }
    Invoke-Adb -Args @('shell', 'input', 'keyevent', $code) -Quiet | Out-Null
    Say "keyevent $code"
  }

  'js' { Invoke-Eval -Expr $Arg1 }

  'jsfile' {
    $f = $Arg1
    if (-not (Test-Path $f)) { throw 'Нет файла: ' + $f }
    Invoke-Eval -Expr ([System.IO.File]::ReadAllText((Resolve-Path $f)))
  }

  'logs' {
    $filter = OptVal 'filter' $null
    $lines = [int](OptVal 'lines' 80)
    if ($Opts.ContainsKey('follow') -or $Opts.ContainsKey('f')) {
      $args = @('logcat')
      if ($filter) { $args += $filter + ':V' }
      & $script:AdbPath @args
    } else {
      $args = @('logcat', '-d', '-t', '400')
      $out = Invoke-Adb -Args $args -Quiet
      if ($filter) { $out = $out | Select-String -Pattern $filter }
      $out | Select-Object -Last $lines
    }
  }

  'perf' {
    $pkg = $Arg1
    if (-not $pkg) { $pkg = 'ru.mooddiary' }
    Say '--- память ---'
    Invoke-Adb -Args @('shell', 'dumpsys', 'meminfo', $pkg) -Quiet | Select-String -Pattern 'TOTAL|TOTAL PSS|Java Heap|Native Heap|Graphics' | Select-Object -First 6
    Say '--- кадры (janky/total) ---'
    $g = Invoke-Adb -Args @('shell', 'dumpsys', 'gfxinfo', $pkg) -Quiet
    $g | Select-String -Pattern 'Total frames rendered|Janky frames|50th percentile|90th percentile|95th percentile|99th percentile|HISTOGRAM' | Select-Object -First 10
  }

  'alarms' {
    $pkg = $Arg1
    $o = Invoke-Adb -Args @('shell', 'dumpsys', 'alarm') -Quiet
    if ($pkg) { $o = $o | Select-String -Pattern ([regex]::Escape($pkg)); $take = 12 } else { $take = 40 }
    $o | Select-Object -First $take
  }

  'notif' {
    $pkg = $Arg1
    $o = Invoke-Adb -Args @('shell', 'dumpsys', 'notification', '--noredact') -Quiet
    if ($pkg) { $o = $o | Select-String -Pattern ([regex]::Escape($pkg)); $take = 14 } else { $take = 40 }
    $o | Select-Object -First $take
  }

  'launch' {
    $pkg = $Arg1
    if (-not $pkg) { $pkg = 'ru.mooddiary' }
    Say ("launch " + (Invoke-Launch -Package $pkg))
  }

  'stop' { Invoke-Adb -Args @('shell', 'am', 'force-stop', $Arg1) -Quiet | Out-Null; Say 'stopped ' + $Arg1 }

  'restart' {
    Invoke-Adb -Args @('shell', 'am', 'force-stop', $Arg1) -Quiet | Out-Null
    Start-Sleep -Milliseconds 400
    Invoke-Adb -Args @('shell', 'am', 'start', "-n", "$($Arg1)/$($Arg1).MainActivity") | Out-Null
    Say 'restarted ' + $Arg1
  }

  'clear' {
    Invoke-Adb -Args @('shell', 'pm', 'clear', $Arg1) | Out-Null
    Say 'cleared ' + $Arg1
  }

  'install' {
    $apk = $Arg1
    if (-not $apk) { $apk = $Pos | Select-Object -First 1 }
    if (-not (Test-Path $apk)) { throw 'Нет APK: ' + $apk }
    $apk = (Resolve-Path $apk).Path
    $info = Get-ApkInfo -Apk $apk
    if ($info.package) { Say ("ставим {0} {1} (код {2})" -f $info.package, $info.versionName, $info.versionCode) }
    # Иначе после установки продолжит работать старый процесс, и правка не видна.
    if ($info.package) { Invoke-Adb -Args @('shell', 'am', 'force-stop', $info.package) -Quiet | Out-Null }
    $args = @('install', '-r')
    if ($Opts.ContainsKey('downgrade')) { $args += '-d' }
    $args += $apk
    Invoke-Adb -Args $args
  }

  'apkinfo' {
    $apk = $Arg1
    if (-not $apk) { $apk = $Pos | Select-Object -First 1 }
    (Get-ApkInfo -Apk (Resolve-Path $apk).Path) | ConvertTo-Json
  }

  'uninstall' { Invoke-Adb -Args @('uninstall', $Arg1) | Out-Null }

  'packages' {
    $sys = $Opts.ContainsKey('system')
    $pk = Get-Packages -System:$sys
    if ($Arg1) { $pk = $pk | Where-Object { $_ -like "*$Arg1*" } }
    Say ("пакетов: " + $pk.Count)
    $pk
  }

  'size' {
    if ($Arg1) {
      Invoke-Adb -Args @('shell', 'wm', 'size', $Arg1) | Out-Null
      Start-Sleep -Milliseconds 800
      Say "wm size -> $Arg1"
    } else { Invoke-Adb -Args @('shell', 'wm', 'size') }
  }

  'density' {
    if ($Arg1) {
      Invoke-Adb -Args @('shell', 'wm', 'density', $Arg1) | Out-Null
      Start-Sleep -Milliseconds 800
      Say "wm density -> $Arg1"
    } else { Invoke-Adb -Args @('shell', 'wm', 'density') }
  }

  'reset-size' { Invoke-Adb -Args @('shell', 'wm', 'size', 'reset') | Out-Null; Invoke-Adb -Args @('shell', 'wm', 'density', 'reset') | Out-Null; Say 'wm size/density reset' }

  'font' {
    $v = $Arg1
    if (-not $v) { Invoke-Adb -Args @('shell', 'settings', 'get', 'system', 'font_scale'); break }
    Invoke-Adb -Args @('shell', 'settings', 'put', 'system', 'font_scale', $v) -Quiet | Out-Null
    Start-Sleep -Milliseconds 700
    Say "font_scale -> $v"
  }

  'night' {
    if ($Arg1) { Invoke-Adb -Args @('shell', 'cmd', 'uimode', 'night', $Arg1) -Quiet | Out-Null; Start-Sleep -Milliseconds 700 }
    Invoke-Adb -Args @('shell', 'cmd', 'uimode', 'night')
  }

  'rotate' {
    if ($Arg1 -ne $null -and $Arg1 -ne '') {
      Invoke-Adb -Args @('shell', 'settings', 'put', 'system', 'accelerometer_rotation', '0') -Quiet | Out-Null
      Invoke-Adb -Args @('shell', 'settings', 'put', 'system', 'user_rotation', $Arg1) -Quiet | Out-Null
      Start-Sleep -Milliseconds 800
    }
    Invoke-Adb -Args @('shell', 'settings', 'get', 'system', 'user_rotation')
  }

  'anim' {
    $v = $Arg1; if (-not $v) { $v = '0' }
    foreach ($k in @('window_animation_scale', 'transition_animation_scale', 'animator_duration_scale')) {
      Invoke-Adb -Args @('shell', 'settings', 'put', 'global', $k, $v) -Quiet | Out-Null
    }
    Say "анимации -> $v"
  }

  'pointer' {
    $v = if ($Arg1 -eq 'off') { 0 } else { 1 }
    Invoke-Adb -Args @('shell', 'settings', 'put', 'system', 'pointer_location', $v) -Quiet | Out-Null
    Invoke-Adb -Args @('shell', 'settings', 'put', 'system', 'show_touches', $v) -Quiet | Out-Null
    Say 'pointer_location -> ' + $v
  }

  'wake' {
    Invoke-Adb -Args @('shell', 'input', 'keyevent', '224') -Quiet | Out-Null
    Invoke-Adb -Args @('shell', 'input', 'keyevent', '82') -Quiet | Out-Null
    Say 'screen on'
  }

  'unlock' {
    Invoke-Adb -Args @('shell', 'input', 'keyevent', '224') -Quiet | Out-Null
    Start-Sleep -Milliseconds 300
    Invoke-Adb -Args @('shell', 'input', 'swipe', '360', '1300', '360', '400', '250') -Quiet | Out-Null
    Start-Sleep -Milliseconds 300
    Invoke-Adb -Args @('shell', 'input', 'keyevent', '82') -Quiet | Out-Null
    Say 'unlock attempted'
  }

  'stayon' {
    $v = if ($Arg1 -eq 'off') { 0 } else { 3 }
    Invoke-Adb -Args @('shell', 'svc', 'power', 'stayon', $v) -Quiet | Out-Null
    Say 'stayon -> ' + $v
  }

  'quiet' {
    $keep = @('ru.mooddiary', 'ru.chronicnotebook', 'com.android.adbkeyboard')
    $keep += Get-LauncherPackage
    $stopped = 0
    foreach ($p in (Get-Packages)) {
      if ($keep -contains $p) { continue }
      if ($p -like 'com.android.*') { continue }
      Invoke-Adb -Args @('shell', 'am', 'force-stop', $p) -Quiet | Out-Null
      $stopped++
    }
    Say "остановлено фоновых: $stopped (запускорщик и наши приложения живы)"
  }

  'loud' {
    Invoke-Adb -Args @('shell', 'monkey', '-p', (Get-LauncherPackage), '-c', 'android.intent.category.LAUNCHER', '1') -Quiet | Out-Null
    Say 'launcher поднят'
  }

  'reboot' { Invoke-Adb -Args @('reboot') | Out-Null; Say 'rebooting' }

  'setup-ime' {
    $apk = $Arg1
    if (-not $apk) { $apk = Join-Path $Lab 'tools\ADBKeyboard.apk' }
    if (-not (Test-Path $apk)) { throw 'Нет APK ADBKeyboard: ' + $apk }
    Invoke-Adb -Args @('install', '-r', (Resolve-Path $apk).Path)
    # Менеджер пакетов не всегда сразу видит новый сервис ввода: пробуем несколько раз.
    $done = $false
    for ($i = 0; $i -lt 8 -and -not $done; $i++) {
      $out = (Invoke-Adb -Args @('shell', 'ime', 'set', 'com.android.adbkeyboard/.AdbIME') -Quiet) -join ' '
      if ($out -match 'selected for user') { $done = $true; break }
      Start-Sleep -Milliseconds 700
    }
    if (-not $done) { throw 'IME не переключился: ' + ((Invoke-Adb -Args @('shell', 'ime', 'list', '-s') -Quiet) -join ' ') }
    Say 'ADBKeyboard установлен и выбран'
  }

  'ime-restore' {
    $cur = (Invoke-Adb -Args @('shell', 'settings', 'get', 'secure', 'default_input_method') -Quiet | Select-Object -First 1)
    Say "был: $cur"
    $imelist = Invoke-Adb -Args @('shell', 'ime', 'list', '-s', '-a') -Quiet
    $ime = $imelist | Where-Object { "$_" -notmatch 'adbkeyboard' -and "$_" -match '/' } | Select-Object -First 1
    if ($ime) { Invoke-Adb -Args @('shell', 'ime', 'set', "$ime".Trim()) | Out-Null; Say "вернули: $ime" }
  }

  'uia' {
    # Дерево доступности нативного экрана: работает там, где нет WebView.
    #   uia list [-Filter текст] [-Class EditText] [-Refresh]
    #   uia tap "текст кнопки"
    #   uia has "текст"      -> печатает ok / none (для автотестов)
    $sub = ($Arg1).ToLower()
    if ($sub -eq 'list') {
      $nodes = Get-UiNodes -Refresh:$Opts.ContainsKey('refresh')
      $f = OptVal 'filter' $null
      $c = OptVal 'class' $null
      foreach ($n in $nodes) {
        $label = ("$($n.text) $($n.desc)").Trim()
        if (-not $label -and -not $c) { continue }
        if ($f -and $f -ne $true -and $label -notlike "*$f*") { continue }
        if ($c -and $c -ne $true -and $n.cls -notlike "*$c*") { continue }
        Say ("{0} | {1,-26} | {2}{3}" -f $n.bounds, ($label -replace '\s+', ' '), $n.cls.Substring([Math]::Max(0, $n.cls.LastIndexOf('.'))), $(if ($n.clickable) { ' [клик]' } else { '' }))
      }
      Say ("всего узлов: " + $nodes.Count)
    }
    elseif ($sub -eq 'tap') {
      $q = $Arg2
      if (-not $q) { $q = ($Pos -join ' ') }
      Assert-AppForeground -Package (Get-ForegroundPackage) | Out-Null
      $n = (Find-UiNode -Text $q -Refresh) | Select-Object -First 1
      if (-not $n) { throw 'Не найден элемент с текстом: ' + $q }
      Invoke-Adb -Args @('shell', 'input', 'tap', $n.x, $n.y) -Quiet | Out-Null
      Say ("tap $($n.x) $($n.y)  -> «$($n.text)$($n.desc)»")
    }
    elseif ($sub -eq 'has') {
      $q = $Arg2
      if (-not $q) { $q = ($Pos -join ' ') }
      $n = Find-UiNode -Text $q -Refresh
      if ($n) { Say ('ok: ' + (($n | Select-Object -First 1).text)) } else { Say 'none' }
    }
    elseif ($sub -eq 'dump') {
      $nodes = Get-UiNodes -Refresh
      Say ("узлов в дереве: " + $nodes.Count)
      Say (Join-Path (Get-LabRoot) 'lab-state\ui.xml')
    }
    else { Say 'uia list | tap | has | dump' }
  }

  'prep' {
    & (Join-Path $PSScriptRoot 'prep.ps1') @Rest
  }

  'panel' {
    & (Join-Path $PSScriptRoot 'panel.ps1') -Action $Arg1 @Rest
  }

  'run' {
    # Флаги проксируем явно: скрипт с [CmdletBinding()] иначе свяжет их как позиционные
    $f = @()
    if ($Opts.ContainsKey('scenario') -and $Opts['scenario'] -ne $true) { $f += @('-Scenario', "$($Opts['scenario'])") }
    if ($Opts.ContainsKey('outdir') -and $Opts['outdir'] -ne $true) { $f += @('-OutDir', "$($Opts['outdir'])") }
    if ($Opts.ContainsKey('clean')) { $f += '-Clean' }
    & (Join-Path $PSScriptRoot 'run.ps1') @f
  }

  'layout' {
    $f = @()
    if ($Opts.ContainsKey('only') -and $Opts['only'] -ne $true) { $f += @('-Only', "$($Opts['only'])") }
    if ($Opts.ContainsKey('app') -and $Opts['app'] -ne $true) { $f += @('-App', "$($Opts['app'])") }
    if ($Opts.ContainsKey('norestore')) { $f += '-NoRestore' }
    & (Join-Path $PSScriptRoot 'layout.ps1') @f
  }

  default {
    Say "Неизвестная команда: $Command"
    Say 'Список команд: .\phone.ps1 help'
  }
}