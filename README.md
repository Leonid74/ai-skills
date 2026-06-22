# leonid74-ai-skills — маркетплейс плагинов для Claude Code

Каталог плагинов для Claude Code. Доступные плагины:

- **andrej-karpathy-skills** — поведенческие принципы Андрея Карпатого для
  уменьшения типичных ошибок LLM при написании кода *(внешний плагин,
  автор: forrestchang)*.

- **chat-handoff** — переносит контекст текущего диалога в новый чат одним
  готовым markdown-блоком *(миграция сессии, не суммаризация)*.

- **dev-toolkit** — инструменты повседневной разработки на PHP/Go/JS:
  - *Slash-команды:* `/dev-toolkit:review`, `/dev-toolkit:review-last`,
    `/dev-toolkit:pr`, `/dev-toolkit:cppr` — code review и подготовка PR
  - *Skills:* `statusline-setup` — настройка строки статуса Claude Code;
    `optimize-project-docs` — оптимизация и реконсиляция `CLAUDE.md` / `README` / памяти проекта
  - *Хук защиты:* блокирует деструктивные Bash-команды (`rm -rf`,
    `git reset --hard`, `git push --force`, `git branch -D`, чтение `.env`)
    и случайную передачу секретов/токенов
  - *Хук уведомлений:* звуковой сигнал, когда Claude ждёт ответа или
    завершил работу

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

### andrej-karpathy-skills

Срабатывает по описанию — направляет работу Claude согласно принципам
Андрея Карпатого: думать перед кодированием, минимальные изменения,
простота, чёткие критерии успеха.

---

### chat-handoff

Срабатывает по описанию — достаточно написать в чате: «сделай хэндоф»,
«перенос в новый чат», «мигрируй сессию».

---

### dev-toolkit

#### Slash-команды

| Команда                    | Что делает                               |
|----------------------------|------------------------------------------|
| `/dev-toolkit:review`      | Code review изменённых файлов (git diff) |
| `/dev-toolkit:review-last` | Code review последнего коммита           |
| `/dev-toolkit:pr`          | Подготовка Pull Request                  |
| `/dev-toolkit:cppr`        | Коммит, пуш и создание PR одной командой |

#### Skill: statusline-setup

Настройка строки статуса Claude Code (модель, git-ветка, папка).

Срабатывает автоматически по описанию — достаточно написать в чате:
«настрой statusline», «setup statusline», «установи statusline». Skill
проверяет текущий `~/.claude/settings.json` и, если `statusLine` не настроен,
создаёт `~/.claude/statusline.sh` и прописывает конфигурацию.

#### Skill: optimize-project-docs

Оптимизация и реконсиляция проектной документации: сжать раздутый `CLAUDE.md`,
почистить память проекта Claude Code (`MEMORY.md` + каталог `memory/`) и
синхронизировать факты между `CLAUDE.md`, `README` и памятью — **без потери
обоснований «почему»**. Это оптимизация существующих доков, не написание новых.

Срабатывает автоматически по описанию — достаточно написать в чате: «оптимизируй
CLAUDE.md», «почисти память проекта», «полная реконсиляция документации»,
«optimize project docs». Skill режет только устаревшее / дубли / противоречия /
воду, сохраняя иерархию детализации (память подробнее `CLAUDE.md` подробнее
`README`), измеряет объём ДО/ПОСЛЕ и передаёт коммит в `/dev-toolkit:cppr`.

#### Хук: защита от деструктивных команд

`PreToolUse` на `Bash` — срабатывает автоматически на каждой Bash-команде,
блокирует с кодом 2 и возвращает модели понятное сообщение, *почему* отказано:

| Правило            | Что ловит                                                             |
|--------------------|-----------------------------------------------------------------------|
| Секреты            | команда содержит `secret` / `password` / `token`                      |
| `rm -r`/`rm -rf`/`rm --recursive` | рекурсивное удаление — флаг ловится в любой позиции аргументов (`rm -v -r x`, `rm x -r`) и в короткой, и в длинной форме, в т.ч. в составных командах (`a && b`, `;`, `\|`, `\|\|`); **исключение: `/tmp` и его содержимое разрешены** |
| `git reset --hard` | потеря незакоммиченных изменений                                      |
| `git push --force` | перезапись истории на remote (`--force`, `-f`, `--force-with-lease`)  |
| `git branch -D`    | принудительное удаление ветки (безопасный `-d` пропускается)          |
| Чтение `.env`      | `cat`/`less`/`head`/`tail`/`bat`… по `.env`-файлам                   |

Особенности:

- **Секреты проверяются первыми и блокируются без эхо команды** — текст команды
  (например `export TOKEN=…`) не возвращается модели и не попадает в логи.
  Для остальных правил команда показывается (она безопасна и полезна для диагностики).
- **Defense in depth.** Хук дополняет `permissions.deny` в `settings.json`:
  даёт явную причину блокировки и ловит то, что permissions не покрывают
  (например чтение `.env` разными утилитами).
- Посмотреть/отключить хук — меню `/hooks`.

#### Хук: звуковые уведомления

`Notification` + `Stop` — воспроизводят сигнал, когда Claude ждёт твоего
ответа/разрешения и когда завершил работу:

| Событие        | Когда срабатывает                 | Звук                         |
|----------------|-----------------------------------|------------------------------|
| `Notification` | Claude ждёт ответа или разрешения | `message` (1 гудок fallback) |
| `Stop`         | Claude закончил работу            | `complete` (2 гудка fallback)|

Особенности:

