# leonid74-ai-skills — личный маркетплейс плагинов для Claude Code

Каталог плагинов Leonid74 для Claude Code. Содержит два плагина:

- **chat-handoff** — скилл переноса контекста текущего диалога в новый чат одним готовым к вставке markdown-блоком (миграция сессии, не суммаризация). Vendor-копия из [Leonid74/ai-skill-chat-handoff](https://github.com/Leonid74/ai-skill-chat-handoff).
- **dev-toolkit** — слэш-команды `/pr`, `/review`, `/review-last` для code review и подготовки PR (PHP/Go/JS) + защитный PreToolUse-хук, блокирующий Bash-команды со словами `secret`/`password`/`token`.

## Структура

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
        ├── commands/                 ← /pr, /review, /review-last
        │   ├── pr.md
        │   ├── review.md
        │   └── review-last.md
        └── hooks/hooks.json          ← PreToolUse: блок secret/password/token
```

## Установка локально (для разработки)

```bash
# в Claude Code:
/plugin marketplace add ./ai-skills
/plugin install chat-handoff@leonid74-ai-skills
/plugin install dev-toolkit@leonid74-ai-skills
```

## Установка из GitHub (после публикации)

```bash
/plugin marketplace add Leonid74/ai-skills
/plugin install chat-handoff@leonid74-ai-skills
/plugin install dev-toolkit@leonid74-ai-skills
```

Команды плагина вызываются с namespace: `/dev-toolkit:review`, `/dev-toolkit:pr`, `/dev-toolkit:review-last`. Скилл `chat-handoff` срабатывает по описанию (триггер-фразы вроде «сделай хэндоф», «перенос в новый чат»).

## Валидация

```bash
claude plugin validate ./ai-skills                      # marketplace.json
claude plugin validate ./ai-skills/plugins/chat-handoff # plugin.json + SKILL.md
claude plugin validate ./ai-skills/plugins/dev-toolkit  # plugin.json + команды + hooks.json
```

## Обновление

После пуша новых коммитов пользователи обновляют каталог:

```bash
/plugin marketplace update leonid74-ai-skills
```

> Обновление приходит пользователям только при изменении поля `version` в `plugin.json` соответствующего плагина. Поднимай версию на каждом релизе.

## Синхронизация vendor-копии chat-handoff

Скилл `chat-handoff` включён как копия (vendor), а не как внешний github-source, поэтому при выходе новой версии в upstream синхронизировать нужно вручную:

```bash
# взять свежий SKILL.md из upstream-клона
cp ~/.claude/skills/chat-handoff/SKILL.md \
   plugins/chat-handoff/skills/chat-handoff/SKILL.md
```

Затем, если в upstream поднялась версия (frontmatter `version:` в `SKILL.md`), синхронно подними `version` в `plugins/chat-handoff/.claude-plugin/plugin.json` — иначе пользователи не получат обновление (Claude Code сверяет именно версию плагина). После — закоммить и запушь.
