#!/usr/bin/env bash
# PreToolUse-хук для Bash: блокирует опасные команды и предотвращает утечку
# секретов. Получает JSON на stdin (.tool_input.command). Выход 2 = блокировка
# (текст из stderr возвращается модели).

set -euo pipefail

# Страховка fail-closed: любой выход, кроме 0 и 2 (падение под set -e/-u,
# ошибка подстановки, сбой внешней утилиты), превращается в блокировку.
# Код 1 Claude Code считает неблокирующей ошибкой хука и выполнил бы команду.
# shellcheck disable=SC2317 # вызывается через trap
_guard_exit() {
  local rc=$?
  if ((rc != 0 && rc != 2)); then
    printf 'ЗАБЛОКИРОВАНО хуком guard-bash: внутренняя ошибка проверки (код %s)\n' "${rc}" >&2
    exit 2
  fi
}
trap _guard_exit EXIT

input="$(cat)"
# command — только строка: массив/объект jq напечатал бы JSON-ом, и текст обходил
# правила; иначе ошибка jq → trap ниже → блокировка.
cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // "" | if type == "string" then . else error("command не строка") end')"

# Блокировка с эхо команды — для деструктивных правил: текст полезен
# для диагностики и не содержит секретов.
block() {
  printf 'ЗАБЛОКИРОВАНО хуком guard-bash: %s\n' "$1" >&2
  printf 'Команда: %s\n' "${cmd}" >&2
  exit 2
}

# Secret-aware блокировка — БЕЗ эхо команды, чтобы не вернуть модели
# и не записать в логи сам секрет/токен/пароль из текста команды.
block_secret() {
  printf 'ЗАБЛОКИРОВАНО хуком guard-bash: %s\n' "$1" >&2
  printf '(команда скрыта, чтобы не раскрыть секрет)\n' >&2
  exit 2
}

# Секреты — проверяем ПЕРВЫМИ, чтобы команда с секретом не попала под
# эхо-правила ниже. Ловим ЗНАЧЕНИЯ секретов, а не слова: прежнее правило
# «слово secret/password/token в любом месте команды» блокировало имена
# классов, путей и тестов (--filter=…TokenTest) и не ловило ни одного
# реального ключа. Защита — от СЛУЧАЙНОЙ утечки значения в текст команды
# (транскрипт, логи), не от целенаправленного обхода: разбор кавычек и
# экранирования здесь осознанно не делается.
_secret_hint="секрет — через переменную окружения или файл, не литералом в команде"

# Значения известных форматов. Регистрозависимо (префиксы у провайдеров
# фиксированы) и под LC_ALL=C (диапазоны [A-Z] — строго ASCII). Граница
# слева не даёт хвосту слова совпасть с префиксом: "task-…"/"disk-…" не "sk-…".
# Для generic "sk-" требуется сплошной буквенно-цифровой прогон ≥ 20 —
# kebab-case имена ("sk-learn-…") такого прогона не содержат.
_secret_value_re='(^|[^A-Za-z0-9_])gh[pousr]_[A-Za-z0-9]{36}'
_secret_value_re+='|(^|[^A-Za-z0-9_])github_pat_[A-Za-z0-9_]{22,}'
_secret_value_re+='|(^|[^A-Za-z0-9_-])sk-ant-[A-Za-z0-9_-]{20,}'
_secret_value_re+='|(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]*[A-Za-z0-9]{20}'
_secret_value_re+='|(^|[^A-Za-z0-9_])xox[abprs]-[A-Za-z0-9-]{10,}'
_secret_value_re+='|(^|[^A-Za-z0-9])(AKIA|ASIA)[0-9A-Z]{16}([^0-9A-Za-z]|$)'
_secret_value_re+='|(^|[^0-9])[0-9]{8,10}:[A-Za-z0-9_-]{35}'
_secret_value_re+='|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.'
_secret_value_re+='|-----BEGIN ([A-Z]+ )*PRIVATE KEY-----'
if LC_ALL=C grep -qE -e "${_secret_value_re}" <<< "${cmd}"; then
  block_secret "в команде значение секрета известного формата (токен/ключ/JWT/приватный ключ); ${_secret_hint}"
fi

