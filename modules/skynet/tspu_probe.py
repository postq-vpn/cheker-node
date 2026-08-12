#!/usr/bin/env python3
# ============================================================ #
# ==   RIPE ATLAS: ПРОБА ДОСТУПНОСТИ IP ИЗ ГОРОДОВ РОССИИ    == #
# ============================================================ #
#
# Метод измерения взят из публичного скрипта censorcheck.tlab.pw
# (автор: Nikola Tesla, https://t.me/tracerlab) - sslcert-проба зондами
# RIPE Atlas из сетей российских операторов, но с СОБСТВЕННЫМ RIPE Atlas
# API-ключом пользователя, а не общим ключом автора скрипта (он сам просит
# не использовать его ключ в сторонних проектах).
#
# Отличия от исходного метода:
#   1. Зонды отбираются ПО ГОРОДАМ, а не по ASN: ТСПУ ставят у оператора в
#      конкретном регионе, и блокировка в Новосибирске ничего не говорит про
#      Краснодар. Отбор по ASN давал случайный состав выборки - 63% всех
#      российских зондов сидят в Москве, и регионы попадали в неё как повезёт.
#   2. Набор зондов ФИКСИРОВАН на сутки (кэш): один и тот же список ID во всех
#      замерах всех серверов за прогон. Иначе проценты между серверами и
#      раундами несравнимы.
#   3. Зонд, у которого сломалась своя сеть, не считается блокировкой -
#      см. classify() и режим control.
#
# Режимы:
#   tspu_probe.py probes  <api_key> [--refresh]         - состав выборки
#   tspu_probe.py asnnames                              - ASN -> имя оператора
#   tspu_probe.py control <api_key> <ip> <sni>           - какие зонды мертвы
#   tspu_probe.py check   <api_key> <ip> <sni> [exclude] - замер по одному IP
#
# exclude - список ID зондов через запятую (выхлоп DOWN из режима control).

import json
import math
import os
import sys
import time
import urllib.error
import urllib.request

API = "https://atlas.ripe.net/api/v2"

# Кэш отобранных зондов. Рядом с базой флота (~/.reshala_fleet), тем же
# способом: домашний каталог того, кто запускает reshala.
CACHE_FILE = os.path.expanduser("~/.reshala_tspu_probes.json")
CACHE_TTL_H = float(os.environ.get("TSPU_PROBE_CACHE_TTL_H", "24"))

# Сколько зондов берём в каждом городе и с какого количества доступных
# зондов город вообще попадает в выборку. При квоте 3 процент по городу
# квантуется на 33 п.п. - поэтому город это СПРАВКА о географии, а не
# основание для вердикта (вердикт ставится по всей выборке, см. bash-модуль).
CITY_QUOTA = int(os.environ.get("TSPU_CITY_PROBES", "3"))
CITY_MIN_PROBES = int(os.environ.get("TSPU_CITY_MIN_PROBES", "5"))

# Зонд относим к ближайшему городу, если он не дальше этого радиуса.
# 120 км - компромисс: на 100 км вне городов остаётся ~21 зонд, на 150 км
# в "город" начинают попадать зонды из соседней области.
CITY_RADIUS_KM = float(os.environ.get("TSPU_CITY_RADIUS_KM", "120"))

# Строгий отбор по географии: выкидывать зонды, чьи координаты не заданы
# хостером, а угаданы по GeoIP (тег system-auto-geoip-city). Точность
# географии выше, но выборка падает с 12 городов до 9 - уходят Казань, Уфа
# и Пермь, где почти все зонды именно такие. По умолчанию выключено.
STRICT_GEO = os.environ.get("TSPU_PROBE_STRICT_GEO", "0") == "1"

# Зонд в дата-центре не годится всегда: ТСПУ ставят на абонентских сетях, а
# из стойки трафик идёт мимо той фильтрации, ради которой всё затевалось.
# Такой зонд ещё и врёт про город - именно так в выборку по Казани попадал
# зонд американского хостера.
EXCLUDE_TAGS = {"datacentre", "datacenter"}

