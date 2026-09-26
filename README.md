# Forge — IDE для iPhone и iPad

Редактор кода, ИИ-агент, запуск скриптов и GitHub прямо на телефоне. Собирается на Linux через
[ipab](../ios-compiler-for-linux) и ставится через LiveContainer / iloader.

## Сборка

```sh
~/ios-compiler-for-linux/ipab build ~/forge            # debug → ~/forge/build/Forge.ipa
~/ios-compiler-for-linux/ipab build ~/forge --release  # версия +1 → ~/forge/releases/Forge-<версия>.ipa
```

Release-сборка сама повышает `VERSION`/`BUILD` в `ipa.conf`, удаляет прошлый релиз и кладёт в `releases/`
новый `.ipa` и карту символов `.map` (для расшифровки отчётов о вылетах). Обновляй приложение в LiveContainer
установкой нового `.ipa` поверх старого — так сохранятся проекты, ключи и токен GitHub.

## Что умеет

- **Проекты** в Documents (видны в «Файлах»): шаблоны Python, JavaScript, веб-сайт, Lua, C (консоль) и
  iOS-приложения (SwiftUI, Swift, ObjC, ObjC++, C). Дерево папок, импорт файлов, поиск по проекту, zip.
- **Редактор**: подсветка ~20 языков, темы (Xcode, оранжевая, фиолетовая, розовая, Monokai, Nord, «Матрица»,
  Ocean, Solarized), номера строк, поиск/замена, проверка синтаксиса на лету (Python, JS, Lua, C, JSON).
- **Запуск без JIT**: Python (pocketpy), JavaScript (JavaScriptCore), Lua 5.4, C (picoc), живое превью HTML.
  Консоль с вводом и кнопкой «Стоп».
- **ИИ-агент** на основе идей opencode: стриминг, инструменты read/edit/write/glob/grep/list/run/todowrite/
  webfetch, «прощающая» замена в edit, план задач, защита от зацикливания, диагностика синтаксиса после правок.
  Любые провайдеры: OpenAI-совместимые и Anthropic. По умолчанию — бесплатный Pollinations без ключа;
  лучше всего работает с бесплатным big-pickle из OpenCode Zen (нужен ключ с opencode.ai/auth).
- **GitHub** через API (без git): клон, коммит и пуш, получение изменений, ветки, история с диффами,
  pull request'ы, issues, публикация проекта в новый репозиторий. Вход — Personal Access Token.
- **Журнал вылетов** (Настройки → Отладка): отчёт с версией, стеком и последними действиями.

## Структура

```
forge/
  ipa.conf, Info.extra.plist   конфиг ipab (фреймворки, bridging header, карта символов, RELEASES)
  src/                         Swift (UI, агент, GitHub, редактор) + C
    engines/                   интерпретаторы: pocketpy, Lua 5.4.9, picoc (+ патчи под iOS) и прослойка forge_engines.c
    forge_crash.c              обработчик вылетов (сигналы → отчёт)
  res/icon.png, art/icon.svg   иконка и её исходник
  tools/symbolicate.sh         «Forge+0x…» из отчёта → имя функции
  compiler/                    компилятор для телефона (в работе): сборка clang + lld под iOS
  releases/                    последний релиз .ipa + .map
  THIRD_PARTY.txt              лицензии opencode, pocketpy, Lua, picoc
```

## Отчёт о вылете

Настройки → Отладка → Журнал вылетов → отчёт → «Поделиться». Расшифровать на компьютере:

```sh
~/forge/tools/symbolicate.sh отчёт.txt   # карта берётся из releases/ по версии из отчёта
```

## Компилятор для телефона (в работе)

`compiler/build-llvm.sh` собирает LLVM 22.1.8 (clang + lld, только AArch64) статическими библиотеками под
arm64-apple-ios — долго, в фоне, лог в `compiler/build.log`. Потом компилятор встраивается в Forge: сборка
C / Objective-C / C++ приложений в `.ipa` прямо на телефоне. Swift на телефоне компилироваться не будет.
