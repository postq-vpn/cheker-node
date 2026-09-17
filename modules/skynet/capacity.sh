#!/bin/bash
# ============================================================ #
# ==        SKYNET: ЗАМЕР ВМЕСТИМОСТИ ПО ВСЕМУ ФЛОТУ        == #
# ============================================================ #
#
# Запускает измерение (Ookla-спидтест + расчёт вместимости) сразу на всех
# серверах флота и складывает их вместимость в одно число — «Общую
# вместимость», которую потом показывает дашборд.
#
# Считаем только по серверам из базы флота: локальная машина в сумму не
# входит, её вместимость дашборд и так показывает отдельной строкой
# (LAST_VPN_CAPACITY, локальный замер в modules/local/local_care.sh).
#
#   ( РОДИТЕЛЬ | КЛАВИША | НАЗВАНИЕ | ФУНКЦИЯ | ПОРЯДОК | ГРУППА | ОПИСАНИЕ )
# @menu.manifest
#
# @item( skynet | p | ${C_GREEN}🏎️  Замер вместимости флота${C_RESET} | _skynet_capacity_fleet_test | 45 | 2 | Измерение скорости на всех серверах и расчёт общей вместимости. )
#

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1 # Защита от прямого запуска

# Модуль вызывается из меню флота, которое executor.sh уже подключило, но
# source идемпотентен — так модуль остаётся рабочим и при вызове напрямую
# через run_module.
source "${SCRIPT_DIR}/modules/skynet/executor.sh"

_SKYNET_CAPACITY_PLUGIN="${SCRIPT_DIR}/plugins/skynet_commands/diagnostics/05_speed_capacity.sh"

# Маркер последнего автозамера: "версия|идентификатор загрузки". Лежит в
# /etc/reshala, а не в конфиге, потому что обновление полностью пересоздаёт
# /opt/reshala вместе с config/reshala.conf — после обновления сравнивать
# версию было бы уже не с чем.
_CAPACITY_STATE_FILE="/etc/reshala/fleet_capacity.state"