# Присваивание литерала чувствительному имени: password=…, API_KEY: …,
# --token=… Литерал — ≥ 8 ASCII-символов подряд и не начинается с "$"
# (ссылка на переменную — норма) и с "/", "~", "." (путь к файлу с
# секретом — тоже норма: TOKEN_FILE=/run/…). ASCII-класс, а не "не пробел",
# чтобы русский текст после "token:" в сообщении коммита не считался
# литералом. Имя с суффиксом (TokenTest, max_tokens) без "="/":" следом не
# ловится — это и убирает ложные срабатывания прежнего правила. Кавычка
# между именем и "=/:" — JSON-форма ("token": "…"), "=>" — PHP-массив.
# Первый символ литерала — не ":": иначе оператор области видимости
# (Password::defaults, --filter=…TokenTest::test_x) читался бы как
# "двоеточие + литерал". В хвосте ":" разрешён (URL, base64-подобные значения).
_secret_assign_re='(password|passwd|secret|token|api[_-]?key)[A-Za-z0-9_]*["'\'']?[[:space:]]*(=>?|:)[[:space:]]*["'\'']?'
_secret_assign_re+='[A-Za-z0-9!#%&*+,;<=>?@^_|-][A-Za-z0-9!#%&*+,./:;<=>?@^_|~-]{7,}'
if LC_ALL=C grep -qiE -e "${_secret_assign_re}" <<< "${cmd}"; then
  block_secret "в команде литерал, присвоенный чувствительному имени (password/secret/token/api_key); ${_secret_hint}"
fi

# Лексер команды для правила .env: токены с учётом кавычек, $'…',
# комментариев и подстановок $(…)/`…`/<(…). Исключений он НЕ даёт — только
# находит токены, цели редиректов и границы сегментов; исключения «текст, а
# не команда» даёт шаблон сообщений (ниже), и только он. Here-doc лексер не
# выделяет: тело идёт строками, как команды, — проверяется всё.
#
# Результат — глобальные массивы:
#   _lx_tk        — токены всех сегментов подряд; префикс w — слово, o —
#                   оператор редиректа (> >> < << &> …); кавычки в словах
#                   сохранены, нормализация — у потребителя;
#   _lx_from/_lx_cnt — начало и число токенов сегмента в _lx_tk;
#   _lx_raw       — исходный текст сегмента (поиск подстановок).
# Режимы стека: T — верхний уровень (нет в стеке), S '…', A $'…', D "…",
# C $(…)/<(…), B `…`, P (…) внутри подстановки. Верхний уровень режет
# сегменты по ; && || | & ( ) и переводу строки; внутри остальных режимов
# текст идёт в текущее слово.
_lx_tk=()
_lx_from=()
_lx_cnt=()
_lx_raw=()

# _lex <строка> — разбирает строку, дописывая глобальные массивы.
# Разбор по байтам (LC_ALL=C): байты кириллицы не совпадают с ASCII-
# разделителями. Строка заранее режется на куски (ch): одиночный
# спецсимвол или прогон обычных байт; off — байтовое смещение куска
# (off[nc] = длина строки). Посимвольный ${s:i:1} не годится: подстрока в
# bash стоит O(длины строки) даже в локали C, и обход длинной команды был
# квадратичным; прогоны обычных байт к тому же сокращают число итераций.
_lex() {
  local LC_ALL=C
  local s="$1"
  local n=${#1} nc i=0 c nx m pc stack="" cur="" inword=0 seg0=0 tk0 b=0 run
  local -a ch=() off=() raw=()
  # \x1f — разделитель нарезки ниже: в самой команде заменить байтом той же
  # длины, чтобы смещения не сдвинулись.
  s="${s//$'\x1f'/$'\x1e'}"
  # Нарезка — одним sed: спецсимволы обрамляются \x1f, mapfile режет по \x1f
  # (пустые куски между соседними спецсимволами пропускаются).
  # shellcheck disable=SC2312 # сбой sed ловит сверка длины ниже
  mapfile -d $'\x1f' -t raw < <(printf '%s' "${s}" \
    | sed -E 's/[[:space:]'\''"\\$`<>&|;()#]/\x1f&\x1f/g; s/^/\x1f/; s/$/\x1f/')
  for run in "${raw[@]}"; do
    [[ -n "${run}" ]] || continue
    ch+=("${run}")
    off+=("${b}")
    b=$((b + ${#run}))
  done
  # Куски обязаны покрыть строку целиком — иначе разбор неполон (fail-closed).
  ((b == n)) || block "внутренняя ошибка разбора команды (guard-bash)"
  nc=${#ch[@]}
  off+=("${n}")
  tk0=${#_lx_tk[@]}
  while ((i < nc)); do
    c="${ch[i]}"
    if ((${#c} > 1)); then
      # Прогон обычных байт — часть текущего слова в любом режиме.
      cur+="${c}"
      inword=1
      i=$((i + 1))
      continue
    fi
    nx="${ch[i+1]:-}"
    pc="${ch[i-1]:-}"
    ((i > 0)) || pc=""
    m="${stack: -1}"
    [[ -n "${m}" ]] || m="T"
    case "${m}" in
      S)
        cur+="${c}"
        [[ "${c}" != "'" ]] || stack="${stack%?}"
        ;;
      A)
        cur+="${c}"
        if [[ "${c}" == "\\" ]]; then
          cur+="${nx}"
          i=$((i + 1))
        elif [[ "${c}" == "'" ]]; then
          stack="${stack%?}"
        fi
        ;;
      D)
        cur+="${c}"
        case "${c}" in
          "\\")
            cur+="${nx}"
            i=$((i + 1))
            ;;
          '"') stack="${stack%?}" ;;
          '`') stack+="B" ;;
          '$') _lx_dollar ;;
          *) ;;
        esac
        ;;
      C | B | P)
        # Подстановка: текст — в слово; отслеживаются кавычки, вложенные
        # подстановки, скобки и комментарии (кавычки в комментарии не
        # действуют).
        if [[ "${c}" == "#" && ("${pc}" == "" || "${pc}" == [$' \t\n;|&(']) ]]; then
          while ((i + 1 < nc)) && [[ "${ch[i+1]}" != $'\n' ]]; do i=$((i + 1)); done
        else
          cur+="${c}"
          inword=1
          case "${c}" in
            "'") stack+="S" ;;
            '"') stack+="D" ;;
            "\\")
              cur+="${nx}"
              i=$((i + 1))
              ;;
            '$') _lx_dollar ;;
            '`')
              if [[ "${m}" == "B" ]]; then stack="${stack%?}"; else stack+="B"; fi
              ;;
            "(") stack+="P" ;;
            ")") [[ "${m}" == "B" ]] || stack="${stack%?}" ;;
            *) ;;
          esac
        fi
        ;;
      *)
        # Верхний уровень.
        case "${c}" in
          " " | $'\t') _lx_flush_word ;;
          $'\n' | ";" | "(" | ")")
            if [[ "${c}" == "(" ]] && ((inword)); then
              cur+="${c}"
            else
              _lx_flush_seg
              seg0=${off[i+1]}
            fi
            ;;
          "#")
            if ((inword)); then
              cur+="${c}"
            else
              # Комментарий до конца строки: кавычки в нём не открываются.
              while ((i + 1 < nc)) && [[ "${ch[i+1]}" != $'\n' ]]; do i=$((i + 1)); done
            fi
            ;;
          "&")
            if [[ "${nx}" == ">" ]]; then
              _lx_flush_word
              _lx_op
            else
              _lx_flush_seg
              [[ "${nx}" != "&" ]] || i=$((i + 1))
              seg0=${off[i+1]}
            fi
            ;;
          "|")
            _lx_flush_seg
            [[ "${nx}" != "|" && "${nx}" != "&" ]] || i=$((i + 1))
            seg0=${off[i+1]}
            ;;
          "<" | ">")
            if [[ "${nx}" == "(" ]]; then
              # Процессная подстановка <(…)/>(…) — код внутри слова.
              cur+="${c}("
              inword=1
              i=$((i + 1))
              stack+="C"
            else
              # Номер дескриптора перед редиректом (2>…) — не слово.
              if ((inword)) && [[ "${cur}" =~ ^[0-9]+$ ]]; then
                cur=""
                inword=0
              fi
              _lx_flush_word
              _lx_op
            fi
            ;;
          "'" | '"')
            cur+="${c}"
            inword=1
            if [[ "${c}" == "'" ]]; then stack+="S"; else stack+="D"; fi
            ;;
          '$')
            cur+="${c}"
            inword=1
            _lx_dollar
            ;;
          '`')
            cur+="${c}"
            inword=1
            stack+="B"
            ;;
          "\\")
            if [[ "${nx}" != $'\n' ]]; then
              cur+="${c}${nx}"
              inword=1
            fi
            i=$((i + 1))
            ;;
          *)
            cur+="${c}"
            inword=1
            ;;
        esac
        ;;
    esac
    i=$((i + 1))
  done
  # Хвостовой \ сдвигает i за конец — вернуть на границу строки.
  ((i <= nc)) || i=${nc}
  _lx_flush_seg
}

