#!/bin/bash
# ============================================================ #
# ==             МОДУЛЬ ОБСЛУЖИВАНИЯ СИСТЕМЫ                == #
# ============================================================ #
#
# Этот модуль — механик. Он крутит гайки в локальной системе:
# обновляет пакеты, тюнингует сеть, меряет скорость.
#  ( РОДИТЕЛЬ | КЛАВИША | НАЗВАНИЕ | ФУНКЦИЯ | ПОРЯДОК | ГРУППА | ОПИСАНИЕ )
# @menu.manifest
#
# @item( main | 4 | 🔧 Сервисное меню ${C_YELLOW}(Обновления, сеть, тесты)${C_RESET} | show_maintenance_menu | 20 | 2 | Обновление системы, тюнинг сети и тесты производительности. )
#
# @item( local_care | 1 | 🔄 Обновить систему | _run_system_update | 10 | 1 | Запускает 'apt update && upgrade' с лечением EOL-ошибок. )
# @item( local_care | 2 | 🚀 Оптимизация сети (BBR + CAKE) | _apply_bbr | 20 | 1 | Применяет BBR + CAKE для максимальной производительности. )
# @item( local_care | 3 | 🌐 Управление IPv6 | _toggle_ipv6 | 30 | 1 | Полное включение или отключение поддержки IPv6. )
# @item( local_care | 4 | 💨 Тест скорости | _run_speedtest | 40 | 2 | Замеряет скорость до лучшего сервера (Ookla). )
# @item( local_care | 5 | ⚙️  Профиль нагрузки дашборда | _set_dashboard_profile_menu | 50 | 2 | Настройка частоты обновления данных на главной панели. )
#

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1 # Защита от прямого запуска

# ============================================================ #
#                  ФУНКЦИИ-ДЕЙСТВИЯ МЕНЮ                       #
# ============================================================ #

_get_net_status() {
    local cc; cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "n/a")
    local qdisc; qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "n/a")
    if [[ "$qdisc" == "pfifo_fast" ]]; then
        local tc_qdisc; tc_qdisc=$(tc qdisc show 2>/dev/null | grep -Eo 'cake|fq' | head -n1)
        [[ -n "$tc_qdisc" ]] && qdisc="$tc_qdisc"
    fi
    echo "${cc}|${qdisc}"
}

_apply_bbr() {
    log "Запуск тюнинга сети (BBR/CAKE)..."
    local net_status=$(_get_net_status); local current_cc=$(echo "$net_status"|cut -d'|' -f1); local current_qdisc=$(echo "$net_status"|cut -d'|' -f2)
    local cake_available; modprobe sch_cake &>/dev/null && cake_available="true" || cake_available="false"

    echo "--- ДИАГНОСТИКА СЕТЕВОГО СТЕКА ---"
    echo "Алгоритм: $current_cc"; echo "Планировщик: $current_qdisc"
    echo "------------------------------------"
    if [[ ("$current_cc" == "bbr" || "$current_cc" == "bbr2") && "$current_qdisc" == "cake" ]]; then
        printf_ok "Оптимальные настройки уже применены."
        wait_for_enter; return
    fi
    if ! ask_yes_no "Включить оптимизацию сети (BBR + CAKE)? (y/n): " "n"; then
        echo "Отменено."; return
    fi

    local preferred_cc="bbr"; [[ $(sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null) == *"bbr2"* ]] && preferred_cc="bbr2"
    local preferred_qdisc="fq"; [[ "$cake_available" == "true" ]] && preferred_qdisc="cake"
    
    local CONFIG_SYSCTL="/etc/sysctl.d/99-reshala-boost.conf"
    printf_info "✍️  Применяю новые настройки..."
    run_cmd tee "$CONFIG_SYSCTL" >/dev/null <<EOF
# === СЕТЕВАЯ ОПТИМИЗАЦИЯ РЕШАЛЫ — НЕ ИЗМЕНЯТЬ ===
net.core.default_qdisc = ${preferred_qdisc}
net.ipv4.tcp_congestion_control = ${preferred_cc}
net.ipv4.tcp_fastopen = 3
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
EOF
    printf_info "🔥 Применяю настройки..."
    run_cmd sysctl -p "$CONFIG_SYSCTL" >/dev/null
    printf_ok "Настройки применены. (CC: ${preferred_cc}, QDisc: ${preferred_qdisc})"
    wait_for_enter
}

