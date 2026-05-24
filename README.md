# leonid74-ai-skills — маркетплейс плагинов для Claude Code

Каталог плагинов для Claude Code. Доступные плагины:

- **chat-handoff** — переносит контекст текущего диалога в новый чат одним готовым markdown-блоком (миграция сессии, не суммаризация).
- **dev-toolkit** — слэш-команды `/dev-toolkit:pr`, `/dev-toolkit:review`, `/dev-toolkit:review-last` для code review и подготовки PR (PHP/Go/JS) + защитный хук, блокирующий деструктивные Bash-команды (`rm -rf`, `git reset --hard`, `git push --force`, `git branch -D`, чтение `.env`) и случайную передачу секретов/токенов.
- **andrej-karpathy-skills** — поведенческие принципы Андрея Карпатого для уменьшения типичных ошибок LLM при написании кода (внешний плагин, автор: forrestchang).

## Установка

Выполни в Claude Code:

```bash
/plugin marketplace add https://github.com/Leonid74/ai-skills
/plugin install chat-handoff@leonid74-ai-skills
/plugin install dev-toolkit@leonid74-ai-skills
/plugin install andrej-karpathy-skills@leonid74-ai-skills
```

Или, после подключения маркетплейса, выбери плагины интерактивно:

```bash
/plugins
```

## Использование

### • chat-handoff

Срабатывает по описанию — достаточно написать в чате: «сделай хэндоф», «перенос в новый чат», «мигрируй сессию».

### • dev-toolkit

| Команда | Что делает |
|---|---|
| `/dev-toolkit:review` | Code review изменённых файлов (git diff) |
| `/dev-toolkit:review-last` | Code review последнего коммита |
| `/dev-toolkit:pr` | Подготовка Pull Request |

**Защитный хук** (`PreToolUse` на `Bash`) — срабатывает автоматически на каждой Bash-команде, блокирует с кодом 2 и возвращает модели понятное сообщение, *почему* отказано:

| Правило | Что ловит |
|---|---|
| Секреты | команда содержит `secret` / `password` / `token` |
| `rm -rf` | рекурсивное/принудительное удаление (`rm -rf`, `rm -r … -f`) |
| `git reset --hard` | потеря незакоммиченных изменений |
| `git push --force` | перезапись истории на remote (`--force`, `-f`, `--force-with-lease`) |
| `git branch -D` | принудительное удаление ветки |
| Чтение `.env` | `cat`/`less`/`head`/`tail`/`bat`… по `.env`-файлам |

Особенности:

- **Секреты проверяются первыми и блокируются без эхо команды** — текст команды (например `export TOKEN=…`) не возвращается модели и не попадает в логи. Для остальных правил команда показывается (она безопасна и полезна для диагностики).
- **Defense in depth.** Хук дополняет `permissions.deny` в `settings.json`: даёт явную причину блокировки и ловит то, что permissions не покрывают (например чтение `.env` разными утилитами).
- Посмотреть/отключить хук — меню `/hooks`.

### • andrej-karpathy-skills

Срабатывает по описанию — направляет работу Claude согласно принципам Андрея Карпатого: думать перед кодированием, минимальные изменения, простота, чёткие критерии успеха.

## Обновление

```bash
/plugin marketplace update leonid74-ai-skills
```

Обновление плагинов происходит только при изменении поля `version` в `plugin.json`.
Следи за релизами: [https://github.com/Leonid74/ai-skills](https://github.com/Leonid74/ai-skills)

---

## Для контрибьюторов

### Структура репозитория

```
ai-skills/
├── .claude-plugin/
│   └── marketplace.json              ← каталог маркетплейса (главный файл)
└── plugins/
    ├── chat-handoff/
    │   ├── .claude-plugin/plugin.json
    │   └── skills/chat-handoff/SKILL.md
    └── dev-toolkit/
        ├── .claude-plugin/plugin.json
        ├── commands/                 ← /dev-toolkit:pr, /dev-toolkit:review, /dev-toolkit:review-last
        │   ├── pr.md
        │   ├── review.md
        │   └── review-last.md
        └── hooks/guard-bash.sh       ← PreToolUse: деструктивные команды + секреты
```

> Плагин `andrej-karpathy-skills` подключён как внешний GitHub source ([multica-ai/andrej-karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills)) и не хранится локально в репозитории.

### Валидация

```bash
claude plugin validate ./ai-skills                      # marketplace.json
claude plugin validate ./ai-skills/plugins/chat-handoff # plugin.json + SKILL.md
claude plugin validate ./ai-skills/plugins/dev-toolkit  # plugin.json + команды + hooks.json
```

### Синхронизация vendor-копии chat-handoff

Скилл `chat-handoff` включён как vendor-копия из [Leonid74/ai-skill-chat-handoff](https://github.com/Leonid74/ai-skill-chat-handoff). При выходе новой версии синхронизируй вручную — скачай свежий `SKILL.md` напрямую из upstream:

```bash
curl -fsSL https://raw.githubusercontent.com/Leonid74/ai-skill-chat-handoff/main/SKILL.md \
  -o plugins/chat-handoff/skills/chat-handoff/SKILL.md
```

Если в upstream поднялась версия (frontmatter `version:` в `SKILL.md`), синхронно подними `version` в `plugins/chat-handoff/.claude-plugin/plugin.json` — иначе пользователи не получат обновление. После — закоммить и запушь.