# Помощники лексера: работают с локальными переменными _lex (динамическая
# область видимости bash).
_lx_flush_word() {
  if ((inword)); then
    _lx_tk+=("w${cur}")
    cur=""
    inword=0
  fi
}
_lx_flush_seg() {
  _lx_flush_word
  if ((${#_lx_tk[@]} > tk0)); then
    _lx_from+=("${tk0}")
    _lx_cnt+=($((${#_lx_tk[@]} - tk0)))
    _lx_raw+=("${s:seg0:off[i]-seg0}")
    tk0=${#_lx_tk[@]}
  fi
}
# Оператор редиректа: > >> < << <<< <> >& <& &> &>> >| — жадно по символам.
_lx_op() {
  local op="${c}"
  while [[ "${ch[i+1]:-}" == [\<\>\&] ]] || [[ "${op}" == ">" && "${ch[i+1]:-}" == "|" ]]; do
    i=$((i + 1))
    op+="${ch[i]}"
    [[ "${op}" != *"|" ]] || break
  done
  _lx_tk+=("o${op}")
}
# $ перед ( или ' — открыть подстановку $(…) или строку $'…' (сам $ уже в
# слове; внутри "…" $'…' — не строка).
_lx_dollar() {
  case "${nx}" in
    "(")
      cur+="("
      i=$((i + 1))
      stack+="C"
      ;;
    "'")
      if [[ "${m}" != "D" ]]; then
        cur+="'"
        i=$((i + 1))
        stack+="A"
      fi
      ;;
    *) ;;
  esac
}

# ---------------------------------------------------------------------------
# Шаблоны сообщений — ЕДИНСТВЕННЫЙ источник исключений «текст, а не команда».
#
# Команда-сообщение ищется строгой грамматикой; её текст сообщения заменяется
# меткой MSG, тело here-doc отбрасывается, а ВСЁ остальное — префикс до
# неё, пути и флаги в ней, хвост цепочки после — остаётся в _scmd, которую
# судят все правила ниже (секреты уже проверили исходную строку: секрет в
# сообщении — тоже утечка). Команда-сообщение:
#   git [-c user.name=…|-c user.email=…|-C <путь>] commit <флаги>
#       [-m|--message|-am… "<текст>"] [-F <путь>|-F -];
#   gh pr|issue create|edit|comment|merge [N] <флаги> [--title|--body|
#       --subject "<текст>"] [--body-file <путь>|--body-file -];
#   echo|printf <аргументы> [> или >> <путь>] — только одиночной командой.
# Формы:
#   A. команда-сообщение в строке или цепочке: <префикс> ; && || & перевод
#      строки <команда-сообщение> ; && || & перевод строки <хвост>;
#   B. <префикс> <команда-сообщение с -F - / --body-file -> <<'EOF' (или
#      <<"EOF", <<-'EOF') в конце строки, тело, строка EOF, <хвост>;
#   C. <префикс> <команда-сообщение> -m/--body "$(cat <<'EOF' в конце
#      строки, тело, строка EOF, строка )" [; && || <хвост>].
# Префикс проверяется простым сканером кавычек: встретил $( ` $' <( >( <<
# ( ) { } или комментарий — дальше команда-сообщение не ищется. Текст
# сообщения — без $ ` \; пути могут содержать $VAR (переменная в пути —
# принятое ограничение хука). Конвейер | сразу после команды-сообщения —
# не шаблон: git commit -m ".env" | xargs cat прочитал бы файл по имени из
# вывода git.
#
# Почему не общий разбор bash: первая версия правки решала «данные или код»
# лексером, и два прохода ревью нашли десять расхождений лексера с bash
# (${x:-<<EOF}, <<< в $( ), $'EOF', # в $( ), CRLF, EOF), $( после
# разделителя, конвейер в теле, 2> как вывод в файл, coproc) — каждое прятало
# настоящие команды за «данными». Грамматика шаблонов мала и проверена целиком;
# лексер ниже исключений не даёт — он только ищет .env.
# ---------------------------------------------------------------------------

# Кусок слова: "…" без ` \ и $ (кроме $VAR/${VAR}), '…', $VAR/${VAR},
# обычные символы.
_tpl_var='\$[A-Za-z_][A-Za-z0-9_]*|\$\{[A-Za-z_][A-Za-z0-9_]*\}'
_tpl_word_re='^(("([^"$`\\]|'"${_tpl_var}"')*"|'\''[^'\'']*'\''|'"${_tpl_var}"'|[A-Za-z0-9_./:@%+,=-])+)'

# _tpl_splits <текст> — в _tpl_pos позиции начал команд верхнего уровня
# (0 и после ; && || & перевода строки вне кавычек) до первой сложной
# конструкции. Проход кусками между спецсимволами (регекс по префиксу).
_tpl_splits() {
  local LC_ALL=C
  local rest="$1" pos=0 pre c last=" "
  local re_plain='^[^'\''"\\;&|<>()$`{}#'$'\n'']*'
  local re_dq='^"([^"\\$`]|\\.|'"${_tpl_var}"')*"'
  _tpl_pos=(0)
  while [[ -n "${rest}" ]]; do
    [[ "${rest}" =~ ${re_plain} ]]
    pre="${BASH_REMATCH[0]}"
    if [[ -n "${pre}" ]]; then
      pos=$((pos + ${#pre}))
      rest="${rest:${#pre}}"
      last="${pre: -1}"
    fi
    [[ -n "${rest}" ]] || break
    c="${rest:0:1}"
    case "${c}" in
      "'")
        pre="${rest:1}"
        [[ "${pre}" == *"'"* ]] || return 0
        pre="${pre%%\'*}"
        pos=$((pos + ${#pre} + 2))
        rest="${rest:${#pre}+2}"
        ;;
      '"')
        [[ "${rest}" =~ ${re_dq} ]] || return 0
        pre="${BASH_REMATCH[0]}"
        pos=$((pos + ${#pre}))
        rest="${rest:${#pre}}"
        ;;
      "\\")
        pos=$((pos + 2))
        rest="${rest:2}"
        ;;
      '$')
        [[ "${rest}" =~ ^(${_tpl_var}) ]] || return 0
        pre="${BASH_REMATCH[0]}"
        pos=$((pos + ${#pre}))
        rest="${rest:${#pre}}"
        ;;
      ";" | $'\n')
        pos=$((pos + 1))
        rest="${rest:1}"
        _tpl_pos+=("${pos}")
        ;;
      "&")
        if [[ "${rest}" == "&&"* ]]; then
          pos=$((pos + 2))
          rest="${rest:2}"
          _tpl_pos+=("${pos}")
        elif [[ "${last}" == [\<\>] || "${rest:1:1}" == ">" ]]; then
          # Часть редиректа: >&2, 2>&1, &>файл.
          pos=$((pos + 1))
          rest="${rest:1}"
        else
          pos=$((pos + 1))
          rest="${rest:1}"
          _tpl_pos+=("${pos}")
        fi
        ;;
      "|")
        if [[ "${rest}" == "||"* ]]; then
          pos=$((pos + 2))
          rest="${rest:2}"
          _tpl_pos+=("${pos}")
        else
          pos=$((pos + 1))
          rest="${rest:1}"
        fi
        ;;
      "<" | ">")
        [[ "${rest:1:1}" != "(" ]] || return 0
        [[ "${rest}" != "<<"* ]] || return 0
        pos=$((pos + 1))
        rest="${rest:1}"
        ;;
      "#")
        [[ "${last}" != [$' \t\n;&|'] ]] || return 0
        pos=$((pos + 1))
        rest="${rest:1}"
        ;;
      *) return 0 ;;
    esac
    last="${c}"
  done
  return 0
}

# _tpl_split <текст> — токены команды-сообщения в _tpl_t (слова, >, >>) до
# первого разделителя ; && || | & или перевода строки вне кавычек: остаток с
# разделителем — в _tpl_tail. Иной символ — _tpl_fail=true.
_tpl_split() {
  local rest="$1" w
  _tpl_t=()
  _tpl_tail=""
  _tpl_fail=false
  while :; do
    rest="${rest#"${rest%%[! $'\t']*}"}"
    [[ -n "${rest}" ]] || break
    if [[ "${rest}" == ">>"* ]]; then
      _tpl_t+=(">>")
      rest="${rest:2}"
    elif [[ "${rest}" == ">"* && "${rest}" != ">&"* && "${rest}" != ">|"* ]]; then
      _tpl_t+=(">")
      rest="${rest:1}"
    elif [[ "${rest}" == [\;\&\|$'\n']* ]]; then
      _tpl_tail="${rest}"
      break
    elif [[ "${rest}" =~ ${_tpl_word_re} ]]; then
      w="${BASH_REMATCH[1]}"
      _tpl_t+=("${w}")
      rest="${rest:${#w}}"
    else
      _tpl_fail=true
      break
    fi
  done
  return 0
}

# _tpl_val — значение флага сообщения: следующий токен без $ заменяется на
# MSG. Работает с локальными tt/i/oo вызывающего _tpl_parse.
_tpl_val() {
  local v="${tt[i+1]:-}"
  [[ -n "${v}" && "${v}" != ">" && "${v}" != ">>" && "${v}" != *'$'* ]] || return 1
  [[ "${v}" != "__CSUB__" ]] || _tpl_csub=1
  oo+=("${tt[i]}" "MSG")
  i=$((i + 1))
}

# _tpl_path — флаг с путём: значение остаётся (его проверят правила), "-" —
# чтение сообщения из stdin.
_tpl_path() {
  local v="${tt[i+1]:-}"
  [[ -n "${v}" && "${v}" != ">" && "${v}" != ">>" ]] || return 1
  [[ "${v}" != "-" ]] || _tpl_stdin=1
  oo+=("${tt[i]}" "${v}")
  i=$((i + 1))
}

# _tpl_parse — разбор _tpl_t по грамматике команды-сообщения; 0 — совпало.
# Пишет _tpl_out (очищенная команда), _tpl_kind (git/gh/echo), _tpl_stdin
# (1 — сообщение из stdin), _tpl_csub (1 — значением стал "$(cat <<…)").
# shellcheck disable=SC2310 # отказ шаблона — штатный код возврата
_tpl_parse() {
  local -a tt=("${_tpl_t[@]}") oo=()
  local n=${#_tpl_t[@]} i=0 u sub seen=0
  _tpl_stdin=0
  _tpl_csub=0
  _tpl_out=""
  _tpl_kind="${tt[0]:-}"
  ((n > 0)) || return 1
  case "${tt[0]}" in
    git)
      oo+=(git)
      i=1
      while [[ "${tt[i]:-}" == "-c" || "${tt[i]:-}" == "-C" ]]; do
        if [[ "${tt[i]}" == "-c" ]]; then
          # Только имя/почта автора: прочие ключи конфига исполняют код
          # (core.hooksPath, core.fsmonitor, alias.*).
          u="${tt[i+1]:-}"
          u="${u//[\"\']/}"
          [[ "${u}" =~ ^user\.(name|email)=[^[:cntrl:]\$]*$ ]] || return 1
        else
          [[ -n "${tt[i+1]:-}" ]] || return 1
        fi
        oo+=("${tt[i]}" "${tt[i+1]}")
        i=$((i + 2))
      done
      [[ "${tt[i]:-}" == "commit" ]] || return 1
      oo+=(commit)
      i=$((i + 1))
      while ((i < n)); do
        case "${tt[i]}" in
          -a | --all | -q | --quiet | -s | --signoff | -n | --no-verify | -v | --verbose | --amend | --no-edit | --allow-empty | -e | --edit)
            oo+=("${tt[i]}")
            ;;
          -F | --file) _tpl_path || return 1 ;;
          -F- | --file=-)
            oo+=("${tt[i]}")
            _tpl_stdin=1
            ;;
          --file=?*) oo+=("${tt[i]}") ;;
          -m | --message) _tpl_val || return 1 ;;
          --message=?* | -m?*)
            # Слитное значение: без $ (токенизатор уже исключил ` \).
            [[ "${tt[i]}" != *'$'* ]] || return 1
            if [[ "${tt[i]}" == --message=* ]]; then oo+=("--message=MSG"); else oo+=("-mMSG"); fi
            ;;
          *)
            # Кластер флагов без значения, оканчивающийся на m (-am, -qm).
            [[ "${tt[i]}" =~ ^-[aqsvn]+m$ ]] || return 1
            _tpl_val || return 1
            ;;
        esac
        i=$((i + 1))
      done
      ;;
    gh)
      [[ "${tt[1]:-}" == "pr" || "${tt[1]:-}" == "issue" ]] || return 1
      sub="${tt[2]:-}"
      case "${tt[1]}:${sub}" in
        pr:create | pr:edit | pr:comment | pr:merge | issue:create | issue:edit | issue:comment) ;;
        *) return 1 ;;
      esac
      oo+=(gh "${tt[1]}" "${sub}")
      i=3
      if [[ "${tt[i]:-}" =~ ^[0-9]+$ ]]; then
        oo+=("${tt[i]}")
        i=$((i + 1))
      fi
      while ((i < n)); do
        case "${sub}:${tt[i]}" in
          create:--draft | create:-d | create:--fill | merge:--squash | merge:-s | merge:--merge | merge:-m | merge:--rebase | merge:-r | merge:--delete-branch | merge:-d | merge:--auto)
            oo+=("${tt[i]}")
            ;;
          *:--title | *:-t | *:--body | *:-b | merge:--subject) _tpl_val || return 1 ;;
          *:--title=?* | *:--body=?* | merge:--subject=?*)
            [[ "${tt[i]}" != *'$'* ]] || return 1
            oo+=("${tt[i]%%=*}=MSG")
            ;;
          *:--body-file | *:-F) _tpl_path || return 1 ;;
          *:--body-file=?* | *:-F-)
            oo+=("${tt[i]}")
            [[ "${tt[i]}" != "--body-file=-" && "${tt[i]}" != "-F-" ]] || _tpl_stdin=1
            ;;
          *:--base | *:-B | *:--head | *:-H | *:--label | *:-l | *:--assignee | *:-a | *:--reviewer | *:-r | *:--milestone)
            [[ -n "${tt[i+1]:-}" && "${tt[i+1]}" != ">" && "${tt[i+1]}" != ">>" ]] || return 1
            oo+=("${tt[i]}" "${tt[i+1]}")
            i=$((i + 1))
            ;;
          *) return 1 ;;
        esac
        i=$((i + 1))
      done
      ;;
    echo | printf)
      oo+=("${tt[0]}")
      i=1
      while ((i < n)); do
        case "${tt[i]}" in
          ">" | ">>")
            # Вывод — только в файл, последним словом команды.
            [[ -n "${tt[i+1]:-}" && "${tt[i+1]}" != ">" && "${tt[i+1]}" != ">>" ]] || return 1
            ((i + 2 == n)) || return 1
            oo+=("${tt[i]}" "${tt[i+1]}")
            i=$((i + 1))
            ;;
          "__CSUB__") return 1 ;;
          *)
            ((seen == 1)) || oo+=("MSG")
            seen=1
            ;;
        esac
        i=$((i + 1))
      done
      ;;
    *) return 1 ;;
  esac
  _tpl_out="${oo[*]}"
  return 0
}

