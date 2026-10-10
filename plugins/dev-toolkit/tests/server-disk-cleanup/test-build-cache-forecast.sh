#!/usr/bin/env bash
# Тест блока «прогноз для кеша сборки» из skills/server-disk-cleanup/SKILL.md:
# блок извлекается из Markdown и исполняется как есть на фикстурах. Настоящий
# Docker не нужен и не вызывается: в PATH стоит заглушка docker, которая сверяет
# аргументы `docker system df -v --format <шаблон>` и отдаёт фикстуру. Каждый
# вектор гоняется под всеми найденными реализациями awk (gawk, mawk, busybox
# awk); какие нашлись — печатается в итоговой строке.
# Запуск из корня репозитория:
#   bash plugins/dev-toolkit/tests/server-disk-cleanup/test-build-cache-forecast.sh
set -uo pipefail

# BUILD_CACHE_FORECAST — путь к готовому блоку вместо извлечения из SKILL.md
# (для мутационной проверки теста).
_skilldir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../skills/server-disk-cleanup"
_skill="${_skilldir}/SKILL.md"
_pass=0
_fail=0
_root="$(mktemp -d)" || exit 1
trap 'rm -rf "${_root}"' EXIT

# Блок — ```bash, первая строка которого начинается с «# build-cache-forecast»;
# в SKILL.md он стоит внутри пункта списка, с отступом.
_blk="${_root}/forecast.sh"
if [[ -n "${BUILD_CACHE_FORECAST:-}" ]]; then
  cp "${BUILD_CACHE_FORECAST}" "${_blk}"
