#!/bin/bash
# Генератор HTML-отчётов (версия 2.6, 25.09.2026).
# Публикация БЕЗ правки nginx: отчёты кладутся в каталог заглушки (webroot),
# который nginx УЖЕ отдаёт как статику. Адрес: https://<webDomain>/<секрет>/latest-<тип>.html
#
# Использование:  bash /root/scripts/report.sh {status|wal|etalon|fail2ban|logs} [часы]
#
# Каждый отчёт состоит из двух ярусов:
#   «═══ КРАТКО ═══»   — несколько строк человеческим языком (для владельца и Telegram);
#   «═══ ПОДРОБНО ═══» — полные данные (для диагностики).
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
  local PANEL DBOK REB CPU_IDLE CPU MEM_LINE DISK_LINE UP XVER CRIT DBE
  if systemctl is-active --quiet x-ui; then PANEL="✅ работает"; else PANEL="❌ НЕ работает"; fi
  DBOK=$(sqlite3 "file:$DB?mode=ro&immutable=1" "PRAGMA integrity_check;" 2>&1 | head -1)
  if [ "$DBOK" = "ok" ]; then DBOK="✅ цела"; else DBOK="❌ ПОВРЕЖДЕНА ($DBOK)"; fi
  if [ -f /var/run/reboot-required ]; then REB="⚠️ нужна"; else REB="✅ не требуется"; fi
  CPU_IDLE=$(mpstat 1 1 2>/dev/null | awk '/Average:/ {print $NF}' | cut -d. -f1)
  [ -z "$CPU_IDLE" ] && CPU_IDLE=$(top -bn1 | grep '%Cpu' | awk '{print $8}' | cut -d. -f1)
  [ -z "$CPU_IDLE" ] && CPU_IDLE=0
  CPU=$((100 - CPU_IDLE))
  MEM_LINE=$(free -m | awk '/Mem:/ {printf "%d%% (занято %d MB из %d MB, свободно %d MB)", $3*100/$2, $3, $2, $7}')
  DISK_LINE=$(df -h / | awk 'NR==2 {print $5" (занято "$3" из "$2", свободно "$4")"}')
  UP=$(uptime -p | sed 's/up //')
  XVER=$(/usr/local/x-ui/bin/xray-linux-amd64 version 2>/dev/null | head -1)
  CRIT=$(journalctl -u x-ui --since "1440 minutes ago" -p err --no-pager 2>/dev/null | grep -vE "^-- |^$|No entries" | wc -l)
  DBE=$(journalctl -u x-ui --since "1440 minutes ago" --no-pager 2>/dev/null | grep -icE "malformed|disk I/O")

  echo "═══ КРАТКО ═══"
  echo "Панель: $PANEL · База данных: $DBOK"
  echo "Перезагрузка системы: $REB"
  echo "Сервер работает: $UP"
  echo "CPU: ${CPU}% · RAM: $MEM_LINE"
  echo "Диск /: $DISK_LINE"
  if [ "$CRIT" = "0" ]; then echo "Критических ошибок за последние 24 часа: ✅ нет"; else echo "Критических ошибок за последние 24 часа: ⚠️ $CRIT"; fi
  if [ "$DBE" = "0" ]; then echo "Ошибки базы данных в логах за последние 24 часа: ✅ нет"; else echo "Ошибки базы данных в логах за последние 24 часа: ❌ $DBE"; fi
  echo ""
  echo "═══ ПОДРОБНО ═══"
  echo ""
  echo "=== 1. Панель и база данных ==="
  echo "Панель x-ui: $PANEL"
  echo "База данных: $DBOK"
  sqlite3 "file:$DB?mode=ro&immutable=1" "SELECT '📊 inbounds: '||COUNT(*) FROM inbounds UNION ALL SELECT '📊 clients: '||COUNT(*) FROM clients UNION ALL SELECT '📊 client_inbounds: '||COUNT(*) FROM client_inbounds UNION ALL SELECT '📊 client_traffics: '||COUNT(*) FROM client_traffics UNION ALL SELECT '📊 nodes: '||COUNT(*) FROM nodes UNION ALL SELECT '📊 limit_ip>0: '||COUNT(*) FROM clients WHERE limit_ip>0;" 2>/dev/null
  echo ""
  echo "=== 2. СТАТУС ОШИБОК ==="
  if [ "$CRIT" = "0" ]; then echo "✅ Критических ошибок за последние 24 часа нет"; else echo "⚠️ Критических ошибок за последние 24 часа: $CRIT"; fi
  if [ "$DBE" = "0" ]; then
    echo "✅ Ошибки базы данных в логах за последние 24 часа: нет"
  else
    echo "❌ Ошибки базы данных в логах за последние 24 часа: $DBE (malformed / disk I/O)"
    journalctl -u x-ui --since "1440 minutes ago" --no-pager 2>/dev/null | grep -iE "malformed|disk I/O" | tail -5
  fi
  echo ""
  echo "=== 3. Ресурсы ==="
  echo "CPU: ${CPU}%"
  echo "RAM: $MEM_LINE"
  echo "Диск /: $DISK_LINE"
  echo "Аптайм: $UP"
  echo ""
  echo "=== 4. Версии, сервисы, порты ==="
  echo "$XVER"
  echo "Сервисы: x-ui=$(systemctl is-active x-ui 2>/dev/null) nginx=$(systemctl is-active nginx 2>/dev/null) fail2ban=$(systemctl is-active fail2ban 2>/dev/null)"
  ss -tulnp 2>/dev/null | grep -E 'nginx|x-ui|xray' | awk '{print $1, $2, $5, $7}' | sort -u
}

