#!/usr/bin/env python3
# ============================================================ #
# ==     ТСПУ: СОХРАНЕНИЕ РЕЗУЛЬТАТОВ ПРОВЕРКИ В JSON         == #
# ============================================================ #
#
# Отчёт "Блокировка ТСПУ" уходит в Telegram, а временная директория с
# сырыми ответами зондов удаляется сразу после него. Для `reshala api`
# (графический интерфейс в панели) результат нужен потом: этот скрипт
# складывает его в JSON до удаления директории.
#
# Источник - те же файлы, из которых собирается отчёт
# (_skynet_tspu_check_fleet_parallel / _skynet_tspu_summarize_server):
#   <tmp>/N.name      "Имя (IP)"
#   <tmp>/N.category  fleet | infra
#   <tmp>/N.out       сырой ответ tspu_probe.py (OK/NOPORT/ERROR + CITY/MOBILE)
#   <tmp>/N.result    вердикт: AVAILABLE|BLOCKED|SKIP <детали>, STAT, CITY, MOBILE
#   <tmp>/.count      сколько серверов проверено
#   <tmp>/.excluded   исключённые из проверки, по имени в строке
#
# Режимы:
#   tspu_store.py run   <tmp_dir> <store_dir> <probes_file> <asn_file> <started> <source>
#   tspu_store.py check <tmp_dir> <out_file>  <probes_file> <asn_file> <started> <target> <ip> <sni>
#
# probes_file - вывод `tspu_probe.py probes` (OK <зондов> <городов>, CITY, MOBILE),
# asn_file    - "asn<TAB>имя" (свои переводы Решалы + имена держателей из RIPEstat).
#
# Хранилище прогонов: <store_dir>/runs/<id>.json и <store_dir>/last.json,
# в истории не больше KEEP_RUNS последних прогонов.

import json
import os
import re
import sys
import tempfile
from datetime import datetime, timedelta, timezone

KEEP_RUNS = 120


def _read(path, default=""):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return default


def _int(value, default=0):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _write_json(path, data):
    """Через временный файл: читатель (api) никогда не видит половину JSON."""
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".tmp-", suffix=".json")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=1)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def load_asn_names(path):
    names = {}
    for line in _read(path).splitlines():
        num, _, name = line.partition("\t")
        if num.strip().isdigit() and name.strip():
            names[num.strip()] = name.strip()
    return names


def parse_probes(path):
    """Состав выборки: сколько зондов, какие города, сколько мобильных."""
    text = _read(path)
    lines = text.splitlines()
    probes = {"probes": 0, "cities": [], "mobile": 0}
    if lines and lines[0].startswith("OK "):
        parts = lines[0].split()
        probes["probes"] = _int(parts[1] if len(parts) > 1 else 0)
    for line in lines[1:]:
        if line.startswith("CITY "):
            # CITY <зондов> <город с пробелами>
            parts = line.split(" ", 2)
            if len(parts) == 3:
                probes["cities"].append({"name": parts[2], "probes": _int(parts[1])})
        elif line.startswith("MOBILE "):
            probes["mobile"] += 1
    return probes


def _asn_list(field):
    if not field or field == "-":
        return []
    out = []
    for item in field.split(","):
        item = item.strip()
        if item.isdigit() and item not in out:
            out.append(item)
    return out


def parse_metrics(lines):
    metrics = {
        "server": "UNKNOWN", "tcpPercent": None, "tcpOk": None, "tcpAttempts": None,
        "atlasTlsPercent": None, "atlasTlsOk": None, "atlasTlsTotal": None,
        "ruVpsTls": "NOT_MEASURED", "tspu": "UNKNOWN", "vpn": "NOT_MEASURED",
    }
    for line in lines:
        parts = line.split()
        if len(parts) == 3 and parts[0] in ("TCP", "ATLAS_TLS"):
            ok, total = (_int(v) for v in parts[1:])
            if total > 0 and 0 <= ok <= total:
                tcp = parts[0] == "TCP"
                metrics["tcpOk" if tcp else "atlasTlsOk"] = ok
                metrics["tcpAttempts" if tcp else "atlasTlsTotal"] = total
                metrics["tcpPercent" if tcp else "atlasTlsPercent"] = ok * 100 // total
                if ok:
                    metrics["server"] = "AVAILABLE"
        elif line == "ATLAS_REACHED" or line == "RU_TLS AVAILABLE":
            metrics["server"] = "AVAILABLE"
        if len(parts) == 2 and parts[0] == "RU_TLS":
            metrics["ruVpsTls"] = parts[1]
        if len(parts) >= 4 and parts[0] == "OK":
            ok, total = _int(parts[2]), _int(parts[3])
            if total:
                metrics["tspu"] = "NO_SIGNS" if ok == total else "SUSPECTED FILTERING"
    return metrics


