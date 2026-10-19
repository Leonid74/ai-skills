#!/usr/bin/env bash
#
# Список задач в двух файлах: открытые и архив закрытых. Заведение задачи, закрытие (перенос записи
# в архив: текст не меняется, кроме строки статуса — она становится «закрыта»), проверка формата и
# счётчика номеров, поиск упоминаний номера.
#
# Формат записи — заголовок «### №N. Название», блок обязательных полей, пустая строка, свободный текст.
# Правила формата живут ЗДЕСЬ (режим check): описание в шапке списка — пересказ для человека.
# Скрипт меняет файлы, только если понимает их структуру целиком: непонятая строка — отказ, а не догадка.
#
# Использование:
#   todo.sh [--todo ФАЙЛ] [--done ФАЙЛ] [--counter ФАЙЛ] КОМАНДА …
#
#   next                     напечатать следующий номер (файла счётчика нет — восстановить его)
#   new --title-file Ф --body-file Ф --priority ЗНАЧ --status ЗНАЧ --type ЗНАЧ
#       --created ЗНАЧ --triage ЗНАЧ --review ЗНАЧ [--related ЗНАЧ]
#                            завести задачу: номер из счётчика, запись в конец списка, счётчик переписан
#   close N --closed ТЕКСТ --summary-file Ф
#                            перенести запись №N в начало архива со строками «Закрыто» и «Итог»
#                            и статусом «закрыта»; сводный пункт — только без открытых строк
#   check                    проверить структуру файлов, формат записей, номера и счётчик (код 1 — нарушения)
#   refs N [ПУТЬ…]           показать упоминания №N (без путей — по всем файлам git-репозитория)
#   compat                   проверить, подходит ли список проекта к формату скрипта (только чтение; код 1 —
#                            несовместим, причины и строки другого вида списка названы)
#   version                  напечатать версию скрипта
#
# Название, текст задачи и итог читаются из файлов: так символы «\», «&», «/» доходят без искажений.
# Файлы по умолчанию — doc/TODO.md, doc/TODO-DONE.md, doc/.todo-next от текущего каталога (обычная
# раскладка, не привязка к проекту); их же задают переменные окружения TODO_FILE, TODO_DONE_FILE,
# TODO_COUNTER_FILE. Файлы заменяются переименованием временного файла рядом с целевым: каталог каждого
# файла должен быть доступен на запись. Если файл списка, архива или счётчика сам — символическая ссылка,
# скрипт отказывает (ссылка в каталогах пути не проверяется). Сначала готовятся временные файлы обоих
# заменяемых файлов, затем идут два переименования подряд: сбой до них не меняет ни один файл; сбой второго
# переименования оставляет первый файл уже заменённым (сообщение называет число заменённых) — check покажет
# расхождение.
#
# Архив: записи нового формата — под первым заголовком второго уровня; записи прежнего формата
# («- **Задача №N…») — ниже, под своим (вторым) заголовком второго уровня, и правилам формата не
# подчиняются (учитываются только как занятые номера).
#
# Сводный пункт (поле «Тип: сводный») закрывается целиком и только когда в нём нет ничего открытого. Строка —
# строка текста записи с «- » в нулевой колонке вне блока кода; её продолжения — следующие непустые строки с
# отступом (пустая строка строку заканчивает). Закрыта только строка, начинающаяся с «- [x] **✅ …» или
# «- [x] **❌ …» — отметка основания стоит сразу после флажка. Что считается открытым — в комментарии функции
# open_lines: close отказывает и называет каждое место, check считает нарушением такой пункт в архиве. Обычные
# абзацы и смысл отметки скрипт не судит — их сверяет человек. После переноса сводного пункта скрипт напоминает
# убрать его из перечня сводных пунктов и разобрать упоминания (refs).
#
# Управляющие символы (C0, DEL, C1) проверяются в названии, значениях полей, «Закрыто» и итоге; текст
# задачи (--body-file) на них НЕ проверяется. NUL-байт в файле названия или итога проверка не видит (оболочка
# его отбрасывает). Строка «- **Задач…» с начала строки в тексте задачи считается записью прежнего формата:
# new такую задачу не заведёт, check назовёт строку — её нужно переформулировать.
#
# Зависимости: bash, POSIX awk (проверено с gawk и mawk), cat, cp, mv, rm, mktemp, head, tail, sed, tr,
# wc, cmp, sort, uniq, grep, dirname, basename; для refs без путей — git.

# Функции-проверки (has_ctrl, file_has_ctrl, structure_ok, validate_fields, parse_counter, compute_next,
# check_violations) зовутся в условиях намеренно: их код возврата и есть результат проверки, отказ идёт через die.
# Под set -e сбой утилиты внутри такой функции и в подстановке внутри условия скрипт не останавливает — так устроен
# исходный скрипт; режим compat и check_violations, добавленные в плагине, держатся того же приёма. Директива ниже
# глушит только эти два вида замечаний (SC2310 — функция в условии, SC2312 — подстановка «$(tail -c 1 …)» в
# проверке перевода строки); новый код сверен прогоном shellcheck без директивы — иных замечаний в нём нет.
# Опыт с нечитаемыми файлами: check и close кончаются кодом ≠ 0, compat называет файл; new при нечитаемом архиве
# заводит запись с кодом 0, а номера архива не учитывает — номер берётся из счётчика.
# shellcheck disable=SC2310,SC2312

set -euo pipefail
export LC_ALL=C

# Версия скрипта: по ней сверяется копия скрипта в проекте с копией в плагине dev-toolkit.
TODO_SH_VERSION='1.1.0'

TODO_FILE=${TODO_FILE:-doc/TODO.md}
DONE_FILE=${TODO_DONE_FILE:-doc/TODO-DONE.md}
COUNTER_FILE=${TODO_COUNTER_FILE:-doc/.todo-next}
WORK=''
STAGED=()

die() {
    printf 'todo: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    local f
    for f in "${STAGED[@]:-}"; do
        if [[ -n "${f}" && -e "${f}" ]]; then
            rm -f -- "${f}"
        fi
    done
    if [[ -n "${WORK}" && -d "${WORK}" ]]; then
        rm -rf -- "${WORK}"
    fi
}
trap cleanup EXIT

