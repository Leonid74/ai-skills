#!/usr/bin/env bash
# Тест блока «прогноз для кеша сборки» из skills/server-disk-cleanup/SKILL.md:
# блок извлекается из Markdown и исполняется на фикстурах. Настоящий Docker не
# нужен и не вызывается: в PATH стоит заглушка docker, которая отдаёт фикстуру
# вместо `docker system df -v --format …`. Каждый вектор гоняется под всеми
# найденными реализациями awk (gawk, mawk, busybox awk).
# Запуск из корня репозитория:
#   bash plugins/dev-toolkit/tests/server-disk-cleanup/test-build-cache-forecast.sh
set -uo pipefail

# BUILD_CACHE_FORECAST — путь к готовому блоку вместо извлечения из SKILL.md
# (для мутационной проверки теста).
_skill="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../skills/server-disk-cleanup/SKILL.md"
_pass=0
_fail=0
_root="$(mktemp -d)"
trap 'rm -rf "${_root}"' EXIT

# Блок — ```bash, первая строка которого начинается с «# build-cache-forecast»;
# в SKILL.md он стоит внутри пункта списка, с отступом.
_blk="${_root}/forecast.sh"
if [[ -n "${BUILD_CACHE_FORECAST:-}" ]]; then
  cp "${BUILD_CACHE_FORECAST}" "${_blk}.src"
else
  awk '
    /^ *```bash$/ { blk = 1; first = 1; next }
    /^ *```$/     { if (keep) exit; blk = 0; next }
    blk && first { first = 0; if ($0 ~ /^ *# build-cache-forecast/) keep = 1 }
    keep
  ' "${_skill}" >"${_blk}.src"
fi
if [[ ! -s "${_blk}.src" ]]; then
  echo "FAIL: блок build-cache-forecast не найден в ${_skill}"
  exit 1
fi
# «W» в блоке — рабочий каталог скилла; подставляется абсолютный путь.
sed "s|W/|${_root}/w/|g" "${_blk}.src" >"${_blk}"
mkdir -p "${_root}/w"

# Заглушка docker: `buildx inspect` печатает драйвер из STUB_DRIVER (пусто —
# buildx нет, код 1), `system df` отдаёт файл STUB_FIXTURE с кодом STUB_DF_RC.
# Любой другой вызов — ошибка теста: блок не должен звать ничего больше.
mkdir -p "${_root}/stub"
cat >"${_root}/stub/docker" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "buildx inspect")
    [[ -n "${STUB_DRIVER:-}" ]] || exit 1
    printf 'Name:   default\nDriver: %s\n' "${STUB_DRIVER}"
    ;;
  "system df")
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
for _a in gawk mawk "busybox awk"; do
  command -v "${_a%% *}" >/dev/null 2>&1 || continue
  _dir="${_root}/awk-${_a// /-}"
  mkdir -p "${_dir}"
  printf '#!/bin/sh\nexec %s "$@"\n' "${_a}" >"${_dir}/awk"
  chmod +x "${_dir}/awk"
  _awks+=("${_dir}")