# _tpl_tail_ok <хвост> — хвост цепочки допустим: пусто или начинается с
# ; && || & перевода строки (не с конвейера |).
_tpl_tail_ok() {
  local t="${1#"${1%%[! $'\t']*}"}"
  [[ -z "${t}" || "${t}" == "&&"* || "${t}" == "||"* || "${t}" == ";"* || "${t}" == $'\n'* ]] \
    || [[ "${t}" == "&"* && "${t}" != "&>"* ]]
}

# _tpl_join <очищенная часть> <хвост> — _scmd = часть + хвост; в хвосте
# (git commit … && gh pr create …) команда-сообщение ищется тем же
# _tpl_try — рекурсия по числу команд-сообщений в цепочке.
# shellcheck disable=SC2310 # отказ шаблона в хвосте — штатный исход
_tpl_join() {
  local done_part="$1" tail="$2"
  if [[ -n "${tail}" ]] && _tpl_try "${tail}"; then
    tail="${_scmd}"
  fi
  _scmd="${done_part}${tail}"
}

# _tpl_try <команда> — 0 и _scmd, если в команде есть команда-сообщение
# одной из форм A/B/C.
# shellcheck disable=SC2310 # отказ шаблона — штатный код возврата
_tpl_try() {
  # Локаль C: смещения _tpl_splits — в байтах, срезы ниже — тоже.
  local LC_ALL=C
  local c="$1" head x dash last j k line pre p sub tail done_part msg_part
  # Бюджет вызовов на команду: рекурсия по цепочке (_tpl_join) без потолка
  # на сотнях git commit … && давала кубическое время и выход хука за
  # таймаут (команда при таймауте не блокируется). Сверх бюджета — отказ:
  # остаток проверяется целиком, как без шаблона.
  ((_tpl_budget-- > 0)) || return 1
  local -a lines
  local re_b="^(.*[^[:space:]])[[:space:]]+<<(-?)'([A-Za-z_][A-Za-z0-9_]*)'\$"
  local re_bq="^(.*[^[:space:]])[[:space:]]+<<(-?)\"([A-Za-z_][A-Za-z0-9_]*)\"\$"
  local re_c="^(.*[^[:space:]])[[:space:]]+\"\\\$\\(cat <<'([A-Za-z_][A-Za-z0-9_]*)'\$"
  mapfile -t lines <<< "${c}"
  last=$((${#lines[@]} - 1))
  # Строка начала here-doc — первая, где он есть; до неё только префикс
  # (сканер ниже откажет, если в префиксе свой << или подстановка).
  for ((j = 0; j <= last; j++)); do
    [[ "${lines[j]}" != *"<<"* ]] || break
  done
  if ((j <= last)) && [[ "${lines[j]}" =~ ${re_c} || "${lines[j]}" =~ ${re_b} || "${lines[j]}" =~ ${re_bq} ]]; then
    # Формы B/C: префикс — строки до j и начало строки j.
    head="${BASH_REMATCH[1]}"
    pre=""
    for ((k = 0; k < j; k++)); do pre+="${lines[k]}"$'\n'; done
    if [[ "${lines[j]}" =~ ${re_c} ]]; then
      x="${BASH_REMATCH[2]}"
      # Тело — до первой строки EOF (строка, начинающаяся с EOF иначе, —
      # отказ: bash в $( ) закрывает here-doc и на «EOF)»), затем строка
      # )" с допустимым хвостом.
      for ((k = j + 1; k <= last; k++)); do
        [[ "${lines[k]}" != "${x}"* ]] || break
      done
      ((k < last)) && [[ "${lines[k]}" == "${x}" && "${lines[k+1]}" == ')"'* ]] || return 1
      tail="${lines[k+1]:2}"
      [[ -z "${tail}" || "${tail}" == [$' \t']* ]] || return 1
      _tpl_tail_ok "${tail}" || return 1
      for ((k = k + 2; k <= last; k++)); do tail+=$'\n'"${lines[k]}"; done
      sub="${head} __CSUB__"
    else
      [[ "${lines[j]}" =~ ${re_b} || "${lines[j]}" =~ ${re_bq} ]]
      dash="${BASH_REMATCH[2]}"
      x="${BASH_REMATCH[3]}"
      # Тело — до первой строки, равной разделителю (как в bash).
      for ((k = j + 1; k <= last; k++)); do
        line="${lines[k]}"
        [[ -z "${dash}" ]] || line="${line#"${line%%[!$'\t']*}"}"
        [[ "${line}" != "${x}" ]] || break
      done
      ((k <= last)) || return 1
      tail=""
      for ((k = k + 1; k <= last; k++)); do tail+=$'\n'"${lines[k]}"; done
      sub="${head}"
    fi
    _tpl_splits "${pre}${head}"
    for p in "${_tpl_pos[@]}"; do
      ((p >= ${#pre})) || continue
      _tpl_split "${sub:p-${#pre}}"
      ! ${_tpl_fail} || continue
      [[ -z "${_tpl_tail}" ]] || continue
      _tpl_parse || continue
      [[ "${_tpl_kind}" == "git" || "${_tpl_kind}" == "gh" ]] || continue
      if [[ "${sub}" == *" __CSUB__" ]]; then
        ((_tpl_csub == 1 && _tpl_stdin == 0)) || continue
      else
        ((_tpl_stdin == 1)) || continue
      fi
      # Префикс перед here-doc-командой тоже может содержать команду-сообщение
      # (git commit -m … && gh pr create --body-file - <<'EOF'): ищем в нём
      # форму A. Значения _tpl_* сохраняются до рекурсии — она их затирает.
      done_part="${pre}${head:0:p-${#pre}}"
      msg_part="${_tpl_out}"
      # Префикс длиннее 4 КБ не разбирается: каждый проход сканера по нему
      # стоит секунды, а сообщение в длинном префиксе редкость (ложная
      # блокировка безопаснее выхода хука за таймаут).
      if ((${#done_part} <= 4096)) && [[ -n "${done_part//[[:space:]]/}" ]] && _tpl_try "${done_part}"; then
        done_part="${_scmd}"
      fi
      _tpl_join "${done_part}${msg_part}" "${tail}"
      return 0
    done
    return 1
  fi
  # Форма A.
  [[ "${c}" != *"<<"* ]] || return 1
  _tpl_splits "${c}"
  for p in "${_tpl_pos[@]}"; do
    _tpl_split "${c:p}"
    ! ${_tpl_fail} || continue
    _tpl_parse || continue
    ((_tpl_stdin == 0 && _tpl_csub == 0)) || continue
    _tpl_tail_ok "${_tpl_tail}" || continue
    if [[ "${_tpl_kind}" == "echo" || "${_tpl_kind}" == "printf" ]]; then
      # echo/printf — только одиночной командой: иначе вывод уходит дальше.
      if ((p != 0)) || [[ -n "${_tpl_tail}" ]]; then continue; fi
    fi
    _tpl_join "${c:0:p}${_tpl_out}" "${_tpl_tail}"
    return 0
  done
  return 1
}

_scmd="${cmd}"
# Команду-сообщение ищем только там, где она может быть (дешёвый фильтр), в
# командах до 16 КБ и не более чем 8 вызовами _tpl_try (см. _tpl_budget).
_tpl_budget=8
if ((${#cmd} <= 16384)) && [[ "${cmd}" == *commit* || "${cmd}" == *"gh "* || "${cmd}" =~ ^[[:space:]]*(echo|printf)[[:space:]] ]]; then
  set -f
  # shellcheck disable=SC2310 # отказ шаблона — штатный исход
  _tpl_try "${cmd}" || true
  set +f
fi

# Длинная команда: лексер не запускается (разбор длинного текста в bash
# медленный, а таймаут хука команду не блокирует) — .env ищется грубо.
_LX_MAX=32768
_lx_big=false
set -f
if ((${#_scmd} > _LX_MAX)); then
  _lx_big=true
else
  _lex "${_scmd}"
fi

# _has_subst <текст> — _hs=true, если в тексте подстановка $( ` <( >(.
# Пара \+перевод строки сначала склеивается: bash превращает $\⏎( в $(.
_has_subst() {
  local t="${1//$'\\\n'/}"
  _hs=false
  # Кавычки не учитываются намеренно: вырезание '…' регексом прятало
  # настоящую подстановку за экранированным апострофом (ls .env \'$(cat .env)\').
  # Цена — ложная блокировка ls .env '$(true)'.
  # shellcheck disable=SC2016 # '$(' и '`' — литералы для поиска
  if [[ "${t}" == *'$('* || "${t}" == *'`'* || "${t}" == *'<('* || "${t}" == *'>('* ]]; then
    _hs=true
  fi
}

# _classify_seg <индекс сегмента> — команда сегмента для правила .env:
#   _sc_ci/_sc_c0 — индекс и имя команды (первое слово, не присваивание, не
#                   цель ведущего редиректа, не { ! then do …);
#   _sc_w1        — первое слово сразу после команды (allowlist git status —
#                   только без глобальных опций: git -c … status исполняет
#                   произвольный конфиг, например core.fsmonitor);
#   _sc_subst     — true, если в сегменте есть подстановка.
_classify_seg() {
  local sg="$1" from to j t tn
  from=${_lx_from[sg]}
  to=$((from + _lx_cnt[sg]))
  _has_subst "${_lx_raw[sg]}"
  _sc_subst=${_hs}
  _sc_ci=-1
  _sc_c0=""
  _sc_w1=""
  for ((j = from; j < to; j++)); do
    t="${_lx_tk[j]}"
    if [[ "${t:0:1}" == "o" ]]; then
      j=$((j + 1))
      continue
    fi
    t="${t:1}"
    [[ ! "${t}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    tn="${t//[\"\'\\]/}"
    case "${tn}" in
      "{" | "}" | "!" | then | do | else | elif | if | while | until | time) continue ;;
      *) ;;
    esac
    _sc_ci=${j}
    break
  done
  ((_sc_ci >= 0)) || return 0
  tn="${_lx_tk[_sc_ci]:1}"
  tn="${tn//[\"\'\\]/}"
  tn="${tn,,}"
  _sc_c0="${tn##*/}"
  if ((_sc_ci + 1 < to)) && [[ "${_lx_tk[_sc_ci+1]}" == w* ]]; then
    tn="${_lx_tk[_sc_ci+1]:1}"
    _sc_w1="${tn//[\"\'\\]/}"
  fi
  return 0
}

set +f
# Текст для правил ниже (rm, git/gh, вывод окружения, git reset/push/
# branch -D): очищенная шаблоном команда либо исходная. Правила секретов
# уже проверили всю исходную строку — секрет в сообщении коммита тоже утечка.
_code="${_scmd}"

# rm -r / rm -rf / rm --recursive (рекурсивное удаление). Флаг -f не делает
# удаление более опасным здесь — без интерактивного stdin (как у агента) -r
# без -f удаляет write-protected файлы точно так же безвозвратно, без
# подтверждения, поэтому ловим сам факт рекурсии, а не обязательную пару
# -r+-f.
# Разбираем составную команду на под-сегменты по &&, ||, ; и | — иначе
# /tmp-исключение ниже ломается на цепочках вида
# "mkdir -p /tmp/x && rm -rf /tmp/x": проверка всей строки целиком включала
# бы соседние команды и блокировала бы безопасный /tmp-кейс.
#
# Внутри сегмента аргументы rm разбираются по словам (а не одним regex-
# проходом), потому что GNU rm пропускает флаги через getopt-permutation —
# recursive-флаг может стоять и после операнда (rm /home/x -r). Команда
# ищется равенством токена (rm или путь, заканчивающийся на /rm), а не
# вырезанием текста до последнего слова "rm" — иначе слово "rm" внутри имени
# операнда (rm -rf /home/rm-backup) обрезает разбор раньше настоящих флагов
# и глушит детект. _operand_seen отдельно от "операнд вне /tmp" нужен для
# rm без аргумента-пути в самой команде (find . | xargs rm -rf — пути идут
# через stdin): без этого флага такой вызов не блокировался бы.
set -f
_segments="$(printf '%s\n' "${_code}" | sed -E 's/(&&|\|\||;|\|)/\n/g')"
while IFS= read -r _seg; do
  if grep -qiE '\brm\b' <<< "${_seg}"; then
    _seen_rm=false
    _is_recursive=false
    _operand_seen=false
    _has_non_tmp_operand=false
    _opts_ended=false
    for _tok in ${_seg}; do
      # Lowercase — только для регистронезависимого опознания команды/флагов
      # (как и остальной файл, который матчит git/rm через grep -i).
      # Сравнение операнда с /tmp ниже идёт по ИСХОДНОМУ "${_tok}", не
      # "${_tok_lc}" — /tmp на Linux регистрочувствителен, и без этого
      # разделения "rm -rf /TMP/x" лоуэркейснулся бы в "/tmp/x" и прошёл бы
      # /tmp-исключение, хотя реально удаляет путь вне /tmp.
      _tok_lc="${_tok,,}"
      if ! ${_seen_rm}; then
        case "${_tok_lc}" in
          rm|*/rm) _seen_rm=true ;;
          *) ;;
        esac
        continue
      fi
      if ! ${_opts_ended} && [[ "${_tok_lc}" = "--" ]]; then
        _opts_ended=true
        continue
      fi
      if ! ${_opts_ended} && [[ "${_tok_lc#-}" != "${_tok_lc}" ]]; then
        case "${_tok_lc}" in
          --recursive) _is_recursive=true ;;
          --*) ;;                     # прочие длинные опции не про рекурсию
          *r*) _is_recursive=true ;;  # короткий кластер с 'r' (-r/-rf/-fr/-vr…)
          *) ;;
        esac
        continue
      fi
      _operand_seen=true
      case "${_tok}" in
        /tmp|/tmp/*) ;;
        *) _has_non_tmp_operand=true ;;
      esac
    done
    if ${_is_recursive} && { ${_has_non_tmp_operand} || ! ${_operand_seen}; }; then
      block "рекурсивное удаление (rm -r/-rf/--recursive)"
    fi
  fi

  # Опасные подфлаги у read-only git/gh-команд — механический барьер для
  # инварианта 3 скилла review-code: префикс allowed-tools вида
  # "Bash(git diff:*)" авто-одобряет команду целиком и НЕ запрещает подфлаги,
  # а --output/--no-index/--ext-diff превращают формально read-only команду
  # в запись файла, чтение вне репозитория или запуск внешней программы.
  # Флаг-сеты у git и gh РАЗДЕЛЬНЫЕ: -w у "git diff" — легитимный
  # ignore-all-space, а у gh — открытие браузера (--web); общий набор давал
  # бы ложную блокировку повседневного "git diff -w".
  if grep -qiE '\b(git|gh)\b' <<< "${_seg}"; then
    _g_cmd=""       # какая команда найдена в сегменте: git | gh
    _g_sub=false    # git: read-only подкоманда (diff/log/blame/show); gh: "pr"
    _g_leaf=false   # gh: после "pr" найден leaf diff|view (git не использует)
    _g_hit=""       # первый найденный опасный подфлаг (для текста блокировки)
    for _tok in ${_seg}; do
      _tok_lc="${_tok,,}"
      if [[ -z "${_g_cmd}" ]]; then
        case "${_tok_lc}" in
          git|*/git) _g_cmd="git" ;;
          gh|*/gh)   _g_cmd="gh" ;;
          *) ;;
        esac
        continue
      fi
      if ! ${_g_sub}; then
        if [[ "${_g_cmd}" = "git" ]]; then
          case "${_tok_lc}" in diff|log|blame|show) _g_sub=true ;; *) ;; esac
        else
          case "${_tok_lc}" in pr) _g_sub=true ;; *) ;; esac
        fi
        continue
      fi
      # Токены после охраняемой подкоманды. "--" завершает опции: всё дальше
      # git/gh трактуют как пути/аргументы, флаги там не ищем — иначе файл
      # с именем "--output" ("git diff -- --output") давал бы ложную
      # блокировку.
      if [[ "${_tok}" = "--" ]]; then
        break
      fi
      if [[ "${_g_cmd}" = "gh" ]] && ! ${_g_leaf}; then
        case "${_tok_lc}" in
          diff|view) _g_leaf=true; continue ;;
          *) ;;
        esac
      fi
      # Флаги матчим по ИСХОДНОМУ регистру (не ${_tok_lc}): git/gh принимают
      # опции только в точном регистре, поэтому обход через регистр
      # невозможен, а лоуэркейс дал бы ложную блокировку -O (orderfile ≠ -o).
      _flag="${_tok%%=*}"
      if [[ "${_g_cmd}" = "git" ]]; then
        case "${_flag}" in
          --?*)
            # git принимает однозначные СОКРАЩЕНИЯ long-опций (--outp= ==
            # --output=), поэтому матчим «токен — префикс опасного флага»,
            # а не только точную форму. Неоднозначное сокращение (--o, --e)
            # git отвергает сам, так что лишняя блокировка тут безвредна.
            for _dflag in --output --ext-diff --no-index --exec; do
              if [[ "${_dflag}" == "${_flag}"* ]]; then
                _g_hit="${_tok}"
                break
              fi
            done
            ;;
          -o*) _g_hit="${_tok}" ;;  # -o / -o<file>: запись вывода в файл
          *) ;;
        esac
      else
        case "${_flag}" in
          --web|--repo|--exec) _g_hit="${_tok}" ;;
          --*) ;;  # прочие long-опции: gh (cobra) сокращений НЕ принимает,
                   # поэтому точного совпадения достаточно
          -R*|-w*) _g_hit="${_tok}" ;;  # -R / -R<owner/repo> / -w
          -*)
            # Кластер коротких флагов (-cw == --comments --web): буквенный
            # токен, содержащий w или R. Может дать ложное срабатывание на
            # прицепленном буквенном значении (-Sfew) — осознанно: ложная
            # блокировка безопаснее открытия браузера/чужого репозитория.
            if [[ "${_tok}" =~ ^-[A-Za-z]+$ && "${_tok}" == *[wR]* ]]; then
              _g_hit="${_tok}"
            fi
            ;;
          *) ;;
        esac
      fi
    done
    if [[ -n "${_g_hit}" ]] && ${_g_sub}; then
      if [[ "${_g_cmd}" = "git" ]]; then
        block "опасный подфлаг ${_g_hit} у read-only git-команды (запись файла / чтение вне репозитория / запуск внешней программы)"
      elif ${_g_leaf}; then
        block "опасный подфлаг ${_g_hit} у gh pr diff/view (открытие браузера / доступ к чужому репозиторию)"
      fi
    fi
  fi
