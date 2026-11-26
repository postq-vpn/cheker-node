"""Форматирование HTML-отчёта Skynet для Telegram."""
import html
import re
import sys
from collections import Counter
from pathlib import Path

from tspu_store import format_metrics, parse_server


def cards(directory):
    root = Path(directory)
    servers = [parse_server(directory, i) for i in range(1, int((root / ".count").read_text()) + 1)]
    blocks = []
    if (root / ".vpn-status").exists():
        fleet = [s for s in servers if s["category"] != "infra"]
        counts = Counter(s["metrics"]["vpn"] for s in fleet)
        unknown = len(fleet) - counts["AVAILABLE"] - counts["FAILED"]
        blocks.append("<b>VPN из России · Xray Checker</b>\n"
                      f"Успешных проверок — {counts['AVAILABLE']} · Сбой — {counts['FAILED']}\n"
                      f"Без свежего результата — {unknown}")

    def priority(server):
        m = server["metrics"]
        return ({"blocked": 0, "skipped": 1, "available": 2}[server["atlasStatus"]],
                m["vpn"] != "FAILED", server["category"] == "infra")

    if servers:
        blocks.append("<b>Результаты по серверам</b>")

    for server in sorted(servers, key=priority):
        title = html.escape(server["name"], quote=False)
        if server["category"] == "infra":
            title += " · инфра"
        address = html.escape(server["ip"], quote=False)
        heading = f"<b>{title}</b>"
        if address and address != title:
            heading += f"\n<code>{address}</code>"
        blocks.append(heading + "\n" + html.escape(format_metrics(server, fleet=True), quote=False))
    return "\n\n".join(blocks)


def chunks(report, limit=3500):
    # Теги имеют нулевую длину для Telegram, HTML-сущность — длину символа.
    tokens = re.findall(r"<[^>]+>|&(?:#\d+|#x[\da-fA-F]+|\w+);|.", report.strip(), re.S)
    stack = []
    start = 0
    while start < len(tokens):
        end = start
        size = 0
        paragraph = line = 0
        while end < len(tokens):
            token = tokens[end]
            width = 0 if token.startswith("<") else len(html.unescape(token).encode("utf-16-le")) // 2
            if size + width > limit:
                break
            size += width
            end += 1
            if token == "\n":
                line = end
                if end > start + 1 and tokens[end - 2] == "\n":
                    paragraph = end
        if end < len(tokens):
            end = paragraph or line or end
        body = [tag for _, tag in stack]
        for token in tokens[start:end]:
            if token.startswith("</"):
                stack.pop()
            elif token.startswith("<"):
                stack.append((token[1:-1].split()[0], token))
            body.append(token)
        body.extend(f"</{name}>" for name, _ in reversed(stack))
        if any(t.strip() and not t.startswith("<") for t in tokens[start:end]):
            yield "".join(body)
        start = end


if __name__ == "__main__":
    if sys.argv[1] == "cards":
        print(cards(sys.argv[2]))
    elif sys.argv[1] == "chunks":
        for chunk in chunks(sys.stdin.read()):
            sys.stdout.buffer.write(chunk.encode() + b"\0")
