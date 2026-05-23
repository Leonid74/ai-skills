#!/usr/bin/env bash
# Блокирует Bash-команды, содержащие чувствительные ключевые слова
cmd=$(jq -r '.tool_input.command // ""')
if echo "$cmd" | grep -qiE 'secret|password|token'; then
    echo "Заблокировано: команда содержит чувствительное ключевое слово (secret/password/token)" >&2
    exit 2
fi