# Относительный путь приводится к «./…»: иначе awk читает операнд «имя=значение» как присваивание,
# а утилиты — путь с «-» как опцию. Пустое значение не трогается (его отвергнет проверка файла).
norm_path() {
    if [[ -n "$1" && "$1" != /* ]]; then
        printf './%s' "$1"
    else
        printf '%s' "$1"
    fi
}

# Значение из параметра — одна строка без управляющих символов (C0, DEL и C1 в UTF-8): перевод строки
# вписал бы в запись посторонние строки, возврат каретки и ESC подменяют вывод в терминале.
has_ctrl() {
    [[ "$1" == *[[:cntrl:]]* || "$1" == *$'\xc2'[$'\x80'-$'\x9f']* ]]
}

# То же для файла (перевод строки — разделитель строк, не нарушение). NUL-байт диапазон не включает.
file_has_ctrl() {
    awk '/[\001-\037\177]|\302[\200-\237]/ { bad = 1 } END { exit !bad }' "$1"
}

# Общие функции awk: начало строки, номер записи по строке заголовка, наибольший номер в строке и начало
# строки для сообщения.
# shellcheck disable=SC2016
AWK_LIB='
# Начало строки для сообщения: табуляция — словом (отказы называют строки с табуляцией), прочие управляющие
# символы — знаком вопроса (текст задачи на них не проверяется, а печатается в терминал); не длиннее
# 100 байт, без разрыва многобайтового символа.
function head(s) {
    gsub(/\t/, "<TAB>", s)
    gsub(/[\001-\037\177]|\302[\200-\237]/, "?", s)
    if (length(s) <= 100) return s
    s = substr(s, 1, 100)
    sub(/[\300-\367][\200-\277]*$/, "", s)
    return s "…"
}
function starts(s, prefix) { return substr(s, 1, length(prefix)) == prefix }
function recnum(line,   p, rest) {
    p = "### №"
    if (substr(line, 1, length(p)) != p) return 0
    rest = substr(line, length(p) + 1)
    if (match(rest, /^[1-9][0-9]*\. ./)) return substr(rest, 1, RLENGTH - 3) + 0
    return 0
}
function maxref(line,   mark, i, v, best) {
    mark = "№"
    best = 0
    while ((i = index(line, mark)) > 0) {
        line = substr(line, i + length(mark))
        if (match(line, /^[0-9]+/)) {
            v = substr(line, 1, RLENGTH) + 0
            if (v > best) best = v
        }
    }
    return best
}
'

# Структурный разбор файла (режим list — список открытых, archive — архив). Строки вывода:
#   R номер первая_строка строка_после_последней тип   — запись нового формата;
#   L номер   — «№число» в строке прежнего формата («- **…») вне записей: занятый номер;
#   T номер   — запись прежнего формата «- **Задача №N…» вне записей;
#   E строка сообщение — строка, которую разбор не понимает (при любой E файл не меняется).
# Запись кончается перед следующим заголовком записи, перед заголовком первого–второго уровня или в
# конце файла; внутри блока кода (```) заголовки не ищутся.
scan() {
    # shellcheck disable=SC2016
    MODE=$1 awk "${AWK_LIB}"'
    function flush(endline) {
        if (cur) print "R", cur, start, endline, (type == "" ? "?" : type)
        cur = 0
    }
    BEGIN { archive = (ENVIRON["MODE"] == "archive"); typefield = "- **Тип:** "; legacy = "- **Задач" }
    {
        # Первый раздел архива до первой записи: только пустые строки, заголовок записи или следующий заголовок
        # раздела. Проверка стоит ДО разбора блока кода — иначе блок кода обходил бы её, а close вставлял бы
        # запись над ним, приписывая блок закрытой записи. Строку «### …» не-заголовок записи называет своя
        # ветка ниже. Открывающая строка блока кода даёт ошибку и идёт дальше — к разбору блока: его содержимое
        # пропускается, закрывающая строка блок закрывает.
        if (archive && h2 == 1 && !cur && !fence && $0 !~ /^[ \t]*$/ && recnum($0) == 0 && substr($0, 1, 3) != "## " && substr($0, 1, 2) != "# " && substr($0, 1, 4) != "### " && $0 != "###") {
            print "E", NR, "под первым заголовком раздела архива до первой записи — только пустые строки; записям прежнего формата нужен свой заголовок раздела (## …)"
            # Строка, открытая и закрытая на себе же («```x```»), блок не взводит — иначе остаток архива
            # не разбирался бы, а к ошибке добавлялась бы ложная «блок не закрыт».
            if (substr($0, 1, 3) != "```" || index(substr($0, 4), "```") > 0) next
        }
        if (substr($0, 1, 3) == "```") { fence = !fence; fenceline = NR; next }
        if (fence) next
        n = recnum($0)
        if (n > 0) {
            if (archive && h2 != 1) print "E", NR, "запись нового формата ниже раздела прежних записей либо выше первого заголовка раздела — записи нового формата держатся под первым заголовком раздела"
            flush(NR)
            cur = n; start = NR; type = ""; infields = 1; seen = 1
            next
        }
        if (substr($0, 1, 4) == "### " || $0 == "###") {
            print "E", NR, "строка «### …» — не заголовок записи (нужно «### №N. Название», номер без ведущих нулей)"
            next
        }
        if (substr($0, 1, 2) == "# " || substr($0, 1, 3) == "## ") {
            flush(NR)
            if (archive) {
                if (substr($0, 1, 2) == "# ") { if (h2 > 0) print "E", NR, "заголовок первого уровня ниже первого заголовка раздела архива" }
                else if (++h2 > 2) print "E", NR, "в архиве после первого раздела допустим один заголовок раздела (прежние записи)"
            } else if (seen) {
                print "E", NR, "заголовок первого–второго уровня после первой записи списка"
            }
            next
        }
        if (cur) {
            if (infields) {
                if ($0 == "") infields = 0
                else if (substr($0, 1, length(typefield)) == typefield) type = substr($0, length(typefield) + 1)
            }
            if (substr($0, 1, length(legacy)) == legacy) {
                if (archive) print "E", NR, "запись прежнего формата внутри записи нового — перед прежними записями нужен заголовок раздела (## …); если это строка текста задачи — переформулируйте строку"
                else print "E", NR, "строка «- **Задач…» в тексте задачи выглядит как запись прежнего формата архива — переформулируйте строку (иначе запись не закроется)"
            }
            next
        }
        if (archive && substr($0, 1, 4) == "- **") {
            v = maxref($0)
            if (v > 0) print "L", v
            p = "- **Задача №"
            if (substr($0, 1, length(p)) == p) {
                rest = substr($0, length(p) + 1)
                if (match(rest, /^[0-9]+/)) print "T", substr(rest, 1, RLENGTH) + 0
            }
        }
    }
    END {
        flush(NR + 1)
        if (fence) print "E", fenceline, "блок кода (```) не закрыт до конца файла"
    }
    ' "$2"
}

# Печатает ошибки структуры файла в stderr; код 1, если они есть.
structure_ok() {
    local mode=$1 file=$2 label=${3:-$2} errors
    errors=$(scan "${mode}" "${file}" | LABEL=${label} awk '$1 == "E" { line = $2; sub(/^E [0-9]+ /, ""); printf "%s:%d: %s\n", ENVIRON["LABEL"], line, $0 }')
    if [[ -n "${errors}" ]]; then
        printf '%s\n' "${errors}" >&2
        return 1
    fi
}

# Наибольший занятый номер: записи нового формата обоих файлов и номера прежних записей архива.
max_number() {
    {
        scan list "${TODO_FILE}"
        scan archive "${DONE_FILE}"
    } | awk '$1 == "R" || $1 == "L" { if ($2 + 0 > max) max = $2 + 0 } END { print max + 0 }'
}

# Проверка блоков полей во всех записях файла. Режим todo — шесть обязательных полей и необязательное
# «Связано»; режим archive — перед ними ещё «Закрыто» и «Итог». Нарушения — в stderr, код 1.
validate_fields() {
    local mode=$1 file=$2 label=${3:-$2}
    # shellcheck disable=SC2016
    MODE=${mode} FILE_LABEL=${label} awk "${AWK_LIB}"'
    function fail(msg) {
        printf "%s:%d: №%d: %s\n", ENVIRON["FILE_LABEL"], NR, cur, msg > "/dev/stderr"
        bad = 1
    }
    function ctrl(s) { return s ~ /[\001-\037\177]|\302[\200-\237]/ }
    function check_value(name, v,   i, n, parts, tok, ok, src) {
        if (v == "") { fail("поле «" name "» пустое"); return }
        if (name == "Закрыто") {
            ok = 0
            if (match(v, /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9], PR #[1-9][0-9]*/)) ok = 1
            if (starts(v, "без реализации — ") && length(v) > length("без реализации — ")) ok = 1
            if (!ok) fail("«Закрыто»: нужно «ГГГГ-ММ-ДД, PR #N» или «без реализации — …»")
        } else if (name == "Приоритет") {
            ok = 0
            n = split("высокий|средний|низкий", parts, "|")
            for (i = 1; i <= n; i++) {
                tok = parts[i] " ("
                if (starts(v, tok) && substr(v, length(v)) == ")") {
                    src = substr(v, length(tok) + 1, length(v) - length(tok) - 1)
                    gsub(/ /, "", src)
                    if (src != "") ok = 1
                }
            }
            if (!ok) fail("«Приоритет»: нужно «высокий|средний|низкий (источник)»")
        } else if (name == "Статус") {
            if (ENVIRON["MODE"] == "archive") {
                if (v != "закрыта") fail("«Статус»: в архиве нужно «закрыта»")
            } else if (!(v == "открыта" || v == "в работе" || (starts(v, "отложена до ") && length(v) > length("отложена до "))))
                fail("«Статус»: нужно «открыта», «в работе» или «отложена до …»")
        } else if (name == "Тип") {
            if (!(v == "задача" || v == "сводный")) fail("«Тип»: нужно «задача» или «сводный»")
        } else if (name == "Заведено") {
            if (!(match(v, /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) && starts(substr(v, 11), " — ") && length(v) > 10 + length(" — ")))
                fail("«Заведено»: нужно «ГГГГ-ММ-ДД — источник»")
        } else if (name == "Триаж v2") {
            if (!(v == "дефект" || v == "улучшение" || v == "не находка ревью" || v == "не подтверждено" || v == "сводный" || v == "не указан"))
                fail("«Триаж v2»: недопустимое значение")
        } else if (name == "Ревью") {
            n = split("low|medium|high|xhigh|max|прямое чтение|не требуется|по таблице при реализации", parts, "|")
            ok = 0
            for (i = 1; i <= n; i++) {
                tok = parts[i]
                if (v == tok || starts(v, tok " ")) ok = 1
            }
            if (!ok) fail("«Ревью»: значение должно начинаться с уровня, «прямое чтение», «не требуется» или «по таблице при реализации»")
        } else if (name == "Связано") {
            n = split(v, parts, ", ")
            for (i = 1; i <= n; i++) {
                if (maxref(parts[i]) == 0 || parts[i] != "№" maxref(parts[i])) fail("«Связано»: нужно «№A, №B»")
            }
        }
    }
    function finish() {
        if (cur && infields) fail("блок полей не закончен пустой строкой")
    }
    BEGIN {
        first = (ENVIRON["MODE"] == "archive") ? 1 : 3
        names[1] = "Закрыто"; names[2] = "Итог"; names[3] = "Приоритет"; names[4] = "Статус"
        names[5] = "Тип"; names[6] = "Заведено"; names[7] = "Триаж v2"; names[8] = "Ревью"; names[9] = "Связано"
    }
    {
        if (substr($0, 1, 3) == "```") { fence = !fence }
        if (!fence) {
            n = recnum($0)
            if (n > 0) {
                finish(); cur = n; infields = 1; k = first
                if (ctrl($0)) fail("управляющий символ в заголовке записи")
                next
            }
            if (substr($0, 1, 2) == "# " || substr($0, 1, 3) == "## ") { finish(); cur = 0; infields = 0; next }
        }
        if (!infields) next
        if ($0 == "") {
            if (k <= 8) fail("нет поля «" names[k] "»")
            infields = 0
            next
        }
        if (ctrl($0)) fail("управляющий символ в блоке полей")
        if (k > 9) { fail("лишняя строка в блоке полей"); infields = 0; next }
        prefix = "- **" names[k] ":** "
        if (starts($0, prefix)) {
            check_value(names[k], substr($0, length(prefix) + 1))
            k++
        } else if (k == 9) {
            fail("после поля «Ревью» ожидается «Связано» или пустая строка"); infields = 0
        } else {
            fail("ожидается поле «" names[k] "»"); infields = 0
        }
    }
    END { finish(); exit bad }
    ' "${file}"
}

