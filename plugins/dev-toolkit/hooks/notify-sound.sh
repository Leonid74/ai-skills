#!/usr/bin/env bash
# Звуковое уведомление для Claude Code: воспроизводит сигнал, когда Claude
# ждёт ответа/разрешения (событие Notification) или завершил работу (Stop).
#
# Первый аргумент — тип события: "notification" | "stop". От него зависит
# выбор звука и число гудков в fallback-режиме. JSON события приходит на
# stdin, но для задачи не нужен — мы его поглощаем, чтобы пишущая сторона
# не получила SIGPIPE.
#
# Логика: перебираем доступные плееры и системные звуковые файлы; если ни
# одного плеера нет (как в чистой tmux/SSH-сессии) — падаем на terminal bell.
# Скрипт НИКОГДА не возвращает ненулевой код: звуковой хук не должен
# блокировать или прерывать работу Claude Code.

event="${1:-stop}"

# Поглощаем JSON со stdin (содержимое не требуется).
cat >/dev/null 2>&1 || true

# --- Подбор имени звука под тип события -------------------------------------
# message.* — «нужно внимание», complete.* — «готово».
case "$event" in
  notification) names="message bell dialog-information" ;;
  *)            names="complete bell-window-system service-login" ;;
esac

sound_dirs="
/usr/share/sounds/freedesktop/stereo
/usr/share/sounds/gnome/default/alerts
/usr/share/sounds/ubuntu/stereo
/usr/share/sounds/alsa
"

# Ищет первый читаемый звуковой файл под выбранные имена.
find_sound() {
  local n d f
  for n in $names; do
    for d in $sound_dirs; do
      for f in "$d/$n".oga "$d/$n".ogg "$d/$n".wav; do
        [ -r "$f" ] && { printf '%s' "$f"; return 0; }
      done
    done
  done
  return 1
}

# Воспроизводит файл первым доступным плеером.
play_file() {
  local file="$1"
  if command -v pw-play >/dev/null 2>&1; then pw-play "$file" >/dev/null 2>&1 && return 0; fi
  if command -v paplay  >/dev/null 2>&1; then paplay  "$file" >/dev/null 2>&1 && return 0; fi
  if command -v ffplay  >/dev/null 2>&1; then ffplay -nodisp -autoexit -loglevel quiet "$file" >/dev/null 2>&1 && return 0; fi
  if command -v play    >/dev/null 2>&1; then play -q "$file" >/dev/null 2>&1 && return 0; fi
  case "$file" in
    *.wav) command -v aplay >/dev/null 2>&1 && aplay -q "$file" >/dev/null 2>&1 && return 0 ;;
  esac
  return 1
}

# canberra умеет играть звук темы по имени, без пути к файлу.
play_canberra() {
  command -v canberra-gtk-play >/dev/null 2>&1 || return 1
  canberra-gtk-play -i "$1" >/dev/null 2>&1
}

# Terminal bell как последний рубеж: notification — 1 гудок, stop — 2,
# чтобы события различались на слух.
bell() {
  local n=1
  [ "$event" != "notification" ] && n=2

  # Хук запускается без tty (Claude Code перехватывает stdout/stderr),
  # поэтому пишем BEL напрямую в tty tmux-панели — туда байт доходит
  # даже через SSH. Если tmux недоступен — пробуем /dev/tty, затем stderr.
  local tty_target
  tty_target=$(tmux display-message -p '#{pane_tty}' 2>/dev/null)

  local i=0
  while [ "$i" -lt "$n" ]; do
    if [ -n "$tty_target" ] && [ -c "$tty_target" ]; then
      printf '\a' > "$tty_target" 2>/dev/null
    else
      { printf '\a' >/dev/tty; } 2>/dev/null || printf '\a' >&2
    fi
    i=$((i + 1))
    [ "$i" -lt "$n" ] && sleep 0.25
  done
}

# --- Основной поток ---------------------------------------------------------
if file="$(find_sound)"; then
  play_file "$file" && exit 0
fi

case "$event" in
  notification) play_canberra message  && exit 0 ;;
  *)            play_canberra complete && exit 0 ;;
esac

bell
exit 0
