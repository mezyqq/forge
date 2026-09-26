**English** · [Русский](README.ru.md)

# Forge — an IDE for iPhone and iPad

A code editor, an AI agent, script runners and GitHub right on your phone. Built on Linux with
[ipab](https://github.com/mezyqq/ios-compiler-for-linux) and installed through LiveContainer / iloader.

## Building

```sh
~/ios-compiler-for-linux/ipab build ~/forge            # debug → ~/forge/build/Forge.ipa
~/ios-compiler-for-linux/ipab build ~/forge --release  # version +1 → ~/forge/releases/Forge-<version>.ipa
```

A release build bumps `VERSION`/`BUILD` in `ipa.conf`, removes the previous release and puts the new `.ipa` and the
`.map` symbol map (for decoding crash reports) into `releases/`. Update the app in LiveContainer by installing the new
`.ipa` over the old one — projects, keys and the GitHub token are kept.

## Features

- **Projects** in Documents (visible in the Files app): templates for Python, JavaScript, website, Lua, C (console)
  and iOS apps (SwiftUI, Swift, ObjC, ObjC++, C). Folder tree, file import, project-wide search, zip.
- **Editor**: highlighting for ~20 languages, themes (Xcode, orange, purple, pink, Monokai, Nord, Matrix, Ocean,
  Solarized), line numbers, find/replace, live syntax checking (Python, JS, Lua, C, JSON).
- **Running without JIT**: Python (pocketpy), JavaScript (JavaScriptCore), Lua 5.4, C (picoc), live HTML preview.
  A console with input and a Stop button.
- **Building .ipa on the phone**: C, Objective-C, C++ with the built-in clang + lld (see below).
- **AI agent** based on opencode's ideas: streaming, read/edit/write/glob/grep/list/run/todowrite/webfetch tools,
  forgiving replacement in edit, a task plan, loop protection, syntax diagnostics after edits.
  Any provider: OpenAI-compatible and Anthropic. The default is the free Pollinations without a key;
  it works best with the free big-pickle from OpenCode Zen (needs a key from opencode.ai/auth).
- **GitHub** over the API (no git): clone, commit and push, pull changes, branches, history with diffs,
  pull requests, issues, publishing a project to a new repository. Sign-in with a Personal Access Token.
- **Crash log** (Settings → Debugging): a report with the version, stack and recent actions.
- **Interface language**: English by default, Russian in Settings → Language.

## Layout

```
forge/
  ipa.conf, Info.extra.plist   ipab config (frameworks, bridging header, symbol map, RELEASES)
  src/                         Swift (UI, agent, GitHub, editor) + C
    engines/                   interpreters: pocketpy, Lua 5.4.9, picoc (+ iOS patches) and the forge_engines.c glue
    forge_crash.c              crash handler (signals → report)
  res/icon.png, art/icon.svg   the icon and its source
  tools/symbolicate.sh         "Forge+0x…" from a report → function name
  compiler/                    separate repo ios-compiler: clang + lld for iOS (not part of Forge's git)
  releases/                    the latest release .ipa + .map
  THIRD_PARTY.txt              licenses of opencode, pocketpy, Lua, picoc
```

## Crash reports

Settings → Debugging → Crash log → report → Share. Decode it on the computer:

```sh
~/forge/tools/symbolicate.sh report.txt   # the map is taken from releases/ by the version in the report
```

## Compiler on the phone

The 🔨 button of an iOS project (one with `ipa.conf`) builds a C / Objective-C / C++ app into an `.ipa` right on the
phone: the built-in clang and lld from [ios-compiler](https://github.com/mezyqq/ios-compiler), with a trimmed iOS SDK
inside the bundle. Same `ipa.conf`, `src/`, `res/`, `Info.plist` as ipab; the result is `build/<NAME>.ipa`, then
Share → LiveContainer. Builds are incremental; the project menu has "Build release" (version +1). Swift is not compiled
on the phone — build such projects with ipab on a computer.

For the compiler to be included in Forge, build it next to it (otherwise Forge is built without it):

```sh
git clone https://github.com/mezyqq/ios-compiler ~/forge/compiler
cd ~/forge/compiler && ./build-llvm.sh > build.log 2>&1 && make && make toolchain   # LLVM takes hours
```
