#!/bin/bash
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
echo "=========================================="
echo "  ОТЧЕТ О СОСТОЯНИИ СЕРВЕРА"
echo "=========================================="
echo ""
echo "1. Статус панели 3X-UI:"
if systemctl is-active --quiet x-ui; then
    echo "   ✅ Панель работает корректно"
else
    echo "   ❌ Панель НЕ работает!"
fi
DB=/etc/x-ui/x-ui.db
if [ -f "$DB" ]; then
    DB_OK=$(sqlite3 "file:$DB?mode=ro&immutable=1" "PRAGMA integrity_check;" 2>&1 | head -1)
    if [ "$DB_OK" = "ok" ]; then
        echo "   ✅ База данных: integrity_check ok"
    else
        echo -e "   ${RED}❌ БАЗА ДАННЫХ ПОВРЕЖДЕНА: $DB_OK${NC}"
    fi
    sqlite3 "file:$DB?mode=ro&immutable=1" "SELECT '   📊 inbounds: '||COUNT(*) FROM inbounds UNION ALL SELECT '   📊 clients: '||COUNT(*) FROM clients UNION ALL SELECT '   📊 client_inbounds: '||COUNT(*) FROM client_inbounds UNION ALL SELECT '   📊 nodes: '||COUNT(*) FROM nodes;" 2>/dev/null
fi
echo ""
echo "2. Перезагрузка системы:"
if [ -f /var/run/reboot-required ]; then
    echo "   ⚠️ Требуется перезагрузка"
else
    echo "   ✅ Перезагрузка не требуется"
fi
echo ""
echo "3. Ресурсы сервера:"
CPU_IDLE=$(mpstat 1 1 | awk '/Average:/ {print $NF}' | cut -d. -f1)
[ -z "$CPU_IDLE" ] && CPU_IDLE=$(top -bn1 | grep '%Cpu' | awk '{print $8}' | cut -d. -f1)
CPU_PERCENT=$((100 - CPU_IDLE))
if [ "$CPU_PERCENT" -gt 80 ]; then
    echo -e "   ${RED}⚠️ Нагрузка (CPU): ${CPU_PERCENT}%${NC}"
else
    echo "   📊 Нагрузка (CPU): ${CPU_PERCENT}%"
fi
MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
MEM_PERCENT=$((MEM_USED * 100 / MEM_TOTAL))
if [ "$MEM_PERCENT" -gt 80 ]; then
    echo -e "   ${RED}⚠️ Память: Занято ${MEM_PERCENT}% | ${MEM_USED}MB / ${MEM_TOTAL}MB${NC}"
else
    echo "   📈 Память: Занято ${MEM_PERCENT}% | ${MEM_USED}MB / ${MEM_TOTAL}MB"
fi
DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
if [ "$DISK_USAGE" -lt 80 ]; then
    echo "   💾 Диск: Занято: ${DISK_USAGE}% (нормально)"
else
    echo -e "   ${RED}⚠️ Диск: Занято: ${DISK_USAGE}% (много!)${NC}"
fi
echo ""
echo "4. Время работы (Uptime):"
echo "   🕒 Сервер работает: $(uptime -p | sed 's/up //')"
echo ""
echo "=========================================="
echo "  СТАТУС ОШИБОК"
echo "=========================================="
CRIT_COUNT=$(journalctl -u x-ui --since "1440 minutes ago" -p err --no-pager 2>/dev/null | grep -vE "^-- |^$|No entries" | wc -l)
DB_ERRORS=$(journalctl -u x-ui --since "1440 minutes ago" --no-pager 2>/dev/null | grep -icE "malformed|disk I/O")
if [ "$CRIT_COUNT" = "0" ]; then
    echo "✅ Критических ошибок за последние 24 часа нет"
else
    echo -e "${RED}⚠️ Критических ошибок за последние 24 часа: $CRIT_COUNT (подробно: menu → 5 → 1)${NC}"
fi
if [ "$DB_ERRORS" = "0" ] || [ -z "$DB_ERRORS" ]; then
    echo "✅ Ошибки базы данных в логах за последние 24 часа: нет"
else
    echo -e "${RED}❌ Ошибки базы данных в логах за последние 24 часа: $DB_ERRORS (malformed / disk I/O)!${NC}"
    journalctl -u x-ui --since "1440 minutes ago" --no-pager 2>/dev/null | grep -iE "malformed|disk I/O" | tail -3
fi
echo "=========================================="
