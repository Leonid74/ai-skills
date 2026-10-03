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
        │                     server-disk-cleanup, debug
        ├── workflows/     ← review-code.js — конвейер review-code (dev-toolkit:review-code-pipeline)
        ├── tests/workflows/ ← стенд-заглушка для workflow-скрипта (моки agent/parallel/pipeline)
        ├── tests/statusline/ ← тест шаблона statusline.sh из SKILL.md скилла statusline-setup
        └── hooks/
            ├── hooks.json       ← регистрация PreToolUse/SessionStart/Notification/Stop
            ├── guard-bash.sh    ← PreToolUse: блокирует деструктивные Bash-команды + секреты
            ├── notify-sound.sh  ← Notification/Stop: звуковое уведомление
            └── post-compact-reminder.sh ← SessionStart(compact): напоминание после компакции
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
тест-векторы хуков (guard-bash, post-compact-reminder):

```bash
shellcheck -S style -o all plugins/dev-toolkit/hooks/guard-bash.sh plugins/dev-toolkit/hooks/post-compact-reminder.sh
bash plugins/dev-toolkit/hooks/tests/test-guard-bash.sh
bash plugins/dev-toolkit/hooks/tests/test-post-compact-reminder.sh
```

Для workflow-скрипта (`plugins/dev-toolkit/workflows/review-code.js`) — стенд-заглушка; `node --check`
к нему неприменим (top-level `return` — штатная форма workflow-скрипта):

```bash
node plugins/dev-toolkit/tests/workflows/test-review-code.mjs
```

Для шаблона `statusline.sh` (блок кода в `plugins/dev-toolkit/skills/statusline-setup/SKILL.md`) — тест с
заглушками `tmux`/`timeout` в `PATH`; настоящий tmux он не вызывает. Мутационная проверка —
`STATUSLINE_TEMPLATE=<копия шаблона>`:

```bash
bash plugins/dev-toolkit/tests/statusline/test-statusline-template.sh
```

## Workflow-скрипт review-code (ловушки)

- Тексты правил (ракурсы углов, skip-list, инварианты, протоколы, формат кандидата) в скрипте **не
  дублировать** — их передаёт скилл через `args` из своего `SKILL.md`. В скрипте только механика.
  Величины-зеркала `SKILL.md` — менять обе стороны синхронно: `LEVELS` («Таблица уровней»),
  `LENSES` (линзы `max`), `SECURITY_ANGLE`, `SWEEP_CAP` (фаза 2.5), `NO_SELF_SUPPRESS` (пункт 1
  skip-list), `MERGE_THRESHOLD`/`MERGE_MAX`, `DEFAULT_WAVE`/`MIN_WAVE`/`MAX_WAVE`, `MAX_PATH_LENGTH`
  и перечень корней security-категорий в `isSecurity` («Оркестрация фаз 1–2.5»).
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
пропускает с exit 0. Это **эвристика по тексту команды, а не реальный shell-парсинг**: лексер
`_lex` разбирает кавычки для правила `.env`, но правила `rm`, git/gh и вывода окружения режут текст
построчно `sed` и кавычек не видят; алиасы/функции и переменные в аргументах не учитываются нигде
(зафиксировано в `TODO.md`). `.tool_input.command` не строка (массив/объект) — ошибка `jq`, то есть
блок. Любой выход, кроме 0 и 2
(падение под `set -euo pipefail`), `trap EXIT` превращает в блокировку — код 1 Claude Code считает
неблокирующей ошибкой и выполнил бы команду. `printf … | grep -q` не использовать: под `pipefail`
ранний выход `grep -q` даёт SIGPIPE, и условие становится ложным — только here-string `<<<`.

Составные команды (`&&`, `||`, `;`, `|`) разбираются на под-сегменты *до* применения правил —
иначе `/tmp`-исключение для `rm` ломается на цепочках вида `mkdir -p /tmp/x && rm -rf /tmp/x`
(проверка всей строки целиком блокировала бы безопасный кейс).

