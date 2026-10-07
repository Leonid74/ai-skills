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
_tools=(bash cat jq git whoami hostname sleep readlink mkdir mv)

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

# --- смена модели, /compact, /clear: «тёплый» кэш показывается холодным ----------
# Файл состояния — в своём каталоге (XDG_CACHE_HOME); строки «сессия время модель».
_st="${_root}/st"
_sf="${_st}/claude-statusline/cache-model"
_extra=("STATUSLINE_NOW=${_now}" "XDG_CACHE_HOME=${_st}")
# state_check <описание> <сессия, JSON> <модель, JSON> <смещение expires_at> <прочие поля кэша> <ожидаемый сегмент>
state_check() {
  tail_check "состояние: $1" \
    "{\"session_id\":$2,\"model\":{\"id\":$3,\"display_name\":\"M\"},\"workspace\":{\"current_dir\":\"${_work}\"},\"prompt_cache\":$(pc "$4" "${7:-1h}" "$5")}" \
    "M | $6"
}
_k=',"recache_tokens_if_cold":56209'
state_check 'первый рендер — тёплый' '"A"' '"claude-haiku-5-5"' 1800 "${_k}" 'cache warm 30m'
check 'состояние: модель запомнена' "$(cat "${_sf}")" "A $((_now + 1800)) claude-haiku-5-5"
state_check 'модель сменили — холодный с объёмом' '"A"' '"claude-sonnet-5-5"' 1800 "${_k}" "cache cold ${_dot} 56k"
check 'состояние: при смене модели запись не тронута' "$(cat "${_sf}")" "A $((_now + 1800)) claude-haiku-5-5"
state_check 'модель сменили, объёма нет' '"A"' '"claude-sonnet-5-5"' 1800 '' 'cache cold'
state_check 'модель сменили при 5m — без тарифа' '"A"' '"claude-sonnet-5-5"' 1800 "${_k}" \
  "cache cold ${_dot} 56k" 5m
state_check 'истекающий — жёлтый' '"G"' '"claude-haiku-5-5"' 300 "${_k}" "${_y}cache warm 5m${_z}"
state_check 'истекающий, модель сменили — холодный' '"G"' '"claude-sonnet-5-5"' 300 "${_k}" "cache cold ${_dot} 56k"
state_check 'истекающий при 5m — жёлтый с тарифом' '"G5"' '"claude-haiku-5-5"' 60 "${_k}" \
  "${_y}cache warm 1m${_z} (5m ttl)" 5m
state_check 'истекающий при 5m, модель сменили — без цвета и тарифа' '"G5"' '"claude-sonnet-5-5"' 60 "${_k}" \
  "cache cold ${_dot} 56k" 5m
: >"${_sf}"
state_check 'первый рендер заново' '"A"' '"claude-haiku-5-5"' 1800 "${_k}" 'cache warm 30m'
state_check 'модель вернули — снова тёплый' '"A"' '"claude-haiku-5-5"' 1800 "${_k}" 'cache warm 30m'
state_check 'запрос на новой модели — тёплый' '"A"' '"claude-sonnet-5-5"' 2000 "${_k}" 'cache warm 33m'
check 'состояние: запись обновлена' "$(cat "${_sf}")" "A $((_now + 2000)) claude-sonnet-5-5"
# Другая сессия с тем же временем истечения (ответы в одну секунду) — сама по
# себе: тёплая, со своей записью.
state_check 'другая сессия с тем же временем — тёплая' '"B"' '"claude-sonnet-5-5"' 2000 "${_k}" 'cache warm 33m'
check 'состояние: вторая сессия записана' "$(cat "${_sf}")" \
  "A $((_now + 2000)) claude-sonnet-5-5"$'\n'"B $((_now + 2000)) claude-sonnet-5-5"