_get_ipv6_status_string() {
    if [[ ! -d "/proc/sys/net/ipv6" ]]; then echo "${C_RED}ОТСУТСТВУЕТ${C_RESET}"
    elif [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" -eq 1 ]]; then echo "${C_RED}ОТКЛЮЧЁН${C_RESET}"
    else echo "${C_GREEN}ВКЛЮЧЁН${C_RESET}"; fi
}

_toggle_ipv6() {
    enable_graceful_ctrlc
    while true;
    do
        clear
        menu_header "Управление IPv6"
        printf_description "Текущий статус IPv6: $(_get_ipv6_status_string)"
        echo ""
        printf_menu_option "1" "Отключить IPv6"
        printf_menu_option "2" "Включить IPv6"
        echo ""
        printf_menu_option "b" "Назад"
        echo "--------------------------"
        local choice; choice=$(safe_read "Ваш выбор") || break
        case "$choice" in
            1) run_cmd tee /etc/sysctl.d/98-disable-ipv6.conf >/dev/null <<< "net.ipv6.conf.all.disable_ipv6 = 1"; run_cmd sysctl -p /etc/sysctl.d/98-disable-ipv6.conf >/dev/null; printf_ok "IPv6 отключён."; sleep 1 ;; 
            2) run_cmd rm -f /etc/sysctl.d/98-disable-ipv6.conf; run_cmd tee /etc/sysctl.d/98-enable-ipv6.conf >/dev/null <<< "net.ipv6.conf.all.disable_ipv6 = 0"; run_cmd sysctl -p /etc/sysctl.d/98-enable-ipv6.conf >/dev/null; run_cmd rm -f /etc/sysctl.d/98-enable-ipv6.conf; printf_ok "IPv6 включён."; sleep 1 ;; 
            [bB]) break ;; 
        esac
    done
    disable_graceful_ctrlc
}

_run_system_update() {
    if ! command -v apt-get &>/dev/null; then printf_error "Система не Debian/Ubuntu: обновление недоступно."; return; fi
    clear
    printf_info "ОБНОВЛЕНИЕ И ВОССТАНОВЛЕНИЕ СИСТЕМЫ"
    echo "1. Проверка подключения к интернету."
    echo "2. Стандартный 'apt update'."
    echo "3. При ошибке 404 (EOL) — переключение на архивные репозитории."
    echo "---------------------------------------------------------------------"

    printf "[*] Проверяю сетевое подключение... "; if ! curl -s --connect-timeout 3 google.com >/dev/null; then err "Нет соединения!"; printf_error "Проверьте DNS и сетевое подключение."; return; fi; ok "Соединение установлено."

    # Превентивная чистка битого репозитория Ookla (из-за которого ломается apt на Ubuntu 24.04)
    rm -f /etc/apt/sources.list.d/ookla_speedtest-cli.list /etc/apt/sources.list.d/ookla_speedtest-cli.list.save

    printf_info "[*] Попытка стандартного обновления (apt update)..."
    if run_cmd apt-get update; then
        printf_ok "Официальные зеркала доступны. Запускаю полное обновление..."
        run_cmd apt-get upgrade -y; run_cmd apt-get full-upgrade -y; run_cmd apt-get autoremove -y; run_cmd apt-get autoclean -y
        printf_ok "Система полностью обновлена."; log "Обновление системы (Standard) успешно."
    else
        printf_error "ОШИБКА ОБНОВЛЕНИЯ! Версия ОС снята с поддержки (EOL)."
        if ask_yes_no "Переключиться на архивные репозитории? (y/n): " "n"; then
            log "Запуск процедуры EOL Fix..."
            local backup_dir="/var/backups/reshala_apt_$(date +%F)"
            printf_info "Делаю бэкап конфигов в ${backup_dir}..." ; run_cmd mkdir -p "$backup_dir"; run_cmd cp /etc/apt/sources.list "$backup_dir/"
            printf_info "🔧 Исправляю адреса серверов..."; run_cmd sed -i -r 's/([a-z]{2}\.)?archive.ubuntu.com/old-releases.ubuntu.com/g' /etc/apt/sources.list; run_cmd sed -i -r 's/security.ubuntu.com/old-releases.ubuntu.com/g' /etc/apt/sources.list
            printf_info "Пробую обновиться снова с архивных репозиториев..."
            if run_cmd apt-get update;
            then
                printf_ok "Архивные репозитории доступны. Запускаю полное обновление..."; run_cmd apt-get upgrade -y; run_cmd apt-get full-upgrade -y; run_cmd apt-get autoremove -y; run_cmd apt-get autoclean -y;
                printf_ok "EOL Fix выполнен, система обновлена."; log "Обновление системы (EOL fix) успешно завершено."
            else
                printf_error "Не удалось. Восстанавливаю резервную копию."; run_cmd cp "$backup_dir/sources.list" /etc/apt/; log "Обновление после EOL fix не удалось."
            fi
        fi
    fi
    wait_for_enter
}