**Исключения «текст, а не команда» даёт только шаблон сообщений (`_tpl_try`)**, не лексер. Команда-
сообщение — `git [-c user.name=|-c user.email=|-C <путь>] commit <флаги> -m "…"`/`-F <путь>`/`-F -`,
`gh pr|issue create|edit|comment|merge [N] <флаги> --title/--body "…"`/`--body-file`, одиночный
`echo`/`printf`; с here-doc — `-F -`/`--body-file -` `<<'EOF'` в конце строки и `-m "$(cat <<'EOF'` …
`EOF` / `)"`. Она ищется в цепочке: **префикс** до неё проходит простой сканер кавычек (на `$(`, `` ` ``,
`<<`, скобках, `{`, комментарии поиск прекращается), **хвост** после разделителя `;`/`&&`/`||`/перевода
строки дописывается как есть (в нём ищется следующая команда-сообщение), конвейер `|` сразу после неё —
не шаблон (`git commit -m ".env" | xargs cat`). Текст сообщения (без `$`/`` ` ``/`\`) заменяется на
`MSG`, тело here-doc отбрасывается; префикс, пути, флаги и хвост остаются в `_scmd`, её судят все
правила (секреты — исходную строку). Всё, что не подошло, проверяется целиком, тела here-doc — как
строки команд. **Не возвращать решение «данные/код» лексеру**: первая версия 2.3.1
так делала, и два прохода ревью нашли десять расхождений лексера с bash (`${x:-<<EOF}`, `<<<` в
`$( )`, `$'EOF'`, `#` в `$( )`, CRLF, `EOF)`, `$(` после разделителя, конвейер в теле, `2>` как вывод
в файл, `coproc`) — каждое прятало настоящие команды за «данными». Расширять грамматику шаблона —
только с тест-векторами на границы и мутационной проверкой. **Бюджет шаблона** — команды до 16 КБ и
не более 8 вызовов `_tpl_try` (`_tpl_budget`): рекурсия по цепочке без потолка давала кубическое время
(632 × `git commit -m "x" &&` — 614 с, за таймаутом, а при таймауте хук команду не блокирует); сверх
бюджета остаток проверяется целиком. Команда длиннее `_LX_MAX` (32 КБ)
лексером не разбирается — `.env` ищется грубо по всей строке. Разбор идёт по байтам под `LC_ALL=C`
и кусками (`sed` + `mapfile`), не
`${s:i:1}`: подстрока в bash — O(длины строки), посимвольный обход был квадратичным и выводил хук
за таймаут 600 с (при таймауте PreToolUse-хук команду не блокирует); `local LC_ALL` в функции на
каждый токен не ставить — `setlocale` на входе/выходе стоит секунды.

Детект рекурсивного `rm` токенизирует сегмент по словам (как и правило `.env` — по токенам
лексера; остальные правила — однострочный `grep -E`), потому что GNU `rm` пропускает флаги через
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
`ls`/`stat`/`test`/`[`/`[[`/`git status`/`git check-ignore`), а не список «читающих» утилит: перечислить
всех читателей невозможно. Токен сверяется после снятия кавычек и `\` **по правилам bash**
(`_env_unquote`: в `"…"` `\` остаётся перед обычным символом — `grep "\.env"` это регулярка, а не
путь; `$'…'` раскрывается через `${x@E}`), с glob-хвостом (`.env*`, `.env{,}`, `.env~`),
присваиваниями (`f=.env`) и слитным значением короткой опции (`-F.env`). Цель редиректа — всегда
путь и блокирует даже allowlist (`ls > .env`, `git check-ignore --stdin < .env`); allowlist git — только
`status`/`check-ignore` **сразу** после `git` (`git -c core.fsmonitor=… status` исполняет конфиг).
Упоминание `.env` в тексте сообщения до правила не доходит — его заменил шаблон (см. выше); флаги
шаблона сверяются **точно и с учётом регистра** (`-Fm` — это `-F m`, у gh `-T` — шаблон-файл, `-c`
у git — только `user.name`/`user.email`: прочие ключи исполняют код). Подстановка `$(`/`` ` ``/`<(`
(в том числе `$\⏎(`) в сегменте блокирует `.env` даже у
allowlist-команды (`ls $(cat .env)`). Неполный glob (`.en?`) и путь через переменную/файл-посредник
текстом не различимы — принятое ограничение, закрывает sandbox ОС. Фейковые токены в тест-векторах — только конкатенацией (`"gh""p_…"`):
иначе хук заблокирует запуск теста, а сканер секретов в CI примет фикстуру за ключ. Новые ассерты
проверять мутацией (`GUARD_BASH_HOOK=<копия хука>` подменяет проверяемый файл).

Известные принятые ограничения — см. `TODO.md` (сокращённые long-опции вида `--recu`, пробел внутри
пути при word-splitting, `echo rm -rf` в цепочке/конвейере как false positive — одиночный `echo`/`printf`
шаблон сообщений пропускает как текст, scope git/gh-барьера).

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
