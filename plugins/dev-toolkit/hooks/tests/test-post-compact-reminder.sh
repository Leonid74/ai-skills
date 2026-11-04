#!/usr/bin/env bash
# Тест-векторы для post-compact-reminder.sh: каждый вектор строит временный
# проект, запускает хук с CLAUDE_PROJECT_DIR на него и проверяет вывод/код.
# Запуск из корня репозитория:
#   bash plugins/dev-toolkit/hooks/tests/test-post-compact-reminder.sh
set -uo pipefail

# POST_COMPACT_HOOK — путь к проверяемой копии хука (для мутационной проверки
# тестов); по умолчанию — хук рядом с каталогом тестов.
_hook="${POST_COMPACT_HOOK:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../post-compact-reminder.sh}"
_pass=0
_fail=0
_root="$(mktemp -d)"
trap 'rm -rf "${_root}"' EXIT

_out=""
_rc=0

# run_hook <каталог проекта|-> [stdin]: пишет вывод в _out, код — в _rc.
# "-" — CLAUDE_PROJECT_DIR не задан (хук берёт $PWD = пустой каталог).
run_hook() {
  local _dir="$1" _in="${2-}" _empty
  _empty="$(mktemp -d "${_root}/cwd.XXXXXX")"
  _rc=0
  if [[ "${_dir}" == "-" ]]; then
    _out="$(cd "${_empty}" && env -u CLAUDE_PROJECT_DIR bash "${_hook}" <<<"${_in}" 2>&1)" || _rc=$?
  else
    _out="$(cd "${_empty}" && CLAUDE_PROJECT_DIR="${_dir}" bash "${_hook}" <<<"${_in}" 2>&1)" || _rc=$?
  fi
}

# new_project <имя>: создаёт пустой проект, печатает путь.
new_project() {
  mkdir -p "${_root}/$1"
  printf '%s' "${_root}/$1"
}

# check <описание> <команда-предикат...>: успех предиката — проверка пройдена.
check() {
  local _desc="$1"
  shift
  if "$@"; then
    _pass=$((_pass + 1))
  else
    _fail=$((_fail + 1))
    printf 'FAIL: %s\n--- вывод (код %s) ---\n%s\n---\n' "${_desc}" "${_rc}" "${_out}"
  fi
}

# has / hasnt <подстрока>: есть ли подстрока в выводе.
has() { [[ "${_out}" == *"$1"* ]]; }
hasnt() { [[ "${_out}" != *"$1"* ]]; }
# rc0: код выхода хука равен 0. in_order: подстроки идут в выводе по порядку.
rc0() { [[ "${_rc}" -eq 0 ]]; }
in_order() { [[ "${_out}" == *"$1"*"$2"* ]]; }
# line_is_exact <проект>: строка «Рабочие файлы» — корень проекта и ровно один
# файл PLAN-recent.md с датой ДД.ММ.
line_is_exact() {
  local _day
  _day="$(date -d '2 days ago' +%d.%m)"
  # shellcheck disable=SC2016  # обратные кавычки — разметка в ожидаемом тексте
  [[ "${_out}" == *$'\nРабочие файлы (пути от корня проекта `'"$1"'`): `.dev/PLAN-recent.md` ('"${_day}"$')' ]]
}
one_list_line() { [[ "$(grep -c '^Рабочие файлы' <<<"${_out}" || true)" -eq 1 ]]; }

_general='перечитай рабочие файлы'

# --- нет .dev/.dev_files → только общий текст ---
p="$(new_project empty)"
run_hook "${p}"
check 'пустой проект: общий текст' has "${_general}"
check 'пустой проект: без строки «Рабочие файлы»' hasnt 'Рабочие файлы'
check 'пустой проект: код 0' rc0

# --- точный формат строки: ровно одна запись, без пустых хвостов ---
p="$(new_project exact)"
mkdir -p "${p}/.dev"
touch -d '2 days ago' "${p}/.dev/PLAN-recent.md"
run_hook "${p}"
check 'один файл: строка списка без пустых записей' line_is_exact "${p}"

