# device-lab / run.ps1
# Автопрогон сценария на телефоне: шаги + проверки + снимки + отчёт.
#
#   .\run.ps1 -Scenario scenarios\mood-diary.json
#   .\run.ps1 -Scenario scenarios\mood-diary.json -Clean      # стереть данные перед прогоном
#
# Формат сценария (JSON):
# {
#   "name": "mood-diary smoke",
#   "package": "ru.mooddiary",
#   "steps": [
#     { "do": "app",   "op": "launch" },
#     { "do": "wait",  "ms": 2500 },
#     { "do": "js",    "label": "заголовок на месте", "expr": "document.querySelector('h1').textContent",
#       "expect": { "contains": "настроен" } },
#     { "do": "tapel", "sel": "#saveBtn" },
#     { "do": "shot",  "name": "01-home" },
#     { "do": "swipe", "x": 360, "y": 1200 },
#     { "do": "key",   "code": 4 },
#     { "do": "text",  "value": "Привет" },
#     { "do": "shell", "args": ["wm", "size"] },
#     { "do": "log",   "filter": "FATAL", "expect": { "empty": true } }
#   ]
# }
# Проверки expect: contains | notContains | eq | ne | regex | gt | gte | lt | lte | exists | empty

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Scenario,
  [switch]$Clean,
  [switch]$KeepData,
  [string]$OutDir
)

. (Join-Path $PSScriptRoot 'lib\common.ps1')