_process_and_display_speed_results() { local dl_mbps="$1"; local ul_mbps="$2"; local ping_ms="$3"; local url="$4"; echo "══════════════════════════════════════════════════"; if [[ -n "$ping_ms" ]]; then LC_NUMERIC=C printf "   %bЗАДЕРЖКА:%b  %.2f мс\n" "${C_GRAY}" "${C_RESET}" "$ping_ms"; fi; printf "   %bПРИЁМ:%b     %s Мбит/с\n" "${C_GREEN}" "${C_RESET}" "$dl_mbps"; printf "   %bПЕРЕДАЧА:%b  %s Мбит/с\n" "${C_CYAN}" "${C_RESET}" "$ul_mbps"; echo "══════════════════════════════════════════════════"; if [[ -n "$url" ]]; then echo "   🔗 Ссылка на результат: $url"; fi; log "Speedtest: DL=${dl_mbps}, UL=${ul_mbps}, Ping=${ping_ms:-N/A}"; local clean_ul_int; clean_ul_int=$(echo "$ul_mbps" | cut -d'.' -f1); if [[ "$clean_ul_int" =~ ^[0-9]+$ ]] && [ "$clean_ul_int" -gt 0 ]; then local capacity; capacity=$(_calculate_vpn_capacity "$ul_mbps"); set_config_var "LAST_UPLOAD_SPEED" "$clean_ul_int"; set_config_var "LAST_VPN_CAPACITY" "$capacity"; printf "\n%b💎 РАСЧЁТ ВМЕСТИМОСТИ:%b\n" "${C_BOLD}" "${C_RESET}"; printf "   Расчётная вместимость сервера, польз.: %b%s%b\n" "${C_GREEN}" "$capacity" "${C_RESET}"; echo "   Результат сохранён для главного меню и дашборда."; fi; }
_get_cpu_load_percent() {
    local cpu_line1 cpu_line2
    cpu_line1=$(grep '^cpu ' /proc/stat)
    sleep 0.2
    cpu_line2=$(grep '^cpu ' /proc/stat)

    if [[ -z "$cpu_line1" || -z "$cpu_line2" ]]; then
        echo "100" # Assume 100% load on error
        return
    fi

    local _ user1 nice1 system1 idle1 iowait1 irq1 softirq1 steal1 guest1 guest_nice1
    read -r _ user1 nice1 system1 idle1 iowait1 irq1 softirq1 steal1 guest1 guest_nice1 <<<"$cpu_line1"
    user1=${user1:-0}; nice1=${nice1:-0}; system1=${system1:-0}; idle1=${idle1:-0}; iowait1=${iowait1:-0}; irq1=${irq1:-0}; softirq1=${softirq1:-0}; steal1=${steal1:-0}; guest1=${guest1:-0}; guest_nice1=${guest_nice1:-0}

    local user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2 guest2 guest_nice2
    read -r _ user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2 guest2 guest_nice2 <<<"$cpu_line2"
    user2=${user2:-0}; nice2=${nice2:-0}; system2=${system2:-0}; idle2=${idle2:-0}; iowait2=${iowait2:-0}; irq2=${irq2:-0}; softirq2=${softirq2:-0}; steal2=${steal2:-0}; guest2=${guest2:-0}; guest_nice2=${guest_nice2:-0}

    local idle_all1=$((idle1 + iowait1))
    local idle_all2=$((idle2 + iowait2))
    local non_idle1=$((user1 + nice1 + system1 + irq1 + softirq1 + steal1))
    local non_idle2=$((user2 + nice2 + system2 + irq2 + softirq2 + steal2))
    local total1=$((idle_all1 + non_idle1))
    local total2=$((idle_all2 + non_idle2))

    local total_delta=$((total2 - total1))
    local idle_delta=$((idle_all2 - idle_all1))

    local perc=0
    if (( total_delta > 0 )); then
        perc=$(awk "BEGIN {printf \"%.0f\", (1 - $idle_delta / $total_delta) * 100}")
    fi

    if [[ "$perc" -lt 0 ]]; then perc=0; fi
    if [[ "$perc" -gt 100 ]]; then perc=100; fi
    echo "$perc"
}