# --- файлы в обоих каталогах → общий топ ---
p="$(new_project both)"
mkdir -p "${p}/.dev" "${p}/.dev_files"
touch -d '3 days ago' "${p}/.dev/PLAN-a.md"
touch -d '1 days ago' "${p}/.dev_files/HANDOFF-b.md"
run_hook "${p}"
check 'оба каталога: .dev' has '.dev/PLAN-a.md'
check 'оба каталога: .dev_files' has '.dev_files/HANDOFF-b.md'
check 'оба каталога: свежий раньше старого' in_order 'HANDOFF-b.md' 'PLAN-a.md'

# --- 5 файлов → 3 самых свежих ---
p="$(new_project five)"
mkdir -p "${p}/.dev"
for i in 1 2 3 4 5; do
  touch -d "${i} days ago" "${p}/.dev/PLAN-f${i}.md"
done
run_hook "${p}"
check 'топ-3: f1' has 'PLAN-f1.md'
check 'топ-3: f2' has 'PLAN-f2.md'
check 'топ-3: f3' has 'PLAN-f3.md'
check 'топ-3: нет f4' hasnt 'PLAN-f4.md'
check 'топ-3: нет f5' hasnt 'PLAN-f5.md'

# --- возраст ---
p="$(new_project old)"
mkdir -p "${p}/.dev"
touch -d '20 days ago' "${p}/.dev/PLAN-old.md"
touch -d '1 days ago' "${p}/.dev/PLAN-new.md"
run_hook "${p}"
check 'старше 14 дней отсечён' hasnt 'PLAN-old.md'
check 'свежий остался' has 'PLAN-new.md'

# --- корень, вложенные каталоги, не под шаблон ---
p="$(new_project scope)"
mkdir -p "${p}/.dev/x"
touch "${p}/HANDOFF.md" "${p}/.dev/x/PLAN-a.md" "${p}/.dev/TODO.md" "${p}/.dev/PLAN-ok.md"
run_hook "${p}"
check 'HANDOFF.md в корне не попадает' hasnt 'HANDOFF.md'
check 'вложенный .dev/x/PLAN-a.md не попадает' hasnt 'PLAN-a.md'
check '.dev/TODO.md не попадает' hasnt 'TODO.md'
check 'подходящий файл попал' has 'PLAN-ok.md'

# --- имена ---
p="$(new_project names)"
mkdir -p "${p}/.dev"
touch "${p}/.dev/PLAN-with space.md"
touch "${p}/.dev/PLAN-new"$'\n'"line.md"
touch "${p}/.dev/PLAN-tab"$'\t'"x.md"
run_hook "${p}"
check 'имя с пробелом выводится целиком' has '.dev/PLAN-with space.md'
check 'имя с переводом строки отброшено' hasnt 'PLAN-new'
check 'имя с табуляцией отброшено' hasnt 'PLAN-tab'
check 'вывод одной строкой «Рабочие файлы»' one_list_line

# --- переменная окружения ---
run_hook -
check 'CLAUDE_PROJECT_DIR не задан: общий текст' has "${_general}"
check 'CLAUDE_PROJECT_DIR не задан: код 0' rc0
run_hook "${_root}/нет-такого"
check 'несуществующий каталог: общий текст' has "${_general}"
check 'несуществующий каталог: код 0' rc0

# --- недопустимые символы в имени: файл отбрасывается целиком ---
p="$(new_project unsafe)"
mkdir -p "${p}/.dev"
touch "${p}/.dev/PLAN-tick\`x.md"
touch "${p}/.dev/PLAN-ls"$' '"x.md"
touch "${p}/.dev/PLAN-c1"$'\xc2\x9b'"x.md"
touch "${p}/.dev/PLAN-raw"$'\x9b'"x.md"
touch "${p}/.dev/PLAN-bidi"$'‮'"x.md"
touch "${p}/.dev/PLAN-zw"$'​'"x.md"
touch "${p}/.dev/PLAN-план.md"
run_hook "${p}"
check 'обратная кавычка в имени отброшена' hasnt 'PLAN-tick'
check 'U+2028 в имени отброшен' hasnt 'PLAN-ls'
check 'C1 (UTF-8) в имени отброшен' hasnt 'PLAN-c1'
check 'сырой байт 0x9B в имени отброшен' hasnt 'PLAN-raw'
check 'bidi-override в имени отброшен' hasnt 'PLAN-bidi'
check 'zero-width в имени отброшен' hasnt 'PLAN-zw'
check 'кириллица в имени допустима' has '.dev/PLAN-план.md'

