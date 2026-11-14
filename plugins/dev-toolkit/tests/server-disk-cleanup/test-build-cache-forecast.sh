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
export STUB_TEMPLATE='{{range .BuildCache}}{{.ID}}|{{.Parent}}|{{.Shared}}|{{.InUse}}|{{.CacheType}}|{{.Size}}|{{.LastUsedAt}}|{{.CreatedAt}}\n{{end}}'

# Заглушка docker: `buildx version` — по STUB_BUILDX: yes — код 0; no и old —
# код 1 и сообщение docker CLI об отсутствующем плагине (новая и старая форма);
# sub — код 1 и ошибка самого buildx «unknown command» (плагин есть, подкоманды
# нет); любое другое значение — код 1 с посторонним текстом (сбой);
# `buildx inspect` печатает драйвер из STUB_DRIVER (пусто — код 1 без вывода);
# `system df` отдаёт STUB_FIXTURE с кодом STUB_DF_RC, только если аргументы —
# ровно `-v --format <шаблон>`; `version --format {{.Server.Version}}` печатает
# STUB_VERSION (пусто — код 1); `context show` печатает STUB_CONTEXT (none — код 1
# и сообщение CLI без подкоманды). Любой другой вызов — ошибка теста.
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
      sub)
        echo 'ERROR: unknown command: "version"' >&2
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
  "version --format")
    if [[ $# -ne 3 || "$3" != '{{.Server.Version}}' ]]; then
      echo "заглушка docker: не тот вызов version: $*" >&2
      exit 96
    fi
    [[ -n "${STUB_VERSION:-}" ]] || exit 1
    echo "${STUB_VERSION}"
    ;;
  "context show")
    if [[ "${STUB_CONTEXT:-}" == none ]]; then
      echo "docker: 'context' is not a docker command." >&2
      exit 1
    fi
    echo "${STUB_CONTEXT:-}"
    ;;
  *)
    echo "заглушка docker: неожиданный вызов: $*" >&2
    exit 97
    ;;
