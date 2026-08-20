cat << 'MAIN_EOF' > /root/scripts/main.sh
#!/bin/bash
export TZ='Europe/Moscow'
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; PINK='\033[95m'; WHITE='\033[0;37m'; NC='\033[0m'
DIR="/root/scripts"
pause() { echo ""; read -p "Нажмите Enter для возврата..."; }

menu_panel() {
  while true; do
    clear
    echo -e "${PINK}==========================================${NC}"
    echo -e "${PINK}  УПРАВЛЕНИЕ ПАНЕЛЬЮ X-UI И XRAY${NC}"
    echo -e "${PINK}==========================================${NC}"
    echo ""
    echo -e "  ${GREEN}1.${NC} 🔄 Перезапуск панели x-ui (перезапускает сервис панели + Xray)"
    echo -e "  ${GREEN}2.${NC} 📡 Статус Xray (состояние панели, Xray, слушаемые порты)"
    echo -e "  ${GREEN}0.${NC} ← Назад (или Enter)"
    echo ""
    echo -e "${WHITE}==========================================${NC}"
    echo -e "${WHITE}  ОТЧЕТ О СОСТОЯНИИ X-UI И XRAY${NC}"
    echo -e "${WHITE}==========================================${NC}"
    echo ""
    echo -e "${WHITE}=== Статус x-ui ===${NC}"
    if systemctl is-active --quiet x-ui; then
        echo -e "${GREEN}✅ активен${NC}"
    else
        echo -e "${RED}❌ не активен${NC}"
    fi
    echo ""
    echo -e "${WHITE}=== Процесс Xray ===${NC}"
    ps aux | grep -v grep | grep xray | awk '{print "PID:", $2, "| запущен в:", $9}' || echo "Xray не запущен"
    echo ""
    echo -e "${WHITE}=== Сокеты в /dev/shm ===${NC}"
    ls -la /dev/shm/uds*.sock 2>/dev/null || echo "сокетов нет"
    echo ""
    echo -e "${WHITE}=== Ошибки за последний час ===${NC}"
    ERROR_COUNT=$(journalctl -u x-ui --since "1 hour ago" --no-pager | grep -c "ERROR")
    echo "$ERROR_COUNT"
    echo ""
    read -p "  Ваш выбор: " c
    case $c in
      1)
        echo ""
        read -p "Перезапустить панель x-ui? (Enter = yes, или введите no): " ans
        ans=${ans:-yes}
        if [ "$ans" = "yes" ]; then
          systemctl restart x-ui
          sleep 2
          systemctl is-active --quiet x-ui && echo -e "${GREEN}✅ Панель перезапущена${NC}" || echo -e "${RED}❌ Ошибка перезапуска${NC}"
          echo ""
          echo -e "${WHITE}=== Статус после перезапуска ===${NC}"
          if systemctl is-active --quiet x-ui; then PANEL_STATE="${GREEN}Running${NC}"; else PANEL_STATE="${RED}Stopped${NC}"; fi
          if pgrep -f xray >/dev/null 2>&1; then XRAY_STATE="${GREEN}Running${NC}"; else XRAY_STATE="${RED}Stopped${NC}"; fi
          echo -e "Panel state: $PANEL_STATE"
          echo -e "xray state: $XRAY_STATE"
        else
          echo "Перезапуск отменен"
        fi
        pause;;
      2)
        echo ""
        if systemctl is-active --quiet x-ui; then PANEL_STATE="${GREEN}Running${NC}"; else PANEL_STATE="${RED}Stopped${NC}"; fi
        if systemctl is-enabled --quiet x-ui 2>/dev/null; then AUTOSTART="${GREEN}Yes${NC}"; else AUTOSTART="${RED}No${NC}"; fi
        if pgrep -f xray >/dev/null 2>&1; then XRAY_STATE="${GREEN}Running${NC}"; else XRAY_STATE="${RED}Stopped${NC}"; fi
        echo -e "Panel state: $PANEL_STATE"
        echo -e "Start automatically: $AUTOSTART"
        echo -e "xray state: $XRAY_STATE"
        echo ""
        echo -e "${WHITE}=== Процесс Xray ===${NC}"
        ps aux | grep -v grep | grep xray || echo -e "${RED}Xray не запущен${NC}"
        echo ""
        echo -e "${WHITE}=== Порты, которые слушает Xray ===${NC}"
        ss -tulpn 2>/dev/null | grep xray || echo "Порты не найдены"
        pause;;
      0|""|" ") return;;
    esac
  done
}

