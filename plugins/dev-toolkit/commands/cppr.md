---
allowed-tools: Bash(git status:*), Bash(git diff:*), Bash(git branch:*), Bash(git log:*), Bash(git checkout:*), Bash(git add:*), Bash(git commit:*), Bash(git push:*), Bash(gh pr create:*)
description: Commit, push, PR (коммит, пуш, PR)
---

## Контекст

- Текущий git статус: !`git status`
- Текущий git diff (staged и unstaged изменения): !`git diff HEAD`
- Текущая ветка: !`git branch --show-current`
- Недавние коммиты: !`git log --oneline -10`

## Твоя задача

На основании вышеуказанных изменений:

1. Определи стек проекта по файлам в корне и запусти соответствующие проверки. Убедись, что все зеленые:
   - **PHP** (`composer.json`): `composer test` / `./vendor/bin/phpunit`, `composer cs-check`, `composer phpstan`
   - **Go** (`go.mod`): `go build ./...`, `go vet ./...`, `go test ./...`, `golangci-lint run` (если установлен)
   - **JS/TS** (`package.json`): `npm test`, `npm run lint`, `npm run format:check` (или аналоги из секции `scripts`)
   - Другой стек — найди и запусти его тесты, линтер и проверку форматирования.
   Запускай только те команды, которые реально объявлены в проекте (`composer.json` → `scripts`, `package.json` → `scripts`, `Makefile`). Несуществующие пропускай, не выдумывай.
2. Создай новую ветку с осмысленным названием, если сейчас находишься в main/master. Если изменения разноплановые - предложи создать несколько веток.
3. Сгенерируй описание для коммита каждой ветки: что изменено и почему, предложи title в формате Conventional Commits.
4. Если в проекте существуют CLAUDE.md, README.md, CHANGELOG.md - последовательно обнови их с учетом всех изменений.
5. Создай один или несколько последовательных коммитов с вышеуказанными описаниями в нужной последовательности.
6. Запушь ветку/ветки в origin.
7. Подготовь Pull Request для текущей ветки и сгенерируй описание PR: что изменено и почему, предложи title в формате Conventional Commits.
8. Перечисли файлы, измененные относительно main/master.
9. Создай PR, используя `gh pr create`.
10. У тебя есть возможность вызывать несколько инструментов в одном ответе. Ты ДОЛЖЕН сделать все вышеперечисленное в одном сообщении. Не используй какие-либо другие инструменты и не делай ничего другого.
