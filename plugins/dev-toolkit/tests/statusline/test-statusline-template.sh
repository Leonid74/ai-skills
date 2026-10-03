#!/usr/bin/env bash
# Тест шаблона statusline.sh из skills/statusline-setup/SKILL.md: шаблон
# извлекается из Markdown и исполняется на фикстурах JSON. Настоящий tmux не
# нужен и не вызывается: в PATH стоят заглушки tmux и timeout, которые пишут
# свои аргументы и потоки в журнал.
# Запуск из корня репозитория:
#   bash plugins/dev-toolkit/tests/statusline/test-statusline-template.sh
set -uo pipefail

# STATUSLINE_TEMPLATE — путь к готовому скрипту вместо извлечения из SKILL.md
# (для мутационной проверки теста).
_skill="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../skills/statusline-setup/SKILL.md"
_pass=0
_fail=0
_root="$(mktemp -d)"
trap 'rm -rf "${_root}"' EXIT

# Шаблон — блок ```bash, начинающийся с shebang (не блок шага 0 с «jq --version»).
_tpl="${_root}/statusline.sh"
if [[ -n "${STATUSLINE_TEMPLATE:-}" ]]; then
  cp "${STATUSLINE_TEMPLATE}" "${_tpl}"
else
  awk '
    /^```bash$/ { blk = 1; first = 1; next }
    /^```$/     { if (keep) exit; blk = 0; next }
    blk && first { first = 0; if ($0 ~ /^#!/) keep = 1 }
    keep
  ' "${_skill}" >"${_tpl}"
fi

# Каталог команд для PATH: только то, что нужно шаблону, плюс заглушки. Так
# проверяется и поведение без tmux/timeout, и то, что настоящий tmux не задет.
_log="${_root}/calls.log"
_tools=(bash cat jq git whoami hostname sleep readlink)

# make_bin <имя каталога> <режим timeout: ok|hang|none> <tmux: yes|no>
make_bin() {
  local _dir="${_root}/$1" _t
  mkdir -p "${_dir}"
  for _t in "${_tools[@]}"; do
    ln -s "$(command -v "${_t}")" "${_dir}/${_t}"
  done
  # Заглушка timeout: аргументы и потоки — в журнал. В режиме hang не
  # завершается 3 с — так виден запуск не в фоне и неотрезанный stdout.
  if [[ "$2" != none ]]; then
    # Пишет в журнал, а не в свой stdout: stdout заглушки отрезан шаблоном.
    cat >"${_dir}/timeout" <<EOF
#!/usr/bin/env bash
_in="\$(readlink /proc/\$\$/fd/0)"
_out="\$(readlink /proc/\$\$/fd/1)"
{
  printf 'timeout'
  printf ' [%s]' "\$@"
  printf ' stdin=%s stdout=%s\n' "\${_in}" "\${_out}"
} >>"${_log}"
EOF
    [[ "$2" == hang ]] && printf 'sleep 3\n' >>"${_dir}/timeout"
    chmod +x "${_dir}/timeout"
  fi
  if [[ "$3" == yes ]]; then
    printf '%s\n' '#!/usr/bin/env bash' "echo 'tmux вызван напрямую' >>\"${_log}\"" >"${_dir}/tmux"
    chmod +x "${_dir}/tmux"
  fi
}
make_bin ok ok yes
make_bin hang hang yes
make_bin notimeout none yes
make_bin notmux ok no

_fx="${_root}/fx.json"
# Папка фикстур — свой каталог; поиск репозитория git выше него закрыт
# (GIT_CEILING_DIRECTORIES в run), так что сегмента ветки нет, где бы ни лежал
# временный каталог.
_work="${_root}/work"
mkdir -p "${_work}"
_who="\"model\":{\"display_name\":\"M\"},\"workspace\":{\"current_dir\":\"${_work}\"}"

# fixture_raw <JSON целиком> — для векторов с лимитами, effort и полями не того типа.
fixture_raw() {
  printf '%s' "$1" >"${_fx}"
}

# fixture <значение used_percentage | -> — «-» значит «поля нет».
fixture() {
  if [[ "$1" == "-" ]]; then
    fixture_raw "{${_who}}"
  else
    fixture_raw "{${_who},\"context_window\":{\"used_percentage\":$1}}"
  fi
}

_out=""
_err=""
_rc=0
_ms=0
# run <каталог bin> <TMUX | -> <TMUX_PANE | -> [nowait]: вывод, stderr, код,
# длительность (мс); затем ждёт фоновый мост — запись заглушки в журнал.
# nowait — не ждать: вектор вне tmux, где журнал моста не проверяется.
run() {
  local _bin="${_root}/$1" _t0 _t1 _i
  local -a _env=(env -i "PATH=${_bin}" "HOME=${_root}" "GIT_CEILING_DIRECTORIES=${_root}")
  [[ "$2" != "-" ]] && _env+=("TMUX=$2")
  [[ "$3" != "-" ]] && _env+=("TMUX_PANE=$3")
  : >"${_log}"
  _rc=0
  _t0=$(date +%s%N)
  _out="$("${_env[@]}" bash "${_tpl}" <"${_fx}" 2>"${_root}/err")" || _rc=$?
  _t1=$(date +%s%N)
  _ms=$(((_t1 - _t0) / 1000000))
  _err="$(cat "${_root}/err")"
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    [[ "${4:-}" == nowait || -s "${_log}" ]] && break
    sleep 0.05
  done
}

# check <описание> <получено> <ожидалось>
check() {
  if [[ "$2" == "$3" ]]; then
    _pass=$((_pass + 1))
  else
    _fail=$((_fail + 1))
    printf 'FAIL %s\n  получено:  [%s]\n  ожидалось: [%s]\n' "$1" "$2" "$3"
  fi
}

_T='/tmp/tmux-1000/default,4242,0'
_null='stdin=/dev/null stdout=/dev/null'
_cond_pre='#{?#{==:#{pid},4242},'

# --- вне tmux: моста нет, вывод — эталон для остальных векторов --------------
fixture 42.4
run ok - -
_ref="${_out}"
check 'вне tmux: tmux/timeout не вызваны' "$(cat "${_log}")" ''
check 'вне tmux: код возврата' "${_rc}" 0
check 'вне tmux: stderr пуст' "${_err}" ''
check 'вне tmux: сегмент Context округлён' "${_out#* | }" 'M | Context 42%'

# --- в tmux: форма вызова -----------------------------------------------------
run ok "${_T}" %7
check 'запись: вызов' "$(cat "${_log}")" \
  "timeout [-s] [KILL] [1] [tmux] [if] [-F] [-t] [%7] [${_cond_pre}#{!=:#{@claude_ctx},42},0}] [set -p -t %7 @claude_ctx 42] ${_null}"
check 'запись: вывод как вне tmux' "${_out}" "${_ref}"
check 'запись: stderr пуст' "${_err}" ''
check 'запись: код возврата' "${_rc}" 0

_unset="timeout [-s] [KILL] [1] [tmux] [if] [-F] [-t] [%7] [${_cond_pre}#{!=:#{@claude_ctx},},0}] [set -pu -t %7 @claude_ctx] ${_null}"
fixture -
run ok "${_T}" %7
check 'поля нет: снятие опции' "$(cat "${_log}")" "${_unset}"

# Значение вне «1–3 цифры» в текст команды tmux не попадает — ветка снятия.
# Проверяется итог, а не слой: такие значения отсекает уже jq (pct), проверка
# ctx_re в шаблоне — второй рубеж на случай сбоя разбора, входом не достижимый.
for _v in -5 1000 1e19 '"7; kill-server"'; do
  fixture "${_v}"
  run ok "${_T}" %7
  check "used_percentage=${_v}: снятие, не запись" "$(cat "${_log}")" "${_unset}"
  check "used_percentage=${_v}: код возврата" "${_rc}" 0
done

for _v in 0 100; do
  fixture "${_v}"
  run ok "${_T}" %7
  check "used_percentage=${_v}: запись" "$([[ "$(cat "${_log}")" == *"[set -p -t %7 @claude_ctx ${_v}]"* ]] && echo да)" да
done

# --- окружение не от tmux: мост не запускается -------------------------------
fixture 42.4
_nl=$'%7\nkill-server'
for _pane in - '' '%' '%7a' '7' ' %7' '%7; kill-server' "${_nl}"; do
  run ok "${_T}" "${_pane}"
  check "TMUX_PANE=[${_pane}]: моста нет" "$(cat "${_log}")" ''
  check "TMUX_PANE=[${_pane}]: вывод цел" "${_out}" "${_ref}"
done
for _tm in - '' ',4242,0' '/tmp/sock' '/tmp/sock,abc,0' '/tmp/sock,,0' 'sock,4242,0'; do
  run ok "${_tm}" %7
  check "TMUX=[${_tm}]: моста нет" "$(cat "${_log}")" ''
  check "TMUX=[${_tm}]: вывод цел" "${_out}" "${_ref}"
done

# --- зависший tmux: строка статуса не ждёт -----------------------------------
# Заглушка timeout висит 3 с. Мост в фоне и отрезан от stdout — скрипт и канал
# вывода завершаются сразу; иначе $(…) в run ждал бы все 3 с.
run hang "${_T}" %7
check 'зависший мост: вывод цел' "${_out}" "${_ref}"
check 'зависший мост: код возврата' "${_rc}" 0
check 'зависший мост: stderr пуст' "${_err}" ''
check "зависший мост: скрипт не ждёт (${_ms} мс)" "$((_ms < 1500 ? 1 : 0))" 1

# --- нет утилит: мост молча не работает, строка цела -------------------------
run notimeout "${_T}" %7
check 'нет timeout: вывод цел' "${_out}" "${_ref}"
check 'нет timeout: код возврата' "${_rc}" 0
check 'нет timeout: stderr пуст' "${_err}" ''
check 'нет timeout: tmux напрямую не вызван' "$(cat "${_log}")" ''
run notmux "${_T}" %7
check 'нет tmux: вывод цел' "${_out}" "${_ref}"
check 'нет tmux: код возврата' "${_rc}" 0
check 'нет tmux: stderr пуст' "${_err}" ''

# --- лимиты подписки и effort --------------------------------------------------
# Хвост строки после «user@host:папка | » сверяется целиком: так видны и лишний
# сегмент, и сдвиг полей.
_sep=$'\xe2\x97\x94'
_y=$'\033[01;33m'
_r=$'\033[01;31m'
_z=$'\033[00m'
_base="${_who},\"context_window\":{\"used_percentage\":42.4}"

# tail_check <описание> <JSON целиком> <ожидаемый хвост>
tail_check() {
  fixture_raw "$2"
  run ok - - nowait
  check "$1" "${_out#* | }" "$3"
  check "$1: код возврата" "${_rc}" 0
  check "$1: stderr пуст" "${_err}" ''
}

tail_check 'всё есть' \
  "{${_base},\"effort\":{\"level\":\"high\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":33.6,\"resets_at\":1},\"seven_day\":{\"used_percentage\":5,\"resets_at\":2}}}" \
  "M ${_sep} high | Context 42% | 5h 34% | 7d 5%"
tail_check 'только пятичасовое окно' "{${_base},\"rate_limits\":{\"five_hour\":{\"used_percentage\":12}}}" \
  'M | Context 42% | 5h 12%'
tail_check 'только недельное окно' "{${_base},\"rate_limits\":{\"seven_day\":{\"used_percentage\":12}}}" \
  'M | Context 42% | 7d 12%'
tail_check 'rate_limits пуст' "{${_base},\"rate_limits\":{}}" 'M | Context 42%'
tail_check 'rate_limits — строка' "{${_base},\"rate_limits\":\"str\"}" 'M | Context 42%'
tail_check 'rate_limits — массив' "{${_base},\"rate_limits\":[1,2]}" 'M | Context 42%'

# Проценты: один и тот же разбор и одни пороги цвета у всех трёх сегментов.
# pct_check <описание> <значение JSON> <ожидаемый сегмент без подписи | пусто>
pct_check() {
  local _c="" _f="" _s="" _exp="$3"
  if [[ -n "${_exp}" ]]; then
    _c=" | ${_exp/@/Context}"
    _f=" | ${_exp/@/5h}"
    _s=" | ${_exp/@/7d}"
  fi
  tail_check "процент $2 ($1): контекст" "{${_who},\"context_window\":{\"used_percentage\":$2}}" "M${_c}"
  tail_check "процент $2 ($1): пять часов" "{${_base},\"rate_limits\":{\"five_hour\":{\"used_percentage\":$2}}}" \
    "M | Context 42%${_f}"
  tail_check "процент $2 ($1): неделя" "{${_base},\"rate_limits\":{\"seven_day\":{\"used_percentage\":$2}}}" \
    "M | Context 42%${_s}"
}
pct_check 'ноль' 0 '@ 0%'
pct_check 'минус ноль' -0.0 '@ 0%'
pct_check 'округление вниз' 0.4 '@ 0%'
pct_check 'ниже жёлтого' 59.4 '@ 59%'
pct_check 'жёлтый с порога' 59.5 "${_y}@ 60%${_z}"
pct_check 'жёлтый' 79 "${_y}@ 79%${_z}"
pct_check 'красный с порога' 80 "${_r}@ 80%${_z}"
pct_check 'сто' 100.4 "${_r}@ 100%${_z}"
pct_check 'перерасход виден' 103.2 "${_r}@ 103%${_z}"
pct_check 'три цифры — предел' 999.4 "${_r}@ 999%${_z}"
pct_check 'четыре цифры' 999.5 ''
pct_check 'отрицательная дробь' -0.4 ''
pct_check 'отрицательное' -1 ''
pct_check 'огромное' 1e19 ''
pct_check 'строка' '"7; x"' ''
pct_check 'null' null ''
pct_check 'массив' '[1]' ''
pct_check 'объект' '{"a":1}' ''
pct_check 'true' true ''
tail_check 'окно — строка' "{${_base},\"rate_limits\":{\"five_hour\":\"str\",\"seven_day\":{\"used_percentage\":5}}}" \
  'M | Context 42% | 7d 5%'
tail_check 'окно — массив' "{${_base},\"rate_limits\":{\"five_hour\":[1],\"seven_day\":{\"used_percentage\":5}}}" \
  'M | Context 42% | 7d 5%'

# effort уходит в терминал: только строчные латинские буквы, иначе — без него.
for _v in low medium high xhigh max abcdefghijkl; do
  tail_check "effort.level=${_v}" "{${_base},\"effort\":{\"level\":\"${_v}\"}}" "M ${_sep} ${_v} | Context 42%"
done
for _v in '"High"' '"medium\nx"' '"medium\n"' '"\u001b[31mx"' '"a b"' '""' '"abcdefghijklm"' '"a1"' '"é"' 5 null '{"level":"x"}'; do
  tail_check "effort.level=${_v}: без effort" "{${_base},\"effort\":{\"level\":${_v}}}" 'M | Context 42%'
done
tail_check 'effort — строка' "{${_base},\"effort\":\"high\"}" 'M | Context 42%'

# Название модели: управляющие символы в терминал не уходят; пустое и не
# строка — «?», и effort не повисает без названия.
_ctx=',"context_window":{"used_percentage":7}'
_dirj="\"workspace\":{\"current_dir\":\"${_work}\"}"
tail_check 'модель: управляющие символы убраны' \
  "{\"model\":{\"display_name\":\"A\\nB\\rC\\u001b]0;X\\u0007D\\u009bE\\u0000F\\u2028G\\tH\\u007fI é\"},${_dirj}${_ctx}}" \
  'ABC]0;XDEFGHI é | Context 7%'
for _v in '""' '"\n"' '"\u001b\u0007"' 7 null '["M"]' '{"a":1}'; do
  tail_check "модель ${_v}: «?»" "{\"model\":{\"display_name\":${_v}},${_dirj},\"effort\":{\"level\":\"high\"}${_ctx}}" \
    "? ${_sep} high | Context 7%"
done
tail_check 'модель — строка вместо объекта' "{\"model\":\"M\",${_dirj}${_ctx}}" '? | Context 7%'

# --- папка: поля не сдвигаются, в терминал уходит очищенный путь --------------
# head_check <описание> <JSON целиком> <ожидаемая папка в выводе> <ожидаемый хвост>
head_check() {
  local _head
  fixture_raw "$2"
  run ok - - nowait
  _head="${_out%% | *}"
  check "$1: папка" "${_head#*:}" $'\033[01;34m'"$3${_z}"
  check "$1: хвост" "${_out#* | }" "$4"
  check "$1: код возврата" "${_rc}" 0
  check "$1: stderr пуст" "${_err}" ''
}
_full='"model":{"display_name":"M"},"effort":{"level":"low"},"context_window":{"used_percentage":7},"rate_limits":{"five_hour":{"used_percentage":1},"seven_day":{"used_percentage":2}}'
_tail="M ${_sep} low | Context 7% | 5h 1% | 7d 2%"
mkdir -p "${_root}/other"
# HOME в run — корень теста, поэтому папки показываются от «~».
_home='~'
head_check 'current_dir важнее cwd' "{${_full},\"workspace\":{\"current_dir\":\"${_work}\"},\"cwd\":\"${_root}/other\"}" \
  "${_home}/work" "${_tail}"
head_check 'нет current_dir — cwd' "{${_full},\"cwd\":\"${_root}/other\"}" "${_home}/other" "${_tail}"
head_check 'пустой current_dir — cwd' "{${_full},\"workspace\":{\"current_dir\":\"\"},\"cwd\":\"${_root}/other\"}" \
  "${_home}/other" "${_tail}"
head_check 'current_dir не строка — cwd' "{${_full},\"workspace\":{\"current_dir\":5},\"cwd\":\"${_root}/other\"}" \
  "${_home}/other" "${_tail}"
head_check 'workspace не объект — cwd' "{${_full},\"workspace\":\"w\",\"cwd\":\"${_root}/other\"}" "${_home}/other" "${_tail}"
head_check 'путь с NUL — cwd' "{${_full},\"workspace\":{\"current_dir\":\"/x\\u0000y\"},\"cwd\":\"${_root}/other\"}" \
  "${_home}/other" "${_tail}"
# Перевод строки и управляющие символы в пути: показывается очищенный путь, одна
# строка вывода, поля на месте.
head_check 'путь с переводом строки и ESC' "{${_full},\"cwd\":\"/nodir/a\\nb\\u001b[1Ac\\u0007\"}" '/nodir/ab[1Ac' "${_tail}"
check 'путь с переводом строки: вывод в одну строку' "$(printf '%s\n' "${_out}" | grep -c '')" 1
head_check 'путь кончается переводом строки' "{${_full},\"cwd\":\"/nodir/a\\n\"}" '/nodir/a' "${_tail}"
head_check 'путь из одного перевода строки' "{${_full},\"cwd\":\"\\n\"}" '' "${_tail}"
head_check 'путь из переводов строки, модель с переводом строки' \
  "{\"model\":{\"display_name\":\"M\\n\"},\"effort\":{\"level\":\"low\"},\"cwd\":\"\\n\\n\",\"context_window\":{\"used_percentage\":7}}" \
  '' "M ${_sep} low | Context 7%"

# git получает путь как есть, а не очищенный: каталог с переводом строки в
# имени — настоящий репозиторий, ветка должна найтись.
_repo="${_root}/re"$'\n'"po"
mkdir -p "${_repo}"
env -i "PATH=${_root}/ok" "HOME=${_root}" git -C "${_repo}" init -q -b trunk >/dev/null 2>&1
env -i "PATH=${_root}/ok" "HOME=${_root}" git -C "${_repo}" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init >/dev/null 2>&1
jq -n --arg d "${_repo}" '{model:{display_name:"M"},workspace:{current_dir:$d}}' >"${_fx}"
run ok - - nowait
check 'репозиторий с переводом строки в пути: ветка найдена' "${_out#* | }" $'M | \xee\x82\xa0 trunk'
check 'репозиторий с переводом строки в пути: папка очищена' "$([[ "${_out}" == *'~/repo'* ]] && echo да)" да

# Запасные значения: нет ни одного поля, вход не объект — строка статуса цела.
# Папка «.» — рабочий каталог теста, поэтому хвост сверяется по началу.
for _v in '{}' '{"model":"M","workspace":"w","cwd":7,"context_window":"c","rate_limits":7,"effort":[1]}' '[1,2]' '"s"' null 7; do
  fixture_raw "${_v}"
  run ok - - nowait
  _head="${_out%% | *}"
  check "вход ${_v}: папка «.»" "${_head#*:}" $'\033[01;34m'".${_z}"
  check "вход ${_v}: модель «?», сегментов нет" "$([[ "${_out#* | }" == '?' || "${_out#* | }" == '? | '$'\xee\x82\xa0'* ]] && echo да)" да
  check "вход ${_v}: код возврата" "${_rc}" 0
  check "вход ${_v}: stderr пуст" "${_err}" ''
done

# Мост в tmux по-прежнему получает только процент контекста — и тот же, что в
# строке статуса (перерасход 103 — три цифры, пишется).
fixture_raw "{${_base},\"effort\":{\"level\":\"high\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":90},\"seven_day\":{\"used_percentage\":95}}}"
run ok "${_T}" %7
check 'лимиты и мост: в опцию идёт контекст' "$(cat "${_log}")" \
  "timeout [-s] [KILL] [1] [tmux] [if] [-F] [-t] [%7] [${_cond_pre}#{!=:#{@claude_ctx},42},0}] [set -p -t %7 @claude_ctx 42] ${_null}"
for _v in 103.2 999; do
  fixture "${_v}"
  run ok "${_T}" %7
  check "used_percentage=${_v}: запись в опцию" \
    "$([[ "$(cat "${_log}")" == *"[set -p -t %7 @claude_ctx ${_v%.*}]"* ]] && echo да)" да
done
for _v in -0.4 999.5 '[1]'; do
  fixture "${_v}"
  run ok "${_T}" %7
  check "used_percentage=${_v}: снятие, не запись" "$(cat "${_log}")" "${_unset}"
done

printf 'pass=%s fail=%s\n' "${_pass}" "${_fail}"
[[ "${_fail}" -eq 0 ]]