# (имя, широта, долгота). Список заведомо шире, чем нужно: город попадает в
# выборку только если в нём реально нашлось >= CITY_MIN_PROBES зондов, так
# что при изменении популяции зондов список чинить не придётся.
CITIES = [
    ("Москва", 55.75, 37.62),
    ("Санкт-Петербург", 59.94, 30.31),
    ("Новосибирск", 55.03, 82.92),
    ("Екатеринбург", 56.84, 60.61),
    ("Казань", 55.79, 49.11),
    ("Нижний Новгород", 56.33, 44.00),
    ("Самара", 53.20, 50.15),
    ("Тольятти", 53.51, 49.42),
    ("Уфа", 54.74, 55.97),
    ("Пермь", 58.01, 56.23),
    ("Челябинск", 55.16, 61.40),
    ("Магнитогорск", 53.41, 59.05),
    ("Ростов-на-Дону", 47.23, 39.72),
    ("Краснодар", 45.04, 38.98),
    ("Сочи", 43.60, 39.73),
    ("Воронеж", 51.67, 39.21),
    ("Волгоград", 48.71, 44.51),
    ("Саратов", 51.53, 46.03),
    ("Тюмень", 57.15, 65.53),
    ("Сургут", 61.25, 73.42),
    ("Омск", 54.99, 73.37),
    ("Красноярск", 56.01, 92.87),
    ("Иркутск", 52.29, 104.28),
    ("Томск", 56.49, 84.95),
    ("Барнаул", 53.35, 83.78),
    ("Кемерово", 55.35, 86.09),
    ("Новокузнецк", 53.76, 87.11),
    ("Улан-Удэ", 51.83, 107.58),
    ("Чита", 52.03, 113.50),
    ("Якутск", 62.03, 129.73),
    ("Владивосток", 43.12, 131.89),
    ("Хабаровск", 48.48, 135.08),
    ("Ярославль", 57.63, 39.87),
    ("Тула", 54.20, 37.62),
    ("Тверь", 56.86, 35.92),
    ("Рязань", 54.63, 39.74),
    ("Брянск", 53.24, 34.36),
    ("Калуга", 54.51, 36.26),
    ("Владимир", 56.13, 40.41),
    ("Иваново", 57.00, 40.97),
    ("Смоленск", 54.78, 32.05),
    ("Белгород", 50.60, 36.59),
    ("Липецк", 52.61, 39.59),
    ("Курск", 51.74, 36.19),
    ("Ижевск", 56.85, 53.20),
    ("Киров", 58.60, 49.66),
    ("Чебоксары", 56.15, 47.25),
    ("Ульяновск", 54.32, 48.40),
    ("Пенза", 53.20, 45.00),
    ("Оренбург", 51.77, 55.10),
    ("Калининград", 54.71, 20.51),
    ("Мурманск", 68.97, 33.08),
    ("Архангельск", 64.54, 40.54),
    ("Вологда", 59.22, 39.89),
    ("Петрозаводск", 61.79, 34.35),
    ("Псков", 57.82, 28.33),
    ("Сыктывкар", 61.67, 50.84),
    ("Ставрополь", 45.04, 41.97),
    ("Махачкала", 42.98, 47.50),
    ("Владикавказ", 43.02, 44.68),
    ("Симферополь", 44.95, 34.10),
    ("Астрахань", 46.35, 48.04),
]

# Массовые операторы, у которых ТСПУ и стоит. Внутри города такие ASN берём
# в выборку первыми: зонд в дата-центре или у корпоративного провайдера
# может ходить мимо той фильтрации, ради которой всё затевалось.
CONSUMER_ASNS = {
    12389, 8402, 25513, 8359, 3216, 20485, 25490, 43727,
    12714, 34757, 29124, 12768, 8997, 42610, 31133, 21479,
    35807, 51604, 39927, 41733, 48642, 60139,
}

# Ошибки, которые означают "сломался сам зонд", а не "цель недоступна".
# Такой результат выкидывается из знаменателя целиком: считать его
# блокировкой - значит записывать в ТСПУ чужие сетевые аварии.
PROBE_FAULT_MARKERS = (
    "network is unreachable",
    "network is down",
    "no route to host",
    "name or service not known",
    "temporary failure in name resolution",
    "dnserr",
    "address family",
    "permission denied",
    "socket",
    "bind",
)


def _get(url, api_key=None, timeout=20):
    headers = {}
    if api_key:
        headers["Authorization"] = f"Key {api_key}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.loads(response.read().decode())


