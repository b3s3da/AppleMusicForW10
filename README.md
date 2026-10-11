# AppleMusicForW10

Patch the official Windows Apple Music app (`AppleInc.AppleMusicWin`) to run on
**Windows 10 (version 21H2 / build 19044 and newer)** instead of refusing to
start because it demands Windows 11.

[Русская версия ниже](#русская-версия)

> **Disclaimer.** This is an independent, unofficial tool. It is not
> affiliated with or endorsed by Apple Inc. **This repository contains, and
> will never contain, any Apple binary.** `install.ps1` downloads the
> current `AppleMusic.msixbundle` itself, directly from Microsoft's own
> package delivery servers, at install time — the same mechanism `winget`
> and the Microsoft Store app use. Nothing is cached or redistributed here.

## Why this exists

Apple's installer for the Windows Apple Music app refuses to run on Windows
10, even on a fully patched, current build (e.g. `10.0.19044`, Windows 10 IoT
Enterprise LTSC 21H2). The app shows no error — it just doesn't launch, or it
crashes right after you accept the license screen.

**There is no real technical reason for this.** Windows 10 and Windows 11
share the exact same NT kernel family and Win32 API surface relevant to this
app. Apple Music for Windows is a Desktop Bridge / MSIX app built on WinUI
and standard Win32/COM APIs — nothing it does requires a Windows-11-only
kernel feature. The Windows-11 requirement is an artificial gate, enforced in
two independent places:

1. **The package manifest** (`AppxManifest.xml`) declares
   `<TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.26100.0" .../>`,
   i.e. "Windows 11 24H2 or newer". Windows' package deployment service
   (`AppXDeploymentServer`) enforces this at install time and refuses to
   register the package on an older build.
2. **`AMP.Utils.dll`** (a support DLL shipped inside the package) exports
   functions such as `SharedUtils::IsMachineWindows11`,
   `IsMachineWindows11_22H2_OrNewer`, and `IsMachineWindows11_24H2_OrNewer`.
   These independently re-check the running OS build number at runtime and
   gate app behavior on it — so even if you trick the installer into
   registering the package, the app can still refuse to behave correctly
   (or crash) once it's running.

We reverse-engineered both checks with IDA Pro and traced the exact failure
chain on a real Windows 10 21H2 machine (full writeup in
[`docs/root-cause-analysis.md`](docs/root-cause-analysis.md)). The short
version:

- With the stock manifest, `Add-AppxPackage` aborts with `0x80073cfd`
  (`MinVersion` not satisfied) — but not before Windows' `StateRepository`
  (the SQLite-backed package database) has already inserted a broken,
  `Publisher = NULL` row for the package family. Every subsequent install
  attempt under the *same* package family name reuses that broken row,
  which later makes `kernelbase!FindPackagesByPackageFamily` return zero
  packages and `ActivateApplication` fail with `0x80270254`, even after you
  lower `MinVersion` in the manifest.
- The fix is to lower `MinVersion` **and** rename the package Identity to a
  same-length name Windows has never seen before, forcing a clean database
  row. `AMP.Utils.dll` independently checks that exact package name
  (`AppleInc.AppleMusicWin`, 22 UTF-16 characters) in several places, so the
  same string must be patched inside the DLL to match the renamed manifest.
- `AMP.Utils.dll`'s Windows-11-version checks are patched to always return
  `true`, since nothing downstream of them actually needs Windows 11 — they
  exist purely to gate the OS version, not to use any OS feature.

None of this touches DRM, licensing, or any Apple server-side logic. It
only removes an artificial OS-version gate so the app runs on a kernel it
is already fully compatible with.

## What's in this repo

| Path | What it is |
|---|---|
| `install.ps1` | One-command installer: downloads the current package from Microsoft, patches it, installs it. No external tools, no third-party sites, no bundled Apple binary. |
| `cmd/applemusic-patcher/` | Go CLI alternative: same patch logic, operates on a `.msixbundle` you already have on disk |
| `internal/pe/` | Minimal PE32+/PE32 export-table parser (no external deps) |
| `internal/patcher/` | The actual patch logic (manifest rewrite + DLL patch) |
| `internal/msix/` | `.msixbundle`/`.msix` unpacking and signature-file cleanup |
| `internal/register/` | Thin wrapper around `Add-AppxPackage -Register` |
| `scripts/patch_apple_music.py` | Python reference implementation of the Go CLI (same logic, zero dependencies) |
| `docs/root-cause-analysis.md` | Full write-up of the reverse-engineering |

All three implementations (`install.ps1`'s patch step, the Go CLI, and the
Python script) produce **byte-identical** patched output — verified with
`Get-FileHash` during development.

## Usage

### One-line install (recommended)

Run this in a normal (non-admin) PowerShell window:

```powershell
irm https://raw.githubusercontent.com/b3s3da/AppleMusicForW10/main/install.ps1 | iex
```

This single command:

1. Resolves the current Apple Music version and its direct CDN URL from
   Microsoft's own package delivery servers (`fe3.delivery.mp.microsoft.com`),
   using the same public protocol `winget`/the Store app use. No
   `AppleMusic.msixbundle` is ever stored in this repository or downloaded
   from anywhere other than Microsoft.
2. Downloads it to a temp folder.
3. Patches the manifest and `AMP.Utils.dll` (see below for exactly what
   changes).
4. Installs into `%LOCALAPPDATA%\Programs\AppleMusic` and registers the
   package.

To customize the run, download the script first:

```powershell
irm https://raw.githubusercontent.com/b3s3da/AppleMusicForW10/main/install.ps1 -OutFile install.ps1
.\install.ps1 -Launch                      # also launch the app when done
.\install.ps1 -Dest "D:\Apps\AppleMusic"   # install somewhere else
.\install.ps1 -KeepDownload                # keep the downloaded/patched files for inspection
```

**Re-running this script later to pick up an Apple Music update is safe
and keeps your data.** The package family name (`AppleInc.AppleMusicW10`)
stays the same across runs, so re-registering is a normal in-place
update, not a reinstall — your Apple ID sign-in, local library cache, and
equalizer settings are not touched. See
[Why updates don't wipe your sign-in](#why-updates-dont-wipe-your-sign-in)
below for exactly what is and isn't preserved.

### Alternative: Go CLI or Python script, for an `.msixbundle` you already have

If you'd rather download `AppleMusic.msixbundle` yourself (e.g. via the
Microsoft Store app, or a sideloading tool like
[store.rg-adguard.net](https://store.rg-adguard.net/)) and patch that exact
file instead of letting the script fetch the latest one, use the Go CLI or
the Python script:

```powershell
# Go CLI -- auto-detects AppleMusic.msixbundle next to the exe,
# installs into %LOCALAPPDATA%\Programs\AppleMusic, and launches it.
.\applemusic-patcher.exe -launch

# Or specify everything explicitly:
.\applemusic-patcher.exe -source "C:\Downloads\AppleMusic.msixbundle" `
                          -dest   "C:\Users\you\AppData\Local\Programs\AppleMusic" `
                          -launch
```

Flags:

| Flag | Meaning |
|---|---|
| `-source PATH` | `.msixbundle`, `*_x64.msix`, or an already-unpacked package folder. Default: auto-detected next to the executable. |
| `-dest PATH` | Install directory. Default: `%LOCALAPPDATA%\Programs\AppleMusic`. |
| `-in-place` | Patch and register directly inside `-source`, without copying. Useful to re-patch an already-installed/updated copy. |
| `-launch` | Launch Apple Music once registration succeeds. |

Re-running the tool (e.g. after Apple pushes an app update that
re-overwrites the files) is safe: it detects already-patched files and
skips them without corrupting anything, and — like `install.ps1` — it
never wipes an existing registration of the renamed package family.

#### Building the Go CLI from source

Requires Go 1.21+.

```powershell
git clone https://github.com/b3s3da/AppleMusicForW10.git
cd AppleMusicForW10
go build -o applemusic-patcher.exe ./cmd/applemusic-patcher
```

#### Python reference version

`scripts/patch_apple_music.py` implements the identical logic in pure
Python 3 (standard library only — no `pip install` needed):

```powershell
python scripts\patch_apple_music.py -s "C:\Downloads\AppleMusic.msixbundle" --launch
```

## Why updates don't wipe your sign-in

The first time any of these tools runs on a machine where the *original*,
unpatched Apple package (`AppleInc.AppleMusicWin`) was ever registered or
attempted, it removes that registration. That one-time removal is
required: that package identity's entry in Windows' `StateRepository`
database is permanently broken on an affected machine (see
[`docs/root-cause-analysis.md`](docs/root-cause-analysis.md)), and nothing
short of removing it lets the renamed package register cleanly.

Every run after that targets only the renamed package family
(`AppleInc.AppleMusicW10`) and never removes its existing registration
first — `Add-AppxPackage -Register` is called directly on top of it. This
is the same thing Windows does for a normal in-place app update: the
package's per-user data folder
(`%LOCALAPPDATA%\Packages\AppleInc.AppleMusicW10_nzyj5cx40ttqa\`), which
holds your Apple ID sign-in token, local library cache, and equalizer/EQ
settings, is left untouched. We verified this directly: the contents and
timestamps of `LocalState`, `LocalCache\Roaming\Apple Computer\Preferences`
(including `com.apple.Music.eq.plist`), and `Settings\settings.dat` are
unchanged after re-running the installer to "update" an already-installed
copy to the same or a newer version.

## How the patch works, in detail

1. **Unpack.** `AppleMusic.msixbundle` is a ZIP containing one `.msix` per
   architecture (`x64`, `arm64`). The tool finds the `x64` one and unpacks
   it directly — no intermediate files are written to disk for the bundle
   itself.
2. **Strip signature metadata.** `AppxSignature.p7x`, `AppxBlockMap.xml`,
   `[Content_Types].xml`, and `AppxMetadata\CodeIntegrity.cat` are deleted.
   These describe the *original, unpatched* file contents; once a binary
   inside the package is modified, Windows would otherwise refuse to load
   it as tampered.
3. **Patch `AppxManifest.xml`.**
   - `MinVersion="10.0.26100.0"` → `MinVersion="10.0.19044.0"`.
   - `<Identity Name="AppleInc.AppleMusicWin">` → `Name="AppleInc.AppleMusicW10"`
     (same length, 22 characters — required for the string patch below to
     line up, and to avoid the undroppable broken `StateRepository` row left
     behind by any earlier install attempt under the original name).
4. **Patch `AMP.Utils.dll`**, using two independent, overlapping techniques
   so the patch keeps working even if Apple reorders or inlines functions in
   a future build:
   - **By export name:** every PE export whose name contains
     `IsMachineWindows11` (`?IsMachineWindows11@SharedUtils@@YA_NXZ` and the
     `_22H2_OrNewer`/`_24H2_OrNewer` variants) is overwritten at its entry
     point with `B0 01 C3` (`mov al, 1; ret`) — unconditionally returns
     `true`.
   - **By byte signature:** the whole `.text` section is scanned for the
     x64 instruction pattern these checks share:
     ```
     48 83 EC 38              sub  rsp, 38h
     48 8D 4C 24 20           lea  rcx, [rsp+20h]
     E8 xx xx xx xx           call GetOSVersion
     81 7C 24 20 xx xx 00 00  cmp  dword ptr [rsp+20h], <build_number>
     0F 93 C0                 setae al
     48 83 C4 38              add  rsp, 38h
     C3                       ret
     ```
     Any match whose captured build number looks like a real Windows 11
     build (21996, 22621, 26100, ...) is patched the same way, even if it
     isn't exported under a recognizable name.
   - **Package-name string:** the UTF-16LE string `AppleInc.AppleMusicWin`
     embedded in the DLL (used by `SharedUtils::IsMusicPackage`,
     `GetMusicAppUserModelId`, `LaunchMusicApp`, etc. for package-identity
     checks) is rewritten to `AppleInc.AppleMusicW10` to match the renamed
     manifest `Identity`.
5. **Register.** The broken stock registration of the original package
   name is removed only if it's still present (first-run migration — see
   [above](#why-updates-dont-wipe-your-sign-in)), then
   `Add-AppxPackage -Register <path>\AppxManifest.xml` registers the
   patched package in place, with no store trip, no re-download, and no
   loss of existing sign-in/library data on repeat runs.

## Limitations / what this does *not* do

- It does not break or bypass DRM, Apple ID auth, or Apple Music
  subscription checks — those are unaffected by the OS-version gate.
- It does not add ARM64-on-Windows-10 support beyond what the `arm64.msix`
  in the bundle already implies (the tool currently targets `x64` only; PRs
  for `arm64` are welcome, the logic is identical).
- Apple could tighten the checks in a future update (real
  Windows-11-exclusive API usage, different signature, etc.) — that's an
  engineering choice they haven't made for this app as of this release;
  this tool patches what is actually there today.

## Contributing

Issues and PRs are welcome — in particular, confirmation (or signature
updates) for other package versions. See
[`docs/root-cause-analysis.md`](docs/root-cause-analysis.md) for the full
RE notes if you want to verify or extend the patch for a new build.

## License

MIT. See [`LICENSE`](LICENSE). Not affiliated with Apple Inc.

---

# Русская версия

Патчер для официального Windows-приложения Apple Music
(`AppleInc.AppleMusicWin`), чтобы оно запускалось на **Windows 10 (версия
21H2 / сборка 19044 и новее)** вместо того, чтобы требовать Windows 11 и
не запускаться.

> **Дисклеймер.** Это независимый неофициальный инструмент. Он не
> связан с Apple Inc. и не одобрен ею. **В этом репозитории нет и никогда
> не будет ни одного бинарника Apple.** `install.ps1` сам скачивает
> актуальный `AppleMusic.msixbundle` напрямую с серверов доставки пакетов
> Microsoft в момент установки — тем же механизмом, которым пользуются
> `winget` и сам клиент Microsoft Store. Здесь ничего не кешируется и не
> распространяется повторно.

## Зачем это нужно

Официальный установщик Apple Music для Windows отказывается запускаться на
Windows 10, даже на полностью актуальной сборке (например `10.0.19044`,
Windows 10 IoT Enterprise LTSC 21H2). Приложение не показывает ошибку — оно
просто не запускается, либо падает сразу после принятия лицензионного
соглашения.

**Реальной технической причины для этого нет.** Windows 10 и Windows 11
используют одно и то же семейство ядра NT и один и тот же набор Win32 API,
важный для этого приложения. Apple Music для Windows — это приложение на
Desktop Bridge / MSIX, построенное на WinUI и стандартных Win32/COM API:
в нём нет ничего, что требует функций ядра, доступных только в Windows 11.
Требование Windows 11 — искусственное ограничение, установленное в двух
независимых местах:

1. **Манифест пакета** (`AppxManifest.xml`) объявляет
   `<TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.26100.0" .../>`,
   то есть "Windows 11 24H2 и новее". Служба развёртывания пакетов Windows
   (`AppXDeploymentServer`) проверяет это при установке и отказывается
   регистрировать пакет на более старой сборке.
2. **`AMP.Utils.dll`** (вспомогательная DLL внутри пакета) экспортирует
   функции `SharedUtils::IsMachineWindows11`,
   `IsMachineWindows11_22H2_OrNewer`, `IsMachineWindows11_24H2_OrNewer`. Они
   независимо проверяют номер сборки ОС уже во время работы приложения и
   блокируют поведение на основе этой проверки — то есть даже если обойти
   установщик, приложение всё равно может отказать в работе или упасть уже
   после запуска.

Мы реверс-инжинирили обе проверки в IDA Pro и прошли по цепочке реального
сбоя на живой машине с Windows 10 21H2 (полный разбор — в
[`docs/root-cause-analysis.md`](docs/root-cause-analysis.md)). Короткая
версия:

- С оригинальным манифестом `Add-AppxPackage` падает с `0x80073cfd`
  (не выполнено условие `MinVersion`) — но перед этим `StateRepository`
  (SQLite-база пакетов Windows) уже успевает вставить сломанную запись с
  `Publisher = NULL` для семейства пакета. Любая последующая попытка
  установки под *тем же* именем семейства пакета переиспользует эту
  сломанную запись, из-за чего `kernelbase!FindPackagesByPackageFamily`
  позже возвращает ноль пакетов, а `ActivateApplication` падает с
  `0x80270254` — даже после понижения `MinVersion` в манифесте.
- Решение — понизить `MinVersion` **и** переименовать Identity пакета в имя
  той же длины, которое Windows ещё не видела, чтобы вынудить создать
  чистую запись в базе. `AMP.Utils.dll` независимо проверяет именно это имя
  пакета (`AppleInc.AppleMusicWin`, 22 символа UTF-16) в нескольких местах,
  поэтому ту же строку нужно пропатчить внутри DLL, чтобы она совпадала с
  переименованным манифестом.
- Проверки версии Windows 11 в `AMP.Utils.dll` патчатся так, чтобы всегда
  возвращать `true` — ничего из того, что идёт после этих проверок, реально
  не требует Windows 11: они существуют только для блокировки по версии ОС,
  а не для использования какой-либо её функции.

Всё это не затрагивает DRM, авторизацию Apple ID или проверки подписки
Apple Music. Патч только убирает искусственное ограничение по версии ОС,
чтобы приложение работало на ядре, с которым оно уже полностью совместимо.

## Что лежит в репозитории

| Путь | Что это |
|---|---|
| `install.ps1` | Установщик в одну команду: сам скачивает актуальный пакет у Microsoft, патчит его, устанавливает. Без сторонних инструментов, без сторонних сайтов, без бинарника Apple внутри репозитория. |
| `cmd/applemusic-patcher/` | Альтернативный CLI на Go: та же логика патча, работает с `.msixbundle`, который уже есть у вас на диске |
| `internal/pe/` | Минимальный парсер таблицы экспортов PE32+/PE32 (без внешних зависимостей) |
| `internal/patcher/` | Собственно логика патчей (манифест + DLL) |
| `internal/msix/` | Распаковка `.msixbundle`/`.msix` и очистка файлов подписи |
| `internal/register/` | Тонкая обёртка над `Add-AppxPackage -Register` |
| `scripts/patch_apple_music.py` | Эталонная реализация CLI на Python (та же логика, без зависимостей) |
| `docs/root-cause-analysis.md` | Полный разбор реверс-инжиниринга |

Все три реализации (патч-шаг `install.ps1`, CLI на Go и скрипт на Python)
дают **побайтово идентичный** результат — проверено через `Get-FileHash`
в процессе разработки.

## Использование

### Установка в одну команду (рекомендуется)

Выполните в обычном (не от администратора) окне PowerShell:

```powershell
irm https://raw.githubusercontent.com/b3s3da/AppleMusicForW10/main/install.ps1 | iex
```

Эта одна команда:

1. Получает текущую версию Apple Music и прямую ссылку на CDN напрямую с
   серверов доставки пакетов Microsoft (`fe3.delivery.mp.microsoft.com`),
   тем же публичным протоколом, которым пользуются `winget` и клиент
   Store. `AppleMusic.msixbundle` никогда не хранится в этом репозитории и
   не скачивается ниоткуда, кроме серверов Microsoft.
2. Скачивает его во временную папку.
3. Патчит манифест и `AMP.Utils.dll` (подробности ниже).
4. Устанавливает в `%LOCALAPPDATA%\Programs\AppleMusic` и регистрирует
   пакет.

Чтобы настроить запуск, сначала скачайте скрипт:

```powershell
irm https://raw.githubusercontent.com/b3s3da/AppleMusicForW10/main/install.ps1 -OutFile install.ps1
.\install.ps1 -Launch                      # также запустить приложение после установки
.\install.ps1 -Dest "D:\Apps\AppleMusic"   # установить в другое место
.\install.ps1 -KeepDownload                # оставить скачанные/пропатченные файлы для проверки
```

**Повторный запуск этого скрипта позже, чтобы подхватить обновление Apple
Music, безопасен и сохраняет ваши данные.** Имя семейства пакета
(`AppleInc.AppleMusicW10`) не меняется между запусками, поэтому
перерегистрация — это обычное обновление на месте, а не переустановка:
вход в Apple ID, локальный кеш библиотеки и настройки эквалайзера не
затрагиваются. Подробности — в разделе
[Почему обновления не сбрасывают вход](#почему-обновления-не-сбрасывают-вход)
ниже.

### Альтернатива: CLI на Go или скрипт на Python, для уже скачанного `.msixbundle`

Если вы предпочитаете сами скачать `AppleMusic.msixbundle` (например через
приложение Microsoft Store или инструмент для сайдлоада, такой как
[store.rg-adguard.net](https://store.rg-adguard.net/)) и пропатчить именно
этот файл, а не дать скрипту скачать последнюю версию самому — используйте
CLI на Go или скрипт на Python:

```powershell
# CLI на Go — автоматически находит AppleMusic.msixbundle рядом с exe,
# устанавливает в %LOCALAPPDATA%\Programs\AppleMusic и запускает.
.\applemusic-patcher.exe -launch

# Либо укажите всё явно:
.\applemusic-patcher.exe -source "C:\Downloads\AppleMusic.msixbundle" `
                          -dest   "C:\Users\you\AppData\Local\Programs\AppleMusic" `
                          -launch
```

Флаги:

| Флаг | Значение |
|---|---|
| `-source PATH` | `.msixbundle`, `*_x64.msix`, либо уже распакованная папка пакета. По умолчанию: автопоиск рядом с исполняемым файлом. |
| `-dest PATH` | Директория установки. По умолчанию: `%LOCALAPPDATA%\Programs\AppleMusic`. |
| `-in-place` | Патчить и регистрировать прямо внутри `-source`, без копирования. Удобно для повторного патча уже установленной/обновлённой копии. |
| `-launch` | Запустить Apple Music после успешной регистрации. |

Повторный запуск инструмента (например после того, как Apple выпустит
обновление приложения и перезапишет файлы) безопасен: он обнаруживает уже
пропатченные файлы и пропускает их без порчи данных, и — как и
`install.ps1` — никогда не удаляет существующую регистрацию
переименованного семейства пакета.

#### Сборка CLI на Go из исходников

Требуется Go 1.21+.

```powershell
git clone https://github.com/b3s3da/AppleMusicForW10.git
cd AppleMusicForW10
go build -o applemusic-patcher.exe ./cmd/applemusic-patcher
```

#### Эталонная версия на Python

`scripts/patch_apple_music.py` реализует идентичную логику на чистом
Python 3 (только стандартная библиотека — `pip install` не требуется):

```powershell
python scripts\patch_apple_music.py -s "C:\Downloads\AppleMusic.msixbundle" --launch
```

## Почему обновления не сбрасывают вход

При первом запуске на машине, где когда-либо был зарегистрирован или хотя
бы пытался зарегистрироваться *оригинальный*, непропатченный пакет Apple
(`AppleInc.AppleMusicWin`), эта регистрация удаляется. Это единоразовое
удаление необходимо: запись этого имени пакета в базе `StateRepository`
Windows навсегда сломана на затронутой машине (см.
[`docs/root-cause-analysis.md`](docs/root-cause-analysis.md)), и ничто
кроме удаления не позволяет переименованному пакету зарегистрироваться
чисто.

Каждый следующий запуск работает только с переименованным семейством
пакета (`AppleInc.AppleMusicW10`) и никогда не удаляет его существующую
регистрацию перед установкой — `Add-AppxPackage -Register` вызывается
прямо поверх неё. Это то же самое, что Windows делает при обычном
обновлении приложения на месте: папка данных пакета для текущего
пользователя
(`%LOCALAPPDATA%\Packages\AppleInc.AppleMusicW10_nzyj5cx40ttqa\`), где
хранится токен входа в Apple ID, локальный кеш библиотеки и настройки
эквалайзера, не затрагивается. Мы проверили это напрямую: содержимое и
временные метки `LocalState`, `LocalCache\Roaming\Apple
Computer\Preferences` (включая `com.apple.Music.eq.plist`) и
`Settings\settings.dat` не изменились после повторного запуска установщика
для "обновления" уже установленной копии до той же или более новой
версии.

## Как работает патч, подробно

1. **Распаковка.** `AppleMusic.msixbundle` — это ZIP-архив с одним `.msix` на
   каждую архитектуру (`x64`, `arm64`). Инструмент находит `x64`-версию и
   распаковывает её напрямую — никакие промежуточные файлы для самого
   бандла на диск не пишутся.
2. **Удаление метаданных подписи.** Удаляются `AppxSignature.p7x`,
   `AppxBlockMap.xml`, `[Content_Types].xml` и
   `AppxMetadata\CodeIntegrity.cat`. Они описывают *оригинальное,
   непропатченное* содержимое файлов; после изменения любого бинарника
   внутри пакета Windows иначе откажется его загружать как повреждённый.
3. **Патч `AppxManifest.xml`.**
   - `MinVersion="10.0.26100.0"` → `MinVersion="10.0.19044.0"`.
   - `<Identity Name="AppleInc.AppleMusicWin">` → `Name="AppleInc.AppleMusicW10"`
     (та же длина, 22 символа — нужна, чтобы совпасть со строковым патчем
     ниже, и чтобы избежать неустранимой сломанной записи в
     `StateRepository`, оставшейся от любой предыдущей попытки установки
     под оригинальным именем).
4. **Патч `AMP.Utils.dll`** двумя независимыми, перекрывающими друг друга
   способами, чтобы патч продолжал работать даже если Apple переставит
   порядок функций или заинлайнит их в будущей сборке:
   - **По имени экспорта:** каждый экспорт PE, чьё имя содержит
     `IsMachineWindows11` (`?IsMachineWindows11@SharedUtils@@YA_NXZ` и
     варианты `_22H2_OrNewer`/`_24H2_OrNewer`), перезаписывается в точке
     входа байтами `B0 01 C3` (`mov al, 1; ret`) — безусловно возвращает
     `true`.
   - **По байтовой сигнатуре:** вся секция `.text` сканируется на паттерн
     инструкций x64, общий для этих проверок:
     ```
     48 83 EC 38              sub  rsp, 38h
     48 8D 4C 24 20           lea  rcx, [rsp+20h]
     E8 xx xx xx xx           call GetOSVersion
     81 7C 24 20 xx xx 00 00  cmp  dword ptr [rsp+20h], <номер_сборки>
     0F 93 C0                 setae al
     48 83 C4 38              add  rsp, 38h
     C3                       ret
     ```
     Любое совпадение, где захваченный номер сборки похож на настоящую
     сборку Windows 11 (21996, 22621, 26100, ...), патчится так же, даже
     если функция не экспортирована под узнаваемым именем.
   - **Строка имени пакета:** встроенная в DLL UTF-16LE строка
     `AppleInc.AppleMusicWin` (используется `SharedUtils::IsMusicPackage`,
     `GetMusicAppUserModelId`, `LaunchMusicApp` и др. для проверки identity
     пакета) переписывается в `AppleInc.AppleMusicW10`, чтобы совпадать с
     переименованным `Identity` в манифесте.
5. **Регистрация.** Сломанная регистрация оригинального имени пакета
   удаляется только если она ещё присутствует (единоразовая миграция —
   см. [выше](#почему-обновления-не-сбрасывают-вход)), затем
   `Add-AppxPackage -Register <путь>\AppxManifest.xml` регистрирует
   пропатченный пакет на месте, без обращения в Store, без повторной
   загрузки и без потери уже существующих данных входа/библиотеки при
   повторных запусках.

## Ограничения / чего этот инструмент не делает

- Он не ломает и не обходит DRM, авторизацию Apple ID или проверки подписки
  Apple Music — они не затрагиваются ограничением по версии ОС.
- Он не добавляет поддержку ARM64 на Windows 10 сверх того, что уже
  подразумевает `arm64.msix` в бандле (сейчас инструмент работает только с
  `x64`; PR для `arm64` приветствуются, логика идентична).
- Apple может в будущем обновлении усилить проверки (реальное использование
  API, доступного только в Windows 11, другая сигнатура и т.д.) — на момент
  этого релиза такого инженерного решения в приложении нет; этот инструмент
  патчит то, что реально присутствует сегодня.

## Участие в разработке

Issues и PR приветствуются — особенно подтверждение (или обновление
сигнатур) для других версий пакета. Полные заметки по реверс-инжинирингу —
в [`docs/root-cause-analysis.md`](docs/root-cause-analysis.md), если
хотите проверить или расширить патч для новой сборки.

## Лицензия

MIT. См. [`LICENSE`](LICENSE). Не связано с Apple Inc.
