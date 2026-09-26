# Справочник: кеши и пакеты вне ядра скилла

Читается из `SKILL.md` до таблицы фазы 3, когда разведка нашла соответствующий каталог или
менеджер. Все правила `SKILL.md` действуют и здесь целиком (согласие, политика удаления, безопасный
путь, «Команды пользователю», секреты). Разведка с `sudo` — как `sudo -n …`; не прошёл — без
`sudo`, с пометкой о неполноте. Группа — рекомендация по умолчанию; конкретный случай может поднять
пункт в Б.

## Системные менеджеры пакетов

| Экосистема | Где смотреть размер | Команда очистки | Группа | Заметки |
|---|---|---|---|---|
| apt | `sudo -n du -sh /var/cache/apt` | `sudo apt-get clean` | А | `sudo apt-get -y autoremove --purge` — Б: список в таблице — из `sudo -n apt-get -s autoremove`, в нём не должно быть работающего ядра |
| dnf / yum | `du -sh /var/cache/dnf /var/cache/yum` | `sudo dnf clean packages` | А | ядра — `rpm -q kernel` против `uname -r`; старые — `sudo dnf -y remove --oldinstallonly` (Б, только если новое уже загружено; список в таблице — из `sudo -n dnf remove --oldinstallonly --assumeno`) |
| snap | `snap list --all \| awk '/disabled/'`, `du -sh /var/lib/snapd` | `sudo snap remove <имя> --revision=<ревизия>` — по одной отключённой ревизии | Б | много отключённых ревизий — «найденная проблема»: `snap set system refresh.retain=2` |
| flatpak | `flatpak list --columns=application,size` | `flatpak uninstall --unused` — **выполняет пользователь в отдельном терминале** | Б | список неиспользуемого команда покажет сама и спросит подтверждение; в неинтерактивном запуске без `-y` она ничего не делает, а с `-y` удалила бы список, которого пользователь не видел |
| journald | `sudo -n journalctl --disk-usage` | `sudo journalctl --vacuum-time=<срок>` или `--vacuum-size=<размер>` | Б | удаляет историю логов необратимо; нет `SystemMaxUse` в `/etc/systemd/journald.conf` — «найденная проблема» |

## Контейнеры

| Экосистема | Где смотреть размер | Команда очистки | Группа | Заметки |
|---|---|---|---|---|
| podman | `podman system df -v`, `podman images`, `podman ps -a` | `podman rmi <ID…>`, `podman volume rm <имя>` | как Docker | правила Docker из `SKILL.md` — те же; `podman system prune` запрещён так же |
| логи контейнеров Docker | драйвер — `docker info --format '{{.LoggingDriver}}'`; для `json-file` — `sudo -n find /var/lib/docker/containers -name '*-json.log' -size +100M -exec du -sh {} +` (маска в пути раскрылась бы до `sudo`, без прав на каталог) | `sudo truncate -s 0 -- <файл-лога>` (каталог — root) | Б | не `rm` (контейнер пишет в открытый файл); причина — нет `log-opts.max-size` в `/etc/docker/daemon.json` или в compose — «найденная проблема» |

## Кеши разработчика

| Экосистема | Где смотреть размер | Команда очистки | Группа | Заметки |
|---|---|---|---|---|
| npm | `du -sh ~/.npm/_cacache ~/.npm/_npx` | `npm cache clean --force` | А | не чистит `~/.npm/_npx` — отдельный пункт (рекурсивное удаление вне `/tmp` → пользователю) |
| yarn | `yarn cache dir` | `yarn cache clean` | А | |
| pnpm | `pnpm store path` | `pnpm store prune` | А | удаляет только пакеты, на которые не ссылается ни один проект; симуляции нет — в таблице так и написать (исключение из правила симуляции в `SKILL.md`) |
| pip | `pip cache dir` | `pip cache purge` | А | |
| uv | `uv cache dir` | `uv cache clean` (или `uv cache prune`) | А | `~/.local/share/uv/{tools,python}` — установленное, не кеш |
| composer | `composer config --global cache-dir` | `composer clear-cache` | А | |
| go (сборка) | `go env GOCACHE` | `go clean -cache` | А | |
| go (модули) | `go env GOMODCACHE` | `go clean -modcache` | Б | сборки без сети перестанут работать до повторной загрузки |
| cargo (реестр) | `du -sh ~/.cargo/registry ~/.cargo/git` | — (нет штатной команды) | Б | рекурсивное удаление вне `/tmp` → пользователю |
| cargo `target/` | `du -sh <проект>/target` | `cargo clean` в каталоге проекта | Б | только если рядом `Cargo.toml` и дерево холодное; иначе «неопознанное»; восстановление — пересборка |
| `node_modules` | `du -sh <проект>/node_modules` | пользователю `rm -rf -- <путь>` (через `!`) | Б | только если рядом `package.json` и проект холодный; восстановление — `npm ci` |
| gh CLI | `du -sh ~/.cache/gh` | пользователю `rm -rf -- <домашний каталог>/.cache/gh` (через `!`) | А | HTTP-кеш `gh` (хеш-подкаталоги), восстанавливается сам; каталог вне `/tmp` — удаляет пользователь |
| Claude Code | `ls -la ~/.local/share/claude/versions` | `rm -- <путь>` для каждой версии, кроме текущей | А | текущая — `claude --version` и цель `readlink -f "$(command -v claude)"` |

## Установлено, не кеш (удалять только менеджером)

Эти каталоги выглядят как кеш, но содержат установленные программы: `rm` сломает инструмент, а
«восстановление само» не произойдёт. По умолчанию — «не трогаю»; по просьбе пользователя — пункт Б
с командой менеджера.

| Каталог | Что это | Команда менеджера |
|---|---|---|
| `~/.rustup/toolchains` | тулчейны Rust | `rustup toolchain uninstall <тулчейн>` |
| `~/.nvm/versions` | версии Node.js | `nvm uninstall <версия>` |
| `~/.local/share/uv/tools`, `~/.local/share/uv/python` | CLI-инструменты и интерпретаторы uv | `uv tool uninstall <имя>`, `uv python uninstall <версия>` |
| `~/.pyenv/versions` | версии Python | `pyenv uninstall <версия>` |
| `~/.sdkman/candidates` | JDK, Gradle и т. п. | `sdk uninstall <кандидат> <версия>` |
| `~/.bun` | рантайм Bun и глобальные пакеты | `bun remove -g <пакет>` |
| `~/.cache/ms-playwright` | браузеры Playwright | **не** `npx playwright uninstall`: без `--all` он удаляет браузеры текущей версии. Старая ревизия (`chromium-<N>` при наличии большей `N`) — Б, `rm -rf -- <каталог>` пользователю через `!` |
| `~/.local/share/claude/versions` (текущая) | работающий Claude Code | не удалять |
