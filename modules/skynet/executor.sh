#!/bin/bash
# ============================================================ #
# ==             SKYNET: ИСПОЛНЕНИЕ КОМАНД (EXECUTOR)       == #
# ============================================================ #
#
# Модуль отвечает за доставку и запуск плагинов на удаленных
# серверах через SSH.
#
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1 # Защита от прямого запуска

# Нужен для _skynet_norm_category/_skynet_category_label (фильтрация по
# категории при обходе флота). Модуль подключается и напрямую через
# run_module (например фоновый замер вместимости), где menu.sh не sourced -
# поэтому зависимость объявляется здесь явно, а не полагается на чужой source.
source "${SCRIPT_DIR}/modules/skynet/db.sh"

# Выполнить выбранный плагин Skynet на одном сервере
_skynet_run_plugin_on_server() {
    local plugin="$1" name="$2" user="$3" ip="$4" port="$5" key_path="$6" sudo_pass="${7:-}"
    printf "\n"; warn "--- Сервер: $name ---"

    local ssh_opts=(-P "$port" -F /dev/null -o IdentitiesOnly=yes -i "$key_path" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

    # Копируем плагин на удалённую машину. Ключ хоста заранее НЕ лечим:
    # StrictHostKeyChecking=accept-new всё равно отклонит подключение, если
    # ИЗМЕНИВШИЙСЯ ключ уже есть в known_hosts (защита от MITM), а
    # безусловное "лечение" перед каждым запуском стирало бы эту защиту
    # на каждой команде. Если первая попытка упала - явно спрашиваем
    # подтверждение fingerprint (см. keys.sh), а не лечим молча.
    if ! scp -q "${ssh_opts[@]}" "$plugin" "${user}@${ip}:/tmp/reshala_plugin.sh" < /dev/null; then
        if ! _skynet_confirm_and_pin_host_key "$ip" "$port"; then
            err "Пропускаю сервер $name."
            return 1
        fi
        if ! scp -q "${ssh_opts[@]}" "$plugin" "${user}@${ip}:/tmp/reshala_plugin.sh" < /dev/null; then
            err "Не удалось скопировать плагин на $name (timeout/access)."
            return 1
        fi
    fi

    local run_cmd="bash /tmp/reshala_plugin.sh; rm -f /tmp/reshala_plugin.sh"

    # Если пользователь не root и есть пароль, используем sudo.
    # Пароль передаётся через stdin ssh-канала, а не вклеивается в текст
    # команды: так он не попадает в командную строку (не виден в `ps` на
    # удалённом сервере) и спецсимволы в пароле не могут разорвать кавычки
    # и выполнить произвольный код.
    # ВАЖНО: явный stdin (</dev/null или heredoc) обязателен на КАЖДОЙ ветке.
    # Эта функция вызывается внутри `while read ... done < "$FLEET_DATABASE_FILE"`
    # (см. _run_fleet_command) - без redirect ssh наследует fd 0 цикла и
    # "съедает" из него оставшиеся строки базы флота, из-за чего обработка
    # обрывается после первого же сервера.
    if [[ "$user" != "root" && -n "$sudo_pass" ]]; then
        local quoted_run_cmd; printf -v quoted_run_cmd '%q' "$run_cmd"
        ssh -t "${ssh_opts[@]/#-P/-p}" "${user}@${ip}" "sudo -S -p '' bash -c ${quoted_run_cmd}" <<< "$sudo_pass"
    else
        ssh -t "${ssh_opts[@]/#-P/-p}" "${user}@${ip}" "$run_cmd" < /dev/null
    fi
}

# Запуск плагина Skynet на ОДНОМ сервере с дополнительными переменными окружения
_skynet_run_plugin_on_server_with_env() {
    local plugin="$1" env_vars="$2" name="$3" user="$4" ip="$5" port="$6" key_path="$7" sudo_pass="${8:-}"
    printf "\n"; warn "--- Сервер: $name ---"

    local ssh_opts=(-P "$port" -F /dev/null -o IdentitiesOnly=yes -i "$key_path" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

    # Копируем плагин. См. комментарий в _skynet_run_plugin_on_server: при
    # сбое явно спрашиваем подтверждение fingerprint, а не лечим молча.
    if ! scp -q "${ssh_opts[@]}" "$plugin" "${user}@${ip}:/tmp/reshala_plugin.sh" < /dev/null; then
        if ! _skynet_confirm_and_pin_host_key "$ip" "$port"; then
            err "Пропускаю сервер $name."
            return 1
        fi
        if ! scp -q "${ssh_opts[@]}" "$plugin" "${user}@${ip}:/tmp/reshala_plugin.sh" < /dev/null; then
            err "Не удалось скопировать плагин на $name (timeout/access)."
            return 1
        fi
    fi

    # env_vars – это строка наподобие "VAR1=val1 VAR2=val2"
    local run_cmd="${env_vars} bash /tmp/reshala_plugin.sh; rm -f /tmp/reshala_plugin.sh"

    # См. комментарии в _skynet_run_plugin_on_server: пароль идёт через stdin
    # ssh-канала, а явный stdin (</dev/null или heredoc) обязателен на КАЖДОЙ
    # ветке, иначе ssh съедает fd 0 цикла по флоту и обрывает обработку
    # после первого сервера.
    if [[ "$user" != "root" && -n "$sudo_pass" ]]; then
        local quoted_run_cmd; printf -v quoted_run_cmd '%q' "$run_cmd"
        ssh -t "${ssh_opts[@]/#-P/-p}" "${user}@${ip}" "sudo -S -p '' bash -c ${quoted_run_cmd}" <<< "$sudo_pass"
    else
        ssh -t "${ssh_opts[@]/#-P/-p}" "${user}@${ip}" "$run_cmd" < /dev/null
    fi
}

# Запуск плагина Skynet для захвата вывода (без TTY и без лишних сообщений)
_skynet_run_plugin_for_capture() {
    local plugin="$1"
    local env_vars="$2"
    local name="$3"
    local user="$4"
    local ip="$5"
    local port="$6"
    local key_path="$7"
    local sudo_pass="${8:-}"
    local temp_plugin_path="/tmp/reshala_plugin_$$_${RANDOM}"

    # Копируем плагин. Явный stdin (</dev/null) - см. комментарий в
    # _skynet_run_plugin_on_server: эту функцию тоже вызывают из циклов
    # `while read ... done < "$FLEET_DATABASE_FILE"` (например, из
    # ежедневного отчёта CensorCheck), и ssh/scp не должны отжирать fd 0 цикла.
    if ! scp -q -P "$port" -F /dev/null -o IdentitiesOnly=yes -i "$key_path" -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes "$plugin" "${user}@${ip}:${temp_plugin_path}" < /dev/null 2>/dev/null; then
        # Не выводим ошибку, просто возвращаем пустоту, т.к. это может быть простая недоступность хоста
        return 1
    fi

    local run_cmd="${env_vars} bash ${temp_plugin_path}; rm -f ${temp_plugin_path}"

    # Выполняем и захватываем вывод. Без -t для чистого вывода.
    # Пароль (если нужен sudo) - через stdin, см. _skynet_run_plugin_on_server.
    local output
    if [[ "$user" != "root" && -n "$sudo_pass" ]]; then
        local quoted_run_cmd; printf -v quoted_run_cmd '%q' "$run_cmd"
        output=$(ssh -p "$port" -F /dev/null -o IdentitiesOnly=yes -i "$key_path" -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes "${user}@${ip}" "sudo -S -p '' bash -c ${quoted_run_cmd}" <<< "$sudo_pass" 2>/dev/null)
    else
        output=$(ssh -p "$port" -F /dev/null -o IdentitiesOnly=yes -i "$key_path" -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes "${user}@${ip}" "$run_cmd" < /dev/null 2>/dev/null)
    fi

    echo "$output"
}

# Запускает плагин на ВСЕХ серверах флота ПАРАЛЛЕЛЬНО (в фоне) и складывает
# результаты в файлы внутри временной директории, путь к которой печатает
# в stdout (единственная строка вывода). На каждый обработанный сервер N:
#   <tmp_dir>/N.name   - "Имя (IP)"
#   <tmp_dir>/N.status - "OK" | "FAIL"
#   <tmp_dir>/N.out    - захваченный вывод плагина (только если OK)
# <tmp_dir>/.count     - общее количество серверов N
# Вызывающая сторона сама решает, как показать результаты, и должна
# удалить tmp_dir после использования.
_skynet_run_plugin_on_fleet_parallel_capture() {
    local plugin="$1"
    local env_vars="${2:-}"
    # Необязательный фильтр по категории ("fleet" | "infra"). Пусто - берём
    # весь флот, как раньше. Нужен там, где категория меняет сам состав
    # выборки (например замер вместимости не должен трогать инфру), а не
    # только отображение результата.
    local category_filter="${3:-}"
    local tmp_dir; tmp_dir=$(mktemp -d)

    # Читаем базу флота СРАЗУ в массив, а не в while-read с фоновыми ssh
    # внутри цикла - иначе параллельные джобы будут бороться за общий fd 0
    # цикла чтения (см. комментарии в _skynet_run_plugin_on_server).
    local -a lines=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && lines+=("$line")
    done < "$FLEET_DATABASE_FILE"

    local -a pids=()
    local i=0 name user ip port key_path sudo_pass category
    for line in "${lines[@]}"; do
        IFS='|' read -r name user ip port key_path sudo_pass category <<< "$line"
        [[ -z "$name" ]] && continue
        category=$(_skynet_norm_category "$category")
        if [[ -n "$category_filter" && "$category" != "$category_filter" ]]; then
            continue
        fi
        i=$((i + 1))
        echo "${name} (${ip})" > "${tmp_dir}/${i}.name"
        (
            local out
            out=$(_skynet_run_plugin_for_capture "$plugin" "$env_vars" "$name" "$user" "$ip" "$port" "$key_path" "$sudo_pass")
            if [[ -z "$out" ]]; then
                echo "FAIL" > "${tmp_dir}/${i}.status"
            else
                printf '%s' "$out" > "${tmp_dir}/${i}.out"
                echo "OK" > "${tmp_dir}/${i}.status"
            fi
        ) &
        pids+=("$!")
    done

    if [[ ${#pids[@]} -gt 0 ]]; then
        wait "${pids[@]}" 2>/dev/null
    fi

    echo "$i" > "${tmp_dir}/.count"
    echo "$tmp_dir"
}

# Запускает плагин на всём флоте параллельно (см. выше) и печатает
# результаты одним списком после завершения всех серверов.
_skynet_run_plugin_on_fleet_parallel() {
    local plugin="$1"

    if [[ ! -s "$FLEET_DATABASE_FILE" ]]; then
        printf_warning "База флота пуста."
        return 1
    fi

    local total; total=$(grep -c . "$FLEET_DATABASE_FILE" 2>/dev/null || echo 0)
    printf_info "Команда '${plugin##*/}' запущена параллельно на ${total} серверах. Ожидание завершения..."

    local tmp_dir; tmp_dir=$(_skynet_run_plugin_on_fleet_parallel_capture "$plugin")
    local count; count=$(cat "${tmp_dir}/.count" 2>/dev/null || echo 0)

    echo ""
    print_separator "=" 60
    printf_info "РЕЗУЛЬТАТЫ: ${plugin##*/}"
    print_separator "=" 60

    local idx status name
    for ((idx = 1; idx <= count; idx++)); do
        name=$(cat "${tmp_dir}/${idx}.name" 2>/dev/null)
        status=$(cat "${tmp_dir}/${idx}.status" 2>/dev/null)
        echo ""
        if [[ "$status" == "OK" ]]; then
            printf "${C_GREEN}✅ %s${C_RESET}\n" "$name"
            sed 's/^/   /' "${tmp_dir}/${idx}.out" 2>/dev/null
        else
            printf "${C_RED}❌ %s — сервер недоступен${C_RESET}\n" "$name"
        fi
    done
    echo ""
    print_separator "=" 60

    rm -rf "$tmp_dir"
}

# Переводит имя цвета из заголовка плагина (# SKYNET_COLOR: yellow) в код
# из common.sh. Список закрытый: заголовок плагина — это просто текст из
# файла, и он не должен уметь выполнить что-то своё.
_skynet_plugin_color() {
    local name="${1,,}"
    case "$name" in
        yellow)          printf '%s' "${C_YELLOW}" ;;
        green)           printf '%s' "${C_GREEN}" ;;
        cyan)            printf '%s' "${C_CYAN}" ;;
        red)             printf '%s' "${C_RED}" ;;
        blue)            printf '%s' "${C_BLUE}" ;;
        magenta|purple)  printf '%s' "${C_MAGENTA}" ;;
        gray|grey)       printf '%s' "${C_GRAY}" ;;
        bold)            printf '%s' "${C_BOLD}" ;;
        *)               printf '' ;; # пусто = цвет меню по умолчанию
    esac
}

