#!/bin/bash
# ============================================================ #
# ==       МОДУЛЬ УСТАНОВКИ, ОБНОВЛЕНИЯ И УДАЛЕНИЯ          == #
# ============================================================ #
#
# Управляет жизненным циклом самого "Решалы".
#
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1 # Защита от прямого запуска

# Переносит данные из установки версии, которая ещё хранила их внутри
# /opt/reshala. Такую версию узнаём по коду: новая знает RESHALA_SETTINGS_FILE.
# Запускается один раз: дальше старое дерево уже новое, и разница его конфига с
# умолчаниями - это смена умолчаний между версиями, а не правки пользователя.
_migrate_legacy_data() {
    local old_dir="$1" new_dir="$2"
    grep -q "RESHALA_SETTINGS_FILE" "${old_dir}/modules/core/common.sh" 2>/dev/null && return 0

    if [[ -f "${old_dir}/config/reshala.conf" && ! -f "$RESHALA_SETTINGS_FILE" ]]; then
        _config_import_from "${old_dir}/config/reshala.conf" "${new_dir}/config/reshala.conf" || return 1
    fi
    if [[ ! -f "$RESHALA_UPDATER_CONF" ]] && grep -qv '^#' "${old_dir}/config/updater.conf" 2>/dev/null; then
        cp "${old_dir}/config/updater.conf" "$RESHALA_UPDATER_CONF" || return 1
    fi
    if [[ -d "${old_dir}/modules/security/backups" ]]; then
        # chmod после cp: "cp -a каталог/." переносит и права самого каталога.
        mkdir -p "$RESHALA_BACKUP_DIR" \
            && cp -a "${old_dir}/modules/security/backups/." "$RESHALA_BACKUP_DIR/" \
            && chmod 700 "$RESHALA_BACKUP_DIR" || return 1
    fi
}

# Ставит версию из src_dir в /opt/reshala. Сначала она целиком копируется рядом
# и только потом подменяет рабочую: при любой ошибке установка остаётся как
# была. src_dir может быть самим /opt/reshala ("reshala install").
_deploy_release() {
    local src_dir="$1"
    local INSTALL_DIR="/opt/reshala"
    local new_dir="${INSTALL_DIR}.new.$$" old_dir="${INSTALL_DIR}.old.$$"

    run_cmd rm -rf "$new_dir"
    if ! run_cmd mkdir -p "$new_dir" || ! run_cmd cp -a "${src_dir}/." "${new_dir}/" \
        || [[ ! -f "${new_dir}/reshala.sh" || ! -f "${new_dir}/modules/core/common.sh" ]]; then
        run_cmd rm -rf "$new_dir"
        err "Не удалось подготовить файлы новой версии. Установка не изменена."
        return 1
    fi
    run_cmd chmod +x "${new_dir}/reshala.sh"

    if [[ -d "$INSTALL_DIR" ]]; then
        if ! _migrate_legacy_data "$INSTALL_DIR" "$new_dir"; then
            run_cmd rm -rf "$new_dir"
            err "Не удалось перенести настройки и бэкапы старой версии. Установка не изменена."
            return 1
        fi
        if ! run_cmd mv "$INSTALL_DIR" "$old_dir"; then
            run_cmd rm -rf "$new_dir"
            err "Не удалось заменить ${INSTALL_DIR}. Установка не изменена."
            return 1
        fi
    fi
    if ! run_cmd mv "$new_dir" "$INSTALL_DIR"; then
        [[ -d "$old_dir" ]] && run_cmd mv "$old_dir" "$INSTALL_DIR"
        run_cmd rm -rf "$new_dir"
        err "Не удалось заменить ${INSTALL_DIR}. Старая версия возвращена на место."
        return 1
    fi
    run_cmd rm -rf "$old_dir"
}

