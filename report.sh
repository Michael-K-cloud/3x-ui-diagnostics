#!/bin/bash
# Генератор HTML-отчётов (версия 2.4, 25.09.2026).
# Публикация БЕЗ правки nginx: отчёты кладутся в каталог заглушки (webroot),
# который nginx УЖЕ отдаёт как статику. Адрес: https://<webDomain>/<секрет>/latest-<тип>.html
#
# Использование:  bash /root/scripts/report.sh {status|wal|etalon|fail2ban|logs} [часы]
#
# Каталог webroot определяется автоматически из vhost-конфига nginx основного домена
# (директива root). Переопределение: REPORT_WEBROOT=... в /root/scripts/.env
# Секретная часть URL (REPORT_PATH) создаётся при первом запуске, хранится в .env (600).
# Все обращения к БД — только чтение (mode=ro&immutable=1), безопасно на живой панели.
export TZ='Europe/Moscow'
DIR="/root/scripts"
ENVF="$DIR/.env"
DB=/etc/x-ui/x-ui.db
LOG=/root/wal-watch.log

# --- .env: секретная часть URL и (опционально) webroot ---
[ -f "$ENVF" ] && . "$ENVF" 2>/dev/null
if [ -z "$REPORT_PATH" ]; then
  REPORT_PATH=$(openssl rand -hex 6 2>/dev/null || head -c 16 /dev/urandom | md5sum | cut -c1-12)
  touch "$ENVF"; chmod 600 "$ENVF"
  echo "REPORT_PATH=$REPORT_PATH" >> "$ENVF"
fi

DOMAIN=$(sqlite3 "file:$DB?mode=ro&immutable=1" "SELECT value FROM settings WHERE key='webDomain';" 2>/dev/null)
[ -z "$DOMAIN" ] && DOMAIN=$(hostname -f 2>/dev/null || hostname)

