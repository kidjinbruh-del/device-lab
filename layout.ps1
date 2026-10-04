# device-lab / layout.ps1
# Прогон вёрстки по разным условиям: размер экрана, масштаб шрифта, поворот,
# тёмная тема. Для каждого экрана — снимок и автоматическая проверка:
#
#   WebView (mood-diary): горизонтальное переполнение страницы и обрезанный текст
#   Натив (chronic-android): выход узлов за экран и подозрительно узкие подписи
#
# .\layout.ps1                     # всё
# .\layout.ps1 -Only small-480x854 # один профиль
# .\layout.ps1 -App mood-diary

[CmdletBinding()]
param(
  [string]$Only,
  [string]$App,
  [switch]$NoRestore
)

. (Join-Path $PSScriptRoot 'lib\common.ps1')
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Lab = Get-LabRoot
$OutDir = Join-Path $Lab ('layout\' + (Get-Date -Format 'yyyyMMdd-HHmm'))
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$Profiles = @(
  @{ name = 'native';            size = '';            font = '1.0';  rotate = 0; night = 'no' }
  @{ name = 'small-480x854';     size = '480x854';     font = '1.0';  rotate = 0; night = 'no' }
  @{ name = 'big-1080x2400';     size = '1080x2400';   font = '1.0';  rotate = 0; night = 'no' }
  @{ name = 'font-1.30';         size = '';            font = '1.3';  rotate = 0; night = 'no' }
  @{ name = 'small-font-1.15';   size = '480x854';     font = '1.15'; rotate = 0; night = 'no' }
  @{ name = 'landscape';         size = '';            font = '1.0';  rotate = 1; night = 'no' }
  @{ name = 'night';             size = '';            font = '1.0';  rotate = 0; night = 'yes' }
)

# Вкладки «древа языка»: проверяем те же четыре, что и на телефоне
$DrevoTabs = @('Дерево', 'Правила', 'Тренировка', 'Родителям')

# Экраны дневника: подпись + JS, который прокручивает к нужному месту
$DiaryScreens = @(
  @{ name = '01-top';       scroll = 'window.scrollTo(0,0);' }
  @{ name = '02-calendar';  scroll = "(function(){var c=document.getElementById('heatmap');c.scrollIntoView({block:'start'});window.scrollBy(0,-90);})()" }
  @{ name = '03-heatmap';   scroll = "(function(){var c=document.getElementById('slotHeat');c.scrollIntoView({block:'start'});window.scrollBy(0,-90);})()" }
  @{ name = '04-chart';     scroll = "(function(){var c=[...document.querySelectorAll('h2')].find(h=>h.textContent.indexOf('Линия')>=0);c.scrollIntoView({block:'start'});window.scrollBy(0,-90);})()" }
  @{ name = '05-tags';      scroll = "(function(){var c=[...document.querySelectorAll('h2')].find(h=>h.textContent.indexOf('Теги')>=0);c.scrollIntoView({block:'start'});window.scrollBy(0,-90);})()" }
  @{ name = '06-summary';   scroll = "(function(){var c=[...document.querySelectorAll('h2')].find(h=>h.textContent.indexOf('Сводка')>=0);c.scrollIntoView({block:'start'});window.scrollBy(0,-90);})()" }
  @{ name = '07-conclusions'; scroll = "(function(){var c=[...document.querySelectorAll('h2')].find(h=>h.textContent.indexOf('Выводы')>=0);c.scrollIntoView({block:'start'});window.scrollBy(0,-90);})()" }
  @{ name = '08-journal';   scroll = "(function(){var c=[...document.querySelectorAll('h2')].find(h=>h.textContent.indexOf('Журнал')>=0);c.scrollIntoView({block:'start'});window.scrollBy(0,-90);})()" }
)

# Экраны chronic-android: вкладка нижней панели
$NotebookTabs = @('Дом', 'Замер', 'Лекарства', 'Связи')

$WebAuditJs = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'lib\audit-web.js'), [System.Text.Encoding]::UTF8)