state_check 'другая сессия, свой запрос — тёплая' '"B"' '"claude-opus-5-5[1m]"' 2100 "${_k}" 'cache warm 35m'
check 'состояние: две сессии' "$(cat "${_sf}")" "A $((_now + 2000)) claude-sonnet-5-5"$'\n'"B $((_now + 2100)) claude-opus-5-5[1m]"
state_check 'время как у другой сессии — запись обновляется' '"A"' '"claude-sonnet-5-5"' 2100 "${_k}" 'cache warm 35m'
check 'состояние: временных файлов не осталось' "$(ls "${_st}/claude-statusline")" 'cache-model'
check 'состояние: каталог 700' "$(stat -c %a "${_st}/claude-statusline")" 700
check 'состояние: файл 600' "$(stat -c %a "${_sf}")" 600
# /compact: поле объёма есть, значение null — холодный без объёма; поля нет — тёплый.
state_check 'после компакции — холодный' '"A"' '"claude-sonnet-5-5"' 2500 ',"recache_tokens_if_cold":null' 'cache cold'
check 'состояние: после компакции запись не тронута' "$(grep -c "^A $((_now + 2100)) " "${_sf}")" 1
state_check 'поля объёма нет — тёплый' '"A"' '"claude-sonnet-5-5"' 2500 '' 'cache warm 41m'
cache_check 'после компакции, без сессии — холодный' "$(pc 1860 1h ',"recache_tokens_if_cold":null')" 'cache cold'
# Истёкший кэш состояние не трогает.
_before="$(cat "${_sf}")"
state_check 'истёкший — холодный' '"C"' '"claude-haiku-5-5"' -5 "${_k}" "cache cold ${_dot} 56k"
check 'состояние: истёкший не записан' "$(cat "${_sf}")" "${_before}"
# Сессия или модель не названы либо с посторонними символами — проверки и записи нет.
for _v in '"A",null' 'null,"claude-x"' '"a b","claude-x"' '"A","claude x"' '"A\nB","claude-x"' '"A","claude\u001b[31m"' \
  '7,"claude-x"' '"A",["claude-x"]' '"","claude-x"' "\"$(printf 'a%.0s' {1..65})\",\"claude-x\"" "\"A\",\"$(printf 'a%.0s' {1..129})\""; do
  state_check "идентификаторы ${_v:0:40}: тёплый" "${_v%%,*}" "${_v#*,}" 1800 "${_k}" 'cache warm 30m'
  check "идентификаторы ${_v:0:40}: записи нет" "$(cat "${_sf}")" "${_before}"
done
# Все допустимые знаки проходят и запись, и чтение (смена модели видна).
state_check 'знаки в идентификаторах: запись' '"a_b.c:d/e@f[g]-h"' '"us.vendor/claude-x_v1:0@z[1m]"' 1800 "${_k}" 'cache warm 30m'
check 'знаки в идентификаторах: записаны' "$(grep -c -F "a_b.c:d/e@f[g]-h $((_now + 1800)) us.vendor/claude-x_v1:0@z[1m]" "${_sf}")" 1
state_check 'знаки в идентификаторах: чтение' '"a_b.c:d/e@f[g]-h"' '"us.vendor/claude-y_v1:0@z[1m]"' 1800 "${_k}" "cache cold ${_dot} 56k"
# Дробное время истечения пишется целым — иначе строка не прочлась бы обратно.
_frac="{\"caching_observed\":true,\"ttl\":\"1h\",\"expires_at\":$((_now + 1800)).5${_k}}"
tail_check 'состояние: дробное время — запись' \
  "{\"session_id\":\"FR\",\"model\":{\"id\":\"claude-x\",\"display_name\":\"M\"},\"workspace\":{\"current_dir\":\"${_work}\"},\"prompt_cache\":${_frac}}" \
  'M | cache warm 30m'
check 'состояние: дробное время записано целым' "$(grep -c "^FR $((_now + 1800)) claude-x$" "${_sf}")" 1
tail_check 'состояние: дробное время — смена модели видна' \
  "{\"session_id\":\"FR\",\"model\":{\"id\":\"claude-y\",\"display_name\":\"M\"},\"workspace\":{\"current_dir\":\"${_work}\"},\"prompt_cache\":${_frac}}" \
  "M | cache cold ${_dot} 56k"
