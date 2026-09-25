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
#   1. Два режима отбора зондов (TSPU_CHECK_MODE). Режим common повторяет
#      исходный - по сетям крупных операторов. Режим geo (по умолчанию)
#      набирает зонды ПО ГОРОДАМ: ТСПУ ставят у оператора в конкретном
#      регионе, и блокировка в Новосибирске ничего не говорит про Краснодар,
#      а отбор по ASN даёт случайный состав выборки - 63% всех российских
#      зондов сидят в Москве, и регионы попадают в неё как повезёт.
#   2. Набор зондов ФИКСИРОВАН на сутки (кэш): один и тот же список ID во всех
#      замерах всех серверов за прогон. Иначе проценты между серверами и
#      прогонами несравнимы.
#   3. Зонд, у которого сломалась своя сеть, не считается блокировкой -
#      см. classify() и перепроверку промахов в cmd_check().
#
# Режимы:
#   tspu_probe.py probes   <api_key> [--refresh]        - состав выборки
#   tspu_probe.py asnnames                              - ASN -> имя оператора
#   tspu_probe.py check    <api_key> <ip> <sni>         - замер по одному IP

import json
import math
import os
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

API = "https://atlas.ripe.net/api/v2"

# Контрольные цели для перепроверки промахов: заведомо доступные зарубежные
# IP с TLS на 443. Именно зарубежные - зонд, у которого лёг весь выход за
# границу, не годится и для проверки наших серверов.
#
# Список, а не одна цель, из-за платформенного лимита RIPE Atlas: больше 25
# одновременных измерений на ОДИН адрес не пускают, причём считаются все
# измерения всех пользователей. На самых популярных резолверах лимит выбран
# всегда - 8.8.8.8 и 1.1.1.1 отдают "We do not allow more than 25 concurrent
# measurements to the same target" в любой момент. Поэтому цели перебираются
# по очереди до первой, которая пустила.
CONTROL_TARGETS = [
    ("9.9.9.9", "dns.quad9.net"),
    ("208.67.222.222", "dns.opendns.com"),
    ("94.140.14.14", "dns.adguard-dns.com"),
    ("149.112.112.112", "dns.quad9.net"),
]

# Свою цель можно навязать через конфиг - тогда список не используется.
_CTL_IP = os.environ.get("TSPU_CONTROL_IP", "").strip()
_CTL_SNI = os.environ.get("TSPU_CONTROL_SNI", "").strip()
if _CTL_IP and _CTL_SNI:
    CONTROL_TARGETS = [(_CTL_IP, _CTL_SNI)]

# Кэш отобранных зондов. Рядом с базой флота (~/.reshala_fleet), тем же
# способом: домашний каталог того, кто запускает reshala.
CACHE_FILE = os.path.expanduser("~/.reshala_tspu_probes.json")
CACHE_TTL_H = float(os.environ.get("TSPU_PROBE_CACHE_TTL_H", "24"))

# Как набирать выборку:
#   geo    - по городам: видно, ГДЕ режут, но зондов больше и прогон дороже.
#   common - по сетям крупных операторов, как в исходном censorcheck.tlab.pw:
#            один процент на сервер, без разбивки по городам, зато втрое
#            дешевле. Годится, когда нужен сам факт блокировки.
CHECK_MODE = os.environ.get("TSPU_CHECK_MODE", "geo").strip().lower()

# Сколько зондов берём в каждом городе и с какого количества доступных
# зондов город вообще попадает в выборку. Квота задаёт и шаг процента по
# городу: при 5 зондах это 20 п.п., при 3 - уже 33. Только для режима geo.
CITY_QUOTA = int(os.environ.get("TSPU_CITY_PROBES", "5"))
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

