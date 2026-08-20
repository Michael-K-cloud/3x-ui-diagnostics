#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}  Установка системы диагностики сервера${NC}"
echo -e "${GREEN}==========================================${NC}"
echo ""

# 1. Проверка прав root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}❌ Пожалуйста, запустите скрипт от имени root (sudo su)${NC}"
  exit 1
fi

# 2. Установка зависимостей
echo -e "${YELLOW}⏳ Установка зависимостей (sqlite3, sysstat)...${NC}"
apt update -qq >/dev/null 2>&1
apt install sqlite3 sysstat -y -qq >/dev/null 2>&1
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Зависимости установлены${NC}"
else
    echo -e "${RED}⚠️ Не удалось установить зависимости, продолжаем...${NC}"
fi

# 3. Создание директории
echo -e "${YELLOW}⏳ Создание директории /root/scripts...${NC}"
mkdir -p /root/scripts

# 4. Настройки GitHub (ЗАМЕНИТЕ НА ВАШИ ДАННЫЕ!)
GITHUB_USER="ВАШ_ЛОГИН"
GITHUB_REPO="ВАШ_РЕПОЗИТОРИЙ"
BRANCH="main"

RAW_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${BRANCH}"

echo -e "${YELLOW}⏳ Скачивание скриптов из GitHub...${NC}"

wget -qO /root/scripts/system_report.sh "${RAW_URL}/system_report.sh"
wget -qO /root/scripts/fail2ban.sh "${RAW_URL}/fail2ban.sh"
wget -qO /root/scripts/logs.sh "${RAW_URL}/logs.sh"
wget -qO /root/scripts/main.sh "${RAW_URL}/main.sh"

# 5. Проверка успешности скачивания
if [ -f /root/scripts/main.sh ]; then
    echo -e "${GREEN}✅ Скрипты успешно скачаны${NC}"
else
    echo -e "${RED}❌ Ошибка скачивания скриптов. Проверьте логин и имя репозитория в install.sh.${NC}"
    exit 1
fi

# 6. Настройка прав и создание команды menu
echo -e "${YELLOW}⏳ Настройка прав доступа и создание команды 'menu'...${NC}"
chmod +x /root/scripts/*.sh
ln -sf /root/scripts/main.sh /usr/local/bin/menu

echo ""
echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}  ✅ Установка успешно завершена!${NC}"
echo -e "${GREEN}==========================================${NC}"
echo ""
echo "Теперь вы можете запустить меню командой:"
echo -e "${YELLOW}  menu${NC}"
echo ""