def _distance_km(lat1, lon1, lat2, lon2):
    r = 6371.0
    p = math.pi / 180
    dlat = (lat2 - lat1) * p
    dlon = (lon2 - lon1) * p
    a = (math.sin(dlat / 2) ** 2
         + math.cos(lat1 * p) * math.cos(lat2 * p) * math.sin(dlon / 2) ** 2)
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def _nearest_city(lat, lon):
    best_name, best_dist = None, None
    for name, clat, clon in CITIES:
        d = _distance_km(lat, lon, clat, clon)
        if best_dist is None or d < best_dist:
            best_name, best_dist = name, d
    if best_dist is not None and best_dist <= CITY_RADIUS_KM:
        return best_name
    return None


def fetch_ru_probes():
    """Все живые публичные зонды в РФ с рабочим IPv4."""
    probes = []
    url = (f"{API}/probes/?country_code=RU&status=1&is_public=true"
           f"&fields=id,asn_v4,geometry,tags&page_size=500")
    while url:
        page = _get(url)
        probes.extend(page.get("results", []))
        url = page.get("next")
    return probes


def select_probes():
    """Отбирает по CITY_QUOTA зондов в каждом подходящем городе.

    Внутри города зонды разных операторов чередуются: три зонда одного
    Ростелекома в Омске покажут одну точку фильтрации, а не город.
    """
    by_city = {}
    for p in fetch_ru_probes():
        slugs = {t.get("slug") for t in p.get("tags", [])}
        if "system-ipv4-works" not in slugs:
            continue
        if slugs & EXCLUDE_TAGS:
            continue
        if STRICT_GEO and "system-auto-geoip-city" in slugs:
            continue
        geo = (p.get("geometry") or {}).get("coordinates")
        if not geo or len(geo) < 2:
            continue
        city = _nearest_city(geo[1], geo[0])
        if not city:
            continue
        by_city.setdefault(city, []).append(
            {"id": p["id"], "asn": p.get("asn_v4") or 0, "city": city}
        )

    chosen = []
    for city, candidates in by_city.items():
        if len(candidates) < CITY_MIN_PROBES:
            continue

        by_asn = {}
        for c in candidates:
            by_asn.setdefault(c["asn"], []).append(c)
        for group in by_asn.values():
            group.sort(key=lambda c: c["id"])

        # Массовые операторы вперёд, дальше - у кого больше зондов (такой ASN
        # реже отваливается целиком), при равенстве по номеру ASN ради
        # воспроизводимого от прогона к прогону состава.
        asn_order = sorted(
            by_asn,
            key=lambda a: (a not in CONSUMER_ASNS, -len(by_asn[a]), a),
        )

        picked, depth = [], 0
        while len(picked) < CITY_QUOTA:
            added = False
            for asn in asn_order:
                if len(picked) >= CITY_QUOTA:
                    break
                if depth < len(by_asn[asn]):
                    picked.append(by_asn[asn][depth])
                    added = True
            if not added:
                break
            depth += 1
        chosen.extend(picked)

    chosen.sort(key=lambda c: (c["city"], c["id"]))
    return chosen


def asn_holder(asn):
    """Человекочитаемое имя оператора по номеру ASN (RIPEstat).

    Ключа не требует. Спрашивается только при пересборке кэша - раз в сутки
    на несколько десятков ASN, поэтому лимиты RIPEstat не трогаем.
    """
    try:
        data = _get(f"https://stat.ripe.net/data/as-overview/data.json?resource=AS{asn}",
                    timeout=10)
        holder = (data.get("data") or {}).get("holder") or ""
    except Exception:
        return ""

    holder = " ".join(holder.replace('"', "").split())
    # У большинства российских ASN holder выглядит как "ROSTELECOM-AS PJSC
    # Rostelecom": первый токен - технический хэндл, читать в отчёте нужно
    # то, что после него.
    parts = holder.split(" ", 1)
    if len(parts) == 2 and parts[0].endswith("-AS"):
        holder = parts[1]
    return holder[:28]


