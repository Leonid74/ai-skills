---
allowed-tools: Bash(git checkout --branch:*), Bash(git add:*), Bash(git status:*), Bash(git log:*), Bash(git push:*), Bash(git commit:*), Bash(gh pr create:*)
description: Подготовить Pull Request — прогнать проверки проекта, описать изменения, предложить title в формате Conventional Commits
---

## Контекст

- Текущий git статус: !`git status`
- Текущий git diff (staged и unstaged изменения): !`git diff HEAD`
- Текущая ветка: !`git branch --show-current`
- Недавние коммиты: !`git log --oneline -10`

## Твоя задача

На основании вышеуказанных изменений подготовь Pull Request для текущей ветки.

1. Определи стек проекта по файлам в корне и запусти соответствующие проверки. Убедись, что все зеленые:
   - **PHP** (`composer.json`): `composer test` / `./vendor/bin/phpunit`, `composer cs-check`, `composer phpstan`
   - **Go** (`go.mod`): `go build ./...`, `go vet ./...`, `go test ./...`, `golangci-lint run` (если установлен)
   - **JS/TS** (`package.json`): `npm test`, `npm run lint`, `npm run format:check` (или аналоги из секции `scripts`)
   - Другой стек — найди и запусти его тесты, линтер и проверку форматирования.
   Запускай только те команды, которые реально объявлены в проекте (`composer.json` → `scripts`, `package.json` → `scripts`, `Makefile`). Несуществующие пропускай, не выдумывай.
2. Сгенерируй описание PR: что изменено и почему.
3. Перечисли файлы, измененные относительно main.
4. Предложи title в формате Conventional Commits.
5. Если в проекте существуют CLAUDE.md, README.md, CHANGELOG.md - обнови их с учетом всех изменений.
6. Создай PR, используя `gh pr create`.
7. У тебя есть возможность вызывать несколько инструментов в одном ответе. Ты ДОЛЖЕН сделать все вышеперечисленное в одном сообщении. Не используй какие-либо другие инструменты и не делай ничего другого.