# --- Определение webroot (каталог заглушки) ---
detect_webroot() {
  local vh=""
  vh=$(grep -lE "server_name[^;]*${DOMAIN}" /etc/nginx/sites-available/* /etc/nginx/conf.d/*.conf 2>/dev/null | head -1)
  [ -z "$vh" ] && vh=$(grep -lE "server_name[^;]*${DOMAIN}" /etc/nginx/sites-enabled/* 2>/dev/null | head -1)
  if [ -n "$vh" ]; then
    awk '/^[[:space:]]*root[[:space:]]/{gsub(/;/,""); print $2; exit}' "$vh"
  fi
}

WEB="$REPORT_WEBROOT"
[ -z "$WEB" ] && WEB=$(detect_webroot)
[ -z "$WEB" ] && [ -d /var/www/html ] && WEB=/var/www/html
WEB="${WEB%/}"

if [ -n "$WEB" ] && [ -d "$WEB" ]; then
  OUT="$WEB/$REPORT_PATH"
  SERVED=1
else
  # запасной вариант: webroot не найден — пишем в /var/www/report (ссылка открываться НЕ будет)
  OUT="/var/www/report/$REPORT_PATH"
  SERVED=0
fi
mkdir -p "$OUT"

html_wrap() { # $1=заголовок; содержимое — из stdin
  local title="$1"
  echo "<!DOCTYPE html><html lang=\"ru\"><head><meta charset=\"utf-8\">"
  echo "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
  echo "<title>$title — $DOMAIN</title>"
  echo "<style>body{background:#111;color:#eee;font-family:Menlo,Consolas,monospace;margin:0;padding:16px;font-size:13px}h2{color:#7ec8ff;margin:0 0 12px}pre{white-space:pre-wrap;word-break:break-word;background:#1a1a1a;padding:12px;border-radius:8px;margin:0}footer{color:#888;margin-top:16px;font-size:12px}</style>"
  echo "</head><body>"
  echo "<h2>$title</h2>"
  echo "<pre>"
  # сначала снимаем терминальные цвета (ANSI) и \r, потом экранируем HTML
  sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/\x1b([A-Z0-9])//g' -e 's/\r//g' -e 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
  echo "</pre>"
  echo "<footer>Сервер: $DOMAIN · Сформировано: $(date '+%F %T %Z')</footer>"
  echo "</body></html>"
}

gen_status() {
  echo "=== 1. Панель и база данных ==="
  if systemctl is-active --quiet x-ui; then echo "✅ Панель x-ui: работает"; else echo "❌ Панель x-ui: НЕ работает!"; fi
  DB_OK=$(sqlite3 "file:$DB?mode=ro&immutable=1" "PRAGMA integrity_check;" 2>&1 | head -1)
  if [ "$DB_OK" = "ok" ]; then echo "✅ База данных: integrity_check ok"; else echo "❌ БАЗА ДАННЫХ ПОВРЕЖДЕНА: $DB_OK"; fi
  sqlite3 "file:$DB?mode=ro&immutable=1" "SELECT '📊 inbounds: '||COUNT(*) FROM inbounds UNION ALL SELECT '📊 clients: '||COUNT(*) FROM clients UNION ALL SELECT '📊 client_inbounds: '||COUNT(*) FROM client_inbounds UNION ALL SELECT '📊 client_traffics: '||COUNT(*) FROM client_traffics UNION ALL SELECT '📊 nodes: '||COUNT(*) FROM nodes UNION ALL SELECT '📊 limit_ip>0: '||COUNT(*) FROM clients WHERE limit_ip>0;" 2>/dev/null
  echo ""
  echo "=== 2. Перезагрузка системы ==="
  if [ -f /var/run/reboot-required ]; then echo "⚠️ Требуется перезагрузка"; else echo "✅ Перезагрузка не требуется"; fi
  echo ""
  echo "=== 3. Ресурсы ==="
  CPU_IDLE=$(mpstat 1 1 2>/dev/null | awk '/Average:/ {print $NF}' | cut -d. -f1)
  [ -z "$CPU_IDLE" ] && CPU_IDLE=$(top -bn1 | grep '%Cpu' | awk '{print $8}' | cut -d. -f1)
  [ -z "$CPU_IDLE" ] && CPU_IDLE=0
  echo "CPU: $((100 - CPU_IDLE))%"
  free -m | awk '/Mem:/ {printf "RAM: занято %d%% (%d MB из %d MB), свободно %d MB\n", $3*100/$2, $3, $2, $7}'
  df -h / | awk 'NR==2 {print "Диск /: занято "$3" из "$2" ("$5"), свободно "$4}'
  echo "Аптайм: $(uptime -p | sed 's/up //')"
  echo ""
  echo "=== 4. Ошибки за 24 часа ==="
  CRIT=$(journalctl -u x-ui --since "1440 minutes ago" -p err --no-pager 2>/dev/null | grep -vE "^-- |^$|No entries" | wc -l)
  echo "Критических (приоритет err и выше): $CRIT"
  DBE=$(journalctl -u x-ui --since "1440 minutes ago" --no-pager 2>/dev/null | grep -icE "malformed|disk I/O")
  echo "Ошибок БД (malformed / disk I/O, включая WARNING): $DBE"
  if [ "$DBE" -gt 0 ] 2>/dev/null; then
    echo "--- Последние 5 записей БД-ошибок: ---"
    journalctl -u x-ui --since "1440 minutes ago" --no-pager 2>/dev/null | grep -iE "malformed|disk I/O" | tail -5
  fi
  echo ""
  echo "=== 5. Версии, сервисы, порты ==="
  /usr/local/x-ui/bin/xray-linux-amd64 version 2>/dev/null | head -1
  echo "Сервисы: x-ui=$(systemctl is-active x-ui 2>/dev/null) nginx=$(systemctl is-active nginx 2>/dev/null) fail2ban=$(systemctl is-active fail2ban 2>/dev/null)"
  ss -tulnp 2>/dev/null | grep -E 'nginx|x-ui|xray' | awk '{print $1, $2, $5, $7}' | sort -u
}

gen_wal() {
  echo "=== WAL-сторож: статус ==="
  WW=""
  for p in "$DIR/wal-watch.sh" /root/wal-watch.sh; do [ -f "$p" ] && WW="$p" && break; done
  if [ -n "$WW" ]; then echo "Скрипт: $WW"; sha256sum "$WW"; else echo "Скрипт: НЕ НАЙДЕН"; fi
  CRON=$(crontab -l 2>/dev/null | grep wal-watch | head -1)
  if [ -n "$CRON" ]; then echo "Cron: включён ($CRON)"; else echo "Cron: ВЫКЛЮЧЕН"; fi
  if [ -f "$LOG" ]; then
    echo "Всего замеров: $(wc -l < "$LOG")"
    echo "Аномалии (DELETED / err5m>0 / wal=-): $(grep -cE 'DELETED|err5m=[1-9]|wal=-' "$LOG")"
    echo "Первый замер: $(head -1 "$LOG")"
    echo ""
    echo "=== Последние 30 замеров ==="
    tail -30 "$LOG"
  else
    echo "Лог ещё не создан"
  fi
}

gen_etalon() {
  if [ ! -f "$DIR/etalon/etalon.txt" ]; then
    echo "Эталон ещё не сохранён. Сохраните: menu → Диагностика → Эталон сервера → пункт 2."
    echo ""
    echo "=== Текущий снапшот ==="
    bash "$DIR/baseline.sh" now
    return
  fi
  echo "Эталон: $(head -1 "$DIR/etalon/etalon.txt")"
  echo ""
  bash "$DIR/baseline.sh" compare
}

gen_fail2ban() {
  echo "=== fail2ban: jails ==="
  fail2ban-client status 2>/dev/null || { echo "fail2ban не запущен"; return; }
  for j in $(fail2ban-client status 2>/dev/null | grep 'Jail list' | sed 's/.*://; s/,/ /g'); do
    echo ""
    echo "=== Jail: $j ==="
    fail2ban-client status "$j" 2>/dev/null
  done
  if [ -f "$DIR/fail2ban.sh" ]; then
    echo ""
    echo "=== Подробный отчёт (fail2ban.sh, ID клиентов) ==="
    timeout 15 bash "$DIR/fail2ban.sh" </dev/null 2>&1
  fi
}

gen_logs() {
  local hrs="${1:-24}"
  echo "Период: последние $hrs ч (x-ui)"
  echo ""
  echo "========== СВОДКА: самые частые записи (дубли схлопнуты) =========="
  journalctl -u x-ui --since "$hrs hours ago" --no-pager 2>/dev/null \
    | grep -E "WARNING|ERROR|error" \
    | sed -E 's/^[A-Za-z]{3} +[0-9]+ [0-9:]{8} [^ ]+ [^:]+: //; s/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+/IP:PORT/g; s/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/IP/g' \
    | sort | uniq -c | sort -rn | head -20
  echo ""
  echo "========== ОШИБКИ (ERROR) — все за период, до 100 =========="
  journalctl -u x-ui --since "$hrs hours ago" --no-pager 2>/dev/null | grep -E "ERROR|error" | tail -100
  echo ""
  echo "========== ПРЕДУПРЕЖДЕНИЯ (WARNING) — последние 20 сырых =========="
  journalctl -u x-ui --since "$hrs hours ago" --no-pager 2>/dev/null | grep "WARNING" | tail -20
  echo ""
  echo "========== ИНФО (INFO) — последние 50 =========="
  journalctl -u x-ui --since "$hrs hours ago" --no-pager 2>/dev/null | grep "INFO" | tail -50
  echo ""
  echo "Примечание: массовые повторяющиеся WARNING про X-Forwarded-For (nginx передаёт запросы в xray) и про OCSP (в сертификате не указан OCSP-сервер) — штатные для схемы x-ui-pro, действий не требуют."
}

TYPE="$1"; HOURS="$2"
case "$TYPE" in
  status|wal|etalon|fail2ban|logs) ;;
  *) echo "Использование: report.sh {status|wal|etalon|fail2ban|logs} [часы]"; exit 1;;
esac

case "$TYPE" in
  status)   TITLE="Отчёт о состоянии сервера"; BASE="status";;
  wal)      TITLE="Отчёт по WAL-сторожу";       BASE="wal";;
  etalon)   TITLE="Сравнение с эталоном";       BASE="etalon";;
  fail2ban) TITLE="Отчёт по fail2ban";          BASE="fail2ban";;
  logs)
    [[ "$HOURS" =~ ^[0-9]+$ ]] || HOURS=24
    [ "$HOURS" -eq 0 ] && HOURS=24
    TITLE="Отсортированные логи x-ui за ${HOURS} ч"; BASE="logs-${HOURS}h";;
esac

STAMP=$(date -u +%F_%H%M%S)
BODY=$(mktemp)
case "$TYPE" in
  status)   gen_status > "$BODY";;
  wal)      gen_wal > "$BODY";;
  etalon)   gen_etalon > "$BODY";;
  fail2ban) gen_fail2ban > "$BODY";;
  logs)     gen_logs "$HOURS" > "$BODY";;
esac

FILE="$OUT/$STAMP-$BASE.html"
LATEST="$OUT/latest-$BASE.html"
html_wrap "$TITLE" < "$BODY" > "$FILE"
cp -f "$FILE" "$LATEST"
rm -f "$BODY"

# Хранить не более 30 копий каждого типа
ls -1t "$OUT"/*-"$BASE".html 2>/dev/null | grep -v latest | tail -n +31 | xargs -r rm -f

echo "✅ Отчёт сформирован: $TITLE"
echo "Каталог: $OUT (webroot заглушки: ${WEB:-не определён})"
echo "Файл:    $FILE"
if [ "$SERVED" = "1" ]; then
  echo "Ссылка:  https://$DOMAIN/$REPORT_PATH/latest-$BASE.html?v=$(date +%s)"
else
  echo "⚠️ Webroot заглушки не найден — файл сохранён в $OUT, но по ссылке НЕ откроется."
  echo "   Укажите каталог вручную: добавьте строку REPORT_WEBROOT=/путь/в/webroot в $ENVF"
fi
