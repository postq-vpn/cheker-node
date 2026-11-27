#!/bin/bash
# @menu.manifest
# @item( skynet | i | 🤖 Доступность AI по IPv4 | _skynet_ai_menu | 55 | 2 | Ежедневная проверка нод, расписание и отчёты в Telegram. )
source "${SCRIPT_DIR}/modules/skynet/executor.sh"
source "${SCRIPT_DIR}/modules/skynet/censorcheck_report.sh"

_skynet_ai_run() (
    umask 077
    local dir=/etc/reshala/ipregion state=/etc/reshala/ipregion/state.json
    local revision=4803d4d6f7d2048be44981b3d9fe4c5058cd2e1d
    local checksum=a286a4407a690999f472cb55fa856c82ccc1759dbc2580993c3bae7458d7b898
    local store="${SCRIPT_DIR}/modules/skynet/ai_state.py"
    mkdir -p "$dir" || return 1
    exec 9>"$dir/lock" || return 1
    flock -n 9 || return 1
    local work results=""
    work=$(mktemp -d) || return 1
    trap 'rm -rf -- "$work"; [[ -z "$results" ]] || rm -rf -- "$results"' EXIT
    if [[ -s "$FLEET_DATABASE_FILE" ]]; then
        if [[ ! -f "$dir/$revision.sh" ]] || ! (cd "$dir" && echo "$checksum  $revision.sh" | sha256sum --check --status); then
            curl -fsSL --max-time 60 "https://raw.githubusercontent.com/vernette/ipregion/$revision/ipregion.sh" -o "$work/source" &&
                (cd "$work" && echo "$checksum  source" | sha256sum --check --status) &&
                mv "$work/source" "$dir/$revision.sh" || return 1
        fi
        printf '%s\n' 'set -- --ipv4 --group ai --service platforms/google --json' > "$work/probe"
        cat "$dir/$revision.sh" >> "$work/probe" || return 1
        results=$(_skynet_run_plugin_on_fleet_parallel_capture "$work/probe" "" fleet) || return 1
    else
        results=$(mktemp -d) || return 1
        echo 0 > "$results/.count"
    fi
    python3 "$store" "$state" record "$results" || return 1
    python3 "$store" "$state" next > "$work/ai-report.txt" || return 1
    if ! _skynet_ai_send "$work/ai-report.txt"; then
        log "IPRegion: не удалось отправить отчёт в Telegram"
        return 1
    fi
    python3 "$store" "$state" ack
)

# Один вызов Bot API на отчёт. Длинный список изменений доставляем целиком файлом.
_skynet_ai_send() {
    local file="$1" method=sendMessage
    [[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]] || return 1
    local -a args=(--data-urlencode "chat_id=$TG_CHAT_ID")
    local length
    length=$(python3 -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8").read().encode("utf-16-le")) // 2)' "$file") || return 1
    if (( length <= 4096 )); then
        args+=(--data-urlencode "text@$file")
        [[ -z "${TG_TOPIC_ID:-}" ]] || args+=(--data-urlencode "message_thread_id=$TG_TOPIC_ID")
    else
        method=sendDocument
        args=(-F "chat_id=$TG_CHAT_ID" -F "document=@$file;type=text/plain" -F "caption=Изменения доступности AI по IPv4")
        [[ -z "${TG_TOPIC_ID:-}" ]] || args+=(-F "message_thread_id=$TG_TOPIC_ID")
    fi
    curl -fsS --max-time 60 "${args[@]}" "https://api.telegram.org/bot${TG_BOT_TOKEN}/$method" >/dev/null
}

_AI_CRON=/etc/cron.d/reshala-ai

_skynet_ai_time() {
    local time
    time=$(sed -n 's/^AI_TIME=//p' "$_AI_CRON" 2>/dev/null)
    printf '%s\n' "${time:-09:00}"
}

_skynet_ai_schedule() (
    local time="$1" enabled="$2" tmp
    [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || return 1
    tmp=$(mktemp "${_AI_CRON}.XXXXXX") || return 1
    trap 'rm -f -- "$tmp"' EXIT
    local prefix=""
    [[ "$enabled" == off ]] && prefix="# "
    sed -e "s/^AI_TIME=.*/AI_TIME=$time/" -e "s/^\*/${prefix}*/" \
        "${SCRIPT_DIR}/static/cron/reshala-ai" > "$tmp" &&
        chmod 644 "$tmp" && mv -f "$tmp" "$_AI_CRON"
)

_skynet_ai_menu() {
    local choice time enabled schedule tg
    while true; do
        clear
        menu_header "🤖 Доступность AI по IPv4"
        time=$(_skynet_ai_time)
        enabled=off
        grep -q '^\*' "$_AI_CRON" 2>/dev/null && enabled=on
        schedule="выключено"; [[ "$enabled" == on ]] && schedule="включено"
        tg="не настроен"
        [[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]] && tg="настроен"
        printf_description "Ноды Skynet · ежедневно в ${time} МСК · расписание ${schedule}"
        printf_description "Telegram ${tg} · одно сообщение по всем нодам"
        printf_menu_option "e" "Изменить время проверки (МСК)"
        printf_menu_option "a" "Включить / выключить расписание"
        printf_menu_option "n" "Настроить общий Telegram Skynet"
        printf_menu_option "r" "Запустить проверку и отправить отчёт сейчас"
        printf_menu_option "s" "Посмотреть последний замер"
        printf_menu_option "b" "Назад"
        choice=$(safe_read "Выбор" "") || return
        case "$choice" in
            [eE]) time=$(safe_read "Время по Москве (ЧЧ:ММ)" "$time") || continue
                  _skynet_ai_schedule "$time" "$enabled" || { printf_error "Не удалось сохранить время. Пример: 09:00."; wait_for_enter; } ;;
            [aA]) if [[ "$enabled" == on ]]; then enabled=off; else enabled=on; fi
                  _skynet_ai_schedule "$time" "$enabled" || { printf_error "Не удалось изменить расписание."; wait_for_enter; } ;;
            [nN]) _skynet_censorcheck_configure_telegram ;;
            [rR]) _skynet_ai_run || printf_error "Не удалось завершить проверку или доставить отчёт."; wait_for_enter ;;
            [sS]) _skynet_ai_main status; wait_for_enter ;;
            [bB]) return 0 ;;
        esac
    done
}

_skynet_ai_main() {
    case "${1:-run}" in
        enable) _skynet_ai_schedule "$(_skynet_ai_time)" on ;;
        run) _skynet_ai_run ;;
        status) python3 "${SCRIPT_DIR}/modules/skynet/ai_state.py" /etc/reshala/ipregion/state.json status ;;
        *) printf '%s\n' 'reshala ai-monitor [run|status|enable]' >&2; return 2 ;;
    esac
}