# Склонение существительного по числу: 1 пользователь, 2 пользователя,
# 5 пользователей. Своя копия есть и в плагине: он уезжает на чужой сервер
# отдельным файлом и общий код подтянуть не может.
_skynet_capacity_users_word() {
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

# Гоняет плагин по всему флоту, складывает вместимость и сохраняет результат
# в конфиг. С --verbose печатает отчёт по каждому серверу (ручной запуск из
# меню), без него молчит — тем же кодом работает фоновый автозамер.
# Итог кладёт в _CAPACITY_SUM/_CAPACITY_OK/_CAPACITY_COUNT.
# Возвращает 1, если ни один сервер не ответил: перетирать прошлый результат
# нулём нельзя, дашборд показал бы «0 польз.» вместо последнего известного.
_skynet_capacity_run_fleet() {
    local verbose=0
    [[ "${1:-}" == "--verbose" ]] && verbose=1

    # Инфра-серверы (категория "infra") не считаются в вместимость флота -
    # это служебные машины, а не VPN-ноды, гонять по ним спидтест и складывать
    # результат в "Общую вместимость" смысла нет.
    local tmp_dir; tmp_dir=$(_skynet_run_plugin_on_fleet_parallel_capture "$_SKYNET_CAPACITY_PLUGIN" "" "fleet")
    local count; count=$(cat "${tmp_dir}/.count" 2>/dev/null || echo 0)

    # Шапку печатаем здесь, а не до запуска: замер идёт минуты, и заголовок
    # «РЕЗУЛЬТАТЫ» над пустым экраном всё это время выглядел бы как зависание.
    if [[ "$verbose" -eq 1 ]]; then
        echo ""
        print_separator "=" 60
        printf_info "РЕЗУЛЬТАТЫ ИЗМЕРЕНИЯ"
        print_separator "=" 60
    fi

    local sum=0 ok_count=0
    local idx name status capacity
    for ((idx = 1; idx <= count; idx++)); do
        name=$(cat "${tmp_dir}/${idx}.name" 2>/dev/null)
        status=$(cat "${tmp_dir}/${idx}.status" 2>/dev/null)
        [[ "$verbose" -eq 1 ]] && echo ""

        if [[ "$status" != "OK" ]]; then
            [[ "$verbose" -eq 1 ]] && printf "${C_RED}❌ %s — сервер недоступен${C_RESET}\n" "$name"
            continue
        fi

        # Плагин печатает человекочитаемый отчёт, а последней строкой -
        # машиночитаемое CAPACITY_USERS=<число>. Сумму собираем только по
        # ней: цифры из текста отчёта (скорость, пинг) в неё не попадут.
        capacity=$(grep -m1 '^CAPACITY_USERS=' "${tmp_dir}/${idx}.out" 2>/dev/null | cut -d'=' -f2)
        if [[ "$capacity" =~ ^[0-9]+$ ]]; then
            sum=$((sum + capacity))
            ok_count=$((ok_count + 1))
            [[ "$verbose" -eq 1 ]] && printf "${C_GREEN}✅ %s${C_RESET}\n" "$name"
        else
            [[ "$verbose" -eq 1 ]] && printf "${C_YELLOW}⚠️  %s — измерение не выполнено${C_RESET}\n" "$name"
        fi

        [[ "$verbose" -eq 1 ]] && grep -v '^CAPACITY_USERS=' "${tmp_dir}/${idx}.out" 2>/dev/null | sed 's/^/   /'
    done

    rm -rf "$tmp_dir"

    _CAPACITY_SUM="$sum"
    _CAPACITY_OK="$ok_count"
    _CAPACITY_COUNT="$count"
    _CAPACITY_STAMP=""

    [[ "$ok_count" -eq 0 ]] && return 1

    # Дата в формате без '|' и '/': set_config_var пишет значение через sed
    # с разделителем '|', а сам конфиг потом сорсится как shell-файл.
    # Время московское (msk_date): метку видно на дашборде рядом с числом,
    # и по часам сервера она разошлась бы с настенными часами пользователя —
    # у VPS это почти всегда UTC.
    _CAPACITY_STAMP=$(msk_date '+%d.%m %H:%M')
    set_config_var "FLEET_TOTAL_CAPACITY" "$sum"
    set_config_var "FLEET_CAPACITY_SERVERS" "${ok_count} из ${count}"
    set_config_var "FLEET_CAPACITY_DATE" "$_CAPACITY_STAMP"
    log "Замер флота: общая вместимость ${sum} $(_skynet_capacity_users_word "$sum") (${ok_count} из ${count} серверов)"
    return 0
}

_skynet_capacity_fleet_test() {
    clear
    menu_header "🏎️ Замер вместимости флота"
    printf_description "Измерение скорости Ookla на каждом сервере и расчёт допустимого числа пользователей."
    echo ""

    if [[ ! -s "$FLEET_DATABASE_FILE" ]]; then
        printf_error "База флота пуста. Добавьте серверы."
        wait_for_enter
        return
    fi

    if [[ ! -f "$_SKYNET_CAPACITY_PLUGIN" ]]; then
        printf_error "Плагин измерения не найден: ${_SKYNET_CAPACITY_PLUGIN}"
        wait_for_enter
        return
    fi

    if _skynet_capacity_is_running; then
        printf_warning "Фоновый замер уже идёт (запущен автоматически при старте Решалы)."
        printf_description "Дождитесь его окончания — результат появится на дашборде."
        wait_for_enter
        return
    fi

    local total; total=$(_skynet_fleet_count_by_category "fleet")
    local infra_n; infra_n=$(_skynet_fleet_count_by_category "infra")
    printf_warning "Измерение займёт несколько минут и создаст трафик на каждом из ${total} серверов."
    [[ "$infra_n" -gt 0 ]] && printf_description "Серверы категории «Инфра» (${infra_n}) в замер и в общую вместимость не входят."
    printf_description "На серверах без клиента Ookla он будет установлен автоматически."
    echo ""
    if ! ask_yes_no "Начать измерение? (y/n): " "n"; then
        return
    fi

    printf_info "Измерение запущено параллельно на ${total} серверах. Ожидание результатов..."

    if ! _skynet_capacity_run_fleet --verbose; then
        echo ""
        print_separator "=" 60
        printf_error "Ни один сервер не вернул результат. Общая вместимость не обновлена."
        wait_for_enter
        return
    fi

    echo ""
    print_separator "=" 60

    printf "\n%b💎 ОБЩАЯ ВМЕСТИМОСТЬ ФЛОТА:%b %b%s %s%b\n" \
        "${C_BOLD}" "${C_RESET}" "${C_GREEN}" "$_CAPACITY_SUM" "$(_skynet_capacity_users_word "$_CAPACITY_SUM")" "${C_RESET}"
    printf "   Результат получен с %s из %s серверов, измерение от %s\n" "$_CAPACITY_OK" "$_CAPACITY_COUNT" "$_CAPACITY_STAMP"
    echo "   Значение сохранено и отображается на дашборде."

    wait_for_enter
}

# ============================================================ #
#          АВТОЗАМЕР: ОБНОВЛЕНИЕ И ПЕРЕЗАГРУЗКА СЕРВЕРА        #
# ============================================================ #
#
# Замер запускается сам, но только на два события: сменилась версия Решалы
# (то есть было обновление) или сервер перезагрузился. Гонять многоминутный
# спидтест по всему флоту на КАЖДЫЙ вход в меню нельзя — Решалу открывают
# по десять раз в день, и каждый раз это трафик на всех серверах.

# Идентификатор текущей загрузки: boot_id ядро меняет на каждую перезагрузку.
# Если /proc недоступен — считаем момент старта системы из uptime с точностью
# до минуты, иначе дрожание uptime давало бы новый id на каждом запуске.
_skynet_capacity_boot_id() {
    if [[ -r /proc/sys/kernel/random/boot_id ]]; then
        cat /proc/sys/kernel/random/boot_id
        return
    fi
    local up; up=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)
    echo "boot-$(( ( $(date +%s) - up ) / 60 ))"
}

