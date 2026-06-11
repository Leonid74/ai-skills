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

# rm -rf / rm -r (рекурсивное удаление)
if printf '%s' "$cmd" | grep -Eiq '\brm\s+(-[a-z]*r[a-z]*f|-[a-z]*f[a-z]*r|-r[a-z]*\s+-f|-rf|-fr)\b'; then
  # Исключение: /tmp и его содержимое разрешены.
  # Убираем rm с флагами и все /tmp-пути; если остаётся непробельный токен —
  # есть цели вне /tmp → блокируем.
  _leftover="$(printf '%s' "$cmd" \
    | sed -E 's#\brm(\s+-[a-zA-Z]+)+\s*##i' \
    | sed -E 's#/tmp(/\S*)?(\s|$)# #g')"
  if printf '%s' "$_leftover" | grep -qE '\S'; then
    block "рекурсивное/принудительное удаление (rm -rf)"
  fi
fi

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
