#!/bin/bash
# ============================================================ #
# ==          SKYNET API: JSON-ИНТЕРФЕЙС ДЛЯ ПАНЕЛИ           == #
# ============================================================ #
#
# `reshala api <группа> <действие> [аргументы]` - машинный интерфейс к флоту
# и проверке ТСПУ для графической панели. Ответ - всегда один JSON-объект в
# stdout: {"ok":true,...} или {"ok":false,"error":"КОД","message":"..."}.
# Входные данные сложнее одного слова (новый сервер, настройки) - JSON в stdin.
#
# Логика остаётся в модулях Решалы (db.sh, keys.sh, censorcheck_report.sh):
# здесь только разбор входа, вызов и упаковка результата. Интерактивных
# вопросов нет нигде - всё, что меню спрашивает у человека (доверять ли
# ключу хоста, пароль для заброса ключа), приходит параметрами.
#
# Безопасность:
#   - пароли SSH/sudo из базы флота наружу не отдаются никогда, только
#     признак "задан";
#   - панель ходит сюда по SSH-ключу, ограниченному в authorized_keys
#     командой `reshala api-ssh` (см. _api_ssh_entry): им нельзя открыть
#     шелл, только вызвать действия из списка ниже.
#
# Действия:
#   version
#   fleet list                      - серверы флота
#   fleet ping                      - доступность SSH-порта и 443 у каждого
#   fleet hostkey <хост> [порт]     - отпечатки ключа хоста до добавления
#   fleet add                       - stdin: {name,host,user,port,category,sni,password,acceptFingerprints,privateKey}
#   fleet update <N>                - stdin: {expectName, ...поля как у add}
#   fleet delete <N>                - stdin: {expectName}
#   tspu status                     - настройки, расписание, идёт ли прогон
#   tspu last                       - последний прогон целиком
#   tspu credits                    - баланс кредитов RIPE Atlas
#   tspu runs [лимит]               - история прогонов (сводки)
#   tspu get <id>                   - прогон из истории целиком
#   tspu run                        - запустить прогон флота в фоне
#   tspu check                      - stdin: {target,sni}; разовая проверка в фоне
#   tspu check-get <id>             - результат разовой проверки
#   tspu settings                   - stdin: {sni,schedule,excluded,thresholds}
#
# N - номер строки в базе флота (с 1), expectName - имя сервера в ней: если
# базу успели поменять (меню, другой запрос), правка не попадёт не туда.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1 # Защита от прямого запуска

source "${SCRIPT_DIR}/modules/skynet/db.sh"
source "${SCRIPT_DIR}/modules/skynet/keys.sh"
source "${SCRIPT_DIR}/modules/skynet/censorcheck_report.sh"

_API_CHECKS_DIR="${_TSPU_STORE_DIR}/checks"

# ------------------------------------------------------------ #
#                          ОТВЕТЫ                              #
# ------------------------------------------------------------ #

# _api_ok '<json-объект>' - добавляет "ok":true к готовому объекту.
_api_ok() {
    local body="$1"
    [[ -n "$body" ]] || body='{}'
    jq -c '{ok: true} + .' <<< "$body"
}

_api_err() {
    local code="$1" message="${2:-}"
    jq -nc --arg e "$code" --arg m "$message" '{ok: false, error: $e, message: $m}'
    return 1
}

# Вход из stdin один раз: несколько jq-запросов к нему не должны каждый раз
# читать поток.
_API_INPUT=""
_api_read_input() {
    if [[ ! -t 0 ]]; then
        _API_INPUT=$(cat)
    fi
    [[ -n "$_API_INPUT" ]] || _API_INPUT="{}"
    jq -e 'type == "object"' >/dev/null 2>&1 <<< "$_API_INPUT"
}

# _api_in <поле> - строковое значение поля входа ("" если нет или null).
_api_in() {
    jq -r --arg k "$1" '.[$k] // "" | if type == "string" then . else tostring end' <<< "$_API_INPUT"
}

# Есть ли поле во входе вообще (в том числе со значением "").
_api_has() {
    jq -e --arg k "$1" 'has($k) and .[$k] != null' >/dev/null <<< "$_API_INPUT"
}

_api_now() { date -u '+%Y-%m-%dT%H:%M:%S+00:00'; }

# ------------------------------------------------------------ #
#                        ПРОВЕРКИ ВХОДА                        #
# ------------------------------------------------------------ #

