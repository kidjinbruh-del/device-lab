# device-lab / prep.ps1
# Разовая подготовка телефона под автотесты: экран не засыпает, анимации выключены,
# фон потит, автозапуск наших приложений разрешён, лишнее отключено.
# Всё обратимо: параметры меняются обратно теми же командами.
#
#   .\prep.ps1            # базовая подготовка
#   .\prep.ps1 -Disable   # + отключить сторонний мусор ( reversible через pm enable)
#   .\prep.ps1 -Radio     # + выключить Wi-Fi/Bluetooth/мобильный интернет
#   .\prep.ps1 -Report    # только показать текущее состояние

[CmdletBinding()]
param(
  [switch]$Disable,
  [switch]$Radio,
  [switch]$Report
)

. (Join-Path $PSScriptRoot 'lib\common.ps1')

# Чтобы кириллица в отчёте не превращалась в мусор при чтении вывода.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Lab = Get-LabRoot
$OurApps = @('ru.mooddiary', 'ru.chronicnotebook')
$sdk = [int]("$(Invoke-Adb -Args @('shell','getprop','ro.build.version.sdk') -Quiet)".Trim())

# Сторонний мусор, который лаборатории не нужен. Отключаем, не удаляем:
# pm enable вернёт всё обратно одной командой.
$Bloat = @(
  'com.yandex.searchapp', 'ru.vk.store', 'com.yandex.browser',
  'com.google.android.apps.tachyon', 'com.google.android.apps.docs',
  'com.google.android.apps.videos', 'com.google.android.apps.photos',
  'com.transsion.compass', 'com.ostechnologies.proxymyapps', 'com.smartlife.nebula'
)

function Step($what, $argsList) {
  if ($Report) { return }
  $out = Invoke-Adb -Args $argsList -Quiet
  Write-Host ("  {0,-46} {1}" -f $what, $(if ($out) { ($out -join ' ').Trim() } else { 'ok' }))
}

if ($Report) {
  Write-Host '--- состояние ---'
  (Get-DeviceInfo) | ConvertTo-Json
  Write-Host '--- анимации ---'
  foreach ($k in @('window_animation_scale', 'transition_animation_scale', 'animator_duration_scale')) {
    $v = (Invoke-Adb -Args @('shell', 'settings', 'get', 'global', $k) -Quiet | Select-Object -First 1)
    Write-Host ("  {0,-28} {1}" -f $k, $v)
  }
  Write-Host '--- ключ блокировки ---'
  Write-Host ('  disabled: ' + (Invoke-Adb -Args @('shell', 'locksettings', 'get-disabled') -Quiet))
  exit 0
}

$serial = (Invoke-Adb -Args @('devices') -Quiet | Select-String -Pattern '^\S+\s+device' | Select-Object -First 1)
$usb = "$serial" -notmatch ':\d+$'

Write-Host '--- базовая подготовка ---'
Step 'экран и плотность -> нативные' @('shell', 'wm', 'size', 'reset')
Step 'плотность -> нативная' @('shell', 'wm', 'density', 'reset')
Step 'шрифт -> 1.0' @('shell', 'settings', 'put', 'system', 'font_scale', '1.0')
Step 'системная тёмная тема -> выкл' @('shell', 'cmd', 'uimode', 'night', 'no')
Step 'поворот -> портрет, автоповорот выкл' @('shell', 'settings', 'put', 'system', 'accelerometer_rotation', '0')
Step 'поворот экрана -> 0' @('shell', 'settings', 'put', 'system', 'user_rotation', '0')
Step '24-часовой формат' @('shell', 'settings', 'put', 'system', 'time_12_24', '24')
Step 'таймаут экрана -> 30 мин' @('shell', 'settings', 'put', 'system', 'screen_off_timeout', '1800000')
Step 'не засыпать на зарядке' @('shell', 'svc', 'power', 'stayon', 'true')
Step 'анимации -> 0 (быстрые тапы)' @('shell', 'settings', 'put', 'global', 'window_animation_scale', '0')
Step 'анимации переходов -> 0' @('shell', 'settings', 'put', 'global', 'transition_animation_scale', '0')
Step 'анимации аниматоров -> 0' @('shell', 'settings', 'put', 'global', 'animator_duration_scale', '0')
Step 'режим низкого энергопотребления -> выкл' @('shell', 'settings', 'put', 'global', 'low_power', '0')
Step 'отключить блокировку экрана' @('shell', 'locksettings', 'set-disabled', 'true')

Write-Host '--- наши приложения ---'
foreach ($p in $OurApps) {
  $installed = (Invoke-Adb -Args @('shell', 'pm', 'list', 'packages', $p) -Quiet) -match 'package:'
  if (-not $installed) { Write-Host ("  {0,-46} {1}" -f $p, 'не установлен'); continue }
  Step "$p : вне dozing" @('shell', 'dumpsys', 'deviceidle', 'whitelist', "+$p")
  Step "$p : фон разрешён" @('shell', 'appops', 'set', $p, 'RUN_IN_BACKGROUND', 'allow')
  Step "$p : запуск в фоне разрешён" @('shell', 'appops', 'set', $p, 'START_FOREGROUND', 'allow')
  if ($sdk -ge 33) {
    # На Android 13+ уведомления спрашивают разрешения; на 12 такого права нет.
    Step "$p : разрешение уведомлений" @('shell', 'pm', 'grant', $p, 'android.permission.POST_NOTIFICATIONS')
  }
}

Write-Host '--- чистка мусора с телефона ---'
Step 'удалить наши временные файлы' @('shell', 'rm', '-rf', '/sdcard/Download/mood_import_test.json', '/sdcard/Download/mood_import_test.csv', '/sdcard/__lab_shot.png')
Step 'почистить кэши, где можно' @('shell', 'pm', 'trim-caches', '1G')

if ($Disable) {
  Write-Host '--- отключение сторонних приложений (обратимо) ---'
  $have = Get-Packages
  foreach ($b in $Bloat) {
    if ($have -contains $b) {
      Step ("отключить " + $b) @('shell', 'pm', 'disable-user', '--user', '0', $b)
    }
  }
} else {
  Write-Host '(сторонние приложения не трогали: добавьте -Disable)'
}

if ($Radio) {
  if ($usb) {
    Write-Host '--- радиомодули (adb по USB — соединение не потеряется) ---'
    Step 'выключить Wi-Fi' @('shell', 'svc', 'wifi', 'disable')
    Step 'выключить Bluetooth' @('shell', 'svc', 'bluetooth', 'disable')
    Step 'выключить мобильный интернет' @('shell', 'svc', 'data', 'disable')
  } else {
    Write-Host 'ВНИМАНИЕ: adb не по USB, радио не трогаем.'
  }
}

Write-Host '--- готово ---'
Write-Host 'Состояние:'
(Get-DeviceInfo) | ConvertTo-Json