def load_cache(force=False):
    """Отобранный набор зондов из кэша, при протухании - заново.

    Набор фиксируется на сутки намеренно: проценты по серверам и раундам
    сравнимы между собой, только если их меряли одни и те же зонды.
    """
    if not force and os.path.exists(CACHE_FILE):
        try:
            with open(CACHE_FILE, "r", encoding="utf-8") as fh:
                cached = json.load(fh)
            fresh = (time.time() - cached.get("generated", 0)) < CACHE_TTL_H * 3600
            same_shape = (cached.get("quota") == CITY_QUOTA
                          and cached.get("min_probes") == CITY_MIN_PROBES
                          and cached.get("strict_geo") == STRICT_GEO)
            if fresh and same_shape and cached.get("probes"):
                return cached
        except Exception:
            pass

    probes = select_probes()
    names = {}
    for asn in sorted({p["asn"] for p in probes if p["asn"]}):
        holder = asn_holder(asn)
        if holder:
            names[str(asn)] = holder

    cache = {
        "generated": time.time(),
        "quota": CITY_QUOTA,
        "min_probes": CITY_MIN_PROBES,
        "strict_geo": STRICT_GEO,
        "probes": probes,
        "asn_names": names,
    }
    if probes:
        try:
            tmp = CACHE_FILE + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(cache, fh, ensure_ascii=False)
            os.replace(tmp, CACHE_FILE)
        except Exception:
            pass
    return cache


def load_probe_set(api_key, force=False):
    return load_cache(force=force).get("probes", [])


def _http_error_detail(e):
    """Читаемая причина отказа RIPE Atlas вместо голого имени исключения.

    Реальная причина (просроченный ключ, нет права на создание измерений,
    кончились кредиты) лежит не в error.detail - там общая обёртка, - а в
    error.errors[] по конкретным полям запроса.
    """
    try:
        body = e.read().decode("utf-8", errors="replace")
    except Exception:
        body = ""
    detail = body
    try:
        err_obj = json.loads(body).get("error", {})
        field_errors = err_obj.get("errors") or []
        if field_errors:
            parts = []
            for fe in field_errors:
                source = fe.get("source", {})
                src = source.get("pointer", "") if isinstance(source, dict) else ""
                msg = fe.get("detail", "")
                parts.append(f"{src}: {msg}" if src else msg)
            detail = "; ".join(p for p in parts if p) or body
        else:
            detail = err_obj.get("detail") or err_obj.get("title") or body
    except Exception:
        pass
    return " ".join(detail.split())[:300]


