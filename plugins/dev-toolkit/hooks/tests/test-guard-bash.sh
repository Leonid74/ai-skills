#!/usr/bin/env bash
# Тест-векторы для guard-bash.sh: каждый вектор подаётся хуку как JSON
# PreToolUse на stdin, сверяется код выхода (0 — пропуск, 2 — блокировка).
# Запуск из корня репозитория:
#   bash plugins/dev-toolkit/hooks/tests/test-guard-bash.sh
set -uo pipefail

# GUARD_BASH_HOOK — путь к проверяемой копии хука (для мутационной проверки
# тестов); по умолчанию — хук рядом с каталогом тестов.
_hook="${GUARD_BASH_HOOK:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../guard-bash.sh}"
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

# --- секреты: фейковые значения собираются конкатенацией, иначе сам хук
# заблокирует запуск теста, а сканер секретов в CI примет фикстуру за ключ ---
_a10="abcdEFGH12"
_a36="${_a10}${_a10}${_a10}abcdef"
_up16="ABCDEFGHIJKLMNOP"
_ghp="gh""p_${_a36}"
_tg="123456789"":${_a10}${_a10}${_a10}abcde"
_jwt="ey""JhbGciOiJIUzI1NiJ9.ey""JzdWIiOiIxMjM0NTY3ODkwIn0.c2ln"
_pem="-----BEGIN RSA PRIV""ATE KEY-----"
_pw="pass""word"
_sec="sec""ret"
_tok="tok""en"

# Таблица из задания: ложные срабатывания прежнего правила по словам (пропуск)
expect 0 "php artisan test --filter=PersistRenewed${_tok^}Test"
expect 0 "grep -n mask${_sec^}sInText app/Support/SensitiveDataMasker.php"
expect 0 "git log --oneline -- app/Http/Middleware/VerifyApplication${_tok^}.php"
expect 0 "echo \"${_tok}s used: 120k\""
# ...и пропуски прежних правил (блокировка)
expect 2 'grep APP_KEY .env'
expect 2 'sed -n 1,50p .env'
expect 2 'awk 1 .env'
expect 2 'printenv'
expect 2 'docker compose exec app env'
expect 2 'docker compose config'
expect 2 "curl -H \"Authorization: Bearer ${_ghp}\" https://api.github.com"
expect 2 "curl https://api.telegram.org/bot${_tg}/getMe"
expect 2 "mysql -u root --${_pw}=hunter2hunter2"

# Значения известных форматов: позитив
expect 2 "echo ${_ghp}"
expect 2 "echo gh""o_${_a36}"
expect 2 "echo github_""pat_${_a10}${_a10}${_a10}"
expect 2 "echo sk-""ant-api03-${_a10}${_a10}${_a10}"
expect 2 "echo sk-""${_a10}${_a10}${_a10}"
expect 2 "echo sk-""proj-${_a10}_${_a10}${_a10}"
expect 2 "echo xox""b-1234567890-${_a10}"
expect 2 "echo AKIA""${_up16}"
expect 2 "echo ${_jwt}"
expect 2 "printf '%s' '${_pem}'"
expect 2 "echo '-----BEGIN PRIV""ATE KEY-----'"
# Значения известных форматов: негатив
expect 0 "echo gh""p_short"
expect 0 "echo xgh""p_${_a36}"                      # префикс внутри слова
expect 0 "echo sk-""ant-short"
expect 0 "cat task-${_a10}${_a10}${_a10}.log"        # "sk-" внутри слова
expect 0 'git checkout -b feat/sk-learn-some-long-kebab-branch-name'
expect 0 "echo xox""b-12"
expect 0 "echo AKIA""ABCDEFGHIJKLMNO"                # 15 символов вместо 16
expect 0 "echo akia""abcdefghijklmnop"              # регистр значим
expect 0 'date +%H:%M && echo 12:30'
expect 0 "echo 123456789:short"
expect 0 "echo ey""JhbGciOiJIUzI1NiJ9"              # одна часть — не JWT
expect 0 "echo '-----BEGIN PUBLIC KEY-----'"
expect 0 "echo '-----BEGIN CERTIFICATE-----'"