done <<< "${_segments}"
set +f

# git reset --hard
if grep -Eiq '\bgit\b.*\breset\b.*--hard\b' <<< "${_code}"; then
  block "git reset --hard (потеря незакоммиченных изменений)"
fi

# git push --force / -f
if grep -Eiq '\bgit\b.*\bpush\b.*(--force\b|--force-with-lease\b|\s-f\b)' <<< "${_code}"; then
  block "git push --force (перезапись истории на remote)"
fi

# git branch -D (принудительное удаление ветки). Проверка регистрозависимая
# (без -i): блокируем только -D, а безопасный -d (git удалит ветку лишь
# если она полностью влита) пропускаем.
if grep -Eq '\bgit\b.*\bbranch\b.*\s-D\b' <<< "${_code}"; then
  block "git branch -D (принудительное удаление ветки)"
fi

# Вывод окружения процесса/контейнера — секреты в env попадают в транскрипт.
if grep -Eq '/proc/[^[:space:]]*/environ' <<< "${_code}"; then
  block "чтение /proc/*/environ (окружение процесса с секретами)"
fi

# Вывод окружения (printenv/env/export/set/declare, docker compose config,
# … exec … env) — по сегментам текста _code (очищенного шаблоном сообщений).
set -f
while IFS= read -r _seg; do
  read -ra _w <<< "${_seg}"
  # Ведущие присваивания (FOO=1 cmd) — не команда сегмента.
  _i=0
  while [[ ${_i} -lt ${#_w[@]} && "${_w[${_i}]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    _i=$((_i + 1))
  done
  [[ ${_i} -lt ${#_w[@]} ]] || continue
  _c0="${_w[${_i}],,}"
  _c0="${_c0##*/}"
  _args=("${_w[@]:$((_i + 1))}")

  # Голые printenv/env/export/set/declare печатают всё окружение. У env
  # аргумент-команда (env FOO=1 cmd) — запуск, а не вывод; -u/-C берут
  # значение следующим токеном.
  _only_flags=true
  _skip=false
  for _t in "${_args[@]}"; do
    if ${_skip}; then _skip=false; continue; fi
    case "${_c0}:${_t}" in
      env:-u|env:--unset|env:-C|env:--chdir) _skip=true ;;
      env:*=*) ;;
      *:-*) ;;
      *) _only_flags=false; break ;;
    esac
  done
  case "${_c0}" in
    printenv|env|export|declare|typeset)
      if ${_only_flags}; then
        block "вывод переменных окружения (${_c0} без аргументов) может раскрыть секреты"
      fi
      ;;
    set)
      if [[ ${#_args[@]} -eq 0 ]]; then
        block "вывод переменных окружения (set без аргументов) может раскрыть секреты"
      fi
      ;;
    *) ;;
  esac
  # docker compose config / … exec … env — сверка по ТОКЕНАМ от команды
  # сегмента, а не регексом по строке: \b считает "." и "/" границей слова,
  # и "grep x docker-compose.yml config/app.php" ложно совпадал с
  # "docker-compose … config".
  case "${_c0}" in
    docker|docker-compose|podman|podman-compose|kubectl)
      _d_compose=false
      _d_exec=false
      if [[ "${_c0}" == *-compose ]]; then _d_compose=true; fi
      for _t in "${_args[@]}"; do
        _t="${_t,,}"
        if ${_d_exec}; then
          case "${_t##*/}" in
            env|printenv) block "вывод окружения контейнера (exec … env/printenv) может раскрыть секреты" ;;
            *) ;;
          esac
          continue
        fi
        case "${_t}" in
          compose) _d_compose=true ;;
          config)
            if ${_d_compose}; then
              block "docker compose config выводит конфигурацию с подставленными секретами"
            fi
            ;;
          exec) _d_exec=true ;;
          *) ;;
        esac
      done
      ;;
    *) ;;
  esac
