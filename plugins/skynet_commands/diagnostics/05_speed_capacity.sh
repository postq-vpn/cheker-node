#!/bin/bash
# TITLE: Измерение скорости и вместимости
# SKYNET_HIDDEN: false
# SKYNET_COLOR: green
# Плагин для Скайнета: измеряет скорость канала через Ookla и считает,
# сколько VPN-пользователей потянет сервер.
#
# Формула вместимости — копия локального «Умного замера» из
# modules/local/local_care.sh (_calculate_vpn_capacity): берём самое узкое
# место из канала, свободной RAM и свободного CPU. Копия, а не общий код,
# потому что плагин уезжает на чужой сервер один файлом и не может
# рассчитывать ни на common.sh, ни на конфиг Решалы.
#
# ПОСЛЕДНЯЯ строка вывода — машиночитаемая: CAPACITY_USERS=<число>.
# По ней modules/skynet/capacity.sh складывает вместимость всего флота,
# поэтому её формат менять нельзя.
#

SPEEDTEST_MIRROR_1="https://install.speedtest.net/app/cli"
SPEEDTEST_MIRROR_2="https://dl.lamp.sh/files"

# --- Установка бинарника Ookla -------------------------------------------- #

_ensure_speedtest() {
    if command -v speedtest >/dev/null 2>&1 && [[ "$(speedtest --version 2>/dev/null)" == *Ookla* ]]; then
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1 || ! command -v sha256sum >/dev/null 2>&1; then
        echo "Не найдены curl, tar или sha256sum: установка Speedtest невозможна."
        return 1
    fi

    # Суммы архивов версии 1.2.0 с сайта Ookla: бинарник запускается от root на
    # всём флоте, а зеркало чужое. Те же суммы - в modules/local/local_care.sh.
    local arch tgz_name tgz_sha256
    arch=$(uname -m)
    case "$arch" in
        x86_64)
            tgz_name="ookla-speedtest-1.2.0-linux-x86_64.tgz"
            tgz_sha256="5690596c54ff9bed63fa3732f818a05dbc2db19ad36ed68f21ca5f64d5cfeeb7"
            ;;
        aarch64)
            tgz_name="ookla-speedtest-1.2.0-linux-aarch64.tgz"
            tgz_sha256="3953d231da3783e2bf8904b6dd72767c5c6e533e163d3742fd0437affa431bd3"
            ;;
        *)
            echo "Неподдерживаемая архитектура: ${arch}. Установка Speedtest невозможна."
            return 1
            ;;
    esac

    local work_dir
    work_dir=$(mktemp -d) || return 1
    local tgz="${work_dir}/speedtest.tgz"

    # Официальный сайт Ookla часто закрыт для российских IP — тогда идём
    # на зеркало (та же пара ссылок, что и в локальном замере).
    local mirror verified=0
    for mirror in "$SPEEDTEST_MIRROR_1" "$SPEEDTEST_MIRROR_2"; do
        if curl -fsL --connect-timeout 15 "${mirror}/${tgz_name}" -o "$tgz" \
            && [[ "$(sha256sum "$tgz" | cut -d' ' -f1)" == "$tgz_sha256" ]]; then
            verified=1
            break
        fi
    done
    if [[ "$verified" -ne 1 ]]; then
        rm -rf "$work_dir"
        echo "Не удалось загрузить Speedtest: источники недоступны или контрольная сумма не совпала."
        return 1
    fi

    if ! tar -xzf "$tgz" -C "$work_dir" speedtest 2>/dev/null || [[ ! -f "${work_dir}/speedtest" ]]; then
        rm -rf "$work_dir"
        echo "Архив Speedtest повреждён: исполняемый файл не найден."
        return 1
    fi

    mv "${work_dir}/speedtest" /usr/local/bin/speedtest
    chmod +x /usr/local/bin/speedtest
    rm -rf "$work_dir"

    # bash кэширует пути команд: без hash -r только что поставленный
    # бинарник может «не найтись» в этом же процессе.
    hash -r 2>/dev/null
    command -v speedtest >/dev/null 2>&1
}

# --- Разбор JSON ----------------------------------------------------------- #

# Достаёт число вида "<секция>":{..."<поле>":123...} из ответа спидтеста.
# Нужен только там, где на сервере нет jq: JSON Ookla плоский (вложенность
# ровно два уровня) и печатается одной строкой, поэтому grep справляется.
_json_num_fallback() {
    local json="$1" section="$2" field="$3"
    printf '%s' "$json" \
        | grep -o "\"${section}\":{[^}]*}" \
        | grep -o "\"${field}\":[0-9.]*" \
        | head -n1 \
        | cut -d':' -f2
}

_json_num() {
    local json="$1" section="$2" field="$3" value=""

    if command -v jq >/dev/null 2>&1; then
        value=$(printf '%s' "$json" | jq -r ".${section}.${field}" 2>/dev/null)
    fi
    if [[ -z "$value" || "$value" == "null" ]]; then
        value=$(_json_num_fallback "$json" "$section" "$field")
    fi

    printf '%s' "$value"
}

# --- Расчёт вместимости ---------------------------------------------------- #

