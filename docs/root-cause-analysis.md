# Root cause analysis / Анализ причин

[English](#english) | [Русский](#русский)

---

## English

### Target

Apple Music for Windows (`AppleInc.AppleMusicWin`, package version
`1.1540.23042.0`), unpacked from the official `AppleMusic.msixbundle`.
Analyzed on Windows 10 IoT Enterprise LTSC 21H2, build `10.0.19044`, using
IDA Pro (static analysis of `AMP.Utils.dll`), Windows Event Viewer, and
live testing of `Add-AppxPackage` / `ActivateApplication`.

### Symptom 1: silent launch failure

Running `AppleMusic.exe` directly (or via its AppExecutionAlias) did
nothing — no window, no error dialog. Running it through
`IApplicationActivationManager::ActivateApplication` (the real Desktop
Bridge activation path) returned `0x80270254`. Event Viewer
(`Microsoft-Windows-AppModel-Runtime/Admin`, Event ID 202) logged the same
failure with no further detail.

### Finding the manifest gate

`AppxManifest.xml` declares:

```xml
<Dependencies>
  <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.26100.0" MaxVersionTested="..."/>
</Dependencies>
```

`10.0.26100.0` is Windows 11 24H2. On Windows 10 (`10.0.19044`),
`AppXDeploymentServer` enforces this at install time and aborts with
`0x80073cfd` (`ERROR_INSTALL_PACKAGE_NOT_FOUND`-adjacent "does not meet the
minimum OS version" error). Simply editing `MinVersion` down in the
manifest and re-running `Add-AppxPackage -Register` was **not** enough —
the activation still failed with `0x80270254`.

### Why lowering MinVersion alone wasn't enough

Windows tracks installed packages in `StateRepository-Machine.srd`, a
SQLite database maintained by `Windows.StateRepository.dll`, with a
write-through cache in the registry at
`HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModel\StateRepository\Cache`.

When the *unmodified* bundle was first attempted on this machine,
`AppXDeploymentServer` got far enough to INSERT a row into the
`PackageFamily` table for `AppleInc.AppleMusicWin_nzyj5cx40ttqa` — but with
`Publisher = NULL` — before the `MinVersion` check aborted the rest of the
install. `Windows.StateRepository.dll` has no `UPDATE PackageFamily`
statement in its repertoire (packages are expected to be fully removed and
reinstalled, not patched in place), so every later
`Add-AppxPackage -Register` attempt under the *same* package family name
reused that same broken, `Publisher = NULL` row instead of creating a
fresh one.

Later, when `Windows.StateRepository.dll` rebuilt its registry-backed
`SRCache` tree (`entity-cachepackagefamily.cpp`, around offset `0x5652B` in
the build we examined), writing
`HKLM\...\StateRepository\Cache\PackageFamily\Data\46` failed because the
cached `Publisher` value was null. The practical effect:
`kernelbase!FindPackagesByPackageFamily` returned zero packages for that
family, so `activationmanager.dll!DevPlat::Shared::PraidAndPackageInfoFromAppId`
(`appidutil.cpp` line 79) had nothing to resolve and returned
`0x80270254` — the exact error seen when trying to launch, even after the
manifest's `MinVersion` was fixed.

**Fix:** rename `<Identity Name="AppleInc.AppleMusicWin">` to a 22-
character name Windows has never seen before
(`AppleInc.AppleMusicW10`). This forces `StateRepository` to `INSERT` a
brand-new `PackageFamily` row — with a valid, non-null `Publisher` and
`PackageSID` this time — instead of reusing the broken one.

### Symptom 2: crash after accepting the license screen

With a renamed package identity (tested first as
`AppleInc.AppleMusicWin2`, a different but still 22-character name), the
app launched and showed its license agreement screen — progress — but
crashed with `0xc000027b` / `0x800703FA` (`ERROR_KEY_DELETED`, surfaced
through `combase.dll`) immediately after clicking "Accept".

### Finding the DLL-level identity check

`AMP.Utils.dll` exports `SharedUtils::IsMusicPackage()`, which:

1. Calls `GetCurrentPackageFullName` / reads the package family name of
   the running process.
2. Checks that its length is exactly `0x16` (22 UTF-16 characters).
3. Compares it against the literal wide string `L"AppleInc.AppleMusicWin"`
   embedded in the DLL's data section.

Several other exports (`GetInstalledMusicAppVersion`,
`GetMusicAppUserModelId`, `LaunchMusicApp`) call into the same check or a
sibling one for IPC/COM activation between `AppleMusic.exe` and
`AMPLibraryAgent.exe`. When the running package's family name didn't
match this hardcoded string, those identity checks failed in ways that
`AppleMusic.exe` and `AMPLibraryAgent.exe` didn't handle gracefully,
producing the `0xc000027b` crash right after the first real IPC exchange
(post-license-acceptance).

**Fix:** keep the renamed package identity exactly 22 characters long
(`AppleInc.AppleMusicW10` — same length as the original, different
content) and patch the embedded UTF-16LE string in `AMP.Utils.dll` from
`AppleInc.AppleMusicWin` to `AppleInc.AppleMusicW10` to match. The length
constraint is why the tool always renames to a same-length string rather
than an arbitrary one.

### Symptom 3 (anticipated, pre-empted): runtime Windows-11 gating

Independent of both issues above, `AMP.Utils.dll` also exports:

- `?IsMachineWindows11@SharedUtils@@YA_NXZ`
- `?IsMachineWindows11_22H2_OrNewer@SharedUtils@@YA_NXZ`
- `?IsMachineWindows11_24H2_OrNewer@SharedUtils@@YA_NXZ`

Each has this x64 shape:

```asm
sub  rsp, 38h
lea  rcx, [rsp+20h]
call GetOSVersion          ; fills a RTL_OSVERSIONINFOW-like struct at [rsp+20h]
cmp  dword ptr [rsp+20h], <build_number>   ; 21996 / 22621 / 26100
setae al                   ; al = (current_build >= build_number)
add  rsp, 38h
ret
```

These feed into feature gating elsewhere in the app (e.g. deciding whether
to show certain WinUI 3 features that *happen* to only be exercised on
Windows 11 builds in Apple's own testing, not because they require a
Windows-11-only kernel or API — Microsoft's WinUI 3 / Windows App SDK,
which this app is built on, officially supports Windows 10 1809 and
newer). Left unpatched, these could cause subtler behavioral differences
or crashes once the two blocking issues above were fixed. They are patched
pre-emptively to `mov al, 1; ret`, i.e. "yes, this is Windows 11 or newer",
regardless of the real build number.

### Why this is safe

- `Windows.Desktop` apps built on the Windows App SDK / WinUI 3 (what this
  app uses) are supported back to Windows 10 version 1809 by Microsoft's
  own documentation. Nothing in the three functions above, or in the
  manifest's `TargetDeviceFamily`, reflects an actual kernel or API
  dependency — they are policy checks, not capability checks.
- No DRM, licensing, Apple ID authentication, or server-side API call is
  touched by any of these patches. They only affect local OS-version
  self-reporting.
- The patches are narrowly scoped (3 known functions by name, plus a
  signature scan restricted to the exact instruction shape and a build
  number in the real Windows 11 range) to avoid accidentally touching
  unrelated code.

---

## Русский

### Объект анализа

Apple Music для Windows (`AppleInc.AppleMusicWin`, версия пакета
`1.1540.23042.0`), распакованный из официального `AppleMusic.msixbundle`.
Анализ проводился на Windows 10 IoT Enterprise LTSC 21H2, сборка
`10.0.19044`, с помощью IDA Pro (статический анализ `AMP.Utils.dll`),
журнала событий Windows и живого тестирования `Add-AppxPackage` /
`ActivateApplication`.

### Симптом 1: тихий сбой запуска

Прямой запуск `AppleMusic.exe` (или через его AppExecutionAlias) ничего не
делал — ни окна, ни диалога с ошибкой. Запуск через
`IApplicationActivationManager::ActivateApplication` (реальный путь
активации Desktop Bridge) возвращал `0x80270254`. Журнал событий
(`Microsoft-Windows-AppModel-Runtime/Admin`, Event ID 202) фиксировал ту же
ошибку без дополнительных деталей.

### Поиск ограничения в манифесте

`AppxManifest.xml` объявляет:

```xml
<Dependencies>
  <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.26100.0" MaxVersionTested="..."/>
</Dependencies>
```

`10.0.26100.0` — это Windows 11 24H2. На Windows 10 (`10.0.19044`)
`AppXDeploymentServer` проверяет это при установке и падает с
`0x80073cfd` (ошибка, близкая к "не соответствует минимальной версии ОС").
Простого понижения `MinVersion` в манифесте и повторного запуска
`Add-AppxPackage -Register` оказалось **недостаточно** — активация всё
равно падала с `0x80270254`.

### Почему одного понижения MinVersion не хватило

Windows хранит установленные пакеты в `StateRepository-Machine.srd` —
SQLite-базе, которую обслуживает `Windows.StateRepository.dll`, с
сквозным кешем в реестре по пути
`HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModel\StateRepository\Cache`.

Когда *немодифицированный* бандл был впервые опробован на этой машине,
`AppXDeploymentServer` успел вставить запись в таблицу `PackageFamily` для
`AppleInc.AppleMusicWin_nzyj5cx40ttqa` — но с `Publisher = NULL` — прежде
чем проверка `MinVersion` прервала установку. У
`Windows.StateRepository.dll` нет инструкции `UPDATE PackageFamily` в
арсенале (ожидается, что пакеты полностью удаляются и переустанавливаются,
а не патчатся на месте), поэтому каждая последующая попытка
`Add-AppxPackage -Register` под *тем же* именем семейства пакета
переиспользовала ту же сломанную запись с `Publisher = NULL` вместо
создания новой.

Позже, когда `Windows.StateRepository.dll` перестраивал привязанное к
реестру дерево `SRCache` (`entity-cachepackagefamily.cpp`, около смещения
`0x5652B` в исследуемой сборке), запись в
`HKLM\...\StateRepository\Cache\PackageFamily\Data\46` падала, потому что
закешированное значение `Publisher` было null. Практический эффект:
`kernelbase!FindPackagesByPackageFamily` возвращал ноль пакетов для этого
семейства, поэтому у
`activationmanager.dll!DevPlat::Shared::PraidAndPackageInfoFromAppId`
(`appidutil.cpp`, строка 79) не было что разрешать, и она возвращала
`0x80270254` — именно эту ошибку мы видели при попытке запуска, даже
после исправления `MinVersion` в манифесте.

**Решение:** переименовать `<Identity Name="AppleInc.AppleMusicWin">` в
имя длиной 22 символа, которое Windows ещё не видела
(`AppleInc.AppleMusicW10`). Это вынуждает `StateRepository` выполнить
`INSERT` новой записи `PackageFamily` — на этот раз с валидными,
непустыми `Publisher` и `PackageSID` — вместо переиспользования сломанной.

### Симптом 2: падение после принятия лицензионного соглашения

С переименованной identity пакета (сначала протестировано как
`AppleInc.AppleMusicWin2` — другое, но тоже 22-символьное имя) приложение
запускалось и показывало экран лицензионного соглашения — прогресс — но
падало с `0xc000027b` / `0x800703FA` (`ERROR_KEY_DELETED`, проявляется
через `combase.dll`) сразу после нажатия "Accept".

### Поиск проверки identity на уровне DLL

`AMP.Utils.dll` экспортирует `SharedUtils::IsMusicPackage()`, которая:

1. Вызывает `GetCurrentPackageFullName` / читает имя семейства пакета
   текущего процесса.
2. Проверяет, что его длина равна ровно `0x16` (22 символа UTF-16).
3. Сравнивает его с буквальной wide-строкой
   `L"AppleInc.AppleMusicWin"`, встроенной в секцию данных DLL.

Несколько других экспортов (`GetInstalledMusicAppVersion`,
`GetMusicAppUserModelId`, `LaunchMusicApp`) обращаются к этой же проверке
или к родственной для IPC/COM-активации между `AppleMusic.exe` и
`AMPLibraryAgent.exe`. Когда имя семейства запущенного пакета не совпадало
с этой захардкоженной строкой, эти проверки identity отказывали так, что
`AppleMusic.exe` и `AMPLibraryAgent.exe` не обрабатывали это корректно,
что приводило к падению `0xc000027b` сразу после первого реального
обмена по IPC (после принятия лицензии).

**Решение:** сохранить переименованную identity пакета ровно 22 символа
длиной (`AppleInc.AppleMusicW10` — та же длина, что и оригинал, но другое
содержимое) и пропатчить встроенную в `AMP.Utils.dll` UTF-16LE строку с
`AppleInc.AppleMusicWin` на `AppleInc.AppleMusicW10`, чтобы она совпадала.
Именно это ограничение по длине — причина, почему инструмент всегда
переименовывает в строку той же длины, а не в произвольную.

### Симптом 3 (предугаданный, упреждён): блокировка по версии ОС во время работы

Независимо от двух проблем выше, `AMP.Utils.dll` также экспортирует:

- `?IsMachineWindows11@SharedUtils@@YA_NXZ`
- `?IsMachineWindows11_22H2_OrNewer@SharedUtils@@YA_NXZ`
- `?IsMachineWindows11_24H2_OrNewer@SharedUtils@@YA_NXZ`

Каждая имеет такую структуру на x64:

```asm
sub  rsp, 38h
lea  rcx, [rsp+20h]
call GetOSVersion          ; заполняет структуру вроде RTL_OSVERSIONINFOW по [rsp+20h]
cmp  dword ptr [rsp+20h], <номер_сборки>   ; 21996 / 22621 / 26100
setae al                   ; al = (текущая_сборка >= номер_сборки)
add  rsp, 38h
ret
```

Результат этих функций используется для включения/отключения отдельных
функций в других местах приложения (например, решение показывать ли
некоторые возможности WinUI 3, которые в тестах самой Apple *оказались*
задействованы только на сборках Windows 11 — не потому что они требуют
ядро или API, доступные только в Windows 11: Windows App SDK / WinUI 3, на
котором построено это приложение, по официальной документации Microsoft
поддерживает Windows 10 начиная с версии 1809). Если их не патчить, после
устранения двух блокирующих проблем выше они могли бы вызывать более
тонкие различия в поведении или падения. Они патчатся заранее в
`mov al, 1; ret`, то есть "да, это Windows 11 или новее", независимо от
реального номера сборки.

### Почему это безопасно

- Приложения `Windows.Desktop`, построенные на Windows App SDK / WinUI 3
  (именно это использует это приложение), по собственной документации
  Microsoft поддерживаются начиная с Windows 10 версии 1809. Ничто в трёх
  функциях выше или в `TargetDeviceFamily` манифеста не отражает реальную
  зависимость от ядра или API — это проверки политики, а не проверки
  возможностей.
- Никакой из этих патчей не затрагивает DRM, авторизацию, вход в Apple ID
  или обращения к серверным API. Они влияют только на локальное
  самоопределение версии ОС.
- Патчи сделаны узко (3 известные функции по имени, плюс сканирование по
  сигнатуре, ограниченное точной формой инструкций и номером сборки в
  реальном диапазоне Windows 11), чтобы случайно не затронуть несвязанный
  код.
