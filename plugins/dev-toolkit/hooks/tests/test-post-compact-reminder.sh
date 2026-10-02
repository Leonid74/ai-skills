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

printf 'pass=%s fail=%s\n' "${_pass}" "${_fail}"
[[ "${_fail}" -eq 0 ]]
