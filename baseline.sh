#!/bin/bash
# Эталон сервера — снапшот ключевых параметров для сверки после изменений.
# Вызывается из menu (пункт «Эталон сервера») или напрямую:
#   bash /root/scripts/baseline.sh {show|save|now|compare}
# Файл эталона: /root/scripts/etalon/etalon.txt
# Все обращения к базе — только для чтения (mode=ro&immutable=1), безопасно на живой панели.
export TZ='Europe/Moscow'
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
DIR="/root/scripts/etalon"
DB=/etc/x-ui/x-ui.db
mkdir -p "$DIR"

snapshot() {
  echo "# Снимок: $(hostname) — $(date -u '+%F %T') UTC"
  echo "## Версия Xray"
  /usr/local/x-ui/bin/xray-linux-amd64 version 2>/dev/null | head -1 || echo "нет данных"
  echo "## БД: целостность"
  sqlite3 "file:$DB?mode=ro&immutable=1" "PRAGMA integrity_check;" 2>&1 | head -1
  echo "## БД: счётчики"
  sqlite3 "file:$DB?mode=ro&immutable=1" "SELECT 'inbounds='||COUNT(*) FROM inbounds UNION ALL SELECT 'clients='||COUNT(*) FROM clients UNION ALL SELECT 'client_inbounds='||COUNT(*) FROM client_inbounds UNION ALL SELECT 'client_traffics='||COUNT(*) FROM client_traffics UNION ALL SELECT 'users='||COUNT(*) FROM users UNION ALL SELECT 'nodes='||COUNT(*) FROM nodes UNION ALL SELECT 'inbound_client_ips='||COUNT(*) FROM inbound_client_ips UNION ALL SELECT 'limit_ip_gt0='||COUNT(*) FROM clients WHERE limit_ip>0;" 2>&1
  echo "## Настройки панели (без секретов)"
  sqlite3 "file:$DB?mode=ro&immutable=1" "SELECT key||'='||value FROM settings WHERE key IN ('webPort','webBasePath','webDomain','webCertFile','webKeyFile','forceTls','subEnable','subPort','subPath','subDomain');" 2>&1
  echo "## sha256 конфигов nginx"
  find /etc/nginx -type f \( -name '*.conf' -o -path '*sites-available/*' -o -path '*stream-enabled/*' -o -path '*snippets/*' \) 2>/dev/null | sort | xargs -r sha256sum 2>/dev/null
  echo "## Слушающие порты (x-ui/nginx/xray, без PID)"
  ss -tulnp 2>/dev/null | grep -E 'nginx|x-ui|xray' | awk '{print $1, $2, $5}' | sort -u
  echo "## fail2ban jail"
  fail2ban-client status 2>/dev/null | grep 'Jail list' || echo "fail2ban не запущен"
  echo "## WAL-сторож"
  crontab -l 2>/dev/null | grep wal-watch || echo "сторож не в cron"
}

case "$1" in
  show)
    if [ -f "$DIR/etalon.txt" ]; then cat "$DIR/etalon.txt"; else echo -e "${YELLOW}Эталон ещё не сохранён ($DIR/etalon.txt). Сохраните пунктом 2 меню.${NC}"; fi;;
  save)
    snapshot > "$DIR/etalon.txt"
    echo -e "${GREEN}✅ Эталон сохранён: $DIR/etalon.txt${NC}"
    head -1 "$DIR/etalon.txt";;
  now)
    snapshot;;
  compare)
    if [ ! -f "$DIR/etalon.txt" ]; then echo -e "${RED}❌ Эталона нет — сначала сохраните его (пункт 2)${NC}"; exit 1; fi
    snapshot > /tmp/etalon-now.txt
    if diff <(grep -v '^# Снимок:' "$DIR/etalon.txt") <(grep -v '^# Снимок:' /tmp/etalon-now.txt); then
      echo -e "${GREEN}✅ Отличий от эталона нет${NC}"
    else
      echo -e "${YELLOW}⚠️ Найдены отличия: '<' — эталон, '>' — текущее состояние${NC}"
      echo -e "${YELLOW}   (счётчики inbound_client_ips/client_traffics могут расти штатно)${NC}"
    fi
    rm -f /tmp/etalon-now.txt;;
  *)
    echo "Использование: baseline.sh {show|save|now|compare}";;
esac