# --- файлы, отслеживаемые git, пропускаются ---
p="$(new_project tracked)"
mkdir -p "${p}/.dev"
touch "${p}/.dev/PLAN-committed.md" "${p}/.dev/PLAN-local.md"
git -C "${p}" init -q
git -C "${p}" add .dev/PLAN-committed.md
run_hook "${p}"
check 'отслеживаемый git файл пропущен' hasnt 'PLAN-committed.md'
check 'неотслеживаемый файл остался' has 'PLAN-local.md'

# --- .dev — симлинк на каталог ---
p="$(new_project symlink)"
mkdir -p "${_root}/symlink-real"
touch "${_root}/symlink-real/PLAN-linked.md"
ln -s "${_root}/symlink-real" "${p}/.dev"
run_hook "${p}"
check '.dev-симлинк на каталог читается' has '.dev/PLAN-linked.md'

# --- mtime в будущем ---
p="$(new_project future)"
mkdir -p "${p}/.dev"
touch -d '3 days' "${p}/.dev/PLAN-future.md"
touch -d '1 hours ago' "${p}/.dev/PLAN-now.md"
run_hook "${p}"
check 'файл с mtime в будущем отброшен' hasnt 'PLAN-future.md'
check 'текущий файл остался' has 'PLAN-now.md'

# --- stdin ---
p="$(new_project stdin)"
run_hook "${p}" ''
check 'пустой stdin: код 0' rc0
run_hook "${p}" $'\x01\xff{{{ мусор'
check 'мусорный stdin: код 0' rc0
check 'мусорный stdin: общий текст' has "${_general}"

# --- отметка автопилота (скилл autopilot) ---
# Отметка несёт id сессии: хук печатает строку, только если id совпадает с
# session_id из JSON события на stdin.
_sid='0f0e0d0c-1111-4222-8333-444455556666'
_sid2='aaaabbbb-cccc-4ddd-8eee-ffff00001111'
_in="{\"session_id\":\"${_sid}\",\"hook_event_name\":\"SessionStart\",\"source\":\"compact\"}"
_mark="<!-- dev-toolkit:autopilot on ${_sid} -->"
_mark2="<!-- dev-toolkit:autopilot on ${_sid2} -->"
_auto='Идёт автономный прогон'
# auto_names <путь>: строка автопилота называет этот файл PLAN.
auto_names() { [[ "${_out}" == *"${_auto} этой сессии (отметка автопилота в \`$1\`)"* ]]; }
one_auto_line() { [[ "$(grep -c "^${_auto}" <<<"${_out}" || true)" -eq 1 ]]; }

p="$(new_project auto-on)"
mkdir -p "${p}/.dev"
printf '# План\n%s\nCANARY-PLAN-TEXT\n' "${_mark}" >"${p}/.dev/PLAN-auto.md"
run_hook "${p}" "${_in}"
check 'отметка: строка автопилота есть' has "${_auto}"
check 'отметка: строка называет PLAN' auto_names '.dev/PLAN-auto.md'
check 'отметка: строка одна' one_auto_line
# shellcheck disable=SC2016  # обратные кавычки — разметка в тексте
check 'отметка: строка называет скилл' has 'скилл `autopilot` (`/dev-toolkit:autopilot`)'
# shellcheck disable=SC2016  # обратные кавычки — разметка в тексте
check 'отметка: строка называет профиль' has '`doc/AUTOPILOT.md`'
check 'отметка: общий текст остался' has "${_general}"
check 'отметка: строка «Рабочие файлы» осталась' has 'Рабочие файлы'
check 'отметка: текст PLAN в вывод не попадает' hasnt 'CANARY-PLAN-TEXT'
check 'отметка: id сессии в вывод не попадает' hasnt "${_sid}"
check 'отметка: код 0' rc0

p="$(new_project auto-off)"
mkdir -p "${p}/.dev"
printf '# План\nавтопилот не включён\n' >"${p}/.dev/PLAN-plain.md"
run_hook "${p}" "${_in}"
check 'без отметки: строки автопилота нет' hasnt "${_auto}"
check 'без отметки: список файлов как раньше' has '.dev/PLAN-plain.md'

