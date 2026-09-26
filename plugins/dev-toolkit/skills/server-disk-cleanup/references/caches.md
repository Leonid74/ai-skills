# Справочник: кеши и пакеты вне ядра скилла

Читается из `SKILL.md`, когда разведка нашла соответствующий каталог или менеджер. Все правила
`SKILL.md` действуют и здесь: согласие — только номерами в ответе на вопрос, адресные команды,
повторная проверка перед выполнением, рекурсивное удаление вне `/tmp` — пользователем через `! …`.
Группа — рекомендация по умолчанию; конкретный случай может поднять пункт в Б.

## Системные менеджеры пакетов

| Экосистема | Где смотреть размер | Команда очистки | Группа | Заметки |
|---|---|---|---|---|
| apt | `du -sh /var/cache/apt` | `sudo apt-get clean` | А | `apt autoremove --purge` — Б: сначала `apt-get -s autoremove`, в списке не должно быть работающего ядра |
| dnf / yum | `du -sh /var/cache/dnf /var/cache/yum` | `sudo dnf clean packages` | А | старые ядра — `sudo dnf remove --oldinstallonly` (Б, только если новое уже загружено) |
| snap | `snap list --all \| awk '/disabled/'`, `du -sh /var/lib/snapd` | `sudo snap remove <имя> --revision=<ревизия>` — по одной отключённой ревизии | Б | много отключённых ревизий — «найденная проблема»: `snap set system refresh.retain=2` |
| flatpak | `flatpak list --app --columns=application,size` | `flatpak uninstall --unused` (сначала без `-y`, показать список) | Б | |
| journald | `sudo journalctl --disk-usage` | `sudo journalctl --vacuum-time=<срок>` или `--vacuum-size=<размер>` | Б | удаляет историю логов необратимо; нет `SystemMaxUse` в `/etc/systemd/journald.conf` — «найденная проблема» |

## Контейнеры

| Экосистема | Где смотреть размер | Команда очистки | Группа | Заметки |
|---|---|---|---|---|
| podman | `podman system df -v`, `podman images`, `podman ps -a` | `podman rmi <ID…>`, `podman volume rm <имя>` | как Docker | правила Docker из `SKILL.md` — те же; `podman system prune` запрещён так же |
| логи контейнеров Docker | `sudo find /var/lib/docker/containers -name '*-json.log' -size +100M -exec du -sh {} +` | `sudo truncate -s 0 <файл-лога>` | Б | не `rm` (контейнер пишет в открытый файл); причина — нет `log-opts.max-size` в `/etc/docker/daemon.json` или в compose — «найденная проблема» |

## Кеши разработчика

| Экосистема | Где смотреть размер | Команда очистки | Группа | Заметки |
|---|---|---|---|---|
| npm | `du -sh ~/.npm/_cacache ~/.npm/_npx` | `npm cache clean --force` | А | не чистит `~/.npm/_npx` — отдельный пункт (рекурсивное удаление вне `/tmp` → пользователю) |
| yarn | `yarn cache dir` | `yarn cache clean` | А | |
| pnpm | `pnpm store path` | `pnpm store prune` | А | удаляет только пакеты, на которые не ссылается ни один проект |
| pip | `pip cache dir` | `pip cache purge` | А | |
| uv | `uv cache dir` | `uv cache clean` (или `uv cache prune`) | А | `~/.local/share/uv/{tools,python}` — установленное, не кеш |
| composer | `composer config --global cache-dir` | `composer clear-cache` | А | |
| go (сборка) | `go env GOCACHE` | `go clean -cache` | А | |
| go (модули) | `go env GOMODCACHE` | `go clean -modcache` | Б | сборки без сети перестанут работать до повторной загрузки |
| cargo (реестр) | `du -sh ~/.cargo/registry ~/.cargo/git` | — (нет штатной команды) | Б | рекурсивное удаление вне `/tmp` → пользователю |
| cargo `target/` | `du -sh <проект>/target` | `cargo clean` в каталоге проекта | А/Б | только если рядом `Cargo.toml` и дерево холодное; иначе «неопознанное» |
| `node_modules` | `du -sh <проект>/node_modules` | пользователю `! rm -rf -- '<путь>'` | Б | только если рядом `package.json` и проект холодный; восстановление — `npm ci` |
| gh CLI | `du -sh ~/.cache/gh` | `rm -- <путь>` для каждого `run-log-*.zip` | А | файлы, не каталоги |
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
| `~/.cache/ms-playwright` | браузеры Playwright | `npx playwright uninstall` (старые версии) |
| `~/.local/share/claude/versions` (текущая) | работающий Claude Code | не удалять |
