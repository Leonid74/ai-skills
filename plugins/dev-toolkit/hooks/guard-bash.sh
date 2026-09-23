#!/usr/bin/env bash
# PreToolUse-хук для Bash: блокирует опасные команды и предотвращает утечку
# секретов. Получает JSON на stdin (.tool_input.command). Выход 2 = блокировка
# (текст из stderr возвращается модели).

set -euo pipefail

input="$(cat)"
cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // ""')"

# Блокировка с эхо команды — для деструктивных правил: текст полезен
# для диагностики и не содержит секретов.
block() {
  printf 'ЗАБЛОКИРОВАНО хуком guard-bash: %s\n' "$1" >&2
  printf 'Команда: %s\n' "${cmd}" >&2
  exit 2
}

# Secret-aware блокировка — БЕЗ эхо команды, чтобы не вернуть модели
# и не записать в логи сам секрет/токен/пароль из текста команды.
block_secret() {
  printf 'ЗАБЛОКИРОВАНО хуком guard-bash: %s\n' "$1" >&2
  printf '(команда скрыта, чтобы не раскрыть секрет)\n' >&2
  exit 2
}

# Секреты — проверяем ПЕРВЫМИ, чтобы команда с секретом не попала под
# эхо-правила ниже. Ловим ЗНАЧЕНИЯ секретов, а не слова: прежнее правило
# «слово secret/password/token в любом месте команды» блокировало имена
# классов, путей и тестов (--filter=…TokenTest) и не ловило ни одного
# реального ключа. Защита — от СЛУЧАЙНОЙ утечки значения в текст команды
# (транскрипт, логи), не от целенаправленного обхода: разбор кавычек и
# экранирования здесь осознанно не делается.
_secret_hint="секрет — через переменную окружения или файл, не литералом в команде"

# Значения известных форматов. Регистрозависимо (префиксы у провайдеров
# фиксированы) и под LC_ALL=C (диапазоны [A-Z] — строго ASCII). Граница
# слева не даёт хвосту слова совпасть с префиксом: "task-…"/"disk-…" не "sk-…".
# Для generic "sk-" требуется сплошной буквенно-цифровой прогон ≥ 20 —
# kebab-case имена ("sk-learn-…") такого прогона не содержат.
_secret_value_re='(^|[^A-Za-z0-9_])gh[pousr]_[A-Za-z0-9]{36}'
_secret_value_re+='|(^|[^A-Za-z0-9_])github_pat_[A-Za-z0-9_]{22,}'
_secret_value_re+='|(^|[^A-Za-z0-9_-])sk-ant-[A-Za-z0-9_-]{20,}'
_secret_value_re+='|(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]*[A-Za-z0-9]{20}'
_secret_value_re+='|(^|[^A-Za-z0-9_])xox[abprs]-[A-Za-z0-9-]{10,}'
_secret_value_re+='|(^|[^A-Za-z0-9])(AKIA|ASIA)[0-9A-Z]{16}([^0-9A-Za-z]|$)'
_secret_value_re+='|(^|[^0-9])[0-9]{8,10}:[A-Za-z0-9_-]{35}'
_secret_value_re+='|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.'
_secret_value_re+='|-----BEGIN ([A-Z]+ )*PRIVATE KEY-----'
if printf '%s' "${cmd}" | LC_ALL=C grep -qE -e "${_secret_value_re}"; then
  block_secret "в команде значение секрета известного формата (токен/ключ/JWT/приватный ключ); ${_secret_hint}"
fi