done <<< "${_segments}"
set +f

# .env-файлы — fail-closed: сегмент, в котором есть путь-токен .env или
# .env.<суффикс>, блокируется при ЛЮБОЙ команде, кроме allowlist безвредных
# (ls, stat, test/[/[[, git status, git check-ignore). Прежний список
# «читающих» утилит (cat/less/head…) пропускал grep/sed/awk/source/
# интерпретаторы/cp — перечислить всех читателей невозможно. Шаблоны
# (.env.example/.env.dist/.env.sample) секретов не содержат и разрешены.
#
# Токены — из лексера; перед сверкой кавычки и \ снимаются по правилам bash
# (_env_unquote): иначе .e""nv, .\env, $'.env', $'\x2eenv' обходили
# правило, а open(f'.env') терял ограничитель. Снимать \ без учёта кавычек
# нельзя: "\.env" и '\\.env' — регулярки grep/nginx, а не путь. Вхождение
# .env ищется с ограничителями: слева начало слова, пробел или / = : < > ( `
# @ , { " ' (пути, --file=.env, редиректы, $(…), open('.env'),
# curl -F f=@.env, {a,.env}), справа конец слова, пробел, ; ) ` > , } " ',
# glob * ? [ { ~ либо суффикс .<буква/цифра/glob> (.env.local, .env.*,
# .env*, .env{,}, .env~) — поэтому process.env.FOO, .envrc и точка в конце
# фразы («боевой .env.») под правило не попадают. Слитное значение короткой
# опции (-F.env, -T.env) проверяется отдельно. Glob в кавычках ('.env*') —
# тоже вхождение: такой шаблон отбирает файлы (find -name, grep --include).
#
# Цель редиректа (> < >> <> …) — всегда путь и блокирует даже allowlist
# (ls > .env перезаписывает файл, git check-ignore --stdin < .env печатает
# его строки). Подстановка $( ` <( >( в сегменте блокирует .env даже у
# allowlist-команды (ls $(cat .env) исполняет cat). Упоминание .env в
# тексте сообщения сюда не доходит: шаблон сообщений заменил текст на MSG.
#
# Не ловится (текст без исполнения этого не различит — нужен sandbox ОС):
# неполные glob-и (.en?, .e*), путь через переменную или файл-посредник.
# shellcheck disable=SC2016 # ` в регексе — литерал
_env_path_re='(^|[[:space:]/=:<>(`@,{"'\''])\.env($|[[:space:];)`>,}"'\''*?[{~]|\.[[:alnum:]_*?[{-])'
_env_tpl_re='^(.*)\.env\.(example|dist|sample)(([[:space:]:;)`>,}"'\'']|\.([^[:alnum:]_*?[{-]|$)|$).*)$'
_env_msg="обращение к .env-файлу (секреты): разрешены ls/stat/test/[/[[/git status/git check-ignore; шаблоны .env.example/.env.dist/.env.sample — свободно. Упоминание в тексте сообщения пропускается в строгих формах (в том числе в цепочке && ;): git commit -m \"…\" / -F - <<'EOF', gh pr|issue … --title/--body \"…\" / --body-file - <<'EOF', -m \"\$(cat <<'EOF' …)\"; echo/printf — только одиночной командой. Иначе текст с .env — в файл (Write) и -F/--body-file; проверка .gitignore — git check-ignore -q .env"