# Кириллица в выводе должна быть читаемой, иначе отчёт об ошибке бесполезен.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Lab = Get-LabRoot
if (-not (Test-Path $Scenario)) { throw 'Нет сценария: ' + $Scenario }
$sc = [System.IO.File]::ReadAllText((Resolve-Path $Scenario), [System.Text.Encoding]::UTF8) | ConvertFrom-Json

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $OutDir) {
  $OutDir = Join-Path $Lab ("runs\" + $stamp + '-' + (($sc.name -replace '[^A-Za-z0-9А-Яа-яЁё]+', '-').Trim('-')).ToLower())
}
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

$pkg = $sc.package
$report = New-Object System.Collections.Generic.List[string]
$results = New-Object System.Collections.Generic.List[object]
$shotN = 0
$pass = 0
$fail = 0

function Log($m) { Write-Host $m; $report.Add($m) }

function Ok($label, $detail) {
  $script:pass++
  $results.Add(@{ ok = $true; label = $label; detail = $detail })
  Write-Host ("  [ok]   {0} {1}" -f $label, $detail) -ForegroundColor DarkGreen
}

function Bad($label, $detail) {
  $script:fail++
  $results.Add(@{ ok = $false; label = $label; detail = $detail })
  Write-Host ("  [FAIL] {0} {1}" -f $label, $detail) -ForegroundColor Red
}

function Check-Expect {
  param([string]$Label, $value, $expect)
  if (-not $expect) {
    if ($value -ne $null -and "$value" -ne '') { Ok $Label "= $value" } else { Ok $Label '= (пусто)' }
    return
  }
  $v = if ($value -eq $null) { '' } else { "$value" }
  $ok = $true; $why = ''
  foreach ($p in $expect.PSObject.Properties) {
    $k = $p.Name; $e = $p.Value
    # Проверка «1 -eq $true» в PowerShell истинна, поэтому тип, а не значение.
    $ee = if ($e -is [bool]) { $(if ($e) { 'true' } else { 'false' }) } else { "$e" }
    switch ($k) {
      'contains'    { if ($v -notlike "*$e*") { $ok = $false; $why = "не содержит '$e'" } }
      'notContains' { if ($v -like "*$e*") { $ok = $false; $why = "содержит '$e'" } }
      'eq'          { if ($v -ne $ee) { $ok = $false; $why = "ожидалось '$ee'" } }
      'ne'          { if ($v -eq $ee) { $ok = $false; $why = "не должно быть '$ee'" } }
      'regex'       { if ($v -notmatch $ee) { $ok = $false; $why = "не матчит /$ee/" } }
      'gt'          { if (-not ([double]$v -gt [double]$ee)) { $ok = $false; $why = "не больше $ee" } }
      'gte'         { if (-not ([double]$v -ge [double]$ee)) { $ok = $false; $why = "не меньше равно $ee" } }
      'lt'          { if (-not ([double]$v -lt [double]$ee)) { $ok = $false; $why = "не меньше $ee" } }
      'lte'         { if (-not ([double]$v -le [double]$ee)) { $ok = $false; $why = "не больше равно $ee" } }
      'exists'      { if ([bool]$e -and -not $v) { $ok = $false; $why = 'пусто' } }
      'empty'       { if ([bool]$e -and $v) { $ok = $false; $why = 'не пусто' } }
      default       { $ok = $false; $why = "неизвестная проверка '$k'" }
    }
  }
  $short = if ($v.Length -gt 160) { $v.Substring(0, 160) + '…' } else { $v }
  if ($ok) { Ok $Label "= $short" } else { Bad $Label ("$short ($why)") }
}

Log "сценарий: $($sc.name)"
Log "пакет: $pkg"
Log "папка: $OutDir"

if ($pkg -and $Clean) {
  Invoke-Adb -Args @('shell', 'am', 'force-stop', $pkg) -Quiet | Out-Null
  Invoke-Adb -Args @('shell', 'pm', 'clear', $pkg) -Quiet | Out-Null
  Log 'данные приложения стёрты перед прогоном'
}

$i = 0
foreach ($step in $sc.steps) {
  $i++
  $kind = "$($step.do)".ToLower()
  $label = if ($step.label) { $step.label } else { "шаг $i ($kind)" }
  try {
    switch ($kind) {
      'wait' {
        $ms = if ($step.ms) { [int]$step.ms } else { 800 }
        Start-Sleep -Milliseconds $ms
        Log "  [$i] ждём ${ms}мс"
      }
      'app' {
        $p = if ($step.pkg) { $step.pkg } else { $pkg }
        switch ($step.op) {
          'launch' { Invoke-Launch -Package $p | Out-Null }
          'stop' { Invoke-Adb -Args @('shell', 'am', 'force-stop', $p) -Quiet | Out-Null }
          'clear' { Invoke-Adb -Args @('shell', 'pm', 'clear', $p) -Quiet | Out-Null }
          'restart' { Invoke-Adb -Args @('shell', 'am', 'force-stop', $p) -Quiet | Out-Null; Start-Sleep -Milliseconds 400; Invoke-Launch -Package $p | Out-Null }
          default { }
        }
        Log "  [$i] $label ($($step.op) $p)"
      }
      'tap' {
        Invoke-Adb -Args @('shell', 'input', 'tap', $step.x, $step.y) -Quiet | Out-Null
        Log "  [$i] тап $($step.x),$($step.y)"
      }
      'tapel' {
        $p = Get-WebViewCenter -Selector $step.sel
        Invoke-Adb -Args @('shell', 'input', 'tap', $p.x, $p.y) -Quiet | Out-Null
        Log "  [$i] тап по $($step.sel) -> $($p.x),$($p.y)"
      }
      'swipe' {
        $ms = if ($step.ms) { [int]$step.ms } else { 400 }
        if ($step.dir -eq 'up') {
          Invoke-Adb -Args @('shell', 'input', 'swipe', $step.x, $step.y, $step.x, ($step.y - 700), $ms) -Quiet | Out-Null
        } elseif ($step.dir -eq 'down') {
          Invoke-Adb -Args @('shell', 'input', 'swipe', $step.x, $step.y, $step.x, ($step.y + 700), $ms) -Quiet | Out-Null
        } else {
          Invoke-Adb -Args @('shell', 'input', 'swipe', $step.x, $step.y, $step.x2, $step.y2, $ms) -Quiet | Out-Null
        }
        Log "  [$i] свайп"
      }
      'key' {
        $code = "$($step.code)"
        $map = @{ back = 4; home = 3; power = 26; recents = 187; menu = 82; enter = 66; del = 67 }
        if ($map.ContainsKey($code)) { $code = $map[$code] }
        Invoke-Adb -Args @('shell', 'input', 'keyevent', $code) -Quiet | Out-Null
        Log "  [$i] клавиша $code"
      }
      'text' {
        $hasAdb = (Invoke-Adb -Args @('shell', 'ime', 'list', '-s') -Quiet | Select-String -Pattern 'adbkeyboard')
        if ($hasAdb) {
          # base64: PowerShell иначе передаёт кириллицу в windows-1251 и она бьётся
          $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$($step.value)"))
          Invoke-Adb -Args @('shell', 'am', 'broadcast', '-a', 'ADB_INPUT_B64', '--es', 'msg', $b64) -Quiet | Out-Null
        } else {
          Invoke-Adb -Args @('shell', 'input', 'text', "$($step.value)") -Quiet | Out-Null
        }
        Log "  [$i] текст «$($step.value)»"
      }
      'uiatap' {
        Assert-AppForeground -Package $pkg -AutoFix | Out-Null
        $n = (Find-UiNode -Text $step.text -Refresh:$step.refresh) | Select-Object -First 1
        if (-not $n) { throw "не найден элемент «$($step.text)»" }
        Invoke-Adb -Args @('shell', 'input', 'tap', $n.x, $n.y) -Quiet | Out-Null
        Log "  [$i] тап по «$($step.text)» -> $($n.x),$($n.y)"
      }
      'uiatapclass' {
        # Тап по N-му узлу класса: 1 = «Верхнее», 2 = «Нижнее», 3 = «Пульс»
        Assert-AppForeground -Package $pkg -AutoFix | Out-Null
        $nodes = @(Get-UiNodes -Refresh | Where-Object { $_.cls -like "*$($step.class)*" -and $_.x2 -gt $_.x1 -and $_.y2 -gt $_.y1 })
        $i2 = [int]$step.index
        if ($nodes.Count -lt $i2) { throw "узлов $($step.class) всего $($nodes.Count), нужен $i2" }
        $n = $nodes[$i2 - 1]
        Invoke-Adb -Args @('shell', 'input', 'tap', $n.x, $n.y) -Quiet | Out-Null
        Log "  [$i] тап по $($step.class) #$i2 -> $($n.x),$($n.y)"
      }
      'uiatxt' {
        $n = Find-UiNode -Text $step.text -Refresh
        $v = if ($n) { 'ok' } else { 'none' }
        if ($step.expect) { Check-Expect $label $v $step.expect } else { Log "  [$i] uia «$($step.text)» = $v" }
      }
      'fill' {
        # Атомарно: доводим фокус тапом, чистим поле, вводим и возвращаем значение.
        # Отдельные шаги «тап → пауза → ввод» проигрывали гонку с показом клавиатуры.
        $sel = $step.sel
        $focused = $false
        for ($try = 0; $try -lt 3 -and -not $focused; $try++) {
          $p = Get-WebViewCenter -Selector $sel
          Invoke-Adb -Args @('shell', 'input', 'tap', $p.x, $p.y) -Quiet | Out-Null
          Start-Sleep -Milliseconds 800
          $probe = Invoke-Eval -Expr ("(function(){var e=document.querySelector('" + $sel.Replace("'", "\'") + "')||document.getElementById('" + $sel.Replace("'", "\'") + "'); if(!e) return 'нет элемента'; var a=document.activeElement; return (a===e||(e.contains&&e.contains(a)))?'да':'нет, активно '+a.tagName+'#'+a.id;})()")
          if ("$probe" -eq 'да') { $focused = $true }
        }
        if (-not $focused) { throw "не удалось сфокусировать $sel ($probe)" }
        $hasAdb = (Invoke-Adb -Args @('shell', 'ime', 'list', '-s') -Quiet | Select-String -Pattern 'adbkeyboard')
        if (-not $hasAdb) { throw 'для ввода нужен ADBKeyboard: .\phone.ps1 setup-ime' }
        Invoke-Adb -Args @('shell', 'am', 'broadcast', '-a', 'ADB_CLEAR_TEXT') -Quiet | Out-Null
        Start-Sleep -Milliseconds 250
        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$($step.value)"))
        Invoke-Adb -Args @('shell', 'am', 'broadcast', '-a', 'ADB_INPUT_B64', '--es', 'msg', $b64) -Quiet | Out-Null
        Start-Sleep -Milliseconds 700
        $v = Invoke-Eval -Expr ("(function(){var e=document.querySelector('" + $sel.Replace("'", "\'") + "')||document.getElementById('" + $sel.Replace("'", "\'") + "'); return e?(e.value!==undefined?e.value:e.textContent):'нет элемента';})()")
        if ($step.expect) { Check-Expect $label $v $step.expect } else { Log "  [$i] поле = $v" }
      }
      'js' {
        $v = Invoke-Eval -Expr $step.expr
        if ($step.expect) { Check-Expect $label $v $step.expect }
        else { Log "  [$i] js = $v" }
      }
      'shot' {
        $script:shotN++
        $name = if ($step.name) { '{0:d2}-{1}' -f $script:shotN, $step.name } else { '{0:d2}-shot' -f $script:shotN }
        $path = Save-Screenshot -Path (Join-Path $OutDir ($name + '.png'))
        $results.Add(@{ ok = $true; label = $label; detail = $path })
        Write-Host ("  [кадр] {0}" -f $path) -ForegroundColor DarkCyan
      }
      'shell' {
        $out = Invoke-Adb -Args (@('shell') + @($step.args))
        $v = ($out -join "`n")
        if ($step.expect) { Check-Expect $label $v $step.expect }
        else { Log "  [$i] shell: $($step.args -join ' ')" }
      }
      'log' {
        $out = Invoke-Adb -Args @('logcat', '-d', '-t', '300') -Quiet
        if ($step.filter) { $out = $out | Select-String -Pattern $step.filter }
        $v = ($out | Select-Object -Last ($step.lines | ForEach-Object { if ($_) { $_ } else { 40 } })) -join "`n"
        if ($step.expect) { Check-Expect $label $v $step.expect }
        else { Log "  [$i] log" }
      }
      default { Bad $label "неизвестный шаг '$kind'" }
    }
  } catch {
    Bad $label $_.Exception.Message
  }
}

Log ''
Log ("итог: успешно $pass, провалено $fail")

$md = New-Object System.Collections.Generic.List[string]
$md.Add("# $($sc.name)")
$md.Add("")
$md.Add("- пакет: $pkg")
$md.Add("- прогон: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$md.Add("- итог: **успешно $pass, провалено $fail**")
$md.Add("")
$md.Add("| | проверка | значение |")
$md.Add("|---|---|---|")
foreach ($r in $results) {
  $mark = if ($r.ok) { 'ok' } else { 'FAIL' }
  $d = "$($r.detail)" -replace '\|', '/'
  if ($d.Length -gt 200) { $d = $d.Substring(0, 200) + '…' }
  $md.Add("| $mark | $($r.label) | $d |")
}
[System.IO.File]::WriteAllLines((Join-Path $OutDir 'report.md'), $md, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "отчёт: $(Join-Path $OutDir 'report.md')"

if ($fail -gt 0) { exit 1 } else { exit 0 }