_before="$(cat "${_sf}")"
state_check 'идентификаторы предельной длины' "\"$(printf 'a%.0s' {1..64})\"" "\"$(printf 'b%.0s' {1..128})\"" 1800 "${_k}" 'cache warm 30m'
check 'идентификаторы предельной длины: записаны' "$(grep -c '^a\{64\} [0-9]* b\{128\}$' "${_sf}")" 1
# Не больше 20 сессий: старые вытесняются.
: >"${_sf}"
for _i in $(seq 1 25); do
  state_check "сессия S${_i}" "\"S${_i}\"" '"claude-x"' "$((3000 + _i))" "${_k}" 'cache warm 50m'
done
check 'состояние: 20 строк' "$(grep -c '' "${_sf}")" 20
check 'состояние: первая — S6, последняя — S25' "$(sed -n '1p;$p' "${_sf}" | cut -d' ' -f1 | tr '\n' ' ')" 'S6 S25 '
# Мусор в файле: строка статуса цела, годные строки сохранены, мусор не переписан.
printf '%s\n' 'мусор' "A $((_now + 1800)) claude-haiku-5-5" 'x y' "Z notanumber m" '' "$(printf 'q%.0s' {1..5000})" >"${_sf}"
state_check 'мусор в файле: запись читается' '"A"' '"claude-sonnet-5-5"' 1800 "${_k}" "cache cold ${_dot} 56k"
state_check 'мусор в файле: новая сессия' '"N"' '"claude-x"' 1900 "${_k}" 'cache warm 31m'
check 'мусор в файле: остались годные строки' "$(cat "${_sf}")" "A $((_now + 1800)) claude-haiku-5-5"$'\n'"N $((_now + 1900)) claude-x"
# Строки верной структуры, но сверх длины, — тоже мусор: не сохраняются.
printf '%s\n' "$(printf 'a%.0s' {1..65}) 1 m" "s 1234567890123 m" "s 1 $(printf 'b%.0s' {1..129})" "K 5 claude-k" >"${_sf}"
state_check 'длинные строки в файле' '"N2"' '"claude-x"' 1900 "${_k}" 'cache warm 31m'
check 'длинные строки в файле: не сохранены' "$(cat "${_sf}")" "K 5 claude-k"$'\n'"N2 $((_now + 1900)) claude-x"
# Читаются только первые 40 строк.
{ for _i in $(seq 1 40); do echo "F${_i} 1 m"; done; echo "A $((_now + 1800)) claude-haiku-5-5"; } >"${_sf}"
state_check 'запись дальше 40-й строки не читается' '"A"' '"claude-sonnet-5-5"' 1800 "${_k}" 'cache warm 30m'
{ for _i in $(seq 1 39); do echo "F${_i} 1 m"; done; echo "A $((_now + 1800)) claude-haiku-5-5"; } >"${_sf}"
state_check 'запись на 40-й строке читается' '"A"' '"claude-sonnet-5-5"' 1800 "${_k}" "cache cold ${_dot} 56k"
# Каталог состояния недоступен или его нечем создать — строка цела.
printf 'x' >"${_root}/notdir"
_extra=("STATUSLINE_NOW=${_now}" "XDG_CACHE_HOME=${_root}/notdir")
state_check 'каталог состояния — файл' '"A"' '"claude-x"' 1800 "${_k}" 'cache warm 30m'
_extra=("STATUSLINE_NOW=${_now}" "XDG_CACHE_HOME=${_root}/st-nomkdir")
fixture_raw "{\"session_id\":\"A\",\"model\":{\"id\":\"claude-x\",\"display_name\":\"M\"},\"workspace\":{\"current_dir\":\"${_work}\"},\"prompt_cache\":$(pc 1800)}"
mkdir -p "${_root}/nomkdir"
for _t in bash cat jq git whoami hostname; do ln -s "$(command -v "${_t}")" "${_root}/nomkdir/${_t}"; done
run nomkdir - - nowait
check 'нет mkdir: вывод' "${_out#* | }" 'M | cache warm 30m'
check 'нет mkdir: код возврата' "${_rc}" 0
check 'нет mkdir: stderr пуст' "${_err}" ''
# XDG_CACHE_HOME не задан или пуст — каталог в HOME.
_hf="${_root}/.cache/claude-statusline/cache-model"
_extra=("STATUSLINE_NOW=${_now}")
state_check 'каталог по умолчанию' '"H"' '"claude-x"' 1800 "${_k}" 'cache warm 30m'
check 'каталог по умолчанию: ~/.cache' "$(cat "${_hf}")" "H $((_now + 1800)) claude-x"
check 'каталог по умолчанию: ~/.cache создан с правами 700' "$(stat -c %a "${_root}/.cache")" 700
_extra=("STATUSLINE_NOW=${_now}" XDG_CACHE_HOME=)
state_check 'XDG_CACHE_HOME пуст' '"H2"' '"claude-x"' 1800 "${_k}" 'cache warm 30m'
check 'XDG_CACHE_HOME пуст: ~/.cache' "$(grep -c "^H2 " "${_hf}")" 1
# Относительный XDG_CACHE_HOME не берётся: файл не появляется в рабочем каталоге.
state_check 'заготовка для относительного пути' '"H3"' '"claude-x"' 1800 "${_k}" 'cache warm 30m'
# Каталоги с такими именами в рабочем каталоге есть — писать в них нельзя.
mkdir -p "${_root}/work/relcache" "${_root}/work/relhome/.cache"
_o="$(cd "${_root}/work" && env -i "PATH=${_root}/ok" "HOME=${_root}" "STATUSLINE_NOW=${_now}" XDG_CACHE_HOME=relcache \
  bash "${_tpl}" <"${_fx}" 2>&1)"
