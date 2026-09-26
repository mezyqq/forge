#!/usr/bin/env bash
# Расшифровка отчёта о вылете Forge: «Forge+0x…» → имя функции по карте символов линкера.
#   ~/forge/tools/symbolicate.sh отчёт.txt [карта.map]
# Карта по умолчанию — ~/forge/releases/Forge-<версия из отчёта>.map.
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)                      # ~/forge
IPAB_HOME=${IPAB_HOME:-$HOME/ios-compiler-for-linux}
report=${1:?укажи файл отчёта}
map=${2:-}
if [ -z "$map" ]; then
	ver=$(grep -m1 -o 'Forge [0-9][0-9.]*' "$report" | cut -d' ' -f2)
	map=$H/releases/Forge-$ver.map
fi
[ -f "$map" ] || { echo "нет карты символов: $map" >&2; exit 1; }
demangle=$IPAB_HOME/toolchains/swift/usr/bin/swift-demangle
[ -x "$demangle" ] || demangle=cat

# смещения из отчёта → адреса в карте (__TEXT начинается с 0x100000000)
offsets=$(grep -o 'Forge+0x[0-9a-f]*' "$report" | sed 's/Forge+//' || true)
[ -n "$offsets" ] || { echo "в отчёте нет строк Forge+0x…"; exit 0; }

# строки символов карты: «0xАДРЕС 0xРАЗМЕР [ n] имя»
awk -v offs="$offsets" '
	BEGIN { n = split(offs, o, "\n") }
	/^0x[0-9A-Fa-f]+[ \t]+0x[0-9A-Fa-f]+[ \t]+\[/ {
		a = strtonum($1); s = strtonum($2)
		name = $0; sub(/^[^]]*\][ \t]*/, "", name)
		for (i = 1; i <= n; i++) {
			addr = strtonum(o[i]) + 4294967296
			if (addr >= a && addr < a + s) { hit[i] = name; hitoff[i] = addr - a }
		}
	}
	END { for (i = 1; i <= n; i++) printf "%s  %s + %d\n", o[i], (i in hit ? hit[i] : "?"), hitoff[i] }
' "$map" | $demangle
