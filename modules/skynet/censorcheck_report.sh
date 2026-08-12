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

_CENSORCHECK_CRON_FILE="/etc/cron.d/reshala-censorcheck"
_TSPU_PROBE_SCRIPT="${SCRIPT_DIR}/modules/skynet/tspu_probe.py"

# Сколько проверок в день считаем нормой. Дальше добавлять можно, но со
# спросом: каждый прогон создаёт _CENSORCHECK_ROUNDS измерений RIPE Atlas на
# КАЖДЫЙ сервер флота плюс _CENSORCHECK_ROUNDS контрольных (кредиты не
# бесконечные, см. _skynet_censorcheck_probe_set_menu) и присылает ещё одно
# сообщение в Telegram.
_CENSORCHECK_SOFT_LIMIT=4

# Сколько замеров подряд делать по каждому серверу за один прогон. Вердикт
# ставится по большинству (см. _skynet_tspu_summarize_server): чтобы уехать
# в "Заблокировано", сервер должен недобрать проценты минимум в двух замерах.
# Меньше трёх смысла не имеет - подтверждать промах будет нечем.
_CENSORCHECK_ROUNDS="${TSPU_PROBE_ROUNDS:-3}"

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
_skynet_censorcheck_html_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    printf '%s' "$s"
}

# Отправляет ОДИН кусок текста (<=4096 символов) в Telegram.
# Печатает HTTP-код ответа в stdout.
_skynet_censorcheck_tg_send_chunk() {
    local text="$1"
    local token="${TG_BOT_TOKEN:-}"
    local chat_id="${TG_CHAT_ID:-}"

    curl -s -m 20 -X POST "https://api.telegram.org/bot${token}/sendMessage" \
        --data-urlencode "chat_id=${chat_id}" \
        --data-urlencode "text=${text}" \
        --data-urlencode "parse_mode=HTML" \
        -o /dev/null -w '%{http_code}'
}

