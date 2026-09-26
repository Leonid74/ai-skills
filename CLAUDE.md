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
        ├── skills/        ← review-code, todo-ship, statusline-setup, optimize-project-docs,
        │                     server-disk-cleanup
        ├── workflows/     ← review-code.js — конвейер review-code (dev-toolkit:review-code-pipeline)
        ├── tests/workflows/ ← стенд-заглушка для workflow-скрипта (моки agent/parallel/pipeline)
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

Для bash-хуков (`plugins/dev-toolkit/hooks/*.sh`) дополнительно гонять `shellcheck` и
тест-векторы guard-bash:

```bash
shellcheck -S style -o all plugins/dev-toolkit/hooks/guard-bash.sh
bash plugins/dev-toolkit/hooks/tests/test-guard-bash.sh
```

Для workflow-скрипта (`plugins/dev-toolkit/workflows/review-code.js`) — стенд-заглушка; `node --check`
к нему неприменим (top-level `return` — штатная форма workflow-скрипта):

```bash
node plugins/dev-toolkit/tests/workflows/test-review-code.mjs
```

## Workflow-скрипт review-code (ловушки)

- Тексты правил (ракурсы углов, skip-list, инварианты, протоколы, формат кандидата) в скрипте **не
  дублировать** — их передаёт скилл через `args` из своего `SKILL.md`. В скрипте только механика.
  Величины-зеркала `SKILL.md` — менять обе стороны синхронно: `LEVELS` («Таблица уровней»),
  `LENSES` (линзы `max`), `SECURITY_ANGLE`, `SWEEP_CAP` (фаза 2.5), `MERGE_THRESHOLD`/`MERGE_MAX`,
  `DEFAULT_WAVE`/`MIN_WAVE`/`MAX_WAVE`, `MAX_PATH_LENGTH` и перечень корней security-категорий в
  `isSecurity` («Оркестрация фаз 1–2.5»).
- Всё, что пришло от агента (путь, текст кандидата), — недоверенные данные: в текст заданий другим
  агентам только JSON-блоком, в ноты — через `showPath`; признаки от самого finder'а (security,
  категория) не должны влиять на то, какие кандидаты дойдут до верификации.
- Запуск агентов — только волнами (`runWaves`), не общим `parallel` по всему списку: волна из двух
  и более агентов без единого ответа трактуется как лимит использования, а не отказ агентов.
- Оба JS-файла — в формате Prettier с дефолтами: `npx --yes prettier@3 --check <файлы>`.
- `Date.now()`, `Math.random()`, `new Date()` без аргументов в скрипте запрещены средой (ломают
  resume); промпты агентов должны быть детерминированы — иначе кэш `resumeFromRunId` не сработает.
- `meta` — чистый литерал; `meta.name` не должен совпадать с именем скилла (`review-code` занят:
  плагинные workflow и скиллы делят неймспейс `dev-toolkit:<имя>`).
- Режим `Agent` из `SKILL.md` не удалять — это фолбэк для автономных вызовов (у `Workflow`
  обязательный opt-in пользователя) и для сессий с малым ориентиром размера workflow.

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

Правило read-only git/gh — механический барьер для инварианта 3 скилла review-code (префикс
`allowed-tools` вида `Bash(git diff:*)` авто-одобряет команду целиком и не запрещает подфлаги):
у `git diff/log/blame/show` блокируются `--output`/`-o`/`--ext-diff`/`--no-index`/`--exec`, у
`gh pr diff/view` — `--web`/`-w`/`-R`/`--repo`/`--exec`. Флаг-сеты раздельные (`-w` у git —
легитимный ignore-all-space, а у gh — браузер); long-опции git матчатся по **префиксу** (git
принимает однозначные сокращения вида `--outp=`), gh — точным совпадением (cobra сокращений не
принимает); скан флагов останавливается на `--` (дальше — пути). Тест-векторы:
`plugins/dev-toolkit/hooks/tests/test-guard-bash.sh`.

Правила секретов ловят **значения**, а не слова: известные форматы ключей (регистрозависимо,
`LC_ALL=C`, с границей слева — иначе `task-…` совпадёт с `sk-…`) и присваивание литерала ≥ 8
ASCII-символов имени `password`/`secret`/`token`/`api_key` (литерал с `$`, `/`, `~`, `.` в начале —
ссылка/путь, пропускается). Не возвращать правило «слово в любом месте команды» — оно блокировало
имена классов/тестов и не ловило ключей. Правило `.env` — **fail-closed по сегменту** (allowlist
`ls`/`stat`/`test`/`[`/`git status`/`git check-ignore`), а не список «читающих» утилит: перечислить
всех читателей невозможно. Фейковые токены в тест-векторах — только конкатенацией (`"gh""p_…"`):
иначе хук заблокирует запуск теста, а сканер секретов в CI примет фикстуру за ключ. Новые ассерты
проверять мутацией (`GUARD_BASH_HOOK=<копия хука>` подменяет проверяемый файл).

Известные принятые ограничения — см. `TODO.md` (сокращённые long-опции вида `--recu`, пробел внутри
пути при word-splitting, `echo rm -rf` как false positive, scope git/gh-барьера).

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
