#!/usr/bin/env bash
# Тест-векторы для guard-bash.sh: каждый вектор подаётся хуку как JSON
# PreToolUse на stdin, сверяется код выхода (0 — пропуск, 2 — блокировка).
# Запуск из корня репозитория:
#   bash plugins/dev-toolkit/hooks/tests/test-guard-bash.sh
set -uo pipefail

_hook="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../guard-bash.sh"
_pass=0
_fail=0

# expect <ожидаемый_код> <текст команды>
expect() {
  local _want="$1" _cmd="$2" _got=0
  jq -cn --arg c "${_cmd}" '{tool_input: {command: $c}}' \
    | bash "${_hook}" > /dev/null 2>&1 || _got=$?
  if [[ "${_got}" -eq "${_want}" ]]; then
    _pass=$((_pass + 1))
  else
    _fail=$((_fail + 1))
    printf 'FAIL: ожидался код %s, получен %s: %s\n' "${_want}" "${_got}" "${_cmd}"
  fi
}

# --- read-only git: опасные подфлаги (блокировка) ---
expect 2 'git diff --output=/tmp/x HEAD~1'
expect 2 'git diff --output /tmp/x HEAD~1'
expect 2 'git diff --outp=/tmp/x HEAD~1'          # сокращение long-опции
expect 2 'git diff -o/tmp/x HEAD~1'
expect 2 'git diff --no-index /etc/passwd /etc/hostname'
expect 2 'git log --ext-diff'
expect 2 'git show --ext-diff HEAD'
expect 2 'git blame --output=/tmp/x file.txt'
expect 2 'git -C /repo diff --no-index a b'        # подкоманда после глобальной опции
expect 2 'mkdir -p /tmp/x && git diff --output=/tmp/x/d HEAD~1'  # сегмент цепочки
expect 2 'git log -p --exec x'

# --- read-only git: легитимные формы (пропуск) ---
expect 0 'git diff HEAD~1...HEAD'
expect 0 'git diff --stat'
expect 0 'git diff -w HEAD~1'                      # -w у git — ignore-all-space, не --web
expect 0 'git diff --no-ext-diff HEAD~1'           # негация — безопасна
expect 0 'git diff --output-indicator-new=+ HEAD~1'
expect 0 'git diff --exit-code'
expect 0 'git diff -- --output'                    # файл с именем --output после "--"
expect 0 'git log --oneline -n 20'
expect 0 'git log --not main'
expect 0 'git log --no-merges'
expect 0 'git blame -L 10,20 file.txt'
expect 0 'git show HEAD --stat'
expect 0 'git checkout -b feat/x'                  # не охраняемая подкоманда

# --- gh pr diff/view: опасные подфлаги (блокировка) ---
expect 2 'gh pr view 123 --web'
expect 2 'gh pr diff --web'
expect 2 'gh pr view -w 123'
expect 2 'gh pr diff -R evil/repo 42'
expect 2 'gh pr view --repo=evil/repo 42'
expect 2 'gh pr view -cw 123'                      # кластер коротких флагов

# --- gh: вне охраняемого scope (пропуск — осознанное решение) ---
expect 0 'gh pr view 123'
expect 0 'gh pr diff 42 --name-only'
expect 0 'gh pr view 123 --comments'
expect 0 'gh pr list -R owner/repo'                # list не auto-approved скиллом
expect 0 'gh repo view'

# --- регрессия существующих правил ---
expect 2 'rm -rf /home/x'
expect 0 'rm -rf /tmp/x'
expect 0 'mkdir -p /tmp/x && rm -rf /tmp/x'
expect 2 'git reset --hard'
expect 2 'git push --force'
expect 2 'git branch -D foo'
expect 0 'git branch -d foo'
expect 2 'cat .env'
expect 0 'ls -la'

printf 'Итог: %d OK, %d FAIL\n' "${_pass}" "${_fail}"
[[ "${_fail}" -eq 0 ]]
