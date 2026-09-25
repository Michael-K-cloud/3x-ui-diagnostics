#!/bin/bash
clear
export TZ='Europe/Moscow'
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; WHITE='\033[0;37m'; BRIGHT_WHITE='\033[1;37m'; PINK='\033[95m'; NC='\033[0m'
DIR="/root/scripts"
echo -e "${PINK}==========================================${NC}"
echo -e "${PINK}  РАБОТА С ЛОГАМИ X-UI${NC}"
echo -e "${PINK}==========================================${NC}"
echo ""
echo -e "${WHITE}INFO: Размер всех логов${NC}"
DISK_USAGE=$(journalctl --disk-usage)
SIZE=$(echo "$DISK_USAGE" | grep -oE '[0-9.]+[KMGT]')
BEFORE="${DISK_USAGE%%$SIZE*}"
AFTER="${DISK_USAGE#*$SIZE}"
echo -e "${WHITE}${BEFORE}${BRIGHT_WHITE}${SIZE}${WHITE}${AFTER}${NC}"
echo ""
echo -e "  ${GREEN}1.${NC} 📋 Просмотр отсортированных логов (ERROR, WARNING, INFO за период)"
echo -e "  ${GREEN}2.${NC} 🧹 Очистка логов (удалить старые записи journald)"
echo -e "  ${GREEN}3.${NC} 🛡  Отчёт по fail2ban (заблокированные IP и статистика блокировок)"
echo -e "  ${GREEN}0.${NC} ← Назад (или Enter)"
read -p "Ваш выбор: " action
case $action in
  1)
    echo ""
    echo "Выберите период:"
    echo -e "  ${GREEN}1.${NC} Последний час"
    echo -e "  ${GREEN}2.${NC} Последние 6 часов"
    echo -e "  ${GREEN}3.${NC} Последние 24 часа"
    read -p "Ваш выбор: " period
    case $period in
      1) SINCE="1 hour ago";;
      2) SINCE="6 hours ago";;
      *) SINCE="24 hours ago";;
    esac
    echo ""
    echo -e "${RED}========== ОШИБКИ (ERROR) ==========${NC}"
    journalctl -u x-ui --since "$SINCE" --no-pager | grep -E "ERROR|error" | tail -30
    echo ""
    echo -e "${YELLOW}========== ПРЕДУПРЕЖДЕНИЯ (WARNING) ==========${NC}"
    journalctl -u x-ui --since "$SINCE" --no-pager | grep "WARNING" | tail -30
    echo ""
    echo -e "${GREEN}========== ИНФО (INFO) - последние 20 ==========${NC}"
    journalctl -u x-ui --since "$SINCE" --no-pager | grep "INFO" | tail -20
    ;;
  2)
    echo ""
    echo -e "${YELLOW}ВНИМАНИЕ: очистка затронет ВСЕ системные логи (не только x-ui)${NC}"
    read -p "Оставить логи за последние N дней (введите число, например 7): " days
    if [[ "$days" =~ ^[0-9]+$ ]]; then
      journalctl --vacuum-time=${days}d
      echo ""
      echo -e "${GREEN}✅ Очистка завершена. Новый размер:${NC}"
      journalctl --disk-usage
    else
      echo -e "${RED}❌ Введено некорректное число${NC}"
    fi
    ;;
  3)
    bash $DIR/fail2ban.sh
    ;;
esac
exit 0