# Присваивание литерала чувствительному имени: password=…, API_KEY: …,
# --token=… Литерал — ≥ 8 ASCII-символов подряд и не начинается с "$"
# (ссылка на переменную — норма) и с "/", "~", "." (путь к файлу с
# секретом — тоже норма: TOKEN_FILE=/run/…). ASCII-класс, а не "не пробел",
# чтобы русский текст после "token:" в сообщении коммита не считался
# литералом. Имя с суффиксом (TokenTest, max_tokens) без "="/":" следом не
# ловится — это и убирает ложные срабатывания прежнего правила. Кавычка
# между именем и "=/:" — JSON-форма ("token": "…"), "=>" — PHP-массив.
# Первый символ литерала — не ":": иначе оператор области видимости
# (Password::defaults, --filter=…TokenTest::test_x) читался бы как
# "двоеточие + литерал". В хвосте ":" разрешён (URL, base64-подобные значения).
_secret_assign_re='(password|passwd|secret|token|api[_-]?key)[A-Za-z0-9_]*["'\'']?[[:space:]]*(=>?|:)[[:space:]]*["'\'']?'
_secret_assign_re+='[A-Za-z0-9!#%&*+,;<=>?@^_|-][A-Za-z0-9!#%&*+,./:;<=>?@^_|~-]{7,}'
if printf '%s' "${cmd}" | LC_ALL=C grep -qiE -e "${_secret_assign_re}"; then
  block_secret "в команде литерал, присвоенный чувствительному имени (password/secret/token/api_key); ${_secret_hint}"
fi

# rm -r / rm -rf / rm --recursive (рекурсивное удаление). Флаг -f не делает
# удаление более опасным здесь — без интерактивного stdin (как у агента) -r
# без -f удаляет write-protected файлы точно так же безвозвратно, без
# подтверждения, поэтому ловим сам факт рекурсии, а не обязательную пару
# -r+-f.
# Разбираем составную команду на под-сегменты по &&, ||, ; и | — иначе
# /tmp-исключение ниже ломается на цепочках вида
# "mkdir -p /tmp/x && rm -rf /tmp/x": проверка всей строки целиком включала
# бы соседние команды и блокировала бы безопасный /tmp-кейс.
#
# Внутри сегмента аргументы rm разбираются по словам (а не одним regex-
# проходом), потому что GNU rm пропускает флаги через getopt-permutation —
# recursive-флаг может стоять и после операнда (rm /home/x -r). Команда
# ищется равенством токена (rm или путь, заканчивающийся на /rm), а не
# вырезанием текста до последнего слова "rm" — иначе слово "rm" внутри имени
# операнда (rm -rf /home/rm-backup) обрезает разбор раньше настоящих флагов
# и глушит детект. _operand_seen отдельно от "операнд вне /tmp" нужен для
# rm без аргумента-пути в самой команде (find . | xargs rm -rf — пути идут
# через stdin): без этого флага такой вызов не блокировался бы.
set -f
_segments="$(printf '%s\n' "${cmd}" | sed -E 's/(&&|\|\||;|\|)/\n/g')"
while IFS= read -r _seg; do
  if printf '%s' "${_seg}" | grep -qiE '\brm\b'; then
    _seen_rm=false
    _is_recursive=false
    _operand_seen=false
    _has_non_tmp_operand=false
    _opts_ended=false
    for _tok in ${_seg}; do
      # Lowercase — только для регистронезависимого опознания команды/флагов
      # (как и остальной файл, который матчит git/rm через grep -i).
      # Сравнение операнда с /tmp ниже идёт по ИСХОДНОМУ "${_tok}", не
      # "${_tok_lc}" — /tmp на Linux регистрочувствителен, и без этого
      # разделения "rm -rf /TMP/x" лоуэркейснулся бы в "/tmp/x" и прошёл бы
      # /tmp-исключение, хотя реально удаляет путь вне /tmp.
      _tok_lc="${_tok,,}"
      if ! ${_seen_rm}; then
        case "${_tok_lc}" in
          rm|*/rm) _seen_rm=true ;;
          *) ;;
        esac
        continue
      fi
      if ! ${_opts_ended} && [[ "${_tok_lc}" = "--" ]]; then
        _opts_ended=true
        continue
      fi
      if ! ${_opts_ended} && [[ "${_tok_lc#-}" != "${_tok_lc}" ]]; then
        case "${_tok_lc}" in
          --recursive) _is_recursive=true ;;
          --*) ;;                     # прочие длинные опции не про рекурсию
          *r*) _is_recursive=true ;;  # короткий кластер с 'r' (-r/-rf/-fr/-vr…)
          *) ;;
        esac
        continue
      fi
      _operand_seen=true
      case "${_tok}" in
        /tmp|/tmp/*) ;;
        *) _has_non_tmp_operand=true ;;
      esac
    done
    if ${_is_recursive} && { ${_has_non_tmp_operand} || ! ${_operand_seen}; }; then
      block "рекурсивное удаление (rm -r/-rf/--recursive)"
    fi
  fi

  # Опасные подфлаги у read-only git/gh-команд — механический барьер для
  # инварианта 3 скилла review-code: префикс allowed-tools вида
  # "Bash(git diff:*)" авто-одобряет команду целиком и НЕ запрещает подфлаги,
  # а --output/--no-index/--ext-diff превращают формально read-only команду
  # в запись файла, чтение вне репозитория или запуск внешней программы.
  # Флаг-сеты у git и gh РАЗДЕЛЬНЫЕ: -w у "git diff" — легитимный
  # ignore-all-space, а у gh — открытие браузера (--web); общий набор давал
  # бы ложную блокировку повседневного "git diff -w".
  if printf '%s' "${_seg}" | grep -qiE '\b(git|gh)\b'; then
    _g_cmd=""       # какая команда найдена в сегменте: git | gh
    _g_sub=false    # git: read-only подкоманда (diff/log/blame/show); gh: "pr"
    _g_leaf=false   # gh: после "pr" найден leaf diff|view (git не использует)
    _g_hit=""       # первый найденный опасный подфлаг (для текста блокировки)
    for _tok in ${_seg}; do
      _tok_lc="${_tok,,}"
      if [[ -z "${_g_cmd}" ]]; then
        case "${_tok_lc}" in
          git|*/git) _g_cmd="git" ;;
          gh|*/gh)   _g_cmd="gh" ;;
          *) ;;
        esac
        continue
      fi
      if ! ${_g_sub}; then
        if [[ "${_g_cmd}" = "git" ]]; then
          case "${_tok_lc}" in diff|log|blame|show) _g_sub=true ;; *) ;; esac
        else
          case "${_tok_lc}" in pr) _g_sub=true ;; *) ;; esac
        fi
        continue
      fi
      # Токены после охраняемой подкоманды. "--" завершает опции: всё дальше
      # git/gh трактуют как пути/аргументы, флаги там не ищем — иначе файл
      # с именем "--output" ("git diff -- --output") давал бы ложную
      # блокировку.
      if [[ "${_tok}" = "--" ]]; then
        break
      fi
      if [[ "${_g_cmd}" = "gh" ]] && ! ${_g_leaf}; then
        case "${_tok_lc}" in
          diff|view) _g_leaf=true; continue ;;
          *) ;;
        esac
      fi
      # Флаги матчим по ИСХОДНОМУ регистру (не ${_tok_lc}): git/gh принимают
      # опции только в точном регистре, поэтому обход через регистр
      # невозможен, а лоуэркейс дал бы ложную блокировку -O (orderfile ≠ -o).
      _flag="${_tok%%=*}"
      if [[ "${_g_cmd}" = "git" ]]; then
        case "${_flag}" in
          --?*)
            # git принимает однозначные СОКРАЩЕНИЯ long-опций (--outp= ==
            # --output=), поэтому матчим «токен — префикс опасного флага»,
            # а не только точную форму. Неоднозначное сокращение (--o, --e)
            # git отвергает сам, так что лишняя блокировка тут безвредна.
            for _dflag in --output --ext-diff --no-index --exec; do
              if [[ "${_dflag}" == "${_flag}"* ]]; then
                _g_hit="${_tok}"
                break
              fi
            done
            ;;
          -o*) _g_hit="${_tok}" ;;  # -o / -o<file>: запись вывода в файл
          *) ;;
        esac
      else
        case "${_flag}" in
          --web|--repo|--exec) _g_hit="${_tok}" ;;
          --*) ;;  # прочие long-опции: gh (cobra) сокращений НЕ принимает,
                   # поэтому точного совпадения достаточно
          -R*|-w*) _g_hit="${_tok}" ;;  # -R / -R<owner/repo> / -w
          -*)
            # Кластер коротких флагов (-cw == --comments --web): буквенный
            # токен, содержащий w или R. Может дать ложное срабатывание на
            # прицепленном буквенном значении (-Sfew) — осознанно: ложная
            # блокировка безопаснее открытия браузера/чужого репозитория.
            if [[ "${_tok}" =~ ^-[A-Za-z]+$ && "${_tok}" == *[wR]* ]]; then
              _g_hit="${_tok}"
            fi
            ;;
          *) ;;
        esac
      fi
    done
    if [[ -n "${_g_hit}" ]] && ${_g_sub}; then
      if [[ "${_g_cmd}" = "git" ]]; then
        block "опасный подфлаг ${_g_hit} у read-only git-команды (запись файла / чтение вне репозитория / запуск внешней программы)"
      elif ${_g_leaf}; then
        block "опасный подфлаг ${_g_hit} у gh pr diff/view (открытие браузера / доступ к чужому репозиторию)"
      fi
    fi
  fi