menu_ports() {
  while true; do
    clear
    echo -e "${PINK}==========================================${NC}"
    echo -e "${PINK}  УПРАВЛЕНИЕ ПОРТАМИ${NC}"
    echo -e "${PINK}==========================================${NC}"
    echo ""
    echo -e "  ${GREEN}1.${NC} 🔌 Проверка открытых портов (правила ufw и слушаемые порты)"
    echo -e "  ${GREEN}2.${NC} ➕ Открыть порт (разрешить порт в файрволе)"
    echo -e "  ${GREEN}3.${NC} ➖ Закрыть порт (запретить порт в файрволе)"
    echo -e "  ${GREEN}4.${NC} 🔁 Перезапуск файрвола (применить изменения ufw)"
    echo -e "  ${GREEN}0.${NC} ← Назад (или Enter)"
    echo ""
    read -p "  Ваш выбор: " c
    case $c in
      1)
        echo ""
        echo -e "${WHITE}=== Правила файрвола (ufw) ===${NC}"
        ufw status
        echo ""
        echo -e "${WHITE}=== Реально слушающие порты ===${NC}"
        ss -tulpn | grep LISTEN
        pause;;
      2)
        echo ""
        read -p "Введите номер порта: " port
        if [[ ! "$port" =~ ^[0-9]+$ ]]; then
          echo -e "${RED}❌ Порт должен быть числом${NC}"; pause; continue
        fi
        read -p "Протокол (tcp/udp) [tcp по умолчанию]: " proto
        if [ -z "$proto" ]; then
          proto="tcp"
          echo -e "${YELLOW}Используется протокол по умолчанию: tcp${NC}"
        fi
        read -p "Название порта (комментарий): " name
        ufw allow $port/$proto comment "$name"
        ufw reload
        echo -e "${GREEN}✅ Порт $port/$proto открыт${NC}"
        pause;;
      3)
        echo ""
        echo -e "${WHITE}=== Текущие правила (с номерами) ===${NC}"
        ufw status numbered
        echo ""
        read -p "Введите номер правила для удаления: " num
        if [[ "$num" =~ ^[0-9]+$ ]]; then
          RULE=$(ufw status numbered | grep "^\[ *$num\]")
          echo -e "${YELLOW}Будет удалено: $RULE${NC}"
          if echo "$RULE" | grep -q "22/tcp"; then
            echo -e "${RED}⚠️ ВНИМАНИЕ: это SSH порт! Вы потеряете доступ к серверу!${NC}"
            read -p "Точно удалить? (yes/no): " ssh_ans
            if [ "$ssh_ans" != "yes" ]; then echo "Отменено"; pause; continue; fi
          fi
          read -p "Подтвердить удаление? (yes/no): " del_ans
          if [ "$del_ans" = "yes" ]; then
            ufw --force delete $num
            ufw reload
            echo -e "${GREEN}✅ Правило удалено${NC}"
          else
            echo "Отменено"
          fi
        else
          echo -e "${RED}❌ Введите номер правила${NC}"
        fi
        pause;;
      4)
        echo ""
        ufw reload
        echo -e "${GREEN}✅ Файрвол перезапущен${NC}"
        pause;;
      0|""|" ") return;;
    esac
  done
}

while true; do
  clear
  echo -e "${PINK}==========================================${NC}"
  echo -e "${PINK}   МЕНЮ УПРАВЛЕНИЯ СЕРВЕРОМ${NC}"
  echo -e "${PINK}==========================================${NC}"
  echo ""
  echo -e "  ${GREEN}1.${NC} 📊 Отчет о состоянии сервера (статус панели, CPU, память, диск, ошибки)"
  echo -e "  ${GREEN}2.${NC} 🔃 Перезагрузка сервера (полная перезагрузка VPS)"
  echo -e "  ${GREEN}3.${NC} 🛠  Управление панелью X-UI и Xray (перезапуск, статус)"
  echo -e "  ${GREEN}4.${NC} 🔌 Управление портами (проверка, открытие, закрытие, файрвол)"
  echo -e "  ${GREEN}5.${NC} 📋 Логи (просмотр / очистка)"
  echo -e "  ${GREEN}6.${NC} 🚀 Запуск меню x-ui (родное меню управления панелью)"
  echo -e "  ${GREEN}0.${NC} Выход"
  echo ""
  read -p "  Выберите пункт: " c
  case $c in
    1) bash $DIR/system_report.sh; pause;;
    2)
      echo ""
      echo -e "${PINK}⚠️ Внимание ⚠️${NC}"
      echo -e "${PINK}Во время перезагрузки:${NC}"
      echo -e "${PINK}- VPN прервется на 1–3 минуты (пока сервер грузится)${NC}"
      echo -e "${PINK}- Бот YadrenoVPN тоже временно перестанет работать${NC}"
      echo -e "${PINK}- Все клиенты будут переподключаться${NC}"
      echo ""
      read -p "Вы уверены, что хотите перезагрузить сервер? (yes/no): " ans1
      if [ "$ans1" = "yes" ]; then
        echo -e "${YELLOW}⏳ Сервер перезагружается...${NC}"
        sleep 2
        reboot
      else
        echo "Перезагрузка отменена"
      fi
      pause;;
    3) menu_panel;;
    4) menu_ports;;
    5) bash $DIR/logs.sh; pause;;
    6) x-ui; pause;;
    0) echo "Выход..."; exit 0;;
    *) echo -e "${RED}Неверный выбор${NC}"; sleep 1;;
  esac
done
MAIN_EOF