# Абонентские сети - мобильные и домашние операторы, у которых ТСПУ и стоит.
# Зонд у хостера или в корпоративной сети ходит мимо той фильтрации, ради
# которой всё затевалось, и завышает доступность. Тега datacentre на таких
# зондах чаще всего нет (Selectel, Baxet, Timeweb, ColoCrossing его не
# ставят), поэтому по умолчанию берём ТОЛЬКО ASN из этого списка
# (TSPU_CONSUMER_ONLY=1). Список закрытый намеренно: хостеров сотни и новые
# появляются каждый месяц, а абонентских операторов с зондами - десятки.
# Свою сеть можно добавить через TSPU_EXTRA_ASNS, не трогая код.
CONSUMER_ASNS = {
    # Ростелеком (включая региональные ASN и бывший РТК-Юг)
    12389, 42610, 25515, 25490, 35125, 8997, 21479, 21127,
    # Билайн
    3216, 8402, 42842, 16345,
    # МТС и МГТС
    8359, 13055, 8580, 197023, 28884, 13174, 25513,
    # Мегафон (включая NetByNet)
    12714, 20632, 31133, 31163, 31213, 31224, 25159,
    # T2 (Tele2)
    15378, 12958, 41330,
    # ТТК
    20485, 15774,
    # Дом.ру / ЭР-Телеком - у каждого региона свой ASN
    12768, 51604, 41733, 57378, 50543, 5563, 34533, 51645, 50544,
    39435, 51035, 52207, 201825, 39927, 48642, 60139,
    # Крупные региональные операторы
    24955,  # Уфанет
    8369,   # Интерсвязь (Челябинск)
    31200,  # Новотелеком (Новосибирск)
    21087,  # Электронный город (Новосибирск)
    34757,  # Сибирские сети
    29124,  # Искрателеком
    35807,  # SkyNet (Санкт-Петербург)
    15582,  # Акадо
    8492,   # Obit
    28840,  # Таттелеком
    58002,  # Связьинформ
    15974, 8427,  # ТрансТел
    43727, 44604,  # Квант-Телеком
    5547,   # Ориент-Телеком
    # Домашние провайдеры в городах выборки
    13178,  # Реал-нет (Воронеж)
    15930,  # Wipline (Воронеж)
    12668,  # КомТехЦентр (Екатеринбург)
    28890,  # Инсис (Екатеринбург)
    49469,  # Мелт-Интернет (Казань)
    47165,  # Омские кабельные сети
    15870,  # БС-Телеком (Омск)
    57494,  # Адман (Новосибирск)
    51724,  # Флайнет (Томск)
    57781,  # Яртелесервис (Ярославль)
    44507,  # Костромская ГТС
    44552,  # Альтура (Саратов)
    60246,  # ПГ-19 (Ростов-на-Дону)
    42893,  # Home Internet (Санкт-Петербург)
    42668,  # Nevalink (Санкт-Петербург)
    24739,  # Северен-Телеком (Санкт-Петербург)
    47236,  # Ситилинк (Петрозаводск)
    48969,  # Парус-Телеком (Тула)
}

_EXTRA = os.environ.get("TSPU_EXTRA_ASNS", "")
CONSUMER_ASNS |= {int(a) for a in _EXTRA.replace(" ", "").split(",") if a.isdigit()}

# 1 - брать зонды только из CONSUMER_ASNS. 0 - как раньше: абонентские сети
# идут в выборку первыми, но город добирается зондами любых сетей.
CONSUMER_ONLY = os.environ.get("TSPU_CONSUMER_ONLY", "1") == "1"

# Зонды на мобильном подключении. В мобильных сетях ТСПУ стоит отдельно от
# домашних, а зондов RIPE Atlas там почти нет (на сентябрь 2026 - один на
# всю Россию), поэтому их берём ВСЕ, где бы они ни стояли, без квоты и
# порога города. В городскую статистику они не идут - у них своя строка
# MOBILE и свой блок в отчёте. Узнаём их по тегам, которые ставит владелец.
# ASN не проверяем: тег lte хостер на зонд в стойке не поставит.
#
# Нужен именно тег радиотехнологии: голый "mobile" владельцы ставят и на
# проводные зонды (у Ростелекома в Екатеринбурге так). И наоборот, зонд с
# тегом проводного подключения рядом - не мобильный, даже если "3g" в тегах
# есть (у Сибирских сетей рядом стоят cable и ftth).
MOBILE_PROBES = os.environ.get("TSPU_MOBILE_PROBES", "1") == "1"
MOBILE_TAGS = {"lte", "4g", "5g", "3g"}
WIRED_TAGS = {"cable", "ftth", "fibre", "fiber", "dsl", "adsl", "vdsl", "ethernet"}

