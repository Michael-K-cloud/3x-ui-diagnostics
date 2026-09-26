#!/bin/bash
# Установка и запуск Telegram-бота диагностики (v0.1, один сервер).
# Предварительно должен быть заполнен /root/scripts/.env (BOT_TOKEN, CHAT_ID).
# Запуск: bash /root/scripts/tg-bot-install.sh   (или из распакованной папки репозитория)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}❌ Запустите от root${NC}"
  exit 1
fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
for f in tg-bot.py tg-diag-bot.service; do
  if [ ! -s "$SRC/$f" ] && [ -s "/root/scripts/$f" ]; then SRC=/root/scripts; fi
done
for f in tg-bot.py tg-diag-bot.service; do
  [ -s "$SRC/$f" ] || { echo -e "${RED}❌ Файл $f не найден (ни в $SRC, ни в /root/scripts)${NC}"; exit 1; }
done

ENVF=/root/scripts/.env
if ! grep -q '^BOT_TOKEN=..' "$ENVF" 2>/dev/null || ! grep -q '^CHAT_ID=..' "$ENVF" 2>/dev/null; then
  echo -e "${RED}❌ В $ENVF нет BOT_TOKEN или CHAT_ID — сначала заполните .env${NC}"
  exit 1
fi
if grep -q 'СЮДА_' "$ENVF" 2>/dev/null; then
  echo -e "${RED}❌ В .env остались заглушки (СЮДА_...) — замените их реальными значениями${NC}"
  exit 1
fi

command -v python3 >/dev/null 2>&1 || { echo -e "${RED}❌ python3 не найден${NC}"; exit 1; }

cp -f "$SRC/tg-bot.py" /root/scripts/tg-bot.py
chmod +x /root/scripts/tg-bot.py
cp -f "$SRC/tg-diag-bot.service" /etc/systemd/system/tg-diag-bot.service
systemctl daemon-reload
systemctl enable tg-diag-bot >/dev/null 2>&1
systemctl restart tg-diag-bot
sleep 3

echo -e "${GREEN}=== Статус бота ===${NC}"
systemctl --no-pager status tg-diag-bot 2>&1 | head -8
echo ""
echo -e "${GREEN}✅ Бот установлен и запущен.${NC}"
echo "Откройте бота в Telegram и нажмите Start (или отправьте /start)."
echo "Живой лог бота:  journalctl -u tg-diag-bot -f"
echo "Остановить:      systemctl stop tg-diag-bot"
