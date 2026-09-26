#!/bin/bash
# ext-check.sh — внешняя проверка доступности порта инбаунда через check-host.net.
# Отвечает на вопрос «блокирует ли провайдер?» — проверяют внешние узлы по всему миру.
#
# Запуск: bash /root/scripts/ext-check.sh 8443     (один порт)
#         bash /root/scripts/ext-check.sh           (без аргумента — список портов из БД, по очереди)
#
# check-host.net — бесплатный внешний сервис; запросы идут с сервера, узлы проверяют
# доступность домен:порт. Ответ API: request_id + список узлов; результат опрашивается
# несколько секунд. Подробный отчёт — по permanent_link (открывается в браузере).
export TZ='Europe/Moscow'
export LC_ALL=C

PORTS="$1"
if [ -z "$PORTS" ]; then
  # порты инбаундов из БД + 443
  PORTS=$(sqlite3 "file:/etc/x-ui/x-ui.db?mode=ro&immutable=1" \
    "SELECT DISTINCT port FROM inbounds WHERE enable=1 AND deleted=0;" 2>/dev/null | sort -un | tr '\n' ' ')
  PORTS="$PORTS 443"
fi

for P in $PORTS; do
python3 - "$P" <<'PYEOF'
import json, sqlite3, subprocess, sys, time, urllib.parse, urllib.request

port = sys.argv[1]
def sh(c):
    try: return subprocess.run(c, shell=True, capture_output=True, text=True).stdout.strip()
    except Exception: return ""
try:
    conn = sqlite3.connect("file:/etc/x-ui/x-ui.db?mode=ro&immutable=1", uri=True)
    row = conn.execute("SELECT value FROM settings WHERE key='webDomain'").fetchone()
    dom = (row[0] or "").strip() if row else ""
    conn.close()
except Exception:
    dom = ""
if not dom:
    dom = sh("hostname -f") or sh("hostname")
target = "%s:%s" % (dom, port)

def api(url, data=None):
    req = urllib.request.Request(url, data=data, headers={"Accept": "application/json", "User-Agent": "diag-ext-check"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode("utf-8", "replace"))

def verdict(arr):
    """Из списка результатов узла: ('ok'|'bad'|'pending', подробности)."""
    if not isinstance(arr, list):
        return "pending", ""
    for n in arr:
        if n is None:
            continue
        if not isinstance(n, list) or not n:
            return "pending", ""
        v = n[0]
        if v is None:
            return "pending", ""
        if v is True or v == 1 or str(v).strip() in ("1", "Connected", "connected", "OK"):
            return "ok", ""
        s = str(v).strip()
        if s:
            return "bad", s[:45]
    return "pending", ""

print("=" * 56)
print("Внешняя проверка: %s (check-host.net)" % target)
try:
    r = api("https://check-host.net/check-tcp",
            urllib.parse.urlencode({"host": target, "max_nodes": "16"}).encode())
    rid = r.get("request_id") or r.get("check_id")
    if not rid:
        raise RuntimeError("нет request_id в ответе: %s" % str(r)[:120])
    link = r.get("permanent_link", "")
    nodes = r.get("nodes", {})

    res = None
    for _ in range(30):
        time.sleep(4)
        try:
            res = api("https://check-host.net/check-results/%s?json=1" % rid)
        except Exception:
            continue
        if isinstance(res, dict) and res and all(v is not None for v in res.values()):
            break

    lines = []
    okc = badc = 0
    for nid, arr in (res or {}).items():
        meta = nodes.get(nid) or ["?", "?", "?"]
        cc, country, city = (meta + ["?", "?", "?"])[:3]
        st, detail = verdict(arr)
        if st == "ok":
            okc += 1
            mark = "✅ доступен"
        elif st == "bad":
            badc += 1
            mark = "❌ %s" % (detail or "нет доступа")
        else:
            mark = "… нет ответа"
        lines.append("%-3s %-14s %-22s %s" % (cc.upper()[:3], country[:14], city[:22], mark))
    print("Проверено узлов: %d · ✅ доступно: %d · ❌ недоступно: %d" % (okc + badc, okc, badc))
    for l in sorted(lines):
        print(l)
    if link:
        print("\nПодробно: %s" % link)
except Exception as e:
    print("❌ Проверка не удалась: %r" % e)
PYEOF
echo ""
done
