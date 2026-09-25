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

# 4. Настройки GitHub
GITHUB_USER="Michael-K-cloud"
GITHUB_REPO="3x-ui-diagnostics"
BRANCH="main"

RAW_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${BRANCH}"

# ВАЖНО: только IPv4 + таймауты. Исходящий IPv6 на серверах может зависать
# (проверено 25.09.2026 на FI): без --inet4-only wget виснет на raw.githubusercontent.com.
WGET_OPTS="--inet4-only --timeout=20 --tries=2 -qO"
FILES="system_report.sh fail2ban.sh logs.sh main.sh wal-watch.sh baseline.sh report.sh"

echo -e "${YELLOW}⏳ Скачивание скриптов из GitHub (IPv4, таймаут 20 c)...${NC}"

FAIL=0
for f in $FILES; do
  if ! wget $WGET_OPTS "/root/scripts/$f" "${RAW_URL}/$f"; then
    echo -e "${RED}❌ Не удалось скачать $f${NC}"
    FAIL=1
  fi
done

# 5. Проверка: все файлы скачаны и НЕ пустые (wget -O обрезает файл ещё до скачивания!)
for f in $FILES; do
  if [ ! -s "/root/scripts/$f" ]; then
    echo -e "${RED}❌ Файл /root/scripts/$f пуст или не скачан${NC}"
    FAIL=1
  fi
done

if [ "$FAIL" = "1" ]; then
  echo -e "${RED}❌ Установка прервана: часть файлов не скачалась.${NC}"
  echo -e "${RED}⚠️ Прерванная установка могла ОБРЕЗАТЬ файлы в /root/scripts — повторите установку до успешного конца.${NC}"
  exit 1
fi
echo -e "${GREEN}✅ Скрипты успешно скачаны${NC}"

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
echo "WAL-сторож (контроль базы данных x-ui) устанавливается,"
echo "но НЕ включается автоматически. Чтобы включить:"
echo -e "${YELLOW}  menu → 1 (Диагностика) → 2 (WAL-сторож) → 3 (Включить)${NC}"
echo ""
echo "HTML-отчёты по ссылкам: menu → 1 → 5. Чтобы ссылки открывались,"
echo "нужно один раз настроить nginx location /report/ (см. README)."
echo ""
echo "Повторный запуск install.sh = безопасное обновление скриптов"
echo "(cron, лог сторожа, .env и эталон не затрагиваются)."
echo ""