# Идёт ли фоновый замер прямо сейчас: в метке лежит PID, и он ещё жив.
# Осиротевшая метка (сервер выключили посреди замера) сама себя не блокирует.
_skynet_capacity_is_running() {
    local pid
    pid=$(cat "${FLEET_CAPACITY_RUN_FILE:-}" 2>/dev/null) || return 1
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

# Тело фонового замера: сюда попадает отдельный процесс, запущенный как
# `reshala.sh fleet-capacity` (см. точку входа). Меню не рисует, вывод — в лог.
_skynet_capacity_auto_run() {
    if [[ ! -s "$FLEET_DATABASE_FILE" || ! -f "$_SKYNET_CAPACITY_PLUGIN" ]]; then
        return 0
    fi
    if _skynet_capacity_is_running; then
        log "Автозамер флота: замер уже идёт, второй запуск пропущен."
        return 0
    fi

    echo "$$" > "$FLEET_CAPACITY_RUN_FILE"
    # Метку снимаем на любом выходе: иначе после падения замера дашборд
    # навсегда останется с «идёт замер», а ручной [p] будет считать себя занятым.
    trap 'rm -f "$FLEET_CAPACITY_RUN_FILE"' EXIT

    log "Автозамер флота ${VERSION}: старт в фоне."
    if _skynet_capacity_run_fleet; then
        return 0
    fi
    log "Автозамер флота: ни один сервер не вернул результат, значение не обновлено."
    return 1
}

# Решает, нужен ли автозамер, и запускает его в фоне. Вызывается из точки
# входа reshala.sh на каждом старте — поэтому все проверки дешёвые.
_skynet_capacity_auto_maybe_start() {
    [[ "$(get_config_var "FLEET_CAPACITY_AUTOTEST")" == "off" ]] && return 0
    # В режиме агента Решала работает на чужом сервере: своего флота у неё нет.
    [[ "${SKYNET_MODE:-0}" -eq 1 ]] && return 0
    [[ -s "$FLEET_DATABASE_FILE" ]] || return 0
    [[ -f "$_SKYNET_CAPACITY_PLUGIN" ]] || return 0
    _skynet_capacity_is_running && return 0

    local want; want="${VERSION}|$(_skynet_capacity_boot_id)"
    local have=""
    [[ -r "$_CAPACITY_STATE_FILE" ]] && have=$(cat "$_CAPACITY_STATE_FILE" 2>/dev/null)
    [[ "$want" == "$have" ]] && return 0

    # Маркер пишем ДО запуска: если замер упадёт (нет ключей, сервер в дауне),
    # он не должен стартовать заново на каждом входе в меню. Ручной запуск [p]
    # для этого случая никуда не делся.
    mkdir -p "$(dirname "$_CAPACITY_STATE_FILE")" 2>/dev/null || true
    echo "$want" > "$_CAPACITY_STATE_FILE"

    local exec_path="${SCRIPT_DIR}/reshala.sh"
    [[ -f "$exec_path" ]] || return 0

    # Отвязываем от терминала: замер идёт минуты, должен пережить выход из
    # меню, а его вывод не должен лезть поверх дашборда. Дашборд узнает о нём
    # по метке FLEET_CAPACITY_RUN_FILE и покажет «идёт замер».
    if command -v setsid >/dev/null 2>&1; then
        setsid nohup bash "$exec_path" fleet-capacity </dev/null >>"$LOGFILE" 2>&1 &
    else
        nohup bash "$exec_path" fleet-capacity </dev/null >>"$LOGFILE" 2>&1 &
    fi
    disown 2>/dev/null || true

    log "Автозамер флота: запущен в фоне (маркер ${want})."
}