# Открытые места сводных пунктов файла: по строке вывода на каждое — «метка:номер_строки: №N: причина: начало
# строки». Тип записи читается из блока полей; у записей другого типа строки не судятся. Третий параметр —
# сдвиг номеров строк (когда файл — вырезанная запись). Файл читает сам awk — без конвейера.
# Закрыта только строка, начинающаяся с «- [x] **✅» или «- [x] **❌» (отметка основания — сразу после флажка:
# так её не спутать с упоминанием отметки в тексте находки). Открыто: «- [ ]»; строка «- » без флажка; «- [x]»
# без отметки сразу после флажка; вложенный «[ ]» под закрытой строкой; пункт списка с маркером не «- » («* »,
# «+ », «1. », «1) », «-<TAB>») на ЛЮБОЙ строке нулевой колонки, с флажком или без (списки пишут и сразу под
# вводной строкой — признак «начало абзаца» их пропускал; цена — отказ на строке переноса абзаца, начавшейся с
# «1. » или «* »); пункт с отступом вне строки; строка, начинающаяся с «*(», — находка, записанная абзацем. Не
# судится только пометка: за первой «)*» в той же строке идёт пробел или табуляция и обычный текст (не «*»), и
# в остатке строки нет «**» — буквально, в том числе внутри кода («*(Вывод ассистента, не решение:)* текст»).
# Прочие абзацы не судятся.
open_lines() {
    # shellcheck disable=SC2016
    FILE_LABEL=$2 OFFSET=${3:-0} awk "${AWK_LIB}"'
    function report(line, reason, text) {
        printf "%s:%d: №%d: %s: %s\n", ENVIRON["FILE_LABEL"], line + ENVIRON["OFFSET"], cur, reason, head(text)
    }
    function flush() {
        if (kind == "m") report(first, "флажок [x] без отметки «**✅ …**» или «**❌ …**» сразу после флажка", text)
        else if (kind == "o") report(first, "открытая строка", text)
        else if (kind == "n") report(first, "строка без флажка", text)
        kind = ""
    }
    {
        if (substr($0, 1, 3) == "```") { flush(); fence = !fence; next }
        if (fence) next
        n = recnum($0)
        if (n > 0) { flush(); cur = n; infields = 1; composite = 0; next }
        if (substr($0, 1, 2) == "# " || substr($0, 1, 3) == "## ") { flush(); cur = 0; next }
        if (!cur) next
        if (infields) {
            if ($0 == "") infields = 0
            else if ($0 == "- **Тип:** сводный") composite = 1
            next
        }
        if (!composite) next
        if (starts($0, "- ")) {
            flush()
            if (starts($0, "- [x] **✅") || starts($0, "- [x] **❌")) kind = "x"
            else if (starts($0, "- [x] ")) kind = "m"
            else kind = starts($0, "- [ ] ") ? "o" : "n"
            first = NR; text = $0
            next
        }
        if ($0 ~ /^[ \t]+[^ \t]/) {
            item = ($0 ~ /^[ \t]+([-*+]|[0-9]+[.)])[ \t]/)
            if (kind == "") {
                if (item) report(NR, "пункт списка с отступом вне строки сводного пункта", $0)
                next
            }
            if (kind == "x" && item && $0 ~ /^[ \t]+([-*+]|[0-9]+[.)])[ \t]+\[ \]/) report(NR, "вложенный открытый флажок под закрытой строкой", $0)
            next
        }
        flush()
        if ($0 ~ /^([*+]|[0-9]+[.)])[ \t]/ || starts($0, "-\t")) report(NR, "пункт списка с маркером не «- »", $0)
        else if (starts($0, "*(")) {
            # Пометка — только «*(…)* обычный текст» без «**» в остатке строки; всё прочее с «*(» — отказ.
            rest = (index($0, ")*") > 0) ? substr($0, index($0, ")*") + 2) : ""
            if (rest !~ /^[ \t]+[^* \t]/ || index(rest, "**") > 0) report(NR, "строка с «*(» вне строки сводного пункта — находка абзацем либо пометка не в форме «*(…)* обычный текст» без «**» в строке", $0)
        }
    }
    END { flush() }
    ' "$1"
}