esac
EOF
# Заглушки pgrep и ps — время запуска dockerd: pgrep печатает строки STUB_PIDS
# (пусто — код 1); ps печатает STUB_PS как procps — с выравниванием по правому
# краю (fail — код 1 и ошибка busybox). Чужой вызов — код 95/94: блок глушит их
# stderr, и такой вызов виден как «время запуска не определено».
cat >"${_root}/stub/pgrep" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "-x dockerd" ]] || exit 95
[[ -n "${STUB_PIDS:-}" ]] || exit 1
printf '%s\n' "${STUB_PIDS}"
EOF
cat >"${_root}/stub/ps" <<'EOF'
#!/usr/bin/env bash
[[ $# -eq 4 && "$1 $2 $3" == "-o uid=,etimes= -p" && "$4" == "${STUB_PIDS:-}" ]] || exit 94
if [[ "${STUB_PS:-}" == fail ]]; then
  echo "ps: bad -o argument 'uid=,etimes='" >&2
  exit 1
fi
printf '%s\n' "${STUB_PS:-}"
EOF
chmod +x "${_root}/stub/docker" "${_root}/stub/pgrep" "${_root}/stub/ps"

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
  "${_root}/timeout-124" "${_root}/timeout-127" "${_root}/clock"
# clock — «часы» блока по умолчанию (в PATH после PRE): `date +%s` — CLOCK_NOW
# из stamp, иначе время запуска dockerd (now − etimes) и граница возраста
# разошлись бы с ожиданием вектора на смене секунды.
# shellcheck disable=SC2016  # `$1`, `$@`, `${…}` — текст заглушки
printf '#!/bin/sh\ncase "$1" in +%%s) echo "${CLOCK_NOW}"; exit 0 ;; esac\nexec "${REAL_DATE}" "$@"\n' >"${_root}/clock/date"
chmod +x "${_root}/clock/date"
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
# Время создания записи по умолчанию — 40 суток назад, dockerd запущен час назад
# (STUB_PS по умолчанию): все старые записи загружены с диска. ST — время запуска,
# как его печатает блок в третьей строке.
stamp() {
  _now="$(date +%s)"
  export CLOCK_NOW="${_now}"
  CREATED="$(ts 3456000)"
  ST="$(date -u -d "@$((_now - 3600))" '+%Y-%m-%d %H:%M:%S')"
  OLD="$(ts 2592000)"
  FRESH="$(ts 3600)"
  EDGE_OLD="$(ts 604860)"
  EDGE_FRESH="$(ts 604740)"
}
stamp

# rec <id> <родители> <shared> <inuse> <тип> <размер> <last used> [<created>]
_fx="${_root}/fixture.txt"
rec() { printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "${8-${CREATED}}" >>"${_fx}"; }
new_fixture() { : >"${_fx}"; }

# run_block <каталог awk>: вывод блока — в _out. Переменные вектора: DRIVER
# (драйвер builder'а), BUILDX (yes|no|old|sub|иное — см. заглушку), DF_RC, CWD (каталог запуска), PRE
# (каталог с подменой date или awk, в PATH раньше остальных), LOC (локаль);
# время запуска dockerd: VER (версия сервера), DHOST (DOCKER_HOST; переменная
# машины разработчика в блок не попадает), CTX (контекст), PIDS (вывод pgrep),
# PSOUT (вывод ps: «uid etimes»).
# Пояс запуска — не UTC: потеря `-u` у date в блоке иначе не видна на UTC-машине.
# stderr блока идёт в тот же вывод: постороннее сообщение роняет вектор.
run_block() {
  local _path="${_root}/stub:${_root}/clock:$1:${PATH}"
  [[ -n "${PRE:-}" ]] && _path="${_root}/stub:${PRE}:${_root}/clock:$1:${PATH}"
  _out="$(cd "${CWD:-${_cwd}}" && TZ=XXX-3 STUB_DRIVER="${DRIVER-docker}" STUB_BUILDX="${BUILDX:-yes}" \
    STUB_FIXTURE="${_fx}" STUB_DF_RC="${DF_RC:-0}" LC_ALL="${LOC:-C}" LOCPATH="${LOCDIR:-}" \
    STUB_VERSION="${VER-29.9.3}" DOCKER_HOST="${DHOST-}" STUB_CONTEXT="${CTX-default}" \
    STUB_PIDS="${PIDS-4242}" STUB_PS="${PSOUT-    0     3600}" \
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
  "остаются: свежие 50 МБ; общие с образами 0 МБ; занятые и служебные 0 МБ; предки остающихся 0 МБ; старые под снимаемыми 0 МБ" \
  "незанятые записи: необщие 150 МБ, все 150 МБ; в прогнозе записи без времени использования: 0 МБ; запуск dockerd: ${ST} UTC"

new_fixture
rec base "" false false regular 100MB "${OLD}"
rec mid base false false regular 30MB "${OLD}"
rec top mid false false regular 50MB "${FRESH}"
check "старые предки свежей (через поколение) — не входят" \
  "прогноз: 0 МБ (записей: 0 из 3; всего в кеше 180 МБ)" \
  "остаются: свежие 50 МБ; общие с образами 0 МБ; занятые и служебные 0 МБ; предки остающихся 130 МБ; старые под снимаемыми 0 МБ"

new_fixture
rec sh1 "" true false regular 100MB "${OLD}"
rec priv1 "" false false regular 7MB "${FRESH}"
check "старая общая с образом — не входит; необщие считаются отдельно" \
  "прогноз: 0 МБ (записей: 0 из 2; всего в кеше 107 МБ)" \
  "остаются: свежие 7 МБ; общие с образами 100 МБ; занятые и служебные 0 МБ; предки остающихся 0 МБ; старые под снимаемыми 0 МБ" \
  "незанятые записи: необщие 7 МБ, все 107 МБ; в прогнозе записи без времени использования: 0 МБ; запуск dockerd: ${ST} UTC"

# --- Граф ---------------------------------------------------------------------

new_fixture
rec base "" false false regular 100MB "${OLD}"
rec sh1 base true false regular 20MB "${OLD}"
check "старая необщая — предок старой общей — не входит" \
  "прогноз: 0 МБ (записей: 0 из 2; всего в кеше 120 МБ)" \
  "остаются: свежие 0 МБ; общие с образами 20 МБ; занятые и служебные 0 МБ; предки остающихся 100 МБ; старые под снимаемыми 0 МБ"

new_fixture
rec base "" false false regular 100MB "${OLD}"
rec leaf base false false regular 50MB "${OLD}"
check "цепочка старых необщих, созданных до запуска dockerd, — снимается только верхняя, нижнюю освежит" \
  "прогноз: 50 МБ (записей: 1 из 2; всего в кеше 150 МБ)" \
  "остаются: свежие 0 МБ; общие с образами 0 МБ; занятые и служебные 0 МБ; предки остающихся 0 МБ; старые под снимаемыми 100 МБ"

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
check "несколько родителей у старой загруженной — входит она, оба родителя освежены" \
  "прогноз: 1 МБ (записей: 1 из 3; всего в кеше 31 МБ)" \
  "остаются: свежие 0 МБ; общие с образами 0 МБ; занятые и служебные 0 МБ; предки остающихся 0 МБ; старые под снимаемыми 30 МБ"

new_fixture
rec a "" false false regular 10MB "${OLD}"
rec b "" false false regular 20MB "${OLD}"
rec merge "a,b" false false regular 1MB "${OLD}"
check "несколько родителей через запятую без пробела у старой загруженной — оба освежены" \
  "прогноз: 1 МБ (записей: 1 из 3; всего в кеше 31 МБ)"

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

# --- Время запуска dockerd: каскад BuildKit ----------------------------------

# Снятие записи, созданной до запуска dockerd, освежает её родителей (ошибка
# parentsOf в BuildKit 0.10+, Docker 23+): цепочка в этом запуске на них
# останавливается. Записи текущей жизни dockerd уходят цепочкой. По умолчанию
# dockerd запущен час назад, записи созданы 40 суток назад — загружены с диска.
new_fixture
rec base "" false false regular 100MB "${OLD}"
rec mid base false false regular 30MB "${OLD}"
rec top mid false false regular 50MB "${OLD}"
check "V1 загруженная цепочка из трёх — только верхняя" \
  "прогноз: 50 МБ (записей: 1 из 3; всего в кеше 180 МБ)" \
  "остаются: свежие 0 МБ; общие с образами 0 МБ; занятые и служебные 0 МБ; предки остающихся 0 МБ; старые под снимаемыми 130 МБ" \
  "незанятые записи: необщие 180 МБ, все 180 МБ; в прогнозе записи без времени использования: 0 МБ; запуск dockerd: ${ST} UTC"
DHOST=unix:///var/run/docker.sock check "V1, DOCKER_HOST — стандартный сокет: время известно" \
  "прогноз: 50 МБ (записей: 1 из 3; всего в кеше 180 МБ)"
DHOST=unix:///run/docker.sock check "V1, DOCKER_HOST — /run/docker.sock: время известно" \
  "прогноз: 50 МБ (записей: 1 из 3; всего в кеше 180 МБ)"
VER=23.0.0 check "V1, Docker 23.0 — родителей освежает" \
  "прогноз: 50 МБ (записей: 1 из 3; всего в кеше 180 МБ)"
_r1="прогноз: от 50 до 180 МБ (записей: от 1 до 3 из 3; всего в кеше 180 МБ)"
_r2="остаются: свежие 0 МБ; общие с образами 0 МБ; занятые и служебные 0 МБ; предки остающихся 0 МБ; старые под снимаемыми 130 МБ"
_r3="незанятые записи: необщие 180 МБ, все 180 МБ; в прогнозе записи без времени использования: 0 МБ; запуск dockerd: не определён"
DHOST=tcp://h:2375 check "V6 удалённый DOCKER_HOST — диапазон" "${_r1}" "${_r2}" "${_r3}"
DHOST=unix:///run/user/1000/docker.sock check "V6 rootless-сокет — диапазон" "${_r1}" "${_r2}" "${_r3}"
CTX=rootless check "V6 контекст не default — диапазон" "${_r1}" "" "${_r3}"
CTX=none check "V6 нет docker context — диапазон" "${_r1}" "" "${_r3}"
PIDS="" check "V6 процесса dockerd не видно — диапазон" "${_r1}" "" "${_r3}"
PIDS=$'4242\n4243' check "V6 два процесса dockerd — диапазон" "${_r1}" "" "${_r3}"
PSOUT=" 1000     3600" check "V6 dockerd не под root — диапазон" "${_r1}" "" "${_r3}"
PSOUT=fail check "V6 ps без etimes (busybox) — диапазон" "${_r1}" "" "${_r3}"
PSOUT="    0      abc" check "V6 etimes не число — диапазон" "${_r1}" "" "${_r3}"
PSOUT="    0" check "V6 ps вернул одно слово — диапазон" "${_r1}" "" "${_r3}"
VER="" check "V6 версия Docker не получена — диапазон" "${_r1}" "" "${_r3}"
VER=17.06.0-ce check "V6 версия Docker вне известных — диапазон" "${_r1}" "" "${_r3}"
_o3="незанятые записи: необщие 180 МБ, все 180 МБ; в прогнозе записи без времени использования: 0 МБ; запуск dockerd: не нужен (Docker до 23)"
VER=20.10.24 check "Docker 20.10 (BuildKit до 0.10) — цепочка целиком" \
  "прогноз: 180 МБ (записей: 3 из 3; всего в кеше 180 МБ)" \
  "остаются: свежие 0 МБ; общие с образами 0 МБ; занятые и служебные 0 МБ; предки остающихся 0 МБ; старые под снимаемыми 0 МБ" \
  "${_o3}"
VER=22.06.0 PIDS="" check "Docker 22 — цепочка целиком, время запуска не нужно" \
  "прогноз: 180 МБ (записей: 3 из 3; всего в кеше 180 МБ)" "" "${_o3}"

_st30="$(date -u -d "@$((_now - 2592000))" '+%Y-%m-%d %H:%M:%S')"
new_fixture
rec base "" false false regular 100MB "$(ts 777600)" "$(ts 864000)"
rec mid base false false regular 30MB "$(ts 777600)" "$(ts 864000)"
rec top mid false false regular 50MB "$(ts 777600)" "$(ts 864000)"
PSOUT="    0  2592000" check "V2 цепочка текущей жизни dockerd — целиком" \
  "прогноз: 180 МБ (записей: 3 из 3; всего в кеше 180 МБ)" \
  "остаются: свежие 0 МБ; общие с образами 0 МБ; занятые и служебные 0 МБ; предки остающихся 0 МБ; старые под снимаемыми 0 МБ" \
  "незанятые записи: необщие 180 МБ, все 180 МБ; в прогнозе записи без времени использования: 0 МБ; запуск dockerd: ${_st30} UTC"

# Как опыт ov-в: две новые записи поверх трёх загруженных — новые и первая
# загруженная, её родитель освежён.
new_fixture
rec l0 "" false false regular 10MB "$(ts 777600)" "$(ts 2160000)"
rec l1 l0 false false regular 20MB "$(ts 777600)" "$(ts 2160000)"
rec l2 l1 false false regular 40MB "$(ts 777600)" "$(ts 2160000)"
rec l3 l2 false false regular 80MB "$(ts 777600)" "$(ts 1296000)"
rec l4 l3 false false regular 160MB "$(ts 777600)" "$(ts 1296000)"
PSOUT="    0  1728000" check "V3 новые записи поверх загруженных — новые и первая загруженная" \
  "прогноз: 280 МБ (записей: 3 из 5; всего в кеше 310 МБ)" \
  "остаются: свежие 0 МБ; общие с образами 0 МБ; занятые и служебные 0 МБ; предки остающихся 0 МБ; старые под снимаемыми 30 МБ"

new_fixture
rec p "" false false regular 5MB "${OLD}"
rec c1 p false false regular 10MB "${OLD}"
rec c2 p false false regular 20MB "${OLD}"
rec c3 c2 false false regular 40MB "${OLD}"
check "V4 ветвление загруженных — сняты оба листа, родитель и середина освежены" \
  "прогноз: 50 МБ (записей: 2 из 4; всего в кеше 75 МБ)" \
  "остаются: свежие 0 МБ; общие с образами 0 МБ; занятые и служебные 0 МБ; предки остающихся 0 МБ; старые под снимаемыми 25 МБ"

new_fixture
rec old1 "" false false regular 100MB "${OLD}"
rec old2 "" false false regular 20MB "${OLD}"
CTX=none check "V7 время запуска не определено, цепочек нет — одно число" \
  "прогноз: 120 МБ (записей: 2 из 2; всего в кеше 120 МБ)" \
  "остаются: свежие 0 МБ; общие с образами 0 МБ; занятые и служебные 0 МБ; предки остающихся 0 МБ; старые под снимаемыми 0 МБ" \
  "незанятые записи: необщие 120 МБ, все 120 МБ; в прогнозе записи без времени использования: 0 МБ; запуск dockerd: не определён"

new_fixture
rec base "" false false regular 100MB "${OLD}"
rec nodate base false false regular 30MB ""
rec top nodate false false regular 10MB "${OLD}"
check "V9 запись без времени использования посреди загруженной цепочки — освежена, остаётся" \
  "прогноз: 10 МБ (записей: 1 из 3; всего в кеше 140 МБ)" \
  "остаются: свежие 0 МБ; общие с образами 0 МБ; занятые и служебные 0 МБ; предки остающихся 0 МБ; старые под снимаемыми 130 МБ" \
  "незанятые записи: необщие 140 МБ, все 140 МБ; в прогнозе записи без времени использования: 0 МБ; запуск dockerd: ${ST} UTC"

# --- Возраст ------------------------------------------------------------------

# BuildKit запись без времени использования удаляет (фильтр возраста её не
# защищает); загруженного предка её снятие освежает, как и у прочих записей, —
# блок считает так же и называет её долю третьей строкой.
new_fixture
rec base "" false false regular 100MB "${OLD}"
rec nodate base false false regular 30MB ""
check "запись без времени использования входит, её загруженного предка освежит" \
  "прогноз: 30 МБ (записей: 1 из 2; всего в кеше 130 МБ)" \
  "остаются: свежие 0 МБ; общие с образами 0 МБ; занятые и служебные 0 МБ; предки остающихся 0 МБ; старые под снимаемыми 100 МБ" \
  "незанятые записи: необщие 130 МБ, все 130 МБ; в прогнозе записи без времени использования: 30 МБ; запуск dockerd: ${ST} UTC"

new_fixture
rec base "" false false regular 100MB "${OLD}"
rec nodate base true false regular 30MB ""
check "общая запись без времени использования остаётся и держит предка" \
  "прогноз: 0 МБ (записей: 0 из 2; всего в кеше 130 МБ)" \
  "остаются: свежие 0 МБ; общие с образами 30 МБ; занятые и служебные 0 МБ; предки остающихся 100 МБ; старые под снимаемыми 0 МБ" \
  "незанятые записи: необщие 100 МБ, все 130 МБ; в прогнозе записи без времени использования: 0 МБ; запуск dockerd: ${ST} UTC"

# Слой идущей сборки: занят и ещё без времени использования — остаётся и держит
# старых предков; в «незанятые» не входит.
new_fixture
rec base "" false false regular 100MB "${OLD}"
rec busy base false true regular 30MB ""
check "занятая запись без времени использования остаётся и держит предка" \
  "прогноз: 0 МБ (записей: 0 из 2; всего в кеше 130 МБ)" \
  "остаются: свежие 0 МБ; общие с образами 0 МБ; занятые и служебные 30 МБ; предки остающихся 100 МБ; старые под снимаемыми 0 МБ" \
  "незанятые записи: необщие 100 МБ, все 100 МБ; в прогнозе записи без времени использования: 0 МБ; запуск dockerd: ${ST} UTC"

new_fixture
rec fs "" true false regular 10MB "${FRESH}"
rec fb "" false true regular 20MB "${FRESH}"
check "свежая запись остаётся «свежей», даже если она общая или занятая" \
  "прогноз: 0 МБ (записей: 0 из 2; всего в кеше 30 МБ)" \
  "остаются: свежие 30 МБ; общие с образами 0 МБ; занятые и служебные 0 МБ; предки остающихся 0 МБ; старые под снимаемыми 0 МБ" \
  "незанятые записи: необщие 0 МБ, все 10 МБ; в прогнозе записи без времени использования: 0 МБ; запуск dockerd: ${ST} UTC"

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

# Граница времени запуска dockerd (тот же фиксированный «сейчас», etimes 1000 с):
# запись, созданная ровно в секунду запуска, — текущей жизни, на секунду раньше —
# загружена с диска.
_st_epoch=$((FIXED_NOW - 1000))
new_fixture
rec base "" false false regular 100MB "$(tsx "$((_cut_epoch - 100))")" "$(tsx "$((_st_epoch - 100))")"
rec top base false false regular 10MB "$(tsx "$((_cut_epoch - 100))")" "$(tsx "${_st_epoch}")"
PRE="${_root}/date-fixed" PSOUT="    0     1000" check "V8 создана ровно в секунду запуска dockerd — цепочка целиком" \
  "прогноз: 110 МБ (записей: 2 из 2; всего в кеше 110 МБ)"
new_fixture
rec base "" false false regular 100MB "$(tsx "$((_cut_epoch - 100))")" "$(tsx "$((_st_epoch - 100))")"
rec top base false false regular 10MB "$(tsx "$((_cut_epoch - 100))")" "$(tsx "$((_st_epoch - 1))")"
PRE="${_root}/date-fixed" PSOUT="    0     1000" check "V8 создана за секунду до запуска dockerd — только верхняя" \
  "прогноз: 10 МБ (записей: 1 из 2; всего в кеше 110 МБ)"

# Снимок опыта в одноразовом dockerd 29.9.3 (overlay2, случай «в», 14.11.2026):
# цепочка после перезапуска dockerd, сверху — две новые записи. Время записей
# сдвинуто на 8 суток назад (порог блока — 168 ч, в опыте — 30 с), «сейчас» — время
# prune, dockerd перезапущен в 09:48:45 (сдвинутое). Время создания: загруженные —
# 09:48:32, новые — 09:49:59 (сдвинутые). Итог prune в опыте — Total: 10.17MB.
_ovnow="$(date -u -d '2026-11-14 09:50:40' +%s)"
_ovst="$(date -u -d '2026-11-06 09:48:45' +%s)"
_ovold='2026-11-06 09:48:32.000000000 +0000 UTC'
_ovnew='2026-11-06 09:49:59.000000000 +0000 UTC'
new_fixture
rec nhbufuf38ajquwuyuv9153foq sved1w92rvktxdt2y5wkknqjz false false regular 2B '2026-11-06 09:48:32.719082102 +0000 UTC' "${_ovold}"
rec 32czkfrkz5iqlqln6wpok04up nhbufuf38ajquwuyuv9153foq false false regular 1.29MB '2026-11-06 09:48:32.728010599 +0000 UTC' "${_ovold}"
rec xd6mjrku7riid4331psy6u032 32czkfrkz5iqlqln6wpok04up false false regular 1.99MB '2026-11-06 09:48:32.737329894 +0000 UTC' "${_ovold}"
rec sved1w92rvktxdt2y5wkknqjz "" false false regular 0B '2026-11-06 09:48:32.767915454 +0000 UTC' "${_ovold}"
rec kv0osxf9xw1ps8vr2dnf9l2wm "" false false source.local 0B '2026-11-06 09:49:59.773764923 +0000 UTC' "${_ovnew}"
rec 970wk3cldbisondfcz6108ymj "" false false source.local 141B '2026-11-06 09:49:59.790912768 +0000 UTC' "${_ovnew}"
rec 4k1txnqbk75j69wcaydfagzv5 xd6mjrku7riid4331psy6u032 false false regular 2.69MB '2026-11-06 09:49:59.799015737 +0000 UTC' "${_ovold}"
rec xsthdsmbfua20ewc2oi1nnuq0 4k1txnqbk75j69wcaydfagzv5 false false regular 3.39MB '2026-11-06 09:49:59.807070296 +0000 UTC' "${_ovnew}"
rec 57cytsc6wr88f8suqym06e1f3 xsthdsmbfua20ewc2oi1nnuq0 false false regular 4.09MB '2026-11-06 09:49:59.820133361 +0000 UTC' "${_ovnew}"
FIXED_NOW="${_ovnow}" PRE="${_root}/date-fixed" PSOUT="    0 $((_ovnow - _ovst))" check "снимок опыта ov-в: 10 МБ (в опыте 10,17)" \
  "прогноз: 10 МБ (записей: 5 из 9; всего в кеше 13 МБ)" \
  "остаются: свежие 0 МБ; общие с образами 0 МБ; занятые и служебные 0 МБ; предки остающихся 0 МБ; старые под снимаемыми 3 МБ"
FIXED_NOW="${_ovnow}" PRE="${_root}/date-fixed" CTX=none check "снимок опыта ov-в, время запуска не определено — диапазон" \
  "прогноз: от 4 до 13 МБ (записей: от 3 до 9 из 9; всего в кеше 13 МБ)"
FIXED_NOW="${_ovnow}" PRE="${_root}/date-fixed" VER=20.10.24 check "снимок опыта ov-в, Docker 20.10 — всё" \
  "прогноз: 13 МБ (записей: 9 из 9; всего в кеше 13 МБ)"

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
  "остаются: свежие 0 МБ; общие с образами 0 МБ; занятые и служебные 70 МБ; предки остающихся 0 МБ; старые под снимаемыми 0 МБ" \
  "незанятые записи: необщие 300 МБ, все 300 МБ; в прогнозе записи без времени использования: 0 МБ; запуск dockerd: ${ST} UTC"

new_fixture
rec odd1 "" "<no value>" false regular 100MB "${OLD}"
rec odd2 "" false "<no value>" regular 50MB "${OLD}"
check "признаки Shared и InUse не из true/false — запись остаётся" \
  "прогноз: 0 МБ (записей: 0 из 2; всего в кеше 150 МБ)" \
  "остаются: свежие 0 МБ; общие с образами 100 МБ; занятые и служебные 50 МБ; предки остающихся 0 МБ; старые под снимаемыми 0 МБ"

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
BUILDX=sub check_undefined "ошибка самого buildx со словами unknown command — не «плагина нет»" "не назвал драйвер"
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
timeout_only tmo-ver "version --format"
timeout_only tmo-ctx "context show"
new_fixture
rec base "" false false regular 100MB "${OLD}"
rec mid base false false regular 30MB "${OLD}"
rec top mid false false regular 50MB "${OLD}"
PRE="${_root}/tmo-ver" check "docker version не уложился в таймаут — диапазон" "${_r1}" "" "${_r3}"
PRE="${_root}/tmo-ctx" check "docker context show не уложился в таймаут — диапазон" "${_r1}" "" "${_r3}"

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
printf 'old1||false|false|regular|100MB|%s\n' "${OLD}" >>"${_fx}"
check_undefined "в строке семь полей (шаблон без времени создания)" "не 8 полей"

new_fixture
printf 'old1||false|false|regular|100MB|%s|%s|лишнее\n' "${OLD}" "${CREATED}" >>"${_fx}"
check_undefined "в строке девять полей" "не 8 полей"

new_fixture
rec old1 "" false false regular 100MB "${OLD}" "${CREATED/+0000 UTC/+0300 MSK}"
check_undefined "время создания не в UTC" "время создания не в UTC"

new_fixture
rec old1 "" false false regular 100MB "${OLD}" ""
check_undefined "пустое время создания" "время создания не в UTC"

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
