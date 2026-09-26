#!/bin/bash
# Установка/обновление системы диагностики сервера 3x-ui-diagnostics. Версия 2.2 (25.09.2026)
#
# Способ 1 (основной): запуск из распакованного архива/папки репозитория — файлы
#         копируются из той же директории, сеть не нужна.
# Способ 2: скачивание ВСЕГО репозитория одним tar-архивом с codeload.github.com (IPv4).
#
# Пофайловое скачивание с raw.githubusercontent.com БОЛЬШЕ НЕ ИСПОЛЬЗУЕТСЯ:
# домен отдаётся с четырёх IP Fastly (185.199.108–111.133); из сетей некоторых
# серверов один из них (185.199.111.133) может быть недоступен (таймаут), а DNS
# выдаёт адреса в случайном порядке → случайные обрывы скачивания (проверено на FI 25.09.2026).
# codeload.github.com обслуживается другой инфраструктурой и таких сбоев не давал.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

DIAG_VERSION="2.3"
FILES="main.sh logs.sh system_report.sh fail2ban.sh wal-watch.sh baseline.sh report.sh tg-bot.py tg-bot-install.sh tg-diag-bot.service"
GITHUB_USER="Michael-K-cloud"
GITHUB_REPO="3x-ui-diagnostics"
BRANCH="main"
TARBALL_URL="https://codeload.github.com/${GITHUB_USER}/${GITHUB_REPO}/tar.gz/refs/heads/${BRANCH}"

echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}  Установка системы диагностики сервера${NC}"
echo -e "${GREEN}  (install.sh v${DIAG_VERSION})${NC}"
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

# 4. Определение источника файлов
SRC=""
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

# Способ 1: все файлы лежат рядом с install.sh (запуск из распакованного архива)
if [ -n "$SRC_DIR" ]; then
  OK=1
  for f in $FILES; do [ -s "$SRC_DIR/$f" ] || OK=0; done
  if [ "$OK" = "1" ]; then
    SRC="$SRC_DIR"
    echo -e "${GREEN}✅ Найден локальный комплект файлов ($SRC_DIR) — установка без сети${NC}"
  fi
fi

# Способ 2: один tar-архив с codeload.github.com
if [ -z "$SRC" ]; then
  echo -e "${YELLOW}⏳ Скачивание репозитория одним архивом (IPv4, codeload.github.com)...${NC}"
  TMPD=$(mktemp -d)
  if wget --inet4-only --timeout=30 --tries=3 -qO "$TMPD/repo.tar.gz" "$TARBALL_URL" && tar -xzf "$TMPD/repo.tar.gz" -C "$TMPD" 2>/dev/null; then
    EXDIR=$(find "$TMPD" -maxdepth 1 -type d -name "${GITHUB_REPO}-*" | head -1)
    OK=1
    for f in $FILES; do [ -n "$EXDIR" ] && [ -s "$EXDIR/$f" ] || OK=0; done
    if [ "$OK" = "1" ]; then
      SRC="$EXDIR"
      echo -e "${GREEN}✅ Архив скачан и распакован${NC}"
    else
      echo -e "${RED}❌ В архиве не хватает файлов${NC}"
    fi
  else
    echo -e "${RED}❌ Не удалось скачать архив с codeload.github.com${NC}"
  fi
fi

if [ -z "$SRC" ]; then
  echo -e "${RED}❌ Установка прервана: нет источника файлов. Существующие файлы в /root/scripts НЕ тронуты.${NC}"
  exit 1
fi

# 5. Копирование файлов (только после того, как источник полностью проверен)
for f in $FILES; do
  cp -f "$SRC/$f" "/root/scripts/$f"
done

# 6. Контроль: все файлы на месте и НЕ пустые
FAIL=0
for f in $FILES; do
  if [ ! -s "/root/scripts/$f" ]; then
    echo -e "${RED}❌ Файл /root/scripts/$f пуст или не скопирован${NC}"
    FAIL=1
  fi
done
if [ "$FAIL" = "1" ]; then
  echo -e "${RED}❌ Установка прервана: повторите установку.${NC}"
  exit 1
fi
echo -e "${GREEN}✅ Все файлы установлены и проверены${NC}"

# 7. Права и команда menu
chmod +x /root/scripts/*.sh
ln -sf /root/scripts/main.sh /usr/local/bin/menu

echo ""
echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}  ✅ Установка успешно завершена!${NC}"
echo -e "${GREEN}==========================================${NC}"
echo ""
echo "Контрольные суммы установленных файлов:"
sha256sum /root/scripts/*.sh
echo ""
echo "Запуск меню:"
echo -e "${YELLOW}  menu${NC}"
echo ""
echo "WAL-сторож устанавливается, но НЕ включается автоматически. Включить:"
echo -e "${YELLOW}  menu → 1 (Диагностика) → 2 (WAL-сторож) → 3 (Включить)${NC}"
echo ""
echo "HTML-отчёты по ссылкам: menu → 1 → 5. Чтобы ссылки открывались,"
echo "нужно один раз настроить nginx location /report/ (см. README)."
echo ""
echo "Telegram-бот: заполните /root/scripts/.env (BOT_TOKEN, CHAT_ID) и выполните"
echo -e "${YELLOW}  bash /root/scripts/tg-bot-install.sh${NC}"
echo ""
echo "Повторный запуск install.sh = безопасное обновление скриптов"
echo "(cron, лог сторожа, .env и эталон не затрагиваются)."
echo ""