_perform_install_or_update() {
    local mode=${1:-install} # 'install' or 'update'
    
    local REPO_ARCHIVE_URL="${REPO_URL}/archive/refs/heads/${REPO_BRANCH}.tar.gz"
    local TEMP_ARCHIVE; TEMP_ARCHIVE=$(mktemp /tmp/reshala_archive.XXXXXX.tar.gz)
    
    printf_info "Качаю последнюю версию с GitHub..."
    if ! curl -sL --fail -o "$TEMP_ARCHIVE" "$REPO_ARCHIVE_URL"; then
        printf_error "Не удалось скачать архив. Проверьте интернет и настройки в config/reshala.conf"
        rm -f "$TEMP_ARCHIVE"; return 1
    fi

    local TEMP_DIR; TEMP_DIR=$(mktemp -d /tmp/reshala_extracted.XXXXXX)
    if ! tar -xzf "$TEMP_ARCHIVE" -C "$TEMP_DIR" --strip-components=1; then
        printf_error "Не могу распаковать архив. Файл повреждён?"; rm -f "$TEMP_ARCHIVE"; rm -rf "$TEMP_DIR"; return 1
    fi

    local INSTALL_DIR="/opt/reshala"
    printf_info "Разворачиваю файлы в ${INSTALL_DIR}..."
    if ! _deploy_release "$TEMP_DIR"; then
        rm -f "$TEMP_ARCHIVE"; rm -rf "$TEMP_DIR"; return 1
    fi

    run_cmd ln -sf "${INSTALL_DIR}/reshala.sh" "$INSTALL_PATH"

    rm -f "$TEMP_ARCHIVE"; rm -rf "$TEMP_DIR"
    return 0
}

# ... (начало self_update.sh) ...

install_script() {
    info "Запуск процедуры установки Решалы (локальная копия из SCRIPT_DIR)..."
    
    # SCRIPT_DIR в данный момент указывает на временную папку,
    # куда bootstrapper уже всё распаковал. Нам больше не нужно ничего качать.
    # Мы просто копируем файлы из текущего места в финальное.
    
    local INSTALL_DIR="/opt/reshala"
    
    info "Копирую файлы из временной директории в ${INSTALL_DIR}..."
    # Вот ключевое изменение! Копируем из SCRIPT_DIR, а не качаем заново.
    _deploy_release "$SCRIPT_DIR" || return 1

    info "Создаю системную команду 'reshala' (через symlink на /opt/reshala/reshala.sh)..."
    run_cmd ln -sf "${INSTALL_DIR}/reshala.sh" "$INSTALL_PATH"

    # Добавляем алиас для root, если он нужен
    if ! grep -q "alias reshala='sudo reshala'" /root/.bashrc 2>/dev/null; then
        echo "alias reshala='sudo reshala'" | run_cmd tee -a /root/.bashrc >/dev/null
    fi

    log "Скрипт успешно установлен."
    ok "Решала установлена в системе."
    printf "   %b: %b\n" "${C_BOLD}Команда запуска" "${C_YELLOW}reshala${C_RESET}"

    # --- Умный враппер: работает с sudo и без него ---
    local wrapper_script="/usr/local/bin/reshala"
    # Удаляем старый симлинк, создаём умный wrapper-скрипт
    rm -f "${wrapper_script}"
    cat > "${wrapper_script}" << 'WRAPPER_EOF'
#!/bin/bash
# Умный лаунчер Решалы: пробует sudo, если нет — запускает напрямую
TARGET="/opt/reshala/reshala.sh"
if [[ $EUID -eq 0 ]]; then
    exec "$TARGET" "$@"
elif command -v sudo >/dev/null 2>&1; then
    exec sudo "$TARGET" "$@"
else
    echo "[!] sudo не найден, пробую запустить напрямую..." >&2
    exec "$TARGET" "$@"
fi
WRAPPER_EOF
    chmod +x "${wrapper_script}"

    # Убираем устаревший алиас sudo reshala из .bashrc (если есть)
    if [ -f /root/.bashrc ]; then
        sed -i "/alias reshala=/d" /root/.bashrc 2>/dev/null || true
    fi

    warn "ВАЖНО: переподключитесь к серверу, чтобы команда заработала в новой сессии."

    # Автозапуск Решалы сразу после установки
    if [[ "${RESHALA_NO_AUTOSTART:-0}" != "1" ]]; then
        echo ""
        info "Стартую Решалу прямо сейчас..."
        sleep 1
        exec "$wrapper_script"
    fi
}