def measure(api_key, target_ip, sni, probe_ids):
    """Одно sslcert-измерение по фиксированному списку зондов.

    Возвращает список результатов RIPE Atlas или бросает RuntimeError с
    причиной, пригодной для показа пользователю.
    """
    ids = ",".join(str(i) for i in probe_ids)
    payload = {
        "definitions": [{
            "target": target_ip,
            "description": "Reshala TSPU Check",
            "type": "sslcert",
            "port": 443,
            "hostname": sni,
            "af": 4,
        }],
        "probes": [{"requested": len(probe_ids), "type": "probes", "value": ids}],
        "is_oneoff": True,
    }

    req = urllib.request.Request(
        f"{API}/measurements/",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json",
                 "Authorization": f"Key {api_key}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            msm_id = json.loads(response.read().decode())["measurements"][0]
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP{e.code}:{_http_error_detail(e)}")
    except Exception as e:
        raise RuntimeError(f"API_FAIL:{type(e).__name__}")

    results_url = f"{API}/measurements/{msm_id}/results/"
    results = []
    for _ in range(30):
        time.sleep(2)
        try:
            results = _get(results_url)
            if len(results) >= len(probe_ids):
                break
        except Exception:
            pass

    if not results:
        raise RuntimeError("NO_DATA")
    return results


def classify(result):
    """ok | fault | blocked для одного результата зонда.

    alert - это TLS-alert от самой цели: соединение дошло и было отвергнуто
    уже на уровне TLS, то есть ТСПУ его не резал. В исходном скрипте такой
    результат попадал в "заблокировано" - в выборке RIPE это около 7% от всех
    неуспешных ответов.
    """
    if "cert" in result:
        return "ok"
    if result.get("alert"):
        return "ok"
    err = str(result.get("err") or result.get("dnserr") or "").lower()
    if err and any(marker in err for marker in PROBE_FAULT_MARKERS):
        return "fault"
    return "blocked"


def cmd_probes(api_key, force=False):
    probes = load_probe_set(api_key, force=force)
    if not probes:
        print("ERROR NO_PROBES")
        return
    cities = {}
    for p in probes:
        cities[p["city"]] = cities.get(p["city"], 0) + 1
    print(f"OK {len(probes)} {len(cities)}")
    for city, count in sorted(cities.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f"CITY {count} {city}")


def cmd_asnnames():
    """Имена операторов из кэша: "<asn>\\t<имя>". Кэш не пересобирает."""
    for asn, name in sorted(load_cache().get("asn_names", {}).items(),
                            key=lambda kv: int(kv[0])):
        print(f"{asn}\t{name}")


def cmd_control(api_key, ip, sni):
    """Замер по заведомо неблокируемой цели: кто из зондов сейчас не в форме.

    Всё, что не достучалось до контроля, в этом раунде выкидывается из
    расчёта по серверам флота: такой зонд ничего не говорит про ТСПУ.
    """
    probes = load_probe_set(api_key)
    if not probes:
        print("ERROR NO_PROBES")
        return

    ids = [p["id"] for p in probes]
    try:
        results = measure(api_key, ip, sni, ids)
    except RuntimeError as e:
        print(f"ERROR {e}")
        return

    down = [str(r.get("prb_id")) for r in results
            if r.get("prb_id") and classify(r) != "ok"]
    # Зонд, который вообще промолчал, тоже не в форме.
    answered = {r.get("prb_id") for r in results}
    down.extend(str(i) for i in ids if i not in answered)

    print(f"OK {len(ids) - len(down)} {len(ids)}")
    if down:
        print("DOWN " + ",".join(sorted(set(down), key=int)))


def cmd_check(api_key, ip, sni, exclude_raw=""):
    probes = load_probe_set(api_key)
    if not probes:
        print("ERROR NO_PROBES")
        return

    excluded = {int(x) for x in exclude_raw.split(",") if x.strip().isdigit()}
    meta = {p["id"]: p for p in probes}
    ids = [p["id"] for p in probes if p["id"] not in excluded]
    if not ids:
        print("ERROR ALL_PROBES_DOWN")
        return

    try:
        results = measure(api_key, ip, sni, ids)
    except RuntimeError as e:
        print(f"ERROR {e}")
        return

    success = blocked = fault = 0
    asn_fail = {}
    city_stat = {}          # город -> [успешно, всего]
    city_asn_fail = {}      # город -> {ASN: сколько зондов не достучалось}

    for r in results:
        prb_id = r.get("prb_id")
        if prb_id in excluded:
            continue
        verdict = classify(r)
        if verdict == "fault":
            fault += 1
            continue

        info = meta.get(prb_id, {})
        city = info.get("city")
        if city:
            stat = city_stat.setdefault(city, [0, 0])
            stat[1] += 1
        if verdict == "ok":
            success += 1
            if city:
                city_stat[city][0] += 1
        else:
            blocked += 1
            asn = info.get("asn")
            if asn:
                asn_fail[asn] = asn_fail.get(asn, 0) + 1
                if city:
                    per_city = city_asn_fail.setdefault(city, {})
                    per_city[asn] = per_city.get(asn, 0) + 1

    total = success + blocked
    if total == 0:
        print(f"ERROR NO_USABLE_RESULTS:{fault}")
        return

    print(f"OK {success * 100 // total} {success} {total} {fault}")
    for asn, count in sorted(asn_fail.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f"ASN {asn} {count}")
    # Имя города идёт последним полем: в нём бывает пробел ("Нижний
    # Новгород"), и в bash оно должно попасть в остаток строки целиком.
    for city, (ok_n, tot_n) in sorted(city_stat.items()):
        failed = city_asn_fail.get(city, {})
        asns = ",".join(str(a) for a, _ in
                        sorted(failed.items(), key=lambda kv: (-kv[1], kv[0]))) or "-"
        print(f"CITY {ok_n} {tot_n} {asns} {city}")


def main():
    args = sys.argv[1:]
    if not args:
        print("ERROR BAD_ARGS")
        return

    mode = args[0]
    try:
        if mode == "probes" and len(args) >= 2:
            cmd_probes(args[1], force="--refresh" in args)
            return
        if mode == "asnnames":
            cmd_asnnames()
            return
        if mode == "control" and len(args) >= 4:
            cmd_control(args[1], args[2], args[3])
            return
        if mode == "check" and len(args) >= 4:
            cmd_check(args[1], args[2], args[3], args[4] if len(args) > 4 else "")
            return
    except Exception as e:
        print(f"ERROR UNEXPECTED:{type(e).__name__}")
        return

    print("ERROR BAD_ARGS")


if __name__ == "__main__":
    main()
