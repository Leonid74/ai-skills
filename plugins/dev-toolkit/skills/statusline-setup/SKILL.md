---
name: statusline-setup
description: Настройка строки статуса (statusline) Claude Code через плагин dev-toolkit. Использовать когда пользователь говорит "настрой statusline", "setup statusline", "установи statusline", "хочу statusline с моделью и git-веткой", "настрой строку статуса", "добавь строку статуса в Claude Code". Skill создаёт скрипт ~/.claude/statusline.sh и прописывает секцию statusLine в ~/.claude/settings.json.
---

# Настройка statusline

## Что делает этот skill

Настраивает строку статуса Claude Code, которая показывает: `user@host:папка | модель | git-ветка`.

Строка статуса — это bash-скрипт, получающий JSON сессии на stdin и выводящий форматированную строку. Claude Code вызывает его и показывает результат в интерфейсе.

## Шаги

### 1. Проверь текущее состояние

Прочитай `~/.claude/settings.json` и найди секцию `statusLine`.

**Если `statusLine` уже настроен:**
- Сообщи пользователю, что statusline уже настроен
- Покажи текущее значение `command`
- Спроси, хочет ли он обновить скрипт или оставить как есть
- Если оставить — завершай, ничего не меняй

**Если `statusLine` отсутствует** — переходи к шагу 2.

### 2. Создай скрипт

Создай файл `~/.claude/statusline.sh` со следующим содержимым:

```bash
#!/usr/bin/env bash
# Строка статуса Claude Code: user@host:папка | модель | git-ветка.
# Получает JSON сессии на stdin (поля .model / .workspace).

set -euo pipefail

input="$(cat)"

model="$(printf '%s' "$input" | jq -r '.model.display_name // "?"')"
dir="$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // "."')"

# Короткое имя папки (~ вместо домашнего каталога).
short_dir="${dir/#$HOME/\~}"

# Ветка git, если текущая папка внутри репозитория.
branch=""
if git -C "$dir" rev-parse --abbrev-ref HEAD >/dev/null 2>&1; then
  branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
fi

# ANSI-цвета как в PS1.
green=$'\033[01;32m'
blue=$'\033[01;34m'
reset=$'\033[00m'

# user@host:dir в стиле PS1.
printf '%s%s@%s%s:%s%s%s' "$green" "$(whoami)" "$(hostname -s)" "$reset" "$blue" "$short_dir" "$reset"

# Модель.
printf ' | %s' "$model"

# Git-ветка (со значком Powerline ), если есть.
if [ -n "$branch" ]; then
  printf ' | \xee\x82\xa0 %s' "$branch"
fi
```

После создания сделай файл исполняемым:
```bash
chmod +x ~/.claude/statusline.sh
```

### 3. Пропиши конфиг в settings.json

Добавь секцию `statusLine` в `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "~/.claude/statusline.sh"
}
```

Используй инструмент Edit для точечного добавления — не перезаписывай весь файл. Добавь секцию на верхний уровень JSON-объекта, рядом с другими ключами.

### 4. Подтверди результат

После настройки:
- Сообщи пользователю, что statusline настроен
- Покажи итоговую конфигурацию
- Предупреди, что изменения вступят в силу после перезапуска Claude Code (если сессия уже активна)

## Важно

- Никогда не удаляй существующий `~/.claude/statusline.sh` без явного разрешения пользователя — предложи сначала показать текущее содержимое
- `settings.json` — это JSON без комментариев, не нарушай его структуру при редактировании
- Если `jq` не установлен, предупреди пользователя — скрипт зависит от него
