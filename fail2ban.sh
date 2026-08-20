cat << 'F2B_EOF' > /root/scripts/fail2ban.sh
#!/bin/bash
export TZ='Europe/Moscow'
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; WHITE='\033[0;37m'; BRIGHT_WHITE='\033[1;37m'; NC='\033[0m'

DB="/var/lib/fail2ban/fail2ban.sqlite3"

echo "=========================================="
echo "  ОТЧЁТ ПО FAIL2BAN (время московское)"
echo "=========================================="
echo ""

echo -e "${CYAN}=== Текущие активные блокировки ===${NC}"
echo ""

COUNT_3X=$(sqlite3 "$DB" "SELECT COUNT(*) FROM bips WHERE jail='3x-ipl';" 2>/dev/null || echo "0")
TOTAL_3X=$(sqlite3 "$DB" "SELECT COUNT(*) FROM bans WHERE jail='3x-ipl';" 2>/dev/null || echo "0")
echo -e "  Jail ${WHITE}3x-ipl${NC}: сейчас забанено ${WHITE}$COUNT_3X${NC} (всего за всё время: $TOTAL_3X)"
if [ "$COUNT_3X" -gt 0 ]; then
    echo -e "  ${YELLOW}Это ваши реальные VPN-клиенты, которые превысили лимит одновременных подключений (функция LIMIT_IP в 3X-UI).${NC}"
    sqlite3 "$DB" "SELECT ip, timeofban, json_extract(data, '\$.user') FROM bips WHERE jail='3x-ipl';" | while IFS='|' read -r ip ts user; do
        ban_date=$(date -d "@$ts" "+%Y-%m-%d %H:%M:%S")
        echo -e "    ${WHITE}- $ip${NC} | клиент: ${WHITE}$user${NC} | забанен: ${WHITE}$ban_date${NC}"
    done
fi
echo ""

COUNT_SSH=$(sqlite3 "$DB" "SELECT COUNT(*) FROM bips WHERE jail='sshd';" 2>/dev/null || echo "0")
TOTAL_SSH=$(sqlite3 "$DB" "SELECT COUNT(*) FROM bans WHERE jail='sshd';" 2>/dev/null || echo "0")
echo -e "  Jail ${WHITE}sshd${NC}: сейчас забанено ${WHITE}$COUNT_SSH${NC} (всего за всё время: $TOTAL_SSH)"
if [ "$COUNT_SSH" -gt 0 ]; then
    echo -e "  ${YELLOW}Это серьёзная атака перебора паролей. Сейчас заблокировано $COUNT_SSH IP одновременно.${NC}"
    echo -e "  ${YELLOW}Это типичные ботнеты, сканирующие интернет в поисках открытых SSH.${NC}"
    sqlite3 "$DB" "SELECT ip, timeofban FROM bips WHERE jail='sshd';" | while IFS='|' read -r ip ts; do
        ban_date=$(date -d "@$ts" "+%Y-%m-%d %H:%M:%S")
        echo -e "    ${WHITE}- $ip${NC} | забанен: ${WHITE}$ban_date${NC}"
    done
fi
echo ""

OLDEST_TS=$(sqlite3 "$DB" "SELECT MIN(timeofban) FROM bans;" 2>/dev/null)
NOW=$(date +%s)
BANS_ALL=$(sqlite3 "$DB" "SELECT COUNT(*) FROM bans;" 2>/dev/null || echo "0")

if [ -n "$OLDEST_TS" ] && [ "$OLDEST_TS" != "0" ]; then
    HOURS_AVAILABLE=$(( (NOW - OLDEST_TS) / 3600 ))
    echo -e "${CYAN}=== Статистика блокировок ===${NC}"
    echo -e "  За последние $HOURS_AVAILABLE часа: ${BRIGHT_WHITE}$BANS_ALL${NC}"
    echo ""
    OLDEST_DATE=$(date -d "@$OLDEST_TS" "+%Y-%m-%d %H:%M:%S")
    echo -e "${WHITE}Статистика доступна с: ${BRIGHT_WHITE}$OLDEST_DATE${NC}"
else
    echo -e "${YELLOW}База пуста или недоступна${NC}"
fi
F2B_EOF