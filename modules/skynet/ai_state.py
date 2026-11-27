"""Daily IPv4 observations and pending Telegram notifications for Skynet nodes."""
import html
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

ACCESS = {"yes": "доступен", "no": "недоступен (блокировка региона)", "ipblock": "недоступен (блокировка IP)"}


def observe(directory, index):
    if (directory / f"{index}.status").read_text().strip() != "OK":
        return None, {}, "Сбой запуска или соединения с нодой"
    try:
        report = json.loads((directory / f"{index}.out").read_text())
        if report["version"] != 2:
            raise ValueError
        groups = report["results"]
        google = next((row for row in groups["platforms"] if row["id"] == "google"), {})
        country = (google.get("ipv4") or {}).get("country")
        services = {}
        for row in groups["ai"]:
            access = (row["ipv4"] or {}).get("access")
            services[row["id"]] = {"service": row["service"], "access": access if access in ACCESS else None}
        return country if re.fullmatch("[A-Z]{2}", country or "") else None, services, None
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None, {}, "Нет корректного отчёта ipregion"


def record(state, directory):
    checked = datetime.now(timezone.utc).isoformat(timespec="seconds")
    nodes = {}
    summary = []
    for index in range(1, int((directory / ".count").read_text()) + 1):
        name = (directory / f"{index}.name").read_text().strip()
        country, services, error = observe(directory, index)
        previous = state["nodes"].get(name, {})
        known = previous.get("known", {})
        last_country = previous.get("last_country")
        changes = []
        region_changed = country and country != last_country and (last_country or country == "RU")
        if region_changed:
            changes.append(f"{last_country or 'первый замер'} → {country}")
        for key, row in services.items():
            access = row["access"]
            if access is None:
                continue
            before = known.get(key)
            label = row["service"]
            current = ACCESS[access]
            if before != access and (before or access != "yes"):
                old = ACCESS[before] if before else "первый замер"
                changes.append(f"{label}: {old} → {current}")
            elif region_changed and "gemini" in label.lower():
                changes.append(f"{label} {current}")
            known[key] = access
        if error:
            changes.append(error)
        else:
            missing = [row["service"] for row in services.values() if row["access"] is None]
            if not country:
                missing.append("регион Google")
            if not services:
                missing.append("AI")
            if missing:
                changes.append("нет данных: " + ", ".join(missing))
        nodes[name] = dict(checked=checked, country=country, services=services, error=error,
                           known=known, last_country=country or last_country)
        if changes:
            display_name = name.rsplit(" (", 1)[0] if name.endswith(")") else name
            summary.append(display_name + " — " + "; ".join(changes))
    if not nodes:
        summary.append("Нет нод для проверки")
    state["pending"].append(html.escape("\n".join(summary) or "нет изменений"))
    state["nodes"] = nodes


def main():
    path, command = Path(sys.argv[1]), sys.argv[2]
    state = json.loads(path.read_text()) if path.exists() else {"nodes": {}, "pending": []}
    if command == "next":
        pending = [html.unescape(message) for message in state["pending"] if message != "нет изменений"]
        sys.stdout.write("\n\n".join(pending) or ("нет изменений" if state["pending"] else ""))
        return
    if command == "status":
        if not state["nodes"]:
            print("Нет результатов проверки нод.")
        for name, node in state["nodes"].items():
            print(f"{name} · {node['checked']} · IPv4")
            print("  Google / регион для Gemini:", node["country"] or "нет данных")
            if node["error"]:
                print(" ", node["error"])
            for row in node["services"].values():
                print(f"  {row['service']}: {ACCESS.get(row['access'], 'нет данных')}")
        return
    if command == "record":
        record(state, Path(sys.argv[3]))
    elif command == "ack":
        state["pending"].clear()
    else:
        raise ValueError(command)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(state, ensure_ascii=False))
    os.replace(temporary, path)


if __name__ == "__main__":
    main()
