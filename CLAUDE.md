# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Что это

`leonid74-ai-skills` — маркетплейс плагинов для Claude Code (`.claude-plugin/marketplace.json`).
Репозиторий не содержит приложения для сборки/тестирования в привычном смысле — это набор
декларативных артефактов плагинов (slash-команды, skills, hooks), которые Claude Code подключает
через `/plugin marketplace add`.

## Структура

```
ai-skills/
├── .claude-plugin/marketplace.json   ← каталог маркетплейса (главный файл, список плагинов)
└── plugins/
    ├── chat-handoff/                 ← vendor-копия из Leonid74/ai-skill-chat-handoff (см. ниже)
    │   ├── .claude-plugin/plugin.json
    │   └── skills/chat-handoff/SKILL.md
    └── dev-toolkit/
        ├── .claude-plugin/plugin.json
        ├── commands/      ← /dev-toolkit:pr, /dev-toolkit:cppr, /dev-toolkit:review-quick, /dev-toolkit:review-last
        ├── skills/        ← review-code, statusline-setup, optimize-project-docs
        └── hooks/
            ├── hooks.json       ← регистрация PreToolUse/Notification/Stop
            ├── guard-bash.sh    ← PreToolUse: блокирует деструктивные Bash-команды + секреты
            └── notify-sound.sh  ← Notification/Stop: звуковое уведомление
```

Плагин `andrej-karpathy-skills` подключён как внешний GitHub source
([multica-ai/andrej-karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills)) и не
хранится локально в этом репозитории — в `marketplace.json` у него `source.type: "url"`, а не путь.

## Валидация (нет автотестов — это и есть проверка перед коммитом)

```bash
claude plugin validate ./                                # marketplace.json
claude plugin validate ./plugins/chat-handoff             # plugin.json + SKILL.md
claude plugin validate ./plugins/dev-toolkit              # plugin.json + команды + hooks.json
```

Для bash-хуков (`plugins/dev-toolkit/hooks/*.sh`) дополнительно гонять `shellcheck`:

```bash
shellcheck -S style -o all plugins/dev-toolkit/hooks/guard-bash.sh
```

## Архитектура: guard-bash.sh (самый сложный артефакт в репозитории)

`plugins/dev-toolkit/hooks/guard-bash.sh` — PreToolUse-хук на `Bash`: получает JSON на stdin
(`.tool_input.command`), блокирует команду с exit 2 (текст из stderr возвращается модели) или
пропускает с exit 0. Это **эвристика по тексту команды, а не реальный shell-парсинг** — кавычки,
escaping, алиасы/функции, переменные в аргументах не учитываются (зафиксировано в `TODO.md`).

Составные команды (`&&`, `||`, `;`, `|`) разбираются на под-сегменты *до* применения правил —
иначе `/tmp`-исключение для `rm` ломается на цепочках вида `mkdir -p /tmp/x && rm -rf /tmp/x`
(проверка всей строки целиком блокировала бы безопасный кейс).

Детект рекурсивного `rm` — единственное правило файла с полноценной токенизацией по словам
(остальные правила — однострочный `grep -E`), потому что GNU `rm` пропускает флаги через
getopt-permutation: recursive-флаг может стоять и после операнда (`rm /home/x -r`). Команда внутри
сегмента ищется равенством токена (`rm`/`*/rm`), не вырезанием текста до последнего слова "rm" —
иначе слово "rm" внутри имени операнда (`rm -rf /home/rm-backup`) обрезает разбор раньше настоящих
флагов и глушит детект. Lowercase токена (`${_tok,,}`) используется только для регистронезависимого
опознания команды/флагов — сравнение операнда с `/tmp` идёт по исходному регистру, потому что `/tmp`
на Linux регистрочувствителен (`/TMP` ≠ `/tmp`). `set -f`/`set +f` вокруг токенизации отключает
pathname expansion — без него `rm -rf /tmp/*` раскрылся бы в реальные файлы `/tmp` на машине, где
запущен хук, а не остался текстовым паттерном.

Известные принятые ограничения — см. `TODO.md` (сокращённые long-опции вида `--recu`, пробел внутри
пути при word-splitting, `echo rm -rf` как false positive).

## Синхронизация vendor-копии chat-handoff

`plugins/chat-handoff/skills/chat-handoff/SKILL.md` — vendor-копия из
[Leonid74/ai-skill-chat-handoff](https://github.com/Leonid74/ai-skill-chat-handoff), не редактируется
напрямую. При обновлении upstream:

```bash
curl -fsSL https://raw.githubusercontent.com/Leonid74/ai-skill-chat-handoff/main/SKILL.md \
  -o plugins/chat-handoff/skills/chat-handoff/SKILL.md
```

Если в upstream поднялась версия (frontmatter `version:` в `SKILL.md`), синхронно поднять `version`
в `plugins/chat-handoff/.claude-plugin/plugin.json` — иначе пользователи не получат обновление
(Claude Code обновляет плагин только при изменении поля `version`).

## Версионирование плагинов

Версия каждого плагина живёт в его `.claude-plugin/plugin.json` (поле `version`). Обновление до
пользователей доходит только при изменении этого поля — бамп версии обязателен при любом
пользователь-видимом изменении плагина (новое правило хука, новый skill/команда, фикс поведения).