# _env_unquote <токен> — в _tu слово, каким его получит команда: кавычки
# сняты; \ снят вне кавычек, а в "…" — только перед $ ` " \ и переводом
# строки (как в bash); $'…' раскрыт (${x@E} только раскрывает escape-
# последовательности и ничего не исполняет); $"…" — как "…". Проход
# кусками между спецсимволами (регекс по префиксу), а не ${t:i:1}: тот
# квадратичен на длинном токене.
_env_unquote() {
  local rest="$1" out="" pre c n2 acc
  local re0='^[^"'\''\\$]*' re1='^[^"\\]*' re2="^[^'\\\\]*"
  _tu="$1"
  [[ "${rest}" == *[\"\'\\\$]* ]] || return 0
  while [[ -n "${rest}" ]]; do
    [[ "${rest}" =~ ${re0} ]]
    pre="${BASH_REMATCH[0]}"
    out+="${pre}"
    rest="${rest:${#pre}}"
    [[ -n "${rest}" ]] || break
    c="${rest:0:1}"
    n2="${rest:1:1}"
    case "${c}" in
      "'")
        rest="${rest:1}"
        pre="${rest%%\'*}"
        out+="${pre}"
        rest="${rest:${#pre}}"
        rest="${rest:1}"
        ;;
      '"')
        rest="${rest:1}"
        while [[ -n "${rest}" ]]; do
          [[ "${rest}" =~ ${re1} ]]
          pre="${BASH_REMATCH[0]}"
          out+="${pre}"
          rest="${rest:${#pre}}"
          c="${rest:0:1}"
          if [[ "${c}" == '"' ]]; then
            rest="${rest:1}"
            break
          elif [[ "${c}" == "\\" ]]; then
            n2="${rest:1:1}"
            case "${n2}" in
              '$' | '`' | '"' | "\\") out+="${n2}" ;;
              $'\n') ;;
              *) out+="\\${n2}" ;;
            esac
            rest="${rest:2}"
          else
            break
          fi
        done
        ;;
      "\\")
        [[ "${n2}" == $'\n' ]] || out+="${n2}"
        rest="${rest:2}"
        ;;
      '$')
        if [[ "${n2}" == "'" ]]; then
          rest="${rest:2}"
          acc=""
          while [[ -n "${rest}" ]]; do
            [[ "${rest}" =~ ${re2} ]]
            pre="${BASH_REMATCH[0]}"
            acc+="${pre}"
            rest="${rest:${#pre}}"
            c="${rest:0:1}"
            if [[ "${c}" == "\\" ]]; then
              acc+="${rest:0:2}"
              rest="${rest:2}"
            else
              rest="${rest:1}"
              break
            fi
          done
          out+="${acc@E}"
        elif [[ "${n2}" == '"' ]]; then
          rest="${rest:1}"
        else
          out+='$'
          rest="${rest:1}"
        fi
        ;;
      *) ;;
    esac
  done
  _tu="${out}"
}