done
if [[ ${#_awks[@]} -eq 0 ]]; then
  _awks=("${_root}/stub") # только системный awk
fi

# Время записей: «старая» — 30 суток назад, «свежая» — час назад; порог блока —
# 168 ч. Граница: на минуту старше и на минуту моложе порога.
_now="$(date +%s)"
ts() { date -u -d "@$((_now - $1))" '+%Y-%m-%d %H:%M:%S.123456789 +0000 UTC'; }
OLD="$(ts 2592000)"
FRESH="$(ts 3600)"
EDGE_OLD="$(ts 604860)"
EDGE_FRESH="$(ts 604740)"

# rec <id> <родители> <shared> <inuse> <тип> <размер> <last used>
_fx="${_root}/fixture.txt"
rec() { printf '%s|%s|%s|%s|%s|%s|%s\n' "$@" >>"${_fx}"; }
new_fixture() { : >"${_fx}"; }

# check <имя> <ожидаемая первая строка> [<ожидаемая вторая строка>]
# Драйвер и код возврата `system df` — переменными DRIVER и DF_RC.
check() {
  local _name="$1" _want1="$2" _want2="${3:-}" _dir _out _got1 _got2
  for _dir in "${_awks[@]}"; do
    _out="$(STUB_DRIVER="${DRIVER-docker}" STUB_FIXTURE="${_fx}" STUB_DF_RC="${DF_RC:-0}" \
      PATH="${_root}/stub:${_dir}:${PATH}" bash "${_blk}" 2>&1)"
    _got1="$(sed -n 1p <<<"${_out}")"
    _got2="$(sed -n 2p <<<"${_out}")"
    if [[ "${_got1}" == "${_want1}" && (-z "${_want2}" || "${_got2}" == "${_want2}") ]]; then
      _pass=$((_pass + 1))
    else
      _fail=$((_fail + 1))
      printf 'FAIL [%s] %s\n  ожидалось: %s\n' "${_dir##*/}" "${_name}" "${_want1}"
      [[ -n "${_want2}" ]] && printf '             %s\n' "${_want2}"
      printf '  получено:  %s\n' "${_out}"
    fi
  done
}
# check_undefined <имя> — вывод ровно одной строкой «прогноз: не определён (…)»:
# причина в скобках — пояснение, тест закрепляет только сам вердикт.
check_undefined() {
  local _name="$1" _dir _out
  for _dir in "${_awks[@]}"; do
    _out="$(STUB_DRIVER="${DRIVER-docker}" STUB_FIXTURE="${_fx}" STUB_DF_RC="${DF_RC:-0}" \
      PATH="${_root}/stub:${_dir}:${PATH}" bash "${_blk}" 2>&1)"
    if [[ "${_out}" == "прогноз: не определён ("*")" ]]; then
      _pass=$((_pass + 1))
    else
      _fail=$((_fail + 1))
      printf 'FAIL [%s] %s\n  ожидалось: прогноз: не определён (…) — одной строкой\n  получено:  %s\n' \
        "${_dir##*/}" "${_name}" "${_out}"
    fi
  done
}

# --- Три ветви из приёмки -----------------------------------------------------

new_fixture
rec old1 "" false false regular 100MB "${OLD}"
rec new1 "" false false regular 50MB "${FRESH}"
check "старая, необщая, без потомков — входит" \
  "прогноз: 100 МБ (записей: 1 из 2; всего в кеше 150 МБ)" \
  "остаются: свежие и без даты 50 МБ; общие с образами 0 МБ; занятые и служебные 0 МБ; предки остающихся 0 МБ"

new_fixture
rec base "" false false regular 100MB "${OLD}"
rec mid base false false regular 30MB "${OLD}"
rec top mid false false regular 50MB "${FRESH}"
check "старые предки свежей (через поколение) — не входят" \
  "прогноз: 0 МБ (записей: 0 из 3; всего в кеше 180 МБ)" \
  "остаются: свежие и без даты 50 МБ; общие с образами 0 МБ; занятые и служебные 0 МБ; предки остающихся 130 МБ"

new_fixture
rec sh1 "" true false regular 100MB "${OLD}"
check "старая общая с образом — не входит" \
  "прогноз: 0 МБ (записей: 0 из 1; всего в кеше 100 МБ)" \
  "остаются: свежие и без даты 0 МБ; общие с образами 100 МБ; занятые и служебные 0 МБ; предки остающихся 0 МБ"

# --- Граф ---------------------------------------------------------------------

new_fixture
rec base "" false false regular 100MB "${OLD}"
rec sh1 base true false regular 20MB "${OLD}"
check "старая необщая — предок старой общей — не входит" \
  "прогноз: 0 МБ (записей: 0 из 2; всего в кеше 120 МБ)" \
  "остаются: свежие и без даты 0 МБ; общие с образами 20 МБ; занятые и служебные 0 МБ; предки остающихся 100 МБ"

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
rec merge "a, b" false false regular 1MB "${OLD}"
check "несколько родителей у старой — входит всё" \
  "прогноз: 31 МБ (записей: 3 из 3; всего в кеше 31 МБ)"

new_fixture
rec leaf gone false false regular 50MB "${OLD}"
rec top gone2 false false regular 5MB "${FRESH}"
check "родитель, которого нет в списке, не мешает" \
  "прогноз: 50 МБ (записей: 1 из 2; всего в кеше 55 МБ)"

# --- Возраст ------------------------------------------------------------------

new_fixture
rec base "" false false regular 100MB "${OLD}"
rec nodate base false false regular 30MB ""
check "запись без времени использования — свежая, предок остаётся" \
  "прогноз: 0 МБ (записей: 0 из 2; всего в кеше 130 МБ)" \
  "остаются: свежие и без даты 30 МБ; общие с образами 0 МБ; занятые и служебные 0 МБ; предки остающихся 100 МБ"

new_fixture
rec e1 "" false false regular 100MB "${EDGE_OLD}"
rec e2 "" false false regular 30MB "${EDGE_FRESH}"
check "граница 168 ч: на минуту старше — входит, на минуту моложе — нет" \
  "прогноз: 100 МБ (записей: 1 из 2; всего в кеше 130 МБ)"

# --- Признаки записи ----------------------------------------------------------

new_fixture
rec busy "" false true regular 10MB "${OLD}"
rec int "" false false internal 20MB "${OLD}"
rec fe "" false false frontend 40MB "${OLD}"
rec mnt "" false false exec.cachemount 80MB "${OLD}"
rec src "" false false source.local 160MB "${OLD}"
check "занятая, internal и frontend остаются; cachemount и source.local входят" \
  "прогноз: 240 МБ (записей: 2 из 5; всего в кеше 310 МБ)" \
  "остаются: свежие и без даты 0 МБ; общие с образами 0 МБ; занятые и служебные 70 МБ; предки остающихся 0 МБ"

# --- Единицы размера (десятичные, как печатает Docker) ------------------------

new_fixture
rec u1 "" false false regular 500000B "${OLD}"
rec u2 "" false false regular 500kB "${OLD}"
rec u3 "" false false regular 2MB "${OLD}"
rec u4 "" false false regular 1.5GB "${OLD}"
rec u5 "" false false regular 1e+03kB "${OLD}"
rec u6 "" false false regular 0B "${OLD}"
check "единицы B, kB, MB, GB и запись вида 1e+03kB" \
  "прогноз: 1504 МБ (записей: 6 из 6; всего в кеше 1504 МБ)"

new_fixture
check "пустой кеш — прогноз 0" \
  "прогноз: 0 МБ (записей: 0 из 0; всего в кеше 0 МБ)"

# --- «Не определён» -----------------------------------------------------------

new_fixture
rec old1 "" false false regular 100MB "${OLD}"
DRIVER=docker-container check_undefined "текущий builder не с драйвером docker"
DF_RC=1 check_undefined "docker system df завершился с ошибкой"
DRIVER="" check "buildx нет — считается по кешу демона" \
  "прогноз: 100 МБ (записей: 1 из 1; всего в кеше 100 МБ)"

new_fixture
rec old1 "" false false regular 100MB "${OLD/+0000 UTC/+0300 MSK}"
check_undefined "время не в UTC"

new_fixture
rec old1 "" false false regular 100MB "3 weeks ago"
check_undefined "время относительным текстом"

new_fixture
rec old1 "" false false regular 12XB "${OLD}"
check_undefined "неизвестная единица размера"

new_fixture
rec old1 "" false false regular "" "${OLD}"
check_undefined "пустой размер"

new_fixture
printf 'old1||false|false|regular|100MB\n' >>"${_fx}"
check_undefined "в строке не семь полей"

new_fixture
rec old1 "" false false regular 100MB "${OLD}"
rec old1 "" false false regular 100MB "${OLD}"
check_undefined "повторный ID"

new_fixture
rec good "" false false regular 100MB "${OLD}"
rec bad "" false false regular 12XB "${OLD}"
rec good2 "" false false regular 100MB "${OLD}"
check_undefined "одна плохая строка среди хороших"

echo "pass=${_pass} fail=${_fail} (реализаций awk: ${#_awks[@]})"
[[ ${_fail} -eq 0 ]]