# Отправляет произвольно длинный текст, разбивая его на несколько
# сообщений по границам строк, если он не влезает в лимит Telegram.
# Возвращает 0, если ВСЕ куски доставлены успешно.
_skynet_censorcheck_tg_send() {
    local full_text="$1"
    local token="${TG_BOT_TOKEN:-}"
    local chat_id="${TG_CHAT_ID:-}"

    if [[ -z "$token" || -z "$chat_id" ]]; then
        return 1
    fi

    local max_len=3500
    local chunk="" all_ok=0 http_code

    while IFS= read -r line; do
        if (( ${#chunk} + ${#line} + 1 > max_len )) && [[ -n "$chunk" ]]; then
            http_code=$(_skynet_censorcheck_tg_send_chunk "$chunk")
            [[ "$http_code" != "200" ]] && all_ok=1
            chunk=""
        fi
        chunk+="${line}"$'\n'
    done <<< "$full_text"

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

    # Храним в /etc/reshala/.env (см. common.sh), а не в config/reshala.conf:
    # это секрет, и он должен пережить переустановку/обновление Решалы.
    set_env_var "TG_BOT_TOKEN" "$token"
    set_env_var "TG_CHAT_ID" "$chat_id"
    TG_BOT_TOKEN="$token"
    TG_CHAT_ID="$chat_id"

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
    TSPU_CITY_PROBES="${TSPU_CITY_PROBES:-3}" \
    TSPU_CITY_MIN_PROBES="${TSPU_CITY_MIN_PROBES:-5}" \
    TSPU_PROBE_STRICT_GEO="${TSPU_PROBE_STRICT_GEO:-0}" \
    python3 "$_TSPU_PROBE_SCRIPT" "$@"
}

# ОДИН замер по IP. Печатает МНОГОСТРОЧНЫЙ блок:
#   OK <percent> <success> <total> <fault>
#   ASN <asn> <сколько зондов не достучалось>       (0..N строк)
#   CITY <успешно> <всего> <asn,asn|-> <город>      (0..N строк)
# либо одну строку:
#   SKIP <причина>
#
# exclude - ID зондов через запятую, которые в этом раунде не прошли
# контрольный замер (см. _skynet_tspu_control_round).
_skynet_tspu_probe_once() {
    local ip="$1" sni="$2" api_key="$3" exclude="${4:-}"

    # Без реально слушающего 443 RIPE Atlas всё равно покажет "заблокировано"
    # для всех зондов - но это не ТСПУ, а просто отсутствие VPN на сервере.
    # Такие случаи не считаем ни OK, ни BLOCKED - помечаем на ручную проверку.
    if ! timeout 4 bash -c "echo > /dev/tcp/${ip}/443" 2>/dev/null; then
        echo "SKIP порт 443 не отвечает (нет VPN/Reality на сервере или сервер недоступен)"
        return
    fi

    local py_out
    py_out=$(_skynet_tspu_py check "$api_key" "$ip" "$sni" "$exclude" 2>/dev/null)

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

# Контрольный замер раунда: ТЕ ЖЕ зонды бьют в заведомо неблокируемую цель.
# Печатает ID зондов через запятую, которые сейчас не в форме.
#
# Зачем: зонды RIPE живут в домашних сетях и отваливаются сами по себе, а
# отвалившийся зонд внешне неотличим от зарезанного ТСПУ. Тот, кто не смог
# дотянуться даже до контрольной цели, в этом раунде не считается вообще -
# ни в числителе, ни в знаменателе. Замер ОДИН на раунд, а не на сервер,
# поэтому его цена не зависит от размера флота.
_skynet_tspu_control_round() {
    local api_key="$1"
    local ip="${TSPU_CONTROL_IP:-8.8.8.8}"
    local sni="${TSPU_CONTROL_SNI:-dns.google}"

    local out
    out=$(_skynet_tspu_py control "$api_key" "$ip" "$sni" 2>/dev/null)

    # Контроль не удался - работаем без отсева, как до его появления.
    if [[ -z "$out" || "$out" == ERROR* ]]; then
        log "CensorCheck: контрольный замер не удался (${out:-нет ответа}), раунд без отсева зондов."
        return
    fi

    echo "$out" | sed -n 's/^DOWN //p' | head -1
}

# Итог по одному серверу за все раунды прогона. Читает файлы
# <tmp_dir>/<idx>.r<N>, оставленные _skynet_tspu_probe_once. Печатает:
#   AVAILABLE|BLOCKED|SKIP <детали>                 - ровно одна первая строка
#   CITY <промахов> <процент> <asn,asn|-> <город>   - 0..N, только проблемные
#
# Почему не один замер: зонды RIPE Atlas живут в реальных домашних сетях и
# отваливаются сами по себе - разовый недобор процентов это чаще шум, чем
# ТСПУ. В "Заблокировано" уезжает только то, что повторилось минимум в двух
# замерах; одиночный промах остаётся в "Доступно" с пометкой.
_skynet_tspu_summarize_server() {
    local tmp_dir="$1" idx="$2"
    local rounds="$_CENSORCHECK_ROUNDS"

    local -a percents=()
    local -A asn_rounds=()      # ASN -> в скольких замерах он резал трафик
    local -A city_ok=() city_tot=() city_miss=() city_asns=()
    local measured=0 misses=0 last_skip=""
    local r file head_line ln

    for ((r = 1; r <= rounds; r++)); do
        file="${tmp_dir}/${idx}.r${r}"
        [[ -s "$file" ]] || continue

        head_line=$(head -1 "$file")
        if [[ "${head_line%% *}" != "OK" ]]; then
            last_skip="${head_line#SKIP }"
            continue
        fi

        local _tag percent success total fault
        read -r _tag percent success total fault <<< "$head_line"
        measured=$((measured + 1))
        percents+=("$percent")
        [[ "$percent" -lt 100 ]] && misses=$((misses + 1))

        while IFS= read -r ln; do
            case "$ln" in
                "ASN "*)
                    local _a asn cnt
                    read -r _a asn cnt <<< "$ln"
                    asn_rounds[$asn]=$(( ${asn_rounds[$asn]:-0} + 1 ))
                    ;;
                "CITY "*)
                    local _c c_ok c_tot c_asns c_name
                    read -r _c c_ok c_tot c_asns c_name <<< "$ln"
                    [[ -n "$c_name" ]] || continue
                    city_ok["$c_name"]=$(( ${city_ok["$c_name"]:-0} + c_ok ))
                    city_tot["$c_name"]=$(( ${city_tot["$c_name"]:-0} + c_tot ))
                    if [[ "$c_ok" -lt "$c_tot" ]]; then
                        city_miss["$c_name"]=$(( ${city_miss["$c_name"]:-0} + 1 ))
                        [[ "$c_asns" != "-" ]] && city_asns["$c_name"]+="${c_asns},"
                    fi
                    ;;
            esac
        done < "$file"
    done

    if [[ "$measured" -eq 0 ]]; then
        echo "SKIP ${last_skip:-ни один из ${rounds} замеров не удался}"
        return
    fi

    local sum=0 p
    for p in "${percents[@]}"; do sum=$((sum + p)); done
    local avg=$(( sum / measured ))

    local seq; seq=$(printf '%s%%/' "${percents[@]}"); seq="${seq%/}"
    local partial=""
    [[ "$measured" -lt "$rounds" ]] && partial=" · удалось ${measured} из ${rounds} замеров"

    local verdict=""
    if [[ "$misses" -eq 0 ]]; then
        verdict="AVAILABLE${partial:+ ${partial# · }}"
    elif [[ "$misses" -lt 2 && "$measured" -lt 2 ]]; then
        # Одиночный промах при единственном удавшемся замере подтвердить нечем -
        # это не "доступно" и не "заблокировано", а повод посмотреть руками.
        verdict="SKIP единственный удавшийся замер показал ${avg}% доступности, остальные не удались (${last_skip})"
    elif [[ "$misses" -lt 2 ]]; then
        verdict="AVAILABLE промах в 1 замере из ${measured} (${seq}) — считаем случайным${partial}"
    else
        # В список блокирующих операторов пускаем только тех, кто повторился:
        # ASN, мелькнувший в одном замере из трёх, - такой же шум, как и сам промах.
        local blockers="" cnt name sorted asn
        sorted=$(
            for asn in "${!asn_rounds[@]}"; do
                [[ "${asn_rounds[$asn]}" -ge 2 ]] || continue
                printf '%s\t%s\n' "${asn_rounds[$asn]}" "${_TSPU_ASN_NAMES[$asn]:-AS$asn}"
            done | sort -k1,1nr -k2,2
        )
        while IFS=$'\t' read -r cnt name; do
            [[ -n "$name" ]] || continue
            blockers+="${name}(${cnt}/${measured}), "
        done <<< "$sorted"
        blockers="${blockers%, }"

        verdict="BLOCKED доступно в среднем ${avg}% (замеры: ${seq})${blockers:+, блокируют: ${blockers}}${partial}"
    fi

    echo "$verdict"

    # Город идёт в отчёт по тому же правилу, что и сам сервер: промах должен
    # повториться минимум в двух замерах. При квоте 3 зонда на город один
    # выпавший зонд это сразу 33 п.п. - без этого правила отчёт будет пестреть
    # случайными городами.
    local c pct uniq
    for c in "${!city_miss[@]}"; do
        [[ "${city_miss[$c]}" -ge 2 ]] || continue
        pct=0
        [[ "${city_tot[$c]:-0}" -gt 0 ]] && pct=$(( ${city_ok[$c]} * 100 / ${city_tot[$c]} ))
        uniq=$(printf '%s' "${city_asns[$c]%,}" | tr ',' '\n' | sort -un | tr '\n' ',')
        uniq="${uniq%,}"
        echo "CITY ${city_miss[$c]} ${pct} ${uniq:--} ${c}"
    done | sort -t' ' -k3,3n
}

# Прогоняет весь флот (без SSH, напрямую по IP из базы флота). Результаты -
# в файлах внутри временной директории, путь к которой печатает в stdout:
#   <tmp_dir>/N.name   - "Имя (IP)"
#   <tmp_dir>/N.r<R>   - сырой выхлоп замера сервера N в раунде R
#   <tmp_dir>/N.result - вердикт + строки CITY (см. _skynet_tspu_summarize_server)
#   <tmp_dir>/.count   - количество серверов N
#
# Раунды идут ПОСЛЕДОВАТЕЛЬНО, серверы внутри раунда - ПАРАЛЛЕЛЬНО. Порядок
# именно такой из-за контрольного замера: он общий на раунд, и его результат
# нужен всем серверам этого раунда до начала их замеров.
_skynet_tspu_check_fleet_parallel() {
    local sni="$1" api_key="$2"
    local tmp_dir; tmp_dir=$(mktemp -d)

    local -a lines=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && lines+=("$line")
    done < "$FLEET_DATABASE_FILE"

    local -a ips=()
    local i=0 name user ip port key_path sudo_pass
    for line in "${lines[@]}"; do
        IFS='|' read -r name user ip port key_path sudo_pass <<< "$line"
        [[ -z "$name" ]] && continue
        i=$((i + 1))
        echo "${name} (${ip})" > "${tmp_dir}/${i}.name"
        ips+=("$ip")
    done
    echo "$i" > "${tmp_dir}/.count"

    local r idx dead
    for ((r = 1; r <= _CENSORCHECK_ROUNDS; r++)); do
        dead=$(_skynet_tspu_control_round "$api_key")
        [[ -n "$dead" ]] && printf '%s' "$dead" > "${tmp_dir}/.dead.${r}"

        local -a pids=()
        for ((idx = 1; idx <= i; idx++)); do
            ( _skynet_tspu_probe_once "${ips[$((idx - 1))]}" "$sni" "$api_key" "$dead" \
                > "${tmp_dir}/${idx}.r${r}" ) &
            pids+=("$!")
        done
        [[ ${#pids[@]} -gt 0 ]] && wait "${pids[@]}" 2>/dev/null
    done

    for ((idx = 1; idx <= i; idx++)); do
        _skynet_tspu_summarize_server "$tmp_dir" "$idx" > "${tmp_dir}/${idx}.result"
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

    if [[ "$verbose" -eq 1 ]]; then
        printf_info "Проверяю доступность всех серверов флота из сетей РФ (RIPE Atlas, параллельно)."
        printf_info "Выборка: ${probe_n} зондов в ${city_n} городах, ${_CENSORCHECK_ROUNDS} замера на сервер."
        printf_info "Каждый раунд начинается с контрольного замера — это займёт несколько минут."
    fi

    local tmp_dir; tmp_dir=$(_skynet_tspu_check_fleet_parallel "$sni" "$RIPE_API_KEY")
    local count; count=$(cat "${tmp_dir}/.count" 2>/dev/null || echo 0)

    # Все три группы - одинаковый вид: сворачиваемая (expandable) цитата
    # с заголовком-счётчиком, внутри - КАЖДЫЙ сервер отдельной строкой.
    local ok_list="" fail_list="" skip_list=""
    local total=0 ok_n=0 blocked_n=0 skip_n=0 idx name result kind detail esc_name

    # Город -> кто в нём недоступен и чьи это сети. Ключ с пробелом внутри
    # ("Нижний Новгород") ассоциативному массиву не мешает.
    local -A city_servers=() city_asns=()

    for ((idx = 1; idx <= count; idx++)); do
        name=$(cat "${tmp_dir}/${idx}.name" 2>/dev/null)
        result=$(head -1 "${tmp_dir}/${idx}.result" 2>/dev/null)
        total=$((total + 1))
        esc_name=$(_skynet_censorcheck_html_escape "$name")

        kind="${result%% *}"
        detail="${result#* }"
        [[ "$detail" == "$result" ]] && detail=""
        detail=$(_skynet_censorcheck_html_escape "$detail")

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

        # В географию идут только те серверы, у которых есть что показать.
        # Имя сервера без IP: в списке городов важно КТО, а адрес уже назван
        # выше в своей секции.
        local short_name; short_name=$(_skynet_censorcheck_html_escape "${name%% (*}")
        local _c miss pct asns city
        while read -r _c miss pct asns city; do
            [[ -n "$city" ]] || continue
            city_servers["$city"]+="${short_name} (${pct}%), "
            [[ "$asns" != "-" ]] && city_asns["$city"]+="${asns},"
        done < <(grep '^CITY ' "${tmp_dir}/${idx}.result" 2>/dev/null)
    done
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

        geo_list+="• <b>${esc_city}</b> — ${city_servers[$city]%, }${ops:+ · ${ops}}"$'\n'
    done
    clean_list="${clean_list%, }"

    local report="<tg-emoji emoji-id=\"5474410313853998290\">💡</tg-emoji> <b>Блокировка ТСПУ — отчёт по флоту</b>"$'\n\n'"<tg-emoji emoji-id=\"5296588050640420683\">🕘</tg-emoji> $(msk_date '+%Y-%m-%d %H:%M') МСК"$'\n'"<i>Замеров на сервер: ${_CENSORCHECK_ROUNDS}, вердикт по большинству</i>"$'\n'"<i>Выборка: ${probe_n} зондов в ${city_n} городах</i>"$'\n'

    if [[ -n "$ok_list" ]]; then
        report+="<blockquote expandable><tg-emoji emoji-id=\"5258053251873400722\">✅</tg-emoji> <b>Доступно (${ok_n}):</b>"$'\n'"${ok_list}</blockquote>"$'\n'
    fi

    if [[ -n "$fail_list" ]]; then
        report+=$'\n'"<blockquote expandable><tg-emoji emoji-id=\"5258190433128834075\">👎</tg-emoji> <b>Заблокировано (${blocked_n}):</b>"$'\n'"${fail_list}</blockquote>"$'\n'
    fi

    if [[ -n "$skip_list" ]]; then
        report+=$'\n'"<blockquote expandable><tg-emoji emoji-id=\"5242222002420346059\">⬇️</tg-emoji> <b>Требуют проверки (${skip_n}):</b>"$'\n'"${skip_list}</blockquote>"$'\n'
    fi

    # География идёт последней и только когда есть о чём говорить: в спокойный
    # день это лишний экран текста про то, что всё хорошо.
    if [[ -n "$geo_list" ]]; then
        report+=$'\n'"<blockquote expandable><tg-emoji emoji-id=\"5240241223632954241\">🌍</tg-emoji> <b>География блокировок:</b>"$'\n'"${geo_list}"
        [[ -n "$clean_list" ]] && report+=$'\n'"<i>Чисто: ${clean_list}</i>"$'\n'
        report+="</blockquote>"$'\n'
    fi

    report+=$'\n'"Итого: ${total} серверов · ${blocked_n} заблокировано · ${skip_n} пропущено"

    if _skynet_censorcheck_tg_send "$report"; then
        [[ "$verbose" -eq 1 ]] && printf_ok "Отчёт отправлен в Telegram (${total} серверов, ${blocked_n} заблокировано, ${skip_n} пропущено)."
        log "CensorCheck: отчёт отправлен (${total} серверов, ${blocked_n} заблокировано, ${skip_n} пропущено)."
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
        printf_description "Каждый прогон — ${_CENSORCHECK_ROUNDS} измерения RIPE Atlas на каждый сервер"
        printf_description "флота и ещё одно сообщение в Telegram. Норма — 3-4 раза в день."
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

# Состав выборки: какие города проверяются, сколько это стоит за прогон и
# кнопка пересобрать набор зондов, не дожидаясь суточного протухания кэша.
_skynet_censorcheck_probe_set_menu() {
    while true; do
        clear
        menu_header "🛰 Выборка зондов по городам"
        printf_description "Зонды набираются по городам: ТСПУ ставят у оператора в"
        printf_description "конкретном регионе, и блокировка в Новосибирске ничего не"
        printf_description "говорит про Краснодар. Набор фиксируется на сутки — иначе"
        printf_description "проценты разных серверов и раундов несравнимы между собой."
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

        printf_description "Зондов: ${C_GREEN}${probe_n}${C_RESET} в ${C_GREEN}${city_n}${C_RESET} городах"
        printf_description "  (по ${TSPU_CITY_PROBES:-3} на город, город берётся от ${TSPU_CITY_MIN_PROBES:-5} доступных зондов)"
        echo ""

        local cnt city
        while read -r _p cnt city; do
            [[ -n "$city" ]] || continue
            printf_description "  • ${city} — ${cnt}"
        done < <(echo "$out" | grep '^CITY ')
        echo ""

        # Прикидка по кредитам: замеры по флоту плюс контрольный замер, один
        # на раунд независимо от размера флота.
        local fleet_n=0
        [[ -s "$FLEET_DATABASE_FILE" ]] && fleet_n=$(grep -c . "$FLEET_DATABASE_FILE")
        local per_msm=$(( probe_n * _CENSORCHECK_CREDITS_PER_PROBE ))
        local per_run=$(( per_msm * _CENSORCHECK_ROUNDS * (fleet_n + 1) ))
        local runs; runs=$(_skynet_censorcheck_times | grep -c .)

        printf_description "Цена прогона: ${C_YELLOW}${per_run}${C_RESET} кредитов RIPE Atlas"
        printf_description "  (${probe_n} зондов × 10 × ${_CENSORCHECK_ROUNDS} замера × ${fleet_n} серверов + контроль)"
        if [[ "$runs" -gt 0 ]]; then
            printf_description "В сутки при ${runs} прогонах: ${C_YELLOW}$(( per_run * runs ))${C_RESET} кредитов"
            printf_description "  (свой зонд RIPE Atlas приносит 21600 кредитов в сутки)"
        fi
        echo ""

        printf_menu_option "u" "Пересобрать набор зондов сейчас"
        printf_menu_option "b" "Назад"
        echo ""

        local choice; choice=$(safe_read "Выбор: " "") || { _LAST_CTRLC_SIGNALED=0; continue; }
        case "$choice" in
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

_skynet_censorcheck_schedule_menu() {
    while true; do
        clear
        menu_header "🗓 Расписание проверок ТСПУ"
        printf_description "Каждый пункт расписания — отдельный прогон по всему флоту"
        printf_description "(${_CENSORCHECK_ROUNDS} замера на сервер, вердикт по большинству) с отдельным"
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

        printf_description "Telegram:          ${tg_status}"
        printf_description "RIPE Atlas ключ:   ${ripe_status}"
        printf_description "Расписание:        ${cron_status}"
        echo ""

        printf_menu_option "n" "Настроить TG_BOT_TOKEN / TG_CHAT_ID"
        printf_menu_option "k" "Настроить RIPE Atlas API-ключ / SNI"
        printf_menu_option "g" "Выборка зондов по городам и цена прогона"
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