# Режим common: сколько зондов брать в каждой операторской сети. Список и
# числа - те же, что в исходном censorcheck.tlab.pw. По ряду ASN зондов
# сейчас меньше, чем просят (у Мегафона AS12714 просят 4, живых 2), поэтому
# берём сколько есть.
RIPE_PROBE_ASNS = [
    (3, 12389), (5, 8402), (5, 25513), (3, 8359), (3, 3216), (2, 20485),
    (1, 25490), (1, 43727), (4, 12714), (2, 34757), (2, 29124), (2, 12768),
]

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


_RU_PROBES = None


def fetch_ru_probes():
    """Все живые публичные зонды в РФ с рабочим IPv4.

    Запоминается на время процесса: при пересборке кэша список нужен и
    городской выборке, и мобильной - качать его дважды незачем.
    """
    global _RU_PROBES
    if _RU_PROBES is not None:
        return _RU_PROBES
    probes = []
    url = (f"{API}/probes/?country_code=RU&status=1&is_public=true"
           f"&fields=id,asn_v4,geometry,tags&page_size=500")
    while url:
        page = _get(url)
        probes.extend(page.get("results", []))
        url = page.get("next")
    _RU_PROBES = probes
    return probes


def _usable_probes(skip_ids=()):
    """Живые зонды, годные для замера: рабочий IPv4, не из стойки и - при
    CONSUMER_ONLY - только в сетях мобильных и домашних операторов."""
    for p in fetch_ru_probes():
        if p["id"] in skip_ids:
            continue
        slugs = {t.get("slug") for t in p.get("tags", [])}
        if "system-ipv4-works" not in slugs:
            continue
        if slugs & EXCLUDE_TAGS:
            continue
        if CONSUMER_ONLY and (p.get("asn_v4") or 0) not in CONSUMER_ASNS:
            continue
        if STRICT_GEO and "system-auto-geoip-city" in slugs:
            continue
        yield p, slugs


def select_probes_by_asn(skip_ids=()):
    """Режим common: по несколько зондов в сетях крупных операторов.

    Города не размечаются вовсе - в этом режиме отчёт про них и не говорит.
    """
    by_asn = {}
    for p, _slugs in _usable_probes(skip_ids):
        asn = p.get("asn_v4") or 0
        by_asn.setdefault(asn, []).append({"id": p["id"], "asn": asn, "city": ""})

    chosen = []
    for want, asn in RIPE_PROBE_ASNS:
        group = sorted(by_asn.get(asn, []), key=lambda c: c["id"])
        chosen.extend(group[:want])

    chosen.sort(key=lambda c: (c["asn"], c["id"]))
    return chosen


def select_probes(skip_ids=()):
    """Режим geo: по CITY_QUOTA зондов в каждом подходящем городе.

    Внутри города зонды разных операторов чередуются: три зонда одного
    Ростелекома в Омске покажут одну точку фильтрации, а не город.
    """
    by_city = {}
    for p, _slugs in _usable_probes(skip_ids):
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


