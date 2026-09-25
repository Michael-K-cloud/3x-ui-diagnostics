#!/bin/bash
# Генератор HTML-отчётов для просмотра по ссылке (из меню и из Telegram-бота).
# Использование:  bash /root/scripts/report.sh {status|wal|etalon|fail2ban|logs} [часы]
# Файлы:          /var/www/report/<REPORT_PATH>/latest-<тип>.html (+ копия с датой)
# Ссылка:         https://<webDomain>/report/<REPORT_PATH>/latest-<тип>.html
# Секретная часть URL (REPORT_PATH) создаётся автоматически при первом запуске
# и хранится в /root/scripts/.env (права 600). Без настройки nginx location /report/
# ссылка работать не будет — см. README (раздел «HTML-отчёты»).
# Все обращения к БД — только чтение (mode=ro&immutable=1), безопасно на живой панели.
export TZ='Europe/Moscow'
DIR="/root/scripts"
ENVF="$DIR/.env"
WEBROOT="/var/www/report"
DB=/etc/x-ui/x-ui.db
LOG=/root/wal-watch.log

# --- .env: секретная часть URL ---
[ -f "$ENVF" ] && . "$ENVF" 2>/dev/null
if [ -z "$REPORT_PATH" ]; then
  REPORT_PATH=$(openssl rand -hex 6 2>/dev/null || head -c 16 /dev/urandom | md5sum | cut -c1-12)
  touch "$ENVF"; chmod 600 "$ENVF"
  echo "REPORT_PATH=$REPORT_PATH" >> "$ENVF"
fi
OUT="$WEBROOT/$REPORT_PATH"
mkdir -p "$OUT"

DOMAIN=$(sqlite3 "file:$DB?mode=ro&immutable=1" "SELECT value FROM settings WHERE key='webDomain';" 2>/dev/null)
[ -z "$DOMAIN" ] && DOMAIN=$(hostname -f 2>/dev/null || hostname)

html_wrap() { # $1=заголовок; содержимое — из stdin
  local title="$1"
  echo "<!DOCTYPE html><html lang=\"ru\"><head><meta charset=\"utf-8\">"
  echo "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
  echo "<title>$title — $DOMAIN</title>"
  echo "<style>body{background:#111;color:#eee;font-family:Menlo,Consolas,monospace;margin:0;padding:16px;font-size:13px}h2{color:#7ec8ff;margin:0 0 12px}pre{white-space:pre-wrap;word-break:break-word;background:#1a1a1a;padding:12px;border-radius:8px;margin:0}footer{color:#888;margin-top:16px;font-size:12px}</style>"
  echo "</head><body>"
  echo "<h2>$title</h2>"
  echo "<pre>"
  sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
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
  echo "========== ОШИБКИ (ERROR), последние 200 =========="
  journalctl -u x-ui --since "$hrs hours ago" --no-pager 2>/dev/null | grep -E "ERROR|error" | tail -200
  echo ""
  echo "========== ПРЕДУПРЕЖДЕНИЯ (WARNING), последние 200 =========="
  journalctl -u x-ui --since "$hrs hours ago" --no-pager 2>/dev/null | grep "WARNING" | tail -200
  echo ""
  echo "========== ИНФО (INFO), последние 100 =========="
  journalctl -u x-ui --since "$hrs hours ago" --no-pager 2>/dev/null | grep "INFO" | tail -100
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

STAMP=$(date -u +%F_%H-%M%S)
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

URL="https://$DOMAIN/report/$REPORT_PATH/latest-$BASE.html"
echo "✅ Отчёт сформирован: $TITLE"
echo "Файл:  $FILE"
echo "Ссылка: $URL"
echo ""
echo "Если ссылка не открывается — на этом сервере ещё не настроен nginx location /report/ (см. README, раздел «HTML-отчёты»)."