check 'XDG_CACHE_HOME относительный: вывод' "${_o#* | }" 'M | cache warm 30m'
check 'XDG_CACHE_HOME относительный: в каталог не записано' "$(ls "${_root}/work/relcache")" ''
# HOME относительный и XDG_CACHE_HOME не задан — состояния нет, строка цела.
_o="$(cd "${_root}/work" && env -i "PATH=${_root}/ok" HOME=relhome "STATUSLINE_NOW=${_now}" bash "${_tpl}" <"${_fx}" 2>&1)"
check 'HOME относительный: вывод' "${_o#* | }" 'M | cache warm 30m'
check 'HOME относительный: в каталог не записано' "$(ls "${_root}/work/relhome/.cache")" ''

# --- файл состояния: не обычный файл, чужой каталог, сбой записи ---------------------
_sx="${_root}/sx"
_sxf="${_sx}/claude-statusline/cache-model"
_extra=("STATUSLINE_NOW=${_now}" "XDG_CACHE_HOME=${_sx}")
mkdir -p "${_sx}/claude-statusline"
# Симлинк на месте файла: цель не читается и не затирается.
printf 'A %s claude-haiku-5-5\n' "$((_now + 1800))" >"${_root}/victim"
ln -s "${_root}/victim" "${_sxf}"
state_check 'симлинк на месте файла: не читается' '"A"' '"claude-sonnet-5-5"' 1800 "${_k}" 'cache warm 30m'
check 'симлинк на месте файла: цель цела' "$(cat "${_root}/victim")" "A $((_now + 1800)) claude-haiku-5-5"
check 'симлинк на месте файла: заменён обычным файлом' "$([[ -f "${_sxf}" && ! -L "${_sxf}" ]] && cat "${_sxf}")" \
  "A $((_now + 1800)) claude-sonnet-5-5"
# FIFO на месте файла: чтение не зависает. Страховка самого теста: через 2 с в
# FIFO (под вторым именем — жёсткой ссылкой) пишет фоновый процесс, так что
# шаблон, всё же открывший FIFO, не повиснет навсегда, а провалит проверку
# времени; исправный шаблон FIFO не открывает, и писатель снимается по timeout.
mv "${_sxf}" "${_root}/sx-old"
mkfifo "${_sxf}"
ln "${_sxf}" "${_root}/fifo-alias"
# shellcheck disable=SC2016 # $1 раскрывает вложенный bash, а не эта оболочка
(sleep 2 && timeout 3 bash -c 'printf "x\n" >"$1"' _ "${_root}/fifo-alias") >/dev/null 2>&1 &
state_check 'FIFO на месте файла: строка цела' '"A"' '"claude-x"' 1800 "${_k}" 'cache warm 30m'
check "FIFO на месте файла: скрипт не ждёт (${_ms} мс)" "$((_ms < 1500 ? 1 : 0))" 1
check 'FIFO на месте файла: заменён обычным файлом' "$([[ -f "${_sxf}" && ! -L "${_sxf}" ]] && cat "${_sxf}")" \
  "A $((_now + 1800)) claude-x"