# _env_match <текст> — _env_tok_res=true, если в тексте вхождение .env
# (шаблоны .env.example/.env.dist/.env.sample вырезаются до проверки).
_env_match() {
  local t="$1"
  while [[ "${t}" =~ ${_env_tpl_re} ]]; do
    t="${BASH_REMATCH[1]}${BASH_REMATCH[3]}"
  done
  _env_tok_res=false
  if [[ "${t}" =~ ${_env_path_re} ]]; then _env_tok_res=true; fi
}

# _env_tok_hit <токен> — _env_tok_res=true, если токен ссылается на
# .env-файл (результат в переменной, а не кодом возврата: вызов в условии
# отключал бы set -e внутри функции). Токен длиннее _ENV_TOK_MAX
# проверяется грубо — кавычки и \ сняты целиком либо заменены пробелом, и
# совпадение любого варианта считается вхождением (fail-closed по времени).
_ENV_TOK_MAX=32768
_env_tok_hit() {
  local t="$1" tt
  _env_tok_res=false
  if ((${#t} > _ENV_TOK_MAX)); then
    _env_match "${t//[\"\'\\]/}"
    ${_env_tok_res} || _env_match "${t//[\"\'\\]/ }"
    return 0
  fi
  _env_unquote "${t}"
  _env_match "${_tu}"
  ${_env_tok_res} && return 0
  # Слитное значение короткой опции: -F.env, -aT.env.
  if [[ "${_tu}" == -[!-]* ]]; then
    tt="${_tu#-}"
    while [[ "${tt}" =~ ^[A-Za-z0-9] ]]; do
      tt="${tt:1}"
      _env_match "${tt}"
      ${_env_tok_res} && return 0
    done
  fi
  return 0
}

# Локаль C на весь цикл, а не local в функциях: local LC_ALL вызывает
# setlocale на каждом входе и выходе, и на сотнях токенов это секунды.
# После цикла идёт только exit — восстанавливать локаль не нужно.
LC_ALL=C
set -f
if ${_lx_big}; then
  # Команда длиннее _LX_MAX не разбиралась лексером — грубая проверка всей
  # строки: любое вхождение .env блокирует.
  _env_tok_hit "${_scmd}"
  ! ${_env_tok_res} || block "${_env_msg}"
fi
for _s in "${!_lx_from[@]}"; do
  _classify_seg "${_s}"
  _from=${_lx_from[_s]}
  _to=$((_from + _lx_cnt[_s]))
  _env_hit=false
  _next_path=false
  for ((_j = _from; _j < _to; _j++)); do
    _t="${_lx_tk[_j]}"
    if [[ "${_t:0:1}" == "o" ]]; then
      _next_path=true
      continue
    fi
    _t="${_t:1}"
    if ${_next_path}; then
      # Цель редиректа — путь; .env здесь блокирует при любой команде.
      _next_path=false
      _env_tok_hit "${_t}"
      ! ${_env_tok_res} || block "${_env_msg}"
      continue
    fi
    _env_tok_hit "${_t}"
    if ${_env_tok_res}; then
      _env_hit=true
      break
    fi
  done
  if ${_env_hit}; then
    ! ${_sc_subst} || block "${_env_msg}"
    case "${_sc_c0}" in
      ls | stat | test | \[ | \[\[) ;;
      git)
        case "${_sc_w1}" in
          status | check-ignore) ;;
          *) block "${_env_msg}" ;;
        esac
        ;;
      *) block "${_env_msg}" ;;
    esac
  fi
done
set +f

exit 0