def vpn_observation(snapshot, hosts):
    try:
        data = json.loads(snapshot)
        if not isinstance(data, dict) or not isinstance(data.get("servers"), list):
            return {"vpn": "SOURCE_ERROR"}
        checked = datetime.fromisoformat(data["checkedAt"].replace("Z", "+00:00"))
        age = (datetime.now(timezone.utc) - checked).total_seconds()
    except (AttributeError, KeyError, TypeError, ValueError):
        return {"vpn": "SOURCE_ERROR"}

    names = {host.lower().rstrip(".") for host in hosts}
    matches = []
    for row in data["servers"]:
        if not isinstance(row, dict):
            return {"vpn": "SOURCE_ERROR"}
        sub = row.get("subdomain")
        if isinstance(sub, str) and re.fullmatch(r"[a-z0-9-]+", sub):
            if f"{sub}.postq.space" in names:
                matches.append(row)
    if not matches:
        return {"vpn": "NO_PROFILE"}
    if len(matches) != 1 or type(matches[0].get("alive")) is not bool:
        return {"vpn": "UNKNOWN"}
    status = "AVAILABLE" if matches[0]["alive"] else "FAILED"
    return {"vpn": status if 0 <= age <= 900 else "STALE",
            "vpnCheckedAt": checked.isoformat(), "vpnProfile": matches[0]["subdomain"]}


def server_metrics(raw_path, lines):
    metrics = parse_metrics(lines)
    snapshot_path = os.path.join(os.path.dirname(raw_path), ".vpn-status")
    if os.path.exists(snapshot_path):
        label = _read(os.path.splitext(raw_path)[0] + ".name").strip()
        name, _, address = label.rpartition(" (")
        metrics.update(vpn_observation(_read(snapshot_path), [name, address.rstrip(")")]))
    return metrics


def format_metrics(server, fleet=False):
    metrics = server["metrics"]
    labels = {"available": "признаков фильтрации нет", "blocked": "возможна фильтрация"}
    if server["category"] == "infra":
        labels = {"available": "доля ответов в пределах порога", "blocked": "доля ответов ниже порога"}
    verdict = labels.get(server["atlasStatus"], "нет результата")
    lines = [f"RIPE Atlas — {verdict}"]
    if server["probesTotal"]:
        lines.append(f"Ответ TLS с учётом перепроверок — {server['probesOk']}/{server['probesTotal']} ({server['percent']}%)")
    ok, total = metrics["atlasTlsOk"], metrics["atlasTlsTotal"]
    if total is None:
        lines.append("RIPE Atlas · TLS — нет данных")
    elif ok == 0:
        lines.append(f"⚠️ RIPE Atlas · TLS не подтверждён (0/{total} зондов получили сертификат)")
    else:
        lines.append(f"RIPE Atlas · сертификат получили {ok}/{total} зондов ({metrics['atlasTlsPercent']}%)")
    vpn = metrics["vpn"]
    if vpn != "NOT_MEASURED":
        labels = {"AVAILABLE": "профиль прошёл проверку", "FAILED": "проверка профиля не прошла",
                  "SOURCE_ERROR": "нет данных", "STALE": "замер устарел",
                  "NO_PROFILE": "нет профиля", "UNKNOWN": "нет однозначного результата"}
        checker = f"Xray Checker (РФ) — {labels[vpn]}"
        if metrics.get("vpnCheckedAt"):
            checked = datetime.fromisoformat(metrics["vpnCheckedAt"])
            checker += checked.astimezone(timezone(timedelta(hours=3))).strftime(" · %d.%m %H:%M МСК")
        lines.append(checker)
    elif not fleet:
        lines.append("VPN — требуется отдельный замер")
    vps = metrics["ruVpsTls"]
    if not fleet or vps != "NOT_MEASURED":
        result = {"AVAILABLE": "рукопожатие прошло", "UNAVAILABLE": "соединение не установлено"}.get(vps, "нет замера")
        lines.append(f"TLS с российского VPS — {result}")
    return "\n".join(lines)