_calculate_vpn_capacity() {
    local upload_speed="$1"

    printf_info "Считаю вместимость по каналу, памяти и процессору..." >&2

    # 1. Лимит по КАНАЛУ (4 Мбит/с на юзера, 80% от канала)
    local net_limit=0
    if [[ -n "$upload_speed" ]]; then
        local clean_speed=${upload_speed%.*}
        net_limit=$(awk -v speed="$clean_speed" 'BEGIN {printf "%.0f", (speed * 0.8) / 4}')
    fi
    
    # 2. Лимит по ПАМЯТИ (на основе доступной, а не общей)
    local available_ram
    available_ram=$(free -m | awk '/^Mem/ {print $7}') # $7 is "available"
    local ram_for_users=$((available_ram - 250)) # Резерв 250МБ
    if (( ram_for_users < 0 )); then ram_for_users=0; fi
    local max_users_ram=$((ram_for_users / 5)) # 5МБ на юзера

    # 3. Лимит по ПРОЦЕССОРУ (на основе свободной мощности)
    local cpu_cores; cpu_cores=$(nproc);
    local cpu_load_perc; cpu_load_perc=$(_get_cpu_load_percent)
    local free_cpu_perc=$((100 - cpu_load_perc))
    local max_users_cpu_total=$((cpu_cores * 100)) # 100 юзеров на ядро - это пик
    local max_users_cpu=$(( (max_users_cpu_total * free_cpu_perc) / 100 ))

    # 4. Выбираем самое узкое место
    local hw_limit=$max_users_ram
    local hw_reason="RAM"
    if (( max_users_cpu < hw_limit )); then
        hw_limit=$max_users_cpu
        hw_reason="CPU"
    fi

    if [[ "$net_limit" -lt "$hw_limit" ]] && [[ "$net_limit" -gt 0 ]]; then
        echo "$net_limit (ограничение: канал)"
    else
        echo "$hw_limit (ограничение: $hw_reason)"
    fi
}
_ensure_speedtest_ok() { 
    if command -v speedtest &>/dev/null && [[ "$(speedtest --version 2>/dev/null)" == *"Ookla"* ]]; then 
        return 0; 
    fi; 
    
    info "Готовлю систему к установке Speedtest (прямая загрузка)..."
    ensure_package "curl" "ca-certificates" "tar"
    
    # Полностью вырезаем старые битые репозитории Ookla, если они остались от прошлых попыток
    rm -f /etc/apt/sources.list.d/ookla_speedtest-cli.list*
    
    local arch; arch=$(uname -m)
    local url1=""
    local url2=""
    # Суммы архивов версии 1.2.0 с сайта Ookla: зеркало чужое, а бинарник
    # запускается от root. Те же суммы - в плагине 05_speed_capacity.sh.
    local tgz_sha256=""
    case "$arch" in 
        x86_64) 
            url1="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz" 
            url2="https://dl.lamp.sh/files/ookla-speedtest-1.2.0-linux-x86_64.tgz"
            tgz_sha256="5690596c54ff9bed63fa3732f818a05dbc2db19ad36ed68f21ca5f64d5cfeeb7"
            ;; 
        aarch64) 
            url1="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz" 
            url2="https://dl.lamp.sh/files/ookla-speedtest-1.2.0-linux-aarch64.tgz"
            tgz_sha256="3953d231da3783e2bf8904b6dd72767c5c6e533e163d3742fd0437affa431bd3"
            ;; 
        *) err "Неизвестная архитектура: $arch."; return 1;; 
    esac
    
    info "Качаю официальный бинарник для $arch..."
    
    local work_dir; work_dir=$(mktemp -d) || return 1
    local tgz="${work_dir}/speedtest.tgz"

    # Сначала пробуем офф сайт, если он заблокирован (например в РФ) - используем резервное зеркало (lamp.sh)
    if ! curl -fsL "$url1" -o "$tgz" || [[ "$(sha256sum "$tgz" | cut -d' ' -f1)" != "$tgz_sha256" ]]; then
        warn "Официальный сайт недоступен. Пробую резервное зеркало (lamp.sh)..."
        if ! curl -fsL "$url2" -o "$tgz" || [[ "$(sha256sum "$tgz" | cut -d' ' -f1)" != "$tgz_sha256" ]]; then
            rm -rf "$work_dir"
            err "Не удалось скачать архив: источники недоступны или контрольная сумма не совпала."
            return 1
        fi
    fi
    
    info "Распаковываю и устанавливаю..."
    if ! tar -xzf "$tgz" -C "$work_dir" speedtest 2>/dev/null || [[ ! -f "${work_dir}/speedtest" ]]; then
        rm -rf "$work_dir"
        err "Архив Speedtest повреждён: исполняемый файл не найден."
        return 1
    fi
    mv "${work_dir}/speedtest" /usr/local/bin/
    chmod +x /usr/local/bin/speedtest
    rm -rf "$work_dir"
    
    if command -v speedtest &>/dev/null; then 
        ok "Speedtest успешно установлен."
        return 0
    else 
        err "Ошибка при установке бинарника."
        return 1
    fi
}