# Каталог состояния — симлинк: в чужой каталог не пишем и оттуда не читаем.
mkdir -p "${_root}/sy" "${_root}/foreign"
printf 'A %s claude-haiku-5-5\n' "$((_now + 1800))" >"${_root}/foreign/cache-model"
ln -s "${_root}/foreign" "${_root}/sy/claude-statusline"
_extra=("STATUSLINE_NOW=${_now}" "XDG_CACHE_HOME=${_root}/sy")
state_check 'каталог состояния — симлинк: не читается' '"A"' '"claude-sonnet-5-5"' 1800 "${_k}" 'cache warm 30m'
check 'каталог состояния — симлинк: чужой файл цел' "$(cat "${_root}/foreign/cache-model")" "A $((_now + 1800)) claude-haiku-5-5"
check 'каталог состояния — симлинк: лишних файлов нет' "$(ls "${_root}/foreign")" 'cache-model'
# Сбой переименования: прежний файл цел, смена модели по-прежнему видна.
mkdir -p "${_root}/mvfail"
for _t in bash cat jq git whoami hostname mkdir; do ln -s "$(command -v "${_t}")" "${_root}/mvfail/${_t}"; done
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"${_root}/mvfail/mv"
chmod +x "${_root}/mvfail/mv"
_extra=("STATUSLINE_NOW=${_now}" "XDG_CACHE_HOME=${_sx}")
printf 'A %s claude-haiku-5-5\nB 7 claude-b\n' "$((_now + 1800))" >"${_sxf}.keep"
mv "${_sxf}.keep" "${_sxf}"
fixture_raw "{\"session_id\":\"C\",\"model\":{\"id\":\"claude-x\",\"display_name\":\"M\"},\"workspace\":{\"current_dir\":\"${_work}\"},\"prompt_cache\":$(pc 1900)}"
run mvfail - - nowait
check 'сбой mv: вывод' "${_out#* | }" 'M | cache warm 31m'
check 'сбой mv: код возврата' "${_rc}" 0
check 'сбой mv: stderr пуст' "${_err}" ''
check 'сбой mv: прежний файл цел' "$(cat "${_sxf}")" "A $((_now + 1800)) claude-haiku-5-5"$'\n'"B 7 claude-b"
# Каталог создать нельзя — mkdir не запускается ни разу; можно — ровно один раз.
mkdir -p "${_root}/mklog"
for _t in bash cat jq git whoami hostname mv; do ln -s "$(command -v "${_t}")" "${_root}/mklog/${_t}"; done
printf '%s\n' '#!/usr/bin/env bash' "echo mkdir >>\"${_root}/mkdir.calls\"" "exec \"$(command -v mkdir)\" \"\$@\"" >"${_root}/mklog/mkdir"
chmod +x "${_root}/mklog/mkdir"
: >"${_root}/mkdir.calls"
_extra=("STATUSLINE_NOW=${_now}" "XDG_CACHE_HOME=${_root}/notdir")
run mklog - - nowait
run mklog - - nowait
check 'каталог создать нельзя: mkdir не запускается' "$(grep -c '' "${_root}/mkdir.calls")" 0
check 'каталог создать нельзя: вывод' "${_out#* | }" 'M | cache warm 31m'
# На месте самого каталога состояния — файл: тоже без попыток.
mkdir -p "${_root}/occupied"
printf 'x' >"${_root}/occupied/claude-statusline"
_extra=("STATUSLINE_NOW=${_now}" "XDG_CACHE_HOME=${_root}/occupied")
run mklog - - nowait
run mklog - - nowait
check 'на месте каталога состояния файл: mkdir не запускается' "$(grep -c '' "${_root}/mkdir.calls")" 0
check 'на месте каталога состояния файл: вывод' "${_out#* | }" 'M | cache warm 31m'
check 'на месте каталога состояния файл: файл цел' "$(cat "${_root}/occupied/claude-statusline")" 'x'
mkdir -p "${_root}/ro/base"
chmod 555 "${_root}/ro/base"
_extra=("STATUSLINE_NOW=${_now}" "XDG_CACHE_HOME=${_root}/ro/base")
run mklog - - nowait
check 'каталог только для чтения: mkdir не запускается' "$(grep -c '' "${_root}/mkdir.calls")" 0
chmod 755 "${_root}/ro/base"
_extra=("STATUSLINE_NOW=${_now}" "XDG_CACHE_HOME=${_root}/fresh/cache")
run mklog - - nowait
check 'нет и родителя XDG_CACHE_HOME: mkdir не запускается' "$(grep -c '' "${_root}/mkdir.calls")" 0
mkdir -p "${_root}/fresh"
run mklog - - nowait
run mklog - - nowait
check 'каталог можно создать: mkdir один раз' "$(grep -c '' "${_root}/mkdir.calls")" 1
check 'каталог можно создать: запись есть' "$(cat "${_root}/fresh/cache/claude-statusline/cache-model")" "C $((_now + 1900)) claude-x"

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
mkdir -p "${_root}/nowho"
for _t in bash cat jq git; do ln -s "$(command -v "${_t}")" "${_root}/nowho/${_t}"; done
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
mkdir -p "${_root}/whofail"
for _t in bash cat jq git; do ln -s "$(command -v "${_t}")" "${_root}/whofail/${_t}"; done
printf '%s\n' '#!/usr/bin/env bash' 'echo oops' 'echo "cannot find name" >&2' 'exit 1' >"${_root}/whofail/whoami"
printf '%s\n' '#!/usr/bin/env bash' 'echo oops' 'echo "no hostname" >&2' 'exit 1' >"${_root}/whofail/hostname"
chmod +x "${_root}/whofail/whoami" "${_root}/whofail/hostname"
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
printf '%s\n' '#!/usr/bin/env bash' 'echo "host.example.org"' >"${_root}/whofail/hostname"
_extra=(USER=alice HOSTNAME=)
run whofail - - nowait
check 'HOSTNAME пуст: короткий хост от hostname' "${_out%%:*}" "${_g}alice@host${_z}"
# Значения окружения — в терминал только очищенными: управляющие символы C0 и
# C1, перевод строки и смена направления письма убраны, прочий юникод цел.
_extra=("USER=ro"$'\033'"[2Jot"$'\n'"X"$'\302\233'"1"$'\342\200\256'"жук" "HOSTNAME=h"$'\033'"]0;pwn"$'\a'"x"$'\342\201\246'"é.example")
run nowho - - nowait
check 'имя и хост очищены' "${_out%%:*}" "${_g}ro[2JotX1жук@h]0;pwnxé${_z}"
check 'имя и хост очищены: вывод в одну строку' "$(printf '%s\n' "${_out}" | grep -c '')" 1
# То же в UTF-8-локали пользователя (из тех, что есть на машине): очистка идёт
# по байтам и от локали не зависит.
_dirty=("${_extra[@]}")
for _loc in $(locale -a 2>/dev/null | grep -i -E '^(C|en_US|ru_RU)\.utf-?8$'); do
  _extra=("${_dirty[@]}" "LC_ALL=${_loc}")
  run nowho - - nowait
  check "имя и хост очищены в локали ${_loc}" "${_out%%:*}" "${_g}ro[2JotX1жук@h]0;pwnxé${_z}"
  check "имя и хост очищены в локали ${_loc}: stderr пуст" "${_err}" ''
done
_extra=()

# --- git: один вызов; репозиторий без коммитов — ветки нет -------------------------
mkdir -p "${_root}/gitlog"
for _t in bash cat jq whoami hostname; do ln -s "$(command -v "${_t}")" "${_root}/gitlog/${_t}"; done
printf '%s\n' '#!/usr/bin/env bash' "echo git >>\"${_root}/git.calls\"" "exec \"$(command -v git)\" \"\$@\"" >"${_root}/gitlog/git"
chmod +x "${_root}/gitlog/git"
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

printf 'pass=%s fail=%s\n' "${_pass}" "${_fail}"
[[ "${_fail}" -eq 0 ]]