_run_fleet_command() {
    local PLUGINS_DIR="${SCRIPT_DIR}/plugins/skynet_commands"
    if [[ ! -d "$PLUGINS_DIR" || -z "$(find "$PLUGINS_DIR" -type f -name '*.sh')" ]]; then
        printf_error "Папка с плагинами пуста или не существует (${PLUGINS_DIR})"; return
    fi
    
    enable_graceful_ctrlc
    while true; do
        clear; menu_header "☢️ Выполнение команды на флоте"
        
        # FIX: Use local -A to ensure arrays are reset on each loop iteration.
        # FIX: Aggressively unset arrays to prevent duplication bug.
        unset categories
        unset plugin_paths
        unset plugin_colors

        local -A categories
        local -A plugin_paths
        local -A plugin_colors
        local total_plugins=0

        # Находим все плагины и разбираем их по категориям
        while IFS= read -r p; do
            if [[ -f "$p" ]]; then
                local hidden
                hidden=$(grep -m1 '^# SKYNET_HIDDEN:' "$p" 2>/dev/null | sed 's/^# SKYNET_HIDDEN:[[:space:]]*//')
                if [[ "$hidden" == "true" || "$hidden" == "1" ]]; then
                    continue
                fi

                local category
                category=$(basename "$(dirname "$p")")
                if [[ "$category" == "skynet_commands" ]]; then
                    category="Общие"
                fi
                
                local title
                title=$(grep -m1 '^# TITLE:' "$p" 2>/dev/null | sed 's/^# TITLE:[[:space:]]*//')
                if [[ -z "$title" ]]; then
                    title="$(basename "$p" | sed 's/^[0-9]*_//;s/.sh$//')"
                fi
                
                # Цвет пункта храним отдельным массивом, а не третьим полем в
                # строке категории: она разбирается через IFS и лишнее поле
                # там уже не отличить от текста заголовка.
                local color_name
                color_name=$(grep -m1 '^# SKYNET_COLOR:' "$p" 2>/dev/null | sed 's/^# SKYNET_COLOR:[[:space:]]*//')

                total_plugins=$((total_plugins + 1))
                categories["$category"]+="${total_plugins}:::${title}\n"
                plugin_paths["$total_plugins"]="$p"
                plugin_colors["$total_plugins"]=$(_skynet_plugin_color "$color_name")
            fi
        done < <(find "$PLUGINS_DIR" -type f -name '*.sh' | sort)

        if [[ "$total_plugins" -eq 0 ]]; then
            printf_warning "Не найдено ни одной видимой команды в ${PLUGINS_DIR}"; wait_for_enter; break
        fi

        # Выводим сгруппированное меню
        local sorted_categories
        sorted_categories=$(for category in "${!categories[@]}"; do echo "$category"; done | sort)

        for category in $sorted_categories; do
            print_section_title "${category^}"
            
            local sorted_plugins
            sorted_plugins=$(echo -e "${categories[$category]}" | sort -n)
            
            while IFS=":::" read -r idx title; do
                if [[ -n "$idx" && -n "$title" ]]; then
                    # FIX: Defensively remove '::' from title before printing, as its source is unclear.
                    local clean_title
                    clean_title=$(echo "$title" | sed 's/::\s*//g')
                    # Пустой цвет printf_menu_option трактует как "по умолчанию"
                    printf_menu_option "$idx" "$clean_title" "${plugin_colors[$idx]:-}"
                fi
            done <<< "$sorted_plugins"
        done
        
        echo ""
        printf_menu_option "b" "Назад"
        
        # FIX: Add colon back to the prompt.
        local choice; choice=$(safe_read "Какую команду выполнить?" "") || { _LAST_CTRLC_SIGNALED=0; break; }
        if [[ "$choice" == "b" ]]; then break; fi
        
        if [[ -z "$choice" || ! -v "plugin_paths[$choice]" ]]; then
            printf_error "Неверный выбор."
            sleep 1
            continue
        fi
        
        local selected_plugin="${plugin_paths[$choice]}"

        echo ""
        printf_info "Где выполнять команду?"
        printf_menu_option "1" "На всём флоте"
        printf_menu_option "2" "На одном выбранном сервере"
        local scope; scope=$(safe_read "Выбор (1/2): " "1") || { _LAST_CTRLC_SIGNALED=0; continue; }

        if [[ "$scope" == "2" ]]; then
            if [[ ! -s "$FLEET_DATABASE_FILE" ]]; then
                printf_error "База флота пуста. Добавьте серверы."
                wait_for_enter
                continue
            fi

            local servers=(); local idx=1
            echo ""
            printf_info "Доступные серверы:"
            while IFS='|' read -r name user ip port key_path sudo_pass category; do
                servers[$idx]="$name|$user|$ip|$port|$key_path|$sudo_pass|$category"
                printf "   [%d] %s (%s@%s:%s) [%s]\n" "$idx" "$name" "$user" "$ip" "$port" "$(_skynet_category_label "$category")"
                ((idx++))
            done < "$FLEET_DATABASE_FILE"

            local s_choice
            s_choice=$(ask_number_in_range "Номер сервера: " 1 "$((idx-1))" "") || continue
            if [[ -n "${servers[$s_choice]:-}" ]]; then
                IFS='|' read -r name user ip port key_path sudo_pass category <<< "${servers[$s_choice]}"
                printf_warning "Команда '${selected_plugin##*/}' будет выполнена на сервере '$name'."
                if ask_yes_no "Начать? (y/n): " "n"; then
                    _skynet_run_plugin_on_server "$selected_plugin" "$name" "$user" "$ip" "$port" "$key_path" "$sudo_pass"
                    printf_ok "Команда выполнена."; wait_for_enter
                fi
            fi
        else
            printf_warning "Команда '${selected_plugin##*/}' будет выполнена на всём флоте одновременно (параллельно)."
            if ask_yes_no "Начать? (y/n): " "n"; then
                _skynet_run_plugin_on_fleet_parallel "$selected_plugin"
                wait_for_enter
            fi
        fi
    done
    disable_graceful_ctrlc
}