# Запускает внешний bench-скрипт. Страница ошибки вместо скрипта запускаться
# не должна.
_run_remote_bench() {
    local url="$1" script
    echo "Загрузка скрипта..."
    if ! script=$(wget -qO- "$url") || [[ -z "$script" || "$script" == "<"* ]]; then
        err "Не удалось скачать скрипт: ${url}"
        wait_for_enter
        return 1
    fi
    bash <<< "$script"
}

_run_speedtest() {
    enable_graceful_ctrlc
    while true; do
        clear
        menu_header "🚀 Центр тестирования сети"
        printf_description "Интеллектуальный выбор тестовых серверов."
        echo ""
        
        printf_menu_option "1" "🏎️  Измерение скорости и вместимости (Ookla)"
        printf_description "Выбирает ближайший сервер и рассчитывает VPN-вместимость."
        
        echo -e "\n  ${C_CYAN}🌍 Зарубежные провайдеры (Global):${C_RESET}"
        printf_menu_option "2" "Классический Bench.sh (Диск + Сеть по миру)"
        printf_menu_option "3" "speed.tlab.pw (Оптимизирован для Европы)"
        
        echo -e "\n  ${C_CYAN}🇷🇺 Российские провайдеры (RU/CIS):${C_RESET}"
        printf_menu_option "4" "bench.gig.ovh (Российские локации)"
        printf_menu_option "5" "bench.tlab.pw (СНГ локации)"
        
        echo ""
        printf_menu_option "b" "🔙 Назад"
        echo ""
        
        local choice
        choice=$(safe_read "Ваш выбор" "") || break
        
        case "$choice" in
            1)
                clear
                menu_header "🏎️ Измерение скорости и вместимости"
                if ! _ensure_speedtest_ok; then wait_for_enter; continue; fi
                info "Используем универсальный тест Ookla с автовыбором сервера."
                printf_critical_warning "Идёт измерение, не прерывайте процесс..."
                printf_warning "Анализирую результат..."
                local json_output; json_output=$(speedtest --accept-license --accept-gdpr -f json 2>/dev/null)
                if [[ -n "$json_output" ]] && echo "$json_output" | jq -e . >/dev/null 2>&1; then
                    local ping; ping=$(echo "$json_output" | jq -r '.ping.latency')
                    local dl_bytes; dl_bytes=$(echo "$json_output" | jq -r '.download.bandwidth')
                    local ul_bytes; ul_bytes=$(echo "$json_output" | jq -r '.upload.bandwidth')
                    local url; url=$(echo "$json_output" | jq -r '.result.url')
                    local dl_mbps; dl_mbps=$(awk "BEGIN {printf \"%.2f\", $dl_bytes * 8 / 1000000}")
                    local ul_mbps; ul_mbps=$(awk "BEGIN {printf \"%.2f\", $ul_bytes * 8 / 1000000}")
                    _process_and_display_speed_results "$dl_mbps" "$ul_mbps" "$ping" "$url"
                else
                    err "Speedtest не вернул корректных данных."
                fi
                wait_for_enter
                ;;
            2)
                # Внешние bench-скрипты сами показывают паузу в конце — не дублируем wait_for_enter
                clear; menu_header "🌍 Запуск Bench.sh"; _run_remote_bench "bench.sh" ;;
            3)
                clear; menu_header "🌍 Запуск speed.tlab.pw"; _run_remote_bench "speed.tlab.pw" ;;
            4)
                clear; menu_header "🇷🇺 Запуск bench.gig.ovh"; _run_remote_bench "bench.gig.ovh" ;;
            5)
                clear; menu_header "🇷🇺 Запуск bench.tlab.pw"; _run_remote_bench "bench.tlab.pw" ;;
            [bB]) break ;;
            *) err "Неверный выбор."; sleep 1 ;;
        esac
    done
    disable_graceful_ctrlc
}
_set_dashboard_profile_menu() { enable_graceful_ctrlc; while true; do clear; menu_header "Профиль нагрузки дашборда"; printf_description "Настройка частоты обновления дашборда."; echo; local current; current=$(get_config_var "DASHBOARD_LOAD_PROFILE" "normal"); local mark_normal=" "; local mark_light=" "; local mark_ultra=" "; case "$current" in normal) mark_normal="*";; light) mark_light="*";; ultra_light) mark_ultra="*";; esac; printf_menu_option "1" "NORMAL ($mark_normal)"; printf_description "     - Стандартный режим (база: 25/60 сек)"; printf_menu_option "2" "LIGHT ($mark_light)"; printf_description "     - Реже обновление (x2, ~50/120 сек)"; printf_menu_option "3" "ULTRA_LIGHT ($mark_ultra)"; printf_description "     - Минимальная нагрузка (x4, ~100/240 сек)"; echo ""; printf_menu_option "b" "Назад"; echo "------------------------------------------------------"; local choice; choice=$(safe_read "Ваш выбор: " "") || break; case "$choice" in 1) set_config_var "DASHBOARD_LOAD_PROFILE" "normal"; ok "Профиль дашборда: NORMAL."; sleep 1;; 2) set_config_var "DASHBOARD_LOAD_PROFILE" "light"; ok "Профиль дашборда: LIGHT."; sleep 1;; 3) set_config_var "DASHBOARD_LOAD_PROFILE" "ultra_light"; ok "Профиль дашборда: ULTRA_LIGHT."; sleep 1;; [bB]) break;; *) err "Нет такого пункта.";; esac; done; disable_graceful_ctrlc; }

# ============================================================ #
#                ГЛАВНОЕ МЕНЮ ОБСЛУЖИВАНИЯ                     #
# ============================================================ #
show_maintenance_menu() {
    enable_graceful_ctrlc
    while true;
    do
        clear
        menu_header "🔧 Сервисное обслуживание"
        printf_description "Обновление системы, тюнинг сети и тесты производительности."
        echo ""

        render_menu_items "local_care"

        echo ""
        printf_menu_option "b" "🔙 Назад"
        print_separator "-" 60
        
        local choice; choice=$(safe_read "Ваш выбор: " "") || break
        if [[ "$choice" == "b" || "$choice" == "B" ]]; then break; fi

        local action; action=$(get_menu_action "local_care" "$choice")
        if [[ -n "$action" ]]; then
            # Действия из этого же файла, можно вызывать напрямую
            $action
        else
            warn "Неверный выбор"
        fi
    done
    disable_graceful_ctrlc
}