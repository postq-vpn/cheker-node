#!/bin/bash
# ============================================================ #
# ==      SKYNET: ОТЧЁТ "БЛОКИРОВКА ТСПУ" В TELEGRAM         == #
# ============================================================ #
#
# По расписанию (несколько раз в день) проверяет доступность IP каждого
# сервера флота из сетей российских операторов через реальные зонды
# RIPE Atlas (тот же метод измерения, что в публичном censorcheck.tlab.pw,
# но со своим API-ключом - см. tspu_probe.py). Проверка бьёт напрямую по IP
# из базы флота, без захода на сам сервер по SSH. Присылает сводный отчёт
# в Telegram. Работает и из TUI (настройка/ручной запуск), и headless из
# cron (см. reshala.sh -> censorcheck-report).
#
# Зонды набираются ПО ГОРОДАМ, а не по операторам: ТСПУ ставят у оператора
# в конкретном регионе, поэтому в отчёте есть раздел "География блокировок"
# с городами, где сервер недоступен, и операторами, чьи сети его режут.
#
# @menu.manifest
# @item( skynet | t | ${C_RED}📡 Отчёт "Блокировка ТСПУ" в Telegram${C_RESET} | _skynet_censorcheck_menu | 50 | 2 | Проверка блокировок ТСПУ по городам России через RIPE Atlas по расписанию с отчётом в Telegram. )
#

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1 # Защита от прямого запуска

# Нужен для _skynet_norm_category (категория "infra" меняет формат вердикта
# в отчёте ТСПУ). Модуль запускается и напрямую из cron через run_module,
# где menu.sh не sourced - зависимость объявляется здесь явно.
source "${SCRIPT_DIR}/modules/skynet/db.sh"

_CENSORCHECK_CRON_FILE="/etc/cron.d/reshala-censorcheck"
_TSPU_PROBE_SCRIPT="${SCRIPT_DIR}/modules/skynet/tspu_probe.py"

# Вердикт последней проверки ТСПУ по инфра-серверам - отдельно от Telegram
# отчёта. Читает plugins/dashboard_widgets/05_infra_tspu.sh: виджет
# пересобирается каждую минуту, а зонды RIPE Atlas бьют по расписанию
# несколько раз в день, так что показывать на дашборде можно только то, что
# уже здесь сохранено, без нового замера.
_TSPU_INFRA_STATE_FILE="/etc/reshala/tspu_infra.state"

# Сколько проверок в день считаем нормой. Дальше добавлять можно, но со
# спросом: каждый прогон создаёт измерение RIPE Atlas на КАЖДЫЙ сервер флота
# (кредиты не бесконечные, см. _skynet_censorcheck_probe_set_menu) и
# присылает ещё одно сообщение в Telegram.
_CENSORCHECK_SOFT_LIMIT=4

# sslcert-измерение стоит 10 кредитов RIPE Atlas за каждый ответивший зонд.
# Нужно, чтобы показать цену прогона до того, как её увидят по факту
# списания.
_CENSORCHECK_CREDITS_PER_PROBE=10

# Время запуска и отметка в отчёте — московские (RESHALA_TZ и
# RESHALA_TZ_OFFSET_MIN из config/reshala.conf), а не по часовому поясу
# сервера: у VPS это почти всегда UTC, и отчёт приходил на 3 часа позже.

# Те же ASN российских операторов, что и в исходном censorcheck.sh -
# только для перевода номера ASN в человекочитаемое имя в отчёте.
declare -A _TSPU_ASN_NAMES=(
    [12389]="Ростелеком"
    [8402]="Билайн"
    [25513]="МГТС"
    [8359]="МТС"
    [3216]="Билайн"
    [20485]="ТТК"
    [25490]="РТК-Юг"
    [43727]="Мегафон"
    [12714]="Мегафон"
    [34757]="Sib Seti"
    [29124]="Iskratelecom"
    [12768]="Дом.ру"
)

# ============================================================ #
#                        TELEGRAM                              #
# ============================================================ #

# Экранирует спецсимволы HTML в тексте, который подставляется внутрь
# <b>/<blockquote> и т.п. (имена серверов из базы флота вводит сам
# пользователь и не должны ломать разметку сообщения).
# Русское склонение при числе: 1 зонд, 2 зонда, 5 зондов, 11 зондов.
_skynet_censorcheck_plural() {
    local n="$1" one="$2" few="$3" many="$4"
    local n100=$(( n % 100 )) n10=$(( n % 10 ))

    if [[ "$n100" -ge 11 && "$n100" -le 14 ]]; then
        printf '%s' "$many"
    elif [[ "$n10" -eq 1 ]]; then
        printf '%s' "$one"
    elif [[ "$n10" -ge 2 && "$n10" -le 4 ]]; then
        printf '%s' "$few"
    else
        printf '%s' "$many"
    fi
}

_skynet_censorcheck_html_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    printf '%s' "$s"
}

# Разбор CSV-списка TSPU_EXCLUDED_SERVERS в массив имён. У серверов флота
# имена часто вида "Город – IP" с самыми настоящими пробелами внутри (это
# не мусор, так их назвал пользователь) - поэтому обрезаем пробелы только
# по КРАЯМ каждого элемента (последствия старого мусора вида "a, b"), а не
# вычищаем их из строки целиком, как это можно делать с именами файлов
# (см. ENABLED_WIDGETS в modules/ui/widget_manager.sh, где пробелов в
# именах не бывает в принципе).
_skynet_tspu_csv_items() {
    local csv="$1" item
    local -a raw=()
    IFS=',' read -ra raw <<< "$csv"
    for item in "${raw[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [[ -n "$item" ]] && printf '%s\n' "$item"
    done
}

# Есть ли имя в CSV-списке (точное совпадение после обрезки пробелов по краям).
_skynet_tspu_csv_contains() {
    local needle="$1" csv="$2" item
    while IFS= read -r item; do
        [[ "$item" == "$needle" ]] && return 0
    done < <(_skynet_tspu_csv_items "$csv")
    return 1
}

# Убирает имя из CSV-списка, попутно схлопывая накопившийся мусор пробелов
# вокруг запятых (наследие бага с tr -d ' ').
_skynet_tspu_csv_remove() {
    local needle="$1" csv="$2" item out=""
    while IFS= read -r item; do
        [[ "$item" == "$needle" ]] && continue
        out+="${out:+,}${item}"
    done < <(_skynet_tspu_csv_items "$csv")
    printf '%s' "$out"
}

# Сколько серверов сейчас исключено из проверки ТСПУ (TSPU_EXCLUDED_SERVERS,
# меню [s]). Используется и в отчёте, и в прикидке цены прогона, и в статусе
# главного меню — чтобы список не разъезжался с реальным подсчётом.
_skynet_tspu_excluded_count() {
    local excluded; excluded=$(get_config_var "TSPU_EXCLUDED_SERVERS")
    _skynet_tspu_csv_items "$excluded" | grep -c .
}

# Отправляет ОДИН кусок текста (<=4096 символов) в Telegram.
# Печатает HTTP-код ответа в stdout.
_skynet_censorcheck_tg_send_chunk() {
    local text="$1"
    local token="${TG_BOT_TOKEN:-}"
    local chat_id="${TG_CHAT_ID:-}"
    local topic_id="${TG_TOPIC_ID:-}"

    # message_thread_id нужен только для групп с включёнными «Темами» (топиками):
    # без него сообщение уходит в General. Пустой TG_TOPIC_ID — старое поведение.
    local -a topic_args=()
    [[ -n "$topic_id" ]] && topic_args=(--data-urlencode "message_thread_id=${topic_id}")

    # Тело ответа держим отдельно от кода: при ошибке Telegram присылает
    # причину текстом ("can't parse entities: ..." и т.п.) - без неё
    # ОШИБКА в логе означает только "не удалось", без единой зацепки, что
    # чинить.
    local body_file; body_file=$(mktemp)
    local http_code
    http_code=$(curl -s -m 20 -X POST "https://api.telegram.org/bot${token}/sendMessage" \
        --data-urlencode "chat_id=${chat_id}" \
        ${topic_args[@]+"${topic_args[@]}"} \
        --data-urlencode "text=${text}" \
        --data-urlencode "parse_mode=HTML" \
        -o "$body_file" -w '%{http_code}')

    if [[ "$http_code" != "200" ]]; then
        log "CensorCheck: Telegram ответил ${http_code}: $(tr -d '\n' < "$body_file" | cut -c1-500)"
    fi
    rm -f "$body_file"

    printf '%s' "$http_code"
}

