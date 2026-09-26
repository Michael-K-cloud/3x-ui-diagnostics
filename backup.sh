#!/bin/bash
# backup.sh — консистентный бэкап сервера (версия 1.0, 26.09.2026).
# Состав: x-ui.db (через .backup + верификация), vpn_bot.db (если есть), /etc/nginx (tar),
#         config.json, x-ui.service + drop-in, эталон, манифест, SHA256SUMS.
# БЕЗ бинарников (восстановимы из релизов) и БЕЗ .env (секреты не должны покидать сервер).
# Безопасно на живой панели: .backup = SQLite Online Backup API (тот же механизм,
# которым ежедневно пользуется бот YadrenoVPN).
# Использование: bash /root/scripts/backup.sh [каталог_назначения]
# Вывод для бота: строки "✅ Бэкап: <путь> (<размер>)" и "sha256: <сумма>"

DATE=$(date -u +%F_%H%M%S)
HOST=$(hostname -s 2>/dev/null || hostname)
OUTDIR="${1:-/root/backups/diag}"
SCRIPTS=/root/scripts
mkdir -p "$OUTDIR"
WORK=$(mktemp -d /tmp/backup-XXXXXX)
D="$WORK/backup-$HOST-$DATE"
mkdir -p "$D"

fail() { echo "❌ Ошибка бэкапа: $1"; rm -rf "$WORK"; exit 1; }

# 1. База панели — консистентная копия + верификация
sqlite3 /etc/x-ui/x-ui.db ".backup '$D/x-ui.db'" || fail ".backup x-ui.db"
CHK=$(sqlite3 "file:$D/x-ui.db?mode=ro" "PRAGMA integrity_check;" 2>&1 | head -1)
[ "$CHK" = "ok" ] || fail "верификация копии БД: $CHK"
sqlite3 "file:$D/x-ui.db?mode=ro" "SELECT 'inbounds='||COUNT(*) FROM inbounds UNION ALL SELECT 'clients='||COUNT(*) FROM clients UNION ALL SELECT 'users='||COUNT(*) FROM users;" > "$D/db-counts.txt" 2>/dev/null

# 2. База бота YadrenoVPN (только на мастер-сервере)
if [ -f /root/YadrenoVPN/database/vpn_bot.db ]; then
  if sqlite3 /root/YadrenoVPN/database/vpn_bot.db ".backup '$D/vpn_bot.db'" 2>/dev/null; then
    echo "vpn_bot.db: ok" >> "$D/db-counts.txt"
  else
    echo "vpn_bot.db: ОШИБКА копирования" >> "$D/db-counts.txt"
  fi
fi

# 3. Конфиги
tar -czf "$D/nginx-etc.tar.gz" /etc/nginx 2>/dev/null
cp -a /usr/local/x-ui/bin/config.json "$D/xray-config.json" 2>/dev/null
cp -a /etc/systemd/system/x-ui.service "$D/x-ui.service" 2>/dev/null
[ -d /etc/systemd/system/x-ui.service.d ] && cp -a /etc/systemd/system/x-ui.service.d "$D/x-ui.service.d" 2>/dev/null
[ -f "$SCRIPTS/etalon/etalon.txt" ] && cp -a "$SCRIPTS/etalon/etalon.txt" "$D/etalon.txt"

# 4. Манифест и контрольные суммы
{
  echo "date=$DATE UTC"
  echo "host=$HOST"
  /usr/local/x-ui/bin/xray-linux-amd64 version 2>/dev/null | head -1
  x-ui status 2>/dev/null | grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+' | sed 's/^/x-ui=/'
} > "$D/manifest.txt"
( cd "$D" && sha256sum -- * .[!.]* 2>/dev/null | grep -v '^SHA256SUMS' > SHA256SUMS )

# 5. Архив
TAR="$OUTDIR/backup-$HOST-$DATE.tar.gz"
tar -czf "$TAR" -C "$WORK" "backup-$HOST-$DATE" || fail "создание tar.gz"
rm -rf "$WORK"
sha256sum "$TAR" > "$TAR.sha256"
SIZE=$(du -h "$TAR" | cut -f1)

# 6. Ротация: хранить 14 последних
ls -1t "$OUTDIR"/backup-*.tar.gz 2>/dev/null | tail -n +15 | while read -r f; do rm -f "$f" "$f.sha256"; done

echo "✅ Бэкап: $TAR ($SIZE)"
echo "sha256: $(cut -d' ' -f1 "$TAR.sha256")"