def select_mobile_probes():
    """Все годные зонды на мобильном подключении, без квоты и порога города.

    city пустой намеренно: в городскую статистику и в порог "Под замену"
    одиночный мобильный зонд не идёт. Где он стоит - в поле place, только
    для подписи в отчёте.
    """
    chosen = []
    for p in fetch_ru_probes():
        slugs = {t.get("slug") for t in p.get("tags", [])}
        if "system-ipv4-works" not in slugs or slugs & EXCLUDE_TAGS:
            continue
        if not slugs & MOBILE_TAGS or slugs & WIRED_TAGS:
            continue
        geo = (p.get("geometry") or {}).get("coordinates") or []
        place = _nearest_city(geo[1], geo[0]) if len(geo) >= 2 else None
        chosen.append({"id": p["id"], "asn": p.get("asn_v4") or 0, "city": "",
                       "mobile": True, "place": place or ""})
    chosen.sort(key=lambda c: c["id"])
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

    Набор фиксируется на сутки намеренно: проценты по серверам и прогонам
    сравнимы между собой, только если их меряли одни и те же зонды.
    """
    if not force and os.path.exists(CACHE_FILE):
        try:
            with open(CACHE_FILE, "r", encoding="utf-8") as fh:
                cached = json.load(fh)
            fresh = (time.time() - cached.get("generated", 0)) < CACHE_TTL_H * 3600
            same_shape = (cached.get("mode") == CHECK_MODE
                          and cached.get("quota") == CITY_QUOTA
                          and cached.get("min_probes") == CITY_MIN_PROBES
                          and cached.get("strict_geo") == STRICT_GEO
                          and cached.get("consumer_only") == CONSUMER_ONLY
                          and cached.get("asn_set") == sorted(CONSUMER_ASNS)
                          and cached.get("mobile") == MOBILE_PROBES)
            if fresh and same_shape and cached.get("probes"):
                return cached
        except Exception:
            pass

    # Мобильные - первыми: иначе LTE-зонд из абонентской сети уйдёт в
    # городскую квоту и в отчёте потеряется среди проводных.
    mobile = select_mobile_probes() if MOBILE_PROBES else []
    skip = {p["id"] for p in mobile}
    probes = (select_probes_by_asn(skip) if CHECK_MODE == "common"
              else select_probes(skip))
    probes += mobile
    names = {}
    for asn in sorted({p["asn"] for p in probes if p["asn"]}):
        holder = asn_holder(asn)
        if holder:
            names[str(asn)] = holder

    cache = {
        "generated": time.time(),
        "mode": CHECK_MODE,
        "quota": CITY_QUOTA,
        "min_probes": CITY_MIN_PROBES,
        "strict_geo": STRICT_GEO,
        "consumer_only": CONSUMER_ONLY,
        "asn_set": sorted(CONSUMER_ASNS),
        "mobile": MOBILE_PROBES,
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


def measure_control(api_key, probe_ids):
    """Контрольный замер: перебирает CONTROL_TARGETS до первой доступной цели.

    Отказ по лимиту одновременных измерений приходит ДО создания измерения,
    поэтому неудачная попытка не стоит кредитов.
    """
    last_error = "нет целей"
    for ip, sni in CONTROL_TARGETS:
        try:
            return measure(api_key, ip, sni, probe_ids)
        except RuntimeError as e:
            last_error = str(e)
    raise RuntimeError(last_error)


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
        if p.get("city"):
            cities[p["city"]] = cities.get(p["city"], 0) + 1
    # В режиме common городов нет вовсе - вторым числом уходит 0, и bash по
    # нему понимает, что раздела про географию в отчёте не будет.
    print(f"OK {len(probes)} {len(cities)}")
    for city, count in sorted(cities.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f"CITY {count} {city}")
    # Мобильные зонды - по строке на зонд: их единицы, и в отчёте каждый
    # подписывается оператором и местом. Место последним полем (пробелы).
    for p in probes:
        if p.get("mobile"):
            print(f"MOBILE {p['asn']} {p.get('place') or '-'}")


def cmd_asnnames():
    """Имена операторов из кэша: "<asn>\\t<имя>". Кэш не пересобирает."""
    for asn, name in sorted(load_cache().get("asn_names", {}).items(),
                            key=lambda kv: int(kv[0])):
        print(f"{asn}\t{name}")


def _failed_ids(results):
    """ID зондов, которые в этом замере не достучались (fault не в счёт)."""
    return {r.get("prb_id") for r in results
            if r.get("prb_id") and classify(r) == "blocked"}


def _ok_ids(results):
    return {r.get("prb_id") for r in results
            if r.get("prb_id") and classify(r) == "ok"}


def cmd_check(api_key, ip, sni):
    """Замер по одному IP с перепроверкой ТОЛЬКО промахнувшихся зондов.

    Полный замер делается один раз. Если промахов нет - на этом всё, второй
    замер не нужен и не оплачивается. Если промахи есть, по ним - и только по
    ним - идут два маленьких замера: повтор по тому же серверу и контрольный
    по заведомо доступной цели.

    Зонд уходит в блокировку, только если промахнулся ОБА раза и при этом
    доказал, что жив (дотянулся до контроля). Отвалившийся зонд отсеивается
    сам собой: до контроля он тоже не дотянется, и из расчёта уйдёт целиком -
    ни в числитель, ни в знаменатель.
    """
    probes = load_probe_set(api_key)
    if not probes:
        print("ERROR NO_PROBES")
        return

    meta = {p["id"]: p for p in probes}
    ids = [p["id"] for p in probes]

    try:
        results = measure(api_key, ip, sni, ids)
    except RuntimeError as e:
        print(f"ERROR {e}")
        return

    ok_ids = _ok_ids(results)
    missed = _failed_ids(results)
    fault_n = sum(1 for r in results if classify(r) == "fault")

    confirmed, noise, dead = set(), set(), set()
    if missed:
        retry_ids = sorted(missed)
        # Повтор и контроль независимы - гоняем их одновременно, чтобы
        # прогон не удлинялся на целый замер.
        with ThreadPoolExecutor(max_workers=2) as pool:
            again = pool.submit(measure, api_key, ip, sni, retry_ids)
            control = pool.submit(measure_control, api_key, retry_ids)
            try:
                again_failed = _failed_ids(again.result())
            except RuntimeError:
                again_failed = set(retry_ids)
            try:
                control_ok = _ok_ids(control.result())
            except RuntimeError:
                # Контроль не удался - подтверждать живость нечем. Считаем
                # промахи неподтверждёнными, а не блокировкой: ошибиться в
                # сторону "доступно" здесь безопаснее.
                control_ok = set()

        for pid in missed:
            if pid not in control_ok:
                dead.add(pid)
            elif pid in again_failed:
                confirmed.add(pid)
            else:
                noise.add(pid)

    # Молчуны (зонд не вернул результата вовсе) и fault в знаменатель не
    # идут: они ничего не говорят ни за блокировку, ни против неё.
    counted = ok_ids | confirmed | noise
    total = len(counted)
    if total == 0:
        print(f"ERROR NO_USABLE_RESULTS:{fault_n}")
        return

    success = len(ok_ids) + len(noise)
    asn_fail = {}
    city_stat = {}          # город -> [успешно, всего]
    city_asn_fail = {}      # город -> {ASN: сколько зондов подтверждённо не дошло}
    mob_stat = [0, 0]       # мобильные зонды: [успешно, всего]
    mob_asn_fail = {}

    for pid in counted:
        info = meta.get(pid, {})
        if info.get("mobile"):
            mob_stat[1] += 1
            if pid not in confirmed:
                mob_stat[0] += 1
            continue
        city = info.get("city")
        if not city:
            continue
        stat = city_stat.setdefault(city, [0, 0])
        stat[1] += 1
        if pid not in confirmed:
            stat[0] += 1

    for pid in confirmed:
        info = meta.get(pid, {})
        asn = info.get("asn")
        if not asn:
            continue
        asn_fail[asn] = asn_fail.get(asn, 0) + 1
        if info.get("mobile"):
            mob_asn_fail[asn] = mob_asn_fail.get(asn, 0) + 1
        city = info.get("city")
        if city:
            per_city = city_asn_fail.setdefault(city, {})
            per_city[asn] = per_city.get(asn, 0) + 1

    print(f"OK {success * 100 // total} {success} {total} "
          f"{fault_n} {len(dead)} {len(noise)}")
    for asn, count in sorted(asn_fail.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f"ASN {asn} {count}")
    # Имя города идёт последним полем: в нём бывает пробел ("Нижний
    # Новгород"), и в bash оно должно попасть в остаток строки целиком.
    for city, (ok_n, tot_n) in sorted(city_stat.items()):
        if ok_n == tot_n:
            continue
        failed = city_asn_fail.get(city, {})
        asns = ",".join(str(a) for a, _ in
                        sorted(failed.items(), key=lambda kv: (-kv[1], kv[0]))) or "-"
        print(f"CITY {ok_n} {tot_n} {asns} {city}")
    # Мобильная строка - всегда, когда мобильный зонд вообще ответил: отчёту
    # нужно знать и "доступен", а не только промахи.
    if mob_stat[1]:
        asns = ",".join(str(a) for a in sorted(mob_asn_fail)) or "-"
        print(f"MOBILE {mob_stat[0]} {mob_stat[1]} {asns}")


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
        if mode == "check" and len(args) >= 4:
            cmd_check(args[1], args[2], args[3])
            return
    except Exception as e:
        print(f"ERROR UNEXPECTED:{type(e).__name__}")
        return

    print("ERROR BAD_ARGS")


if __name__ == "__main__":
    main()