def parse_server(tmp_dir, idx):
    """Один сервер из файлов прогона."""
    label = _read(os.path.join(tmp_dir, f"{idx}.name")).strip()
    name, ip = label, ""
    if label.endswith(")") and " (" in label:
        name, _, rest = label.rpartition(" (")
        ip = rest[:-1]
    category = _read(os.path.join(tmp_dir, f"{idx}.category"), "fleet").strip() or "fleet"

    result_lines = _read(os.path.join(tmp_dir, f"{idx}.result")).splitlines()
    raw_lines = _read(os.path.join(tmp_dir, f"{idx}.out")).splitlines()
    head = result_lines[0] if result_lines else "SKIP замер не выполнялся"
    kind, _, detail = head.partition(" ")
    status = {"AVAILABLE": "available", "BLOCKED": "blocked"}.get(kind, "skipped")

    metrics = server_metrics(os.path.join(tmp_dir, f"{idx}.out"), raw_lines)
    server = {
        "name": name,
        "ip": ip,
        "category": category,
        "sni": _read(os.path.join(tmp_dir, f"{idx}.sni")).strip() or None,
        "status": metrics["server"].lower(),
        "atlasStatus": status,
        "metrics": metrics,
        "detail": detail.strip(),
        "percent": None,
        "probesOk": None,
        "probesTotal": None,
        "probesFault": None,
        "probesDead": None,
        "cities": [],
        "mobile": None,
        "error": None,
        "failedProbes": [],
    }

    raw_head = raw_lines[0] if raw_lines else ""
    if raw_head.startswith("OK "):
        parts = raw_head.split()
        server["percent"] = _int(parts[1] if len(parts) > 1 else None, None)
        server["probesOk"] = _int(parts[2] if len(parts) > 2 else None, None)
        server["probesTotal"] = _int(parts[3] if len(parts) > 3 else None, None)
        server["probesFault"] = _int(parts[4] if len(parts) > 4 else None, None)
        server["probesDead"] = _int(parts[5] if len(parts) > 5 else None, None)
    elif raw_head == "NOPORT":
        server["error"] = "NOPORT"
    elif raw_head.startswith("ERROR"):
        server["error"] = raw_head[len("ERROR "):].split(":", 1)[0] or "ERROR"

    for line in result_lines[1:]:
        if line.startswith("CITY "):
            # CITY <промахов> <процент> <asn,asn|-> <город>
            parts = line.split(" ", 4)
            if len(parts) == 5:
                server["cities"].append({
                    "city": parts[4],
                    "missed": _int(parts[1]),
                    "percent": _int(parts[2]),
                    "asns": _asn_list(parts[3]),
                })
        elif line.startswith("MOBILE "):
            parts = line.split()
            if len(parts) >= 3:
                server["mobile"] = {
                    "missed": _int(parts[1]),
                    "percent": _int(parts[2]),
                    "asns": _asn_list(parts[3] if len(parts) > 3 else "-"),
                }

    # Подтверждённые промахи: что зонд ответил в замере и на повторе.
    for line in raw_lines:
        if not line.startswith("PROBE\t"):
            continue
        cols = line.split("\t")
        cols += [""] * (6 - len(cols))
        server["failedProbes"].append({
            "id": _int(cols[1]),
            "asn": cols[2] if cols[2] not in ("", "0") else None,
            "place": None if cols[3] in ("", "-") else cols[3],
            "first": cols[4],
            "retry": cols[5],
        })
    return server