function Set-Conditions($p) {
  Invoke-Adb -Args @('shell', 'am', 'force-stop', 'ru.mooddiary') -Quiet | Out-Null
  Invoke-Adb -Args @('shell', 'am', 'force-stop', 'ru.chronicnotebook') -Quiet | Out-Null
  if ($p.size) {
    Invoke-Adb -Args @('shell', 'wm', 'density', '320') -Quiet | Out-Null
    Invoke-Adb -Args @('shell', 'wm', 'size', $p.size) -Quiet | Out-Null
  } else {
    Invoke-Adb -Args @('shell', 'wm', 'size', 'reset') -Quiet | Out-Null
    Invoke-Adb -Args @('shell', 'wm', 'density', 'reset') -Quiet | Out-Null
  }
  Start-Sleep -Milliseconds 900
  Invoke-Adb -Args @('shell', 'settings', 'put', 'system', 'font_scale', $p.font) -Quiet | Out-Null
  Invoke-Adb -Args @('shell', 'cmd', 'uimode', 'night', $p.night) -Quiet | Out-Null
  Invoke-Adb -Args @('shell', 'settings', 'put', 'system', 'accelerometer_rotation', '0') -Quiet | Out-Null
  Invoke-Adb -Args @('shell', 'settings', 'put', 'system', 'user_rotation', $p.rotate) -Quiet | Out-Null
  Start-Sleep -Milliseconds 1200
}

function Audit-Web {
  $json = Invoke-Eval -Expr $WebAuditJs
  $o = $json | ConvertFrom-Json
  $issues = @()
  if ($o.overflow) { $issues += $o.overflow }
  if ($o.clipped) { $issues += $o.clipped }
  return @{ issues = $issues; width = "$($o.innerW)px" }
}

function Audit-Native {
  $nodes = @(Get-UiNodes -Refresh | Where-Object { $_.x2 -gt $_.x1 -and $_.y2 -gt $_.y1 -and $_.text })
  $size = Get-ScreenSize
  $issues = @()
  foreach ($n in $nodes) {
    if ($n.x1 -lt -2 -or $n.x2 -gt $size.w + 2) {
      $issues += ('"' + ($n.text -replace '\s+', ' ') + '" выходит за экран: ' + $n.bounds)
    }
  }
  # Узкая подпись = вероятный перенос по буквам. Считаем медиану «пикселей на
  # символ» только по КОРОТКИМ подписям (4–24 символа): у длинных абзацев
  # плотность всегда ниже, и раньше они попадали в ложные срабатывания.
  # Дополнительно требуем, чтобы подпись была ещё и заметно выше медианы —
  # именно так выглядит текст, разложенный в столбик.
  $short = @($nodes | Where-Object {
      $len = "$($_.text)".Trim().Length
      $len -ge 4 -and $len -le 24
    })
  if ($short.Count -ge 5) {
    $ppc = @(); $heights = @()
    foreach ($n in $short) {
      $len = "$($n.text)".Trim().Length
      $ppc += [double](($n.x2 - $n.x1) / $len)
      $heights += [double]($n.y2 - $n.y1)
    }
    $sp = @($ppc | Sort-Object); $sh = @($heights | Sort-Object)
    $medPpc = $sp[[int]($sp.Count / 2)]
    $medH = $sh[[int]($sh.Count / 2)]
    foreach ($n in $short) {
      $t = "$($n.text)".Trim()
      $len = $t.Length
      $v = ($n.x2 - $n.x1) / $len
      $h = $n.y2 - $n.y1
      if ($v -lt $medPpc * 0.5 -and $h -gt $medH * 1.6) {
        $issues += ('"' + ($t -replace '\s+', ' ') + '" подозрительно узкая подпись: ' + [math]::Round($v, 1) + ' px/символ и высота ' + [math]::Round($h) + ' px при медиане ' + [math]::Round($medPpc, 1) + '/' + [math]::Round($medH))
      }
    }
    # Перенос коротких подписей («Правил а») автоматикой не ловится:
    # uiautomator отдаёт для Compose весь текст целиком, и по высоте узла
    # нельзя отличить перенос от крупного шрифта — проверка ругалась на
    # каждую подпись нижней панели. Такие места смотрят глазами по снимку.
  }
  return @{ issues = $issues; width = "$($size.w)px" }
}

