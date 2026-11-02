#!/bin/bash
# TITLE: Блокировка ТСПУ
# SKYNET_HIDDEN: false
# SKYNET_COLOR: red
# Плагин для Скайнета: скачивает и запускает CensorCheck на удалённом сервере.
#

run() {
    if ! command -v wget >/dev/null 2>&1; then
        echo "Утилита wget не найдена на сервере."
        return 1
    fi
    # Страница ошибки вместо скрипта запускаться не должна.
    local script
    if ! script=$(wget -qO- censorcheck.tlab.pw) || [[ -z "$script" || "$script" == "<"* ]]; then
        echo "Не удалось скачать скрипт CensorCheck."
        return 1
    fi
    bash <<< "$script"
}

run