# Три файла — не символические ссылки, список и архив на месте.
require_files() {
    local f
    for f in "${TODO_FILE}" "${DONE_FILE}" "${COUNTER_FILE}"; do
        [[ ! -L "${f}" ]] || die "символическая ссылка вместо файла: ${f} — по ссылке скрипт не пишет"
    done
    [[ -f "${TODO_FILE}" ]] || die "нет файла списка: ${TODO_FILE}"
    [[ -f "${DONE_FILE}" ]] || die "нет файла архива: ${DONE_FILE}"
}

# Список и архив разбираются целиком — иначе скрипт ничего не меняет.
require_structure() {
    local bad=0
    structure_ok list "${TODO_FILE}" || bad=1
    structure_ok archive "${DONE_FILE}" || bad=1
    [[ "${bad}" -eq 0 ]] || die 'структура файлов не разобрана (строки выше) — файлы не изменены; исправьте и проверьте: check'
}

# Файл непуст и кончается переводом строки — иначе перенос по номерам строк исказил бы последнюю запись.
require_final_newline() {
    [[ -s "$1" && -z "$(tail -c 1 "$1")" ]] || die "файл пуст или не кончается переводом строки: $1"
}

# Название записи с данным номером в файле (пусто, если записи нет).
record_title() {
    local n=$1 mode=$2 file=$3 start
    start=$(scan "${mode}" "${file}" | awk -v n="${n}" '$1 == "R" && $2 == n { print $3; exit }')
    [[ -n "${start}" ]] || return 0
    sed -n "${start}p" "${file}" | sed "s/^### №${n}\\. //"
}

# Номер строки первого заголовка второго уровня архива вне блоков кода (пусто, если его нет) — место вставки close.
archive_heading() {
    awk '
        { if (substr($0, 1, 3) == "```") fence = !fence; else if (!fence && substr($0, 1, 3) == "## ") { print NR; exit } }
    ' "${DONE_FILE}"
}

