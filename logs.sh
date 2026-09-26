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
echo -e "  ${GREEN}1.${NC} 📋 Просмотр отсортированных логов (ERROR, WARNING, INFO за период) + ссылка на HTML"
echo -e "  ${GREEN}2.${NC} 🧹 Очистка логов (удалить старые записи journald)"
echo -e "  ${GREEN}3.${NC} 🛡  Отчёт по fail2ban (заблокированные IP и статистика блокировок) + ссылка на HTML"
echo -e "  ${GREEN}0.${NC} ← Назад (или Enter)"
read -p "Ваш выбор: " action
case $action in
  1)
    echo ""
    echo "Выберите период:"
    echo -e "  ${GREEN}1.${NC} Последний час"
    echo -e "  ${GREEN}2.${NC} Последние 6 часов"
    echo -e "  ${GREEN}3.${NC} Ввести кол-во часов"
    read -p "Ваш выбор: " period
    case $period in
      1) HRS=1;;
      2) HRS=6;;
      3)
        read -p "Сколько часов логов показать? (введите число, например 12, 24, 72): " hours
        [[ "$hours" =~ ^[0-9]+$ ]] || { echo -e "${RED}❌ Введено не число, беру 24 часа${NC}"; hours=24; }
        [ "$hours" -eq 0 ] && hours=24
        HRS=$hours;;
      *) HRS=24;;
    esac
    echo ""
    bash $DIR/report.sh logs "$HRS" --print
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
    echo ""
    bash $DIR/report.sh fail2ban --print
    ;;
esac
exit 0