# Присваивание литерала: позитив
expect 2 "export API_KEY=abcd1234efgh"
expect 2 "printf '${_pw}: hunter2hunter2' > cfg.yml"
expect 2 "echo '{\"${_tok}\": \"abcdefgh1234\"}'"
expect 2 "curl 'https://example.com/api?${_tok}=abcdefgh1234'"
expect 2 "${_sec^^}_KEY_BASE=abcdef123456 php artisan x"
# Присваивание литерала: негатив
expect 0 "export GITHUB_${_tok^^}=\$GH"
expect 0 "${_tok^^}=\"\${VAR}\" ./deploy.sh"
expect 0 "${_tok^^}_FILE=/run/${_sec}s/x ./deploy.sh"
expect 0 "mysql --${_pw}=short"                     # литерал короче 8
expect 0 "curl -d max_${_tok}s=4096 https://example.com"
expect 0 "git commit -m \"fix: ${_tok}: обновление логики\""
expect 0 "./app --${_tok}-file ./x"
expect 0 "grep -rn \"${_pw^}::sendResetLink\" app/"  # оператор области видимости ::
expect 0 "grep -rn \"${_pw^}::defaults\" app/"
expect 0 "php artisan test --filter=PersistRenewed${_tok^}Test::test_it_persists"
expect 2 "php -r \"\\\$c = ['${_pw}' => 'hunter2hunter2'];\""  # PHP-массив =>

# --- вывод окружения ---
expect 2 'printenv | grep FOO'
expect 2 'env'
expect 2 'env | sort'
expect 2 'env -0'
expect 2 'export -p'
expect 2 'export'
expect 2 'set'
expect 2 'declare -p'
expect 2 'FOO=1 printenv'
expect 2 '/usr/bin/env'
expect 2 'docker-compose config'
expect 2 'docker compose -f x.yml config --services'
expect 2 'docker exec app printenv'
expect 2 'kubectl exec pod -- env'
expect 2 'cat /proc/1/environ'
expect 2 'tr "\0" "\n" < /proc/self/environ'
expect 0 'env FOO=1 php artisan x'
expect 0 'env -u FOO ./cmd'
expect 0 '/usr/bin/env bash script.sh'
expect 0 'set -euo pipefail'
expect 0 'export FOO=bar'
expect 0 'declare -a arr'
expect 0 'printenv HOME'                             # одна переменная — вне правила
expect 0 'docker compose up -d'
expect 0 'docker compose exec app php artisan migrate'
expect 0 'grep -n redis docker-compose.yml config/database.php'  # имя файла, не команда
expect 0 'grep -rn QUEUE deploy/ docker-compose.yml config/queue.php'
expect 0 'docker config ls'                          # swarm configs, не compose
expect 0 'echo run docker compose exec app env later >> notes.md'  # текст, не команда
expect 2 'env -u FOO'                                # -u берёт значение, команды нет

# --- .env-файлы: fail-closed ---
expect 2 'cat .env.local'
expect 2 'source .env'
expect 2 '. .env'
expect 2 'grep -r X --include=.env.production .'
expect 2 "python3 -c \"print(open('.env').read())\""
expect 2 "php -r 'echo file_get_contents(\".env\");'"
expect 2 'cp .env /tmp/x'
expect 2 'rsync app/.env backup/'
expect 2 'base64 < .env'
expect 2 'ls .env && cat .env'
expect 2 'cat .env.example.bak'
expect 2 'git diff .env'
expect 2 'cp .env.example .env'                       # запись .env — тоже вне allowlist
expect 0 'ls -la .env'
expect 0 'stat .env'
expect 0 'test -f .env && echo ok'
expect 0 '[ -f .env ] || echo missing'
expect 0 '[[ -s .env.local ]]'
expect 0 'git status .env'
expect 0 'git check-ignore .env'
expect 0 'cat .env.example'
expect 0 'diff .env.dist .env.sample'
expect 0 'grep -rn "process.env" src'
expect 0 'node -e "console.log(process.env.FOO)"'
expect 0 'cat .envrc'

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