# Мгновенная загрузка CPU по дельте /proc/stat (не load average: он врёт
# на свежезагруженной ноде и на машинах с высоким iowait).
_cpu_load_percent() {
    local line1 line2
    line1=$(grep '^cpu ' /proc/stat)
    sleep 0.2
    line2=$(grep '^cpu ' /proc/stat)

    if [[ -z "$line1" || -z "$line2" ]]; then
        echo "100" # при ошибке считаем, что процессор занят целиком
        return
    fi

    local _ user1 nice1 system1 idle1 iowait1 irq1 softirq1 steal1
    read -r _ user1 nice1 system1 idle1 iowait1 irq1 softirq1 steal1 _ <<< "$line1"
    local user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2
    read -r _ user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2 _ <<< "$line2"

    local idle_all1=$(( ${idle1:-0} + ${iowait1:-0} ))
    local idle_all2=$(( ${idle2:-0} + ${iowait2:-0} ))
    local busy1=$(( ${user1:-0} + ${nice1:-0} + ${system1:-0} + ${irq1:-0} + ${softirq1:-0} + ${steal1:-0} ))
    local busy2=$(( ${user2:-0} + ${nice2:-0} + ${system2:-0} + ${irq2:-0} + ${softirq2:-0} + ${steal2:-0} ))

    local total_delta=$(( (idle_all2 + busy2) - (idle_all1 + busy1) ))
    local idle_delta=$(( idle_all2 - idle_all1 ))

    local perc=0
    if (( total_delta > 0 )); then
        perc=$(awk "BEGIN {printf \"%.0f\", (1 - ${idle_delta} / ${total_delta}) * 100}")
    fi
    if (( perc < 0 )); then perc=0; fi
    if (( perc > 100 )); then perc=100; fi
    echo "$perc"
}

# Печатает две строки: число юзеров и причину упора ("Канал"/"RAM"/"CPU").
_calculate_capacity() {
    local upload_mbps="$1"

    # 1. Лимит по КАНАЛУ: 4 Мбит/с на юзера, от полосы берём 80%
    local net_limit=0
    if [[ -n "$upload_mbps" ]]; then
        local clean_speed=${upload_mbps%.*}
        net_limit=$(awk -v speed="${clean_speed:-0}" 'BEGIN {printf "%.0f", (speed * 0.8) / 4}')
    fi

    # 2. Лимит по ПАМЯТИ: считаем от available, а не от total, и оставляем
    #    250 МБ системе; на юзера кладём 5 МБ
    local available_ram
    available_ram=$(free -m | awk '/^Mem/ {print $7}')
    local ram_for_users=$(( ${available_ram:-0} - 250 ))
    if (( ram_for_users < 0 )); then ram_for_users=0; fi
    local max_users_ram=$(( ram_for_users / 5 ))

    # 3. Лимит по ПРОЦЕССОРУ: пик — 100 юзеров на ядро, но берём только
    #    ту долю, которая сейчас реально свободна
    local cpu_cores; cpu_cores=$(nproc 2>/dev/null || echo 1)
    local cpu_load; cpu_load=$(_cpu_load_percent)
    local max_users_cpu=$(( (cpu_cores * 100 * (100 - cpu_load)) / 100 ))

    # 4. Побеждает самое узкое место
    local hw_limit=$max_users_ram
    local hw_reason="RAM"
    if (( max_users_cpu < hw_limit )); then
        hw_limit=$max_users_cpu
        hw_reason="CPU"
    fi

    if (( net_limit < hw_limit )) && (( net_limit > 0 )); then
        echo "$net_limit"
        echo "канал"
    else
        echo "$hw_limit"
        echo "$hw_reason"
    fi
}

# --- Главная логика -------------------------------------------------------- #

# Склонение существительного по числу: 1 пользователь, 2 пользователя,
# 5 пользователей. Отчёт читают люди, и «102 пользователей» в официальном
# тоне выглядит опечаткой.
_users_word() {
    local n="$1"
    local n100=$((n % 100)) n10=$((n % 10))
    if (( n100 >= 11 && n100 <= 14 )); then
        echo "пользователей"
    elif (( n10 == 1 )); then
        echo "пользователь"
    elif (( n10 >= 2 && n10 <= 4 )); then
        echo "пользователя"
    else
        echo "пользователей"
    fi
}

run() {
    echo "===== ИЗМЕРЕНИЕ СКОРОСТИ И ВМЕСТИМОСТИ ====="

    if ! _ensure_speedtest; then
        echo "Измерение не выполнено."
        return 1
    fi

    local json
    json=$(speedtest --accept-license --accept-gdpr -f json 2>/dev/null)
    if [[ -z "$json" ]]; then
        echo "Speedtest не вернул данных: нет сети или сервер Ookla недоступен."
        return 1
    fi

    local ping dl_bytes ul_bytes
    ping=$(_json_num "$json" "ping" "latency")
    dl_bytes=$(_json_num "$json" "download" "bandwidth")
    ul_bytes=$(_json_num "$json" "upload" "bandwidth")

    if [[ -z "$ul_bytes" || ! "$ul_bytes" =~ ^[0-9]+$ ]]; then
        echo "Не удалось разобрать ответ Speedtest: измерение не засчитано."
        return 1
    fi

    # Ookla отдаёт байты в секунду, показываем мегабиты
    local dl_mbps ul_mbps
    dl_mbps=$(awk "BEGIN {printf \"%.2f\", ${dl_bytes:-0} * 8 / 1000000}")
    ul_mbps=$(awk "BEGIN {printf \"%.2f\", ${ul_bytes} * 8 / 1000000}")

    local capacity reason
    { read -r capacity; read -r reason; } < <(_calculate_capacity "$ul_mbps")

    if [[ -n "$ping" && "$ping" != "null" ]]; then
        LC_NUMERIC=C printf "Задержка:    %.2f мс\n" "$ping"
    fi
    echo "Приём:       ${dl_mbps} Мбит/с"
    echo "Передача:    ${ul_mbps} Мбит/с"
    echo "Вместимость: ${capacity} $(_users_word "$capacity") (ограничение: ${reason})"

    # Машиночитаемый хвост для modules/skynet/capacity.sh — строго последней
    # строкой и строго в этом формате.
    echo "CAPACITY_USERS=${capacity}"
}

run
