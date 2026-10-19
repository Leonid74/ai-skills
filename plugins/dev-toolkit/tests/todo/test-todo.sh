#!/usr/bin/env bash
# Стенд скрипта scripts/todo.sh (список задач в двух файлах): перенос PHPUnit-теста
# apps-b24-platform tests/Unit/Scripts/TodoScriptTest.php (38 методов, 187 случаев с наборами
# данных) без потери проверок. Скрипт гоняется только на фикстурах во временном каталоге.
#
# Запуск из корня репозитория:
#   bash plugins/dev-toolkit/tests/todo/test-todo.sh
# Переменные:
#   TODO_SH=<путь>   проверяемый скрипт вместо plugins/dev-toolkit/scripts/todo.sh (мутационная
#                    проверка, прогон на старых редакциях);
#   TODO_AWKS="…"    только названные варианты awk (через пробел: системный mawk gawk busybox);
#                    тесты без цикла по awk идут только с вариантом «системный». Сверка числа
#                    случаев (187) и методов (38) — только при полном наборе.
#
# Соответствие PHP: имя проверки — «метод[ключ набора данных]» (без ключа — метод без провайдера),
# в скобках — вариант awk. Одна проверка — один случай PHP под одним awk; ассерты случая внутри неё.
# Тесты с циклом по awkVariants() в PHP идут здесь под всеми вариантами awk, остальные шесть —
# один раз под системным awk, как в PHP. Варианты: системный awk, mawk, gawk (как в PHP) и
# busybox awk (в PHP его нет) — подменой «awk» симлинком в каталоге первым в PATH; подмена
# действует только на вызов скрипта, собственные проверки стенда идут на системных утилитах.
# Отличия от PHP — в MAPPING.md рядом.
#
# Обратные апострофы и «$» в одинарных кавычках — Markdown-код и текст фикстур, а не подстановка:
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
unset TODO_FILE TODO_DONE_FILE TODO_COUNTER_FILE

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TODO_SH="${TODO_SH:-${_here}/../../scripts/todo.sh}"
[[ "${TODO_SH}" == /* ]] || TODO_SH="${PWD}/${TODO_SH}"
if [[ ! -r "${TODO_SH}" ]]; then
  printf 'нет проверяемого скрипта: %s\n' "${TODO_SH}" >&2
  exit 1
fi

_pass=0
_fail=0
_asserts=0
_root="$(mktemp -d)"
# Каталог без права записи (ro/) возвращается в 755 до уборки.
trap 'chmod -R u+rwx "${_root}" 2>/dev/null; rm -rf "${_root}"' EXIT
_io="${_root}/io"
mkdir "${_io}"

# ---------------------------------------------------------------------------------------------
# Фикстура (константы PHP побайтно). Тело каждой — строки PHP-heredoc как есть; heredoc bash даёт
# лишний перевод строки в конце, его снимает «%$'\n'».

IFS= read -r -d '' R3 <<'MD' || true
### №3. Первая задача
- **Приоритет:** низкий (по тексту пункта)
- **Статус:** открыта
- **Тип:** задача
- **Заведено:** 2026-01-01 — решение владельца
- **Триаж v2:** дефект
- **Ревью:** high
- **Связано:** №5, №7

**Первая задача.** Путь `C:\temp\new` & знак / и обратный апостроф.
- вложенный пункт
  продолжение


MD
R3="${R3%$'\n'}"

IFS= read -r -d '' R5 <<'MD' || true
### №5. Сводный: подсистема
- **Приоритет:** средний (владелец, 2026-01-02)
- **Статус:** открыта
- **Тип:** сводный
- **Заведено:** 2026-01-02 — нормы v2
- **Триаж v2:** сводный
- **Ревью:** max (строки только `Makefile` — high)

- **Строка сводного пункта.** Текст.


MD
R5="${R5%$'\n'}"

IFS= read -r -d '' R7 <<'MD' || true
### №7. Последняя задача
- **Приоритет:** высокий (ассистент, 2026-01-03 — не подтверждён)
- **Статус:** отложена до замера
- **Тип:** задача
- **Заведено:** 2026-01-03 — ревью `xhigh` ветки `fix/x`, проход 1, CONFIRMED
- **Триаж v2:** не находка ревью
- **Ревью:** по таблице при реализации (install — max)

Текст последней задачи.
MD
R7="${R7%$'\n'}"

IFS= read -r -d '' TODO_HEAD <<'MD' || true
# Список задач

Шапка. Пример записи:

```markdown
### №N. Короткое название
### №99. Пример с номером в блоке кода
- **Приоритет:** мусор
```

## Активные задачи


MD
TODO_HEAD="${TODO_HEAD%$'\n'}"

IFS= read -r -d '' DONE_HEAD <<'MD' || true
# Архив

Шапка архива.

## Выполненные задачи


MD
DONE_HEAD="${DONE_HEAD%$'\n'}"

IFS= read -r -d '' DONE_LEGACY <<'MD' || true
## Закрытые до формата (прежний вид)

- **Задача №2: старая запись — ВЫПОЛНЕНА** (2026-01-01).
  Текст старой записи.

- **Строки сводного №5 — follow-up №4 — ВЫПОЛНЕНЫ** (2026-01-01).

MD
DONE_LEGACY="${DONE_LEGACY%$'\n'}"

# Части, повторяющиеся в ожиданиях.
H3=$'### №3. Первая задача\n'
H5=$'### №5. Сводный: подсистема\n'
CLOSED_OLD=$'- **Закрыто:** 2026-01-05, PR #1\n- **Итог:** x\n'
CLOSED_NEW=$'- **Закрыто:** 2026-02-01, PR #10\n'
LEGACY2=$'- **Задача №2: старая запись — ВЫПОЛНЕНА** (2026-01-01).\n'
DN='- [x] **✅ Сделано 2026-01-05, PR #3** **Закрытая.** Текст.'
COUNTER0=$'8 # выдан №7 — Последняя задача\n'

# ---------------------------------------------------------------------------------------------
# Строковые помощники: результат — в _r. Шаблон и замена в кавычках — буквально (без glob и без
# «&» из patsub_replacement bash 5.2).

# sr <строка> <что> <на что> — str_replace: все вхождения.
sr() {
  local _s="$1" _from="$2" _to="$3"
  _r="${_s//"${_from}"/"${_to}"}"
}

# cs <запись> — closedStatus: первая строка «- **Статус:** …» становится «- **Статус:** закрыта».
cs() {
  local _s="$1" _key=$'\n- **Статус:** ' _pre _post
  if [[ "${_s}" != *"${_key}"* ]]; then
    _r="${_s}"
    return
  fi
  _pre="${_s%%"${_key}"*}"
  _post="${_s#*"${_key}"}"
  if [[ "${_post}" == *$'\n'* ]]; then
    _post=$'\n'"${_post#*$'\n'}"
  else
    _post=''
  fi
  _r="${_pre}"$'\n- **Статус:** закрыта'"${_post}"
}

# composite <текст> — запись №5 с заданным текстом вместо единственной строки.
composite() {
  sr "${R5}" $'- **Строка сводного пункта.** Текст.\n' "$1"
}

# t3 <запись №3> — список: шапка, данная запись, №5, №7.
t3() {
  _r="${TODO_HEAD}$1${R5}${R7}"$'\n'
}

# swap <что> <на что> — список с заменой в записи №3.
swap() {
  sr "${R3}" "$1" "$2"
  t3 "${_r}"
}

# rep <строка> <N> — строка, повторённая N раз.
rep() {
  local _s="$1"
  printf -v _r '%*s' "$2" ''
  _r="${_r// /"${_s}"}"
}

# trim <строка> — без пробельных символов по краям (как trim() PHP).
trim() {
  local _s="$1"
  _s="${_s#"${_s%%[![:space:]]*}"}"
  _r="${_s%"${_s##*[![:space:]]}"}"
}

# Производные записи.
A3="${H3}${CLOSED_OLD}${R3#"${H3}"}"
sr "${R5}" "${H5}" "${H5}${CLOSED_OLD}"
cs "${_r}"
ARCHIVED5="${_r}"
T57="${TODO_HEAD}${R5}${R7}"$'\n'
T37="${TODO_HEAD}${R3}${R7}"$'\n'
OK=(--closed '2026-02-01, PR #10' --summary-file '{dir}/summary')

# ---------------------------------------------------------------------------------------------
# Варианты awk.

_awk_names=('системный')
_awk_paths=("${PATH}")
for _a in mawk gawk busybox; do
  _bin_src="$(command -v "${_a}" 2>/dev/null)" || continue
  mkdir -p "${_root}/.bin-${_a}"
  ln -s "${_bin_src}" "${_root}/.bin-${_a}/awk"
  _awk_names+=("${_a}")
  _awk_paths+=("${_root}/.bin-${_a}:${PATH}")
done
_sel_names=()
_sel_paths=()
for _i in "${!_awk_names[@]}"; do
  if [[ -z "${TODO_AWKS:-}" || " ${TODO_AWKS} " == *" ${_awk_names[_i]} "* ]]; then
    _sel_names+=("${_awk_names[_i]}")
    _sel_paths+=("${_awk_paths[_i]}")
  fi
done
_once=0
[[ " ${_sel_names[*]} " == *' системный '* ]] && _once=1

# ---------------------------------------------------------------------------------------------
# Учёт случаев и проверок.

declare -A _seen=() _mseen=()
_cases=0
_methods=0
_case_list=()
_failed=()
_skips=()
_bad=()
_case=''
_awk=''
_awkpath=''
_d=''

# reg <метод> [ключ] — учесть случай PHP (один раз на «метод[ключ]», не на вариант awk).
reg() {
  _case="$1"
  [[ $# -ge 2 ]] && _case+="[$2]"
  if [[ -z "${_seen[${_case}]+x}" ]]; then
    _seen[${_case}]=1
    _cases=$((_cases + 1))
    _case_list+=("${_case}")
  fi
  if [[ -z "${_mseen[$1]+x}" ]]; then
    _mseen[$1]=1
    _methods=$((_methods + 1))
  fi
}

bad() {
  _bad+=("$*")
}

# begin / finish — свежий каталог фикстуры на каждую проверку (setUp/tearDown PHP).
begin() {
  _bad=()
  _skipped=0
  _d="$(mktemp -d "${_root}/c.XXXXXX")"
  _tfiles=()
  reset_fixture
}

finish() {
  if [[ "${_skipped}" -eq 1 ]]; then
    :
  elif [[ ${#_bad[@]} -eq 0 ]]; then
    _pass=$((_pass + 1))
  else
    _fail=$((_fail + 1))
    _failed+=("${_case} (${_awk})")
    printf 'FAIL %s (%s)\n' "${_case}" "${_awk}"
    printf '  %s\n' "${_bad[@]}"
  fi
  chmod -R u+rwx "${_d}" 2>/dev/null
  rm -rf "${_d}"
}

# each_awk <метод> <ключ или ''> <функция> — случай под каждым выбранным вариантом awk.
each_awk() {
  local _i
  for _i in "${!_sel_names[@]}"; do
    _awk="${_sel_names[_i]}"
    _awkpath="${_sel_paths[_i]}"
    if [[ -n "$2" ]]; then reg "$1" "$2"; else reg "$1"; fi
    begin
    "$3"
    finish
  done
}

# once <метод> <функция> — случай один раз под системным awk.
once() {
  [[ "${_once}" -eq 1 ]] || return 0
  _awk='системный'
  _awkpath="${PATH}"
  reg "$1"
  begin
  "$2"
  finish
}

# skip <причина> — случай пропущен (markTestSkipped): не pass и не fail, называется в итоге.
skip() {
  _skipped=1
  _skips+=("${_case}: $1")
}
_skipped=0

# ---------------------------------------------------------------------------------------------
# Файлы фикстуры и запуск скрипта.

put() {
  printf '%s' "$2" >"${_d}/$1"
}

# slurp <переменная> <файл> — содержимое побайтно (с завершающими переводами строки).
slurp() {
  local _s=''
  [[ -e "$2" ]] && IFS= read -r -d '' _s <"$2"
  printf -v "$1" '%s' "${_s}"
}

reset_fixture() {
  put TODO.md "${TODO_HEAD}${R3}${R5}${R7}"$'\n'
  put DONE.md "${DONE_HEAD}${DONE_LEGACY}"
  put next "${COUNTER0}"
}

# T <аргументы…> — todo(): bash todo.sh <--todo …|_tfiles> --done … --counter … <аргументы>,
# каталог — фикстура, awk — выбранный вариант. Итог: _code, _out, _err.
_tfiles=()
T() {
  local _paths=(--todo "${_d}/TODO.md")
  [[ ${#_tfiles[@]} -gt 0 ]] && _paths=("${_tfiles[@]}")
  (
    cd "${_d}" || exit 99
    PATH="${_awkpath}" exec timeout 60 bash "${TODO_SH}" "${_paths[@]}" \
      --done "${_d}/DONE.md" --counter "${_d}/next" "$@"
  ) >"${_io}/out" 2>"${_io}/err"
  _code=$?
  slurp _out "${_io}/out"
  slurp _err "${_io}/err"
}

# new_args <опция> <значение>… — newArgs(): переопределённые параметры, затем умолчания. Итог: _na.
new_args() {
  local -A _ov=()
  local _order=() _k _j
  while [[ $# -ge 2 ]]; do
    _ov[$1]="$2"
    _order+=("$1")
    shift 2
  done
  _na=(new)
  for _k in "${_order[@]}"; do
    _na+=("${_k}" "${_ov[${_k}]}")
  done
  local _def=(--title-file "${_d}/title" --body-file "${_d}/body"
    --priority 'высокий (владелец, 2026-02-01)' --status открыта --type задача
    --created '2026-02-01 — решение владельца' --triage 'не находка ревью' --review high)
  for ((_j = 0; _j < ${#_def[@]}; _j += 2)); do
    [[ -n "${_ov[${_def[_j]}]+x}" ]] || _na+=("${_def[_j]}" "${_def[_j + 1]}")
  done
}
_na=()

# Снимок файлов до вызова и сверка после (assertSame содержимого; отсутствие тоже сверяется).
_snapped=()
snap() {
  local _f
  rm -rf "${_io}/snap"
  mkdir "${_io}/snap"
  _snapped=("$@")
  for _f in "$@"; do
    [[ -e "${_d}/${_f}" ]] && cat -- "${_d}/${_f}" >"${_io}/snap/${_f//\//_}"
  done
}

unchanged() {
  local _f _s
  for _f in "${_snapped[@]}"; do
    _asserts=$((_asserts + 1))
    _s="${_io}/snap/${_f//\//_}"
    if [[ -e "${_s}" ]]; then
      if ! cmp -s -- "${_s}" "${_d}/${_f}"; then
        diag_cmp "${_s}" "${_d}/${_f}"
        bad "файл ${_f} изменён${_dc}"
      fi
    elif [[ -e "${_d}/${_f}" || -L "${_d}/${_f}" ]]; then
      bad "файл ${_f} появился"
    fi
  done
}

# ---------------------------------------------------------------------------------------------
# Ассерты.

_code=0
_out=''
_err=''

# short <строка> — строка для сообщения о падении (до 600 байт, перевод строки — «⏎»). Итог: _sh.
short() {
  local _s="$1"
  [[ ${#_s} -gt 600 ]] && _s="${_s:0:600}…"
  _sh="${_s//$'\n'/⏎}"
}
_sh=''

# diag_cmp <файл> <файл> — первое расхождение для сообщения. Итог: _dc.
diag_cmp() {
  local _m
  _m="$(cmp -- "$1" "$2" 2>&1)" || true
  _dc=''
  [[ -n "${_m}" ]] && _dc=" (${_m})"
}
_dc=''

code_is() {
  _asserts=$((_asserts + 1))
  if [[ "${_code}" != "$1" ]]; then
    short "${_err}"
    bad "${2:+$2: }код ${_code}, ожидался $1; stderr: ${_sh}"
  fi
}

has() {
  _asserts=$((_asserts + 1))
  if [[ "$1" != *"$2"* ]]; then
    local _a
    short "$2"
    _a="${_sh}"
    short "$1"
    bad "${3:+$3: }нет подстроки [${_a}] в [${_sh}]"
  fi
}

lacks() {
  _asserts=$((_asserts + 1))
  if [[ "$1" == *"$2"* ]]; then
    short "$2"
    bad "${3:+$3: }лишняя подстрока [${_sh}]"
  fi
}

same() {
  _asserts=$((_asserts + 1))
  if [[ "$1" != "$2" ]]; then
    local _a
    short "$1"
    _a="${_sh}"
    short "$2"
    bad "${3:+$3: }получено [${_a}], ожидалось [${_sh}]"
  fi
}

has_err() { has "${_err}" "$@"; }
lacks_err() { lacks "${_err}" "$@"; }

# eq_file <имя> <ожидаемое> — файл фикстуры побайтно равен строке.
eq_file() {
  _asserts=$((_asserts + 1))
  printf '%s' "$2" >"${_io}/expected"
  if ! cmp -s -- "${_io}/expected" "${_d}/$1"; then
    diag_cmp "${_io}/expected" "${_d}/$1"
    bad "${3:+$3: }${1} не совпадает с ожидаемым${_dc}"
  fi
}

file_has() {
  local _f
  slurp _f "${_d}/$1"
  has "${_f}" "$2" "${3:-$1}"
}

# line_no <файл> <строка> — номер первой строки, равной данной (array_search по explode("\n")).
line_no() {
  local _lines _i
  mapfile -t _lines <"$1"
  for _i in "${!_lines[@]}"; do
    if [[ "${_lines[_i]}" == "$2" ]]; then
      _r=$((_i + 1))
      return 0
    fi
  done
  _r=0
  return 1
}

# no_ctrl <файл> — нет C0 (кроме перевода строки), DEL и C1 (регулярка assertDoesNotMatchRegularExpression).
# Код 2 (grep без -P) — тоже падение: иначе проверка молча проходила бы.
no_ctrl() {
  local _rc
  _asserts=$((_asserts + 1))
  LC_ALL=C grep -qaP '[\x00-\x09\x0b-\x1f\x7f]|\xc2[\x80-\x9f]' -- "$1"
  _rc=$?
  case "${_rc}" in
    0) bad "${2:+$2: }управляющий символ в сообщении" ;;
    1) ;;
    *) bad "${2:+$2: }grep -P недоступен (код ${_rc}) — проверка не выполнена" ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# close: перенос записи.

t_close_moves_byte_for_byte() {
  put summary $'Сделано: путь C:\\temp\\new & знак / и `код`\nвторая строка итога.\n'
  T close 3 --closed '2026-02-01, PR #10' --summary-file "${_d}/summary"
  code_is 0
  eq_file TODO.md "${TODO_HEAD}${R5}${R7}"$'\n'
  sr "${R3}" "${H3}" "${H3}${CLOSED_NEW}"$'- **Итог:** Сделано: путь C:\\temp\\new & знак / и `код` вторая строка итога.\n'
  cs "${_r}"
  eq_file DONE.md "${DONE_HEAD}${_r}${DONE_LEGACY}"
  eq_file next "${COUNTER0}" 'close счётчик не трогает'
}
each_awk closeMovesRecordToArchiveByteForByte '' t_close_moves_byte_for_byte

t_close_middle() {
  local _middle
  sr "${R3}" '### №3. Первая задача' '### №4. Средняя задача'
  sr "${_r}" '**Первая задача.**' '**Средняя задача.**'
  _middle="${_r}"
  put TODO.md "${TODO_HEAD}${R3}${_middle}${R5}${R7}"$'\n'
  put summary $'Итог.\n'
  T close 4 --closed '2026-02-01, PR #10' --summary-file "${_d}/summary"
  code_is 0
  eq_file TODO.md "${TODO_HEAD}${R3}${R5}${R7}"$'\n'
  sr "${_middle}" $'### №4. Средняя задача\n' $'### №4. Средняя задача\n'"${CLOSED_NEW}"$'- **Итог:** Итог.\n'
  cs "${_r}"
  eq_file DONE.md "${DONE_HEAD}${_r}${DONE_LEGACY}"
}
each_awk closeMovesMiddleRecordAndKeepsNeighbours '' t_close_middle

t_close_last() {
  put summary $'Итог.\n'
  T close 7 --closed 'без реализации — решение владельца 2026-02-01' --summary-file "${_d}/summary"
  code_is 0
  eq_file TODO.md "${TODO_HEAD}${R3}${R5}"
  sr "${R7}" $'### №7. Последняя задача\n' \
    $'### №7. Последняя задача\n- **Закрыто:** без реализации — решение владельца 2026-02-01\n- **Итог:** Итог.\n'
  cs "${_r}"
  eq_file DONE.md "${DONE_HEAD}${_r}"$'\n\n'"${DONE_LEGACY}"
}
each_awk closeMovesLastRecordAndSeparatesItInArchive '' t_close_last

# ---------------------------------------------------------------------------------------------
# Разбор параметров случаев провайдеров: -f ИМЯ СОДЕРЖИМОЕ (файл), -d ИМЯ (удалить файл),
# -o ОПЦИЯ ЗНАЧЕНИЕ (параметр new), -- АРГУМЕНТЫ (аргументы close после номера).

parse_case() {
  _p_fn=()
  _p_fc=()
  _p_ov=()
  _p_args=()
  _p_has_args=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f)
        _p_fn+=("$2")
        _p_fc+=("$3")
        shift 3
        ;;
      -d)
        _p_fn+=("$2")
        _p_fc+=($'\x01del')
        shift 2
        ;;
      -o)
        _p_ov+=("$2" "$3")
        shift 3
        ;;
      --)
        shift
        _p_args=("$@")
        _p_has_args=1
        break
        ;;
      *)
        printf 'стенд: неизвестный параметр случая %s\n' "$1" >&2
        exit 2
        ;;
    esac
  done
}

apply_files() {
  local _i
  for _i in "${!_p_fn[@]}"; do
    if [[ "${_p_fc[_i]}" == $'\x01del' ]]; then
      rm -f -- "${_d}/${_p_fn[_i]}"
    else
      put "${_p_fn[_i]}" "${_p_fc[_i]}"
    fi
  done
}

# ---------------------------------------------------------------------------------------------
# closeRefusalLeavesBothFilesUntouched (23 случая): отказ close не трогает список, архив, счётчик.
# cr <ключ> <номер> <подстрока stderr> [-f ИМЯ СОДЕРЖИМОЕ]… [-- аргументы close; по умолчанию OK]

b_cr() {
  local _argv=(close "${_p_num}") _a
  put summary $'Итог.\n'
  put empty $'\n'
  apply_files
  snap TODO.md DONE.md next
  for _a in "${_p_args[@]}"; do
    _argv+=("${_a//"{dir}"/"${_d}"}")
  done
  T "${_argv[@]}"
  code_is 1
  has_err "${_p_msg}"
  unchanged
}

cr() {
  _p_num="$2"
  _p_msg="$3"
  local _key="$1"
  shift 3
  parse_case "$@"
  [[ "${_p_has_args}" -eq 1 ]] || _p_args=("${OK[@]}")
  each_awk closeRefusalLeavesBothFilesUntouched "${_key}" b_cr
}

cr 'неизвестный номер' 42 'записи №42 нет'
cr 'номер есть только в блоке кода шапки' 99 'записи №99 нет'
cr 'сводный пункт со строкой без флажка' 5 '№5: строка без флажка'
cr 'запись уже в архиве' 3 'уже есть' \
  -f DONE.md "${DONE_HEAD}"$'### №3. Уже закрыта\n'"${CLOSED_OLD}${R3#"${H3}"}${DONE_LEGACY}"
cr 'архив без заголовка раздела' 3 'нет заголовка раздела' -f DONE.md $'# Архив\n\nБез раздела.\n'
cr 'пустой итог' 3 'итог пуст' -- --closed '2026-02-01, PR #10' --summary-file '{dir}/empty'
cr 'нет строки закрытия' 3 'нужен --closed' -- --summary-file '{dir}/summary'
cr 'строка закрытия не по формату' 3 '«Закрыто»' -- --closed 'когда-нибудь' --summary-file '{dir}/summary'
cr 'строка закрытия без номера PR' 3 '«Закрыто»' -- --closed '2026-02-01, PR #' --summary-file '{dir}/summary'
cr 'возврат каретки в строке закрытия' 3 'без управляющих символов' \
  -- --closed $'2026-02-01, PR #10\rподмена' --summary-file '{dir}/summary'
cr 'перевод строки в строке закрытия' 3 'без управляющих символов' \
  -- --closed $'2026-02-01, PR #10\n- **Итог:** чужой' --summary-file '{dir}/summary'
cr 'возврат каретки в итоге' 3 'в итоге управляющий символ' -f summary $'Сделано\rВСЁ ОТМЕНЕНО\n'
cr 'символ C1 в итоге' 3 'в итоге управляющий символ' -f summary $'Сделано\xc2\x9b2K\n'
swap $'- вложенный пункт\n' $'```\nкод без закрытия\n'
cr 'незакрытый блок кода в списке' 3 'не закрыт до конца файла' -f TODO.md "${_r}"
swap $'- вложенный пункт\n' $'## Подраздел\n- вложенный пункт\n'
cr 'заголовок раздела в тексте записи' 3 'после первой записи списка' -f TODO.md "${_r}"
sr "${R5}" '### №5. Сводный' '### №5 Сводный'
cr 'заголовок следующей записи без точки' 3 'не заголовок записи' -f TODO.md "${TODO_HEAD}${R3}${_r}${R7}"$'\n'
sr "${R5}" '### №5. Сводный' '### №05. Сводный'
cr 'номер следующей записи с ведущим нулём' 3 'не заголовок записи' -f TODO.md "${TODO_HEAD}${R3}${_r}${R7}"$'\n'
cr 'посторонний текст под первым заголовком архива' 3 'до первой записи — только пустые строки' \
  -f DONE.md "${DONE_HEAD}"$'Здесь лежат закрытые задачи.\n\n'"${DONE_LEGACY}"
cr 'блок кода под первым заголовком архива' 3 'до первой записи — только пустые строки' \
  -f DONE.md "${DONE_HEAD}"$'```\nпосторонний блок\n```\n\n'"${DONE_LEGACY}"
cr 'прежние записи архива без своего заголовка' 3 'нужен свой заголовок раздела' -f DONE.md "${DONE_HEAD}${LEGACY2}"
cr 'запись нового формата ниже раздела прежних' 7 'ниже раздела прежних записей' \
  -f DONE.md "${DONE_HEAD}${DONE_LEGACY}"$'\n'"${A3}" -f TODO.md "${T57}"
swap $'- **Тип:** задача\n' ''
cr 'запись не в формате' 3 'не в формате' -f TODO.md "${_r}"
cr 'список без завершающего перевода строки' 3 'не кончается переводом строки' \
  -f TODO.md "${TODO_HEAD}${R3}${R5}${R7}"

# ---------------------------------------------------------------------------------------------
# new.

t_new_appends() {
  put title $'Новая: путь C:\\dir & `код` / конец\n'
  put body $'Текст новой задачи с \\n и & и /.\n- пункт\n'
  new_args --related '№3'
  T "${_na[@]}"
  code_is 0
  same "${_out}" $'№8\n' stdout
  local _record=$'### №8. Новая: путь C:\\dir & `код` / конец\n'
  _record+=$'- **Приоритет:** высокий (владелец, 2026-02-01)\n- **Статус:** открыта\n- **Тип:** задача\n'
  _record+=$'- **Заведено:** 2026-02-01 — решение владельца\n- **Триаж v2:** не находка ревью\n- **Ревью:** high\n'
  _record+=$'- **Связано:** №3\n\nТекст новой задачи с \\n и & и /.\n- пункт\n'
  eq_file TODO.md "${TODO_HEAD}${R3}${R5}${R7}"$'\n\n'"${_record}"
  eq_file next $'9 # выдан №8 — Новая: путь C:\\dir & `код` / конец\n'
  eq_file DONE.md "${DONE_HEAD}${DONE_LEGACY}" 'new архив не трогает'
  T check
  code_is 0 'после new список проходит check'
}
each_awk newAppendsRecordAndRewritesCounter '' t_new_appends

# newRejectsInvalidInput (34 случая): отказ new не трогает список и счётчик.
# nr <ключ> <подстрока stderr> [-o ОПЦИЯ ЗНАЧЕНИЕ]… [-f ИМЯ СОДЕРЖИМОЕ]…
b_nr() {
  put title $'Название\n'
  put body $'Текст.\n'
  apply_files
  snap TODO.md next
  new_args "${_p_ov[@]}"
  T "${_na[@]}"
  code_is 1
  has_err "${_p_msg}"
  unchanged
}

nr() {
  _p_msg="$2"
  local _key="$1"
  shift 2
  parse_case "$@"
  each_awk newRejectsInvalidInput "${_key}" b_nr
}

nr 'приоритет без источника' '«Приоритет»' -o --priority 'высокий'
nr 'приоритет не из списка' '«Приоритет»' -o --priority 'срочный (владелец, 2026-02-01)'
nr 'пустой приоритет' 'поле «Приоритет» пустое' -o --priority ''
nr 'статус не из списка' '«Статус»' -o --status 'закрыта'
nr 'отложена без условия' '«Статус»' -o --status 'отложена до '
nr 'тип не из списка' '«Тип»' -o --type 'эпик'
nr 'заведено без даты' '«Заведено»' -o --created 'решение владельца'
nr 'заведено без источника' '«Заведено»' -o --created '2026-02-01'
nr 'заведено с пустым источником' '«Заведено»' -o --created '2026-02-01 — '
nr 'триаж не из списка' '«Триаж v2»' -o --triage 'баг'
nr 'ревью не с уровня' '«Ревью»' -o --review 'средний'
nr 'ревью — уровень слитно с текстом' '«Ревью»' -o --review 'highest'
nr 'связано не номерами' '«Связано»' -o --related 'задача 3'
nr 'название в две строки' 'одна строка' -f title $'Первая\nВторая\n'
nr 'пустое название' 'название пусто' -f title $'\n'
nr 'заголовок записи в тексте' 'заголовок первого–третьего уровня' -f body $'Текст.\n\n### №50. Чужая запись\n'
nr 'заголовок раздела в тексте' 'заголовок первого–третьего уровня' -f body $'## Раздел\n'
nr 'перевод строки в значении поля' 'без управляющих символов' -o --review $'low\n\n### №500. Вписанная'
nr 'заголовок раздела через значение поля' 'без управляющих символов' -o --related $'№3\n\n## Чужой раздел'
nr 'возврат каретки в значении поля' 'без управляющих символов' -o --status $'открыта\r'
nr 'символ C1 в значении поля' 'без управляющих символов' -o --status $'открыта\xc2\x9b2K'
nr 'триаж «не указан» у новой задачи' 'у новой задачи не ставится' -o --triage 'не указан'
nr 'приоритет с пустым источником' '«Приоритет»' -o --priority 'высокий ()'
nr 'приоритет с пробелом вместо источника' '«Приоритет»' -o --priority 'высокий ( )'
nr 'возврат каретки в названии' 'в названии управляющий символ' -f title $'Название\rподмена\n'
nr 'название из файла с CRLF' 'в названии управляющий символ' -f title $'Название\r\n'
nr 'символ C1 в названии' 'в названии управляющий символ' -f title $'Название\xc2\x9b2K\n'
nr 'незакрытый блок кода в тексте' 'не закрыт до конца файла' -f body $'Текст.\n```\nкод без закрытия\n'
nr 'заголовок третьего уровня без текста' 'заголовок первого–третьего уровня' -f body $'Текст.\n###\n'
nr 'строка «- **Задач…» в тексте задачи' 'переформулируйте строку' -f body $'Текст.\n- **Задача-минимум:** сделать.\n'
nr 'счётчик не в формате' 'не в формате' -f next $'8\n'
nr 'счётчик с ведущим нулём' 'не в формате' -f next $'08 # выдан №7 — Последняя задача\n'
nr 'счётчик не больше занятого номера' 'не больше наибольшего занятого номера' -f next $'7 # выдан №6 — Старая\n'
nr 'счётчик: следующий не равен выданному плюс один' 'плюс один' -f next $'9 # выдан №7 — Последняя задача\n'

t_new_fence() {
  put title $'Название\n'
  put body $'Пример:\n\n```markdown\n### №50. Пример\n```\n'
  new_args
  T "${_na[@]}"
  code_is 0
  T check
  code_is 0 check
}
each_awk newAcceptsHeadingInsideCodeFence '' t_new_fence

t_missing_counter() {
  put DONE.md "${DONE_HEAD}${DONE_LEGACY}"$'\n- **Задачи №11 и №12: закрыты вместе — ВЫПОЛНЕНЫ** (2026-01-01).\n'
  rm -f -- "${_d}/next"
  T next
  code_is 0
  same "${_out}" $'13\n' 'next: stdout'
  eq_file next $'13 # выдан №12 — восстановлено по наибольшему номеру\n'
  rm -f -- "${_d}/next"
  put DONE.md "${DONE_HEAD}${DONE_LEGACY}"
  put title $'Название\n'
  put body $'Текст.\n'
  new_args
  T "${_na[@]}"
  code_is 0 new
  same "${_out}" $'№8\n' 'new: stdout'
  eq_file next $'9 # выдан №8 — Название\n'
}
each_awk missingCounterIsRestoredFromBothFiles '' t_missing_counter

# ---------------------------------------------------------------------------------------------
# check.

t_check_passes() {
  put summary $'Итог.\n'
  T close 3 --closed '2026-02-01, PR #10' --summary-file "${_d}/summary"
  code_is 0 close
  T check
  code_is 0 check
  has "${_out}" 'наибольший номер — 7' stdout
}
each_awk checkPassesOnValidFiles '' t_check_passes

# checkReportsViolation (43 случая). cv <ключ> <подстрока stderr> [-f ИМЯ СОДЕРЖИМОЕ | -d ИМЯ]…
b_cv() {
  apply_files
  T check
  code_is 1
  has_err "${_p_msg}"
}

cv() {
  _p_msg="$2"
  local _key="$1"
  shift 2
  parse_case "$@"
  each_awk checkReportsViolation "${_key}" b_cv
}

swap $'- **Статус:** открыта\n' ''
cv 'нет поля' '№3: ожидается поле «Статус»' -f TODO.md "${_r}"
swap $'- **Ревью:** high\n- **Связано:** №5, №7\n' ''
cv 'нет последнего обязательного поля' '№3: нет поля «Ревью»' -f TODO.md "${_r}"
swap $'- **Статус:** открыта\n- **Тип:** задача\n' $'- **Тип:** задача\n- **Статус:** открыта\n'
cv 'поля не по порядку' '№3: ожидается поле «Статус»' -f TODO.md "${_r}"
swap '- **Статус:** открыта' '- **Статус:** закрыта'
cv 'недопустимый статус' '№3: «Статус»' -f TODO.md "${_r}"
swap 'низкий (по тексту пункта)' 'низкий'
cv 'приоритет без источника' '№3: «Приоритет»' -f TODO.md "${_r}"
swap '- **Тип:** задача' '- **Тип:** эпик'
cv 'недопустимый тип' '№3: «Тип»' -f TODO.md "${_r}"
swap '2026-01-01 — решение владельца' 'давно'
cv 'заведено без даты' '№3: «Заведено»' -f TODO.md "${_r}"
swap '- **Триаж v2:** дефект' '- **Триаж v2:** баг'
cv 'недопустимый триаж' '№3: «Триаж v2»' -f TODO.md "${_r}"
swap '- **Ревью:** high' '- **Ревью:** тщательное'
cv 'недопустимое ревью' '№3: «Ревью»' -f TODO.md "${_r}"
swap '№5, №7' '№5 и №7'
cv 'связано не номерами' '№3: «Связано»' -f TODO.md "${_r}"
swap $'- **Связано:** №5, №7\n' $'- **Связано:** №5, №7\n- **Ещё:** поле\n'
cv 'лишняя строка в блоке полей' '№3: лишняя строка' -f TODO.md "${_r}"
swap $'- **Связано:** №5, №7\n\n' $'- **Связано:** №5, №7\n'
cv 'нет пустой строки после полей' '№3: лишняя строка' -f TODO.md "${_r}"
t3 "${R3}${R3}"
cv 'повтор номера в списке' '№3: номер встречается больше одного раза' -f TODO.md "${_r}"
cv 'повтор номера между списком и архивом' '№3: номер встречается больше одного раза' \
  -f DONE.md "${DONE_HEAD}${A3}${DONE_LEGACY}"
cv 'сводный пункт в архиве со строкой без флажка' 'DONE.md:17: №5: строка без флажка' \
  -f TODO.md "${T37}" -f DONE.md "${DONE_HEAD}${ARCHIVED5}${DONE_LEGACY}"
sr "${ARCHIVED5}" '- **Строка сводного пункта.** Текст.' '- [ ] **Строка.** Текст.'
cv 'сводный пункт в архиве с открытой строкой' '№5: открытая строка' \
  -f TODO.md "${T37}" -f DONE.md "${DONE_HEAD}${_r}${DONE_LEGACY}"
cv 'открытая задача числится в архиве старого формата' '№7: открытая задача числится закрытой' \
  -f DONE.md "${DONE_HEAD}${DONE_LEGACY}"$'\n- **Задача №7: закрыта раньше — ВЫПОЛНЕНА** (2026-01-01).\n'
cv 'запись архива без строки закрытия' '№3: ожидается поле «Закрыто»' \
  -f DONE.md "${DONE_HEAD}${R3}${DONE_LEGACY}" -f TODO.md "${T57}"
swap $'- вложенный пункт\n' $'```\nкод без закрытия\n'
cv 'незакрытый блок кода' 'не закрыт до конца файла' -f TODO.md "${_r}"
swap $'- вложенный пункт\n' $'## Подраздел\n'
cv 'заголовок раздела после записи' 'после первой записи списка' -f TODO.md "${_r}"
swap $'- вложенный пункт\n' $'# Часть\n'
cv 'заголовок первого уровня после записи' 'после первой записи списка' -f TODO.md "${_r}"
swap '### №3. Первая задача' '### №3 Первая задача'
cv 'строка ### не запись' 'не заголовок записи' -f TODO.md "${_r}"
swap '### №3. Первая задача' '### №3.'
cv 'заголовок записи без названия' 'не заголовок записи' -f TODO.md "${_r}"
swap '### №3. Первая задача' '### №03. Первая задача'
cv 'номер с ведущим нулём' 'не заголовок записи' -f TODO.md "${_r}"
swap '### №3. Первая задача' $'### №3. Пер\rвая задача'
cv 'управляющий символ в заголовке' '№3: управляющий символ в заголовке' -f TODO.md "${_r}"
swap '- **Статус:** открыта' $'- **Статус:** открыта\x1b[2K'
cv 'управляющий символ в поле' '№3: управляющий символ в блоке полей' -f TODO.md "${_r}"
swap 'низкий (по тексту пункта)' 'низкий ()'
cv 'приоритет с пустым источником' '№3: «Приоритет»' -f TODO.md "${_r}"
sr "${R3}" "${H3}" "${H3}"$'- **Закрыто:** когда-нибудь\n- **Итог:** x\n'
cv 'строка закрытия не по формату' '№3: «Закрыто»' \
  -f DONE.md "${DONE_HEAD}${_r}${DONE_LEGACY}" -f TODO.md "${T57}"
cv 'запись нового формата ниже раздела прежних' 'ниже раздела прежних записей' \
  -f DONE.md "${DONE_HEAD}${DONE_LEGACY}"$'\n'"${A3}" -f TODO.md "${T57}"
cv 'второй заголовок раздела после записей архива' 'допустим один заголовок раздела' \
  -f DONE.md "${DONE_HEAD}${A3}"$'## Лишний раздел\n\n'"${DONE_LEGACY}" -f TODO.md "${T57}"
cv 'прежняя запись внутри записи нового формата' 'перед прежними записями нужен заголовок раздела' \
  -f DONE.md "${DONE_HEAD}${A3}${LEGACY2}" -f TODO.md "${T57}"
cv 'прежние записи под первым заголовком раздела' 'нужен свой заголовок раздела' -f DONE.md "${DONE_HEAD}${LEGACY2}"
swap $'- вложенный пункт\n' $'- **Задачи №1 и №2** связаны.\n'
cv 'строка «- **Задач…» в тексте открытой задачи' 'переформулируйте строку' -f TODO.md "${_r}"
cv 'посторонний текст под первым заголовком архива' 'до первой записи — только пустые строки' \
  -f DONE.md "${DONE_HEAD}"$'Здесь лежат закрытые задачи.\n\n'"${DONE_LEGACY}"
cv 'блок кода под первым заголовком архива' 'до первой записи — только пустые строки' \
  -f DONE.md "${DONE_HEAD}"$'```\nпосторонний блок\n- **Задача №40: в блоке**\n```\n\n'"${DONE_LEGACY}"
cv 'прежняя запись выше первого заголовка архива занимает номер' 'не больше наибольшего занятого (50)' \
  -f DONE.md $'# Архив\n\n- **Задача №50: старая запись — ВЫПОЛНЕНА** (2026-01-01).\n\n## Выполненные задачи\n\n'"${DONE_LEGACY}"
cv 'прежняя запись в архиве без заголовков занимает номер' 'не больше наибольшего занятого (50)' \
  -f DONE.md $'# Архив\n\n- **Задача №50: старая запись — ВЫПОЛНЕНА** (2026-01-01).\n'
cv 'запись архива со статусом открытой задачи' '№3: «Статус»: в архиве нужно «закрыта»' \
  -f DONE.md "${DONE_HEAD}${A3}${DONE_LEGACY}" -f TODO.md "${T57}"
cv 'счётчика нет' 'файла счётчика нет' -d next
cv 'счётчик не в формате' 'не в формате' -f next $'8 выдан 7\n'
cv 'счётчик в две строки' 'не одна строка' -f next $'8 # выдан №7 — Последняя задача\n9 # выдан №8 — Ещё\n'
cv 'счётчик не больше номера из списка' 'не больше наибольшего занятого' -f next $'7 # выдан №6 — Старая\n'
cv 'счётчик не больше номера из архива старого формата' 'не больше наибольшего занятого (12)' \
  -f DONE.md "${DONE_HEAD}${DONE_LEGACY}"$'\n- **Задачи №11 и №12 — ВЫПОЛНЕНЫ** (2026-01-01).\n'

# ---------------------------------------------------------------------------------------------
# refs и переносимость.

t_refs_boundary() {
  put notes.md $'см. №3.\nсм. №31 и №33\nв конце строки №3\nв скобках (№3)\n'
  T refs 3 "${_d}/notes.md"
  code_is 0
  trim "${_out}"
  same "${_r}" $'1:см. №3.\n3:в конце строки №3\n4:в скобках (№3)' stdout
}
once refsRespectsNumberBoundary t_refs_boundary

# В PHP — литералы проекта apps-b24-platform в тексте скрипта; здесь те же литералы (имя исходного
# проекта, artisan, вызов php): скрипт плагина не должен к ним возвращаться.
t_paths_from_options() {
  local _script
  slurp _script "${TODO_SH}"
  lacks "${_script}" 'apps-b24' 'текст скрипта'
  lacks "${_script}" 'artisan' 'текст скрипта'
  lacks "${_script}" 'php ' 'текст скрипта'
  _tfiles=(--todo "${_d}/missing.md")
  T check
  code_is 1
  has_err "нет файла списка: ${_d}/missing.md"
}
once pathsComeFromOptionsNotFromProjectLayout t_paths_from_options

t_numbers_inside_archived() {
  put summary $'Сделано, продолжение — PR №381, см. issue №500.\n'
  T close 3 --closed '2026-02-01, PR #10' --summary-file "${_d}/summary"
  code_is 0 close
  T check
  code_is 0 check
  T next
  same "${_out}" $'8\n' 'next: stdout'
}
each_awk numbersInsideArchivedRecordsAreNotOccupiedNumbers '' t_numbers_inside_archived

t_close_type_from_fields() {
  sr "${R3}" $'- вложенный пункт\n' $'- **Тип:** сводный\n- [ ] шаг плана после примера\n'
  put TODO.md "${TODO_HEAD}${_r}${R5}${R7}"$'\n'
  put summary $'Итог.\n'
  T close 3 --closed '2026-02-01, PR #10' --summary-file "${_d}/summary"
  code_is 0
  file_has DONE.md "${H3}${CLOSED_NEW}"
}
each_awk closeReadsTypeFromFieldBlockOnly '' t_close_type_from_fields

t_refused_new_counter() {
  rm -f -- "${_d}/next"
  put title $'Название\n'
  put body $'Текст.\n'
  snap TODO.md
  new_args --priority 'срочный'
  T "${_na[@]}"
  code_is 1
  _asserts=$((_asserts + 1))
  [[ -e "${_d}/next" || -L "${_d}/next" ]] && bad 'файл счётчика появился'
  unchanged
}
each_awk refusedNewDoesNotCreateMissingCounter '' t_refused_new_counter

t_symlinks() {
  put title $'Название\n'
  put body $'Текст.\n'
  rm -f -- "${_d}/next"
  ln -s "${_d}/planted" "${_d}/next"
  T next
  code_is 1 next
  has_err 'символическая ссылка' next
  _asserts=$((_asserts + 2))
  [[ -e "${_d}/planted" ]] && bad 'next: цель ссылки создана'
  new_args
  T "${_na[@]}"
  code_is 1 'new при ссылке-счётчике'
  [[ -e "${_d}/planted" ]] && bad 'new: цель ссылки создана'

  rm -f -- "${_d}/next"
  reset_fixture
  mv -- "${_d}/TODO.md" "${_d}/victim"
  ln -s "${_d}/victim" "${_d}/TODO.md"
  snap victim
  T "${_na[@]}"
  code_is 1 'new при ссылке-списке'
  has_err 'символическая ссылка' 'new при ссылке-списке'
  unchanged
}
each_awk symlinkedFilesAreRefused '' t_symlinks

t_relative_equals() {
  put title $'Название\n'
  put 'body=1.md' $'Текст.\n\n### №77. Подложная запись\n'
  new_args --body-file 'body=1.md'
  T "${_na[@]}"
  code_is 1 new
  has_err 'заголовок первого–третьего уровня' new
  put 't=1.md' "${TODO_HEAD}"$'### №5. Без полей\n\nТекст.\n'
  _tfiles=(--todo 't=1.md')
  T check
  code_is 1 check
  has_err '№5: нет поля «Приоритет»' check
}
each_awk relativePathWithEqualsSignIsReadAsFile '' t_relative_equals

t_ro_dir() {
  if [[ "${EUID}" -eq 0 ]]; then
    skip 'под root каталог без права записи не останавливает запись'
    return
  fi
  put summary $'Итог.\n'
  mkdir "${_d}/ro"
  cp -- "${_d}/TODO.md" "${_d}/ro/TODO.md"
  chmod 0555 "${_d}/ro"
  snap ro/TODO.md DONE.md
  _tfiles=(--todo "${_d}/ro/TODO.md")
  T close 3 --closed '2026-02-01, PR #10' --summary-file "${_d}/summary"
  chmod 0755 "${_d}/ro"
  code_is 1
  has_err 'файлы не изменены'
  unchanged
  _asserts=$((_asserts + 1))
  local _left
  _left="$(compgen -G "${_d}/.*.tmp.*")" || true
  [[ -z "${_left}" ]] || bad "временные файлы замены не убраны: ${_left//$'\n'/ }"
}
once closeTouchesNeitherFileWhenListCannotBeReplaced t_ro_dir

# В PHP — живой репозиторий apps-b24-platform, задача №96 и его CHANGELOG.md. Здесь — синтетический
# git-репозиторий: №96 упомянут только в CHANGELOG.md в корне, запуск — из подкаталога scripts/.
t_refs_repo() {
  if ! command -v git >/dev/null 2>&1; then
    skip 'git не установлен'
    return
  fi
  local _repo="${_d}/repo"
  mkdir -p "${_repo}/scripts"
  printf '# Изменения\n\n- Задача №96: заведение и закрытие задач.\n' >"${_repo}/CHANGELOG.md"
  printf 'без упоминаний\n' >"${_repo}/scripts/readme.txt"
  if ! (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
    cd "${_repo}" && git init -q . && git add -A
  ) >/dev/null 2>&1; then
    skip 'не удалось создать git-репозиторий'
    return
  fi
  (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
    cd "${_repo}/scripts" || exit 99
    PATH="${_awkpath}" exec timeout 60 bash "${TODO_SH}" refs 96
  ) >"${_io}/out" 2>"${_io}/err"
  _code=$?
  slurp _out "${_io}/out"
  slurp _err "${_io}/err"
  code_is 0
  has "${_out}" '../CHANGELOG.md:' stdout
}
once refsSearchesWholeRepositoryFromSubdirectory t_refs_repo

# ---------------------------------------------------------------------------------------------
# Большие файлы и первый раздел архива.

rep 'текст записи ' 40
rep $'\n- **Запись прежнего формата без номера — ВЫПОЛНЕНА** (2026-01-01).\n  '"${_r}"$'\n' 400
BIG_LEGACY="${DONE_LEGACY}${_r}"

t_close_big_archive() {
  _asserts=$((_asserts + 1))
  [[ ${#BIG_LEGACY} -gt 200000 ]] || bad "фикстура меньше 200 000 байт: ${#BIG_LEGACY}"
  put DONE.md "${DONE_HEAD}${BIG_LEGACY}"
  put summary $'Итог.\n'
  T close 3 --closed '2026-02-01, PR #10' --summary-file "${_d}/summary"
  code_is 0
  has "${_out}" '№3 перенесена' stdout
  local _f
  slurp _f "${_d}/DONE.md"
  _asserts=$((_asserts + 1))
  [[ "${_f}" == *"${BIG_LEGACY}" ]] || bad 'архив не кончается исходным хвостом'
  T check
  code_is 0 check
}
each_awk closeWorksOnArchiveLargerThanPipeBuffer '' t_close_big_archive

t_whitespace_line() {
  local _archives=(
    $'# Архив\n\nШапка архива.\n\n## Выполненные задачи\n  \t\n\n'"${DONE_LEGACY}"
    "${DONE_HEAD}"$'  \t\n\n'"${DONE_LEGACY}"
  )
  local _labels=('сразу за заголовком' 'после пустой строки') _i
  for _i in 0 1; do
    reset_fixture
    put DONE.md "${_archives[_i]}"
    put summary $'Итог.\n'
    T check
    code_is 0 "${_labels[_i]}: check до close"
    T close 3 --closed '2026-02-01, PR #10' --summary-file "${_d}/summary"
    code_is 0 "${_labels[_i]}: close"
    file_has DONE.md "${H3}${CLOSED_NEW}" "${_labels[_i]}"
    T check
    code_is 0 "${_labels[_i]}: check после close"
  done
}
each_awk whitespaceOnlyLineUnderFirstArchiveHeadingIsBlank '' t_whitespace_line

FIRST_SECTION_MSG='под первым заголовком раздела архива до первой записи — только пустые строки; записям прежнего формата нужен свой заголовок раздела (## …)'

t_code_fence_single_error() {
  put DONE.md "${DONE_HEAD}"$'```\n### №7. В блоке\n- **Задача №40: в блоке**\n```\n\n'"${DONE_LEGACY}"
  T check
  code_is 1
  same "${_err}" "${_d}/DONE.md:7: ${FIRST_SECTION_MSG}"$'\n' 'stderr целиком'
}
each_awk codeFenceUnderFirstArchiveHeadingGivesSingleError '' t_code_fence_single_error

t_inline_fence() {
  put DONE.md "${DONE_HEAD}"$'```x```\n\n'"${DONE_LEGACY}"$'\n- **Задача №50: старая запись — ВЫПОЛНЕНА** (2026-01-01).\n'
  T check
  code_is 1
  same "${_err}" "${_d}/DONE.md:7: ${FIRST_SECTION_MSG}"$'\n'"${_d}/next: следующий номер 8 не больше наибольшего занятого (50)"$'\n' \
    'stderr целиком'
}
each_awk inlineFenceLineUnderFirstArchiveHeadingDoesNotOpenBlock '' t_inline_fence

t_malformed_first() {
  put DONE.md "${DONE_HEAD}"$'### №02. С ведущим нулём\n\n'"${DONE_LEGACY}"
  T check
  code_is 1
  same "${_err}" "${_d}/DONE.md:7: строка «### …» — не заголовок записи (нужно «### №N. Название», номер без ведущих нулей)"$'\n' \
    'stderr целиком'
}
each_awk malformedFirstArchiveRecordHeadingKeepsItsOwnReason '' t_malformed_first

# Ссылки на чужой файл подложены под имена временных файлов с номером процесса скрипта: обёртка
# заменяет себя скриптом через exec, поэтому её $$ — это $$ скрипта.
t_planted_tmp() {
  put title $'Название\n'
  put body $'Текст.\n'
  put victim $'ЧУЖОЙ ФАЙЛ\n'
  # $1, $2, $$ раскрывает обёртка, а не стенд.
  local _wrapper='ln -s "$1" "$2/.TODO.md.tmp.$$" && ln -s "$1" "$2/.next.tmp.$$" && shift 2 && exec bash "$@"'
  new_args
  (
    cd "${_d}" || exit 99
    exec timeout 60 bash -c "${_wrapper}" wrapper "${_d}/victim" "${_d}" "${TODO_SH}" \
      --todo "${_d}/TODO.md" --done "${_d}/DONE.md" --counter "${_d}/next" "${_na[@]}"
  ) >"${_io}/out" 2>"${_io}/err"
  _code=$?
  slurp _err "${_io}/err"
  code_is 0
  eq_file victim $'ЧУЖОЙ ФАЙЛ\n'
  _asserts=$((_asserts + 2))
  [[ -L "${_d}/TODO.md" ]] && bad 'TODO.md стал символической ссылкой'
  [[ -L "${_d}/next" ]] && bad 'next стал символической ссылкой'
  file_has TODO.md '### №8. Название'
}
once plantedTempSymlinkIsNotFollowed t_planted_tmp

t_restored_counter_ctrl() {
  sr "${R7}" '### №7. Последняя задача' $'### №7. Послед\tняя задача'
  put TODO.md "${TODO_HEAD}${R3}${R5}${_r}"$'\n'
  rm -f -- "${_d}/next"
  T next
  code_is 0
  same "${_out}" $'8\n' stdout
  eq_file next $'8 # выдан №7 — восстановлено по наибольшему номеру\n'
  T next
  same "${_out}" $'8\n' 'повторный next принимает восстановленный счётчик'
}
each_awk restoredCounterNeverCarriesControlCharacters '' t_restored_counter_ctrl

# ---------------------------------------------------------------------------------------------
# Сводный пункт: перенос без открытых строк (6 случаев). cm <ключ> <текст пункта>

b_cm() {
  composite "${_p_body}"
  local _record="${_r}"
  put TODO.md "${TODO_HEAD}${R3}${_record}${R7}"$'\n'
  put summary $'Итог.\n'
  T close 5 --closed '2026-02-01, PR #10' --summary-file "${_d}/summary"
  code_is 0
  has_err '№5 был сводным пунктом' 'нет напоминания о перечне сводных и ссылках'
  has_err 'refs 5'
  eq_file TODO.md "${T37}"
  sr "${_record}" "${H5}" "${H5}${CLOSED_NEW}"$'- **Итог:** Итог.\n'
  cs "${_r}"
  eq_file DONE.md "${DONE_HEAD}${_r}${DONE_LEGACY}"
  file_has DONE.md $'- **Тип:** сводный\n'
  T check
  code_is 0 check
}

cm() {
  _p_body="$2"
  each_awk closeMovesCompositeWithoutOpenLines "$1" b_cm
}

cm 'все строки закрыты' $'Вводный абзац.\n'\
$'- [x] **✅ Сделано 2026-01-05, PR #3** *(PLAUSIBLE; ревью)* **Первая.** Путь `C:\\temp\\new` & знак /.\n'\
$'- [x] **❌ Снято 2026-01-06 (решение владельца)** *(улучшение, CONFIRMED)* **Вторая.** Текст\n  продолжение строки.\n'\
$'**Состояние.** Абзац после строк.\n'
cm 'без строк — только абзацы' $'Вводный абзац.\n\n**Состояние.** Строк нет.\n'
cm 'флажок в блоке кода, вложенные пункты без открытого флажка и продолжение' \
  $'- [x] **✅ Сделано 2026-01-05, PR #3** **Строка.** Текст:\n  - [x] вложенный закрытый\n\t- вложенный через табуляцию, без флажка\n  * вложенный со звёздочкой\n  продолжение после вложенных\n'\
$'\n```markdown\n- [ ] строка в блоке кода\n* [ ] звёздочка в блоке кода\n*(ревью)* абзац-находка в блоке кода\n```\n'
cm 'пометка: табуляция, два пробела, «**» внутри скобок и вторая «)*» дальше в строке' \
  $'*(Вывод ассистента, не решение:)*\tтекст пометки через табуляцию\n\n'\
$'*(Вывод ассистента, не решение:)*  текст пометки через два пробела\n\n'\
$'*(Вывод **ассистента**, не решение:)* текст пометки\n\n'\
$'*(Вывод ассистента, не решение:)* см. *(№87)*ниже\n'
cm 'абзацы с жирным началом и курсивом строками не считаются' \
  $'**Состояние на дату.** Абзац с жирного.\n*Курсив без скобки* в начале абзаца.\n1.5 — число в начале абзаца, не пункт списка.\n'\
$'- [x] **✅ Сделано 2026-01-05, PR #3** **Строка.** Текст.\n'
cm 'пометка «*(…)*» с обычным текстом после скобок — в середине абзаца и в его начале' \
  $'Абзац обычный, год\n2026-й, перенос без маркера\n'\
$'*(Вывод ассистента, не решение:)* после этого остаются строки\nпродолжение пометки.\n\n'\
$'*(Вывод ассистента, не решение:)* пометка в начале абзаца.\n'\
$'- [x] **❌ Снято 2026-01-06 (решение владельца)** **Строка.** Текст с упоминанием `- [ ]` и `**✅` в коде.\n'

# ---------------------------------------------------------------------------------------------
# Сводный пункт с открытой строкой (48 случаев). co <ключ> <текст пункта> <открытая строка> <причина>

b_co() {
  composite "${_p_body}"
  put TODO.md "${TODO_HEAD}${R3}${_r}${R7}"$'\n'
  put summary $'Итог.\n'
  snap TODO.md DONE.md next
  _asserts=$((_asserts + 1))
  if ! line_no "${_d}/TODO.md" "${_p_line}"; then
    bad 'строка фикстуры не найдена'
    return
  fi
  local _n="${_r}"
  T close 5 --closed '2026-02-01, PR #10' --summary-file "${_d}/summary"
  code_is 1
  has_err "TODO.md:${_n}: №5: ${_p_reason}"
  has_err 'незакрытых строк: 1'
  has_err 'только по решению владельца'
  has_err 'всего текста пункта'
  has_err 'Открытую находку записывают строкой «- [ ] …»; закрытую строку — «- [x] **✅ Сделано …**» (или «**❌ Снято …**») сразу после флажка'
  has_err 'Находка это, пометка или перенос абзаца — решается в сверке с владельцем, до правки текста'
  lacks_err 'переформулир'
  unchanged
}

co() {
  _p_body="$2"
  _p_line="$3"
  _p_reason="$4"
  each_awk closeRefusesCompositeWithOpenLine "$1" b_co
}

R_X='флажок [x] без отметки «**✅ …**» или «**❌ …**»'
R_MARK='пункт списка с маркером не «- »'
R_PAREN='строка с «*(» вне строки сводного пункта'
R_NEST='вложенный открытый флажок под закрытой строкой'
R_INDENT='пункт списка с отступом вне строки сводного пункта'

co 'флажок не поставлен' "${DN}"$'\n- [ ] **Открытая.** Текст.\n' '- [ ] **Открытая.** Текст.' 'открытая строка'
co 'строка без флажка' "${DN}"$'\n- **Прежняя.** Текст.\n' '- **Прежняя.** Текст.' 'строка без флажка'
co 'строка без флажка с отметкой в тексте' $'- **Прежняя.** Текст. **✅ Сделано 2026-01-05, PR #3**\n'"${DN}"$'\n' \
  '- **Прежняя.** Текст. **✅ Сделано 2026-01-05, PR #3**' 'строка без флажка'
co 'флажок без отметки, отметка у соседней строки' $'- [x] **Без основания.** Текст.\n'"${DN}"$'\n' \
  '- [x] **Без основания.** Текст.' "${R_X}"
co 'флажок без отметки, отметка обычным текстом без звёздочек' $'- [x] **Обычным текстом.** Текст. ✅ Сделано 2026-01-05, PR #3\n' \
  '- [x] **Обычным текстом.** Текст. ✅ Сделано 2026-01-05, PR #3' "${R_X}"
co 'отметка только в продолжении строки' $'- [x] **Многострочная.** Текст первой строки\n  продолжение. **✅ Сделано 2026-01-05, PR #3**\n' \
  '- [x] **Многострочная.** Текст первой строки' "${R_X} сразу после флажка"
co 'отметка только у вложенного пункта' $'- [x] **Родитель.** Текст:\n  - [x] часть **✅ Сделано 2026-01-05, PR #3**\n' \
  '- [x] **Родитель.** Текст:' "${R_X} сразу после флажка"
co 'флажок без отметки, отметка в абзаце ниже' $'- [x] **Без основания.** Текст.\n**Состояние.** Абзац. **✅ Сделано 2026-01-05, PR #3**\n' \
  '- [x] **Без основания.** Текст.' 'флажок [x] без отметки'
co 'открытая строка после блока кода' "${DN}"$'\n\n```\n- [ ] в блоке кода\n```\n\n- [ ] **После блока.** Текст.\n' \
  '- [ ] **После блока.** Текст.' 'открытая строка'
co 'пункт со звёздочкой' "${DN}"$'\n* [ ] **Звёздочка.** Текст.\n' '* [ ] **Звёздочка.** Текст.' "${R_MARK}"
co 'пункт с плюсом' "${DN}"$'\n+ [x] **Плюс.** **✅ Сделано 2026-01-05, PR #3**\n' '+ [x] **Плюс.** **✅ Сделано 2026-01-05, PR #3**' "${R_MARK}"
co 'нумерованный пункт' "${DN}"$'\n1. [ ] **Нумерованный.** Текст.\n' '1. [ ] **Нумерованный.** Текст.' "${R_MARK}"
co 'дефис и табуляция' "${DN}"$'\n-\t[ ] **Табуляция.** Текст.\n' $'-\t[ ] **Табуляция.** Текст.' "${R_MARK}"
co 'находка абзацем' "${DN}"$'\n*(ревью `xhigh` ветки `fix/x`, проход 1, 2026-01-05)* **PLAUSIBLE:** текст находки.\n' \
  '*(ревью `xhigh` ветки `fix/x`, проход 1, 2026-01-05)* **PLAUSIBLE:** текст находки.' "${R_PAREN}"
co 'вложенный открытый флажок под закрытой строкой' $'- [x] **✅ Сделано 2026-01-05, PR #3** **Часть сделана.** Текст.\n  - [ ] остаток не сделан\n' \
  '  - [ ] остаток не сделан' "${R_NEST}"
co 'вложенный открытый флажок с одним пробелом и звёздочкой' $'- [x] **✅ Сделано 2026-01-05, PR #3** **Часть сделана.** Текст.\n * [ ] остаток не сделан\n' \
  ' * [ ] остаток не сделан' "${R_NEST}"
co 'вложенный открытый флажок с плюсом' $'- [x] **✅ Сделано 2026-01-05, PR #3** **Часть.** Текст.\n  + [ ] остаток с плюсом\n' \
  '  + [ ] остаток с плюсом' "${R_NEST}"
co 'вложенный открытый флажок с номером и точкой' $'- [x] **✅ Сделано 2026-01-05, PR #3** **Часть.** Текст.\n  1. [ ] остаток нумерованный\n' \
  '  1. [ ] остаток нумерованный' "${R_NEST}"
co 'вложенный открытый флажок с номером и скобкой' $'- [x] **✅ Сделано 2026-01-05, PR #3** **Часть.** Текст.\n\t2) [ ] остаток со скобкой\n' \
  $'\t2) [ ] остаток со скобкой' "${R_NEST}"
co 'отметка в конце однострочной строки, не сразу после флажка' $'- [x] **В конце.** Текст. **✅ Сделано 2026-01-05, PR #3**\n' \
  '- [x] **В конце.** Текст. **✅ Сделано 2026-01-05, PR #3**' "${R_X} сразу после флажка"
co 'упоминание отметки в коде текста находки — не отметка' $'- [x] **Правило.** отметка `**✅` обязательна сразу после флажка\n' \
  '- [x] **Правило.** отметка `**✅` обязательна сразу после флажка' "${R_X} сразу после флажка"
co 'флажок со звёздочкой сразу после строки абзаца' "${DN}"$'\n**Остаток после аудита:**\n* [ ] открытая под абзацем без пустой строки\n' \
  '* [ ] открытая под абзацем без пустой строки' "${R_MARK}"
co 'нумерованный флажок в переносе абзаца' "${DN}"$'\nАбзац обычный\n2. [x] закрытый с виду\n' '2. [x] закрытый с виду' "${R_MARK}"
co 'пункт со звёздочкой без флажка после пустой строки' "${DN}"$'\n\n* находка маркером-звёздочкой\n' \
  '* находка маркером-звёздочкой' "${R_MARK}"
co 'пункт без флажка сразу после строки, перед которой шёл абзац' $'Абзац обычный.\n'"${DN}"$'\n+ находка после абзаца и строки\n' \
  '+ находка после абзаца и строки' "${R_MARK}"
co 'нумерованный пункт сразу под вводной строкой' "${DN}"$'\n\n**Остаток (открыто):**\n1. Новый шаблон не сделан\n' \
  '1. Новый шаблон не сделан' "${R_MARK}"
co 'пункт со скобкой после номера в середине абзаца' "${DN}"$'\nОстаток:\n2) тест не написан\n' '2) тест не написан' "${R_MARK}"
co 'перенос абзаца, начавшийся с числа и точки, — тоже отказ' "${DN}"$'\nАбзац обычный, год\n2026. перенос абзаца с числа\n' \
  '2026. перенос абзаца с числа' "${R_MARK}"
co 'находка абзацем, жирное перенесено на следующую строку' \
  "${DN}"$'\n\n*(ревью `high` ветки `feat/x`, проход 1, 2026-01-05; найдено при приёмке)*\n**PLAUSIBLE:** находка.\n' \
  '*(ревью `high` ветки `feat/x`, проход 1, 2026-01-05; найдено при приёмке)*' "${R_PAREN}"
co 'находка абзацем, два пробела перед жирным' "${DN}"$'\n\n*(ревью)*  **PLAUSIBLE:** текст\n' '*(ревью)*  **PLAUSIBLE:** текст' "${R_PAREN}"
co 'находка абзацем, жирное вплотную к скобке' "${DN}"$'\n\n*(ревью)***PLAUSIBLE:** текст\n' '*(ревью)***PLAUSIBLE:** текст' "${R_PAREN}"
co 'находка абзацем, двоеточие между скобкой и жирным' "${DN}"$'\n\n*(ревью)*: **PLAUSIBLE** текст\n' '*(ревью)*: **PLAUSIBLE** текст' "${R_PAREN}"
co 'находка абзацем, тире между скобкой и жирным' "${DN}"$'\n\n*(ревью)* — **PLAUSIBLE:** текст\n' '*(ревью)* — **PLAUSIBLE:** текст' "${R_PAREN}"
co 'текст вплотную к закрывающей скобке — не пометка' "${DN}"$'\n\n*(ревью)*находка без пробела\n' '*(ревью)*находка без пробела' "${R_PAREN}"
co 'курсив сразу после скобок — не пометка' "${DN}"$'\n\n*(ревью)* *PLAUSIBLE* находка курсивом\n' \
  '*(ревью)* *PLAUSIBLE* находка курсивом' "${R_PAREN}"
co 'находка абзацем, пробелы в конце строки и жирное на следующей' "${DN}"$'\n\n*(ревью high, проход 1)*  \n**PLAUSIBLE:** находка.\n' \
  '*(ревью high, проход 1)*  ' "${R_PAREN}"
co 'находка абзацем, два пробела и курсив' "${DN}"$'\n\n*(ревью)*  *PLAUSIBLE* находка\n' '*(ревью)*  *PLAUSIBLE* находка' "${R_PAREN}"
co 'находка вплотную к первой скобке, дальше в строке вторая «)*»' "${DN}"$'\n\n*(ревью)*находка без пробела (см. №87)* и хвост\n' \
  '*(ревью)*находка без пробела (см. №87)* и хвост' "${R_PAREN}"
co 'звёздочка и табуляция под вводной строкой' "${DN}"$'\n\n**Остаток (открыто):**\n*\tне сделано\n' $'*\tне сделано' "${R_MARK}"
co 'номер, точка и табуляция под вводной строкой' "${DN}"$'\n\n**Остаток (открыто):**\n1.\tне сделано\n' $'1.\tне сделано' "${R_MARK}"
co 'пометка с жирным дальше в той же строке — отказ' "${DN}"$'\n\n*(Вывод ассистента, не решение:)* см. (№87)* **важно**\n' \
  '*(Вывод ассистента, не решение:)* см. (№87)* **важно**' "${R_PAREN}"
co 'пункт без флажка после абзаца и пустой строки' "${DN}"$'\nАбзац обычный.\n\n1. находка нумерованным пунктом\n' \
  '1. находка нумерованным пунктом' "${R_MARK}"
co 'пункт с плюсом без флажка сразу после строки' "${DN}"$'\n+ находка сразу после строки\n' '+ находка сразу после строки' "${R_MARK}"
co 'находка абзацем в середине абзаца, без пустой строки' \
  "${DN}"$'\nАбзац, кончающийся точкой.\n*(ревью `xhigh` ветки `fix/x`, проход 1, 2026-01-05)* **PLAUSIBLE:** (8) находка.\n' \
  '*(ревью `xhigh` ветки `fix/x`, проход 1, 2026-01-05)* **PLAUSIBLE:** (8) находка.' "${R_PAREN}"
co 'находка абзацем, скобка не закрыта в первой строке' "${DN}"$'\n\n*(ревью `xhigh` ветки `fix/x`,\nпроход 1, 2026-01-05)* **PLAUSIBLE:** находка.\n' \
  '*(ревью `xhigh` ветки `fix/x`,' "${R_PAREN}"
co 'пункт с отступом под абзацем' "${DN}"$'\n**Остаток после аудита:**\n  - [ ] под абзацем\n' '  - [ ] под абзацем' "${R_INDENT}"
co 'пункт с отступом после пустой строки' "${DN}"$'\n\n    - без флажка, после пустой строки\n' \
  '    - без флажка, после пустой строки' "${R_INDENT}"
co 'заглавная буква во флажке — не флажок' "${DN}"$'\n- [X] **Иначе.** Текст. **✅ Сделано 2026-01-05, PR #3**\n' \
  '- [X] **Иначе.** Текст. **✅ Сделано 2026-01-05, PR #3**' 'строка без флажка'

# ---------------------------------------------------------------------------------------------
# Сводный пункт: перечень открытых строк, прежняя форма, табуляция, управляющие символы.

t_lists_every_open_line() {
  local _long
  rep 'щ' 200
  _long="- [ ] **Длинная.** z${_r}"
  composite $'- [ ] **Первая.** Текст.\n- [x] **❌ Снято 2026-01-05** **Закрытая.**\n- **Вторая.** Текст.\n'"${_long}"$'\n'
  put TODO.md "${TODO_HEAD}${_r}${R7}"$'\n'
  put summary $'Итог.\n'
  local _n1 _n2 _n3
  line_no "${_d}/TODO.md" '- [ ] **Первая.** Текст.'
  _n1="${_r}"
  line_no "${_d}/TODO.md" '- **Вторая.** Текст.'
  _n2="${_r}"
  line_no "${_d}/TODO.md" "${_long}"
  _n3="${_r}"
  T close 5 --closed '2026-02-01, PR #10' --summary-file "${_d}/summary"
  code_is 1
  has_err "TODO.md:${_n1}: №5: открытая строка: - [ ] **Первая.** Текст."
  has_err "TODO.md:${_n2}: №5: строка без флажка"
  has_err "TODO.md:${_n3}: №5: открытая строка: - [ ] **Длинная.** zщщ"
  lacks_err 'Закрытая'
  rep 'щ' 100
  lacks_err "${_r}" 'длинная строка не обрезана'
  _asserts=$((_asserts + 1))
  # mb_check_encoding: сообщение — правильный UTF-8 (обрезка не разорвала символ).
  iconv -f UTF-8 -t UTF-8 -- "${_io}/err" >/dev/null 2>&1 || bad 'сообщение разорвало символ (не UTF-8)'
  has_err 'незакрытых строк: 3'
}
each_awk closeRefusalListsEveryOpenLine '' t_lists_every_open_line

t_legacy_shaped() {
  local _body=$'**(а) Часть первая.** Вводный абзац.\n'
  _body+=$'- [x] **(а) Робот от системного пользователя.** Описание части\n  на несколько строк.\n  **✅ Проверка на портале пройдена 2026-01-04** — подробности.\n  PLAUSIBLE (1): находка внутри продолжения, не сделана.\n'
  _body+=$'- [x] **❌ Снято 2026-01-05 (решение владельца)** **(г) Закрыта без реализации.** Текст\n  продолжение.\n'
  _body+=$'Связано: абзац без маркера.\n\n'
  _body+=$'*(ревью `xhigh` ветки `fix/x`, проход 1, 2026-01-06)* **PLAUSIBLE:** (8) находка абзацем.\n'
  composite "${_body}"
  put TODO.md "${TODO_HEAD}${R3}${_r}${R7}"$'\n'
  put summary $'Итог.\n'
  snap TODO.md DONE.md
  T close 5 --closed '2026-02-01, PR #10' --summary-file "${_d}/summary"
  code_is 1
  has_err 'сразу после флажка: - [x] **(а) Робот'
  has_err "${R_PAREN}"
  lacks_err '(г) Закрыта' 'правильно закрытая строка в перечне'
  has_err 'незакрытых строк: 2'
  unchanged
}
each_awk flagsAloneDoNotCloseLegacyShapedComposite '' t_legacy_shaped

t_open_last_line() {
  local _lasts=(
    $'- [ ] **Открытая последней.** Текст.\n'
    $'- [x] **Без отметки.** Текст\n  продолжение в конце файла\n'
    $'- **Без флажка.** Текст.\n'
  )
  local _last _s
  for _last in "${_lasts[@]}"; do
    reset_fixture
    composite $'- [x] **✅ Сделано 2026-01-05, PR #3** **Закрытая.**\n'"${_last}"
    _s="${_r}"
    while [[ "${_s}" == *$'\n' ]]; do _s="${_s%$'\n'}"; done
    put TODO.md "${TODO_HEAD}${R3}${_s}"$'\n'
    put summary $'Итог.\n'
    snap TODO.md
    T close 5 --closed '2026-02-01, PR #10' --summary-file "${_d}/summary"
    short "${_last}"
    code_is 1 "${_sh}"
    has_err 'незакрытых строк: 1' "${_sh}"
    unchanged
  done
}
each_awk openLastLineOfLastCompositeIsReported '' t_open_last_line

t_plain_below_composite() {
  local _composite _plain
  composite $'- [x] **✅ Сделано 2026-01-05, PR #3** **Закрытая.**\n'
  sr "${_r}" "${H5}" "${H5}${CLOSED_OLD}"
  cs "${_r}"
  _composite="${_r}"
  sr "${R3}" "${H3}" "${H3}"$'- **Закрыто:** 2026-01-04, PR #1\n- **Итог:** x\n'
  sr "${_r}" $'- вложенный пункт\n' $'- [ ] шаг плана\n- [x] шаг без отметки\n* звёздочка\n'
  cs "${_r}"
  _plain="${_r}"
  put TODO.md "${TODO_HEAD}${R7}"$'\n'
  put DONE.md "${DONE_HEAD}${_composite}${_plain}${DONE_LEGACY}"
  T check
  code_is 0
}
each_awk plainTaskBelowArchivedCompositeIsNotJudged '' t_plain_below_composite

t_tab_spelled_out() {
  composite $'-\tтаб вместо пробела\n\n- [x] **✅ Сделано 2026-01-05, PR #3** **Часть.**\n\t- [ ] вложенный с табуляцией\n'
  put TODO.md "${TODO_HEAD}${_r}${R7}"$'\n'
  put summary $'Итог.\n'
  T close 5 --closed '2026-02-01, PR #10' --summary-file "${_d}/summary"
  code_is 1
  has_err "${R_MARK}: -<TAB>таб вместо пробела"
  has_err "${R_NEST}: <TAB>- [ ] вложенный с табуляцией"
  lacks_err $'\t' 'табуляция в сообщении'
}
each_awk tabIsSpelledOutInRefusal '' t_tab_spelled_out

t_list_under_intro() {
  local _lists=(
    $'1. Новый шаблон не сделан\n2. Тест не написан\n'
    $'* не сделано\n+ ещё не сделано\n'
    $'1) первое\n   продолжение пункта\n2) второе\n'
  )
  local _list _rest _count _label
  for _list in "${_lists[@]}"; do
    reset_fixture
    composite $'- [x] **✅ Сделано 2026-01-05, PR #3** **Закрытая.**\n\n**Остаток (открыто):**\n'"${_list}"
    put TODO.md "${TODO_HEAD}${_r}${R7}"$'\n'
    put summary $'Итог.\n'
    snap TODO.md
    T close 5 --closed '2026-02-01, PR #10' --summary-file "${_d}/summary"
    short "${_list}"
    _label="${_sh}"
    code_is 1 "${_label}"
    has_err 'незакрытых строк: 2' "${_label}"
    # substr_count: вхождения причины — по разнице длин (LC_ALL=C — длина в байтах).
    _rest="${_err//"${R_MARK}"/}"
    _count=$(((${#_err} - ${#_rest}) / ${#R_MARK}))
    same "${_count}" 2 "${_label}: число «${R_MARK}»"
    unchanged
  done
}
each_awk listUnderIntroLineIsReportedItemByItem '' t_list_under_intro

t_no_ctrl_in_refusal() {
  local _line=$'- [ ] дело\r\x1b[2K№5 перенесена в архив\x1b[8m \xc2\x9b2K конец' _archived
  composite "${_line}"$'\n'
  sr "${_r}" "${H5}" "${H5}${CLOSED_OLD}"
  cs "${_r}"
  _archived="${_r}"
  composite "${_line}"$'\n'
  put TODO.md "${TODO_HEAD}${R3}${_r}${R7}"$'\n'
  put summary $'Итог.\n'
  T close 5 --closed '2026-02-01, PR #10' --summary-file "${_d}/summary"
  code_is 1 close
  has_err 'открытая строка: - [ ] дело??[2K№5 перенесена в архив?[8m ?2K конец' close
  no_ctrl "${_io}/err" close
  put TODO.md "${T37}"
  put DONE.md "${DONE_HEAD}${_archived}${DONE_LEGACY}"
  T check
  code_is 1 check
  has_err 'открытая строка: - [ ] дело??[2K' check
  no_ctrl "${_io}/err" check
}
each_awk refusalNeverPrintsControlCharactersFromRecordText '' t_no_ctrl_in_refusal

t_plain_task_checkboxes() {
  sr "${R3}" $'- вложенный пункт\n' $'- [ ] шаг плана\n- [x] шаг без отметки\n'
  put TODO.md "${TODO_HEAD}${_r}${R5}${R7}"$'\n'
  put summary $'Итог.\n'
  T close 3 --closed '2026-02-01, PR #10' --summary-file "${_d}/summary"
  code_is 0
  lacks_err 'сводным пунктом' 'напоминание — только для сводного пункта'
  file_has DONE.md $'- [ ] шаг плана\n'
  T check
  code_is 0 check
}
each_awk closeOfPlainTaskIgnoresCheckboxLines '' t_plain_task_checkboxes

rep 'текст строки ' 30
rep '- [x] **✅ Сделано 2026-01-05, PR #3** **Строка.** '"${_r}"$'\n' 500
BIG_CLOSED="${_r}"

t_big_composite() {
  _asserts=$((_asserts + 1))
  [[ ${#BIG_CLOSED} -gt 200000 ]] || bad "фикстура меньше 200 000 байт: ${#BIG_CLOSED}"
  sr "${BIG_CLOSED}" '- [x] ' '- [ ] '
  composite "${_r}"
  put TODO.md "${TODO_HEAD}${_r}${R7}"$'\n'
  put summary $'Итог.\n'
  T close 5 --closed '2026-02-01, PR #10' --summary-file "${_d}/summary"
  code_is 1 отказ
  _asserts=$((_asserts + 1))
  [[ ${#_err} -gt 70000 ]] || bad "перечень строк должен быть больше буфера канала: ${#_err} байт"
  has_err 'незакрытых строк: 500' отказ
  composite "${BIG_CLOSED}"
  put TODO.md "${TODO_HEAD}${_r}${R7}"$'\n'
  T close 5 --closed '2026-02-01, PR #10' --summary-file "${_d}/summary"
  code_is 0 перенос
  has "${_out}" '№5 перенесена' 'перенос: stdout'
  T check
  code_is 0 check
}
each_awk closeCompositeLargerThanPipeBuffer '' t_big_composite

# В CI тесты обязаны идти и под mawk (awk узлов Ubuntu): без этой проверки раннер без mawk молча
# оставил бы один системный вариант.
t_ci_mawk() {
  if [[ -z "${CI:-}" ]]; then
    skip 'вне CI набор awk зависит от машины разработчика'
    return
  fi
  _asserts=$((_asserts + 1))
  [[ " ${_awk_names[*]} " == *' mawk '* ]] || bad 'в CI нет mawk — прогон под mawk не выполняется'
}
once ciRunsScriptUnderMawk t_ci_mawk

# ---------------------------------------------------------------------------------------------
# Дополнения плагина — случаи, которых нет в PHP (пробелы R1 и Q4 со стороны close, ранний выход поиска в check,
# управляющие символы в выводе refs). В учёт
# 187 случаев PHP они не входят: имя начинается с «plugin:».

_extra=0

# plugin_case <имя> <функция> — случай под каждым выбранным вариантом awk, вне учёта PHP.
plugin_case() {
  local _i
  for _i in "${!_sel_names[@]}"; do
    _awk="${_sel_names[_i]}"
    _awkpath="${_sel_paths[_i]}"
    _case="plugin:$1"
    _extra=$((_extra + 1))
    begin
    "$2"
    finish
  done
}

# R1 для close: заранее подложенные ссылки на предсказуемых именах временных файлов списка и архива
# (прежняя редакция брала имя от $$) не должны вести запись в чужой файл.
t_planted_tmp_close() {
  put summary $'Итог.\n'
  put victim $'ЧУЖОЙ ФАЙЛ\n'
  # $1, $2, $$ раскрывает обёртка, а не стенд.
  local _wrapper='ln -s "$1" "$2/.DONE.md.tmp.$$" && ln -s "$1" "$2/.TODO.md.tmp.$$" && shift 2 && exec bash "$@"'
  (
    cd "${_d}" || exit 99
    exec timeout 60 bash -c "${_wrapper}" wrapper "${_d}/victim" "${_d}" "${TODO_SH}" \
      --todo "${_d}/TODO.md" --done "${_d}/DONE.md" --counter "${_d}/next" \
      close 3 --closed '2026-02-01, PR #10' --summary-file "${_d}/summary"
  ) >"${_io}/out" 2>"${_io}/err"
  _code=$?
  slurp _err "${_io}/err"
  code_is 0
  eq_file victim $'ЧУЖОЙ ФАЙЛ\n'
  _asserts=$((_asserts + 2))
  [[ -L "${_d}/TODO.md" ]] && bad 'TODO.md стал символической ссылкой'
  [[ -L "${_d}/DONE.md" ]] && bad 'DONE.md стал символической ссылкой'
  file_has DONE.md '### №3. Первая задача'
}
plugin_case closePlantedTempSymlinkIsNotFollowed t_planted_tmp_close

# Q4 для close: запись, в тексте которой строка «- **Задач…» (её не заведёт new и назовёт check), close
# тоже не переносит — отказ с названием строки, файлы не меняются.
t_close_legacy_line_in_record() {
  sr "${R3}" '**Первая задача.**' $'**Первая задача.**\n- **Задача-минимум:** сделать.'
  put TODO.md "${TODO_HEAD}${_r}${R5}${R7}"$'\n'
  put summary $'Итог.\n'
  snap TODO.md DONE.md next
  T close 3 --closed '2026-02-01, PR #10' --summary-file "${_d}/summary"
  code_is 1
  # Отказ — от разбора списка до сборки архива, а не от самопроверки собранного архива.
  has_err 'в тексте задачи выглядит как запись прежнего формата архива'
  lacks_err 'самопроверка'
  unchanged
}
plugin_case closeRefusesLegacyLineInRecordText t_close_legacy_line_in_record

# check при большом разделе прежних записей: номер открытой задачи среди них (первой строкой раздела, дальше —
# больше буфера канала) называется, а не теряется из-за раннего выхода поиска.
t_check_large_legacy() {
  local _k _legacy=$'## Закрытые до формата (прежний вид)\n\n- **Задача №3: тоже открыта** (2026-01-01).\n'
  for ((_k = 0; _k < 60000; _k++)); do
    _legacy+=$'- **Задача №1: старая** (2026-01-01).\n'
  done
  put DONE.md "${DONE_HEAD}${_legacy}"
  T check
  code_is 1
  has_err '№3: открытая задача числится закрытой'
}
plugin_case checkFindsOpenTaskInLargeLegacySection t_check_large_legacy

# refs не выводит управляющие символы из найденных строк (ESC, BEL) — они меняли бы вывод терминала: ни при
# поиске по путям, ни при поиске по git-репозиторию (без путей).
t_refs_ctrl() {
  mkdir "${_d}/notes"
  printf 'см. №3 \033]0;окно\007 и \033[31mкрасный\033[0m\n' >"${_d}/notes/n.md"
  T refs 3 "${_d}/notes"
  code_is 0 'по путям'
  has "${_out}" 'см. №3' 'по путям'
  lacks "${_out}" $'\033' 'ESC в выводе refs по путям'
  lacks "${_out}" $'\007' 'BEL в выводе refs по путям'
  if ! git -C "${_d}" init -q 2>/dev/null || ! git -C "${_d}" add notes/n.md 2>/dev/null; then
    bad 'не удалось создать git-репозиторий фикстуры'
    return
  fi
  T refs 3
  code_is 0 'по git'
  has "${_out}" 'см. №3' 'по git'
  lacks "${_out}" $'\033' 'ESC в выводе refs по git'
  lacks "${_out}" $'\007' 'BEL в выводе refs по git'
}
plugin_case refsReplacesControlCharacters t_refs_ctrl

# ---------------------------------------------------------------------------------------------
# Итог. Полный набор (без TODO_AWKS) обязан учесть все 187 случаев и 38 методов PHP: потерянный
# или задвоенный случай — падение стенда, а не расхождение в таблице.

if [[ -n "${TODO_CASES_FILE:-}" ]]; then
  printf '%s\n' "${_case_list[@]}" >"${TODO_CASES_FILE}"
fi
if [[ -z "${TODO_AWKS:-}" ]]; then
  if [[ "${_cases}" -ne 187 || "${_methods}" -ne 38 ]]; then
    _fail=$((_fail + 1))
    printf 'FAIL учёт: случаев PHP %s (нужно 187), методов %s (нужно 38)\n' "${_cases}" "${_methods}"
  fi
fi
# Случаи плагина: 4 метода под каждым выбранным вариантом awk — выпавший случай виден и здесь.
if [[ "${_extra}" -ne $((4 * ${#_sel_names[@]})) ]]; then
  _fail=$((_fail + 1))
  printf 'FAIL учёт: проверок плагина %s (нужно %s: 4 метода × %s awk)\n' "${_extra}" "$((4 * ${#_sel_names[@]}))" "${#_sel_names[@]}"
fi
if [[ ${#_failed[@]} -gt 0 ]]; then
  printf 'Упавшие проверки (%s):\n' "${#_failed[@]}"
  printf '  %s\n' "${_failed[@]}"
fi
_skip_text='нет'
if [[ ${#_skips[@]} -gt 0 ]]; then
  _skip_text="$(printf '%s; ' "${_skips[@]}")"
  _skip_text="${_skip_text%; }"
fi
printf 'pass=%s fail=%s (проверок: %s; случаев PHP: %s; методов: %s; проверок плагина: %s; ассертов: %s; awk: %s; пропуски: %s)\n' \
  "${_pass}" "${_fail}" "$((_pass + _fail))" "${_cases}" "${_methods}" "${_extra}" "${_asserts}" "${_sel_names[*]}" "${_skip_text}"
[[ "${_fail}" -eq 0 ]]
