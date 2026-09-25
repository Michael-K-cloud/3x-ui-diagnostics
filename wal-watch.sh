#!/bin/bash
DB=/etc/x-ui/x-ui.db
LOG=/root/wal-watch.log
TS=$(date -u '+%F %T')
PID=$(pgrep -f "/usr/local/x-ui/x-ui" | head -1)
WAL="-"; SHM="-"
[ -e "$DB-wal" ] && WAL=$(stat -c %s "$DB-wal")
[ -e "$DB-shm" ] && SHM=$(stat -c %s "$DB-shm")
DEL="clean"
if [ -n "$PID" ]; then
  ls -l "/proc/$PID/fd" 2>/dev/null | grep -q "(deleted)" && DEL="DELETED-HANDLE"
fi
ERR=$(journalctl -u x-ui --since "-5 min" --no-pager 2>/dev/null | grep -icE "malformed|disk I/O")
echo "$TS pid=$PID wal=$WAL shm=$SHM fd=$DEL err5m=$ERR" >> "$LOG"