$report = New-Object System.Collections.Generic.List[string]
$report.Add("# Вёрстка под разными условиями")
$report.Add('')
$report.Add("- телефон: $((Get-DeviceInfo).model)")
$report.Add("- прогон: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$report.Add('')
$total = 0; $bad = 0

try {
  foreach ($p in $Profiles) {
    if ($Only -and $p.name -ne $Only) { continue }
    Write-Host ''
    Write-Host ("=== профиль {0}: экран {1}, шрифт {2}, поворот {3}, тема {4}" -f $p.name, ($p.size -replace '^$', 'свой'), $p.font, $p.rotate, $p.night)
    Set-Conditions -p $p
    $size = Get-ScreenSize
    $report.Add("## Профиль $($p.name) — экран $($size.w)×$($size.h), шрифт $($p.font), поворот $($p.rotate), ночь $($p.night)")

    if (-not $App -or $App -eq 'mood-diary') {
      Write-Host '  дневник настроения:'
      Invoke-Adb -Args @('shell', 'am', 'start', '-n', 'ru.mooddiary/.MainActivity') -Quiet | Out-Null
      Start-Sleep -Seconds 5
      Invoke-Eval -Expr "(function(){var b=document.getElementById('onboardBtn'); if(b) b.click(); return 'ok';})()" | Out-Null
      $report.Add('')
      $report.Add('### mood-diary')
      foreach ($s in $DiaryScreens) {
        Invoke-Eval -Expr $s.scroll | Out-Null
        Start-Sleep -Milliseconds 900
        $shot = Save-Screenshot -Path (Join-Path $OutDir ("mood-diary-{0}-{1}.png" -f $p.name, $s.name))
        $a = Audit-Web
        $total++
        if ($a.issues.Count -gt 0) {
          $bad++
          Write-Host ("    [проблема] {0}: {1}" -f $s.name, ($a.issues -join '; ')) -ForegroundColor Red
        } else {
          Write-Host ("    ок  {0}  ({1})" -f $s.name, $a.width) -ForegroundColor DarkGreen
        }
        $report.Add("- $($s.name): " + $(if ($a.issues.Count) { '**' + ($a.issues -join '; ') + '**' } else { "ок, ширина $($a.width)" }))
      }
      Invoke-Adb -Args @('shell', 'am', 'force-stop', 'ru.mooddiary') -Quiet | Out-Null
    }

    if (-not $App -or $App -eq 'chronic-android') {
      Write-Host '  дневник давления:'
      Invoke-Adb -Args @('shell', 'am', 'start', '-n', 'ru.chronicnotebook/.MainActivity') -Quiet | Out-Null
      Start-Sleep -Seconds 5
      $report.Add('')
      $report.Add('### chronic-android')
      $i = 0
      foreach ($tab in $NotebookTabs) {
        $i++
        try {
          $n = (Find-UiNode -Text $tab -Refresh) | Select-Object -First 1
          if ($n) {
            Invoke-Adb -Args @('shell', 'input', 'tap', $n.x, $n.y) -Quiet | Out-Null
            Start-Sleep -Milliseconds 1400
          }
        } catch { }
        $shot = Save-Screenshot -Path (Join-Path $OutDir ("chronic-{0}-{1:D2}-{2}.png" -f $p.name, $i, $tab))
        $a = Audit-Native
        $total++
        if ($a.issues.Count -gt 0) {
          $bad++
          Write-Host ("    [проблема] {0}: {1}" -f $tab, ($a.issues -join '; ')) -ForegroundColor Red
        } else {
          Write-Host ("    ок  {0}" -f $tab) -ForegroundColor DarkGreen
        }
        $report.Add("- вкладка $tab`: " + $(if ($a.issues.Count) { '**' + ($a.issues -join '; ') + '**' } else { 'ок' }))
      }
      Invoke-Adb -Args @('shell', 'am', 'force-stop', 'ru.chronicnotebook') -Quiet | Out-Null
    }

    if (-not $App -or $App -eq 'drevo-yazyka') {
      Write-Host '  древо языка:'
      Invoke-Adb -Args @('shell', 'am', 'start', '-n', 'ru.drevo.yazyka/.MainActivity') -Quiet | Out-Null
      Start-Sleep -Seconds 5
      $report.Add('')
      $report.Add('### drevo-yazyka')
      $i = 0
      foreach ($tab in $DrevoTabs) {
        $i++
        try {
          $n = (Find-UiNode -Text $tab -Refresh) | Select-Object -First 1
          if ($n) {
            Invoke-Adb -Args @('shell', 'input', 'tap', $n.x, $n.y) -Quiet | Out-Null
            Start-Sleep -Milliseconds 1500
          }
        } catch { }
        # Вкладки ниже листа не помещаются: прокручиваем, чтобы аудит видел
        # нижние кнопки — именно они раньше схлопывались в полоску.
        Invoke-Adb -Args @('shell', 'input', 'swipe', 360, 1100, 360, 400, 400) -Quiet | Out-Null
        Start-Sleep -Milliseconds 700
        Save-Screenshot -Path (Join-Path $OutDir ("drevo-{0}-{1:D2}-{2}.png" -f $p.name, $i, $tab)) | Out-Null
        $a = Audit-Native
        $total++
        if ($a.issues.Count -gt 0) {
          $bad++
          Write-Host ("    [проблема] {0}: {1}" -f $tab, ($a.issues -join '; ')) -ForegroundColor Red
        } else {
          Write-Host ("    ок  {0}" -f $tab) -ForegroundColor DarkGreen
        }
        $report.Add("- вкладка $tab`: " + $(if ($a.issues.Count) { '**' + ($a.issues -join '; ') + '**' } else { 'ок' }))
      }
      Invoke-Adb -Args @('shell', 'am', 'force-stop', 'ru.drevo.yazyka') -Quiet | Out-Null
    }
    if (-not $App -or $App -eq 'speedmeter') {
      Write-Host '  спидометр:'
      # Отладочная сборка ставится рядом с релизной (applicationIdSuffix),
      # поэтому на стенде проверяем её — она же попадает в снимки.
      $pkg = 'ru.speedmeter.app.debug'
      $act = "$pkg/ru.speedmeter.app.MainActivity"
      Invoke-Adb -Args @('shell', 'am', 'start', '-n', $act) -Quiet | Out-Null
      Start-Sleep -Seconds 4
      $report.Add('')
      $report.Add('### speedmeter')
      $i = 0
      foreach ($tab in @('01-glavnyj', '02-rezultat')) {
        $i++
        if ($tab -eq '02-rezultat') {
          # Живой замер: ждём, пока отработает загрузка и отдача.
          try {
            $n = (Find-UiNode -Text 'Измерить' -Refresh) | Select-Object -First 1
            if ($n) { Invoke-Adb -Args @('shell', 'input', 'tap', $n.x, $n.y) -Quiet | Out-Null }
          } catch { }
          Start-Sleep -Seconds 30
        }
        Save-Screenshot -Path (Join-Path $OutDir ("speedmeter-{0}-{1}-{2}.png" -f $p.name, $i, $tab)) | Out-Null
        $a = Audit-Native
        $total++
        if ($a.issues.Count -gt 0) {
          $bad++
          Write-Host ("    [проблема] {0}: {1}" -f $tab, ($a.issues -join '; ')) -ForegroundColor Red
        } else {
          Write-Host ("    ок  {0}" -f $tab) -ForegroundColor DarkGreen
        }
        $report.Add("- экран $tab`: " + $(if ($a.issues.Count) { '**' + ($a.issues -join '; ') + '**' } else { 'ок' }))
      }
      Invoke-Adb -Args @('shell', 'am', 'force-stop', $pkg) -Quiet | Out-Null
    }
    $report.Add('')
  }
} finally {
  if (-not $NoRestore) {
    Write-Host ''
    Write-Host 'возвращаю исходные условия...'
    Invoke-Adb -Args @('shell', 'wm', 'size', 'reset') -Quiet | Out-Null
    Invoke-Adb -Args @('shell', 'wm', 'density', 'reset') -Quiet | Out-Null
    Invoke-Adb -Args @('shell', 'settings', 'put', 'system', 'font_scale', '1.0') -Quiet | Out-Null
    Invoke-Adb -Args @('shell', 'cmd', 'uimode', 'night', 'no') -Quiet | Out-Null
    Invoke-Adb -Args @('shell', 'settings', 'put', 'system', 'user_rotation', '0') -Quiet | Out-Null
  }
}

$report.Add('')
$report.Add("**Итого проверок: $total, с замечаниями: $bad**")
[System.IO.File]::WriteAllLines((Join-Path $OutDir 'report.md'), $report, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ''
Write-Host ("проверок: {0}, с замечаниями: {1}" -f $total, $bad)
Write-Host ("отчёт: {0}" -f (Join-Path $OutDir 'report.md'))
if ($bad -gt 0) { exit 1 } else { exit 0 }