done <<< "${_segments}"
set +f

# git reset --hard
if printf '%s' "${cmd}" | grep -Eiq '\bgit\b.*\breset\b.*--hard\b'; then
  block "git reset --hard (потеря незакоммиченных изменений)"
fi

# git push --force / -f
if printf '%s' "${cmd}" | grep -Eiq '\bgit\b.*\bpush\b.*(--force\b|--force-with-lease\b|\s-f\b)'; then
  block "git push --force (перезапись истории на remote)"
fi

# git branch -D (принудительное удаление ветки). Проверка регистрозависимая
# (без -i): блокируем только -D, а безопасный -d (git удалит ветку лишь
# если она полностью влита) пропускаем.
if printf '%s' "${cmd}" | grep -Eq '\bgit\b.*\bbranch\b.*\s-D\b'; then
  block "git branch -D (принудительное удаление ветки)"
fi

# Вывод окружения процесса/контейнера — секреты в env попадают в транскрипт.
if printf '%s' "${cmd}" | grep -Eq '/proc/[^[:space:]]*/environ'; then
  block "чтение /proc/*/environ (окружение процесса с секретами)"
fi

# .env-файлы — fail-closed: сегмент, в котором есть путь-токен .env или
# .env.<суффикс>, блокируется при ЛЮБОЙ команде, кроме allowlist безвредных
# (ls, stat, test/[/[[, git status, git check-ignore). Прежний список
# «читающих» утилит (cat/less/head…) пропускал grep/sed/awk/source/
# интерпретаторы/cp — перечислить всех читателей невозможно. Шаблоны
# (.env.example/.env.dist/.env.sample) секретов не содержат и разрешены.
# Вхождение .env ищется внутри токена с ограничителями по краям: слева
# начало слова или / = : кавычка < > ( ` (пути, --file=.env, редиректы,
# $(…), open('.env') в коде интерпретатора), справа конец слова или
# кавычка ; ) ` > , — поэтому process.env.FOO и .envrc под правило не
# попадают. Шаблоны вырезаются из токена до проверки (_env_tpl_re).
_env_path_re='(^|[/=:"'\''<>(`])\.env(\.[[:alnum:]_-]+)*(["'\'';)`>,]|$)'
_env_tpl_re='^(.*)\.env\.(example|dist|sample)((["'\'';)`>,]|$).*)$'
_env_msg="обращение к .env-файлу (секреты): разрешены только ls/stat/test/git status/git check-ignore; шаблоны .env.example/.env.dist/.env.sample — свободно"
set -f
while IFS= read -r _seg; do
  read -ra _w <<< "${_seg}"
  # Ведущие присваивания (FOO=1 cmd) — не команда сегмента.
  _i=0
  while [[ ${_i} -lt ${#_w[@]} && "${_w[${_i}]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    _i=$((_i + 1))
  done
  [[ ${_i} -lt ${#_w[@]} ]] || continue
  _c0="${_w[${_i}],,}"
  _c0="${_c0##*/}"
  _args=("${_w[@]:$((_i + 1))}")

  # Голые printenv/env/export/set/declare печатают всё окружение. У env
  # аргумент-команда (env FOO=1 cmd) — запуск, а не вывод; -u/-C берут
  # значение следующим токеном.
  _only_flags=true
  _skip=false
  for _t in "${_args[@]}"; do
    if ${_skip}; then _skip=false; continue; fi
    case "${_c0}:${_t}" in
      env:-u|env:--unset|env:-C|env:--chdir) _skip=true ;;
      env:*=*) ;;
      *:-*) ;;
      *) _only_flags=false; break ;;
    esac
  done
  case "${_c0}" in
    printenv|env|export|declare|typeset)
      if ${_only_flags}; then
        block "вывод переменных окружения (${_c0} без аргументов) может раскрыть секреты"
      fi
      ;;
    set)
      if [[ ${#_args[@]} -eq 0 ]]; then
        block "вывод переменных окружения (set без аргументов) может раскрыть секреты"
      fi
      ;;
    *) ;;
  esac
  # docker compose config / … exec … env — сверка по ТОКЕНАМ от команды
  # сегмента, а не регексом по строке: \b считает "." и "/" границей слова,
  # и "grep x docker-compose.yml config/app.php" ложно совпадал с
  # "docker-compose … config".
  case "${_c0}" in
    docker|docker-compose|podman|podman-compose|kubectl)
      _d_compose=false
      _d_exec=false
      if [[ "${_c0}" == *-compose ]]; then _d_compose=true; fi
      for _t in "${_args[@]}"; do
        _t="${_t,,}"
        if ${_d_exec}; then
          case "${_t##*/}" in
            env|printenv) block "вывод окружения контейнера (exec … env/printenv) может раскрыть секреты" ;;
            *) ;;
          esac
          continue
        fi
        case "${_t}" in
          compose) _d_compose=true ;;
          config)
            if ${_d_compose}; then
              block "docker compose config выводит конфигурацию с подставленными секретами"
            fi
            ;;
          exec) _d_exec=true ;;
          *) ;;
        esac
      done
      ;;
    *) ;;
  esac

  _env_hit=false
  for _t in "${_w[@]}"; do
    while [[ "${_t}" =~ ${_env_tpl_re} ]]; do
      _t="${BASH_REMATCH[1]}${BASH_REMATCH[3]}"
    done
    if [[ "${_t}" =~ ${_env_path_re} ]]; then
      _env_hit=true
      break
    fi
  done
  if ${_env_hit}; then
    case "${_c0}" in
      ls|stat|test|\[|\[\[) ;;
      git)
        case "${_args[0]:-}" in
          status|check-ignore) ;;
          *) block "${_env_msg}" ;;
        esac
        ;;
      *) block "${_env_msg}" ;;
    esac
  fi
done <<< "${_segments}"
set +f

exit 0
