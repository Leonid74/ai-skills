---
description: Подготовить Pull Request — прогнать проверки проекта, описать изменения, предложить title в формате Conventional Commits
---

Подготовь Pull Request для текущей ветки.

1. Определи стек проекта по файлам в корне и запусти соответствующие проверки. Убедись, что все зелёные:
   - **PHP** (`composer.json`): `composer test` / `./vendor/bin/phpunit`, `composer cs-check`, `composer phpstan`
   - **Go** (`go.mod`): `go build ./...`, `go vet ./...`, `go test ./...`, `golangci-lint run` (если установлен)
   - **JS/TS** (`package.json`): `npm test`, `npm run lint`, `npm run format:check` (или аналоги из секции `scripts`)
   - Другой стек — найди и запусти его тесты, линтер и проверку форматирования.
   Запускай только те команды, которые реально объявлены в проекте (`composer.json` → `scripts`, `package.json` → `scripts`, `Makefile`). Несуществующие пропускай, не выдумывай.
2. Сгенерируй описание PR: что изменено и почему.
3. Перечисли файлы, изменённые относительно main.
4. Предложи title в формате Conventional Commits.
