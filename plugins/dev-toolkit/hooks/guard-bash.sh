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

# Секреты — проверяем ПЕРВОЙ, чтобы команда с секретом не попала под
# эхо-правило ниже.
if printf '%s' "${cmd}" | grep -qiE 'secret|password|token'; then
  block_secret "команда содержит чувствительное ключевое слово (secret/password/token)"
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

# Чтение .env-файлов
if printf '%s' "${cmd}" | grep -Eiq '\b(cat|less|more|head|tail|bat|nl|xxd|od|strings)\b[^|]*\.env'; then
  block "чтение .env-файла (секреты)"
fi

exit 0
