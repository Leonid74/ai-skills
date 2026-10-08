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
# link_tools <имя каталога> <утилита>…: каталог команд ровно из названных утилит
# (для векторов, где какой-то утилиты нет или она подменена заглушкой).
link_tools() {
  local _dir="${_root}/$1" _t
  shift
  mkdir -p "${_dir}"
  for _t in "$@"; do
    ln -s "$(command -v "${_t}")" "${_dir}/${_t}"
  done
}

# stub <имя каталога> <утилита> <строка тела>…: заглушка утилиты в каталоге команд.
stub() {
  local _file="${_root}/$1/$2"
  shift 2
  printf '%s\n' '#!/usr/bin/env bash' "$@" >"${_file}"
  chmod +x "${_file}"
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
# Дополнительные переменные окружения шаблона (STATUSLINE_NOW, NO_COLOR, USER…).
_extra=()
# run <каталог bin> <TMUX | -> <TMUX_PANE | -> [nowait]: вывод, stderr, код,
# длительность (мс); затем ждёт фоновый мост — запись заглушки в журнал.
# nowait — не ждать: вектор вне tmux, где журнал моста не проверяется.
run() {
  local _bin="${_root}/$1" _t0 _t1 _i
  local -a _env=(env -i "PATH=${_bin}" "HOME=${_root}" "GIT_CEILING_DIRECTORIES=${_root}")
  [[ "$2" != "-" ]] && _env+=("TMUX=$2")
  [[ "$3" != "-" ]] && _env+=("TMUX_PANE=$3")
  _env+=(${_extra[@]+"${_extra[@]}"})
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

# --- отсчёт до сброса, темп, кэш промпта ---------------------------------------
# Часы подменены: STATUSLINE_NOW. Времена в фикстурах — смещения от _now.
_now=1800000000
_extra=("STATUSLINE_NOW=${_now}")
_x=$'\xc3\x97'
_dot=$'\xc2\xb7'
_m="\"model\":{\"display_name\":\"M\"},\"workspace\":{\"current_dir\":\"${_work}\"}"

# win5 <процент> <время сброса, JSON>: окно пяти часов.
win5() { printf '"five_hour":{"used_percentage":%s,"resets_at":%s}' "$1" "$2"; }
win7() { printf '"seven_day":{"used_percentage":%s,"resets_at":%s}' "$1" "$2"; }

# Отсчёт: округление вниз, только будущее время и не дальше окна плюс час.
# reset_check <смещение от _now | JSON> <ожидаемый отсчёт | пусто>
reset_check() {
  local _r="$1" _exp=""
  [[ "${_r}" =~ ^-?[0-9]+$ ]] && _r=$((_now + _r))
  [[ -n "$2" ]] && _exp=" (resets in $2)"
  tail_check "отсчёт: сброс $1" "{${_m},\"rate_limits\":{$(win5 10 "${_r}")}}" "M | 5h 10%${_exp}"
}
reset_check 8940 2h29m
reset_check 8999 2h29m
reset_check 3600 1h00m
reset_check 4199 1h09m
reset_check 4200 1h10m
reset_check 3599 59m
reset_check 60 1m
reset_check 59 '<1m'
reset_check 1 '<1m'
reset_check 0 ''
reset_check -5 ''
reset_check 21600 6h00m
reset_check 21601 ''
reset_check "$((_now + 8940)).9" 2h29m
reset_check '"1800008940"' ''
reset_check null ''
reset_check '[1800008940]' ''
reset_check 1e19 ''
tail_check 'отсчёт: у недели его нет' "{${_m},\"rate_limits\":{$(win7 10 $((_now + 300000)))}}" 'M | 7d 10%'
tail_check 'отсчёт: процента нет — сегмента нет' \
  "{${_m},\"rate_limits\":{\"five_hour\":{\"resets_at\":$((_now + 8940))}}}" 'M'

# Темп: средний с начала окна; от 1.0, не раньше 5% окна; с темпом сегмент жёлтый.
# 53% за 40 минут пятичасового окна — 3.975; 61% за 304800 с недели — 1.21.
tail_check 'темп: оба окна' \
  "{${_m},\"rate_limits\":{$(win5 53 $((_now + 15600))),$(win7 61 $((_now + 300000)))}}" \
  "M | ${_y}5h 53% 4.0${_x}${_z} (resets in 4h20m) | ${_y}7d 61% 1.2${_x}${_z}"
tail_check 'темп: ниже 1.0 не выводится' \
  "{${_m},\"rate_limits\":{$(win5 37 $((_now + 8940))),$(win7 30 $((_now + 300000)))}}" \
  'M | 5h 37% (resets in 2h29m) | 7d 30%'
# Порог — до округления: половина окна и 49.9% — темп 0.998, не выводится; 50% — 1.0.
tail_check 'темп: 0.998 не выводится' "{${_m},\"rate_limits\":{$(win5 49.9 $((_now + 9000)))}}" \
  'M | 5h 50% (resets in 2h30m)'
tail_check 'темп: ровно 1.0' "{${_m},\"rate_limits\":{$(win5 50 $((_now + 9000)))}}" \
  "M | ${_y}5h 50% 1.0${_x}${_z} (resets in 2h30m)"
tail_check 'темп: 1.04 — 1.0' "{${_m},\"rate_limits\":{$(win5 52 $((_now + 9000)))}}" \
  "M | ${_y}5h 52% 1.0${_x}${_z} (resets in 2h30m)"
tail_check 'темп: 1.06 — 1.1' "{${_m},\"rate_limits\":{$(win5 53 $((_now + 9000)))}}" \
  "M | ${_y}5h 53% 1.1${_x}${_z} (resets in 2h30m)"
# Граница 5% окна: 900 с от начала — темп есть, 899 с — нет.
tail_check 'темп: ровно 5% окна' "{${_m},\"rate_limits\":{$(win5 30 $((_now + 17100)))}}" \
  "M | ${_y}5h 30% 6.0${_x}${_z} (resets in 4h45m)"
tail_check 'темп: раньше 5% окна' "{${_m},\"rate_limits\":{$(win5 30 $((_now + 17101)))}}" \
  'M | 5h 30% (resets in 4h45m)'
# Неделя: 5% — 30240 с.
tail_check 'темп: неделя, ровно 5% окна' "{${_m},\"rate_limits\":{$(win7 10 $((_now + 574560)))}}" \
  "M | ${_y}7d 10% 2.0${_x}${_z}"
tail_check 'темп: неделя, раньше 5% окна' "{${_m},\"rate_limits\":{$(win7 10 $((_now + 574561)))}}" \
  'M | 7d 10%'
# От 10 — целое: за 1800 с 99.4% — 9.94 (9.9), 99.6% — 9.96 (10), 85% за 900 с — 17.
tail_check 'темп: 9.9' "{${_m},\"rate_limits\":{$(win5 99.4 $((_now + 16200)))}}" \
  "M | ${_r}5h 99% 9.9${_x}${_z} (resets in 4h30m)"
tail_check 'темп: 10 — целое' "{${_m},\"rate_limits\":{$(win5 99.6 $((_now + 16200)))}}" \
  "M | ${_r}5h 100% 10${_x}${_z} (resets in 4h30m)"
tail_check 'темп: красный важнее жёлтого' "{${_m},\"rate_limits\":{$(win5 85 $((_now + 17100)))}}" \
  "M | ${_r}5h 85% 17${_x}${_z} (resets in 4h45m)"
tail_check 'темп: предел' "{${_m},\"rate_limits\":{$(win5 999 $((_now + 17100)))}}" \
  "M | ${_r}5h 999% 200${_x}${_z} (resets in 4h45m)"
tail_check 'темп: времени сброса нет' "{${_m},\"rate_limits\":{\"five_hour\":{\"used_percentage\":99}}}" \
  "M | ${_r}5h 99%${_z}"
tail_check 'темп: время сброса прошло' "{${_m},\"rate_limits\":{$(win5 99 $((_now - 1)))}}" "M | ${_r}5h 99%${_z}"
tail_check 'темп: сброс дальше длины окна — до начала окна темпа нет' "{${_m},\"rate_limits\":{$(win5 50 $((_now + 18001)))}}" \
  'M | 5h 50% (resets in 5h00m)'

# Кэш промпта. cache_check <описание> <объект prompt_cache, JSON> <ожидаемый сегмент | пусто>
cache_check() {
  local _exp=""
  [[ -n "$3" ]] && _exp=" | $3"
  tail_check "кэш: $1" "{${_m},\"context_window\":{\"used_percentage\":7},\"prompt_cache\":$2}" "M | Context 7%${_exp}"
}
# pc <смещение expires_at от _now> [ttl] [прочие поля]
pc() { printf '{"caching_observed":true,"ttl":"%s","expires_at":%s%s}' "${2:-1h}" "$((_now + $1))" "${3:-}"; }
_re=',"recache_tokens_if_cold":151000'
cache_check 'тёплый' "$(pc 1860 1h "${_re}")" 'cache warm 31m'
cache_check 'тёплый, меньше минуты до границы' "$(pc 601)" 'cache warm 10m'
cache_check 'истекает с шестой части TTL' "$(pc 600)" "${_y}cache warm 10m${_z}"
cache_check 'истекает, меньше минуты' "$(pc 1)" "${_y}cache warm <1m${_z}"
cache_check 'остаток не больше TTL' "$(pc 99999)" 'cache warm 1h00m'
cache_check 'TTL не назван — час' '{"caching_observed":true,"expires_at":'"$((_now + 99999))"'}' 'cache warm 1h00m'
cache_check 'TTL неизвестен — час' "$(pc 601 2h)" 'cache warm 10m'
cache_check '5m: тёплый' "$(pc 61 5m)" 'cache warm 1m (5m ttl)'
cache_check '5m: истекает с минуты' "$(pc 60 5m)" "${_y}cache warm 1m${_z} (5m ttl)"
cache_check '5m: остаток не больше TTL' "$(pc 99999 5m)" 'cache warm 5m (5m ttl)'
cache_check 'истёк' "$(pc 0 1h "${_re}")" "cache cold ${_dot} 151k"
cache_check 'истёк давно' "$(pc -99999 5m "${_re}")" "cache cold ${_dot} 151k"
cache_check 'истёк, объём неизвестен' "$(pc -5 1h ',"recache_tokens_if_cold":null')" 'cache cold'
cache_check 'объём 999' "$(pc -5 1h ',"recache_tokens_if_cold":999')" "cache cold ${_dot} 999"
cache_check 'объём 1000' "$(pc -5 1h ',"recache_tokens_if_cold":1000')" "cache cold ${_dot} 1k"
cache_check 'объём 1499' "$(pc -5 1h ',"recache_tokens_if_cold":1499')" "cache cold ${_dot} 1k"
cache_check 'объём 1500' "$(pc -5 1h ',"recache_tokens_if_cold":1500')" "cache cold ${_dot} 2k"
cache_check 'объём 0' "$(pc -5 1h ',"recache_tokens_if_cold":0')" 'cache cold'
cache_check 'объём огромный' "$(pc -5 1h ',"recache_tokens_if_cold":1e9')" 'cache cold'
cache_check 'объём — строка' "$(pc -5 1h ',"recache_tokens_if_cold":"7; x"')" 'cache cold'
cache_check 'объём дробный — вниз' "$(pc -5 1h ',"recache_tokens_if_cold":999.6')" "cache cold ${_dot} 999"
cache_check 'expires_at ноль' '{"caching_observed":true,"expires_at":0}' ''
cache_check 'время истечения дробное' '{"caching_observed":true,"ttl":"1h","expires_at":'"$((_now + 1860))"'.9}' 'cache warm 31m'
# warm: false — Claude Code сам считает кэш не тёплым: холодный с объёмом.
cache_check 'warm false при будущем времени' "$(pc 1860 1h "${_re}"',"warm":false')" "cache cold ${_dot} 151k"
cache_check 'warm true' "$(pc 1860 1h "${_re}"',"warm":true')" 'cache warm 31m'
cache_check 'warm не булево' "$(pc 1860 1h "${_re}"',"warm":"false"')" 'cache warm 31m'
# Компакция важнее «истекает»: объём null в последней шестой части срока — холодный.
cache_check 'после компакции, истекающий' "$(pc 300 1h ',"recache_tokens_if_cold":null')" 'cache cold'
cache_check 'после компакции, 5m' "$(pc 200 5m ',"recache_tokens_if_cold":null')" 'cache cold'
cache_check 'expires_at null, кэш наблюдался' '{"caching_observed":true,"expires_at":null,"recache_tokens_if_cold":45000}' \
  "cache cold ${_dot} 45k"
cache_check 'expires_at нет, кэш наблюдался' '{"caching_observed":true}' 'cache cold'
cache_check 'кэширование не наблюдалось' '{"caching_observed":false,"expires_at":null}' ''
cache_check 'caching_observed нет' '{"expires_at":null}' ''
# Кэширование не наблюдалось — сегмента нет и при числовом времени истечения;
# признака нет вовсе — время истечения показывается.
cache_check 'кэширование не наблюдалось, время в будущем' '{"caching_observed":false,"ttl":"1h","expires_at":'"$((_now + 1860))"'}' ''
cache_check 'кэширование не наблюдалось, время в прошлом' '{"caching_observed":false,"expires_at":'"$((_now - 5))"',"recache_tokens_if_cold":900}' ''
cache_check 'caching_observed нет, время в будущем' '{"ttl":"1h","expires_at":'"$((_now + 1860))"'}' 'cache warm 31m'
cache_check 'пустой объект' '{}' ''
cache_check 'expires_at — строка' '{"caching_observed":true,"expires_at":"1800001860"}' ''
cache_check 'expires_at отрицательный' '{"caching_observed":true,"expires_at":-1}' ''
cache_check 'expires_at огромный' '{"caching_observed":true,"expires_at":1e19}' ''
cache_check 'prompt_cache — строка' '"warm"' ''
cache_check 'prompt_cache — массив' '[1]' ''
cache_check 'prompt_cache — null' null ''

# Всё вместе: порядок сегментов, поля не сдвинуты, папка на месте.
head_check 'всё вместе' \
  "{${_m},\"effort\":{\"level\":\"high\"},\"context_window\":{\"used_percentage\":42.4},\"rate_limits\":{$(win5 53 $((_now + 15600))),$(win7 61 $((_now + 300000)))},\"prompt_cache\":$(pc 200 5m)}" \
  "${_home}/work" \
  "M ${_sep} high | Context 42% | ${_y}5h 53% 4.0${_x}${_z} (resets in 4h20m) | ${_y}7d 61% 1.2${_x}${_z} | cache warm 3m (5m ttl)"
# Мост в tmux от новых полей не зависит.
run ok "${_T}" %7
check 'всё вместе: в опцию идёт контекст' "$([[ "$(cat "${_log}")" == *'[set -p -t %7 @claude_ctx 42]'* ]] && echo да)" да

# STATUSLINE_NOW не из цифр — берутся настоящие часы (сброс через 2 ч 30 мин 30 с).
for _v in abc '1;x' '' 1234567890123; do
  _extra=("STATUSLINE_NOW=${_v}")
  tail_check "STATUSLINE_NOW=[${_v}]: настоящие часы" \
    "{${_m},\"rate_limits\":{$(win5 10 $(($(date +%s) + 9030)))}}" 'M | 5h 10% (resets in 2h30m)'
done

_extra=("STATUSLINE_NOW=${_now}")
cache_check 'после компакции' "$(pc 1860 1h ',"recache_tokens_if_cold":null')" 'cache cold'

# --- смена модели не определяется; файлов скрипт не создаёт ------------------------
# Идентификаторы сессии и модели на сегмент не влияют: после /model Claude Code
# передаёт прежний тёплый кэш, и строка показывает его как есть.
_k=',"recache_tokens_if_cold":56209'
for _v in claude-haiku-5-5 claude-sonnet-5-5; do
  tail_check "модель ${_v}: кэш как в данных" \
    "{\"session_id\":\"A\",\"model\":{\"id\":\"${_v}\",\"display_name\":\"M\"},\"workspace\":{\"current_dir\":\"${_work}\"},\"prompt_cache\":$(pc 1800 1h "${_k}")}" \
    'M | cache warm 30m'
done
check 'файлов в HOME не создано' "$([[ -e "${_root}/.cache" || -e "${_root}/.config" || -e "${_root}/.local" ]] && echo есть)" ''
_extra=("STATUSLINE_NOW=${_now}" "XDG_CACHE_HOME=${_root}/xdg")
run ok - - nowait
check 'XDG_CACHE_HOME не используется' "$([[ -e "${_root}/xdg" ]] && echo есть)" ''

# --- NO_COLOR --------------------------------------------------------------------
_all="{${_m},\"context_window\":{\"used_percentage\":85},\"rate_limits\":{$(win5 53 $((_now + 15600)))},\"prompt_cache\":$(pc 30)}"
_extra=("STATUSLINE_NOW=${_now}" NO_COLOR=1 USER=alice HOSTNAME=box)
fixture_raw "${_all}"
run ok - - nowait
check 'NO_COLOR: вывод без ANSI' "${_out}" \
  "alice@box:~/work | M | Context 85% | 5h 53% 4.0${_x} (resets in 4h20m) | cache warm <1m"
_extra=("STATUSLINE_NOW=${_now}" NO_COLOR=)
tail_check 'NO_COLOR пуст: цвета есть' "${_all}" \
  "M | ${_r}Context 85%${_z} | ${_y}5h 53% 4.0${_x}${_z} (resets in 4h20m) | ${_y}cache warm <1m${_z}"

# --- имя и хост: из переменных, без процессов ------------------------------------
# Каталог без whoami и hostname: с USER шаблон их не запускает.
link_tools nowho bash cat jq git
_extra=(USER=alice HOSTNAME=box.example.org)
fixture -
run nowho - - nowait
check 'USER и HOSTNAME: имя и короткий хост' "${_out%%:*}" $'\033[01;32m'"alice@box${_z}"
check 'USER и HOSTNAME: код возврата' "${_rc}" 0
check 'USER и HOSTNAME: stderr пуст' "${_err}" ''
# USER пуст или не задан — whoami.
for _v in USER= HOSTNAME=box; do
  _extra=("${_v}" HOSTNAME=box)
  run ok - - nowait
  check "${_v}: имя из whoami" "${_out%%:*}" $'\033[01;32m'"$(env -i "PATH=${_root}/ok" whoami)@box${_z}"
  check "${_v}: код возврата" "${_rc}" 0
done
# Сбой whoami или hostname (нет записи о пользователе, нет утилиты) — пустое
# имя, строка статуса цела.
link_tools whofail bash cat jq git
stub whofail whoami 'echo oops' 'echo "cannot find name" >&2' 'exit 1'
stub whofail hostname 'echo oops' 'echo "no hostname" >&2' 'exit 1'
_g=$'\033[01;32m'
_extra=(HOSTNAME=box)
run whofail - - nowait
check 'сбой whoami: имя пусто, строка цела' "${_out}" "${_g}@box${_z}:"$'\033[01;34m'"~/work${_z} | M"
check 'сбой whoami: код возврата' "${_rc}" 0
check 'сбой whoami: stderr пуст' "${_err}" ''
_extra=(USER=alice HOSTNAME=)
run whofail - - nowait
check 'сбой hostname: хост пуст, строка цела' "${_out%%:*}" "${_g}alice@${_z}"
check 'сбой hostname: код возврата' "${_rc}" 0
check 'сбой hostname: stderr пуст' "${_err}" ''
run nowho - - nowait
check 'нет hostname: хост пуст, строка цела' "${_out%%:*}" "${_g}alice@${_z}"
check 'нет hostname: код возврата' "${_rc}" 0
check 'нет hostname: stderr пуст' "${_err}" ''
_extra=(HOSTNAME=box)
run nowho - - nowait
check 'нет whoami: имя пусто, строка цела' "${_out%%:*}" "${_g}@box${_z}"
check 'нет whoami: код возврата' "${_rc}" 0
check 'нет whoami: stderr пуст' "${_err}" ''
# HOSTNAME пуст, hostname работает — короткое имя от утилиты.
stub whofail hostname 'echo "host.example.org"'
_extra=(USER=alice HOSTNAME=)
run whofail - - nowait
check 'HOSTNAME пуст: короткий хост от hostname' "${_out%%:*}" "${_g}alice@host${_z}"
# Значения окружения — в терминал только очищенными: управляющие символы C0 и
# C1, перевод строки и смена направления письма убраны, прочий юникод цел.
_extra=("USER=ro"$'\033'"[2Jot"$'\n'"X"$'\302\233'"1"$'\342\200\256'"жук" "HOSTNAME=h"$'\033'"]0;pwn"$'\a'"x"$'\342\201\246'"é.example")
run nowho - - nowait
check 'имя и хост очищены' "${_out%%:*}" "${_g}ro[2JotX1жук@h]0;pwnxé${_z}"
check 'имя и хост очищены: вывод в одну строку' "$(printf '%s\n' "${_out}" | grep -c '')" 1
# Края каждого диапазона clean: первый и последний символ убираются, соседние
# снаружи остаются. clean_check <описание> <значение USER> <ожидаемое имя>
clean_check() {
  _extra=("USER=$2" HOSTNAME=h)
  run nowho - - nowait
  check "очистка: $1" "${_out%%:*}" "${_g}$3@h${_z}"
}
clean_check 'C0: U+0001 и U+001F' "a"$'\001'"b"$'\037'"c d" 'abc d'
clean_check 'DEL' "a"$'\177'"b~" 'ab~'
clean_check 'C1: U+0080 и U+009F' "a"$'\302\200'"b"$'\302\237'"c" 'abc'
clean_check 'рядом с C1: U+00A0 остаётся' "a"$'\302\240'"b" "a"$'\302\240'"b"
clean_check 'U+061C' "a"$'\330\234'"b"$'\330\233'"c" "ab"$'\330\233'"c"
clean_check 'U+200B и U+200F' "a"$'\342\200\213'"b"$'\342\200\217'"c" 'abc'
clean_check 'рядом: U+200A и U+2010 остаются' "a"$'\342\200\212'"b"$'\342\200\220'"c" "a"$'\342\200\212'"b"$'\342\200\220'"c"
clean_check 'U+2028 и U+202E' "a"$'\342\200\250'"b"$'\342\200\256'"c" 'abc'
clean_check 'рядом: U+2027 и U+202F остаются' "a"$'\342\200\247'"b"$'\342\200\257'"c" "a"$'\342\200\247'"b"$'\342\200\257'"c"
clean_check 'U+2060 и U+206F' "a"$'\342\201\240'"b"$'\342\201\257'"c" 'abc'
clean_check 'рядом: U+205F и U+2070 остаются' "a"$'\342\201\237'"b"$'\342\201\260'"c" "a"$'\342\201\237'"b"$'\342\201\260'"c"
clean_check 'U+FEFF' "a"$'\357\273\277'"b"$'\357\273\276'"c" "ab"$'\357\273\276'"c"
clean_check 'теги U+E0000 и U+E007F' "a"$'\363\240\200\200'"b"$'\363\240\201\277'"c" 'abc'
clean_check 'рядом с тегами: U+E0080 остаётся' "a"$'\363\240\202\200'"b" "a"$'\363\240\202\200'"b"
# Склейка: внутри пары C1 спрятана другая запрещённая последовательность — после
# её удаления остаток не должен сложиться в U+009B.
clean_check 'вложенная вставка: U+2028 внутри C1' "x"$'\302\342\200\250\233'"2J" 'x2J'
clean_check 'вложенная вставка: U+2066 внутри U+202E' "x"$'\342\200\342\201\246\256'"y" 'xy'
clean_check 'вложенная вставка: трижды' "x"$'\302\342\200\342\201\246\250\233'"y" 'xy'
clean_check 'вложенная вставка: BEL внутри C1' "x"$'\302\a\233'"y" 'xy'
# Предел проходов: семь уровней вложенности ещё чистятся, восемь — значение
# отбрасывается целиком; время на враждебном значении ограничено.
# nested <глубина>: C1-пара, в которую глубина раз вложена та же пара.
nested() {
  local _i _head="" _tail=""
  for ((_i = 0; _i < $1; _i++)); do
    _head+=$'\302'
    _tail+=$'\233'
  done
  printf '%s%s' "${_head}" "${_tail}"
}
clean_check 'вложенность 7 — очищено' "a$(nested 7)b" 'ab'
clean_check 'вложенность 8 — значение отброшено' "a$(nested 8)b" ''
clean_check 'враждебное значение 16 КБ — отброшено' "a$(nested 8000)b" ''
check "враждебное значение 16 КБ: скрипт не ждёт (${_ms} мс)" "$((_ms < 1500 ? 1 : 0))" 1
# То же в UTF-8-локалях машины и в режиме диапазонов по порядку сортировки (так
# работал bash до 5.0): очистка идёт по байтам и от локали не зависит.
# Грязные имя, хост и ветка разом; репозиторий с грязной веткой — свой.
_dirty="ro"$'\033'"[2Jot"$'\n'"X"$'\302\233'"1"$'\342\200\256'"жук"
_dirty_host="h"$'\033'"]0;pwn"$'\a'"x"$'\342\201\246'"é"
_lrepo="${_root}/locrepo"
mkdir -p "${_lrepo}"
env -i "PATH=${_root}/ok" "HOME=${_root}" git -C "${_lrepo}" init -q -b trunk >/dev/null 2>&1
env -i "PATH=${_root}/ok" "HOME=${_root}" git -C "${_lrepo}" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init >/dev/null 2>&1
env -i "PATH=${_root}/ok" "HOME=${_root}" git -C "${_lrepo}" checkout -q -b "x"$'\302\233'"31mY"$'\342\200\256'"Zжук" >/dev/null 2>&1
jq -n --arg d "${_lrepo}" '{model:{display_name:"M"},workspace:{current_dir:$d}}' >"${_fx}"
_locs="$(locale -a 2>/dev/null | grep -i -E '^(C|en_US|ru_RU)\.utf-?8$')"
_opts=(-O)
if bash +O globasciiranges -c : 2>/dev/null; then
  _opts+=(+O)
else
  printf 'ПРОПУСК: у bash нет опции globasciiranges — режим диапазонов по сортировке не проверен\n'
fi
if [[ -z "${_locs}" ]]; then
  printf 'ПРОПУСК: на машине нет UTF-8-локалей (C, en_US, ru_RU) — очистка в локалях не проверена\n'
fi
for _loc in ${_locs}; do
  for _opt in "${_opts[@]}"; do
    _o="$(env -i "PATH=${_root}/ok" "HOME=${_root}" "USER=${_dirty}" "HOSTNAME=${_dirty_host}" "LC_ALL=${_loc}" \
      bash "${_opt}" globasciiranges "${_tpl}" <"${_fx}" 2>&1)"
    check "очистка в локали ${_loc}, ${_opt} globasciiranges: имя и хост" "${_o%%:*}" "${_g}ro[2JotX1жук@h]0;pwnxé${_z}"
    check "очистка в локали ${_loc}, ${_opt} globasciiranges: ветка" "${_o##* | }" $'\xee\x82\xa0 x31mYZжук'
    check "очистка в локали ${_loc}, ${_opt} globasciiranges: одна строка" "$(printf '%s\n' "${_o}" | grep -c '')" 1
  done
done
# Папка и название модели — тот же набор (shown в jq).
_hid=$'\330\234\342\200\213\342\200\217\342\200\250\342\200\256\342\201\240\342\201\246\342\201\257\357\273\277\363\240\200\201'
jq -n --arg d "/nodir/a${_hid}b"$'\302\240'"c" --arg m "Op${_hid}us"$'\342\200\220'"X" '{model:{display_name:$m},cwd:$d}' >"${_fx}"
_extra=()
run ok - - nowait
check 'папка: невидимые знаки убраны' "${_out%% | *}" "${_out%%:*}:"$'\033[01;34m'"/nodir/ab"$'\302\240'"c${_z}"
check 'модель: невидимые знаки убраны' "${_out#* | }" "Opus"$'\342\200\220'"X"
# Только невидимые знаки: модель — «?», папка показывается пустой.
jq -n --arg d "${_hid}" --arg m "${_hid}" '{model:{display_name:$m},cwd:$d}' >"${_fx}"
run ok - - nowait
check 'папка из одних невидимых знаков — пусто' "${_out%% | *}" "${_out%%:*}:"$'\033[01;34m'"${_z}"
check 'модель из одних невидимых знаков — «?»' "${_out#* | }" '?'
_extra=()

# --- git: один вызов; репозиторий без коммитов — ветки нет -------------------------
link_tools gitlog bash cat jq whoami hostname
stub gitlog git "echo git >>\"${_root}/git.calls\"" "exec \"$(command -v git)\" \"\$@\""
: >"${_root}/git.calls"
jq -n --arg d "${_repo}" '{model:{display_name:"M"},workspace:{current_dir:$d}}' >"${_fx}"
run gitlog - - nowait
check 'git: ветка найдена' "${_out#* | }" $'M | \xee\x82\xa0 trunk'
check 'git: один вызов' "$(grep -c '' "${_root}/git.calls")" 1
_empty="${_root}/empty"
mkdir -p "${_empty}"
env -i "PATH=${_root}/ok" "HOME=${_root}" git -C "${_empty}" init -q -b trunk >/dev/null 2>&1
jq -n --arg d "${_empty}" '{model:{display_name:"M"},workspace:{current_dir:$d}}' >"${_fx}"
run ok - - nowait
check 'репозиторий без коммитов: ветки нет' "${_out#* | }" 'M'
check 'репозиторий без коммитов: код возврата' "${_rc}" 0
check 'репозиторий без коммитов: stderr пуст' "${_err}" ''
# Имя ветки — из репозитория, который может быть чужим: в терминал очищенным.
_bad="x"$'\302\233'"31mY"$'\342\200\256'"Z"$'\342\201\247'"é"
env -i "PATH=${_root}/ok" "HOME=${_root}" git -C "${_repo}" checkout -q -b "${_bad}" >/dev/null 2>&1
jq -n --arg d "${_repo}" '{model:{display_name:"M"},workspace:{current_dir:$d}}' >"${_fx}"
run ok - - nowait
check 'имя ветки очищено' "${_out#* | }" $'M | \xee\x82\xa0 x31mYZé'

# --- узкий экран: ступени по COLUMNS ---------------------------------------------
# Уже 80 колонок ступень выбирается по видимой длине: каждая строка вывода
# помещается в «COLUMNS − 4» — она, иначе следующая (полная → средняя → сжатая
# → две строки; у средней, сжатой и двух строк следом пробуется та же ступень с
# веткой, укороченной до 20 знаков). Не поместилась ни одна — три строки, уже
# без проверки. От 80 колонок строка всегда полная.
_i=$'\xee\x82\xa0'
_e=$'\xe2\x80\xa6'
_b=$'\033[01;34m'
_nrepo="${_root}/w"
mkdir -p "${_nrepo}"
env -i "PATH=${_root}/ok" "HOME=${_root}" git -C "${_nrepo}" init -q -b main >/dev/null 2>&1
env -i "PATH=${_root}/ok" "HOME=${_root}" git -C "${_nrepo}" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init >/dev/null 2>&1

# nbranch <ветка>: переключить тестовый репозиторий на новую ветку; код
# возврата — как у git (вектор, которому ветка нужна, без неё не имеет смысла).
nbranch() {
  env -i "PATH=${_root}/ok" "HOME=${_root}" git -C "${_nrepo}" checkout -q -B "$1" >/dev/null 2>&1
}

# narrow_fixture <папка> [prompt_cache JSON] [процент 5h]: все сегменты разом —
# контекст, оба окна лимитов (у недели темп 1.2×), кэш.
narrow_fixture() {
  jq -n --arg d "$1" --argjson now "${_now}" --argjson pc "${2:-$(pc 1860 1h "${_re}")}" --argjson h "${3:-37}" '{
      model: {display_name: "Opus 5.5"}, effort: {level: "high"}, workspace: {current_dir: $d},
      context_window: {used_percentage: 42},
      rate_limits: {
        five_hour: {used_percentage: $h, resets_at: ($now + 8940)},
        seven_day: {used_percentage: 61, resets_at: ($now + 300000)}
      },
      prompt_cache: $pc
    }' >"${_fx}"
}

# small_fixture <папка> [процент контекста]: только модель, effort и контекст.
small_fixture() {
  jq -n --arg d "$1" --argjson c "${2:-42}" \
    '{model:{display_name:"Opus 5.5"},effort:{level:"high"},workspace:{current_dir:$d},context_window:{used_percentage:$c}}' >"${_fx}"
}

# narrow <COLUMNS | -> [переменные окружения…]: запуск с застывшими часами,
# именем u и хостом h; «-» — без COLUMNS.
narrow() {
  local _c="$1"
  shift
  _extra=("STATUSLINE_NOW=${_now}" USER=u HOSTNAME=h "$@")
  [[ "${_c}" != "-" ]] && _extra+=("COLUMNS=${_c}")
  run ok - - nowait
  _extra=()
}

# rep <строка> <число>: строка, повторённая заданное число раз.
rep() {
  local _k _s=""
  for ((_k = 0; _k < $2; _k++)); do
    _s+="$1"
  done
  printf '%s' "${_s}"
}

# vlen <строка>: число знаков самой длинной строки без цветов — по байтам, от
# локали теста не зависит.
vlen() {
  local LC_ALL=C _s="$1" _l _m=0
  _s="${_s//$'\033['[0-9][0-9]m/}"
  _s="${_s//$'\033['[0-9][0-9]';'[0-9][0-9]m/}"
  while :; do
    _l="${_s%%$'\n'*}"
    _l="${_l//[$'\200'-$'\277']/}"
    ((${#_l} > _m)) && _m=${#_l}
    [[ "${_s}" == *$'\n'* ]] || break
    _s="${_s#*$'\n'}"
  done
  printf '%s' "${_m}"
}

# out_check <описание> <ожидаемый вывод>: вывод целиком, код возврата, stderr.
out_check() {
  check "$1" "${_out}" "$2"
  check "$1: код возврата" "${_rc}" 0
  check "$1: stderr пуст" "${_err}" ''
}

# fits_check <описание> <вывод> <следующая попытка> [переменные окружения…]:
# вывод выбирается при ширине «длина самой длинной его строки + 4», а на знак
# уже — следующая попытка. _adj — сколько знаков вывода не имеют ширины (их
# vlen считает, а шаблон — нет).
_adj=0
fits_check() {
  local _d1="$1" _exp="$2" _next="$3" _n
  shift 3
  _n="$(($(vlen "${_exp}") - _adj))"
  narrow "$((_n + 4))" "$@"
  out_check "${_d1}: ширина $((_n + 4)) — помещается" "${_exp}"
  narrow "$((_n + 3))" "$@"
  out_check "${_d1}: ширина $((_n + 3)) — следующая попытка" "${_next}"
}

_lim="5h 37% 2h29m | 7d 61% 1.2${_x}"
_l1="Ctx 42% ${_dot} 5h 37% 2h29m"
_l2="7d 61% 1.2${_x}"
_nf="u@h:~/w | Opus 5.5 ${_sep} high | Context 42% | 5h 37% (resets in 2h29m) | 7d 61% 1.2${_x} | cache warm 31m | ${_i} main"
# shellcheck disable=SC2088 # «~» — текст строки статуса, а не путь
_nm="~/w | Opus 5.5 | Ctx 42% | ${_lim} | cache 31m | ${_i} main"
_nc="${_l1} ${_dot} ${_l2} ${_dot} cache 31m ${_dot} ${_i} main"
_nt="${_l1} ${_dot} ${_l2}"$'\n'"cache 31m ${_dot} ${_i} main"
_n3="${_l1}"$'\n'"${_l2}"$'\n'"cache 31m ${_dot} ${_i} main"
narrow_fixture "${_nrepo}"
narrow - NO_COLOR=1
out_check 'без COLUMNS: полная строка' "${_nf}"
# Порог узкого экрана: от 80 колонок — полная строка, хотя она не помещается.
for _v in 80 81 110 200 9999; do
  narrow "${_v}" NO_COLOR=1
  check "ширина ${_v}: полная строка" "${_out}" "${_nf}"
done
narrow 79 NO_COLOR=1
check 'ширина 79: средняя строка' "${_out}" "${_nm}"
fits_check 'средняя' "${_nm}" "${_nc}" NO_COLOR=1
fits_check 'сжатая' "${_nc}" "${_nt}" NO_COLOR=1
fits_check 'две строки' "${_nt}" "${_n3}" NO_COLOR=1
# Три строки — последняя ступень, выводится и когда не помещается.
narrow 20 NO_COLOR=1
out_check 'ширина 20: три строки' "${_n3}"

# COLUMNS не число из 1–4 цифр или меньше 20 — полная строка, без ошибок.
# 18446744073709551650 — 2^64 + 34: без потолка длины арифметика bash дала бы 34.
_nl=$'60\n60'
for _v in '' abc 0 19 0019 12345 18446744073709551650 ' 60' '60 ' -5 +60 1e1 '60;x' '6 0' "${_nl}"; do
  narrow "${_v}" NO_COLOR=1
  out_check "COLUMNS=[${_v}]: полная строка" "${_nf}"
done
# Цифры других письменностей — не число, в какой бы локали ни сверялся шаблон
# (диапазон 0-9 в en_US.UTF-8 их пропускает, а арифметика bash на них падает).
for _loc in ${_locs}; do
  for _v in $'\331\246\331\240' $'\357\274\226\357\274\220' $'\302\262\302\262'; do
    narrow "${_v}" NO_COLOR=1 "LC_ALL=${_loc}"
    out_check "COLUMNS=[${_v}] в локали ${_loc}: полная строка" "${_nf}"
  done
done
# Ведущие нули — десятичное число, а не восьмеричное («079» в $(( )) — ошибка).
for _v in 79 0079; do
  narrow "${_v}" NO_COLOR=1
  out_check "COLUMNS=${_v}: средняя строка" "${_nm}"
done
narrow 0020 NO_COLOR=1
check 'COLUMNS=0020: три строки' "${_out}" "${_n3}"

# Мост в tmux от ступени не зависит: вызов один и тот же на средней (ширина
# 79), сжатой (61), в двух строках (40) и в трёх (30).
_bridge="timeout [-s] [KILL] [1] [tmux] [if] [-F] [-t] [%7] [${_cond_pre}#{!=:#{@claude_ctx},42},0}] [set -p -t %7 @claude_ctx 42] ${_null}"
for _v in "79:${_nm}" "61:${_nc}" "40:${_nt}" "30:${_n3}"; do
  _extra=("STATUSLINE_NOW=${_now}" USER=u HOSTNAME=h NO_COLOR=1 "COLUMNS=${_v%%:*}")
  run ok "${_T}" %7
  _extra=()
  check "узкий экран в tmux, ширина ${_v%%:*}: вывод" "${_out}" "${_v#*:}"
  check "узкий экран в tmux, ширина ${_v%%:*}: вызов моста" "$(cat "${_log}")" "${_bridge}"
done

# Кириллица в папке: знаки, а не байты.
_cyr="${_root}/папка-проекта"
mkdir -p "${_cyr}"
small_fixture "${_cyr}"
# shellcheck disable=SC2088 # «~» — текст строки статуса, а не путь
fits_check 'кириллица в папке, средняя' "~/папка-проекта | Opus 5.5 | Ctx 42%" 'Ctx 42%' NO_COLOR=1
narrow_fixture "${_nrepo}"

# Цвета в длину не входят: на границе с цветами выбирается та же ступень, что
# без них, — для каждого цвета (зелёный и синий — полная строка, красный —
# процент от 80, жёлтый — темп).
small_fixture "${_nrepo}"
fits_check 'цвета, полная: зелёный и синий' \
  "${_g}u@h${_z}:${_b}~/w${_z} | Opus 5.5 ${_sep} high | Context 42% | ${_i} main" \
  "${_b}~/w${_z} | Opus 5.5 | Ctx 42% | ${_i} main"
small_fixture "${_nrepo}" 85
fits_check 'цвета, средняя: красный' \
  "${_b}~/w${_z} | Opus 5.5 | ${_r}Ctx 85%${_z} | ${_i} main" "${_r}Ctx 85%${_z} ${_dot} ${_i} main"
narrow_fixture "${_nrepo}"
fits_check 'цвета, средняя: жёлтый' \
  "${_b}~/w${_z} | Opus 5.5 | Ctx 42% | 5h 37% 2h29m | ${_y}${_l2}${_z} | cache 31m | ${_i} main" \
  "${_l1} ${_dot} ${_y}${_l2}${_z} ${_dot} cache 31m ${_dot} ${_i} main"
# Отсчёт на ступенях после полной — без слов и при проценте от 80 (красный).
narrow_fixture "${_nrepo}" '{"caching_observed":false}' 85
narrow 79 NO_COLOR=1
# shellcheck disable=SC2088 # «~» — текст строки статуса, а не путь
out_check 'средняя, 5h 85%: отсчёт без слов' "~/w | Opus 5.5 | Ctx 42% | 5h 85% 1.7${_x} 2h29m | ${_l2} | ${_i} main"

# Длинная ветка: на ступенях после полной следом пробуется та же ступень с
# укороченной веткой. Сегментов мало (только контекст) — иначе уже 80 колонок
# полная и средняя строки с такой веткой не помещаются.
_long='feat/statusline-narrow-screens'
_short="feat/statusline-nar${_e}"
nbranch "${_long}"
check 'тестовая ветка создана' "$?" 0
small_fixture "${_nrepo}"
_lf="u@h:~/w | Opus 5.5 ${_sep} high | Context 42% | ${_i} ${_long}"
# shellcheck disable=SC2088 # «~» — текст строки статуса, а не путь
_lm="~/w | Opus 5.5 | Ctx 42% | ${_i} ${_long}"
_lms="${_lm%"${_long}"}${_short}"
_lc="Ctx 42% ${_dot} ${_i} ${_long}"
_lcs="Ctx 42% ${_dot} ${_i} ${_short}"
_lts="Ctx 42%"$'\n'"${_i} ${_short}"
fits_check 'длинная ветка, полная' "${_lf}" "${_lm}" NO_COLOR=1
fits_check 'длинная ветка, средняя' "${_lm}" "${_lms}" NO_COLOR=1
fits_check 'длинная ветка, средняя с укороченной' "${_lms}" "${_lc}" NO_COLOR=1
fits_check 'длинная ветка, сжатая' "${_lc}" "${_lcs}" NO_COLOR=1
fits_check 'длинная ветка, сжатая с укороченной' "${_lcs}" "${_lts}" NO_COLOR=1
# Две строки: сначала с полной веткой, с укороченной — когда полная не помещается.
narrow_fixture "${_nrepo}"
_ltf="${_l1} ${_dot} ${_l2}"$'\n'"cache 31m ${_dot} ${_i} ${_long}"
_lt="${_l1} ${_dot} ${_l2}"$'\n'"cache 31m ${_dot} ${_i} ${_short}"
fits_check 'длинная ветка, сжатая с укороченной и лимитами' \
  "${_l1} ${_dot} ${_l2} ${_dot} cache 31m ${_dot} ${_i} ${_short}" "${_ltf}" NO_COLOR=1
fits_check 'длинная ветка, две строки' "${_ltf}" "${_lt}" NO_COLOR=1
fits_check 'длинная ветка, две строки с укороченной' "${_lt}" \
  "${_l1}"$'\n'"${_l2}"$'\n'"cache 31m ${_dot} ${_i} ${_short}" NO_COLOR=1

# Короткий вид ветки: до 20 видимых знаков — без изменений (кроме мягких
# переносов: они убираются всегда, векторы ниже), длиннее — 19 знаков и «…»
# (имя длиннее 120 байт — сколько знаков уместилось в 120 байт, и «…»); знаки,
# а не байты, в любой локали.
# branch_check <описание> <ветка> <ожидаемый вид> [переменные окружения…]
branch_check() {
  local _d1="$1" _br="$2" _exp="$3"
  shift 3
  if ! nbranch "${_br}"; then
    printf 'ПРОПУСК: %s — git не создал ветку с таким именем\n' "${_d1}"
    return 0
  fi
  narrow 20 NO_COLOR=1 "$@"
  check "${_d1}" "${_out##*"${_i} "}" "${_exp}"
  check "${_d1}: код возврата" "${_rc}" 0
  check "${_d1}: stderr пуст" "${_err}" ''
}
branch_check 'ветка 20 знаков — целиком' 'b234567890123456789z' 'b234567890123456789z'
branch_check 'ветка 21 знак — укорочена' 'c2345678901234567890z' "c234567890123456789${_e}"
branch_check 'ветка 20 знаков кириллицей — целиком' 'ветка-ветка-ветка-ве' 'ветка-ветка-ветка-ве'
branch_check 'ветка 23 знака кириллицей — укорочена' 'ветка-ветка-ветка-ветка' "ветка-ветка-ветка-в${_e}"
branch_check 'ветка смешанная — укорочена' 'fix/ошибка-в-разборе-даты' "fix/ошибка-в-разбор${_e}"
for _loc in ${_locs}; do
  branch_check "ветка кириллицей в локали ${_loc}" "ветка-ветка-ветка-${_loc}" \
    "ветка-ветка-ветка-${_loc:0:1}${_e}" "LC_ALL=${_loc}"
done
branch_check 'ветка 200 знаков — укорочена' "$(rep a 200)" "aaaaaaaaaaaaaaaaaaa${_e}"
# Мягкий перенос (U+00AD) и вариационный селектор (U+FE0F) из укороченной ветки
# убираются — цепочка невидимых знаков не вытеснит имя; комбинирующий знак
# (U+0306 — «й» в именах macOS; U+0345 — из второй половины диапазона, байт
# 0xCD) остаётся при своей букве и местом не считается, а U+0370 (тот же байт
# 0xCD, уже буква) считается.
_shy=$'\302\255'
_brv=$'\314\206'
_ypo=$'\315\205'
_heta=$'\315\260'
branch_check 'ветка: 19 мягких переносов перед именем — имя видно' \
  "$(rep "${_shy}" 19)evil-real-branch-name" "evil-real-branch-na${_e}"
# Вариационный селектор убирается, только когда имя приходится укорачивать:
# короткое имя с эмодзи сохраняет его и в трёх строках, а цепочка селекторов
# перед именем (больше 120 байт) имя не вытесняет.
_vs=$'\357\270\217'
branch_check 'ветка: короткое имя с эмодзи сохраняет селектор' \
  "fix/"$'\342\235\244'"${_vs}-bug" "fix/"$'\342\235\244'"${_vs}-bug"
branch_check 'ветка: шестьдесят селекторов перед именем — имя видно' "$(rep "${_vs}" 60)main" 'main'
branch_check 'ветка: вариационные селекторы не считаются' \
  "a"$'\357\270\217'"b"$'\357\270\217'"-234567890123456789z" "ab-2345678901234567${_e}"
branch_check 'ветка: 17 видимых знаков в NFD — целиком' \
  "feat/$(rep "и${_brv}" 12)" "feat/$(rep "и${_brv}" 12)"
branch_check 'ветка: 25 видимых знаков в NFD — 19 и многоточие' \
  "feat/$(rep "и${_brv}" 20)" "feat/$(rep "и${_brv}" 14)${_e}"
branch_check 'ветка: 25 букв с U+0345 — 19 букв и многоточие' \
  "$(rep "a${_ypo}" 25)" "$(rep "a${_ypo}" 19)${_e}"
branch_check 'ветка: 25 букв с U+0370 — знак считается' \
  "$(rep "a${_heta}" 25)" "$(rep "a${_heta}" 9)a${_e}"
# Вырезанные байты могли разделять половинки знака, который обязана убирать
# очистка: смена направления письма U+202E (E2 80 | AE) и управляющий C1 U+009B
# (C2 | 9B) после удаления мягкого переноса и селектора не собираются.
branch_check 'ветка: U+202E не собирается из половинок' \
  "featu"$'\342\200'"${_shy}"$'\256'"re-long-branch-xx" "feature-long-branch${_e}"
branch_check 'ветка: C1 CSI не собирается из половинок' \
  "featu"$'\302\357\270\217\233'"31mre-long-branch-xx" "featu31mre-long-bra${_e}"
# Предел 120 байт не рвёт знак: срез отступает до его начала — на один, два и
# три байта (знаки в два, три и четыре байта).
_acu=$'\314\201'
branch_check 'ветка: 141 байт комбинирующих — срез по границе знака' \
  "a$(rep "${_acu}" 70)" "a$(rep "${_acu}" 59)${_e}"
branch_check 'ветка: трёхбайтный знак на пределе — срез по границе знака' \
  "a$(rep "${_acu}" 58)b"$'\344\270\255'"$(rep x 30)" "a$(rep "${_acu}" 58)b${_e}"
branch_check 'ветка: четырёхбайтный знак на пределе — срез по границе знака' \
  "a$(rep "${_acu}" 58)"$'\360\237\230\200'"$(rep x 30)" "a$(rep "${_acu}" 58)${_e}"
# Очистка короткого вида не сошлась за восемь проходов (восемь вложенных
# половинок мягкого переноса) или не оставила ничего — вместо имени одно «…»,
# сырое значение не выводится; семь слоёв сходятся.
branch_check 'ветка: восемь слоёв мягкого переноса — только многоточие' \
  "$(rep $'\302' 8)$(rep $'\255' 8)-$(rep "${_shy}" 100)evil-real-name" "${_e}"
branch_check 'ветка: семь слоёв мягкого переноса — имя видно' \
  "$(rep $'\302' 7)$(rep $'\255' 7)-evil-real-name-long-enough" "-evil-real-name-lon${_e}"
branch_check 'ветка из одних мягких переносов — только многоточие' "$(rep "${_shy}" 30)" "${_e}"
# Одиночный байт 0xCC (имя не в UTF-8) и длина строки, и срез считают знаком
# (иначе короткий вид вышел бы вдвое длиннее); начальный байт, оставшийся перед
# «…» без продолжения, отбрасывается.
branch_check 'ветка: одиночные 0xCC считаются знаками' \
  "$(rep $'\314a' 25)" "$(rep $'\314a' 9)${_e}"
# Имя не в UTF-8: после отступа на три байта срез мог лечь между 0xCD и его
# продолжением — оставшийся одиночный 0xCD отбрасывается.
branch_check 'ветка: начальный байт без продолжения у предела — отброшен' \
  "$(rep $'\200' 97)$(rep x 19)"$'\315'"$(rep $'\217' 6)" "$(rep $'\200' 97)$(rep x 19)${_e}"
# Имя из одних знаков без ширины — как пустое: вместо него «…».
branch_check 'ветка из одних комбинирующих знаков — только многоточие' "$(rep "${_brv}" 2)" "${_e}"
# Ветка длиннее 255 байт на узком экране выводится только в коротком виде — и
# на ступени, где длинная строка «поместилась» бы по счёту (байты без ширины).
# Имя — из трёх компонентов: один компонент ссылки git не длиннее 255 байт.
small_fixture "${_nrepo}"
_bf="$(rep $'\277' 120)"
if nbranch "m${_bf}/${_bf}/$(rep x 18)"; then
  narrow 79 NO_COLOR=1
  out_check 'ветка 261 байт без ширины: короткий вид на полной ступени' \
    "u@h:~/w | Opus 5.5 ${_sep} high | Context 42% | ${_i} m$(rep $'\277' 116)${_e}"
else
  printf 'ПРОПУСК: ветка 261 байт без ширины — git не создал ветку с таким именем\n'
fi
if nbranch "m${_bf}/${_bf}/$(rep x 12)"; then
  narrow 79 NO_COLOR=1
  out_check 'ветка 255 байт без ширины: как есть' \
    "u@h:~/w | Opus 5.5 ${_sep} high | Context 42% | ${_i} m${_bf}/${_bf}/$(rep x 12)"
else
  printf 'ПРОПУСК: ветка 255 байт без ширины — git не создал ветку с таким именем\n'
fi
# То же в длине строки: пять знаков без ширины в неукороченной ветке места не
# занимают — ступень выбирается так, будто их нет.
small_fixture "${_nrepo}"
_adj=5
for _v in $'\357\270\217' "${_brv}" "${_ypo}"; do
  _br="a$(rep "${_v}" 5)b"
  _vx="$(printf '%s' "${_v}" | od -An -tx1 | tr -d ' \n')"
  if nbranch "${_br}"; then
    # shellcheck disable=SC2088 # «~» — текст строки статуса, а не путь
    fits_check "знаки без ширины в длину не входят (${_vx})" \
      "~/w | Opus 5.5 | Ctx 42% | ${_i} ${_br}" "Ctx 42% ${_dot} ${_i} ${_br}" NO_COLOR=1
  else
    printf 'ПРОПУСК: знаки без ширины в длину не входят (%s) — git не создал ветку с таким именем\n' "${_vx}"
  fi
done
_adj=0
# Мягкий перенос и буква U+0370 место занимают. У ветки с мягкими переносами
# следом пробуется её короткий вид — без них, на той же ступени.
for _v in "${_shy}" "${_heta}"; do
  _br="a$(rep "${_v}" 5)b"
  _vx="$(printf '%s' "${_v}" | od -An -tx1 | tr -d ' \n')"
  _nx="Ctx 42% ${_dot} ${_i} ${_br}"
  # shellcheck disable=SC2088 # «~» — текст строки статуса, а не путь
  [[ "${_v}" == "${_shy}" ]] && _nx="~/w | Opus 5.5 | Ctx 42% | ${_i} ab"
  if nbranch "${_br}"; then
    # shellcheck disable=SC2088 # «~» — текст строки статуса, а не путь
    fits_check "знак с шириной в длину входит (${_vx})" "~/w | Opus 5.5 | Ctx 42% | ${_i} ${_br}" "${_nx}" NO_COLOR=1
  else
    printf 'ПРОПУСК: знак с шириной в длину входит (%s) — git не создал ветку с таким именем\n' "${_vx}"
  fi
done
narrow_fixture "${_nrepo}"
# Имя не в UTF-8 (одни байты продолжения): видимых знаков «один», но обход и
# укороченная ветка ограничены 120 байтами.
# 116, а не 119: на предел попадает байт продолжения, срез отступает на три байта
# — начала знака в таком имени нет вовсе.
branch_check 'ветка: 200 байтов продолжения — не длиннее 120 байтов и многоточия' \
  "m$(rep $'\277' 200)" "m$(rep $'\277' 116)${_e}"

# Кэш на ступенях после полной: без слова warm, без точки перед объёмом, срок —
# «(5m)» — на средней (ширина 79), сжатой (60) и в двух строках (45).
# narrow_cache_check <описание> <prompt_cache JSON> <ожидаемый сегмент>
narrow_cache_check() {
  narrow_fixture "${_work}" "$2"
  narrow 79
  check "$1: средняя" "${_out}" \
    "${_b}~/work${_z} | Opus 5.5 | Ctx 42% | 5h 37% 2h29m | ${_y}${_l2}${_z} | $3"
  narrow 60
  check "$1: сжатая" "${_out}" "${_l1} ${_dot} ${_y}${_l2}${_z} ${_dot} $3"
  narrow 45
  check "$1: две строки" "${_out}" "${_l1} ${_dot} ${_y}${_l2}${_z}"$'\n'"$3"
}
narrow_cache_check 'узкий экран: кэш истекает — жёлтый' "$(pc 240)" "${_y}cache 4m${_z}"
narrow_cache_check 'узкий экран: пятиминутный срок' "$(pc 200 5m)" 'cache 3m (5m)'
narrow_cache_check 'узкий экран: пятиминутный срок истекает' "$(pc 40 5m)" "${_y}cache <1m${_z} (5m)"
narrow_cache_check 'узкий экран: кэш остыл, объём известен' "$(pc -10 1h "${_re}")" 'cache cold 151k'
narrow_cache_check 'узкий экран: кэш остыл, объём неизвестен' \
  "$(pc 1860 1h ',"recache_tokens_if_cold":null')" 'cache cold'

# Данных мало: пустая строка вывода не печатается; показать нечего — название модели.
nbranch main
check 'тестовая ветка main' "$?" 0
jq -n --arg d "${_nrepo}" --argjson pc "$(pc -10 1h "${_re}")" \
  '{model:{display_name:"Opus 5.5"},workspace:{current_dir:$d},prompt_cache:$pc}' >"${_fx}"
narrow 20 NO_COLOR=1
out_check 'без контекста и лимитов: одна строка' "cache cold 151k ${_dot} ${_i} main"
jq -n --arg d "${_work}" '{model:{display_name:"Opus 5.5 (1M context)"},workspace:{current_dir:$d}}' >"${_fx}"
narrow 20
out_check 'показать нечего: название модели' 'Opus 5.5 (1M context)'
jq -n --arg d "${_work}" '{model:{display_name:"Opus 5.5 (1M context)"},workspace:{current_dir:$d},context_window:{used_percentage:42}}' >"${_fx}"
narrow 20
check 'только контекст на самой узкой: одна строка' "${_out}" 'Ctx 42%'
# Вывод не кончается переводом строки, когда последняя строка пуста (нет ни
# кэша, ни ветки). $(…) в run его срезает, поэтому вывод берётся с замком «.»
# в конце — тем же окружением, что дают narrow и run.
narrow_fixture "${_work}" '{"caching_observed":false}'
for _v in 45 20; do
  _o="$(env -i "PATH=${_root}/ok" "HOME=${_root}" "GIT_CEILING_DIRECTORIES=${_root}" "STATUSLINE_NOW=${_now}" \
    USER=u HOSTNAME=h NO_COLOR=1 "COLUMNS=${_v}" bash "${_tpl}" <"${_fx}" && printf .)"
  if [[ "${_v}" == 45 ]]; then
    check 'сжатая без кэша и ветки: без перевода строки в конце' "${_o}" "${_l1} ${_dot} ${_l2}."
  else
    check 'три строки без третьей: без перевода строки в конце' "${_o}" "${_l1}"$'\n'"${_l2}."
  fi
done
# Папка показывается пустой (из одних невидимых знаков): средняя строка начинается
# с модели, без разделителя впереди — и с цветами тоже.
jq -n --arg d "${_hid}" '{model:{display_name:"M"},cwd:$d,context_window:{used_percentage:42}}' >"${_fx}"
narrow 20
check 'средняя без папки: с модели' "${_out}" 'M | Ctx 42%'
# Пустой ввод: названия модели нет, на узких ступенях показать нечего — строка
# не пропадает, выводится полная, как без COLUMNS. Папки во вводе нет, git
# смотрит текущую — запуск из каталога вне репозитория, иначе покажется ветка.
: >"${_fx}"
_back="${PWD}"
cd "${_work}" || exit 1
narrow - NO_COLOR=1 USER=verylongusername HOSTNAME=verylonghostname
_full="${_out}"
check 'пустой ввод без COLUMNS: имя и хост' "${_full%%:*}" 'verylongusername@verylonghostname'
narrow 20 NO_COLOR=1 USER=verylongusername HOSTNAME=verylonghostname
out_check 'пустой ввод на узком экране: строка как без COLUMNS' "${_full}"
cd "${_back}" || exit 1

printf 'pass=%s fail=%s\n' "${_pass}" "${_fail}"
[[ "${_fail}" -eq 0 ]]