uninstall_script() {
    warn "Удалить Решалу? Будут удалены все её файлы."
    if ! ask_yes_no "(y/n): " "n"; then info "Удаление отменено."; return; fi
    info "Начинаю удаление (исполняемый файл, каталог /opt/reshala, журнал и база флота)..."
    run_cmd rm -f "$INSTALL_PATH"
    run_cmd rm -rf "/opt/reshala"
    # Сносим лог и базу флота, если есть
    if [ -n "${LOGFILE:-}" ]; then run_cmd rm -f "$LOGFILE" 2>/dev/null || true; fi
    if [ -n "${FLEET_DATABASE_FILE:-}" ]; then run_cmd rm -f "$FLEET_DATABASE_FILE" 2>/dev/null || true; fi
    if [ -f "/root/.bashrc" ]; then run_cmd sed -i "/alias reshala='sudo reshala'/d" /root/.bashrc; fi
    ok "Удаление завершено. Переподключитесь к серверу, чтобы очистить alias и окружение."
    exit 0
}

# Нормализация версии: убираем префикс v/V
_self_update_normalize_version() {
    echo "$1" | sed 's/^[vV]//' 2>/dev/null
}

# Возвращает 0 (успех), если remote > local в терминах sort -V
_self_update_is_remote_newer() {
    local local_v remote_v
    local_v=$(_self_update_normalize_version "$1")
    remote_v=$(_self_update_normalize_version "$2")

    # Если одинаковые после нормализации — обновления нет
    if [[ "$local_v" == "$remote_v" ]]; then
        return 1
    fi

    # sort -V отсортирует версии по возрастанию; берём последнюю
    local top
    top=$(printf '%s\n%s\n' "$local_v" "$remote_v" | sort -V | tail -n1)
    if [[ "$top" == "$remote_v" ]]; then
        return 0
    fi
    return 1
}

check_for_updates() {
    local remote_version_url="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}/reshala.sh?cb=$(date +%s)"
    local remote_ver
    remote_ver=$(curl -s -L --connect-timeout 8 --max-time 12 "$remote_version_url" 2>/dev/null \
        | grep 'readonly VERSION=' | head -1 | cut -d'"' -f2)

    if [[ -z "$remote_ver" ]]; then
        debug_log "check_for_updates: не удалось получить версию с GitHub (branch=${REPO_BRANCH})"
        UPDATE_AVAILABLE=0; LATEST_VERSION=""
        return
    fi

    debug_log "check_for_updates: local=${VERSION} remote=${remote_ver}"

    if _self_update_is_remote_newer "$VERSION" "$remote_ver"; then
        UPDATE_AVAILABLE=1; LATEST_VERSION="$remote_ver"
        log "[ОБНОВЛЕНИЕ] Доступно: ${VERSION} -> ${remote_ver}"
        
        # Получаем текст последнего коммита (что нового)
        local commit_api_url="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/commits/${REPO_BRANCH}"
        local commit_msg
        commit_msg=$(curl -s -L --connect-timeout 8 --max-time 12 "$commit_api_url" 2>/dev/null \
            | jq -r 'if type=="array" then .[0].commit.message else .commit.message end' 2>/dev/null)
        
        if [[ -n "$commit_msg" && "$commit_msg" != "null" ]]; then
            LATEST_COMMIT_MESSAGE="$commit_msg"
        else
            LATEST_COMMIT_MESSAGE=""
        fi
    else
        UPDATE_AVAILABLE=0; LATEST_VERSION=""; LATEST_COMMIT_MESSAGE=""
    fi
}

run_update() {
    if _perform_install_or_update "update"; then
        log "Скрипт успешно обновлён до версии ${LATEST_VERSION}."
        ok "Обновление завершено. Установлена версия ${LATEST_VERSION}."
        info "Перезапускаю Решалу, чтобы все модули подхватили новую версию..."
        sleep 2
        cd / || true
        exec "$INSTALL_PATH"
    fi
}