# Имя сервера: без "|" (разделитель полей базы) и переводов строк, не пустое.
_api_valid_name() {
    [[ -n "$1" && "$1" != *"|"* && "$1" != *$'\n'* && "$1" != *$'\r'* && ${#1} -le 64 ]]
}
_api_valid_host() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && ${#1} -le 253 ]]
}
_api_valid_user() {
    [[ "$1" =~ ^[a-z_][a-z0-9_.-]*$ && ${#1} -le 32 ]]
}
_api_valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# ------------------------------------------------------------ #
#                            ФЛОТ                              #
# ------------------------------------------------------------ #

# Строка базы N (с 1) -> "name|user|ip|port|key|pass|category|sni", пусто если нет.
_api_fleet_line() {
    [[ -f "$FLEET_DATABASE_FILE" ]] || return 1
    sed -n "${1}p" "$FLEET_DATABASE_FILE"
}

_api_fleet_list() {
    # Без _sanitize_fleet_database: чтение не должно переписывать базу (тот
    # перезаписывает файл даже без изменений). Пустые строки и запись без
    # категории разбираются и так.
    local excluded; excluded=$(get_config_var "TSPU_EXCLUDED_SERVERS")
    local -a excl=()
    mapfile -t excl < <(_skynet_tspu_csv_items "$excluded")

    # Пароль не покидает этот процесс: в JSON только признак hasPassword.
    local rows="" n=0 name user ip port key_path sudo_pass category sni
    if [[ -f "$FLEET_DATABASE_FILE" ]]; then
        while IFS='|' read -r name user ip port key_path sudo_pass category sni; do
            n=$((n + 1))
            [[ -z "$name" ]] && continue
            rows+=$(jq -nc --argjson n "$n" --arg name "$name" --arg user "$user" \
                --arg host "$ip" --arg port "${port:-22}" --arg key "$(basename "${key_path:-}")" \
                --argjson haspass "$([[ -n "$sudo_pass" ]] && echo true || echo false)" \
                --arg sni "$sni" --arg category "$(_skynet_norm_category "$category")" \
                '{index: $n, name: $name, user: $user, host: $host, port: ($port|tonumber? // 22),
                  key: (if $key == "" then null else $key end), hasPassword: $haspass,
                  category: $category, sni: $sni}')$'\n'
        done < "$FLEET_DATABASE_FILE"
    fi

    local excl_json; excl_json=$(printf '%s\n' ${excl[@]+"${excl[@]}"} | jq -R . | jq -sc 'map(select(length > 0))')
    _api_ok "$(jq -sc --argjson excl "$excl_json" \
        '{servers: map(. + {tspuExcluded: (.name as $n | $excl | index($n) != null)})}' <<< "$rows")"
}

# Доступность каждого сервера: открыт ли SSH-порт и 443 (VPN/Reality).
# Как виджет "Флот онлайн" - TCP-соединение без входа, так что не нужен ни
# ключ, ни пароль, и fail2ban на сервере не тревожится.
# Открыт ли TCP-порт: до двух попыток по 4 секунды. За 4 секунды ядро шлёт
# три SYN (0, 1 и 3 с), а у части хостеров первые SYN на 443 пачками теряются:
# одна трёхсекундная попытка называла такой порт закрытым, хотя клиент,
# повторив, подключается через секунду-две.
_api_tcp_open() {
    local attempt
    for attempt in 1 2; do
        timeout 4 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$1" "$2" 2>/dev/null && return 0
    done
    return 1
}

_api_fleet_ping() {
    local tmp_dir; tmp_dir=$(mktemp -d) || { _api_err INTERNAL "mktemp"; return; }
    local n=0 name user ip port key_path sudo_pass category sni
    if [[ -f "$FLEET_DATABASE_FILE" ]]; then
        while IFS='|' read -r name user ip port key_path sudo_pass category sni; do
            n=$((n + 1))
            [[ -n "$ip" ]] || continue
            (
                local t0 t1 ssh_ok=false https_ok=false ms=null
                t0=$(date +%s%N)
                if _api_tcp_open "$ip" "${port:-22}"; then
                    t1=$(date +%s%N)
                    ssh_ok=true
                    ms=$(( (t1 - t0) / 1000000 ))
                fi
                if _api_tcp_open "$ip" 443; then
                    https_ok=true
                fi
                printf '{"index":%d,"ssh":%s,"https":%s,"ms":%s}\n' "$n" "$ssh_ok" "$https_ok" "$ms"
            ) > "${tmp_dir}/${n}" 2>/dev/null &
        done < "$FLEET_DATABASE_FILE"
    fi
    wait
    local body; body=$(cat "$tmp_dir"/* 2>/dev/null | jq -sc '{checkedAt: $at, results: sort_by(.index)}' --arg at "$(_api_now)")
    rm -rf "$tmp_dir"
    _api_ok "$body"
}

# Ключи хоста: отпечатки и сверка с known_hosts (как
# _skynet_confirm_and_pin_host_key, но без вопросов). status:
#   MATCH    - ключ уже известен и тот же;
#   NEW      - первое подключение, отпечатки надо показать человеку;
#   MISMATCH - ключ сменился (переустановка или MITM) - через API не
#              принимается, только из меню Решалы, где риск проговорён.
# Печатает "STATUS<TAB>сырые строки keyscan" в файл $3 и JSON отпечатков в stdout.
_api_hostkey_scan() {
    local host="$1" port="$2" raw_out="$3"
    local khf="${HOME}/.ssh/known_hosts"
    mkdir -p "${HOME}/.ssh"; touch "$khf"

    local scanned
    scanned=$(ssh-keyscan -p "$port" -T 5 "$host" 2>/dev/null | grep -v '^#')
    [[ -n "$scanned" ]] || return 1
    printf '%s\n' "$scanned" > "$raw_out"

    local known_lines=""
    known_lines+=$'\n'"$(ssh-keygen -F "[$host]:$port" -f "$khf" 2>/dev/null | grep -v '^#')"
    [[ "$port" == "22" ]] && known_lines+=$'\n'"$(ssh-keygen -F "$host" -f "$khf" 2>/dev/null | grep -v '^#')"

    local status="NEW" new_line old_line new_algo new_blob old_algo old_blob
    if [[ -n "${known_lines//$'\n'/}" ]]; then
        status="MATCH"
        while IFS= read -r new_line; do
            [[ -z "$new_line" ]] && continue
            new_algo=$(awk '{print $2}' <<< "$new_line"); new_blob=$(awk '{print $3}' <<< "$new_line")
            while IFS= read -r old_line; do
                [[ -z "$old_line" ]] && continue
                old_algo=$(awk '{print $2}' <<< "$old_line"); old_blob=$(awk '{print $3}' <<< "$old_line")
                [[ "$old_algo" == "$new_algo" && "$old_blob" != "$new_blob" ]] && status="MISMATCH"
            done <<< "$known_lines"
        done <<< "$scanned"
    fi

    local keys="" fp line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        fp=$(ssh-keygen -lf /dev/stdin <<< "$line" 2>/dev/null) || continue
        # "256 SHA256:xxxx host (ED25519)"
        keys+=$(jq -nc --arg fp "$(awk '{print $2}' <<< "$fp")" --arg type "$(awk '{print $NF}' <<< "$fp" | tr -d '()')" \
            '{type: $type, fingerprint: $fp}')$'\n'
    done <<< "$scanned"
    jq -sc --arg status "$status" '{status: $status, keys: unique_by(.fingerprint)}' <<< "$keys"
}

_api_fleet_hostkey() {
    local host="$1" port="${2:-22}"
    _api_valid_host "$host" || { _api_err BAD_HOST "Некорректный адрес: ${host}"; return; }
    _api_valid_port "$port" || { _api_err BAD_PORT "Некорректный порт: ${port}"; return; }
    local raw; raw=$(mktemp)
    local body
    if ! body=$(_api_hostkey_scan "$host" "$port" "$raw"); then
        rm -f "$raw"
        _api_err HOST_UNREACHABLE "Не удалось получить ключ хоста ${host}:${port} — сервер недоступен или порт закрыт."
        return
    fi
    rm -f "$raw"
    _api_ok "$(jq -c --arg host "$host" --argjson port "$port" '. + {host: $host, port: $port}' <<< "$body")"
}

# Доступ к серверу для записи в базу: ключ хоста принят, мастер-ключ лежит
# на сервере. При успехе печатает путь к ключу.
#   accept_json - массив отпечатков, которые человек видел и подтвердил;
#   password    - для однократного заброса ключа, если входа по ключу нет.
_api_ensure_access() {
    local host="$1" port="$2" user="$3" password="$4" accept_json="$5" key_override="${6:-}"

    local raw; raw=$(mktemp)
    local scan
    if ! scan=$(_api_hostkey_scan "$host" "$port" "$raw"); then
        rm -f "$raw"
        _api_err HOST_UNREACHABLE "Не удалось получить ключ хоста ${host}:${port} — сервер недоступен или порт закрыт."
        return 1
    fi
    local status; status=$(jq -r .status <<< "$scan")
    case "$status" in
        MATCH) ;;
        MISMATCH)
            rm -f "$raw"
            _api_err HOSTKEY_CHANGED "Ключ хоста ${host}:${port} сменился. Если сервер переустанавливали — прими новый ключ в меню Решалы (Skynet), там же сверка отпечатка."
            return 1
            ;;
        NEW)
            # Принимаем только если человек подтвердил ВСЕ отпечатки, что
            # показал сервер прямо сейчас: подмена между показом и добавлением
            # даст другой набор и не пройдёт.
            if ! jq -e --argjson acc "${accept_json:-[]}" \
                    '[.keys[].fingerprint] - $acc | length == 0' >/dev/null <<< "$scan"; then
                rm -f "$raw"
                # Отпечатки - в самом ответе: панель показывает их человеку
                # и повторяет запрос с acceptFingerprints.
                jq -c --arg host "$host" --argjson port "$port" \
                    '{ok: false, error: "HOSTKEY_UNCONFIRMED",
                      message: "Подтверди отпечаток ключа хоста.",
                      hostkey: (. + {host: $host, port: $port})}' <<< "$scan"
                return 1
            fi
            cat "$raw" >> "${HOME}/.ssh/known_hosts"
            log "Skynet API: ключ хоста ${host}:${port} принят из панели."
            ;;
    esac
    rm -f "$raw"

    local key="$key_override"
    [[ -n "$key" ]] || key=$(_ensure_master_key 2>/dev/null)
    [[ -f "$key" ]] || { _api_err KEY_MISSING "Не удалось создать мастер-ключ."; return 1; }

    local -a ssh_opts=(-q -F /dev/null -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5
                       -o StrictHostKeyChecking=yes -i "$key" -p "$port")
    if timeout 15 ssh "${ssh_opts[@]}" "${user}@${host}" exit 2>/dev/null; then
        echo "$key"
        return 0
    fi

    if [[ -z "$password" ]]; then
        if [[ -n "$key_override" ]]; then
            _api_err NEED_PASSWORD "Вход по этому ключу не прошёл. Укажи пароль — его публичная часть будет закинута на сервер один раз."
        else
            _api_err NEED_PASSWORD "Вход по мастер-ключу не прошёл. Укажи пароль — ключ будет закинут на сервер один раз."
        fi
        return 1
    fi

    # Пароль - через SSH_ASKPASS из переменной окружения: ни в аргументах
    # (видны в ps), ни в файле на диске его нет.
    local askpass; askpass=$(mktemp)
    printf '#!/bin/sh\nprintf "%%s\\n" "$RESHALA_API_PASS"\n' > "$askpass"
    chmod 700 "$askpass"
    local rc=0
    RESHALA_API_PASS="$password" SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
        timeout 40 setsid ssh-copy-id -f -o StrictHostKeyChecking=yes -o ConnectTimeout=8 \
        -o PreferredAuthentications=password,keyboard-interactive -o NumberOfPasswordPrompts=1 \
        -i "${key}.pub" -p "$port" "${user}@${host}" </dev/null >/dev/null 2>&1 || rc=$?
    rm -f "$askpass"
    if [[ "$rc" -ne 0 ]]; then
        _api_err KEY_DEPLOY_FAILED "Не удалось закинуть ключ: неверный пароль, вход по паролю запрещён или сработал Fail2Ban."
        return 1
    fi
    if ! timeout 15 ssh "${ssh_opts[@]}" "${user}@${host}" exit 2>/dev/null; then
        _api_err KEY_DEPLOY_FAILED "Ключ закинут, но вход по нему не прошёл."
        return 1
    fi
    log "Skynet API: ключ $(basename "$key") закинут на ${user}@${host}:${port}."
    echo "$key"
}

# Свой ключ сервера из входа (privateKey) - как импорт в меню Решалы
# (_import_ssh_key): ~/.ssh/reshala_imported_<имя>, публичная часть рядом.
# Печатает путь к ключу. Код возврата - что произошло, потому что вызов идёт
# через $(...), и переменные отсюда до вызывающего не доходят:
#   0 - такой ключ уже был импортирован (под любым именем), он и берётся;
#   3 - ключ записан заново: при неудаче вызывающий удаляет его сам;
#   1 - ключа во входе нет;   2 - ключ негодный (ошибка уже напечатана).
_api_import_key() {
    local server_name="$1"
    local material; material=$(jq -r '.privateKey // ""' <<< "$_API_INPUT")
    material="${material//$'\r'/}"
    [[ -n "$material" ]] || return 1
    (( ${#material} <= 16384 )) || { _api_err BAD_KEY "Ключ слишком большой."; return 2; }
    [[ "$material" == *"PRIVATE KEY"* ]] || { _api_err BAD_KEY "Это не приватный ключ: нужен файл целиком, со строками BEGIN/END."; return 2; }

    local tmp; tmp=$(mktemp) || { _api_err INTERNAL "mktemp"; return 2; }
    chmod 600 "$tmp"
    printf '%s\n' "$material" > "$tmp"
    local pub
    # -P "" - без вопроса о парольной фразе: защищённый ею ключ здесь
    # просто не открывается, а не повисает в ожидании ввода.
    if ! pub=$(ssh-keygen -y -P "" -f "$tmp" 2>/dev/null); then
        rm -f "$tmp"
        _api_err BAD_KEY "Ключ не читается: неверный формат или он защищён парольной фразой (такие не поддерживаются)."
        return 2
    fi
    pub=$(awk '{print $1" "$2}' <<< "$pub")

    mkdir -p "${HOME}/.ssh"; chmod 700 "${HOME}/.ssh"
    # Тот же ключ уже лежит (импортирован раньше, хоть под другим именем) -
    # второй копии не заводим.
    local existing
    for existing in "${HOME}"/.ssh/reshala_imported_*; do
        [[ -f "$existing" && "$existing" != *.pub ]] || continue
        if [[ "$(ssh-keygen -y -P "" -f "$existing" 2>/dev/null | awk '{print $1" "$2}')" == "$pub" ]]; then
            rm -f "$tmp"
            echo "$existing"
            return 0
        fi
    done

    local slug; slug=$(printf '%s' "$server_name" | tr -cd '[:alnum:]_-' | head -c 40)
    [[ -n "$slug" ]] || slug="key"
    local path="${HOME}/.ssh/reshala_imported_${slug}" n=2
    while [[ -e "$path" ]]; do
        path="${HOME}/.ssh/reshala_imported_${slug}-${n}"; n=$((n + 1))
    done
    mv "$tmp" "$path"
    chmod 600 "$path"
    printf '%s %s\n' "$pub" "reshala-imported" > "${path}.pub"
    chmod 644 "${path}.pub"
    echo "$path"
    return 3
}

# Общая проверка полей add/update. Печатает ошибку и возвращает 1.
_api_fleet_validate() {
    local name="$1" host="$2" user="$3" port="$4" category="$5"
    _api_valid_name "$name" || { _api_err BAD_NAME "Имя: 1–64 символа, без «|»."; return 1; }
    _api_valid_host "$host" || { _api_err BAD_HOST "Некорректный адрес: ${host}"; return 1; }
    _api_valid_user "$user" || { _api_err BAD_USER "Некорректный пользователь: ${user}"; return 1; }
    _api_valid_port "$port" || { _api_err BAD_PORT "Некорректный порт: ${port}"; return 1; }
    [[ "$category" == "fleet" || "$category" == "infra" ]] || { _api_err BAD_CATEGORY "Категория: fleet или infra."; return 1; }
}

# Есть ли в базе сервер с таким именем, кроме строки skip.
_api_name_taken() {
    local wanted="$1" skip="${2:-0}" n=0 name rest
    [[ -f "$FLEET_DATABASE_FILE" ]] || return 1
    while IFS='|' read -r name rest; do
        n=$((n + 1))
        [[ "$n" -eq "$skip" ]] && continue
        [[ "$name" == "$wanted" ]] && return 0
    done < "$FLEET_DATABASE_FILE"
    return 1
}

_api_fleet_add() {
    _api_read_input || { _api_err BAD_INPUT "Ожидается JSON-объект в stdin."; return; }
    local name host user port category password sni accept
    name=$(_api_in name); host=$(_api_in host)
    user=$(_api_in user); user="${user:-$SKYNET_DEFAULT_USER}"
    port=$(_api_in port); port="${port:-$SKYNET_DEFAULT_PORT}"
    category=$(_api_in category); category="${category:-fleet}"
    sni=$(_api_in sni)
    _skynet_valid_server_sni "$sni" || { _api_err BAD_SNI "Укажите доменное имя SNI сервера."; return; }
    _sanitize_fleet_database
    password=$(_api_in password)
    accept=$(jq -c '.acceptFingerprints // []' <<< "$_API_INPUT")

    _api_fleet_validate "$name" "$host" "$user" "$port" "$category" || return
    [[ "$password" != *"|"* && "$password" != *$'\n'* ]] || { _api_err BAD_PASSWORD "Пароль не может содержать «|» и перевод строки."; return; }
    _api_name_taken "$name" && { _api_err NAME_TAKEN "Сервер «${name}» уже есть во флоте."; return; }

    local own_key="" rc=0
    own_key=$(_api_import_key "$name") || rc=$?
    [[ "$rc" -eq 2 ]] && { echo "$own_key"; return; }
    [[ "$rc" -eq 1 ]] && own_key=""

    local key
    if ! key=$(_api_ensure_access "$host" "$port" "$user" "$password" "$accept" "$own_key"); then
        # Ключ, записанный только что, без доступа никому не нужен.
        [[ "$rc" -eq 3 ]] && rm -f "$own_key" "${own_key}.pub"
        echo "$key"
        return
    fi

    echo "${name}|${user}|${host}|${port}|${key}|${password}|${category}|${sni}" >> "$FLEET_DATABASE_FILE"
    chmod 600 "$FLEET_DATABASE_FILE" 2>/dev/null || true
    log "Skynet API: сервер '${name}' (${host}) добавлен из панели."
    _api_fleet_list
}

_api_fleet_update() {
    local n="$1"
    [[ "$n" =~ ^[0-9]+$ ]] || { _api_err BAD_INDEX "Номер сервера — целое число."; return; }
    _api_read_input || { _api_err BAD_INPUT "Ожидается JSON-объект в stdin."; return; }

    local line; line=$(_api_fleet_line "$n")
    local o_name o_user o_ip o_port o_key o_pass o_cat o_sni
    IFS='|' read -r o_name o_user o_ip o_port o_key o_pass o_cat o_sni <<< "$line"
    [[ -n "$o_name" && "$o_name" == "$(_api_in expectName)" ]] \
        || { _api_err STALE "База флота изменилась — обнови список и повтори."; return; }

    local name host user port category password sni
    name=$(_api_in name); name="${name:-$o_name}"
    host=$(_api_in host); host="${host:-$o_ip}"
    user=$(_api_in user); user="${user:-$o_user}"
    port=$(_api_in port); port="${port:-${o_port:-22}}"
    category=$(_api_in category); category="${category:-$(_skynet_norm_category "$o_cat")}"
    sni="$o_sni"
    if _api_has sni; then
        sni=$(_api_in sni)
        _skynet_valid_server_sni "$sni" || { _api_err BAD_SNI "Укажите доменное имя SNI сервера."; return; }
    fi
    # password: нет поля - оставить, "" - очистить, строка - задать.
    if _api_has password; then password=$(_api_in password); else password="$o_pass"; fi

    _api_fleet_validate "$name" "$host" "$user" "$port" "$category" || return
    [[ "$password" != *"|"* && "$password" != *$'\n'* ]] || { _api_err BAD_PASSWORD "Пароль не может содержать «|» и перевод строки."; return; }
    _api_name_taken "$name" "$n" && { _api_err NAME_TAKEN "Сервер «${name}» уже есть во флоте."; return; }

    # Сменился адрес, порт или пользователь - доступ проверяется заново, как
    # при добавлении. Иначе ключ остаётся прежним.
    # Новый ключ - тоже повод проверить доступ заново (уже им).
    local own_key="" rc=0
    own_key=$(_api_import_key "$name") || rc=$?
    [[ "$rc" -eq 2 ]] && { echo "$own_key"; return; }
    [[ "$rc" -eq 1 ]] && own_key=""

    local key="$o_key"
    if [[ -n "$own_key" || "$host" != "$o_ip" || "$port" != "${o_port:-22}" || "$user" != "$o_user" ]]; then
        local accept; accept=$(jq -c '.acceptFingerprints // []' <<< "$_API_INPUT")
        # Без нового ключа - тот, что был у сервера (не обязательно мастер).
        if ! key=$(_api_ensure_access "$host" "$port" "$user" "$password" "$accept" "${own_key:-$o_key}"); then
            # Ключ, записанный только что, без доступа никому не нужен.
        [[ "$rc" -eq 3 ]] && rm -f "$own_key" "${own_key}.pub"
            echo "$key"
            return
        fi
    fi

    _update_fleet_record "$n" "${name}|${user}|${host}|${port}|${key}|${password}|${category}|${sni}"

    # Переименование не должно молча вернуть сервер в проверку ТСПУ.
    if [[ "$name" != "$o_name" ]]; then
        local excluded; excluded=$(get_config_var "TSPU_EXCLUDED_SERVERS")
        if _skynet_tspu_csv_contains "$o_name" "$excluded"; then
            excluded=$(_skynet_tspu_csv_remove "$o_name" "$excluded")
            set_config_var "TSPU_EXCLUDED_SERVERS" "${excluded:+${excluded},}${name}"
        fi
    fi
    log "Skynet API: сервер '${o_name}' изменён из панели."
    _api_fleet_list
}

_api_fleet_delete() {
    local n="$1"
    [[ "$n" =~ ^[0-9]+$ ]] || { _api_err BAD_INDEX "Номер сервера — целое число."; return; }
    _api_read_input || { _api_err BAD_INPUT "Ожидается JSON-объект в stdin."; return; }
    local line; line=$(_api_fleet_line "$n")
    local o_name; o_name="${line%%|*}"
    [[ -n "$o_name" && "$o_name" == "$(_api_in expectName)" ]] \
        || { _api_err STALE "База флота изменилась — обнови список и повтори."; return; }

    local tmp; tmp=$(mktemp)
    awk -v line="$n" 'NR != line' "$FLEET_DATABASE_FILE" > "$tmp" && mv "$tmp" "$FLEET_DATABASE_FILE"
    chmod 600 "$FLEET_DATABASE_FILE" 2>/dev/null || true

    local excluded; excluded=$(get_config_var "TSPU_EXCLUDED_SERVERS")
    if _skynet_tspu_csv_contains "$o_name" "$excluded"; then
        set_config_var "TSPU_EXCLUDED_SERVERS" "$(_skynet_tspu_csv_remove "$o_name" "$excluded")"
    fi
    log "Skynet API: сервер '${o_name}' удалён из панели."
    _api_fleet_list
}

# ------------------------------------------------------------ #
#                            ТСПУ                              #
# ------------------------------------------------------------ #

# Идёт ли прогон: замок держит процесс, а не файл - running.json мог
# остаться от убитого процесса, поэтому верим только flock.
_api_tspu_running_json() {
    local fd
    exec {fd}>"$_TSPU_LOCK_FILE" 2>/dev/null || { echo null; return; }
    if flock -n "$fd"; then
        exec {fd}>&-
        rm -f "$_TSPU_RUNNING_FILE" 2>/dev/null
        echo null
        return
    fi
    exec {fd}>&-
    if [[ -s "$_TSPU_RUNNING_FILE" ]] && jq -e . >/dev/null 2>&1 < "$_TSPU_RUNNING_FILE"; then
        jq -c '{startedAt, source}' < "$_TSPU_RUNNING_FILE"
    else
        echo '{"startedAt":null,"source":null}'
    fi
}

# Выборка зондов из кэша tspu_probe.py - без запросов в RIPE Atlas.
_api_tspu_sample_json() {
    python3 - <<'PY' 2>/dev/null || echo null
import json, os
path = os.path.expanduser("~/.reshala_tspu_probes.json")
try:
    with open(path, encoding="utf-8") as fh:
        c = json.load(fh)
except Exception:
    print("null"); raise SystemExit
probes = c.get("probes") or []
cities = {}
for p in probes:
    if p.get("city"):
        cities[p["city"]] = cities.get(p["city"], 0) + 1
print(json.dumps({
    "generatedAt": c.get("generated"),
    "mode": c.get("mode"),
    "probes": len(probes),
    "mobile": sum(1 for p in probes if p.get("mobile")),
    "cities": [{"name": k, "probes": v} for k, v in sorted(cities.items(), key=lambda kv: (-kv[1], kv[0]))],
}, ensure_ascii=False))
PY
}

_api_tspu_status() {
    local times_json excluded_json fleet_n=0 infra_n=0 excluded_n=0
    times_json=$(_skynet_censorcheck_times | jq -R . | jq -sc 'map(select(length > 0))')
    excluded_json=$(_skynet_tspu_csv_items "$(get_config_var TSPU_EXCLUDED_SERVERS)" | jq -R . | jq -sc 'map(select(length > 0))')
    fleet_n=$(_skynet_fleet_count_by_category fleet)
    infra_n=$(_skynet_fleet_count_by_category infra)
    excluded_n=$(jq length <<< "$excluded_json")

    local last="null" last_error="null"
    [[ -s "${_TSPU_STORE_DIR}/last.json" ]] && last=$(jq -c '{id, startedAt, finishedAt, source, summary}' < "${_TSPU_STORE_DIR}/last.json" 2>/dev/null || echo null)
    [[ -s "${_TSPU_STORE_DIR}/last_error.json" ]] && last_error=$(jq -c . < "${_TSPU_STORE_DIR}/last_error.json" 2>/dev/null || echo null)

    _api_ok "$(jq -nc \
        --argjson ripe "$([[ -n "${RIPE_API_KEY:-}" ]] && echo true || echo false)" \
        --argjson tg "$([[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]] && echo true || echo false)" \
        --arg sni "${TSPU_REALITY_SNI:-max.ru}" --arg mode "${TSPU_CHECK_MODE:-geo}" \
        --argjson times "$times_json" --argjson excluded "$excluded_json" \
        --argjson eligible "$(_skynet_tspu_target_count)" --argjson fleet "$fleet_n" --argjson infra "$infra_n" --argjson excl_n "$excluded_n" \
        --argjson running "$(_api_tspu_running_json)" --argjson sample "$(_api_tspu_sample_json)" \
        --argjson last "$last" --argjson lastError "$last_error" \
        --argjson credits "$_CENSORCHECK_CREDITS_PER_PROBE" --argjson soft "$_CENSORCHECK_SOFT_LIMIT" \
        --argjson t1 "${TSPU_REPLACE_CITY_SHARE:-50}" --argjson t2 "${TSPU_REPLACE_AVG_THRESHOLD:-55}" \
        --argjson t3 "${TSPU_RED_BLOCKED_SHARE:-50}" --argjson t4 "${TSPU_INFRA_OK_THRESHOLD:-60}" \
        --argjson t5 "${TSPU_INFRA_RED_BLOCKED_SHARE:-1}" \
        '{configured: {ripe: $ripe, telegram: $tg},
          sni: $sni, mode: $mode,
          schedule: {times: $times, timezone: "Europe/Moscow", softLimit: $soft},
          servers: {fleet: $fleet, infra: $infra, excluded: $excl_n},
          excluded: $excluded,
          thresholds: {replaceCityShare: $t1, replaceAvgThreshold: $t2, redBlockedShare: $t3,
                       infraOkThreshold: $t4, infraRedBlockedShare: $t5},
          sample: $sample,
          creditsPerProbe: $credits,
          estimatedCredits: (if $sample == null then null
                             else $sample.probes * $credits * $eligible end),
          running: $running, last: $last, lastError: $lastError}')"
}

# Баланс кредитов RIPE Atlas. Читать его ключ может, только если ему выдано
# право на кредиты (atlas.ripe.net → API Keys → «Get information about your
# credits»): без него RIPE отвечает 403, и это отдельный ответ, а не ошибка,
# - всё остальное в проверке ТСПУ работает и так.
_api_tspu_credits() {
    [[ -n "${RIPE_API_KEY:-}" ]] || { _api_err RIPE_NOT_CONFIGURED "RIPE Atlas API-ключ не настроен."; return; }
    local body
    body=$(RIPE_API_KEY="$RIPE_API_KEY" python3 - <<'PY' 2>/dev/null
import json, os, urllib.error, urllib.request
req = urllib.request.Request(
    "https://atlas.ripe.net/api/v2/credits/",
    headers={"Authorization": "Key " + os.environ["RIPE_API_KEY"], "Accept": "application/json"},
)
def num(value):
    return value if isinstance(value, (int, float)) else None
try:
    with urllib.request.urlopen(req, timeout=15) as resp:
        d = json.load(resp)
    print(json.dumps({
        "available": True,
        "balance": num(d.get("current_balance")),
        "dailyIncome": num(d.get("estimated_daily_income")),
        "dailyExpenditure": num(d.get("estimated_daily_expenditure")),
        "pastDaySpent": num(d.get("past_day_credits_spent")),
        "runoutSeconds": num(d.get("estimated_runout_seconds")),
    }))
except urllib.error.HTTPError as e:
    reason = "NO_PERMISSION" if e.code in (401, 403) else f"HTTP_{e.code}"
    print(json.dumps({"available": False, "reason": reason}))
except Exception as e:
    print(json.dumps({"available": False, "reason": "UNREACHABLE"}))
PY
)
    [[ -n "$body" ]] || body='{"available":false,"reason":"UNREACHABLE"}'
    _api_ok "$(jq -c --argjson per "$_CENSORCHECK_CREDITS_PER_PROBE" '{credits: .} | .creditsPerProbe = $per' <<< "$body")"
}

_api_tspu_last() {
    if [[ -s "${_TSPU_STORE_DIR}/last.json" ]]; then
        _api_ok "$(jq -c '{run: .}' < "${_TSPU_STORE_DIR}/last.json")"
    else
        _api_ok '{"run":null}'
    fi
}

_api_tspu_runs() {
    local limit="${1:-30}"
    [[ "$limit" =~ ^[0-9]+$ ]] || limit=30
    local dir="${_TSPU_STORE_DIR}/runs" files=()
    if [[ -d "$dir" ]]; then
        mapfile -t files < <(find "$dir" -maxdepth 1 -name '[0-9]*.json' -printf '%f\n' | sort -r | head -n "$limit")
    fi
    local body="" f
    for f in ${files[@]+"${files[@]}"}; do
        body+=$(jq -c '{id, startedAt, finishedAt, source, summary,
                        blocked: [.servers[] | select((.atlasStatus // .status) == "blocked") | .name]}' < "${dir}/${f}" 2>/dev/null)$'\n'
    done
    _api_ok "$(jq -sc '{runs: .}' <<< "$body")"
}

_api_tspu_get() {
    local id="$1"
    [[ "$id" =~ ^[0-9]{8}-[0-9]{6}$ ]] || { _api_err BAD_ID "Некорректный id прогона."; return; }
    local f="${_TSPU_STORE_DIR}/runs/${id}.json"
    [[ -s "$f" ]] || { _api_err NOT_FOUND "Прогона ${id} нет в истории."; return; }
    _api_ok "$(jq -c '{run: .}' < "$f")"
}

_api_tspu_preflight() {
    [[ -n "${RIPE_API_KEY:-}" ]] || { _api_err RIPE_NOT_CONFIGURED "RIPE Atlas API-ключ не настроен (меню Решалы → Skynet → ТСПУ → [k])."; return 1; }
    [[ -f "$_TSPU_PROBE_SCRIPT" ]] || { _api_err INSTALL_BROKEN "Нет tspu_probe.py — переустанови Решалу."; return 1; }
    command -v python3 >/dev/null || { _api_err NO_PYTHON "На сервере нет python3."; return 1; }
}

_api_tspu_run() {
    _api_tspu_preflight || return
    [[ -s "$FLEET_DATABASE_FILE" ]] || { _api_err FLEET_EMPTY "Флот пуст — нечего проверять."; return; }
    if [[ "$(_api_tspu_running_json)" != "null" ]]; then
        _api_err ALREADY_RUNNING "Проверка уже идёт."
        return
    fi
    # Отдельный процесс без терминала: прогон идёт минуты, SSH-сессия панели
    # столько не ждёт. Замок берёт уже он сам.
    local exec_path; exec_path=$(_skynet_censorcheck_cron_exec_path)
    setsid nohup "$exec_path" censorcheck-report --api >> "$LOGFILE" 2>&1 < /dev/null &
    disown 2>/dev/null || true
    # Дать процессу взять замок, чтобы следующий status уже видел прогон.
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        [[ "$(_api_tspu_running_json)" != "null" ]] && break
        sleep 0.3
    done
    log "Skynet API: проверка ТСПУ запущена из панели."
    _api_ok "$(jq -nc --argjson running "$(_api_tspu_running_json)" '{started: true, running: $running}')"
}

# Разовая проверка адреса не из флота - тот же замер, что у сервера флота
# (см. _skynet_censorcheck_check_address), но в фоне и с результатом в JSON.
_api_tspu_check() {
    _api_tspu_preflight || return
    _api_read_input || { _api_err BAD_INPUT "Ожидается JSON-объект в stdin."; return; }
    local target sni
    target=$(_api_in target); target="${target// /}"
    target="${target#*://}"; target="${target%%/*}"; target="${target%%:*}"
    sni=$(_api_in sni)

    local ip=""
    if [[ "$target" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        local octet
        for octet in "${BASH_REMATCH[@]:1}"; do
            (( 10#$octet <= 255 )) || { _api_err BAD_TARGET "Некорректный IP-адрес: ${target}"; return; }
        done
        ip="$target"
        sni="${sni:-${TSPU_REALITY_SNI:-max.ru}}"
    elif _api_valid_host "$target" && [[ "$target" == *.* ]]; then
        ip=$(python3 -c 'import socket, sys; print(socket.gethostbyname(sys.argv[1]))' "$target" 2>/dev/null)
        [[ -n "$ip" ]] || { _api_err RESOLVE_FAILED "Не удалось получить IPv4-адрес домена ${target}."; return; }
        sni="${sni:-$target}"
    else
        _api_err BAD_TARGET "Это не IPv4-адрес и не домен: ${target}"
        return
    fi
    _api_valid_host "$sni" || { _api_err BAD_SNI "Некорректный SNI: ${sni}"; return; }

    mkdir -p "$_API_CHECKS_DIR"
    local id; id="$(date -u '+%Y%m%d-%H%M%S')-$((RANDOM % 9000 + 1000))"
    local out="${_API_CHECKS_DIR}/${id}.json" started; started=$(_api_now)
    jq -nc --arg t "$target" --arg ip "$ip" --arg sni "$sni" --arg at "$started" \
        '{status: "running", target: $t, ip: $ip, sni: $sni, startedAt: $at}' > "$out"

    # Фоновый подпроцесс этой же оболочки: все функции модуля уже загружены.
    (
        trap '' HUP
        local tmp_dir; tmp_dir=$(mktemp -d)
        local probes_out; probes_out=$(_skynet_tspu_py probes "$RIPE_API_KEY" 2>/dev/null)
        printf '1\t%s\n' "$ip" > "${tmp_dir}/.targets"
        echo "${target} (${ip})" > "${tmp_dir}/1.name"
        echo "fleet" > "${tmp_dir}/1.category"
        echo 1 > "${tmp_dir}/.count"
        _skynet_tspu_py fleet "$RIPE_API_KEY" "$sni" "${tmp_dir}/.targets" "$tmp_dir" >/dev/null 2>&1
        _skynet_tspu_summarize_server "$tmp_dir" 1 > "${tmp_dir}/1.result"
        printf '%s\n' "$probes_out" > "${tmp_dir}/.probes"
        _skynet_tspu_asn_names_file "${tmp_dir}/.asnnames"
        python3 "$_TSPU_STORE_SCRIPT" check "$tmp_dir" "$out" "${tmp_dir}/.probes" "${tmp_dir}/.asnnames" \
            "$started" "$target" "$ip" "$sni" 2>/dev/null \
            || jq -nc --arg t "$target" --arg at "$started" '{status: "error", target: $t, startedAt: $at, message: "Не удалось разобрать результат замера."}' > "$out"
        log "CensorCheck: проверка ${target} (${ip}, SNI ${sni}) из панели — $(head -1 "${tmp_dir}/1.result")"
        rm -rf "$tmp_dir"
        # Старые разовые проверки не копятся бесконечно.
        find "$_API_CHECKS_DIR" -name '*.json' -mtime +30 -delete 2>/dev/null
    ) > /dev/null 2>&1 < /dev/null &
    disown 2>/dev/null || true

    _api_ok "$(jq -nc --arg id "$id" --arg t "$target" --arg ip "$ip" --arg sni "$sni" \
        '{id: $id, target: $t, ip: $ip, sni: $sni, status: "running"}')"
}

_api_tspu_check_get() {
    local id="$1"
    [[ "$id" =~ ^[0-9]{8}-[0-9]{6}-[0-9]{4}$ ]] || { _api_err BAD_ID "Некорректный id проверки."; return; }
    local f="${_API_CHECKS_DIR}/${id}.json"
    [[ -s "$f" ]] || { _api_err NOT_FOUND "Проверки ${id} нет."; return; }
    _api_ok "$(jq -c '{check: .}' < "$f")"
}

# Настройки проверки. Все поля необязательны - меняется только переданное:
#   sni         - SNI для пробы;
#   schedule    - ["HH:MM", ...] по Москве, целиком заменяет расписание;
#   excluded    - [имя, ...] исключённые из проверки серверы, целиком;
#   thresholds  - {replaceCityShare, replaceAvgThreshold, redBlockedShare,
#                  infraOkThreshold, infraRedBlockedShare}, проценты 1-100.
_api_tspu_settings() {
    _api_read_input || { _api_err BAD_INPUT "Ожидается JSON-объект в stdin."; return; }

    if _api_has sni; then
        local sni; sni=$(_api_in sni)
        _api_valid_host "$sni" && [[ "$sni" == *.* ]] || { _api_err BAD_SNI "Некорректный SNI: ${sni}"; return; }
    fi

    local -a times=()
    if _api_has schedule; then
        jq -e '.schedule | type == "array"' >/dev/null <<< "$_API_INPUT" || { _api_err BAD_SCHEDULE "schedule — массив «ЧЧ:ММ»."; return; }
        local t
        while IFS= read -r t; do
            [[ "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { _api_err BAD_SCHEDULE "Время «${t}» — нужно ЧЧ:ММ."; return; }
            times+=("$t")
        done < <(jq -r '.schedule[] | tostring' <<< "$_API_INPUT" | sort -u)
        (( ${#times[@]} <= 24 )) || { _api_err BAD_SCHEDULE "Не больше 24 запусков в день."; return; }
    fi

    local excluded_csv=""
    if _api_has excluded; then
        jq -e '.excluded | type == "array" and all(type == "string")' >/dev/null <<< "$_API_INPUT" \
            || { _api_err BAD_EXCLUDED "excluded — массив имён серверов."; return; }
        local ex
        while IFS= read -r ex; do
            _api_valid_name "$ex" || { _api_err BAD_EXCLUDED "Некорректное имя: ${ex}"; return; }
            [[ "$ex" != *","* ]] || { _api_err BAD_EXCLUDED "Имя с запятой нельзя исключить: ${ex}"; return; }
            excluded_csv+="${excluded_csv:+,}${ex}"
        done < <(jq -r '.excluded[]' <<< "$_API_INPUT")
    fi

    local -A th_keys=([replaceCityShare]=TSPU_REPLACE_CITY_SHARE [replaceAvgThreshold]=TSPU_REPLACE_AVG_THRESHOLD
                      [redBlockedShare]=TSPU_RED_BLOCKED_SHARE [infraOkThreshold]=TSPU_INFRA_OK_THRESHOLD
                      [infraRedBlockedShare]=TSPU_INFRA_RED_BLOCKED_SHARE)
    local -A th_new=()
    if _api_has thresholds; then
        local k v
        while IFS=$'\t' read -r k v; do
            [[ -n "${th_keys[$k]:-}" ]] || { _api_err BAD_THRESHOLD "Неизвестный порог: ${k}"; return; }
            [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 100 )) || { _api_err BAD_THRESHOLD "Порог ${k}: целое 1–100."; return; }
            th_new[${th_keys[$k]}]="$v"
        done < <(jq -r '.thresholds | to_entries[] | "\(.key)\t\(.value)"' <<< "$_API_INPUT")
    fi

    # Всё проверено - только теперь пишем, чтобы ошибка в одном поле не
    # оставила настройки применёнными наполовину.
    if _api_has sni; then
        set_config_var "TSPU_REALITY_SNI" "$(_api_in sni)"
        TSPU_REALITY_SNI="$(_api_in sni)"
    fi
    if _api_has schedule; then
        if (( ${#times[@]} )); then
            _skynet_censorcheck_write_cron "${times[@]}"
        else
            _skynet_censorcheck_clear_cron >/dev/null 2>&1
            rm -f "$_CENSORCHECK_CRON_FILE" 2>/dev/null
        fi
    fi
    _api_has excluded && set_config_var "TSPU_EXCLUDED_SERVERS" "$excluded_csv"
    local key
    for key in "${!th_new[@]}"; do
        set_config_var "$key" "${th_new[$key]}"
        printf -v "$key" '%s' "${th_new[$key]}"
    done
    log "Skynet API: настройки проверки ТСПУ изменены из панели."
    _api_tspu_status
}

# ------------------------------------------------------------ #
#                        ТОЧКИ ВХОДА                           #
# ------------------------------------------------------------ #

_api_main() {
    if ! command -v jq >/dev/null 2>&1; then
        ensure_package "jq" >/dev/null 2>&1 || true
        command -v jq >/dev/null 2>&1 || { echo '{"ok":false,"error":"NO_JQ","message":"jq не установлен"}'; return 1; }
    fi

    local group="${1:-}" action="${2:-}"
    shift 2 2>/dev/null || shift $#
    case "${group} ${action}" in
        "version "|"version")
            _api_ok "$(jq -nc --arg v "$VERSION" '{version: $v, api: 1}')" ;;
        "fleet list")    _api_fleet_list ;;
        "fleet ping")    _api_fleet_ping ;;
        "fleet hostkey") _api_fleet_hostkey "$@" ;;
        "fleet add")     _api_fleet_add ;;
        "fleet update")  _api_fleet_update "$@" ;;
        "fleet delete")  _api_fleet_delete "$@" ;;
        "tspu status")   _api_tspu_status ;;
        "tspu last")     _api_tspu_last ;;
        "tspu credits")  _api_tspu_credits ;;
        "tspu runs")     _api_tspu_runs "$@" ;;
        "tspu get")      _api_tspu_get "$@" ;;
        "tspu run")      _api_tspu_run ;;
        "tspu check")    _api_tspu_check ;;
        "tspu check-get") _api_tspu_check_get "$@" ;;
        "tspu settings") _api_tspu_settings ;;
        *) _api_err UNKNOWN_ACTION "Неизвестное действие: ${group} ${action}" ;;
    esac
}

# Вход для ключа панели в authorized_keys:
#   command="/usr/local/bin/reshala api-ssh",restrict ssh-ed25519 AAAA... servix
# SSH кладёт присланную команду в SSH_ORIGINAL_COMMAND. Её НЕ исполняем как
# шелл: режем на слова, каждое - из узкого алфавита, первое - "api".
_api_ssh_entry() {
    local -a words=()
    read -ra words <<< "${SSH_ORIGINAL_COMMAND:-}"
    # "reshala api ..." и "api ..." - одно и то же.
    [[ "${words[0]:-}" == "reshala" ]] && words=("${words[@]:1}")
    if [[ "${words[0]:-}" != "api" ]]; then
        echo '{"ok":false,"error":"FORBIDDEN","message":"Этим ключом можно вызывать только reshala api."}'
        return 1
    fi
    local w
    for w in "${words[@]}"; do
        if [[ ! "$w" =~ ^[A-Za-z0-9._:-]{1,64}$ ]]; then
            echo '{"ok":false,"error":"FORBIDDEN","message":"Недопустимые символы в команде."}'
            return 1
        fi
    done
    _api_main "${words[@]:1}"
}