# Разбор строки счётчика: печатает «следующий выданный». Формат — «N # выдан №M — название», N = M + 1.
parse_counter() {
    local line next issued
    [[ "$(wc -l < "${COUNTER_FILE}")" -eq 1 ]] || die "счётчик ${COUNTER_FILE} — не одна строка"
    line=$(cat -- "${COUNTER_FILE}")
    if has_ctrl "${line}" || [[ ! "${line}" =~ ^([1-9][0-9]*)\ \#\ выдан\ №(0|[1-9][0-9]*)\ —\ .+$ ]]; then
        die "счётчик ${COUNTER_FILE} не в формате «N # выдан №M — название»"
    fi
    next=${BASH_REMATCH[1]}
    issued=${BASH_REMATCH[2]}
    [[ "${next}" -eq $((issued + 1)) ]] || die "счётчик ${COUNTER_FILE}: следующий номер ${next} не равен выданному ${issued} плюс один"
    printf '%s %s\n' "${next}" "${issued}"
}

# Следующий номер без записи в файлы. Файла счётчика нет — наибольший номер в обоих файлах плюс один.
compute_next() {
    local max next
    max=$(max_number)
    if [[ ! -e "${COUNTER_FILE}" ]]; then
        printf '%s\n' "$((max + 1))"
        return 0
    fi
    next=$(parse_counter) || exit 1
    next=${next%% *}
    [[ "${next}" -gt "${max}" ]] || die "счётчик ${COUNTER_FILE} (${next}) не больше наибольшего занятого номера (${max})"
    printf '%s\n' "${next}"
}

# Готовит замену файла: временный файл рядом с целевым — имя выдаёт mktemp (по предсказуемому имени можно
# подложить ссылку), права — с целевого, а если его нет — со списка; содержимое — из источника. Сама замена
# — commit_staged, когда готовы все файлы.
stage() {
    local target=$1 source=$2 tmp like
    tmp=$(mktemp "$(dirname -- "${target}")/.$(basename -- "${target}").tmp.XXXXXX" 2> /dev/null) \
        || die "не удалось подготовить замену ${target} (каталог недоступен на запись?) — файлы не изменены"
    STAGED+=("${tmp}")
    like=${target}
    [[ -e "${target}" ]] || like=${TODO_FILE}
    cp -p -- "${like}" "${tmp}" 2> /dev/null || die "не удалось подготовить замену ${target} (каталог недоступен на запись?) — файлы не изменены"
    cat -- "${source}" > "${tmp}" || die "не удалось записать замену ${target} — файлы не изменены"
}

# Переименовывает подготовленные файлы на место: цели — в порядке вызовов stage.
commit_staged() {
    local i=0 tmp
    for tmp in "${STAGED[@]}"; do
        mv -f -- "${tmp}" "$1" || die "не удалось заменить $1 (заменено файлов до сбоя: ${i})"
        i=$((i + 1))
        shift
    done
    STAGED=()
}

cmd_next() {
    local max n title
    require_files
    require_structure
    if [[ ! -e "${COUNTER_FILE}" ]]; then
        max=$(max_number)
        title=$(record_title "${max}" list "${TODO_FILE}")
        [[ -n "${title}" ]] || title=$(record_title "${max}" archive "${DONE_FILE}")
        if [[ -z "${title}" ]] || has_ctrl "${title}"; then
            title='восстановлено по наибольшему номеру'
        fi
        WORK=$(mktemp -d)
        printf '%s # выдан №%s — %s\n' "$((max + 1))" "${max}" "${title}" > "${WORK}/counter"
        stage "${COUNTER_FILE}" "${WORK}/counter"
        commit_staged "${COUNTER_FILE}"
        printf 'todo: счётчик %s восстановлен: следующий номер %s\n' "${COUNTER_FILE}" "$((max + 1))" >&2
    fi
    n=$(compute_next) || exit 1
    printf '%s\n' "${n}"
}

cmd_new() {
    local title_file='' body_file='' priority='' status='' type='' created='' triage='' review='' related=''
    while [[ $# -gt 0 ]]; do
        [[ $# -ge 2 ]] || die "у параметра $1 нет значения"
        case "$1" in
            --title-file) title_file=$(norm_path "$2") ;;
            --body-file) body_file=$(norm_path "$2") ;;
            --priority) priority=$2 ;;
            --status) status=$2 ;;
            --type) type=$2 ;;
            --created) created=$2 ;;
            --triage) triage=$2 ;;
            --review) review=$2 ;;
            --related) related=$2 ;;
            *) die "неизвестный параметр new: $1" ;;
        esac
        shift 2
    done
    require_files
    require_final_newline "${TODO_FILE}"
    require_structure
    [[ -f "${title_file}" ]] || die 'нужен --title-file с названием задачи'
    [[ -f "${body_file}" && -s "${body_file}" ]] || die 'нужен непустой --body-file с текстом задачи'

    local value
    for value in "${priority}" "${status}" "${type}" "${created}" "${triage}" "${review}" "${related}"; do
        ! has_ctrl "${value}" || die 'значение поля — одна строка без управляющих символов'
    done
    [[ "${triage}" != 'не указан' ]] || die '«Триаж v2»: «не указан» — только у записей, заведённых до формата; у новой задачи не ставится'

    local title
    [[ "$(wc -l < "${title_file}")" -le 1 ]] || die 'название — одна строка'
    ! file_has_ctrl "${title_file}" || die 'в названии управляющий символ (в том числе возврат каретки из файла с CRLF)'
    title=$(cat -- "${title_file}")
    [[ -n "${title}" && "${title}" == "${title# }" && "${title}" == "${title% }" ]] || die 'название пусто либо начинается или кончается пробелом'

    # В тексте задачи заголовки первого–третьего уровня запрещены: заголовок «### №N.» — граница записи.
    if ! awk '
        { if (substr($0, 1, 3) == "```") fence = !fence; else if (!fence && $0 ~ /^(#|##|###)( |$)/) bad = 1 }
        END { exit bad }
    ' "${body_file}"; then
        die 'в тексте задачи есть заголовок первого–третьего уровня'
    fi

    local n restored=0
    [[ -e "${COUNTER_FILE}" ]] || restored=1
    n=$(compute_next) || exit 1
    WORK=$(mktemp -d)
    {
        printf '### №%s. %s\n' "${n}" "${title}"
        printf -- '- **Приоритет:** %s\n' "${priority}"
        printf -- '- **Статус:** %s\n' "${status}"
        printf -- '- **Тип:** %s\n' "${type}"
        printf -- '- **Заведено:** %s\n' "${created}"
        printf -- '- **Триаж v2:** %s\n' "${triage}"
        printf -- '- **Ревью:** %s\n' "${review}"
        if [[ -n "${related}" ]]; then
            printf -- '- **Связано:** %s\n' "${related}"
        fi
        printf '\n'
        cat -- "${body_file}"
        if [[ -n "$(tail -c 1 "${body_file}")" ]]; then
            printf '\n'
        fi
    } > "${WORK}/record"
    validate_fields todo "${WORK}/record" 'новая запись' || die 'запись не заведена: поля не прошли проверку'

    {
        cat -- "${TODO_FILE}"
        if [[ -n "$(tail -n 1 "${TODO_FILE}")" ]]; then
            printf '\n'
        fi
        cat "${WORK}/record"
    } > "${WORK}/todo"
    printf '%s # выдан №%s — %s\n' "$((n + 1))" "${n}" "${title}" > "${WORK}/counter"

    # Собранный список проверяется до записи: новая запись не должна сломать разбор (незакрытый блок кода).
    structure_ok list "${WORK}/todo" 'список с новой записью' \
        || die 'запись не заведена: с ней список не разбирается — файлы не изменены'

    stage "${TODO_FILE}" "${WORK}/todo"
    stage "${COUNTER_FILE}" "${WORK}/counter"
    commit_staged "${TODO_FILE}" "${COUNTER_FILE}"
    if [[ "${restored}" -eq 1 ]]; then
        printf 'todo: файла счётчика не было — создан %s по наибольшему номеру в обоих файлах\n' "${COUNTER_FILE}" >&2
    fi
    printf '№%s\n' "${n}"
}

cmd_close() {
    local n=${1:-} closed='' summary_file=''
    [[ "${n}" =~ ^[1-9][0-9]*$ ]] || die 'close: первым аргументом нужен номер задачи'
    shift
    while [[ $# -gt 0 ]]; do
        [[ $# -ge 2 ]] || die "у параметра $1 нет значения"
        case "$1" in
            --closed) closed=$2 ;;
            --summary-file) summary_file=$(norm_path "$2") ;;
            *) die "неизвестный параметр close: $1" ;;
        esac
        shift 2
    done
    require_files
    require_final_newline "${TODO_FILE}"
    require_final_newline "${DONE_FILE}"
    require_structure
    [[ -n "${closed}" ]] || die 'нужен --closed: «ГГГГ-ММ-ДД, PR #N» либо «без реализации — …»'
    ! has_ctrl "${closed}" || die '--closed — одна строка без управляющих символов'
    [[ -f "${summary_file}" && -s "${summary_file}" ]] || die 'нужен непустой --summary-file с итогом'
    ! file_has_ctrl "${summary_file}" || die 'в итоге управляющий символ (в том числе возврат каретки из файла с CRLF)'

    local summary
    summary=$(tr '\n' ' ' < "${summary_file}" | sed 's/^ *//; s/ *$//')
    [[ -n "${summary}" ]] || die 'итог пуст'

    local range start end type
    range=$(scan list "${TODO_FILE}" | awk -v n="${n}" '$1 == "R" && $2 == n { print $3, $4, $5 }')
    [[ -n "${range}" ]] || die "записи №${n} нет в ${TODO_FILE}"
    [[ "$(printf '%s\n' "${range}" | wc -l)" -eq 1 ]] || die "запись №${n} встречается в ${TODO_FILE} больше одного раза"
    read -r start end type <<< "${range}"
    if scan archive "${DONE_FILE}" | awk -v n="${n}" '$1 == "R" && $2 == n { found = 1 } END { exit !found }'; then
        die "запись №${n} уже есть в ${DONE_FILE}"
    fi

    WORK=$(mktemp -d)
    sed -n "${start},$((end - 1))p" "${TODO_FILE}" > "${WORK}/record"
    validate_fields todo "${WORK}/record" "запись №${n}" || die "запись №${n} не в формате — закрытие отменено"
    # Сводный пункт уходит в архив только целиком закрытым: открытые строки называются все.
    local open
    open=$(open_lines "${WORK}/record" "${TODO_FILE}" "$((start - 1))")
    if [[ -n "${open}" ]]; then
        printf '%s\n' "${open}" >&2
        die "№${n} — сводный пункт, незакрытых строк: $(printf '%s\n' "${open}" | wc -l | tr -d ' ') — файлы не изменены. Сводный пункт закрывается только по решению владельца после сверки с ним всего текста пункта. Открытую находку записывают строкой «- [ ] …»; закрытую строку — «- [x] **✅ Сделано …**» (или «**❌ Снято …**») сразу после флажка. Находка это, пометка или перенос абзаца — решается в сверке с владельцем, до правки текста"
    fi

    # Место вставки — после первого заголовка второго уровня архива и пустой строки за ним.
    local heading ins
    heading=$(archive_heading)
    [[ -n "${heading}" ]] || die "в ${DONE_FILE} нет заголовка раздела (## …) — некуда вставлять запись"
    # Пустая — в том же смысле, что в scan: без символов либо из пробелов и табуляции.
    local after_heading
    after_heading=$(sed -n "$((heading + 1))p" "${DONE_FILE}")
    [[ -z "${after_heading//[ $'\t']/}" ]] || die "в ${DONE_FILE} после заголовка раздела нет пустой строки"
    ins=$((heading + 2))

    # Запись ложится в архив как есть, кроме одной строки: статус (третья строка записи — её место
    # закреплено проверкой полей выше) заменяется на «закрыта».
    [[ "$(sed -n '3p' "${WORK}/record")" == '- **Статус:** '* ]] || die "запись №${n}: третьей строкой ожидается поле «Статус» — закрытие отменено"
    local sep=0
    {
        head -n 1 "${WORK}/record"
        printf -- '- **Закрыто:** %s\n' "${closed}"
        printf -- '- **Итог:** %s\n' "${summary}"
        sed -n '2p' "${WORK}/record"
        printf -- '- **Статус:** закрыта\n'
        tail -n +4 "${WORK}/record"
        if [[ -n "$(tail -n 1 "${WORK}/record")" ]]; then
            printf '\n'
        fi
    } > "${WORK}/block"
    if [[ -n "$(tail -n 1 "${WORK}/record")" ]]; then
        sep=1
    fi
    local block_len
    block_len=$(wc -l < "${WORK}/block")

    {
        head -n "$((ins - 1))" "${DONE_FILE}"
        cat "${WORK}/block"
        tail -n "+${ins}" "${DONE_FILE}"
    } > "${WORK}/done"
    {
        head -n "$((start - 1))" "${TODO_FILE}"
        tail -n "+${end}" "${TODO_FILE}"
    } > "${WORK}/todo"

    # Самопроверка до записи: текст не потерян и не изменён, оба собранных файла разбираются.
    {
        head -n "$((start - 1))" "${WORK}/todo"
        cat "${WORK}/record"
        tail -n "+${start}" "${WORK}/todo"
    } | cmp -s - "${TODO_FILE}" || die 'самопроверка: список без записи плюс запись не равен прежнему списку — файлы не изменены'
    {
        head -n "$((ins - 1))" "${WORK}/done"
        tail -n "+$((ins + block_len))" "${WORK}/done"
    } | cmp -s - "${DONE_FILE}" || die 'самопроверка: архив без вставки не равен прежнему архиву — файлы не изменены'
    sed -n "${ins},$((ins + block_len - 1 - sep))p" "${WORK}/done" | sed '2,3d' > "${WORK}/back"
    sed '3d' "${WORK}/record" > "${WORK}/record.rest"
    [[ "$(sed -n '3p' "${WORK}/back")" == '- **Статус:** закрыта' ]] \
        || die 'самопроверка: в записи архива нет строки статуса «закрыта» — файлы не изменены'
    sed '3d' "${WORK}/back" | cmp -s - "${WORK}/record.rest" \
        || die 'самопроверка: запись в архиве отличается от записи списка не только строкой статуса — файлы не изменены'
    validate_fields archive "${WORK}/block" "запись №${n} для архива" || die 'запись архива не прошла проверку формата — файлы не изменены'
    structure_ok archive "${WORK}/done" 'архив с записью' || die 'самопроверка: архив с записью не разбирается — файлы не изменены'
    structure_ok list "${WORK}/todo" 'список без записи' || die 'самопроверка: список без записи не разбирается — файлы не изменены'

    stage "${DONE_FILE}" "${WORK}/done"
    stage "${TODO_FILE}" "${WORK}/todo"
    commit_staged "${DONE_FILE}" "${TODO_FILE}"
    printf '№%s перенесена в %s\n' "${n}" "${DONE_FILE}"
    if [[ "${type}" == 'сводный' ]]; then
        printf 'todo: №%s был сводным пунктом — уберите его из перечня сводных пунктов в шапке списка и разберите упоминания: refs %s по репозиторию и refs %s <каталог> по заметкам вне репозитория (новые находки подсистемы — новым сводным пунктом)\n' "${n}" "${n}" "${n}" >&2
    fi
}

# Нарушения, которые судит check: структура и поля обоих файлов, открытые строки сводных пунктов архива, повторы
# номеров, открытая задача среди прежних записей архива, счётчик (аргумент «без-счётчика» — счётчик не
# проверяется). Сообщения — в stderr, код 1, если нарушения есть. Список и архив — на месте (require_files).
check_violations() {
    local counter_mode=${1:-} bad=0 dup opened legacy n max counter next
    structure_ok list "${TODO_FILE}" || bad=1
    structure_ok archive "${DONE_FILE}" || bad=1
    validate_fields todo "${TODO_FILE}" || bad=1
    validate_fields archive "${DONE_FILE}" || bad=1

    # Сводный пункт в архиве — только без открытых строк (то же правило, что у close).
    local open
    open=$(open_lines "${DONE_FILE}" "${DONE_FILE}")
    if [[ -n "${open}" ]]; then
        printf '%s\n' "${open}" >&2
        bad=1
    fi

    dup=$({ scan list "${TODO_FILE}"; scan archive "${DONE_FILE}"; } | awk '$1 == "R" { print $2 }' | sort -n | uniq -d)
    for n in ${dup}; do
        printf '%s: №%s: номер встречается больше одного раза в заголовках записей\n' "${TODO_FILE}" "${n}" >&2
        bad=1
    done

    # Номер открытой задачи не должен стоять в записи архива прежнего формата «- **Задача №N…».
    opened=$(scan list "${TODO_FILE}" | awk '$1 == "R" { print $2 }')
    legacy=$(scan archive "${DONE_FILE}" | awk '$1 == "T" { print $2 }')
    for n in ${opened}; do
        # Here-string, не конвейер: ранний выход grep -q оборвал бы printf (SIGPIPE), и под pipefail условие
        # стало бы ложным на большом разделе прежних записей.
        if grep -q -x -e "${n}" <<< "${legacy}"; then
            printf '%s: №%s: открытая задача числится закрытой в %s\n' "${TODO_FILE}" "${n}" "${DONE_FILE}" >&2
            bad=1
        fi
    done

    max=$(max_number)
    if [[ "${counter_mode}" == 'без-счётчика' ]]; then
        :
    elif [[ ! -e "${COUNTER_FILE}" ]]; then
        printf '%s: файла счётчика нет\n' "${COUNTER_FILE}" >&2
        bad=1
    elif counter=$(parse_counter); then
        next=${counter%% *}
        if [[ "${next}" -le "${max}" ]]; then
            printf '%s: следующий номер %s не больше наибольшего занятого (%s)\n' "${COUNTER_FILE}" "${next}" "${max}" >&2
            bad=1
        fi
    else
        bad=1
    fi
    [[ "${bad}" -eq 0 ]]
}

cmd_check() {
    local max
    require_files
    check_violations || exit 1
    max=$(max_number)
    printf 'todo: структура, формат, номера и счётчик в порядке (наибольший номер — %s)\n' "${max}"
}

cmd_refs() {
    local n=${1:-}
    [[ "${n}" =~ ^[1-9][0-9]*$ ]] || die 'refs: нужен номер задачи'
    shift
    local pattern="№${n}([^0-9]|\$)"
    # Управляющие символы найденных строк (кроме табуляции) — знаком вопроса: ESC и BEL меняли бы вывод терминала.
    if [[ $# -eq 0 ]] && git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        # «:/» — от корня репозитория: из подкаталога поиск иначе молча сузился бы до него.
        { git grep -n -I -E -e "${pattern}" -- ':/' || true; } | sanitize_lines
    else
        if [[ $# -eq 0 ]]; then
            set -- .
        fi
        { grep -r -n -I -E -e "${pattern}" -- "$@" || true; } | sanitize_lines
    fi
}

sanitize_lines() {
    awk '{ gsub(/[\001-\010\013-\037\177]|\302[\200-\237]/, "?"); print }'
}

# Строки вне записей, похожие на пункты другого вида списка задач: чекбоксы («- [ ] …», «* [ ] …», «+ [ ] …»),
# нумерованные пункты («12. …», «12) …», «- **12.** …», «**12.** …»), строки таблиц — вне блоков кода. Печатает
# «вид номер_строки начало_строки» на каждую такую строку (начало — как в отказах close: управляющие символы
# заменены, не длиннее 100 байт) и в конце «N наибольший_номер» — наибольший номер прежнего пункта во всех строках
# вне записей: номер в начале пункта («12. …», «- [ ] 12. …», «- **12.** …», «| 12 | …», «### 12. …», в том числе
# под «**» и «~~») и «№N» в любом месте строки. Числа дальше в тексте (дата, количество) номером не считаются.
foreign_lines() {
    # shellcheck disable=SC2016
    awk "${AWK_LIB}"'
    function lead(s,   v) {
        sub(/^([-*+] (\[[ xX]\] )?|### |\| *)/, "", s)
        sub(/^[*~_ ]+/, "", s)
        if (!match(s, /^[0-9]+/)) return 0
        v = substr(s, 1, RLENGTH) + 0
        s = substr(s, RLENGTH + 1)
        return (s == "" || s ~ /^([.)*~]| *\|)/) ? v : 0
    }
    {
        if (substr($0, 1, 3) == "```") { fence = !fence; next }
        if (fence) next
        if (recnum($0) > 0) { inrec = 1; next }
        if (substr($0, 1, 2) == "# " || substr($0, 1, 3) == "## ") { inrec = 0; next }
        if (inrec) next
        v = lead($0); if (v > max) max = v
        v = maxref($0); if (v > max) max = v
        kind = ""
        if ($0 ~ /^[-*+] \[[ xX]\] /) kind = "чекбоксы"
        else if ($0 ~ /^([0-9]+[.)] |([-*+] )?\*\*[0-9]+[.)]?\*\*)/) kind = "нумерованные"
        else if (substr($0, 1, 1) == "|") kind = "таблицы"
        if (kind != "") print kind, NR, head($0)
    }
    END { print "N", max + 0 }
    ' "$1"
}

# Совместимость списка с форматом скрипта — только чтение, файлы не меняются ни при каком исходе. Судит то же, что
# check (файла счётчика нет — предупреждение: next создаст его), и то, на чём откажут new и close: файл пуст или не
# кончается переводом строки, в архиве некуда вставить запись. Отчёт — в stdout; код 0 — совместим (предупреждения
# возможны), 1 — несовместим (причины названы).
cmd_compat() {
    local bad=0 i f label records out errors lines kinds total heading max=0 amax next='' mode=''
    local -a files=("${TODO_FILE}" "${DONE_FILE}" "${COUNTER_FILE}") labels=('список' 'архив' 'счётчик')
    local -a usable=(0 0 0)
    printf 'todo compat: проверка списка задач на формат скрипта (файлы не меняются)\n'
    # Метка — по месту в перечне, а не по сравнению путей: пути разных ролей могут совпасть.
    for i in 0 1 2; do
        f=${files[i]}
        label=${labels[i]}
        if [[ -L "${f}" ]]; then
            printf 'todo compat: %s %s: символическая ссылка — по ссылке скрипт не пишет\n' "${label}" "${f}"
            bad=1
        elif [[ ! -e "${f}" && "${i}" -eq 2 ]]; then
            printf 'todo compat: предупреждение: %s %s: нет файла — next создаст его по наибольшему номеру записей формата и строк «- **…№N…» архива; номера пунктов другого вида он не учитывает — сверьте с наибольшим номером вне записей\n' "${label}" "${f}"
        elif [[ ! -e "${f}" ]]; then
            printf 'todo compat: %s %s: нет файла\n' "${label}" "${f}"
            bad=1
        elif [[ ! -f "${f}" ]]; then
            printf 'todo compat: %s %s: не обычный файл (каталог?)\n' "${label}" "${f}"
            bad=1
        elif [[ ! -r "${f}" ]]; then
            printf 'todo compat: %s %s: не читается — нет прав на чтение\n' "${label}" "${f}"
            bad=1
        else
            usable[i]=1
        fi
    done

    if [[ "${usable[0]}" -eq 1 ]]; then
        records=$(scan list "${TODO_FILE}" | awk '$1 == "R"' | wc -l | tr -d ' ')
        printf 'todo compat: список %s: есть, записей формата: %s\n' "${TODO_FILE}" "${records}"
        if [[ ! -s "${TODO_FILE}" || -n "$(tail -c 1 "${TODO_FILE}")" ]]; then
            printf 'todo compat: список %s: файл пуст или не кончается переводом строки — new и close откажут\n' "${TODO_FILE}"
            bad=1
        fi
    fi
    if [[ "${usable[1]}" -eq 1 ]]; then
        records=$(scan archive "${DONE_FILE}" | awk '$1 == "R"' | wc -l | tr -d ' ')
        printf 'todo compat: архив %s: есть, записей формата: %s\n' "${DONE_FILE}" "${records}"
        if [[ ! -s "${DONE_FILE}" || -n "$(tail -c 1 "${DONE_FILE}")" ]]; then
            printf 'todo compat: архив %s: файл пуст или не кончается переводом строки — close откажет\n' "${DONE_FILE}"
            bad=1
        fi
        # Место вставки — как у close: первый заголовок второго уровня и пустая строка за ним.
        heading=$(archive_heading)
        if [[ -z "${heading}" ]]; then
            printf 'todo compat: архив %s: нет заголовка раздела (## …) — close некуда вставить запись\n' "${DONE_FILE}"
            bad=1
        else
            errors=$(sed -n "$((heading + 1))p" "${DONE_FILE}")
            if [[ -n "${errors//[ $'\t']/}" ]]; then
                printf 'todo compat: архив %s: после первого заголовка раздела нет пустой строки — close откажет\n' "${DONE_FILE}"
                bad=1
            fi
        fi
    fi
    if [[ "${usable[2]}" -eq 1 ]]; then
        if errors=$( (parse_counter) 2>&1); then
            next=${errors%% *}
            printf 'todo compat: счётчик %s: есть, следующий номер %s\n' "${COUNTER_FILE}" "${next}"
        else
            printf 'todo compat: счётчик %s: не разобран — %s\n' "${COUNTER_FILE}" "${errors#todo: }"
            bad=1
        fi
    fi

    # Нарушения check. Счётчик сверяется только разобранный; без него — проверки файлов по отдельности.
    [[ -n "${next}" ]] || mode='без-счётчика'
    if [[ "${usable[0]}" -eq 1 && "${usable[1]}" -eq 1 ]]; then
        errors=$(check_violations "${mode}" 2>&1) || { printf '%s\n' "${errors}"; bad=1; }
    elif [[ "${usable[0]}" -eq 1 ]]; then
        errors=$(structure_ok list "${TODO_FILE}" 2>&1 && validate_fields todo "${TODO_FILE}" 2>&1) || { printf '%s\n' "${errors}"; bad=1; }
    elif [[ "${usable[1]}" -eq 1 ]]; then
        errors=$(structure_ok archive "${DONE_FILE}" 2>&1 && validate_fields archive "${DONE_FILE}" 2>&1) || { printf '%s\n' "${errors}"; bad=1; }
    fi

    # Строки другого вида вне записей. Вывод — here-string, не конвейер: head с ранним выходом под pipefail
    # оборвал бы compat (SIGPIPE) на большом прежнем списке.
    lines=''
    if [[ "${usable[0]}" -eq 1 ]]; then
        out=$(foreign_lines "${TODO_FILE}")
        max=$(awk '$1 == "N" { print $2 }' <<< "${out}")
        lines=$(F=${TODO_FILE} awk '$1 != "N" { k = $1; n = $2; sub(/^[^ ]+ [0-9]+ /, ""); printf "%s:%d: %s: %s\n", ENVIRON["F"], n, k, $0 }' <<< "${out}")
        if [[ -n "${lines}" ]]; then
            kinds=$(awk '$1 != "N" { c[$1]++ } END { s = ""; for (k in c) { if (s != "") s = s ", "; s = s (k == "нумерованные" ? "нумерованные пункты" : (k == "таблицы" ? "строки таблиц" : k)) " — " c[k] } print s }' <<< "${out}")
            if [[ "${bad}" -eq 0 ]]; then
                printf 'todo compat: предупреждение: вне записей есть строки другого вида списка задач (%s) — если это задачи, а не текст шапки, переведите их в записи до new/close:\n' "${kinds}"
            else
                printf 'todo compat: вне записей — строки другого вида списка задач (%s):\n' "${kinds}"
            fi
            head -n 5 <<< "${lines}"
            total=$(wc -l <<< "${lines}")
            total=${total//[^0-9]/}
            [[ "${total}" -le 5 ]] || printf 'todo compat: … всего таких строк: %s\n' "${total}"
        fi
    fi
    # Номера прежних пунктов архива (его второй раздел) тоже заняты.
    if [[ "${usable[1]}" -eq 1 ]]; then
        amax=$(foreign_lines "${DONE_FILE}" | awk '$1 == "N" { print $2 }')
        [[ "${amax}" -le "${max:-0}" ]] || max=${amax}
    fi
    max=${max:-0}
    if [[ "${max}" -gt 0 ]] && [[ -n "${lines}" || ! -e "${COUNTER_FILE}" || (-n "${next}" && "${next}" -le "${max}") ]]; then
        printf 'todo compat: наибольший номер в строках вне записей: %s (список и прежний раздел архива: номер в начале пункта и «№N»; проверьте по спискам) — счётчик ставить не меньше %s\n' "${max}" "$((max + 1))"
    fi
    if [[ -n "${next}" && "${next}" -le "${max}" ]]; then
        printf 'todo compat: предупреждение: следующий номер счётчика %s не больше наибольшего номера вне записей (%s) — новые записи получат номера прежних пунктов; поднимите счётчик руками: «%s # выдан №%s — перевод списка»\n' "${next}" "${max}" "$((max + 1))" "${max}"
    fi

    if [[ "${bad}" -ne 0 ]]; then
        printf 'todo compat: несовместим — new и close на этих файлах не запускать; варианты: перевести список в формат (записи «### №N.», архив, счётчик) либо не применять скрипт в этом проекте\n'
        exit 1
    fi
    printf 'todo compat: совместим\n'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --todo) [[ $# -ge 2 ]] || die 'у --todo нет значения'; TODO_FILE=$2; shift 2 ;;
        --done) [[ $# -ge 2 ]] || die 'у --done нет значения'; DONE_FILE=$2; shift 2 ;;
        --counter) [[ $# -ge 2 ]] || die 'у --counter нет значения'; COUNTER_FILE=$2; shift 2 ;;
        *) break ;;
    esac
done
[[ -n "${TODO_FILE}" && -n "${DONE_FILE}" && -n "${COUNTER_FILE}" ]] || die 'путь списка, архива или счётчика пуст'
TODO_FILE=$(norm_path "${TODO_FILE}")
DONE_FILE=$(norm_path "${DONE_FILE}")
COUNTER_FILE=$(norm_path "${COUNTER_FILE}")

command=${1:-}
if [[ $# -gt 0 ]]; then
    shift
fi
case "${command}" in
    next) cmd_next "$@" ;;
    new) cmd_new "$@" ;;
    close) cmd_close "$@" ;;
    check) cmd_check "$@" ;;
    refs) cmd_refs "$@" ;;
    compat) cmd_compat "$@" ;;
    version) printf 'todo.sh %s\n' "${TODO_SH_VERSION}" ;;
    *) die 'команды: next | new | close N | check | refs N | compat | version (описание — в начале файла скрипта)' ;;
esac
