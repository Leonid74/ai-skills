#!/usr/bin/env bash
# PreToolUse-хук для Bash: блокирует опасные команды и предотвращает утечку
# секретов. Получает JSON на stdin (.tool_input.command). Выход 2 = блокировка
# (текст из stderr возвращается модели).

set -euo pipefail

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"

# Блокировка с эхо команды — для деструктивных правил: текст полезен
# для диагностики и не содержит секретов.
block() {
  printf 'ЗАБЛОКИРОВАНО хуком guard-bash: %s\n' "$1" >&2
  printf 'Команда: %s\n' "$cmd" >&2
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
if printf '%s' "$cmd" | grep -qiE 'secret|password|token'; then
  block_secret "команда содержит чувствительное ключевое слово (secret/password/token)"
fi

# rm -r / rm -rf (рекурсивное удаление). Флаг -f не делает удаление более
# опасным здесь — без интерактивного stdin (как у агента) -r без -f удаляет
# write-protected файлы точно так же безвозвратно, без подтверждения, поэтому
# ловим сам факт рекурсии (-r), а не обязательную пару -r+-f.
# Разбираем составную команду на под-сегменты по &&, ||, ; и | — иначе
# /tmp-исключение ниже ломается на цепочках вида
# "mkdir -p /tmp/x && rm -rf /tmp/x": leftover для всей строки целиком
# включал бы соседние команды и блокировал бы безопасный /tmp-кейс.
while IFS= read -r _seg; do
  if printf '%s' "$_seg" | grep -Eiq '\brm\s+-[a-z]*r[a-z]*\b'; then
    # Исключение: /tmp и его содержимое разрешены.
    # Убираем rm с флагами и все /tmp-пути; если остаётся непробельный токен —
    # есть цели вне /tmp → блокируем.
    _leftover="$(printf '%s' "$_seg" \
      | sed -E 's#\brm(\s+-[a-zA-Z]+)+\s*##i' \
      | sed -E 's#/tmp(/\S*)?(\s|$)# #g')"
    if printf '%s' "$_leftover" | grep -qE '\S'; then
      block "рекурсивное удаление (rm -r/-rf)"
    fi
  fi
done < <(printf '%s\n' "$cmd" | sed -E 's/(&&|\|\||;|\|)/\n/g')

# git reset --hard
if printf '%s' "$cmd" | grep -Eiq '\bgit\b.*\breset\b.*--hard\b'; then
  block "git reset --hard (потеря незакоммиченных изменений)"
fi

# git push --force / -f
if printf '%s' "$cmd" | grep -Eiq '\bgit\b.*\bpush\b.*(--force\b|--force-with-lease\b|\s-f\b)'; then
  block "git push --force (перезапись истории на remote)"
fi

# git branch -D (принудительное удаление ветки). Проверка регистрозависимая
# (без -i): блокируем только -D, а безопасный -d (git удалит ветку лишь
# если она полностью влита) пропускаем.
if printf '%s' "$cmd" | grep -Eq '\bgit\b.*\bbranch\b.*\s-D\b'; then
  block "git branch -D (принудительное удаление ветки)"
fi

# Чтение .env-файлов
if printf '%s' "$cmd" | grep -Eiq '\b(cat|less|more|head|tail|bat|nl|xxd|od|strings)\b[^|]*\.env'; then
  block "чтение .env-файла (секреты)"
fi

exit 0
