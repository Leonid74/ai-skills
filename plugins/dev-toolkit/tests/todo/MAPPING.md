# Соответствие стенда `test-todo.sh` тесту `TodoScriptTest.php`

Источник: apps-b24-platform `tests/Unit/Scripts/TodoScriptTest.php` на `179a5db` (#388): 38 методов
`#[Test]`, 187 случаев с наборами данных. Скрипт — копия `scripts/todo.sh` на `a0bcd62` (после
`179a5db` скрипт не менялся).

Имя проверки стенда — `метод[ключ набора данных]`, как в PHP. Стенд сам считает случаи и методы
и падает, если при полном наборе awk их не 187 и не 38. Сверка 1:1 с PHP — по выгрузке ключей
провайдеров (рефлексией по тексту теста): список имён совпал целиком. Колонка «awk»: `A` — цикл по
всем вариантам awk, `1` — один раз под системным awk, как в PHP.

| # | Метод PHP | Случаев | awk | Функция стенда |
|---|---|---|---|---|
| 1 | `closeMovesRecordToArchiveByteForByte` | 1 | A | `t_close_moves_byte_for_byte` |
| 2 | `closeMovesMiddleRecordAndKeepsNeighbours` | 1 | A | `t_close_middle` |
| 3 | `closeMovesLastRecordAndSeparatesItInArchive` | 1 | A | `t_close_last` |
| 4 | `closeRefusalLeavesBothFilesUntouched` | 23 | A | `cr` / `b_cr` |
| 5 | `newAppendsRecordAndRewritesCounter` | 1 | A | `t_new_appends` |
| 6 | `newRejectsInvalidInput` | 34 | A | `nr` / `b_nr` |
| 7 | `newAcceptsHeadingInsideCodeFence` | 1 | A | `t_new_fence` |
| 8 | `missingCounterIsRestoredFromBothFiles` | 1 | A | `t_missing_counter` |
| 9 | `checkPassesOnValidFiles` | 1 | A | `t_check_passes` |
| 10 | `checkReportsViolation` | 43 | A | `cv` / `b_cv` |
| 11 | `refsRespectsNumberBoundary` | 1 | 1 | `t_refs_boundary` |
| 12 | `pathsComeFromOptionsNotFromProjectLayout` | 1 | 1 | `t_paths_from_options` |
| 13 | `numbersInsideArchivedRecordsAreNotOccupiedNumbers` | 1 | A | `t_numbers_inside_archived` |
| 14 | `closeReadsTypeFromFieldBlockOnly` | 1 | A | `t_close_type_from_fields` |
| 15 | `refusedNewDoesNotCreateMissingCounter` | 1 | A | `t_refused_new_counter` |
| 16 | `symlinkedFilesAreRefused` | 1 | A | `t_symlinks` |
| 17 | `relativePathWithEqualsSignIsReadAsFile` | 1 | A | `t_relative_equals` |
| 18 | `closeTouchesNeitherFileWhenListCannotBeReplaced` | 1 | 1 | `t_ro_dir` |
| 19 | `refsSearchesWholeRepositoryFromSubdirectory` | 1 | 1 | `t_refs_repo` |
| 20 | `closeWorksOnArchiveLargerThanPipeBuffer` | 1 | A | `t_close_big_archive` |
| 21 | `whitespaceOnlyLineUnderFirstArchiveHeadingIsBlank` | 1 | A | `t_whitespace_line` |
| 22 | `codeFenceUnderFirstArchiveHeadingGivesSingleError` | 1 | A | `t_code_fence_single_error` |
| 23 | `inlineFenceLineUnderFirstArchiveHeadingDoesNotOpenBlock` | 1 | A | `t_inline_fence` |
| 24 | `malformedFirstArchiveRecordHeadingKeepsItsOwnReason` | 1 | A | `t_malformed_first` |
| 25 | `plantedTempSymlinkIsNotFollowed` | 1 | 1 | `t_planted_tmp` |
| 26 | `restoredCounterNeverCarriesControlCharacters` | 1 | A | `t_restored_counter_ctrl` |
| 27 | `closeMovesCompositeWithoutOpenLines` | 6 | A | `cm` / `b_cm` |
| 28 | `closeRefusesCompositeWithOpenLine` | 48 | A | `co` / `b_co` |
| 29 | `closeRefusalListsEveryOpenLine` | 1 | A | `t_lists_every_open_line` |
| 30 | `flagsAloneDoNotCloseLegacyShapedComposite` | 1 | A | `t_legacy_shaped` |
| 31 | `openLastLineOfLastCompositeIsReported` | 1 | A | `t_open_last_line` |
| 32 | `plainTaskBelowArchivedCompositeIsNotJudged` | 1 | A | `t_plain_below_composite` |
| 33 | `tabIsSpelledOutInRefusal` | 1 | A | `t_tab_spelled_out` |
| 34 | `listUnderIntroLineIsReportedItemByItem` | 1 | A | `t_list_under_intro` |
| 35 | `refusalNeverPrintsControlCharactersFromRecordText` | 1 | A | `t_no_ctrl_in_refusal` |
| 36 | `closeOfPlainTaskIgnoresCheckboxLines` | 1 | A | `t_plain_task_checkboxes` |
| 37 | `closeCompositeLargerThanPipeBuffer` | 1 | A | `t_big_composite` |
| 38 | `ciRunsScriptUnderMawk` | 1 | 1 | `t_ci_mawk` |

Итого: 33 метода без провайдера + 23 + 34 + 43 + 6 + 48 = 187 случаев.

## Перенесено не 1:1

- **`refsSearchesWholeRepositoryFromSubdirectory`.** В PHP — живой репозиторий проекта, задача №96 и
  его `CHANGELOG.md`. Здесь — синтетический git-репозиторий во временном каталоге: №96 упомянут
  только в `CHANGELOG.md` в корне, запуск из подкаталога `scripts/` без путей. Проверки те же: код 0
  и `../CHANGELOG.md:` в выводе. Пропуск — если нет git или не удалось создать репозиторий (в PHP —
  если рабочая копия не git).
- **`pathsComeFromOptionsNotFromProjectLayout`.** Запрещённые литералы те же (`apps-b24`, `artisan`,
  `php `), но ищутся в тексте проверяемого скрипта (`TODO_SH`), а не в `scripts/todo.sh` проекта.
- **`closeRefusalListsEveryOpenLine`.** Вместо `mb_check_encoding($err, 'UTF-8')` —
  `iconv -f UTF-8 -t UTF-8`.
- **`refusalNeverPrintsControlCharactersFromRecordText`.** Регулярка
  `/[\x00-\x09\x0b-\x1f\x7f]|\xc2[\x80-\x9f]/` — та же, через `grep -aP` под `LC_ALL=C`.
- **`ciRunsScriptUnderMawk`.** Как в PHP, вне CI (пустая `CI`) пропускается. Варианты awk стенд
  ищет через `command -v`, а не по путям `/usr/bin/<имя>`.
- **Варианты awk.** К трём вариантам PHP (системный, mawk, gawk) добавлен busybox awk.
- **Изоляция.** Каталог фикстуры свежий на каждую проверку: на каждый случай и каждый вариант awk. В
  PHP один каталог на метод, а `resetFixture()` вызывается на каждой итерации по awk. Каталоги
  `.bin-<awk>` лежат в корне стенда, а не в каталоге фикстуры.
- **Ассерты.** PHP останавливает метод на первом упавшем ассерте, и остальные варианты awk этого
  случая не проверяются. Стенд проверяет все ассерты под каждым вариантом awk.
- **Таймаут.** Вызов скрипта идёт под `timeout 60`, как и умолчание Symfony Process (60 с).

## Случаи плагина (в PHP их нет)

Имя начинается с «plugin:», в учёт 187 случаев не входят; идут под каждым вариантом awk, их число (5 методов)
стенд сверяет сам.

- **`closePlantedTempSymlinkIsNotFollowed`** — R1 со стороны `close`: подложенные ссылки на предсказуемых
  именах временных файлов списка и архива не ведут запись в чужой файл.
- **`closeRefusesLegacyLineInRecordText`** — Q4 со стороны `close`: запись со строкой «- **Задач…» не
  переносится; отказ — от разбора списка, а не от самопроверки собранного архива.
- **`checkFindsOpenTaskInLargeLegacySection`** — `check` называет открытую задачу среди прежних записей
  архива, когда их список больше буфера канала (ранний выход поиска).
- **`closeRefusesArchiveHeadingAsLastLine`** — `close` при заголовке раздела последней строкой архива (так
  оставляет пустой архив форматировщик Markdown) отказывает с названием причины до сборки файлов, а не на
  самопроверке; шаблон архива из скилла (второй раздел под пустой строкой) запись принимает.
- **`refsReplacesControlCharacters`** — `refs` не выводит ESC, BEL, CR, DEL и C1 (табуляция остаётся) ни при
  поиске по путям, ни по git; имя нечитаемого файла в сообщении поиска — тоже.

`TodoFormatContractTest` (`check` на настоящих `doc/TODO*.md` проекта) не переносился: это контракт
проекта, а не тест скрипта.