# Отправляет произвольно длинный текст, разбивая его на несколько
# сообщений по границам строк, если он не влезает в лимит Telegram.
# Возвращает 0, если ВСЕ куски доставлены успешно.
#
# Резать разрешено только СНАРУЖИ <blockquote>: разрез посреди открытого
# тега отправляет Telegram половину пары ("Can't find end tag..." /
# "Unexpected end tag...") и валит ВЕСЬ кусок, а не только форматирование.
# Поэтому пока открыт хотя бы один blockquote, чанк копится дальше,
# даже за счёт max_len - overshoot на один блок безопаснее гарантированно
# битого HTML.
_skynet_censorcheck_tg_send() {
    local full_text="$1"
    local token="${TG_BOT_TOKEN:-}"
    local chat_id="${TG_CHAT_ID:-}"

    if [[ -z "$token" || -z "$chat_id" ]]; then
        return 1
    fi

    local max_len=3500
    local chunk="" all_ok=0 http_code
    local depth=0 line

    # "< <(printf ...)", а не "<<< "$full_text"": here-string дописывает свой
    # собственный "\n" в конец, а $full_text и так уже кончается на "\n" -
    # на выходе лишняя пустая "строка", которая при многочастевой отправке
    # улетает Telegram отдельным пустым сообщением ("text must be non-empty").
    while IFS= read -r line; do
        if (( depth == 0 )) && (( ${#chunk} + ${#line} + 1 > max_len )) && [[ -n "$chunk" ]]; then
            http_code=$(_skynet_censorcheck_tg_send_chunk "$chunk")
            [[ "$http_code" != "200" ]] && all_ok=1
            chunk=""
        fi
        chunk+="${line}"$'\n'

        case "$line" in *'</blockquote>'*) depth=$((depth - 1)) ;; esac
        case "$line" in *'<blockquote'*) depth=$((depth + 1)) ;; esac
        (( depth < 0 )) && depth=0
    done < <(printf '%s' "$full_text")

    if [[ -n "$chunk" ]]; then
        http_code=$(_skynet_censorcheck_tg_send_chunk "$chunk")
        [[ "$http_code" != "200" ]] && all_ok=1
    fi

    return "$all_ok"
}

_skynet_censorcheck_configure_telegram() {
    clear
    menu_header "📡 Настройка Telegram"
    echo ""
    printf_description "1. Напишите @BotFather в Telegram и создайте бота — получите TG_BOT_TOKEN."
    printf_description "2. Отправьте созданному боту любое сообщение (например /start)."
    printf_description "3. Откройте в браузере (замените <TOKEN> на свой):"
    printf_description "   https://api.telegram.org/bot<TOKEN>/getUpdates"
    printf_description "4. Найдите там \"chat\":{\"id\":ЧИСЛО — это ваш TG_CHAT_ID."
    printf_description "5. Для группы с топиками: TG_TOPIC_ID — это message_thread_id из getUpdates"
    printf_description "   (или число из ссылки на сообщение: t.me/c/<чат>/<ТОПИК>/<сообщение>)."
    echo ""
    printf_description "Хранится в ${C_CYAN}${RESHALA_ENV_FILE}${C_RESET} (права 600), не в общем конфиге."
    echo ""

    # Токен вводится скрыто (как sudo-пароли в этом проекте) и никогда не
    # показывается на экране как значение по умолчанию — даже если он уже
    # сохранён. Пустой ввод при повторной настройке оставляет прежний токен.
    local token
    if [[ -n "${TG_BOT_TOKEN:-}" ]]; then
        token=$(ask_password "TG_BOT_TOKEN (уже сохранён, Enter — оставить как есть): ") || return
        [[ -z "$token" ]] && token="$TG_BOT_TOKEN"
    else
        token=$(ask_password "TG_BOT_TOKEN: ") || return
        if [[ -z "$token" ]]; then
            printf_error "Токен не может быть пустым."
            wait_for_enter
            return
        fi
    fi

    local chat_id; chat_id=$(ask_non_empty "TG_CHAT_ID" "${TG_CHAT_ID:-}") || return

    # Топик необязателен. Пустой ввод оставляет прежнее значение, «-» сбрасывает
    # его (отчёты пойдут в основной чат/General).
    local topic_id
    topic_id=$(safe_read "TG_TOPIC_ID (необязательно, «-» — сбросить)" "${TG_TOPIC_ID:-}") || return
    if [[ "$topic_id" == "-" ]]; then
        topic_id=""
    elif [[ -n "$topic_id" && ! "$topic_id" =~ ^[0-9]+$ ]]; then
        printf_error "TG_TOPIC_ID должен быть числом."
        wait_for_enter
        return
    fi

    # Храним в /etc/reshala/.env (см. common.sh), а не в config/reshala.conf:
    # это секрет, и он должен пережить переустановку/обновление Решалы.
    set_env_var "TG_BOT_TOKEN" "$token"
    set_env_var "TG_CHAT_ID" "$chat_id"
    set_env_var "TG_TOPIC_ID" "$topic_id"
    TG_BOT_TOKEN="$token"
    TG_CHAT_ID="$chat_id"
    TG_TOPIC_ID="$topic_id"

    printf_info "Отправляю тестовое сообщение..."
    if _skynet_censorcheck_tg_send "✅ Решала: Telegram настроен. Сюда будут приходить отчёты «Блокировка ТСПУ»."; then
        printf_ok "Готово. Проверьте Telegram."
    else
        printf_error "Не удалось отправить тестовое сообщение. Проверьте токен и chat_id."
    fi
    wait_for_enter
}

_skynet_censorcheck_configure_ripe() {
    clear
    menu_header "🛰 Настройка RIPE Atlas (радар ТСПУ)"
    echo ""
    printf_description "Отчёт проверяет доступность IP серверов из сетей российских"
    printf_description "операторов через реальные зонды RIPE Atlas (тот же метод, что"
    printf_description "и в censorcheck.tlab.pw, но со СВОИМ ключом - автор скрипта"
    printf_description "прямо просит не использовать его ключ в сторонних проектах)."
    echo ""
    printf_description "Как получить свой ключ (бесплатно, пару минут):"
    printf_description "1. Зарегистрируйся на ${C_CYAN}https://atlas.ripe.net${C_RESET}"
    printf_description "2. Профиль -> ${C_CYAN}My API Keys${C_RESET} -> Create -> дай права"
    printf_description "   на создание измерений (Measurement creation)."
    printf_description "3. Скопируй ключ сюда."
    echo ""
    printf_description "Хранится в ${C_CYAN}${RESHALA_ENV_FILE}${C_RESET} (права 600), не в общем конфиге."
    echo ""

    local key
    if [[ -n "${RIPE_API_KEY:-}" ]]; then
        key=$(ask_password "RIPE_API_KEY (уже сохранён, Enter — оставить как есть): ") || return
        [[ -z "$key" ]] && key="$RIPE_API_KEY"
    else
        key=$(ask_password "RIPE_API_KEY: ") || return
        if [[ -z "$key" ]]; then
            printf_error "Ключ не может быть пустым."
            wait_for_enter
            return
        fi
    fi

    echo ""
    printf_description "SNI, под который маскируется проверка (например, домен из вашего"
    printf_description "Reality-конфига). По умолчанию как в исходном скрипте: max.ru"
    local sni; sni=$(ask_non_empty "SNI для пробы" "${TSPU_REALITY_SNI:-max.ru}") || return

    set_env_var "RIPE_API_KEY" "$key"
    RIPE_API_KEY="$key"
    set_config_var "TSPU_REALITY_SNI" "$sni"
    TSPU_REALITY_SNI="$sni"

    printf_ok "Сохранено."
    wait_for_enter
}

# ============================================================ #
#                РАДАР ТСПУ (RIPE ATLAS, БЕЗ SSH)               #
# ============================================================ #
#
# В отличие от полного censorcheck.tlab.pw (который гоняется ПО SSH НА
# каждом сервере флота и проверяет заодно ~30 внешних доменов), проверка
# ТСПУ бьёт зондами RIPE Atlas напрямую в IP сервера - для этого не нужно
# заходить на сам сервер, IP уже есть в базе флота. Поэтому эта часть
# выполняется локально с контрольного хоста, параллельно по всем серверам.

# Запуск tspu_probe.py. Настройки выборки лежат в config/reshala.conf
# обычными переменными оболочки (без export), а питон читает их из
# окружения - поэтому пробрасываем здесь, а не засоряем конфиг экспортами.
_skynet_tspu_py() {
    TSPU_CHECK_MODE="${TSPU_CHECK_MODE:-geo}" \
    TSPU_CITY_PROBES="${TSPU_CITY_PROBES:-5}" \
    TSPU_CITY_MIN_PROBES="${TSPU_CITY_MIN_PROBES:-5}" \
    TSPU_PROBE_STRICT_GEO="${TSPU_PROBE_STRICT_GEO:-0}" \
    TSPU_CONTROL_IP="${TSPU_CONTROL_IP:-}" \
    TSPU_CONTROL_SNI="${TSPU_CONTROL_SNI:-}" \
    python3 "$_TSPU_PROBE_SCRIPT" "$@"
}

# Замер по одному IP. Печатает МНОГОСТРОЧНЫЙ блок:
#   OK <percent> <success> <total> <fault> <dead> <noise>
#   ASN <asn> <сколько зондов подтверждённо не дошло>   (0..N строк)
#   CITY <успешно> <всего> <asn,asn|-> <город>          (0..N строк)
# либо одну строку:
#   SKIP <причина>
#
# Перепроверка промахов живёт внутри tspu_probe.py: полный замер делается
# один раз, а повтор и контроль идут только по тем зондам, которые
# промахнулись. Поэтому здесь никаких раундов больше нет.
_skynet_tspu_probe_once() {
    local ip="$1" sni="$2" api_key="$3"

    # Без реально слушающего 443 RIPE Atlas всё равно покажет "заблокировано"
    # для всех зондов - но это не ТСПУ, а просто отсутствие VPN на сервере.
    # Такие случаи не считаем ни OK, ни BLOCKED - помечаем на ручную проверку.
    if ! timeout 4 bash -c "echo > /dev/tcp/${ip}/443" 2>/dev/null; then
        echo "SKIP порт 443 не отвечает (нет VPN/Reality на сервере или сервер недоступен)"
        return
    fi

    local py_out
    py_out=$(_skynet_tspu_py check "$api_key" "$ip" "$sni" 2>/dev/null)

    if [[ -z "$py_out" ]] || [[ "$py_out" == ERROR* ]]; then
        local reason; reason=$(echo "$py_out" | grep "^ERROR" | head -1)
        echo "SKIP RIPE Atlas не ответил (${reason:-нет ответа})"
        return
    fi

    if [[ "$py_out" != OK\ * ]]; then
        echo "SKIP не удалось разобрать ответ RIPE Atlas"
        return
    fi

    echo "$py_out"
}

# Сохраняет вердикт последней проверки ТСПУ по инфра-серверам в файл
# состояния - читает его виджет дашборда (05_infra_tspu.sh), сам он новых
# замеров не делает. Вызывается только когда в флоте вообще есть инфра-
# серверы (пустой $lines означает "нечего сохранять", а не "все пропали").
_skynet_tspu_infra_save_state() {
    local lines="$1" ok="$2" blocked="$3" skip="$4"
    [[ -n "$lines" ]] || return 0

    mkdir -p "$(dirname "$_TSPU_INFRA_STATE_FILE")" 2>/dev/null || true
    {
        printf 'TS=%s\n' "$(msk_date '+%d.%m %H:%M')"
        printf 'OK=%s\n' "$ok"
        printf 'BLOCKED=%s\n' "$blocked"
        printf 'SKIP=%s\n' "$skip"
        printf '%s' "$lines"
    } > "$_TSPU_INFRA_STATE_FILE" 2>/dev/null

    # Виджет 05_infra_tspu.sh на дашборде кэширует свой рендер по TTL
    # (modules/ui/dashboard.sh, WIDGET_CACHE_DIR), а не по mtime этого файла
    # состояния. Без явного сброса дашборд после свежей проверки ещё до
    # DASHBOARD_WIDGET_CACHE_TTL_ADJ (60с, x2/x4 на light/ultra_light) будет
    # показывать старый результат — рвём кэш сразу, чтобы "Решала" подхватил
    # новые данные при следующем же открытии, а не только после ручной
    # очистки кэша виджетов.
    rm -f "/tmp/reshala_widgets_cache/05_infra_tspu.sh.cache" 2>/dev/null || true
}

# Итог по одному серверу. Читает <tmp_dir>/<idx>.out, оставленный
# _skynet_tspu_probe_once, и печатает:
#   AVAILABLE|BLOCKED|SKIP <детали>              - ровно одна первая строка
#   STAT <успешно> <всего>                        - для сводки по флоту
#   CITY <промахов> <процент> <asn,asn|-> <город> - 0..N, только проблемные
#
# Подтверждение промаха живёт в tspu_probe.py: сюда приходят уже только те
# зонды, которые не достучались ДВАЖДЫ и при этом доказали, что живы. Поэтому
# здесь никакого усреднения по раундам нет - одного подтверждённого промаха
# достаточно, чтобы назвать сервер заблокированным.
_skynet_tspu_summarize_server() {
    local tmp_dir="$1" idx="$2" category="${3:-fleet}"
    local file="${tmp_dir}/${idx}.out"

    [[ -s "$file" ]] || { echo "SKIP замер не выполнялся"; return; }

    local head_line; head_line=$(head -1 "$file")
    if [[ "${head_line%% *}" != "OK" ]]; then
        echo "${head_line}"
        return
    fi

    local _tag percent success total fault dead noise
    read -r _tag percent success total fault dead noise <<< "$head_line"

    # Инфра-серверы (control-plane, панели и т.п., не VPN-ноды) не нужно
    # показывать с точностью до процента и городов - только грубый вердикт
    # по порогу: доступен, если пробилось хотя бы 60% зондов, иначе нет.
    if [[ "$category" == "infra" ]]; then
        if [[ "$percent" -ge 60 ]]; then
            echo "AVAILABLE"
        else
            echo "BLOCKED недоступен"
        fi
        echo "STAT ${success} ${total}"
        return
    fi

    local blocked=$(( total - success ))

    # Что осталось за кадром процента: зонды со своей сетевой аварией и
    # отвалившиеся между замерами. Говорим об этом, только когда выборка
    # просела заметно - иначе это одинаковый хвост у каждой строки отчёта.
    local aside=$(( fault + dead ))
    local note=""
    if [[ "$aside" -gt 0 && $(( aside * 100 / (total + aside) )) -ge 20 ]]; then
        note=" · в расчёт пошло ${total} $(_skynet_censorcheck_plural "$total" зонд зонда зондов) из $(( total + aside ))"
    fi

    # Операторы в строке сервера не называются: кто именно режет - вопрос
    # места, и ответ на него даётся в разделе по городам, где ASN привязан
    # к конкретному городу и потому что-то значит.
    if [[ "$blocked" -eq 0 ]]; then
        echo "AVAILABLE${note:+ ${note# · }}"
    else
        echo "BLOCKED доступно ${percent}% (${success}/${total})${note}"
    fi

    # Машиночитаемая строка для сводки по флоту: складывать проценты серверов
    # напрямую нельзя, у них разные знаменатели.
    echo "STAT ${success} ${total}"

    # Города python отдаёт уже отфильтрованными - только те, где есть
    # подтверждённые промахи. Пересчитываем в проценты и сортируем по
    # тяжести, худшие сверху.
    local _c c_ok c_tot c_asns c_name c_pct
    while read -r _c c_ok c_tot c_asns c_name; do
        [[ -n "$c_name" ]] || continue
        c_pct=0
        [[ "$c_tot" -gt 0 ]] && c_pct=$(( c_ok * 100 / c_tot ))
        echo "CITY $(( c_tot - c_ok )) ${c_pct} ${c_asns} ${c_name}"
    done < <(grep '^CITY ' "$file") | sort -t' ' -k3,3n
}

# Прогоняет весь флот (без SSH, напрямую по IP из базы флота). Результаты -
# в файлах внутри временной директории, путь к которой печатает в stdout:
#   <tmp_dir>/N.name    - "Имя (IP)"
#   <tmp_dir>/N.out     - сырой выхлоп замера сервера N
#   <tmp_dir>/N.result  - вердикт + строки CITY (см. _skynet_tspu_summarize_server)
#   <tmp_dir>/.count    - количество проверенных серверов N
#   <tmp_dir>/.excluded - имена серверов, пропущенных по TSPU_EXCLUDED_SERVERS
#                         (по одному в строке), файла нет, если таких нет
#
# Серверы идут ПАРАЛЛЕЛЬНО, по одному замеру на сервер: перепроверка промахов
# спрятана внутрь tspu_probe.py и тратит замеры только на те зонды, которым
# есть что подтверждать.
_skynet_tspu_check_fleet_parallel() {
    local sni="$1" api_key="$2"
    local tmp_dir; tmp_dir=$(mktemp -d)

    local excluded; excluded=$(get_config_var "TSPU_EXCLUDED_SERVERS")

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
        # Хвостовой \r (частый гость при вставке в SSH-терминал из Windows)
        # иначе никогда не совпадёт со списком исключений.
        name="${name%$'\r'}"

        # Исключённый сервер не бьётся зондами вообще - имя откладывается для
        # отчёта, а сам сервер даже не входит в счётчик .count.
        if _skynet_tspu_csv_contains "$name" "$excluded"; then
            echo "$name" >> "${tmp_dir}/.excluded"
            continue
        fi

        i=$((i + 1))
        echo "${name} (${ip})" > "${tmp_dir}/${i}.name"
        echo "$category" > "${tmp_dir}/${i}.category"
        ( _skynet_tspu_probe_once "$ip" "$sni" "$api_key" > "${tmp_dir}/${i}.out" ) &
        pids+=("$!")
    done

    if [[ ${#pids[@]} -gt 0 ]]; then
        wait "${pids[@]}" 2>/dev/null
    fi

    echo "$i" > "${tmp_dir}/.count"

    local idx idx_category
    for ((idx = 1; idx <= i; idx++)); do
        idx_category=$(cat "${tmp_dir}/${idx}.category" 2>/dev/null || echo fleet)
        _skynet_tspu_summarize_server "$tmp_dir" "$idx" "$idx_category" > "${tmp_dir}/${idx}.result"
    done

    echo "$tmp_dir"
}

# ============================================================ #
#                     ЗАПУСК ПРОВЕРКИ И ОТЧЁТ                  #
# ============================================================ #

# _skynet_censorcheck_run_and_report [--cron]
# --cron подавляет интерактивный вывод (для запуска без TTY).
_skynet_censorcheck_run_and_report() {
    local mode="${1:-}"
    local verbose=1
    [[ "$mode" == "--cron" ]] && verbose=0

    ensure_package "curl" >/dev/null 2>&1 || true
    ensure_package "python3" >/dev/null 2>&1 || true

    if [[ -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then
        [[ "$verbose" -eq 1 ]] && printf_error "TG_BOT_TOKEN/TG_CHAT_ID не настроены (пункт [n])."
        log "CensorCheck: TG_BOT_TOKEN/TG_CHAT_ID не настроены, отчёт не отправлен."
        return 1
    fi

    if [[ -z "${RIPE_API_KEY:-}" ]]; then
        [[ "$verbose" -eq 1 ]] && printf_error "RIPE_API_KEY не настроен (пункт [k])."
        log "CensorCheck: RIPE_API_KEY не настроен, отчёт не отправлен."
        return 1
    fi

    if [[ ! -s "$FLEET_DATABASE_FILE" ]]; then
        [[ "$verbose" -eq 1 ]] && printf_warning "Флот пуст, нечего проверять."
        log "CensorCheck: флот пуст, проверка пропущена."
        return 1
    fi

    if [[ ! -f "$_TSPU_PROBE_SCRIPT" ]]; then
        [[ "$verbose" -eq 1 ]] && printf_error "Скрипт проверки не найден: $_TSPU_PROBE_SCRIPT"
        log "CensorCheck: tspu_probe.py не найден."
        return 1
    fi

    local sni="${TSPU_REALITY_SNI:-max.ru}"

    # Состав выборки берём ДО прогона: заодно кэш зондов соберётся один раз,
    # а не в каждом из параллельных замеров сразу.
    local probes_out; probes_out=$(_skynet_tspu_py probes "$RIPE_API_KEY" 2>/dev/null)
    if [[ "$probes_out" != OK\ * ]]; then
        [[ "$verbose" -eq 1 ]] && printf_error "Не удалось собрать выборку зондов RIPE Atlas (${probes_out:-нет ответа})."
        log "CensorCheck: не удалось собрать выборку зондов (${probes_out:-нет ответа})."
        return 1
    fi

    local _p probe_n city_n
    read -r _p probe_n city_n <<< "$(echo "$probes_out" | head -1)"

    local -a all_cities=()
    mapfile -t all_cities < <(echo "$probes_out" | sed -n 's/^CITY [0-9]* //p')

    # В режиме common городов нет: и строка о выборке, и раздел с географией
    # в отчёте отличаются только этим.
    local sample_line="${probe_n} $(_skynet_censorcheck_plural "$probe_n" зонд зонда зондов)"
    if [[ "$city_n" -gt 0 ]]; then
        sample_line+=" в ${city_n} $(_skynet_censorcheck_plural "$city_n" городе городах городах)"
    else
        sample_line+=" в сетях крупных операторов"
    fi

    if [[ "$verbose" -eq 1 ]]; then
        printf_info "Проверяю доступность всех серверов флота из сетей РФ (RIPE Atlas, параллельно)."
        printf_info "Выборка: ${sample_line}, по одному замеру на сервер."
        printf_info "Промахи перепроверяются отдельно — это займёт пару минут."

        local excluded_pre_n; excluded_pre_n=$(_skynet_tspu_excluded_count)
        if [[ "$excluded_pre_n" -gt 0 ]]; then
            printf_info "Исключено из проверки: ${excluded_pre_n} $(_skynet_censorcheck_plural "$excluded_pre_n" сервер сервера серверов) (меню [s])."
        fi
    fi

    local tmp_dir; tmp_dir=$(_skynet_tspu_check_fleet_parallel "$sni" "$RIPE_API_KEY")
    local count; count=$(cat "${tmp_dir}/.count" 2>/dev/null || echo 0)

    # Все три группы - одинаковый вид: сворачиваемая (expandable) цитата
    # с заголовком-счётчиком, внутри - КАЖДЫЙ сервер отдельной строкой.
    local ok_list="" fail_list="" skip_list=""
    local total=0 ok_n=0 blocked_n=0 skip_n=0 idx name result kind detail esc_name category

    # Инфра (категория "infra") идёт отдельным блоком от основного флота -
    # не в ok_list/fail_list/skip_list, и без веса в fleet_ok/fleet_total:
    # это служебные серверы, а не VPN-ноды, и общий процент доступности
    # флота не должен зависеть от них.
    local infra_list="" infra_ok_n=0 infra_blocked_n=0 infra_skip_n=0
    # "имя|ВЕРДИКТ" по одному на строку - сырьё для _skynet_tspu_infra_save_state,
    # без HTML-экранирования и без IP (виджету он не нужен).
    local infra_state_lines=""

    # Город -> кто в нём недоступен и чьи это сети. Ключ с пробелом внутри
    # ("Нижний Новгород") ассоциативному массиву не мешает.
    local -A city_servers=() city_asns=()

    # Сервер попадает "под замену", когда режется не в одном городе, а
    # системно: заблокирован минимум в TSPU_REPLACE_CITY_SHARE% городов
    # выборки, и средняя доступность по этим городам ниже TSPU_REPLACE_AVG_THRESHOLD%.
    # Один заблокированный город (даже 0%) сам по себе повода не даёт - это
    # может быть локальная особенность конкретной сети, а не сервер целиком.
    local replace_list="" replace_n=0

    # Зонды всего флота в одной куче: доступность по флоту это доля дошедших
    # зондов, а не среднее из процентов серверов - у тех разные знаменатели.
    local fleet_ok=0 fleet_total=0

    for ((idx = 1; idx <= count; idx++)); do
        name=$(cat "${tmp_dir}/${idx}.name" 2>/dev/null)
        result=$(head -1 "${tmp_dir}/${idx}.result" 2>/dev/null)
        category=$(cat "${tmp_dir}/${idx}.category" 2>/dev/null || echo fleet)
        esc_name=$(_skynet_censorcheck_html_escape "$name")

        kind="${result%% *}"
        detail="${result#* }"
        [[ "$detail" == "$result" ]] && detail=""
        detail=$(_skynet_censorcheck_html_escape "$detail")

        # У инфры "total"/skip_n/ok_n/blocked_n не считаются вовсе - это
        # счётчики для секции основного флота, инфра ведёт свои (infra_*).
        if [[ "$category" == "infra" ]]; then
            # Без IP: в имени сервера он приписан как "Имя (IP)" - для
            # виджета на дашборде это лишний шум, там только "Имя".
            local infra_bare_name="${name%% (*}"
            case "$kind" in
                AVAILABLE)
                    infra_ok_n=$((infra_ok_n + 1))
                    infra_list+="• ${esc_name} — <tg-emoji emoji-id=\"5258053251873400722\">✅</tg-emoji> доступен"$'\n'
                    infra_state_lines+="${infra_bare_name}|AVAILABLE"$'\n'
                    ;;
                BLOCKED)
                    infra_blocked_n=$((infra_blocked_n + 1))
                    infra_list+="• ${esc_name} — <tg-emoji emoji-id=\"5258190433128834075\">👎</tg-emoji> не доступен"$'\n'
                    infra_state_lines+="${infra_bare_name}|BLOCKED"$'\n'
                    ;;
                *)
                    infra_skip_n=$((infra_skip_n + 1))
                    infra_list+="• ${esc_name}${detail:+ — ${detail}}"$'\n'
                    infra_state_lines+="${infra_bare_name}|SKIP"$'\n'
                    ;;
            esac
            continue
        fi

        total=$((total + 1))
        case "$kind" in
            AVAILABLE)
                # Деталь у доступного сервера появляется только когда есть что
                # сказать: одиночный промах или неполный набор замеров.
                ok_n=$((ok_n + 1))
                ok_list+="• ${esc_name}${detail:+ — ${detail}}"$'\n'
                ;;
            BLOCKED)
                blocked_n=$((blocked_n + 1))
                fail_list+="• ${esc_name} — ${detail}"$'\n'
                ;;
            *)
                skip_n=$((skip_n + 1))
                skip_list+="• ${esc_name}${detail:+ — ${detail}}"$'\n'
                ;;
        esac

        local _s s_ok s_tot
        read -r _s s_ok s_tot < <(grep '^STAT ' "${tmp_dir}/${idx}.result" 2>/dev/null)
        if [[ -n "${s_tot:-}" ]]; then
            fleet_ok=$(( fleet_ok + s_ok ))
            fleet_total=$(( fleet_total + s_tot ))
        fi

        # В географию идут только те серверы, у которых есть что показать.
        # Имя сервера без IP: в списке городов важно КТО, а адрес уже назван
        # выше в своей секции.
        local short_name; short_name=$(_skynet_censorcheck_html_escape "${name%% (*}")
        local _c miss pct asns city
        local server_city_hits=0 server_pct_sum=0
        while read -r _c miss pct asns city; do
            [[ -n "$city" ]] || continue
            # Каждый сервер - отдельной строкой (не через запятую): в городах
            # с несколькими заблокированными серверами список иначе сливался
            # в нечитаемый абзац.
            city_servers["$city"]+="${short_name} (${pct}%)"$'\n'
            [[ "$asns" != "-" ]] && city_asns["$city"]+="${asns},"
            server_city_hits=$((server_city_hits + 1))
            server_pct_sum=$((server_pct_sum + pct))
        done < <(grep '^CITY ' "${tmp_dir}/${idx}.result" 2>/dev/null)

        # "Под замену": режется системно, не в одном случайном городе -
        # доля городов с подтверждённым промахом и средняя доступность по
        # ним обе должны перевалить за порог.
        if [[ "$city_n" -gt 0 && "$server_city_hits" -gt 0 ]] \
            && (( server_city_hits * 100 >= city_n * ${TSPU_REPLACE_CITY_SHARE:-50} )); then
            local server_avg_pct=$(( server_pct_sum / server_city_hits ))
            if (( server_avg_pct < ${TSPU_REPLACE_AVG_THRESHOLD:-55} )); then
                replace_list+="• ${short_name} — сред. доступность <b>${server_avg_pct}%</b>, блокировка в ${server_city_hits} из ${city_n} городов"$'\n'
                replace_n=$((replace_n + 1))
            fi
        fi
    done

    _skynet_tspu_infra_save_state "$infra_state_lines" "$infra_ok_n" "$infra_blocked_n" "$infra_skip_n"

    # Серверы, исключённые через TSPU_EXCLUDED_SERVERS ([s] в меню) - в
    # проверке не участвовали вовсе, но отчёт должен явно называть, кто
    # пропущен и почему, а не просто молчать о них.
    local excluded_list="" excluded_n=0 ex_name esc_ex_name
    if [[ -f "${tmp_dir}/.excluded" ]]; then
        while IFS= read -r ex_name; do
            [[ -n "$ex_name" ]] || continue
            excluded_n=$((excluded_n + 1))
            esc_ex_name=$(_skynet_censorcheck_html_escape "$ex_name")
            excluded_list+="• ${esc_ex_name}"$'\n'
        done < "${tmp_dir}/.excluded"
    fi

    rm -rf "$tmp_dir"

    # Номера ASN в имена операторов: свои переводы для крупных операторов,
    # для остального - имя держателя ASN из кэша (RIPEstat).
    local -A asn_titles=()
    local a_num a_name
    while IFS=$'\t' read -r a_num a_name; do
        [[ -n "$a_num" ]] || continue
        asn_titles[$a_num]="$a_name"
    done < <(_skynet_tspu_py asnnames 2>/dev/null)

    local geo_list="" clean_list="" city ops op
    for city in "${all_cities[@]}"; do
        [[ -n "$city" ]] || continue
        local esc_city; esc_city=$(_skynet_censorcheck_html_escape "$city")

        if [[ -z "${city_servers[$city]:-}" ]]; then
            clean_list+="${esc_city}, "
            continue
        fi

        ops=""
        for a_num in $(printf '%s' "${city_asns[$city]%,}" | tr ',' '\n' | sort -un); do
            [[ -n "$a_num" ]] || continue
            op="${_TSPU_ASN_NAMES[$a_num]:-${asn_titles[$a_num]:-AS$a_num}}"
            ops+="$(_skynet_censorcheck_html_escape "$op"), "
        done
        ops="${ops%, }"

        # Город + операторы одной строкой-шапкой, каждый сервер - своей
        # строкой с отступом и "↳" (не через запятую при городе, как раньше -
        # это разваливалось на экране при 4-5 серверах).
        geo_list+="• <b>${esc_city}</b>${ops:+ — ${ops}}"$'\n'
        local city_server_line
        while IFS= read -r city_server_line; do
            [[ -n "$city_server_line" ]] || continue
            geo_list+="  ↳ ${city_server_line}"$'\n'
        done <<< "${city_servers[$city]}"
        geo_list+=$'\n'
    done
    # Последний город не должен тащить за собой лишнюю пустую строку перед
    # закрывающим тегом blockquote.
    geo_list="${geo_list%$'\n'}"
    clean_list="${clean_list%, }"
    local hit_cities=${#city_servers[@]}

    # Сводка в процентах. Доступность по флоту считается по зондам, а не как
    # среднее из процентов серверов: у сервера, который не удалось померить,
    # процента нет вовсе, и он не должен тянуть среднее ни вверх, ни вниз.
    local measured=$(( ok_n + blocked_n ))
    local infra_measured=$(( infra_ok_n + infra_blocked_n ))

    # Вердикт-эмодзи идёт первым символом заголовка — виден даже в превью
    # пуша, без открытия Telegram. Блокировка инфры (control-plane, не
    # VPN-нода) сразу красная, даже если по флоту почти всё чисто - там
    # молчание значит панель/нода недоступна, а не просто урезанный канал.
    local verdict_emoji verdict_text
    if [[ "$measured" -eq 0 && "$infra_measured" -eq 0 ]]; then
        verdict_emoji="⚪"
        verdict_text="нет данных"
    elif [[ "$blocked_n" -eq 0 && "$infra_blocked_n" -eq 0 ]]; then
        verdict_emoji="🟢"
        verdict_text="всё чисто"
    elif [[ "$infra_blocked_n" -gt 0 ]] || { [[ "$measured" -gt 0 ]] && (( blocked_n * 2 >= measured )); }; then
        verdict_emoji="🔴"
        verdict_text="серьёзные блокировки"
    else
        verdict_emoji="🟡"
        verdict_text="есть блокировки"
    fi

    local report="${verdict_emoji} <b>Блокировка ТСПУ — ${verdict_text}</b>"$'\n\n'"<tg-emoji emoji-id=\"5296588050640420683\">🕘</tg-emoji> $(msk_date '+%Y-%m-%d %H:%M') МСК"$'\n'"<i>Выборка: ${sample_line}, промахи перепроверены</i>"$'\n'

    # Сводка поднята сразу под заголовок и в НЕразворачиваемой цитате -
    # главное видно без единого клика, детали (кто именно и где) остаются
    # ниже по тем же сворачиваемым блокам, что и раньше.
    local summary_block="📊 <b>Сводка</b>"$'\n'
    if [[ "$fleet_total" -gt 0 ]]; then
        # "Без учёта инфры" явно проговариваем: зонды инфра-серверов сюда не
        # входят (у инфры отдельный вердикт по 60%-порогу, а не по зондам).
        summary_block+="• Доступность по флоту: <b>$(( fleet_ok * 100 / fleet_total ))%</b> (${fleet_ok} из ${fleet_total} зондов)${infra_list:+ — без учёта инфры}"$'\n'
        summary_block+="• Серверов с блокировками: <b>${blocked_n} из ${measured}</b> ($(( blocked_n * 100 / measured ))%)"$'\n'
        if [[ "$city_n" -gt 0 ]]; then
            summary_block+="• Городов с блокировками: <b>${hit_cities} из ${city_n}</b> ($(( hit_cities * 100 / city_n ))%)"$'\n'
        fi
    else
        # Ни одного удавшегося замера: показывать 100% доступности здесь было
        # бы прямой ложью.
        summary_block+="• Доступность по флоту: <b>нет данных</b>"$'\n'
    fi
    [[ "$skip_n" -gt 0 ]] && summary_block+="• Не удалось померить: <b>${skip_n} из ${total}</b>"$'\n'
    [[ "$excluded_n" -gt 0 ]] && summary_block+="• Исключено из проверки: <b>${excluded_n}</b>"$'\n'
    if [[ -n "$infra_list" ]]; then
        if [[ "$infra_measured" -gt 0 ]]; then
            summary_block+="• Инфра: <b>${infra_ok_n} из ${infra_measured}</b> доступно"
            [[ "$infra_skip_n" -gt 0 ]] && summary_block+=" (${infra_skip_n} требует проверки)"
            summary_block+=$'\n'
        else
            summary_block+="• Инфра: <b>нет данных</b> (${infra_skip_n} требует проверки)"$'\n'
        fi
    fi
    summary_block="${summary_block%$'\n'}"

    report+=$'\n'"<blockquote>${summary_block}</blockquote>"$'\n'

    if [[ -n "$replace_list" ]]; then
        report+=$'\n'"<blockquote expandable>🔴 <b>Под замену (${replace_n}):</b>"$'\n'"${replace_list}</blockquote>"$'\n'
    fi

    if [[ -n "$ok_list" ]]; then
        report+="<blockquote expandable><tg-emoji emoji-id=\"5258053251873400722\">✅</tg-emoji> <b>Доступно (${ok_n}):</b>"$'\n'"${ok_list}</blockquote>"$'\n'
    fi

    # Инфра - отдельным блоком от основного флота: свой список, свой счётчик,
    # без процентов и городов (см. _skynet_tspu_summarize_server).
    if [[ -n "$infra_list" ]]; then
        local infra_total_n=$(( infra_ok_n + infra_blocked_n + infra_skip_n ))
        report+=$'\n'"<blockquote expandable>🧩 <b>Инфра (${infra_total_n}):</b>"$'\n'"${infra_list}</blockquote>"$'\n'
    fi

    # Отдельного списка заблокированных серверов нет: где именно режут -
    # видно в разделе по городам, а он же называет и оператора. Список
    # остаётся только в режиме common, где городов не бывает вовсе и иначе
    # заблокированные серверы просто не попали бы в отчёт.
    if [[ -n "$fail_list" && -z "$geo_list" ]]; then
        report+=$'\n'"<blockquote expandable><tg-emoji emoji-id=\"5258190433128834075\">👎</tg-emoji> <b>Заблокировано (${blocked_n}):</b>"$'\n'"${fail_list}</blockquote>"$'\n'
    fi

    if [[ -n "$skip_list" ]]; then
        report+=$'\n'"<blockquote expandable><tg-emoji emoji-id=\"5242222002420346059\">⬇️</tg-emoji> <b>Требуют проверки (${skip_n}):</b>"$'\n'"${skip_list}</blockquote>"$'\n'
    fi

    if [[ -n "$excluded_list" ]]; then
        report+=$'\n'"<blockquote expandable>🚫 <b>Исключены из проверки (${excluded_n}):</b>"$'\n'"${excluded_list}</blockquote>"$'\n'
    fi

    if [[ -n "$geo_list" ]]; then
        report+=$'\n'"<blockquote expandable><tg-emoji emoji-id=\"5240241223632954241\">🌍</tg-emoji> <b>Блокировки по городам (${hit_cities}):</b>"$'\n'"${geo_list}"
        [[ -n "$clean_list" ]] && report+=$'\n'"<i>Чисто: ${clean_list}</i>"$'\n'
        report+="</blockquote>"$'\n'
    fi

    if _skynet_censorcheck_tg_send "$report"; then
        [[ "$verbose" -eq 1 ]] && printf_ok "Отчёт отправлен в Telegram (${total} серверов, ${blocked_n} заблокировано, ${skip_n} пропущено, ${excluded_n} исключено)."
        log "CensorCheck: отчёт отправлен (${total} серверов, ${blocked_n} заблокировано, ${skip_n} пропущено, ${excluded_n} исключено)."
        return 0
    else
        [[ "$verbose" -eq 1 ]] && printf_error "Не удалось отправить отчёт в Telegram."
        log "CensorCheck: ОШИБКА отправки отчёта в Telegram."
        return 1
    fi
}

# ============================================================ #
#                       ПЛАНИРОВЩИК (CRON)                     #
# ============================================================ #

_skynet_censorcheck_cron_exec_path() {
    if [[ -x "${INSTALL_PATH:-}" ]]; then
        echo "$INSTALL_PATH"
    else
        echo "${SCRIPT_DIR}/reshala.sh"
    fi
}

# Понимает ли установленный cron переменную CRON_TZ (Vixie-cron в Debian/Ubuntu
# и cronie — да, busybox crond — нет). Ищем литерал прямо в бинарнике: man-страниц
# на голом сервере может не быть, а в cron с поддержкой строка есть всегда.
_skynet_censorcheck_cron_has_tz() {
    local bin
    for bin in /usr/sbin/cron /usr/sbin/crond /usr/bin/crond /sbin/cron; do
        [[ -x "$bin" ]] || continue
        grep -qa "CRON_TZ" "$bin" 2>/dev/null && return 0
    done
    return 1
}

# Переводит московское время в локальное время сервера — для cron без CRON_TZ.
# Считаем арифметикой по текущему смещению сервера (date +%z), а не через
# `date -d "TZ=..."`: последнее есть только в GNU date. Печатает "часы минуты".
# Если сам сервер живёт в зоне с переходом на лето, задание после перевода
# стрелок сдвинется на час — на UTC-серверах (типичный VPS) этого не бывает.
_skynet_censorcheck_msk_to_local() {
    local hour="$1" minute="$2"
    local z; z=$(date +%z)   # вида +0300 / -0500
    local offset=$(( 10#${z:1:2} * 60 + 10#${z:3:2} ))
    [[ "${z:0:1}" == "-" ]] && offset=$(( -offset ))

    local total=$(( 10#$hour * 60 + 10#$minute - RESHALA_TZ_OFFSET_MIN + offset ))
    total=$(( (total % 1440 + 1440) % 1440 ))
    echo "$(( total / 60 )) $(( total % 60 ))"
}

# Времена запусков (МСК, "HH:MM") — по одному на строку, по возрастанию.
# Источник правды — строки "# reshala-msk-time": по полям cron время
# пользователя уже не восстановить (мы могли перевести его в зону сервера).
# Формат тот же, что был у версии с одним запуском в день, — расписание,
# заданное до этой правки, читается как обычное расписание из одного пункта.
_skynet_censorcheck_times() {
    [[ -f "$_CENSORCHECK_CRON_FILE" ]] || return 0
    sed -n 's/^# reshala-msk-time //p' "$_CENSORCHECK_CRON_FILE" 2>/dev/null | sort -u
}

# Перезаписывает cron-файл под переданный список времён "HH:MM" (МСК).
# Пустой список = расписание выключено, файл удаляется.
_skynet_censorcheck_write_cron() {
    if [[ $# -eq 0 ]]; then
        rm -f "$_CENSORCHECK_CRON_FILE"
        return 0
    fi

    local exec_path; exec_path=$(_skynet_censorcheck_cron_exec_path)

    # Поля cron считаются в часовом поясе сервера. Либо просим считать по Москве
    # сам cron (CRON_TZ), либо, если он этого не умеет, переводим время сами.
    local has_tz=0
    _skynet_censorcheck_cron_has_tz && has_tz=1

    local tz_line
    if [[ "$has_tz" -eq 1 ]]; then
        tz_line="CRON_TZ=${RESHALA_TZ}"
    else
        tz_line="# Этот cron не понимает CRON_TZ, поэтому поля времени ниже записаны"$'\n'"# по часовому поясу сервера, а не по Москве (МСК — в комментариях)."
    fi

    local body="" t hour minute cron_hour cron_minute
    while IFS= read -r t; do
        [[ -n "$t" ]] || continue
        hour="${t%%:*}"; minute="${t##*:}"
        if [[ "$has_tz" -eq 1 ]]; then
            cron_hour="$hour"; cron_minute="$minute"
        else
            read -r cron_hour cron_minute <<< "$(_skynet_censorcheck_msk_to_local "$hour" "$minute")"
        fi
        # 10# — иначе "09" уедет в арифметику как восьмеричное и сломает запись.
        body+="# reshala-msk-time ${t}"$'\n'
        body+="$((10#$cron_minute)) $((10#$cron_hour)) * * * root ${exec_path} censorcheck-report >> ${LOGFILE} 2>&1"$'\n'
    done < <(printf '%s\n' "$@" | sort -u)
    body="${body%$'\n'}"   # завершающий перевод строки добавит сам heredoc

    cat > "$_CENSORCHECK_CRON_FILE" << EOF
# Reshala: отчёт "Блокировка ТСПУ" по флоту Skynet.
# Управляется через: reshala -> 🌐 Skynet -> [t] -> [e].
# Один пункт расписания = пара строк: "# reshala-msk-time HH:MM" (что задал
# пользователь, по Москве) и само задание cron.
${tz_line}
${body}
EOF
    chmod 644 "$_CENSORCHECK_CRON_FILE"
}

_skynet_censorcheck_add_time() {
    local -a times=(); mapfile -t times < <(_skynet_censorcheck_times)

    local hour minute new
    hour=$(ask_number_in_range "Час запуска по Москве (0-23)" 0 23 "9") || return
    minute=$(ask_number_in_range "Минута запуска (0-59)" 0 59 "0") || return
    new=$(printf '%02d:%02d' "$((10#$hour))" "$((10#$minute))")

    local t
    for t in ${times[@]+"${times[@]}"}; do
        if [[ "$t" == "$new" ]]; then
            printf_warning "Запуск в ${new} МСК уже есть в расписании."
            sleep 1
            return
        fi
    done

    if (( ${#times[@]} >= _CENSORCHECK_SOFT_LIMIT )); then
        echo ""
        printf_warning "Сейчас проверок в день: ${#times[@]}."
        printf_description "Каждый прогон — измерение RIPE Atlas на каждый сервер флота"
        printf_description "и ещё одно сообщение в Telegram. Норма — 3-4 раза в день."
        echo ""
        ask_yes_no "Всё равно добавить ${new} МСК?" "n" || return
    fi

    times+=("$new")
    _skynet_censorcheck_write_cron "${times[@]}"
    printf_ok "Добавлен запуск в ${new} МСК. Всего в расписании: ${#times[@]}."
    sleep 1
}

_skynet_censorcheck_remove_time() {
    local -a times=(); mapfile -t times < <(_skynet_censorcheck_times)

    if [[ ${#times[@]} -eq 0 ]]; then
        printf_info "Расписание и так пустое."
        sleep 1
        return
    fi

    local idx
    idx=$(ask_number_in_range "Номер запуска для удаления (1-${#times[@]}, 0 — отмена)" 0 "${#times[@]}" "0") || return
    [[ "$((10#$idx))" -eq 0 ]] && return

    local -a rest=()
    local i
    for i in "${!times[@]}"; do
        [[ "$i" -eq $((10#$idx - 1)) ]] && continue
        rest+=("${times[$i]}")
    done

    _skynet_censorcheck_write_cron ${rest[@]+"${rest[@]}"}
    if [[ ${#rest[@]} -eq 0 ]]; then
        printf_ok "Удалён последний пункт — автоматические проверки выключены."
    else
        printf_ok "Удалён запуск в ${times[$((10#$idx - 1))]} МСК. Осталось: ${#rest[@]}."
    fi
    sleep 1
}

_skynet_censorcheck_clear_cron() {
    if [[ -f "$_CENSORCHECK_CRON_FILE" ]]; then
        rm -f "$_CENSORCHECK_CRON_FILE"
        printf_ok "Расписание очищено, автоматические проверки выключены."
    else
        printf_info "Расписание и так было пустым."
    fi
    sleep 1
}

# ============================================================ #
#                          МЕНЮ                                #
# ============================================================ #

# Печатает список пунктов расписания в человекочитаемом виде для строки статуса:
# "09:00, 15:00, 21:00 МСК".
_skynet_censorcheck_times_inline() {
    local -a times=(); mapfile -t times < <(_skynet_censorcheck_times)
    [[ ${#times[@]} -eq 0 ]] && return
    local joined; joined=$(printf '%s, ' "${times[@]}")
    printf '%s МСК' "${joined%, }"
}

# Режим проверки и состав выборки: что проверяется, сколько это стоит за
# прогон и кнопка пересобрать набор зондов, не дожидаясь суточного
# протухания кэша.
_skynet_censorcheck_probe_set_menu() {
    while true; do
        clear
        menu_header "🛰 Режим проверки и выборка зондов"

        local mode="${TSPU_CHECK_MODE:-geo}"
        if [[ "$mode" == "common" ]]; then
            printf_description "Режим: ${C_GREEN}общая проверка${C_RESET}"
            printf_description "Зонды берутся в сетях крупных операторов, как в исходном"
            printf_description "censorcheck.tlab.pw. В отчёте — один процент на сервер и"
            printf_description "список операторов, без разбивки по городам. Дешевле."
        else
            printf_description "Режим: ${C_GREEN}проверка по географии${C_RESET}"
            printf_description "Зонды берутся по городам: ТСПУ ставят у оператора в"
            printf_description "конкретном регионе, и блокировка в Новосибирске ничего не"
            printf_description "говорит про Краснодар. В отчёте — раздел «География"
            printf_description "блокировок» с городами и операторами. Зондов больше."
        fi
        printf_description "Набор фиксируется на сутки — иначе проценты разных"
        printf_description "серверов несравнимы между собой."
        echo ""

        if [[ -z "${RIPE_API_KEY:-}" ]]; then
            printf_error "Сначала настрой RIPE Atlas ключ [k]."
            wait_for_enter
            return
        fi

        local out; out=$(_skynet_tspu_py probes "$RIPE_API_KEY" 2>/dev/null)
        if [[ "$out" != OK\ * ]]; then
            printf_error "Не удалось собрать выборку (${out:-нет ответа})."
            wait_for_enter
            return
        fi

        local _p probe_n city_n
        read -r _p probe_n city_n <<< "$(echo "$out" | head -1)"

        if [[ "$city_n" -gt 0 ]]; then
            printf_description "Зондов: ${C_GREEN}${probe_n}${C_RESET} в ${C_GREEN}${city_n}${C_RESET} городах"
            printf_description "  (по ${TSPU_CITY_PROBES:-5} на город, город берётся от ${TSPU_CITY_MIN_PROBES:-5} доступных зондов)"
            echo ""

            local cnt city
            while read -r _p cnt city; do
                [[ -n "$city" ]] || continue
                printf_description "  • ${city} — ${cnt}"
            done < <(echo "$out" | grep '^CITY ')
        else
            printf_description "Зондов: ${C_GREEN}${probe_n}${C_RESET} в сетях крупных операторов"
        fi
        echo ""

        # Прикидка по кредитам считается по чистому прогону, без блокировок:
        # перепроверка тратится только на промахнувшиеся зонды, и на спокойном
        # флоте её просто нет. При реальной блокировке добавится по два
        # маленьких замера на каждый промахнувшийся зонд.
        local fleet_n=0
        [[ -s "$FLEET_DATABASE_FILE" ]] && fleet_n=$(grep -c . "$FLEET_DATABASE_FILE")
        local excluded_n; excluded_n=$(_skynet_tspu_excluded_count)
        fleet_n=$(( fleet_n - excluded_n ))
        [[ "$fleet_n" -lt 0 ]] && fleet_n=0
        local per_msm=$(( probe_n * _CENSORCHECK_CREDITS_PER_PROBE ))
        local per_run=$(( per_msm * fleet_n ))
        local runs; runs=$(_skynet_censorcheck_times | grep -c .)

        printf_description "Цена прогона: ${C_YELLOW}${per_run}${C_RESET} кредитов RIPE Atlas"
        printf_description "  (${probe_n} зондов × 10 × ${fleet_n} серверов, без блокировок$([[ "$excluded_n" -gt 0 ]] && echo ", ${excluded_n} исключено"))"
        if [[ "$runs" -gt 0 ]]; then
            printf_description "В сутки при ${runs} прогонах: ${C_YELLOW}$(( per_run * runs ))${C_RESET} кредитов"
            printf_description "  (свой зонд RIPE Atlas приносит 21600 кредитов в сутки)"
        fi
        echo ""

        if [[ "$mode" == "common" ]]; then
            printf_menu_option "m" "Переключить на проверку по географии"
        else
            printf_menu_option "m" "Переключить на общую проверку"
        fi
        printf_menu_option "u" "Пересобрать набор зондов сейчас"
        printf_menu_option "b" "Назад"
        echo ""

        local choice; choice=$(safe_read "Выбор: " "") || { _LAST_CTRLC_SIGNALED=0; continue; }
        case "$choice" in
            [mM])
                # Набор зондов у режимов разный, поэтому кэш пересобирается
                # сразу же — иначе до конца суток проверка шла бы старым
                # набором, а отчёт обещал бы новый режим.
                local new_mode="common"
                [[ "$mode" == "common" ]] && new_mode="geo"
                set_config_var "TSPU_CHECK_MODE" "$new_mode"
                TSPU_CHECK_MODE="$new_mode"
                printf_info "Пересобираю набор под новый режим..."
                _skynet_tspu_py probes "$RIPE_API_KEY" --refresh >/dev/null 2>&1 \
                    && printf_ok "Готово." || printf_error "Не удалось пересобрать набор."
                sleep 1
                ;;
            [uU])
                printf_info "Пересобираю набор (опрос RIPE Atlas и имён операторов)..."
                if _skynet_tspu_py probes "$RIPE_API_KEY" --refresh >/dev/null 2>&1; then
                    printf_ok "Готово."
                else
                    printf_error "Не удалось пересобрать набор."
                fi
                sleep 1
                ;;
            [bB]) break ;;
            *) printf_error "Неверный выбор."; sleep 1 ;;
        esac
    done
}

# Какие серверы флота участвуют в проверке ТСПУ. Исключённые хранятся в
# TSPU_EXCLUDED_SERVERS (config/reshala.conf) как список имён через запятую -
# тот же приём, что ENABLED_WIDGETS в modules/ui/widget_manager.sh. Привязка
# идёт по имени сервера (уникальный ключ в базе флота).
_skynet_censorcheck_servers_menu() {
    while true; do
        clear
        menu_header "🖥 Серверы в проверке ТСПУ"
        printf_description "Исключённый сервер не бьётся зондами RIPE Atlas и не тратит"
        printf_description "кредиты. В отчёте о нём отдельная строка «исключён из проверки»."
        echo ""

        if [[ ! -s "$FLEET_DATABASE_FILE" ]]; then
            printf_warning "Флот пуст, выбирать нечего."
            wait_for_enter
            return
        fi

        local excluded; excluded=$(get_config_var "TSPU_EXCLUDED_SERVERS")

        local -a names=()
        local i=1 name user ip port key_path sudo_pass category
        while IFS='|' read -r name user ip port key_path sudo_pass category; do
            [[ -z "$name" ]] && continue
            name="${name%$'\r'}"
            names[$i]="$name"

            local status status_color
            if _skynet_tspu_csv_contains "$name" "$excluded"; then
                status="ИСКЛЮЧЁН"; status_color="${C_RED}"
            else
                status="ПРОВЕРЯЕТСЯ"; status_color="${C_GREEN}"
            fi

            local menu_text; menu_text=$(printf "%b%-12s%b - %s (%s) [%s]" "$status_color" "[$status]" "${C_RESET}" "$name" "$ip" "$(_skynet_category_label "$category")")
            printf_menu_option "$i" "$menu_text"
            ((i++))
        done < "$FLEET_DATABASE_FILE"

        echo ""
        printf_menu_option "b" "Назад"
        echo ""

        local choice; choice=$(safe_read "Номер сервера для переключения или буква: " "") || { _LAST_CTRLC_SIGNALED=0; continue; }
        case "$choice" in
            [bB]) break ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && [[ -n "${names[$choice]:-}" ]]; then
                    local selected="${names[$choice]}"
                    if _skynet_tspu_csv_contains "$selected" "$excluded"; then
                        excluded=$(_skynet_tspu_csv_remove "$selected" "$excluded")
                        printf_ok "Сервер '${selected}' снова участвует в проверке."
                    else
                        if [[ -z "$excluded" ]]; then
                            excluded="$selected"
                        else
                            excluded="$excluded,$selected"
                        fi
                        printf_ok "Сервер '${selected}' исключён из проверки."
                    fi
                    set_config_var "TSPU_EXCLUDED_SERVERS" "$excluded"
                    sleep 1
                else
                    printf_error "Неверный выбор."
                    sleep 1
                fi
                ;;
        esac
    done
}

_skynet_censorcheck_schedule_menu() {
    while true; do
        clear
        menu_header "🗓 Расписание проверок ТСПУ"
        printf_description "Каждый пункт расписания — отдельный прогон по всему флоту"
        printf_description "(один замер на сервер, промахи перепроверяются) с отдельным"
        printf_description "отчётом в Telegram. Норма — 3-4 прогона в день."
        echo ""

        local -a times=(); mapfile -t times < <(_skynet_censorcheck_times)
        if [[ ${#times[@]} -eq 0 ]]; then
            if [[ -f "$_CENSORCHECK_CRON_FILE" ]]; then
                # Файл есть, а разметки времени в нём нет: правили руками или он
                # остался от версии без метки. Что там за время — не угадать.
                printf_description "${C_YELLOW}Задание cron есть, но время в нём не размечено${C_RESET} —"
                printf_description "задай расписание заново через [a], старое будет перезаписано."
            else
                printf_description "${C_RED}Расписание пустое${C_RESET} — автоматические проверки выключены."
            fi
        else
            printf_description "Запусков в день: ${C_GREEN}${#times[@]}${C_RESET}"
            local i
            for i in "${!times[@]}"; do
                printf_description "  $((i + 1)). ${C_GREEN}${times[$i]}${C_RESET} МСК"
            done
        fi
        echo ""

        printf_menu_option "a" "Добавить время"
        printf_menu_option "x" "Удалить время"
        printf_menu_option "c" "Очистить расписание (выключить проверки)"
        echo ""
        printf_menu_option "b" "Назад"
        echo ""

        local choice; choice=$(safe_read "Выбор: " "") || { _LAST_CTRLC_SIGNALED=0; continue; }
        case "$choice" in
            [aA]) _skynet_censorcheck_add_time ;;
            [xX]) _skynet_censorcheck_remove_time ;;
            [cC]) _skynet_censorcheck_clear_cron ;;
            [bB]) break ;;
            *) printf_error "Неверный выбор."; sleep 1 ;;
        esac
    done
}

_skynet_censorcheck_menu() {
    enable_graceful_ctrlc
    while true; do
        clear
        menu_header "📡 Отчёт «Блокировка ТСПУ» в Telegram"
        printf_description "По расписанию бьёт зондами RIPE Atlas из городов России в IP"
        printf_description "каждого сервера флота и присылает сводный отчёт в Telegram —"
        printf_description "с разбором, в каких городах и чьи сети режут доступ."
        echo ""

        local tg_status="${C_RED}не настроен${C_RESET}"
        [[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]] && tg_status="${C_GREEN}настроен${C_RESET}"

        local ripe_status="${C_RED}не настроен${C_RESET}"
        [[ -n "${RIPE_API_KEY:-}" ]] && ripe_status="${C_GREEN}настроен${C_RESET}"

        local cron_status="${C_RED}пусто (проверки выключены)${C_RESET}"
        local cron_times; cron_times=$(_skynet_censorcheck_times_inline)
        local cron_count; cron_count=$(_skynet_censorcheck_times | grep -c .)
        if [[ -n "$cron_times" ]]; then
            cron_status="${C_GREEN}${cron_count} в день${C_RESET} (${cron_times})"
        elif [[ -f "$_CENSORCHECK_CRON_FILE" ]]; then
            # Задание, записанное до появления метки времени (или правленное
            # руками): что там за время — не угадать, чинится пересозданием.
            cron_status="${C_YELLOW}задание есть, время не размечено${C_RESET} — задай заново через [e]"
        fi

        local mode_status="${C_GREEN}по географии${C_RESET} (города и операторы)"
        [[ "${TSPU_CHECK_MODE:-geo}" == "common" ]] && mode_status="${C_GREEN}общая${C_RESET} (без разбивки по городам)"

        local servers_status="${C_GREEN}все${C_RESET}"
        local excluded_n_status; excluded_n_status=$(_skynet_tspu_excluded_count)
        [[ "$excluded_n_status" -gt 0 ]] && servers_status="${C_YELLOW}исключено ${excluded_n_status}${C_RESET}"

        printf_description "Telegram:          ${tg_status}"
        printf_description "RIPE Atlas ключ:   ${ripe_status}"
        printf_description "Режим проверки:    ${mode_status}"
        printf_description "Серверы в проверке: ${servers_status}"
        printf_description "Расписание:        ${cron_status}"
        echo ""

        printf_menu_option "n" "Настроить TG_BOT_TOKEN / TG_CHAT_ID"
        printf_menu_option "k" "Настроить RIPE Atlas API-ключ / SNI"
        printf_menu_option "g" "Режим проверки, выборка зондов и цена прогона"
        printf_menu_option "s" "Серверы в проверке (включить/исключить)"
        printf_menu_option "e" "Расписание проверок (добавить/убрать время)"
        printf_menu_option "r" "Запустить проверку и отчёт СЕЙЧАС"
        echo ""
        printf_menu_option "b" "Назад"
        echo ""

        local choice; choice=$(safe_read "Выбор: " "") || { _LAST_CTRLC_SIGNALED=0; continue; }
        case "$choice" in
            [nN]) _skynet_censorcheck_configure_telegram ;;
            [kK]) _skynet_censorcheck_configure_ripe ;;
            [gG]) _skynet_censorcheck_probe_set_menu ;;
            [sS]) _skynet_censorcheck_servers_menu ;;
            [eE]) _skynet_censorcheck_schedule_menu ;;
            [rR])
                if [[ -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then
                    printf_error "Сначала настрой Telegram [n]."
                    sleep 1
                elif [[ -z "${RIPE_API_KEY:-}" ]]; then
                    printf_error "Сначала настрой RIPE Atlas ключ [k]."
                    sleep 1
                else
                    echo ""
                    _skynet_censorcheck_run_and_report
                    wait_for_enter
                fi
                ;;
            [bB]) break ;;
            *) printf_error "Неверный выбор."; sleep 1 ;;
        esac
    done
    disable_graceful_ctrlc
}
