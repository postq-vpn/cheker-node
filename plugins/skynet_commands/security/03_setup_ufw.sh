#!/bin/bash
#
# TITLE: (System) Setup UFW Firewall
# SKYNET_HIDDEN: true
#
# Настраивает UFW для роли "Нода".
# Принимает PANEL_IP, ADMIN_IP, SSH_PORT через переменные окружения.

# --- Standard helpers for Skynet plugins ---
set -e # Exit immediately if a command exits with a non-zero status.
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m';
info() { echo -e "${C_RESET}[i] $*${C_RESET}"; }
ok()   { echo -e "${C_GREEN}[✓] $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}[!] $*${C_RESET}"; }
err()  { echo -e "${C_RED}[✗] $*${C_RESET}"; exit 1; }
# --- End of helpers ---

# --- Проверка переменных ---
if [[ -z "$TARGET_SSH_PORT" ]]; then
    TARGET_SSH_PORT=22
fi

info "Настраиваю файрвол UFW (Профиль: Универсальный)..."

# --- Установка UFW ---
if ! command -v ufw &>/dev/null; then
    info "UFW не найден. Устанавливаю..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null
    apt-get install -y -qq ufw >/dev/null
    ok "UFW установлен."
fi

# --- Настройка правил ---
info "Конфигурирую правила UFW..."

# Включаем поддержку IPv6 в конфиге UFW
if [[ -f "/etc/default/ufw" ]]; then
    sed -i 's/^IPV6=.*/IPV6=yes/' "/etc/default/ufw"
fi

# Сброс на случай, если уже что-то было
ufw --force reset >/dev/null

# Базовые правила
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null

# SSH и VPN - сразу после сброса и до всего остального: даже если дальше что-то
# пойдёт не так, включённый файрвол не должен закрыть доступ к серверу.
# Разрешаем SSH для всех (если не в GWL), иначе можно потерять доступ
# Если GWL был пуст, то это единственный способ зайти.
ufw allow "$TARGET_SSH_PORT"/tcp comment 'SSH Port' >/dev/null
ok "Порт SSH ($TARGET_SSH_PORT) открыт."

# Основной порт для VPN (стандарт Reshala)
ufw allow 443/tcp comment 'VPN/HTTPS' >/dev/null
ufw allow 443/udp comment 'VPN/UDP' >/dev/null
ok "Порты 443 TCP/UDP (VPN) открыты."

# --- СИНХРОНИЗАЦИЯ ГЛОБАЛЬНОГО БЕЛОГО СПИСКА ---
temp_gwl=$(mktemp)
if [[ -n "${GWL_B64:-}" ]]; then
    echo "$GWL_B64" | base64 -d > "$temp_gwl" 2>/dev/null || true
fi
if [[ -f "/etc/reshala/global-whitelist.txt" ]]; then
    cat "/etc/reshala/global-whitelist.txt" >> "$temp_gwl"
fi

if [[ -s "$temp_gwl" ]]; then
    info "Синхронизирую Глобальный Белый Список (Мастер + Локальный)..."
    # Читаем IP, игнорируя комментарии, сортируем и удаляем дубликаты
    ips=$(grep -v '^\s*#' "$temp_gwl" | grep -v '^\s*$' | awk '{print $1}' | sort -u)
    count=0
    for ip in $ips; do
        # Не ((count++)): при count=0 оно возвращает ошибку, и set -e обрывал
        # плагин после сброса правил, оставляя файрвол выключенным. Плохая
        # запись в списке тоже не повод бросать настройку на полпути.
        if ufw allow from "$ip" comment 'GWL Trusted' >/dev/null; then
            count=$((count + 1))
        else
            warn "Пропущена некорректная запись белого списка: $ip"
        fi
    done
    ok "Добавлено $count уникальных IP из Глобального Белого Списка."
else
    warn "Глобальный Белый Список пуст. Используются только стандартные правила."
fi
rm -f "$temp_gwl"

# --- Docker UFW Fix (Professional) ---
if command -v docker &>/dev/null; then
    info "Обнаружен Docker. Применяю Professional UFW Fix..."
    iface=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -1)
    iface=${iface:-eth0}
    after_rules="/etc/ufw/after.rules"
    marker_start="# --- НАЧАЛО: Reshala Docker UFW Fix ---"
    marker_end="# --- КОНЕЦ: Reshala Docker UFW Fix ---"
    
    # Чистим старое
    sed -i "/${marker_start}/,/${marker_end}/d" "$after_rules"
    
    # Вставляем блок
    python3 - "$after_rules" "$marker_start" "$marker_end" "$iface" <<'PYEOF'
import sys
rules_file, marker_s, marker_e, iface = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(rules_file, 'r') as f:
    content = f.read()
docker_block = f"""
{marker_s}
:DOCKER-USER - [0:0]
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -i {iface} -p udp -m udp --sport 53 --dport 1024:65535 -j RETURN
-A DOCKER-USER -i {iface} -j ufw-user-forward
-A DOCKER-USER -i {iface} -j DROP
-A DOCKER-USER -j RETURN
{marker_e}
"""
if 'COMMIT' in content:
    idx = content.rfind('COMMIT')
    content = content[:idx] + docker_block + content[idx:]
else:
    content += docker_block
with open(rules_file, 'w') as f:
    f.write(content)
PYEOF
    
    # Синхронизация портов в route
    info "Синхронизирую текущие правила UFW с Docker (route)..."
    for p in $TARGET_SSH_PORT 443; do
        ufw route allow "$p" >/dev/null 2>&1 || true
    done
fi

# Включаем UFW и проверяем, что он реально поднялся: правила уже сброшены, и
# молчаливая неудача оставила бы сервер без файрвола.
echo "y" | ufw enable >/dev/null || err "UFW не включился: сервер сейчас БЕЗ файрвола."
LC_ALL=C ufw status | grep -qw "active" || err "UFW не активен: сервер сейчас БЕЗ файрвола."
ok "UFW активирован и работает (IPv6: ON)."

ok "Настройка файрвола завершена."
exit 0