def _summary(servers, excluded):
    fleet = [s for s in servers if s["category"] != "infra"]
    infra = [s for s in servers if s["category"] == "infra"]

    def count(group, status):
        return sum(1 for s in group if s["atlasStatus"] == status)

    probes_ok = sum(s["probesOk"] or 0 for s in fleet if s["probesTotal"])
    probes_total = sum(s["probesTotal"] or 0 for s in fleet if s["probesTotal"])
    return {
        "fleet": {
            "total": len(fleet),
            "serverAvailable": sum(s["status"] == "available" for s in fleet),
            "suspectedFiltering": sum(s["metrics"]["tspu"] == "SUSPECTED FILTERING" for s in fleet),
            "available": count(fleet, "available"),
            "blocked": count(fleet, "blocked"),
            "skipped": count(fleet, "skipped"),
            # Доля дошедших зондов по всему флоту, а не среднее процентов
            # серверов - у тех разные знаменатели (как в отчёте).
            "percent": (probes_ok * 100 // probes_total) if probes_total else None,
        },
        "infra": {
            "total": len(infra),
            "serverAvailable": sum(s["status"] == "available" for s in infra),
            "suspectedFiltering": sum(s["metrics"]["tspu"] == "SUSPECTED FILTERING" for s in infra),
            "available": count(infra, "available"),
            "blocked": count(infra, "blocked"),
            "skipped": count(infra, "skipped"),
        },
        "excluded": len(excluded),
    }


def _collect(tmp_dir):
    count = _int(_read(os.path.join(tmp_dir, ".count")).strip())
    servers = [parse_server(tmp_dir, idx) for idx in range(1, count + 1)]
    excluded = [line.strip() for line in _read(os.path.join(tmp_dir, ".excluded")).splitlines()
                if line.strip()]
    return servers, excluded


def _used_asns(servers):
    used = set()
    for s in servers:
        for c in s["cities"]:
            used.update(c["asns"])
        if s["mobile"]:
            used.update(s["mobile"]["asns"])
        for p in s["failedProbes"]:
            if p["asn"]:
                used.add(p["asn"])
    return used


def _now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def cmd_run(tmp_dir, store_dir, probes_file, asn_file, started, source):
    servers, excluded = _collect(tmp_dir)
    names = load_asn_names(asn_file)
    run_id = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    data = {
        "id": run_id,
        "startedAt": started,
        "finishedAt": _now(),
        "source": source,
        "sni": None,
        "sample": parse_probes(probes_file),
        "summary": _summary(servers, excluded),
        "servers": servers,
        "excluded": excluded,
        "asnNames": {a: names[a] for a in sorted(_used_asns(servers)) if a in names},
    }
    runs_dir = os.path.join(store_dir, "runs")
    _write_json(os.path.join(runs_dir, f"{run_id}.json"), data)
    _write_json(os.path.join(store_dir, "last.json"), data)

    # История ограничена: прогон - пара десятков килобайт, но cron гоняет
    # его несколько раз в день годами.
    runs = sorted(f for f in os.listdir(runs_dir) if f.endswith(".json") and not f.startswith("."))
    for old in runs[:-KEEP_RUNS]:
        try:
            os.remove(os.path.join(runs_dir, old))
        except OSError:
            pass
    print(run_id)


def cmd_check(tmp_dir, out_file, probes_file, asn_file, started, target, ip, sni):
    servers, _ = _collect(tmp_dir)
    names = load_asn_names(asn_file)
    server = servers[0] if servers else None
    if server:
        server["sni"] = sni
    data = {
        "status": "done",
        "target": target,
        "ip": ip,
        "sni": sni,
        "startedAt": started,
        "finishedAt": _now(),
        "sample": parse_probes(probes_file),
        "result": server,
        "asnNames": {a: names[a] for a in sorted(_used_asns(servers)) if a in names},
    }
    _write_json(out_file, data)


def main():
    args = sys.argv[1:]
    if len(args) == 2 and args[0] in ("metrics", "fleet-metrics"):
        directory, filename = os.path.split(args[1])
        server = parse_server(directory, os.path.splitext(filename)[0])
        print(format_metrics(server, fleet=args[0] == "fleet-metrics"))
        return 0
    if len(args) == 7 and args[0] == "run":
        cmd_run(*args[1:])
        return 0
    if len(args) == 9 and args[0] == "check":
        cmd_check(*args[1:])
        return 0
    print("ERROR BAD_ARGS", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
