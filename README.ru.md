[English](README.md) · **Русский**

# Forge — IDE для iPhone и iPad

Редактор кода, ИИ-агент, запуск скриптов и GitHub прямо на телефоне. Собирается на Linux через
[ipab](https://github.com/mezyqq/ios-compiler-for-linux) и ставится через LiveContainer / iloader.

## Скриншоты

<p>
  <img src="docs/screenshots/editor.jpg" width="260" alt="Редактор">
  <img src="docs/screenshots/themes.jpg" width="260" alt="Темы">
  <img src="docs/screenshots/settings.jpg" width="260" alt="Настройки">
</p>

## Сборка

```sh
~/ios-compiler-for-linux/ipab build ~/forge            # debug → ~/forge/build/Forge.ipa
~/ios-compiler-for-linux/ipab build ~/forge --release  # версия +1 → ~/forge/releases/Forge-<версия>.ipa
```

Release-сборка сама повышает `VERSION`/`BUILD` в `ipa.conf`, удаляет прошлый релиз и кладёт в `releases/`
новый `.ipa` и карту символов `.map` (для расшифровки отчётов о вылетах). Обновляй приложение в LiveContainer
установкой нового `.ipa` поверх старого — так сохранятся проекты, ключи и токен GitHub.

## Что умеет

- **Проекты** в Documents (видны в «Файлах»): шаблоны Python, JavaScript, веб-сайт, Lua, C и C++ (консоль)
  и iOS-приложения (SwiftUI, Swift, ObjC, игра на ObjC, ObjC++, C). Дерево папок, импорт файлов, поиск по проекту, zip.
- **Редактор**: подсветка ~20 языков, 30 тем (Xcode, GitHub, One, Catppuccin, Tokyo Night, Gruvbox, Rosé Pine, Ayu, Everforest,
  Kanagawa, Night Owl, Tomorrow, Material, Solarized — у каждой светлая и тёмная версия; Dracula, Monokai, Nord, чёрная
  AMOLED, Synthwave и другие), оформление приложения Системное / Светлое / Тёмное (Настройки → Оформление), номера строк, поиск/замена, проверка синтаксиса на лету (Python, JS, Lua, C, JSON). Со встроенным компилятором у файлов C / ObjC / C++ —
  настоящая диагностика clang, автодополнение clang с параметрами-заглушками (⇥ — к следующей) и clang-format
  (учитывается `.clang-format` в корне проекта).
- **Запуск без JIT**: Python (pocketpy), JavaScript (JavaScriptCore), Lua 5.4, C (picoc), живое превью HTML.
  Консоль с вводом и кнопкой «Стоп».
- **Нативный запуск с JIT** (компилятор + включённый для Forge JIT): скрипты `.c`, `.cpp`, `.m` компилируются clang и
  выполняются нативно; iOS-проект можно запустить прямо в Forge без установки (см. ниже).
- **Графика и игры в скриптах:** `import pygame` в Python (свой pygame в Forge: окно, рисование, события, клавиши, мышь,
  Clock, шрифты, картинки, Rect, спрайты — без звука) и Lua в стиле LÖVE (`love.load/update/draw`, `love.graphics…`) или
  низкоуровневый `gfx`. Экран игры — над консолью; касание работает как мышь, экранный пульт даёт стрелки, пробел,
  Enter и Esc. Шаблоны «Игра (Python, pygame)» и «Игра (Lua, LÖVE)».
- **Шрифты редактора** JetBrains Mono, Fira Code, Cascadia Code (и SF Mono, Menlo) с лигатурами для кода (можно выключить);
  **предпросмотр Markdown** для `.md`; **поиск и замена по всему проекту** (регистр, регулярки, предпросмотр); на iPad
  **превью приложения можно пристыковать рядом с редактором**.
- **Пакеты из интернета** (меню проекта → Пакеты): PyPI (чистый Python → `py_modules/`, просто `import`), npm (с
  зависимостями и semver → `node_modules/`, `require('имя')` как в Node), LuaRocks (модули на чистом Lua → `lua_modules/`) и
  каталог C/C++ библиотек из одного файла (stb, cJSON, nlohmann/json, miniaudio… → `vendor/`, `#include "cJSON.h"`).
  Список хранится в `packages.json` («Установить всё» после клона); ИИ умеет ставить пакеты сам (`install_package`).
  Python — это pocketpy, JS — JavaScriptCore, поэтому пакеты с C-расширениями или API Node работать не будут.
- **Сборка .ipa на телефоне**: C, Objective-C, C++ через встроенные clang + lld: список ошибок с переходом к строке,
  установка в LiveContainer одной кнопкой (см. ниже).
- **ИИ-агент** на основе идей opencode: стриминг, инструменты read/edit/write/glob/grep/list/run/build/
  todowrite/webfetch, «прощающая» замена в edit, план задач, защита от зацикливания, диагностика после правок (clang
  для C-кода). Инструмент `build` — агент сам собирает приложение и исправляет ошибки компиляции. Каждый файл,
  который тронул агент, можно посмотреть диффом и оставить или откатить (панель «Изменено файлов» в чате).
  Любые провайдеры: OpenAI-совместимые и Anthropic. Бесплатно и без ключа сразу после установки: Pollinations
  (по умолчанию) и LLM7 (GLM-5.3-Flash, MiniMax-M2.7, Codestral).
- **GitHub** через API (без git): клон, коммит и пуш, получение изменений, ветки, история с диффами,
  pull request'ы, issues, публикация проекта в новый репозиторий. Вход — Personal Access Token.
- **Окно превью**: экран `forge_preview()` («Запустить в Forge») сворачивается в живое окно поверх редактора, его
  можно перетаскивать; есть панель лога (stdout/stderr, NSLog). По желанию (Настройки → Функции, по умолчанию
  выключено): **живая перезагрузка** (сохранил исходник — экран пересобрался), **скриншоты превью для ИИ** (инструмент
  `screenshot`), **голосовой ввод** в чате, **проверка обновлений при запуске**.
- **Картинки в чате**: до 4 фото к сообщению (модель должна понимать изображения).
- **Вкладки** открытых файлов на iPad.
- **Состояние JIT** (Настройки → Нативный код): распознаёт JIT через отладчик (StikDebug, SideStore, LiveContainer) и
  JIT, разрешающий исполняемую память (например, Lara); ручной переключатель для способов, которые Forge не видит.
- **Другие версии и снимки данных** (Настройки → Обновления): установка любого релиза, в том числе откат. Перед каждой
  сменой версии проекты (без `build/`) и настройки упаковываются в снимок LZMA; при возврате на более новую версию Forge
  предлагает восстановить её данные. Снимки можно восстановить, отправить или удалить; перед восстановлением текущее
  состояние сохраняется. Ключи ИИ и аккаунт GitHub лежат в Keychain и не затрагиваются.
- **Обновления** (Настройки → Обновления): проверка GitHub Releases, скачивание нового `.ipa` и, внутри LiveContainer,
  замена Forge на месте (`LCAppInfo.plist` LiveContainer сохраняется — проекты, настройки, ключи и GitHub остаются);
  затем «Перезапустить» → откроется LiveContainer → нажать Forge (LiveContainer переподпишет его при этом запуске).
  Если Forge установлен напрямую (не в LiveContainer), Forge скачивает `.ipa`, чтобы поставить его поверх через iloader
  (файл удаляется при следующем запуске); можно и через отдельно установленный SideStore (`sidestore://install`,
  уведомление потом открывает новую версию). «Установить в LiveContainer» после сборки теперь работает
  и изнутри LiveContainer.
- **Журнал вылетов** (Настройки → Отладка): отчёт с версией, стеком и последними действиями.
- **Язык интерфейса**: английский по умолчанию, русский — Настройки → Язык.

## Структура

```
forge/
  ipa.conf, Info.extra.plist   конфиг ipab (фреймворки, bridging header, карта символов, RELEASES)
  src/                         Swift (UI, агент, GitHub, редактор) + C
    engines/                   интерпретаторы: pocketpy, Lua 5.4.9, picoc (+ патчи под iOS) и прослойка forge_engines.c
    forge_crash.c              обработчик вылетов (сигналы → отчёт)
  res/icon.png, art/icon.svg   иконка и её исходник
  tools/symbolicate.sh         «Forge+0x…» из отчёта → имя функции
  compiler/                    отдельный репо ios-compiler: clang + lld под iOS (в git Forge не входит)
  releases/                    последний релиз .ipa + .map
  THIRD_PARTY.txt              лицензии opencode, pocketpy, Lua, picoc
```

## Отчёт о вылете

Настройки → Отладка → Журнал вылетов → отчёт → «Поделиться». Расшифровать на компьютере:

```sh
~/forge/tools/symbolicate.sh отчёт.txt   # карта берётся из releases/ по версии из отчёта
```

## Компилятор на телефоне

Кнопка 🔨 у iOS-проекта (есть `ipa.conf`) собирает C / Objective-C / C++ приложение в `.ipa` прямо на телефоне:
встроенные clang и lld из [ios-compiler](https://github.com/mezyqq/ios-compiler), урезанный iOS SDK в бандле.
Те же `ipa.conf`, `src/`, `res/`, `Info.plist`, что у ipab; результат — `build/<NAME>.ipa`, дальше «Установить в
LiveContainer» (Forge раздаёт `.ipa` на 127.0.0.1 и открывает `livecontainer://install`), потом «Открыть», или
«Поделиться». Ошибки компиляции — списком под логом, нажатие открывает файл на нужной строке. Сборка инкрементальная;
в меню проекта есть «Собрать релиз» (версия +1). Swift на телефоне не компилируется — такие проекты собираются ipab
на компьютере.

**Запустить в Forge (JIT, без установки)** — меню проекта. Исходники компилируются и линкуются прямо в память Forge
(ORC JIT); нужен включённый для Forge JIT. Если в проекте есть `UIViewController *forge_preview(void)`, её экран
показывается внутри Forge (в шаблонах ObjC и игры она есть); иначе в консоли выполняется `main()`. Классы и селекторы
Objective-C регистрируются, статические конструкторы вызываются; категории, `+load` и исключения C++ там не
поддерживаются.

Чтобы компилятор попал в Forge, его надо собрать рядом (иначе Forge собирается без него):

```sh
git clone https://github.com/mezyqq/ios-compiler ~/forge/compiler
cd ~/forge/compiler && ./build-llvm.sh > build.log 2>&1 && make && make toolchain   # LLVM — часы
```

## Лицензия

Forge распространяется по GNU General Public License v3.0 — см. [LICENSE](LICENSE).
Сторонний код и его лицензии: [THIRD_PARTY.txt](THIRD_PARTY.txt).