p="$(new_project auto-foreign)"
mkdir -p "${p}/.dev"
printf '%s\n' "${_mark2}" >"${p}/.dev/PLAN-other.md"
printf '%s\n' '<!-- dev-toolkit:autopilot on -->' >"${p}/.dev/PLAN-noid.md"
run_hook "${p}" "${_in}"
check 'отметка чужой сессии и отметка без id: строки нет' hasnt "${_auto}"
run_hook "${p}" "{\"session_id\":\"${_sid2}\"}"
check 'отметка своей сессии (другой id на stdin): строка называет PLAN' auto_names '.dev/PLAN-other.md'

p="$(new_project auto-nosid)"
mkdir -p "${p}/.dev"
# В PLAN — отметки и с теми «id», что придут на stdin ниже: ослабленный разбор
# session_id (или без проверки пустого id) дал бы на них строку.
{
  printf '%s\n' "${_mark}" '<!-- dev-toolkit:autopilot on  -->'
  printf '%s\n' '<!-- dev-toolkit:autopilot on не-uuid -->'
  printf '<!-- dev-toolkit:autopilot on %sx -->\n' "${_sid}"
  printf '<!-- dev-toolkit:autopilot on %s -->\n' "${_sid^^}"
  printf '<!-- dev-toolkit:autopilot on %sa -->\n' "${_sid}"
  printf '<!-- dev-toolkit:autopilot on %s -->\n' "${_sid2}"
} >"${p}/.dev/PLAN-a.md"
run_hook "${p}" ''
check 'пустой stdin: строки нет' hasnt "${_auto}"
run_hook "${p}" '{"session_id":"не-uuid"}'
check 'session_id не UUID: строки нет' hasnt "${_auto}"
run_hook "${p}" "{\"sessionid\":\"${_sid}\"}"
check 'нет поля session_id: строки нет' hasnt "${_auto}"
run_hook "${p}" "{\"session_id\":\"${_sid}x\"}"
check 'session_id с хвостом: строки нет' hasnt "${_auto}"
run_hook "${p}" "{\"session_id\":\"${_sid}a\"}"
check 'session_id с hex-хвостом: строки нет' hasnt "${_auto}"
run_hook "${p}" "{\"parent_session_id\":\"${_sid2}\",\"x\":1}"
check 'чужой ключ с суффиксом session_id: строки нет' hasnt "${_auto}"
run_hook "${p}" "{\"session_id\":\"${_sid}\",\"parent_session_id\":\"${_sid2}\"}"
check 'первый session_id, не вложенный чужой: строка своей отметки' auto_names '.dev/PLAN-a.md'
run_hook "${p}" "{\"session_id\":\"${_sid^^}\"}"
check 'session_id в верхнем регистре: строки нет' hasnt "${_auto}"
run_hook "${p}" "{\"session_id\" : \"${_sid}\"}"
check 'пробелы вокруг двоеточия: строка есть' auto_names '.dev/PLAN-a.md'
check 'разбор stdin: код 0' rc0

p="$(new_project auto-tracked)"
mkdir -p "${p}/.dev"
printf '%s\n' "${_mark}" >"${p}/.dev/PLAN-committed.md"
git -C "${p}" init -q
git -C "${p}" add .dev/PLAN-committed.md
run_hook "${p}" "${_in}"
check 'отметка в файле под git: строки нет' hasnt "${_auto}"

p="$(new_project auto-symlink)"
mkdir -p "${p}/docs/x"
printf '%s\n' "${_mark2}" >"${p}/docs/x/PLAN-a.md"
ln -s docs/x "${p}/.dev"
git -C "${p}" init -q
git -C "${p}" add .dev docs/x/PLAN-a.md
run_hook "${p}" "${_in}"
check 'закоммиченный симлинк .dev с чужой отметкой: строки нет' hasnt "${_auto}"

p="$(new_project auto-inline)"
mkdir -p "${p}/.dev"
# shellcheck disable=SC2016  # обратные кавычки — разметка в тексте
printf 'форма отметки — `%s` (прозой)\n  %s\n' "${_mark}" "${_mark}" >"${p}/.dev/PLAN-prose.md"
run_hook "${p}" "${_in}"
check 'отметка внутри строки или с отступом: строки нет' hasnt "${_auto}"