else
  awk '
    /^ *```bash$/ { blk = 1; first = 1; next }
    /^ *```$/     { if (keep) exit; blk = 0; next }
    blk && first { first = 0; if ($0 ~ /^ *# build-cache-forecast/) keep = 1 }
    keep
  ' "${_skill}" >"${_blk}"
fi
if [[ ! -s "${_blk}" ]]; then
  echo "FAIL: блок build-cache-forecast не найден в ${_skill}"
  exit 1
fi
# «W» в блоке — рабочий каталог скилла. Блок не переписывается: он запускается
# из каталога, в котором есть подкаталог W.
_cwd="${_root}/run"
mkdir -p "${_cwd}/W" "${_root}/ro/W" "${_root}/now"
chmod 555 "${_root}/ro/W"

# Шаблон, с которым блок обязан вызвать `docker system df -v --format`: порядок
# полей шаблона и номера полей в awk — одна пара, заглушка её закрепляет.
export STUB_TEMPLATE='{{range .BuildCache}}{{.ID}}|{{.Parent}}|{{.Shared}}|{{.InUse}}|{{.CacheType}}|{{.Size}}|{{.LastUsedAt}}\n{{end}}'

# Заглушка docker: `buildx version` — по STUB_BUILDX: yes — код 0; no — код 1 и
# сообщение Docker об отсутствующем плагине; broken — код 1 с другим текстом;
# `buildx inspect` печатает драйвер из STUB_DRIVER (пусто — код 1 без вывода);
# `system df` отдаёт STUB_FIXTURE с кодом STUB_DF_RC, только если аргументы —
# ровно `-v --format <шаблон>`. Любой другой вызов — ошибка теста.
mkdir -p "${_root}/stub"
cat >"${_root}/stub/docker" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "buildx version")
    case "${STUB_BUILDX:-yes}" in
      yes) echo "github.com/docker/buildx v0.0.0" ;;
      no)
        echo "docker: unknown command: docker buildx" >&2
        exit 1
        ;;
      old)
        echo "docker: 'buildx' is not a docker command." >&2
        exit 1
        ;;
      *)
        echo "Killed" >&2
        exit 1
        ;;
    esac
    ;;
  "buildx inspect")
    [[ -n "${STUB_DRIVER:-}" ]] || exit 1
    printf 'Name:   default\nDriver: %s\n' "${STUB_DRIVER}"
    ;;
  "system df")
    if [[ $# -ne 5 || "$3" != "-v" || "$4" != "--format" || "$5" != "${STUB_TEMPLATE}" ]]; then
      echo "заглушка docker: не тот вызов system df: $*" >&2
      exit 98
    fi
    cat "${STUB_FIXTURE}"
    exit "${STUB_DF_RC:-0}"
    ;;
  *)
    echo "заглушка docker: неожиданный вызов: $*" >&2
    exit 97
    ;;
esac
EOF
chmod +x "${_root}/stub/docker"

# Реализации awk: каталог с обёрткой `awk` на каждую найденную.
_awks=()
_awk_names=()
for _a in gawk mawk "busybox awk"; do
  command -v "${_a%% *}" >/dev/null 2>&1 || continue
  _dir="${_root}/awk-${_a// /-}"
  mkdir -p "${_dir}"
  printf '#!/bin/sh\nexec %s "$@"\n' "${_a}" >"${_dir}/awk"
  chmod +x "${_dir}/awk"
  _awks+=("${_dir}")
  _awk_names+=("${_a}")
done
if [[ ${#_awks[@]} -eq 0 ]]; then
  _awks=("${_root}/stub") # только системный awk
  _awk_names=("системный awk")
fi

# Заглушки отказов (каталог ставится в PATH раньше остальных через PRE). Путь к
# настоящим утилитам они берут из окружения, а не из своего текста.
#   awk-fail:  поиск строки Driver отдаёт настоящему awk; расчёт печатает одну
#              строку с числом и завершается кодом 3;
#   date-*:    `date +%s` — настоящий; вызов с -u — пусто с кодом 1 либо строка
#              другого формата;
#   date-fixed: `date +%s` — фиксированная эпоха FIXED_NOW, остальное — настоящий;
#   timeout-*: команду не запускают, завершаются кодом 124 либо 127.
export REAL_AWK REAL_DATE
REAL_AWK="$(command -v awk)"
REAL_DATE="$(command -v date)"
mkdir -p "${_root}/awk-fail" "${_root}/date-empty" "${_root}/date-junk" "${_root}/date-fixed" \
  "${_root}/timeout-124" "${_root}/timeout-127"
# shellcheck disable=SC2016  # `$1`, `$@`, `${REAL_…}` — текст заглушек, раскрываются при их запуске
{
  printf '#!/bin/sh\ncase "$*" in *Driver:*) exec "${REAL_AWK}" "$@" ;; esac\n' >"${_root}/awk-fail/awk"
  printf 'echo "прогноз: 500 МБ (записей: 1 из 1; всего в кеше 500 МБ)"\nexit 3\n' >>"${_root}/awk-fail/awk"
  printf '#!/bin/sh\ncase "$1" in -u) exit 1 ;; esac\nexec "${REAL_DATE}" "$@"\n' >"${_root}/date-empty/date"
  printf '#!/bin/sh\ncase "$1" in -u) echo "Sat Oct  3 12:00:00 UTC 2026"; exit 0 ;; esac\nexec "${REAL_DATE}" "$@"\n' >"${_root}/date-junk/date"
  printf '#!/bin/sh\ncase "$1" in +%%s) echo "${FIXED_NOW}"; exit 0 ;; esac\nexec "${REAL_DATE}" "$@"\n' >"${_root}/date-fixed/date"
  printf '#!/bin/sh\nexit 124\n' >"${_root}/timeout-124/timeout"
  printf '#!/bin/sh\nexit 127\n' >"${_root}/timeout-127/timeout"
}
chmod +x "${_root}/awk-fail/awk" "${_root}"/date-*/date "${_root}"/timeout-*/timeout

# Время записей: «старая» — 30 суток назад, «свежая» — час назад; порог блока —
# 168 ч. Граница: на минуту старше и на минуту моложе порога. stamp вызывается
# заново перед вектором границы: блок берёт «сейчас» при каждом запуске.
ts() { date -u -d "@$((_now - $1))" '+%Y-%m-%d %H:%M:%S.123456789 +0000 UTC'; }
stamp() {
  _now="$(date +%s)"
  OLD="$(ts 2592000)"
  FRESH="$(ts 3600)"
  EDGE_OLD="$(ts 604860)"
  EDGE_FRESH="$(ts 604740)"
}
stamp

# rec <id> <родители> <shared> <inuse> <тип> <размер> <last used>
_fx="${_root}/fixture.txt"
rec() { printf '%s|%s|%s|%s|%s|%s|%s\n' "$@" >>"${_fx}"; }
new_fixture() { : >"${_fx}"; }

# run_block <каталог awk>: вывод блока — в _out. Переменные вектора: DRIVER
# (драйвер builder'а), BUILDX (yes|no), DF_RC, CWD (каталог запуска), PRE
# (каталог с подменой date или awk, в PATH раньше остальных), LOC (локаль).
# Пояс запуска — не UTC: потеря `-u` у date в блоке иначе не видна на UTC-машине.
# stderr блока идёт в тот же вывод: постороннее сообщение роняет вектор.
run_block() {
  local _path="${_root}/stub:$1:${PATH}"
  [[ -n "${PRE:-}" ]] && _path="${_root}/stub:${PRE}:$1:${PATH}"
  _out="$(cd "${CWD:-${_cwd}}" && TZ=XXX-3 STUB_DRIVER="${DRIVER-docker}" STUB_BUILDX="${BUILDX:-yes}" \
    STUB_FIXTURE="${_fx}" STUB_DF_RC="${DF_RC:-0}" LC_ALL="${LOC:-C}" LOCPATH="${LOCDIR:-}" \
    PATH="${_path}" bash "${_blk}" 2>&1)"
}
ok() { _pass=$((_pass + 1)); }
bad() { # bad <каталог awk> <имя> <ожидалось>
  _fail=$((_fail + 1))
  printf 'FAIL [%s] %s\n  ожидалось: %s\n  получено:  %s\n' "${1##*/}" "$2" "$3" "${_out}"
}

# check <имя> <первая строка> [<вторая строка> [<третья строка>]]: названные
# строки сверяются точно; вывод — ровно три строки, четвёртой быть не должно.
check() {
  local _name="$1" _dir _i _want _all
  for _dir in "${_awks[@]}"; do
    run_block "${_dir}"
    _all=1
    for _i in 1 2 3; do
      _want="${*:_i+1:1}"
      [[ -z "${_want}" ]] && continue
      [[ "$(sed -n "${_i}p" <<<"${_out}")" == "${_want}" ]] || _all=0
    done
    [[ "$(wc -l <<<"${_out}")" -eq 3 ]] || _all=0
    if [[ ${_all} -eq 1 ]]; then ok; else bad "${_dir}" "${_name}" "${*:2} — ровно три строки"; fi
  done
}
# check_undefined <имя> <слово из причины>: вывод — ровно одна строка «прогноз:
# не определён (…)», и в скобках есть названное слово: вектор не должен
# проходить по соседней проверке.
check_undefined() {
  local _name="$1" _word="$2" _dir
  for _dir in "${_awks[@]}"; do
    run_block "${_dir}"
    if [[ "${_out}" == "прогноз: не определён ("*"${_word}"*")" && "${_out}" != *$'\n'* ]]; then
      ok
    else
      bad "${_dir}" "${_name}" "прогноз: не определён (…${_word}…) — одной строкой"
    fi
  done
}

# --- Три ветви из приёмки -----------------------------------------------------

new_fixture
rec old1 "" false false regular 100MB "${OLD}"
rec new1 "" false false regular 50MB "${FRESH}"
check "старая, необщая, без потомков — входит" \
  "прогноз: 100 МБ (записей: 1 из 2; всего в кеше 150 МБ)" \
  "остаются: свежие 50 МБ; общие с образами 0 МБ; занятые и служебные 0 МБ; предки остающихся 0 МБ" \
  "незанятые записи: необщие 150 МБ, все 150 МБ; в прогнозе записи без времени использования: 0 МБ"

new_fixture
rec base "" false false regular 100MB "${OLD}"
rec mid base false false regular 30MB "${OLD}"
rec top mid false false regular 50MB "${FRESH}"
check "старые предки свежей (через поколение) — не входят" \
  "прогноз: 0 МБ (записей: 0 из 3; всего в кеше 180 МБ)" \
  "остаются: свежие 50 МБ; общие с образами 0 МБ; занятые и служебные 0 МБ; предки остающихся 130 МБ"

new_fixture
rec sh1 "" true false regular 100MB "${OLD}"
rec priv1 "" false false regular 7MB "${FRESH}"
check "старая общая с образом — не входит; необщие считаются отдельно" \
  "прогноз: 0 МБ (записей: 0 из 2; всего в кеше 107 МБ)" \
  "остаются: свежие 7 МБ; общие с образами 100 МБ; занятые и служебные 0 МБ; предки остающихся 0 МБ" \
  "незанятые записи: необщие 7 МБ, все 107 МБ; в прогнозе записи без времени использования: 0 МБ"

# --- Граф ---------------------------------------------------------------------

new_fixture
rec base "" false false regular 100MB "${OLD}"
rec sh1 base true false regular 20MB "${OLD}"
check "старая необщая — предок старой общей — не входит" \
  "прогноз: 0 МБ (записей: 0 из 2; всего в кеше 120 МБ)" \
  "остаются: свежие 0 МБ; общие с образами 20 МБ; занятые и служебные 0 МБ; предки остающихся 100 МБ"

new_fixture
rec base "" false false regular 100MB "${OLD}"
rec leaf base false false regular 50MB "${OLD}"
check "цепочка старых необщих — входит целиком" \
  "прогноз: 150 МБ (записей: 2 из 2; всего в кеше 150 МБ)"

new_fixture
rec a "" false false regular 10MB "${OLD}"
rec b "" false false regular 20MB "${OLD}"
rec c "" false false regular 40MB "${OLD}"
rec merge "a, b" false false regular 1MB "${FRESH}"
check "несколько родителей у свежей — оба остаются, посторонняя входит" \
  "прогноз: 40 МБ (записей: 1 из 4; всего в кеше 71 МБ)"

new_fixture
rec a "" false false regular 10MB "${OLD}"
rec b "" false false regular 20MB "${OLD}"
rec merge "a,b" false false regular 1MB "${FRESH}"
check "родители через запятую без пробела — оба остаются" \
  "прогноз: 0 МБ (записей: 0 из 3; всего в кеше 31 МБ)"

new_fixture
rec a "" false false regular 10MB "${OLD}"
rec b "" false false regular 20MB "${OLD}"
rec merge "a, b" false false regular 1MB "${OLD}"
check "несколько родителей у старой — входит всё" \
  "прогноз: 31 МБ (записей: 3 из 3; всего в кеше 31 МБ)"

new_fixture
rec leaf gone false false regular 50MB "${OLD}"
rec top gone2 false false regular 5MB "${FRESH}"
check "родитель, которого нет в списке, не мешает" \
  "прогноз: 50 МБ (записей: 1 из 2; всего в кеше 55 МБ)"

new_fixture
rec old1 "" false false regular 100MB "${OLD}"
printf '\n' >>"${_fx}"
check "пустая строка в конце вывода пропускается" \
  "прогноз: 100 МБ (записей: 1 из 1; всего в кеше 100 МБ)"

# --- Возраст ------------------------------------------------------------------

# BuildKit запись без времени использования удаляет (фильтр возраста её не
# защищает) и затем снимает освободившихся предков — блок считает так же и
# называет её долю третьей строкой.
new_fixture
rec base "" false false regular 100MB "${OLD}"
rec nodate base false false regular 30MB ""
check "запись без времени использования входит вместе с предком" \
  "прогноз: 130 МБ (записей: 2 из 2; всего в кеше 130 МБ)" \
  "остаются: свежие 0 МБ; общие с образами 0 МБ; занятые и служебные 0 МБ; предки остающихся 0 МБ" \
  "незанятые записи: необщие 130 МБ, все 130 МБ; в прогнозе записи без времени использования: 30 МБ"

new_fixture
rec base "" false false regular 100MB "${OLD}"
rec nodate base true false regular 30MB ""
check "общая запись без времени использования остаётся и держит предка" \
  "прогноз: 0 МБ (записей: 0 из 2; всего в кеше 130 МБ)" \
  "остаются: свежие 0 МБ; общие с образами 30 МБ; занятые и служебные 0 МБ; предки остающихся 100 МБ" \
  "незанятые записи: необщие 100 МБ, все 130 МБ; в прогнозе записи без времени использования: 0 МБ"

# Слой идущей сборки: занят и ещё без времени использования — остаётся и держит
# старых предков; в «незанятые» не входит.
new_fixture
rec base "" false false regular 100MB "${OLD}"
rec busy base false true regular 30MB ""
check "занятая запись без времени использования остаётся и держит предка" \
  "прогноз: 0 МБ (записей: 0 из 2; всего в кеше 130 МБ)" \
  "остаются: свежие 0 МБ; общие с образами 0 МБ; занятые и служебные 30 МБ; предки остающихся 100 МБ" \
  "незанятые записи: необщие 100 МБ, все 100 МБ; в прогнозе записи без времени использования: 0 МБ"

new_fixture
rec fs "" true false regular 10MB "${FRESH}"
rec fb "" false true regular 20MB "${FRESH}"
check "свежая запись остаётся «свежей», даже если она общая или занятая" \
  "прогноз: 0 МБ (записей: 0 из 2; всего в кеше 30 МБ)" \
  "остаются: свежие 30 МБ; общие с образами 0 МБ; занятые и служебные 0 МБ; предки остающихся 0 МБ" \
  "незанятые записи: необщие 0 МБ, все 10 МБ; в прогнозе записи без времени использования: 0 МБ"

# Точная граница: «сейчас» блока зафиксировано заглушкой date, секунды границы —
# :30. Запись ровно на границе и на 10 с моложе — свежие, на секунду старше — нет.
export FIXED_NOW=1800000030
_cut_epoch=$((FIXED_NOW - 604800))
tsx() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%S.000000001 +0000 UTC'; }
new_fixture
rec at "" false false regular 10MB "$(tsx "${_cut_epoch}")"
rec plus10 "" false false regular 20MB "$(tsx "$((_cut_epoch + 10))")"
rec minus1 "" false false regular 40MB "$(tsx "$((_cut_epoch - 1))")"
PRE="${_root}/date-fixed" check "граница до секунды: ровно на границе и +10 с — свежие, −1 с — старая" \
  "прогноз: 40 МБ (записей: 1 из 3; всего в кеше 70 МБ)"

stamp
new_fixture
rec e1 "" false false regular 100MB "${EDGE_OLD}"
rec e2 "" false false regular 30MB "${EDGE_FRESH}"
check "граница 168 ч: на минуту старше — входит, на минуту моложе — нет" \
  "прогноз: 100 МБ (записей: 1 из 2; всего в кеше 130 МБ)"

# --- Признаки записи ----------------------------------------------------------

new_fixture
rec 'busy*' "" false true regular 10MB "${OLD}"
rec int "" false false internal 20MB "${OLD}"
rec fe "" false false frontend 40MB "${OLD}"
rec mnt "" false false exec.cachemount 80MB "${OLD}"
rec src "" false false source.local 160MB "${OLD}"
check "занятая (ID со звёздочкой), internal и frontend остаются; cachemount и source.local входят" \
  "прогноз: 240 МБ (записей: 2 из 5; всего в кеше 310 МБ)" \
  "остаются: свежие 0 МБ; общие с образами 0 МБ; занятые и служебные 70 МБ; предки остающихся 0 МБ" \
  "незанятые записи: необщие 300 МБ, все 300 МБ; в прогнозе записи без времени использования: 0 МБ"

new_fixture
rec odd1 "" "<no value>" false regular 100MB "${OLD}"
rec odd2 "" false "<no value>" regular 50MB "${OLD}"
check "признаки Shared и InUse не из true/false — запись остаётся" \
  "прогноз: 0 МБ (записей: 0 из 2; всего в кеше 150 МБ)" \
  "остаются: свежие 0 МБ; общие с образами 100 МБ; занятые и служебные 50 МБ; предки остающихся 0 МБ"

# --- Единицы размера (десятичные, как печатает Docker) ------------------------

new_fixture
rec u1 "" false false regular 500000B "${OLD}"
rec u2 "" false false regular 500kB "${OLD}"
rec u3 "" false false regular 2MB "${OLD}"
rec u4 "" false false regular 1.5GB "${OLD}"
rec u5 "" false false regular 1e+03kB "${OLD}"
rec u6 "" false false regular 0B "${OLD}"
check "единицы kB, MB, GB и запись вида 1e+03kB" \
  "прогноз: 1504 МБ (записей: 6 из 6; всего в кеше 1504 МБ)"

new_fixture
rec b1 "" false false regular 2e+06B "${OLD}"
check "единица B" \
  "прогноз: 2 МБ (записей: 1 из 1; всего в кеше 2 МБ)"

new_fixture
rec t1 "" false false regular 1.2TB "${OLD}"
check "единица TB" \
  "прогноз: 1200000 МБ (записей: 1 из 1; всего в кеше 1200000 МБ)"

new_fixture
check "пустой кеш — прогноз 0" \
  "прогноз: 0 МБ (записей: 0 из 0; всего в кеше 0 МБ)"

# Локаль с десятичной запятой: mawk без LC_ALL=C читает «1.5GB» как 1 (gawk и
# busybox awk — нет, поэтому вектору нужен mawk). Локаль собирается во временный
# каталог. Нет mawk или localedef не собрал локаль — это падение: без вектора
# потеря LC_ALL=C пройдёт незамеченной. Осознанный пропуск — SKIP_LOCALE_VECTOR=1.
_notes=""
mkdir -p "${_root}/loc"
if [[ "${SKIP_LOCALE_VECTOR:-}" == 1 ]]; then
  _notes+="; вектор локали пропущен (SKIP_LOCALE_VECTOR=1)"
elif ! command -v mawk >/dev/null 2>&1; then
  _fail=$((_fail + 1))
  echo "FAIL вектор локали: нет mawk (осознанный пропуск — SKIP_LOCALE_VECTOR=1)"
elif ! localedef -i ru_RU -f UTF-8 "${_root}/loc/ru_RU.UTF-8" >/dev/null 2>&1; then
  _fail=$((_fail + 1))
  echo "FAIL вектор локали: localedef не собрал ru_RU.UTF-8 (осознанный пропуск — SKIP_LOCALE_VECTOR=1)"
else
  new_fixture
  rec u4 "" false false regular 1.5GB "${OLD}"
  LOC=ru_RU.UTF-8 LOCDIR="${_root}/loc" check "локаль с десятичной запятой не меняет разбор размера" \
    "прогноз: 1500 МБ (записей: 1 из 1; всего в кеше 1500 МБ)"
fi

# --- «Не определён» -----------------------------------------------------------

new_fixture
rec old1 "" false false regular 100MB "${OLD}"
DRIVER=docker-container check_undefined "текущий builder не с драйвером docker" "docker-container"
DRIVER="" check_undefined "buildx есть, а inspect не назвал драйвер" "не назвал драйвер"
BUILDX=broken check_undefined "docker buildx version упал не из-за отсутствия плагина" "не назвал драйвер"
PRE="${_root}/timeout-127" check_undefined "нет утилиты timeout" "не назвал драйвер"
DF_RC=1 check_undefined "docker system df завершился с ошибкой" "завершился с кодом 1"
CWD="${_root}/now" check_undefined "каталога W нет" "W недоступен"
if [[ "$(id -u)" -ne 0 ]]; then
  CWD="${_root}/ro" check_undefined "каталог W только для чтения" "W недоступен"
else
  _notes+="; вектор «W только для чтения» пропущен — запуск под root"
fi
PRE="${_root}/awk-fail" check_undefined "awk напечатал строку с числом и упал — число не выводится" "awk не отработал"
PRE="${_root}/date-empty" check_undefined "date не посчитал границу" "date не посчитал"
PRE="${_root}/date-junk" check_undefined "date вернул строку другого формата" "граница возраста не разобрана"
BUILDX=no DRIVER="" check "buildx нет (unknown command) — считается по кешу демона" \
  "прогноз: 100 МБ (записей: 1 из 1; всего в кеше 100 МБ)"
BUILDX=old DRIVER="" check "buildx нет (is not a docker command) — считается по кешу демона" \
  "прогноз: 100 МБ (записей: 1 из 1; всего в кеше 100 МБ)"

# timeout у каждого из трёх вызовов Docker: заглушка timeout возвращает 124 для
# одного названного вызова, не запуская его, остальные исполняет как есть. Блок
# без timeout у этого вызова заглушку не заденет и напечатает число.
# timeout_only <имя каталога> <подстрока командной строки>
timeout_only() {
  mkdir -p "${_root}/$1"
  # shellcheck disable=SC2016  # `$*`, `$@` — текст заглушки
  printf '#!/bin/sh\ncase "$*" in *"%s"*) exit 124 ;; esac\nshift\nexec "$@"\n' "$2" >"${_root}/$1/timeout"
  chmod +x "${_root}/$1/timeout"
}
timeout_only tmo-df "system df"
timeout_only tmo-inspect "buildx inspect"
timeout_only tmo-version "buildx version"
new_fixture
rec old1 "" false false regular 100MB "${OLD}"
PRE="${_root}/tmo-df" check_undefined "docker system df не уложился в таймаут" "не отработал за 60 с"
PRE="${_root}/tmo-inspect" check_undefined "docker buildx inspect не уложился в таймаут" "не назвал драйвер"
PRE="${_root}/tmo-version" check_undefined "docker buildx version не уложился в таймаут" "не назвал драйвер"
PRE="${_root}/timeout-124" check_undefined "все вызовы Docker не уложились в таймаут" "не назвал драйвер"

new_fixture
rec old1 "" false false regular 100MB "${OLD/+0000 UTC/+0300 MSK}"
check_undefined "время не в UTC" "время не в UTC"

new_fixture
rec old1 "" false false regular 100MB "3 weeks ago +0000 UTC"
check_undefined "не дата с суффиксом UTC" "время не в UTC"

new_fixture
rec old1 "" false false regular 12XB "${OLD}"
check_undefined "неизвестная единица размера" "размер не разобран"

new_fixture
rec old1 "" false false regular MB "${OLD}"
check_undefined "размер без числа" "размер не разобран"

new_fixture
printf 'old1||false|false|regular|100MB\n' >>"${_fx}"
check_undefined "в строке шесть полей" "не 7 полей"

new_fixture
printf 'old1||false|false|regular|100MB|%s|лишнее\n' "${OLD}" >>"${_fx}"
check_undefined "в строке восемь полей" "не 7 полей"

new_fixture
rec "" "" false false regular 100MB "${OLD}"
check_undefined "пустой ID" "пустой или повторный ID"

new_fixture
rec old1 "" false false regular 100MB "${OLD}"
rec old1 "" false false regular 100MB "${OLD}"
check_undefined "повторный ID" "пустой или повторный ID"

new_fixture
rec good "" false false regular 100MB "${OLD}"
rec bad "" false false regular 12XB "${OLD}"
rec good2 "" false false regular 100MB "${OLD}"
check_undefined "одна плохая строка среди хороших" "размер не разобран"

# --- Порог блока и порог в тексте команды -------------------------------------

# T в блоке и `until=<N>h` в SKILL.md и справочнике — одна величина: прогноз для
# одного возраста при команде с другим дал бы «обещано N, возвращено 0B».
_t="$(sed -n 's/^ *T=\([0-9][0-9]*\).*/\1/p' "${_blk}" | head -1)"
_want_until="until=$((${_t:-0} / 3600))h"
_untils="$(grep -oh 'until=[0-9][0-9]*h' "${_skill}" "${_skilldir}/references/caches.md" | sort -u | tr '\n' ' ')"
if [[ -n "${_t}" && "${_untils}" == "${_want_until} " ]]; then
  ok
else
  _fail=$((_fail + 1))
  printf 'FAIL порог: T=%s в блоке требует «%s», в тексте: %s\n' "${_t:-<нет>}" "${_want_until}" "${_untils:-<нет>}"
fi

echo "pass=${_pass} fail=${_fail} (awk: ${_awk_names[*]}${_notes})"
[[ ${_fail} -eq 0 ]]