- **Универсальный подбор бэкенда.** Скрипт `notify-sound.sh` перебирает плееры
  (`pw-play` → `paplay` → `ffplay` → `play` → `aplay` → `canberra-gtk-play`)
  и системные звуки (`/usr/share/sounds/freedesktop/…`). Если плеера нет
  (например чистая tmux/SSH-сессия) — падает на **terminal bell** (`\a`):
  разное число гудков для двух событий.
- **Никогда не блокирует Claude** — хук всегда завершается кодом 0.
- Посмотреть/отключить — меню `/hooks`.

**Куда уйдёт звук при работе через SSH**

Хук исполняется **на той машине, где запущен Claude Code**. Если ты
подключаешься с ноутбука по ssh/tmux к серверу, важно, какой из двух
механизмов сработает:

- **Terminal bell (`\a`) — дойдёт до ноутбука.** Звонок — это байт `0x07`
  в потоке вывода терминала. Он едет по тому же каналу, что и весь текст:
  хук на сервере → tmux (при `bell-action any` пробрасывает звонок клиенту)
  → SSH → твой локальный эмулятор терминала пикает. Звук издаёт
  **локальный терминал на ноутбуке**, поэтому ты его слышишь.
- **Системные мелодии через плеер (`paplay` и т.п.) — останутся на сервере.**
  Плеер рендерит звук в звуковую карту той машины, где исполняется хук.
  SSH по умолчанию аудио не пробрасывает (в отличие от текстового потока
  и опционального X11), а на сервере звуковой карты обычно и нет. Чтобы
  мелодия с сервера зазвучала на ноутбуке, понадобилась бы сетевая
  переадресация PulseAudio/PipeWire — отдельная нетривиальная настройка.

**Вывод:** при работе по ssh/tmux выбирай **Вариант A (terminal bell)** —
только он реально доходит до ноутбука. **Вариант B (плеер)** имеет смысл,
когда Claude Code запускается прямо на ноутбуке в десктоп-сессии.

<details>
<summary>Вариант A. Только terminal bell (без установки пакетов)</summary>

Подходит, когда работаешь в терминале/tmux/SSH и не хочешь ставить плеер.
По умолчанию tmux перехватывает символ звонка (`\a`) и не пробрасывает его
в эмулятор терминала — чтобы гудок было слышно, добавь в `~/.tmux.conf`:

```tmux
# Пробрасывать звонок (bell) во все окна и в эмулятор терминала
set -g bell-action any
set -g visual-bell off
```

Применить без перезапуска tmux:

```bash
tmux source-file ~/.tmux.conf
```

Затем включи **audible bell** в самом эмуляторе терминала (GNOME Terminal:
*Preferences → Profile → Terminal bell*; Konsole, xterm и др. — аналогично).
Без поддержки звонка на стороне эмулятора гудка не будет — это ограничение
терминала, а не хука.

</details>

<details>
<summary>Вариант B. Системные мелодии (через плеер)</summary>

Даёт нормальный звук вместо гудка — отдельные мелодии для «жду ответа»
и «готово». Поставь плеер и тему звуков:

```bash
# Debian/Ubuntu
sudo apt install pulseaudio-utils sound-theme-freedesktop

# Fedora
sudo dnf install pulseaudio-utils sound-theme-freedesktop

# Arch
sudo pacman -S libpulse sound-theme-freedesktop
```

`pulseaudio-utils` даёт `paplay`, `sound-theme-freedesktop` — файлы
`/usr/share/sounds/freedesktop/stereo/{message,complete}.oga`. Скрипт
подхватит их автоматически, правок не требуется. Проверить вручную:

```bash
paplay /usr/share/sounds/freedesktop/stereo/complete.oga
```

> Помни про SSH-нюанс выше: мелодии плеера звучат на машине, где запущен
> Claude Code, и для них нужен работающий звуковой сервер (PipeWire/PulseAudio)
> и аудиоустройство. Для звука именно на ноутбуке через ssh/tmux используй
> Вариант A.

</details>

## Обновление

> Если в настройках маркетплейса (меню `/plugin`) **не включено автообновление** этих плагинов, обновляй их вручную командами ниже. При включённом автообновлении свежие версии подтягиваются сами, и эти шаги не нужны.

Сначала обнови каталог маркетплейса, затем нужные плагины. Скиллы (`statusline-setup`, `optimize-project-docs`, `chat-handoff`) обновляются вместе со своим плагином — отдельной команды для них нет.

```bash
/plugin marketplace update leonid74-ai-skills
/plugin update chat-handoff@leonid74-ai-skills
/plugin update dev-toolkit@leonid74-ai-skills
/plugin update andrej-karpathy-skills@leonid74-ai-skills
```

Обновление плагинов происходит только при изменении поля `version` в `plugin.json`.
Следи за релизами: [https://github.com/Leonid74/ai-skills](https://github.com/Leonid74/ai-skills)

---

## Для контрибьюторов

См. также [`CLAUDE.md`](./CLAUDE.md) — инструкции для Claude Code по работе в этом репозитории
(структура, валидация, архитектура `guard-bash.sh`).

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
        ├── commands/                 ← /dev-toolkit:pr, /dev-toolkit:cppr, /dev-toolkit:review, /dev-toolkit:review-last
        │   ├── pr.md
        │   ├── cppr.md
        │   ├── review.md
        │   └── review-last.md
        ├── skills/                   ← statusline-setup, optimize-project-docs
        │   ├── statusline-setup/SKILL.md
        │   └── optimize-project-docs/SKILL.md
        └── hooks/
            ├── hooks.json            ← регистрация хуков (PreToolUse, Notification, Stop)
            ├── guard-bash.sh         ← PreToolUse: деструктивные команды + секреты
            └── notify-sound.sh       ← Notification/Stop: звуковое уведомление
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