p="$(new_project auto-handoff)"
mkdir -p "${p}/.dev/x"
printf '%s\n' "${_mark}" >"${p}/.dev/HANDOFF-x.md"
printf '%s\n' "${_mark}" >"${p}/.dev/x/PLAN-nested.md"
printf '%s\n' "${_mark}" >"${p}/.dev/TODO.md"
run_hook "${p}" "${_in}"
check 'отметка в HANDOFF, во вложенном каталоге, не в PLAN: строки нет' hasnt "${_auto}"

p="$(new_project auto-old)"
mkdir -p "${p}/.dev"
printf '%s\n' "${_mark}" >"${p}/.dev/PLAN-old.md"
touch -d '20 days ago' "${p}/.dev/PLAN-old.md"
run_hook "${p}" "${_in}"
check 'отметка в PLAN старше 14 дней: строки нет' hasnt "${_auto}"

p="$(new_project auto-unsafe)"
mkdir -p "${p}/.dev"
printf '%s\n' "${_mark}" >"${p}/.dev/PLAN-tick\`x.md"
run_hook "${p}" "${_in}"
check 'отметка в PLAN с недопустимым именем: строки нет' hasnt "${_auto}"

p="$(new_project auto-far)"
mkdir -p "${p}/.dev"
{
  head -c 70000 /dev/zero | tr '\0' 'a'
  printf '\n%s\n' "${_mark}"
} >"${p}/.dev/PLAN-far.md"
run_hook "${p}" "${_in}"
check 'отметка дальше 64 КБ: строки нет' hasnt "${_auto}"
check 'отметка дальше 64 КБ: код 0' rc0

p="$(new_project auto-deep)"
mkdir -p "${p}/.dev"
{
  head -c 60000 /dev/zero | tr '\0' 'a'
  printf '\n%s\n' "${_mark}"
} >"${p}/.dev/PLAN-deep.md"
run_hook "${p}" "${_in}"
check 'отметка на ~60 КБ (внутри предела): строка есть' auto_names '.dev/PLAN-deep.md'

p="$(new_project auto-nul)"
mkdir -p "${p}/.dev"
printf 'a\000b\n%s\n' "${_mark}" >"${p}/.dev/PLAN-nul.md"
run_hook "${p}" "${_in}"
check 'NUL в другой строке: строка есть' auto_names '.dev/PLAN-nul.md'
check 'NUL в другой строке: предупреждений bash нет' hasnt 'null byte'
p="$(new_project auto-nul-in)"
mkdir -p "${p}/.dev"
printf '<!-- dev-toolkit:auto\000pilot on %s -->\n' "${_sid}" >"${p}/.dev/PLAN-nulin.md"
run_hook "${p}" "${_in}"
check 'NUL внутри отметки: строки нет' hasnt "${_auto}"

p="$(new_project auto-files)"
mkdir -p "${p}/.dev_files"
printf '%s\n' "${_mark}" >"${p}/.dev_files/PLAN-df.md"
run_hook "${p}" "${_in}"
check 'отметка в .dev_files: строка называет PLAN' auto_names '.dev_files/PLAN-df.md'

p="$(new_project auto-pick)"
mkdir -p "${p}/.dev"
for i in 1 2 3; do
  touch -d "${i} days ago" "${p}/.dev/PLAN-n${i}.md"
done
printf '%s\n' "${_mark2}" >"${p}/.dev/PLAN-m4.md"
touch -d '4 days ago' "${p}/.dev/PLAN-m4.md"
printf '%s\n' "${_mark}" >"${p}/.dev/PLAN-m5.md"
touch -d '5 days ago' "${p}/.dev/PLAN-m5.md"
printf '%s\n' "${_mark}" >"${p}/.dev/PLAN-m6.md"
touch -d '6 days ago' "${p}/.dev/PLAN-m6.md"
run_hook "${p}" "${_in}"
check 'вне топ-3, рядом чужая отметка: строка называет самый свежий свой PLAN' auto_names '.dev/PLAN-m5.md'
check 'вне топ-3: строка одна' one_auto_line

printf 'pass=%s fail=%s\n' "${_pass}" "${_fail}"
[[ "${_fail}" -eq 0 ]]
