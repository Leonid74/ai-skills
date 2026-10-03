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
# fixture <значение used_percentage | -> — «-» значит «поля нет».
fixture() {
  if [[ "$1" == "-" ]]; then
    printf '%s' '{"model":{"display_name":"M"},"workspace":{"current_dir":"/tmp"}}' >"${_fx}"
  else
    printf '{"model":{"display_name":"M"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":%s}}' "$1" >"${_fx}"
  fi
}

# fixture_raw <JSON целиком> — для векторов с лимитами, effort и полями не того типа.
fixture_raw() {
  printf '%s' "$1" >"${_fx}"
}

_out=""
_err=""
_rc=0
_ms=0
# _wait=0 — не ждать журнал моста (векторы вне tmux, где мост не проверяется).
_wait=1
# run <каталог bin> <TMUX | -> <TMUX_PANE | ->: вывод, stderr, код, длительность
# (мс); затем ждёт фоновый мост — запись заглушки в журнал.
run() {
  local _bin="${_root}/$1" _t0 _t1 _i
  local -a _env=(env -i "PATH=${_bin}" "HOME=${_root}")
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
    [[ "${_wait}" -eq 0 || -s "${_log}" ]] && break
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
# сегмент, и сдвиг полей. /tmp — не репозиторий, сегмента ветки нет.
_sep=$'\xe2\x97\x94'
_y=$'\033[01;33m'
_r=$'\033[01;31m'
_z=$'\033[00m'
_base='"model":{"display_name":"M"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":42.4}'

# tail_check <описание> <остальные поля JSON> <ожидаемый хвост>
tail_check() {
  fixture_raw "{${_base}$2}"
  _wait=0
  run ok - -
  _wait=1
  check "$1" "${_out#* | }" "$3"
  check "$1: код возврата" "${_rc}" 0
  check "$1: stderr пуст" "${_err}" ''
}

tail_check 'всё есть' \
  ',"effort":{"level":"high"},"rate_limits":{"five_hour":{"used_percentage":33.6,"resets_at":1},"seven_day":{"used_percentage":5,"resets_at":2}}' \
  "M ${_sep} high | Context 42% | 5h 34% | 7d 5%"
tail_check 'только пятичасовое окно' ',"rate_limits":{"five_hour":{"used_percentage":12}}' \
  'M | Context 42% | 5h 12%'
tail_check 'только недельное окно' ',"rate_limits":{"seven_day":{"used_percentage":12}}' \
  'M | Context 42% | 7d 12%'
tail_check 'rate_limits пуст' ',"rate_limits":{}' 'M | Context 42%'
tail_check 'границы 0 и 100' ',"rate_limits":{"five_hour":{"used_percentage":0},"seven_day":{"used_percentage":100}}' \
  "M | Context 42% | 5h 0% | ${_r}7d 100%${_z}"
tail_check 'пороги цвета 59/60' ',"rate_limits":{"five_hour":{"used_percentage":59},"seven_day":{"used_percentage":60}}' \
  "M | Context 42% | 5h 59% | ${_y}7d 60%${_z}"
tail_check 'пороги цвета 79/80' ',"rate_limits":{"five_hour":{"used_percentage":79},"seven_day":{"used_percentage":80}}' \
  "M | Context 42% | ${_y}5h 79%${_z} | ${_r}7d 80%${_z}"

# Значение не число или вне 0–100, блок не того типа — сегмента нет, строка цела.
for _v in '"five_hour":{"used_percentage":"7; x"}' '"five_hour":{"used_percentage":101}' \
  '"five_hour":{"used_percentage":-1}' '"five_hour":{"used_percentage":1e19}' \
  '"five_hour":{"used_percentage":null}' '"five_hour":"str"' '"five_hour":[1]'; do
  tail_check "лимит ${_v}: сегмента нет" ",\"rate_limits\":{${_v},\"seven_day\":{\"used_percentage\":5}}" \
    'M | Context 42% | 7d 5%'
done
tail_check 'rate_limits — строка' ',"rate_limits":"str"' 'M | Context 42%'
tail_check 'rate_limits — массив' ',"rate_limits":[1,2]' 'M | Context 42%'

# effort уходит в терминал: только строчные латинские буквы, иначе — без него.
for _v in '"High"' '"medium\nx"' '"medium\n"' '"\u001b[31mx"' '"a b"' '""' '"abcdefghijklm"' 5 null '{"level":"x"}'; do
  tail_check "effort.level=${_v}: без effort" ",\"effort\":{\"level\":${_v}}" 'M | Context 42%'
done
tail_check 'effort — строка' ',"effort":"high"' 'M | Context 42%'

# Перевод строки в названии модели и в пути не сдвигает поля.
fixture_raw '{"model":{"display_name":"M\nX"},"cwd":"/tmp/a\nb","effort":{"level":"low"},"context_window":{"used_percentage":7},"rate_limits":{"five_hour":{"used_percentage":1},"seven_day":{"used_percentage":2}}}'
run ok - -
check 'перевод строки в модели и пути: поля на месте' "${_out#* | }" "M X ${_sep} low | Context 7% | 5h 1% | 7d 2%"
check 'перевод строки в пути: путь цел' "$([[ "${_out}" == *$'/tmp/a\nb'* ]] && echo да)" да

# Поля не того типа целиком — строка статуса не гаснет.
fixture_raw '{"model":"M","cwd":"/tmp","workspace":"w","context_window":"c","rate_limits":7,"effort":[1]}'
run ok - -
check 'поля не того типа: хвост' "${_out#* | }" '?'
check 'поля не того типа: код возврата' "${_rc}" 0
check 'поля не того типа: stderr пуст' "${_err}" ''

# Мост в tmux по-прежнему получает только процент контекста.
fixture_raw "{${_base},\"effort\":{\"level\":\"high\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":90},\"seven_day\":{\"used_percentage\":95}}}"
run ok "${_T}" %7
check 'лимиты и мост: в опцию идёт контекст' "$(cat "${_log}")" \
  "timeout [-s] [KILL] [1] [tmux] [if] [-F] [-t] [%7] [${_cond_pre}#{!=:#{@claude_ctx},42},0}] [set -p -t %7 @claude_ctx 42] ${_null}"

printf 'pass=%s fail=%s\n' "${_pass}" "${_fail}"
[[ "${_fail}" -eq 0 ]]