gen_wal() {
  local WW="" CRON LINES ANOM
  for p in "$DIR/wal-watch.sh" /root/wal-watch.sh; do [ -f "$p" ] && WW="$p" && break; done
  CRON=$(crontab -l 2>/dev/null | grep wal-watch | head -1)
  if [ -f "$LOG" ]; then
    LINES=$(wc -l < "$LOG")
    ANOM=$(grep -cE "DELETED|err5m=[1-9]|wal=-" "$LOG")
  fi

  echo "═══ КРАТКО ═══"
  if [ -n "$CRON" ]; then echo "Сторож: ✅ включён (замер каждые 5 минут)"; else echo "Сторож: ⚠️ ВЫКЛЮЧЕН"; fi
  echo "Замеров в логе: ${LINES:-0} · Аномалии: ${ANOM:-0}"
  [ -f "$LOG" ] && echo "Последний замер: $(tail -1 "$LOG")"
  if [ "${ANOM:-0}" = "0" ]; then echo "Вердикт: ✅ база под наблюдением, тревог нет"; else echo "Вердикт: ❌ ЕСТЬ АНОМАЛИИ — смотри лог ниже"; fi
  echo ""
  echo "═══ ПОДРОБНО ═══"
  if [ -n "$WW" ]; then echo "Скрипт: $WW"; sha256sum "$WW"; else echo "Скрипт: НЕ НАЙДЕН"; fi
  if [ -n "$CRON" ]; then echo "Cron: $CRON"; else echo "Cron: не установлен"; fi
  if [ -f "$LOG" ]; then
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
    echo "═══ КРАТКО ═══"
    echo "⚠️ Эталон ещё не сохранён (menu → Диагностика → Эталон сервера → пункт 2). Ниже — текущий снапшот."
    echo ""
    echo "═══ ПОДРОБНО ═══"
    bash "$DIR/baseline.sh" now
    return
  fi
  local OUT N
  OUT=$(bash "$DIR/baseline.sh" compare 2>&1)
  N=$(echo "$OUT" | grep -cE '^[<>]')
  echo "═══ КРАТКО ═══"
  if [ "$N" = "0" ]; then
    echo "✅ Отличий от эталона нет"
  else
    echo "⚠️ Отличий от эталона: $N строк (в списке ниже: «<» — эталон, «>» — текущее состояние)"
  fi
  echo "Эталон сохранён: $(head -1 "$DIR/etalon/etalon.txt" | sed 's/^# Снимок: //')"
  echo ""
  echo "═══ ПОДРОБНО ═══"
  echo "$OUT"
}

gen_fail2ban() {
  echo "═══ КРАТКО ═══"
  if ! command -v fail2ban-client >/dev/null 2>&1; then
    echo "fail2ban не установлен"
  else
    local JAILS
    JAILS=$(fail2ban-client status 2>/dev/null | grep 'Jail list' | sed 's/.*://; s/,/ /g')
    for j in $JAILS; do
      local CB TB
      CB=$(fail2ban-client status "$j" 2>/dev/null | awk -F: '/Currently banned/{gsub(/[ \t]/,"",$2); print $2}')
      TB=$(fail2ban-client status "$j" 2>/dev/null | awk -F: '/Total banned/{gsub(/[ \t]/,"",$2); print $2}')
      echo "jail «$j»: сейчас забанено ${CB:-0} (всего за историю ${TB:-0})"
    done
    echo "(фоновый перебор SSH — обычное явление; баны sshd-jail — это работа защиты, не атака на вас лично)"
  fi
  echo ""
  echo "═══ ПОДРОБНО ═══"
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
    echo ""
    echo "(примечание: «сейчас забанено» в блоке fail2ban.sh считается по записям лога за окно и может отличаться от реального бан-листа выше — известная неточность, правка в бэклоге)"
  fi
}

gen_logs() {
  local hrs="${1:-24}"
  j() { journalctl -u x-ui --since "$hrs hours ago" --no-pager 2>/dev/null; }
  local NERR NWRN NINF
  NERR=$(j | grep -c "ERROR")
  NWRN=$(j | grep -c "WARNING")
  NINF=$(j | grep -c "INFO")

  echo "═══ КРАТКО ═══"
  echo "Период: последние $hrs ч"
  echo "Записей по уровням: ERROR — $NERR · WARNING — $NWRN · INFO — $NINF"
  if [ "$NERR" = "0" ]; then echo "✅ Ошибок уровня ERROR нет"; else echo "❌ Есть ERROR — полный список в разделе ниже"; fi
  echo "Массовые WARNING про X-Forwarded-For и OCSP — штатные для схемы x-ui-pro, действий не требуют."
  echo ""
  echo "═══ ПОДРОБНО ═══"
  echo ""
  echo "========== СВОДКА: самые частые записи (дубли схлопнуты, число повторов в начале строки) =========="
  j | grep -E "WARNING|ERROR" \
    | sed -E 's/^[A-Za-z]{3} +[0-9]+ [0-9:]{8} [^ ]+ [^:]+: //; s/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+/IP:PORT/g; s/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/IP/g' \
    | sort | uniq -c | sort -rn | head -20
  echo ""
  echo "========== ОШИБКИ (уровень ERROR) — все за период, до 100 =========="
  j | grep "ERROR" | tail -100
  echo ""
  echo "========== ПРЕДУПРЕЖДЕНИЯ (WARNING) — последние 20 сырых =========="
  j | grep "WARNING" | tail -20
  echo ""
  echo "========== ИНФО (INFO) — последние 50 =========="
  j | grep "INFO" | tail -50
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
