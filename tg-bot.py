#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tg-bot.py — Telegram-бот диагностики сервера 3x-ui (версия 0.1, 25.09.2026).
ОДИН сервер = ОДИН запущенный бот (Telegram не позволяет нескольким процессам
слушать один токен). Мульти-серверная версия (выбор сервера, утренние бэкапы
со всех серверов) — v0.2, центральный бот на мастере.

Только стандартная библиотека python3 (никаких pip-пакетов).
Настройки: /root/scripts/.env  (BOT_TOKEN, CHAT_ID, REPORT_INTERVAL_HOURS,
SERVER_NAME, TG_ENABLED; REPORT_PATH используется report.sh).
Безопасность: принимаются обновления ТОЛЬКО от владельца (CHAT_ID из .env);
деструктивные действия — только после подтверждения (текст "yes" или кнопка).
Запуск: systemd-юнит tg-diag-bot.service (см. tg-bot-install.sh).
"""
import datetime
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

ENVF = "/root/scripts/.env"
SCRIPTS = "/root/scripts"
WALLOG = "/root/wal-watch.log"
REBOOT_MARKER = "/root/.tg-diag-reboot-pending"
STATE_FILE = "/run/tg-diag-bot.state.json"

# ---------------------------------------------------------------- .env -----

def load_env():
    env = {}
    try:
        with open(ENVF, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    return env


def set_env_key(key, val):
    lines = []
    if os.path.exists(ENVF):
        with open(ENVF, encoding="utf-8") as f:
            lines = f.read().splitlines()
    out, found = [], False
    for l in lines:
        if l.strip().startswith(key + "="):
            out.append(f"{key}={val}")
            found = True
        else:
            out.append(l)
    if not found:
        out.append(f"{key}={val}")
    with open(ENVF, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    os.chmod(ENVF, 0o600)


ENV = load_env()
TOKEN = ENV.get("BOT_TOKEN", "")
CHAT = ENV.get("CHAT_ID", "")
try:
    CHAT_INT = int(CHAT)
except ValueError:
    CHAT_INT = None
INTERVAL = ENV.get("REPORT_INTERVAL_HOURS", "6")
try:
    INTERVAL = max(1, min(168, int(INTERVAL)))
except ValueError:
    INTERVAL = 6
SRVNAME = ENV.get("SERVER_NAME", os.uname().nodename)
API = "https://api.telegram.org/bot" + TOKEN

# ------------------------------------------------------------ утилиты -----

def log(msg):
    print("[%s] %s" % (datetime.datetime.now().strftime("%F %T"), msg), flush=True)


def tg(method, **params):
    if not TOKEN:
        return {"ok": False}
    data = json.dumps(params).encode("utf-8")
    req = urllib.request.Request(API + "/" + method, data=data,
                                 headers={"Content-Type": "application/json"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=40) as r:
                return json.loads(r.read().decode("utf-8"))
        except Exception as e:
            log("TG API %s ошибка (попытка %d): %s" % (method, attempt + 1, e))
            time.sleep(3)
    return {"ok": False}


def send(text, kb=None):
    text = text[:4000]
    params = {"chat_id": CHAT, "text": text}
    if kb:
        params["reply_markup"] = {"inline_keyboard": kb}
    return tg("sendMessage", **params)


def edit(text, msg_id, kb=None):
    params = {"chat_id": CHAT, "message_id": msg_id, "text": text[:4000]}
    if kb:
        params["reply_markup"] = {"inline_keyboard": kb}
    return tg("editMessageText", **params)


def sh(cmd, timeout=60):
    try:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        out = p.stdout or ""
        if p.stderr and p.stderr.strip():
            out += "\n[stderr] " + p.stderr.strip()
        return out.strip()
    except subprocess.TimeoutExpired:
        return "[таймаут команды]"
    except Exception as e:
        return "[ошибка: %s]" % e


def btn(text, cb):
    return {"text": text, "callback_data": cb}


def kbd(*rows):
    return [list(r) for r in rows]


BACK_HOME = (btn("⬅️ Назад", "m:back"), btn("🏠 Главное меню", "m:home"))

# --------------------------------------------------------- сбор данных ----

def gen_report_link(kind, hours=None):
    cmd = "bash %s/report.sh %s" % (SCRIPTS, kind)
    if hours:
        cmd += " %d" % hours
    out = sh(cmd, timeout=120)
    m = re.search(r"Ссылка:\s*(\S+)", out)
    return m.group(1) if m else None


def brief_status():
    panel = sh("systemctl is-active x-ui")
    db = sh("sqlite3 'file:/etc/x-ui/x-ui.db?mode=ro&immutable=1' 'PRAGMA integrity_check;' | head -1")
    crit = sh("journalctl -u x-ui --since '1440 minutes ago' -p err --no-pager 2>/dev/null | grep -vcE '^-- |^$|No entries'") or "0"
    dbe = sh("journalctl -u x-ui --since '1440 minutes ago' --no-pager 2>/dev/null | grep -icE 'malformed|disk I/O'") or "0"
    up = sh("uptime -p | sed 's/up //'")
    reb = "⚠️ нужна" if os.path.exists("/var/run/reboot-required") else "не требуется"
    cpu = sh("top -bn1 | grep '%Cpu' | awk '{print 100-$8}' | cut -d. -f1") or "?"
    ram = sh("free -m | awk '/Mem:/ {printf \"%d%% (%d из %d MB)\", $3*100/$2, $3, $2}'")
    disk = sh("df -h / | awk 'NR==2 {printf \"%s (свободно %s)\", $5, $4}'")
    p_emoji = "✅" if panel == "active" else "❌"
    d_emoji = "✅" if db == "ok" else "❌"
    e_emoji = "✅" if crit.strip() == "0" else "⚠️ %s" % crit.strip()
    b_emoji = "✅" if dbe.strip() == "0" else "❌ %s" % dbe.strip()
    return ("📊 Отчёт о состоянии сервера %s\n"
            "Панель: %s %s\n"
            "База данных: %s %s\n"
            "Перезагрузка системы: %s\n"
            "Сервер работает: %s\n"
            "CPU: %s%% · RAM: %s · Диск: %s\n"
            "Критических ошибок за 24 ч: %s\n"
            "Ошибки БД в логах за 24 ч: %s"
            % (SRVNAME, p_emoji, panel, d_emoji, db, reb, up, cpu, ram, disk, e_emoji, b_emoji))


def resources_text():
    cpu = sh("top -bn1 | grep '%Cpu' | awk '{print 100-$8}' | cut -d. -f1") or "?"
    ram = sh("free -m | awk '/Mem:/ {printf \"%d%% (занято %d MB из %d MB, свободно %d MB)\", $3*100/$2, $3, $2, $7}'")
    disk = sh("df -BG / | awk 'NR==2 {printf \"занято %s из %s, свободно %s\", $3, $2, $4}'")
    now = datetime.datetime.now().strftime("%F %T")
    return ("📈 Ресурсы — сервер %s\n\nCPU: %s%%\nRAM: %s\nДиск /: %s\n\n🕒 %s"
            % (SRVNAME, cpu, ram, disk, now))


def wal_state():
    """Возвращает (краткий_текст, аномалия_bool, последняя_строка)."""
    if not os.path.exists(WALLOG):
        return ("⚠️ Лог сторожа не найден — сторож не работал?", False, "")
    last = sh("tail -1 %s" % WALLOG)
    total = sh("wc -l < %s" % WALLOG) or "?"
    anom = sh("grep -cE 'DELETED|err5m=[1-9]|wal=-' %s" % WALLOG) or "0"
    cron = sh("crontab -l 2>/dev/null | grep -c wal-watch") or "0"
    anom_int = int(anom.strip() or 0)
    txt = ("🛡 WAL-сторож — сервер %s\n"
           "Cron: %s\nЗамеров: %s · Аномалии: %s\nПоследний замер:\n%s"
           % (SRVNAME, "✅ включён" if cron.strip() != "0" else "⚠️ ВЫКЛЮЧЕН",
              total, anom, last))
    fresh_bad = ("DELETED" in last) or re.search(r"err5m=[1-9]", last) or ("wal=-" in last)
    return (txt, anom_int > 0 or fresh_bad, last)


def etalon_brief():
    if not os.path.exists(SCRIPTS + "/etalon/etalon.txt"):
        return "📌 Эталон ещё не сохранён (меню Диагностика → Эталон → Сохранить)."
    out = sh("bash %s/baseline.sh compare 2>&1" % SCRIPTS, timeout=90)
    n = len([l for l in out.splitlines() if l.startswith("<") or l.startswith(">")])
    head = sh("head -1 %s/etalon/etalon.txt | sed 's/^# Снимок: //'" % SCRIPTS)
    if n == 0:
        return "📌 Эталон (%s)\n✅ Отличий от эталона нет" % head
    return "📌 Эталон (%s)\n⚠️ Отличий от эталона: %d строк — подробности в HTML-отчёте" % (head, n)


def f2b_brief():
    if not os.path.exists("/usr/bin/fail2ban-client"):
        return "fail2ban не установлен"
    jails = sh("fail2ban-client status 2>/dev/null | grep 'Jail list' | sed 's/.*://; s/,/ /g'")
    lines = ["🛡 fail2ban — сервер %s" % SRVNAME]
    for j in jails.split():
        cb = sh("fail2ban-client status %s 2>/dev/null | awk -F: '/Currently banned/{gsub(/[ \\t]/,\"\",$2); print $2}'" % j)
        tb = sh("fail2ban-client status %s 2>/dev/null | awk -F: '/Total banned/{gsub(/[ \\t]/,\"\",$2); print $2}'" % j)
        lines.append("jail «%s»: сейчас забанено %s (всего %s)" % (j, cb or "0", tb or "0"))
    return "\n".join(lines)


def logs_brief(hours):
    nerr = sh("journalctl -u x-ui --since '%d hours ago' --no-pager 2>/dev/null | grep -c ERROR" % hours) or "0"
    nwrn = sh("journalctl -u x-ui --since '%d hours ago' --no-pager 2>/dev/null | grep -c WARNING" % hours) or "0"
    ninf = sh("journalctl -u x-ui --since '%d hours ago' --no-pager 2>/dev/null | grep -c INFO" % hours) or "0"
    verdict = "✅ Ошибок уровня ERROR нет" if nerr.strip() == "0" else "❌ ERROR: %s — список в HTML" % nerr.strip()
    return ("📋 Логи x-ui за %d ч — сервер %s\nERROR: %s · WARNING: %s · INFO: %s\n%s\n"
            "(массовые WARNING про X-Forwarded-For и OCSP — штатные)"
            % (hours, SRVNAME, nerr, nwrn, ninf, verdict))

# ------------------------------------------------------------- клавиатуры --

def kb_main():
    return kbd(
        (btn("🔎 Диагностика сервера", "m:diag"),),
        (btn("🔃 Перезагрузка сервера", "act:reboot"),),
        (btn("🛠 Панель X-UI и Xray", "m:panel"),),
        (btn("🔌 Порты и файрвол", "m:ports"),),
        (btn("📋 Логи", "m:logs"),),
        (btn("⏱ Периодичность отчётов", "act:interval"),),
    )


def kb_diag():
    return kbd(
        (btn("📊 Отчёт о состоянии", "r:status"), btn("🛡 WAL-сторож", "m:wal")),
        (btn("📈 Ресурсы (CPU/RAM/диск)", "r:res"), btn("📌 Эталон", "m:etalon")),
        (btn("🛡 fail2ban", "r:f2b"), btn("📋 Логи", "m:logs")),
        BACK_HOME,
    )


def kb_wal():
    return kbd(
        (btn("🛡 Включить сторож", "wal:on"), btn("⏹ Выключить", "wal:off")),
        (btn("🌐 Полный HTML-отчёт", "r:wal"),),
        BACK_HOME,
    )


def kb_etalon():
    return kbd(
        (btn("🔍 Сравнить с эталоном", "r:etalon"),),
        (btn("💾 Сохранить текущее как эталон", "et:save"),),
        BACK_HOME,
    )


def kb_panel():
    return kbd(
        (btn("📡 Статус панели и Xray", "p:status"),),
        (btn("🔄 Перезапустить панель + Xray", "p:restart"),),
        BACK_HOME,
    )


def kb_ports():
    return kbd(
        (btn("👁 Слушающие порты", "po:list"), btn("🛡 Правила UFW", "po:ufw")),
        (btn("➕ Открыть порт", "po:open"), btn("➖ Закрыть порт", "po:close")),
        BACK_HOME,
    )


def kb_logs():
    return kbd(
        (btn("За 1 час", "lg:1"), btn("За 6 часов", "lg:6"), btn("За 24 часа", "lg:24")),
        (btn("За N часов (ввести)", "lg:ask"),),
        (btn("🧹 Очистка лого journald", "lg:vac"),),
        BACK_HOME,
    )


def kb_res():
    return kbd(
        (btn("🔄 Обновить", "res:upd"), btn("⬅️ Назад", "m:diag"), btn("🏠 Главное меню", "m:home")),
    )


def kb_confirm(yes_cb, no_cb="m:diag"):
    return kbd((btn("✅ Подтвердить", yes_cb), btn("❌ Отмена", no_cb)),)

# --------------------------------------------------- диалоговые состояния --
# STATE["mode"]: None | "reboot_yes" | "logs_hours" | "vac_days" | "interval"
#                | "po_open" | "po_open_yes" | "po_close" | "po_close_yes" | "et_save_yes"
STATE = {"mode": None, "until": 0, "data": {}}


def set_mode(mode, seconds=180, **data):
    STATE["mode"] = mode
    STATE["until"] = time.time() + seconds
    STATE["data"] = data


def clear_mode():
    STATE["mode"] = None
    STATE["data"] = {}


def mode_expired():
    if STATE["mode"] and time.time() > STATE["until"]:
        clear_mode()
        send("⌛ Время ввода истекло, действие отменено.")

# ------------------------------------------------------------- действия ---

def do_status():
    send("⏳ Готовлю отчёт (несколько секунд)...")
    text = brief_status()
    link = gen_report_link("status")
    if link:
        text += "\n\n🌐 Полный отчёт: " + link
    send(text, kbd(BACK_HOME))


def do_resources(msg_id=None):
    text = resources_text()
    if msg_id:
        edit(text, msg_id, kb_res())
    else:
        send(text, kb_res())


def do_wal():
    text, _anom, _last = wal_state()
    send(text, kb_wal())


def do_wal_on():
    out = sh("( crontab -l 2>/dev/null | grep -v 'wal-watch.sh' ; echo '*/5 * * * * %s/wal-watch.sh' ) | crontab - && %s/wal-watch.sh && tail -1 %s"
             % (SCRIPTS, SCRIPTS, WALLOG))
    send("🛡 Сторож включён.\n" + (out or ""), kb_wal())


def do_wal_off():
    sh("crontab -l 2>/dev/null | grep -v 'wal-watch.sh' | crontab -")
    send("⏹ Сторож выключен (лог сохранён). Включить: кнопка «🛡 Включить сторож».", kb_wal())


def do_report(kind, hours=None):
    send("⏳ Готовлю отчёт...")
    if kind == "status":
        return do_status()
    if kind == "wal":
        text, _a, _l = wal_state()
        link = gen_report_link("wal")
        if link:
            text += "\n\n🌐 Полный отчёт: " + link
        send(text, kbd(BACK_HOME))
        return
    if kind == "etalon":
        text = etalon_brief()
        link = gen_report_link("etalon")
        if link:
            text += "\n\n🌐 Полный отчёт (diff): " + link
        send(text, kbd(BACK_HOME))
        return
    if kind == "f2b":
        text = f2b_brief()
        link = gen_report_link("fail2ban")
        if link:
            text += "\n\n🌐 Полный отчёт: " + link
        send(text, kbd(BACK_HOME))
        return
    if kind == "logs":
        hours = hours or 24
        text = logs_brief(hours)
        link = gen_report_link("logs", hours)
        if link:
            text += "\n\n🌐 Полный отчёт: " + link
        send(text, kbd(BACK_HOME))
        return


def do_panel_status():
    act = sh("systemctl is-active x-ui")
    xver = sh("/usr/local/x-ui/bin/xray-linux-amd64 version 2>/dev/null | head -1")
    ports = sh("ss -tulnp 2>/dev/null | grep -E 'nginx|x-ui|xray' | awk '{print $1, $5}' | sort -u | head -20")
    up = sh("systemctl show x-ui -p ActiveEnterTimestamp --value")
    send("🛠 Панель и Xray — сервер %s\n\nx-ui: %s (запущена: %s)\n%s\n\nСлушают:\n%s"
         % (SRVNAME, act, up.strip(), xver, ports), kb_panel())


def do_panel_restart():
    send("🔄 Перезапускаю панель + Xray...")
    sh("systemctl restart x-ui && sleep 3")
    act = sh("systemctl is-active x-ui")
    send("Готово: x-ui = %s" % act, kb_panel())


def do_reboot_ask():
    set_mode("reboot_yes", 120)
    send("⚠️ ПЕРЕЗАГРУЗКА сервера %s!\n"
         "VPN прервётся на 1–3 минуты, все клиенты переподключатся.\n\n"
         "Для подтверждения отправьте текстом: yes (2 минуты на ввод)" % SRVNAME)


def do_reboot():
    clear_mode()
    try:
        open(REBOOT_MARKER, "w").write(str(time.time()))
    except Exception:
        pass
    send("🔃 Сервер перезагружается... После загрузки пришлю подтверждение.")
    sh("nohup bash -c 'sleep 3; systemctl reboot' >/dev/null 2>&1 &")


def do_ports_list():
    out = sh("ss -tulnp 2>/dev/null | grep -E 'nginx|x-ui|xray' | awk '{print $1, $2, $5, $7}' | sort -u")
    send("🔌 Слушающие порты — сервер %s\n\n%s" % (SRVNAME, out[:3500] or "пусто"), kb_ports())


def do_ufw():
    out = sh("ufw status verbose 2>/dev/null || echo 'ufw не установлен/не активен'")
    send("🛡 UFW — сервер %s\n\n%s" % (SRVNAME, out[:3500]), kb_ports())


def do_interval_ask():
    set_mode("interval", 180)
    send("⏱ Сейчас регулярные отчёты приходят каждые %d ч.\n"
         "Введите новое количество часов (число от 1 до 168):" % INTERVAL)


def save_interval(val):
    global INTERVAL
    INTERVAL = val
    set_env_key("REPORT_INTERVAL_HOURS", str(val))
    clear_mode()
    send("✅ Регулярные отчёты: каждые %d ч. Ближайший — через %d ч." % (val, val), kb_main())

# --------------------------------------------------- обработка обновлений --

def auth_ok(user_id):
    return CHAT_INT is not None and user_id == CHAT_INT


def handle_callback(q):
    if not auth_ok(q.get("from", {}).get("id")):
        tg("answerCallbackQuery", callback_query_id=q["id"], text="Нет доступа")
        return
    data = q.get("data", "")
    msg_id = q.get("message", {}).get("message_id")
    tg("answerCallbackQuery", callback_query_id=q["id"])

    if data == "m:home":
        edit("🏠 Главное меню — сервер %s\n\nВыберите раздел:" % SRVNAME, msg_id, kb_main())
    elif data == "m:diag" or data == "m:back":
        edit("🔎 Диагностика сервера %s:" % SRVNAME, msg_id, kb_diag())
    elif data == "m:wal":
        text, _a, _l = wal_state()
        edit(text, msg_id, kb_wal())
    elif data == "m:etalon":
        edit("📌 Эталон сервера %s:" % SRVNAME, msg_id, kb_etalon())
    elif data == "m:panel":
        edit("🛠 Панель X-UI и Xray — сервер %s:" % SRVNAME, msg_id, kb_panel())
    elif data == "m:ports":
        edit("🔌 Порты и файрвол — сервер %s:" % SRVNAME, msg_id, kb_ports())
    elif data == "m:logs":
        edit("📋 Логи x-ui — выбрать период (пришлю КРАТКО + ссылку на полный):", msg_id, kb_logs())
    elif data == "r:status":
        do_status()
    elif data == "r:res" :
        do_resources()
    elif data == "res:upd":
        do_resources(msg_id)
    elif data == "r:wal":
        do_report("wal")
    elif data == "r:etalon":
        do_report("etalon")
    elif data == "r:f2b":
        do_report("f2b")
    elif data == "et:save":
        if os.path.exists(SCRIPTS + "/etalon/etalon.txt"):
            head = sh("head -1 %s/etalon/etalon.txt | sed 's/^# Снимок: //'" % SCRIPTS)
            set_mode("et_save_yes", 120)
            send("⚠️ Эталон уже сохранён: %s\nПерезаписать текущим состоянием? Отправьте: yes" % head)
        else:
            out = sh("bash %s/baseline.sh save" % SCRIPTS)
            send(out or "✅ Эталон сохранён", kb_etalon())
    elif data == "act:reboot":
        do_reboot_ask()
    elif data == "act:interval":
        do_interval_ask()
    elif data == "p:status":
        do_panel_status()
    elif data == "p:restart":
        set_mode("panel_restart_yes", 120, msg_id=msg_id)
        send("⚠️ Перезапустить панель x-ui вместе с Xray на сервере %s?\n"
             "Соединения клиентов прервутся на несколько секунд.\nОтправьте: yes" % SRVNAME)
    elif data == "po:list":
        do_ports_list()
    elif data == "po:ufw":
        do_ufw()
    elif data == "po:open":
        set_mode("po_open", 180)
        send("➕ Открыть порт. Введите одной строкой:\nПОРТ ПРОТОКОЛ КОММЕНТАРИЙ\nнапример: 8443 tcp reality")
    elif data == "po:close":
        rules = sh("ufw status numbered 2>/dev/null | head -30")
        set_mode("po_close", 180)
        send("➖ Закрыть порт. Текущие правила:\n%s\n\nВведите НОМЕР правила для удаления:" % (rules or "правил нет"))
    elif data.startswith("lg:"):
        arg = data.split(":", 1)[1]
        if arg == "ask":
            set_mode("logs_hours", 180)
            send("Введите количество часов для отчёта логов (число, например 12):")
        elif arg == "vac":
            set_mode("vac_days", 180)
            send("🧹 Очистка логов journald (затронет ВСЕ системные логи).\nСколько ДНЕЙ логов оставить? (число, например 7):")
        else:
            try:
                do_report("logs", int(arg))
            except ValueError:
                pass


def handle_text(msg):
    if not auth_ok(msg.get("from", {}).get("id")):
        log("игнорирую сообщение от чужого chat_id: %s" % msg.get("chat", {}).get("id"))
        return
    text = (msg.get("text") or "").strip()
    mode = STATE["mode"]
    mode_expired()

    if text in ("/start", "start", "меню"):
        clear_mode()
        send("🏠 Главное меню — сервер %s (%s)\n\nВыберите раздел:" % (SRVNAME, sh("hostname")), kb_main())
        return

    if mode == "reboot_yes":
        if text.lower() == "yes":
            do_reboot()
        else:
            clear_mode()
            send("Перезагрузка отменена.", kb_main())
        return

    if mode == "panel_restart_yes":
        if text.lower() == "yes":
            clear_mode()
            do_panel_restart()
        else:
            clear_mode()
            send("Перезапуск отменён.", kb_panel())
        return

    if mode == "et_save_yes":
        if text.lower() == "yes":
            out = sh("bash %s/baseline.sh save" % SCRIPTS)
            send((out or "✅ Эталон перезаписан"), kb_etalon())
        else:
            send("Отменено — эталон не изменён.", kb_etalon())
        clear_mode()
        return

    if mode == "logs_hours":
        if re.fullmatch(r"\d{1,4}", text) and 1 <= int(text) <= 720:
            clear_mode()
            do_report("logs", int(text))
        else:
            send("Нужно число часов от 1 до 720. Попробуйте ещё раз:")
        return

    if mode == "vac_days":
        if re.fullmatch(r"\d{1,4}", text):
            out = sh("journalctl --vacuum-time=%sd 2>&1 | tail -2" % text)
            clear_mode()
            send("🧹 Очистка выполнена (оставили %s дн.):\n%s\nНовый размер: %s"
                 % (text, out, sh("journalctl --disk-usage")), kb_logs())
        else:
            send("Нужно число дней. Попробуйте ещё раз:")
        return

    if mode == "interval":
        if re.fullmatch(r"\d{1,3}", text) and 1 <= int(text) <= 168:
            save_interval(int(text))
        else:
            send("Нужно число от 1 до 168. Попробуйте ещё раз:")
        return

    if mode == "po_open":
        parts = text.split(None, 2)
        if len(parts) >= 2 and re.fullmatch(r"\d{1,5}", parts[0]) and parts[1] in ("tcp", "udp"):
            port, proto = parts[0], parts[1]
            comment = re.sub(r"[^A-Za-z0-9 _.-]", "", parts[2] if len(parts) > 2 else "tg-bot")[:40]
            set_mode("po_open_yes", 120, cmd="ufw allow %s/%s comment '%s' && ufw reload" % (port, proto, comment))
            send("Будет выполнено:\n  ufw allow %s/%s comment '%s'\n  ufw reload\n\nОтправьте yes для подтверждения:" % (port, proto, comment))
        else:
            send("Формат: ПОРТ ПРОТОКОЛ КОММЕНТАРИЙ (например: 8443 tcp reality). Ещё раз:")
        return

    if mode == "po_open_yes":
        if text.lower() == "yes":
            out = sh(STATE["data"].get("cmd", ""))
            send("✅ Выполнено.\n%s\n\n%s" % (out or "", sh("ufw status | tail -5")), kb_ports())
        else:
            send("Отменено.", kb_ports())
        clear_mode()
        return

    if mode == "po_close":
        if re.fullmatch(r"\d{1,3}", text):
            rule = sh("ufw status numbered | grep -E '^\\[ *%s\\]'" % text)
            warn = "\n⚠️ ВНИМАНИЕ: правило похоже на SSH (22/tcp) — можно потерять доступ!\n" if "22/tcp" in rule else ""
            set_mode("po_close_yes", 120, num=text)
            send("Будет удалено правило:\n%s\n%s\nОтправьте yes для подтверждения:" % (rule or "(не найдено)", warn))
        else:
            send("Нужен номер правила (число). Ещё раз:")
        return

    if mode == "po_close_yes":
        if text.lower() == "yes":
            num = STATE["data"].get("num", "")
            out = sh("ufw --force delete %s && ufw reload" % num)
            send("✅ Правило %s удалено.\n%s" % (num, out or ""), kb_ports())
        else:
            send("Отменено.", kb_ports())
        clear_mode()
        return

    if text in ("статус", "status"):
        do_status()
        return

    send("Я понимаю кнопки меню, а также команды: /start (меню), статус.\n"
         "Сейчас режим ввода: %s" % (mode or "нет"), kb_main())

# ------------------------------------------------- фоновые проверки -------

def wal_watch_check(prev):
    """Проверяет последнюю строку лога сторожа; возвращает новое состояние.
    Шлёт алерт только при СМЕНЕ состояния (требование §6.6)."""
    if not os.path.exists(WALLOG):
        return prev
    last = sh("tail -1 %s" % WALLOG)
    if not last:
        return prev
    bad = ("DELETED" in last) or bool(re.search(r"err5m=[1-9]", last)) or ("wal=-" in last)
    if bad and not prev:
        send("🔴🔴 АВАРИЯ: WAL-сторож обнаружил проблему на сервере %s!\n%s\n\n"
             "Срочно проверьте панель (вероятно, повреждение БД)." % (SRVNAME, last))
    elif (not bad) and prev:
        send("🟢 Отбой: WAL-сторож снова в норме (сервер %s).\n%s" % (SRVNAME, last))
    return bad


def daily_alive():
    total = sh("wc -l < %s 2>/dev/null" % WALLOG) or "0"
    anom = sh("grep -cE 'DELETED|err5m=[1-9]|wal=-' %s 2>/dev/null" % WALLOG) or "0"
    up = sh("uptime -p | sed 's/up //'")
    send("🟢 Контрольное «жив» — сервер %s\nСторож: замеров %s, аномалий %s\n"
         "Панель: %s · Аптайм: %s" % (SRVNAME, total.strip(), anom.strip(),
                                      sh("systemctl is-active x-ui"), up))

# ---------------------------------------------------------------- main ----

def main():
    global INTERVAL
    if ENV.get("TG_ENABLED", "1") != "1":
        log("TG_ENABLED != 1 — бот выключен настройкой. Выход.")
        sys.exit(0)
    if not TOKEN or CHAT_INT is None:
        log("В %s нет BOT_TOKEN или CHAT_ID — заполните файл. Выход." % ENVF)
        sys.exit(1)

    me = tg("getMe")
    if not me.get("ok"):
        log("getMe не прошёл — проверьте BOT_TOKEN. Выход.")
        sys.exit(1)
    log("Бот запущен: @%s, сервер %s, интервал отчётов %d ч" % (me["result"].get("username"), SRVNAME, INTERVAL))

    # Стартовое сообщение (в т.ч. уведомление после перезагрузки)
    if os.path.exists(REBOOT_MARKER):
        try:
            os.remove(REBOOT_MARKER)
        except Exception:
            pass
        send("🟢 Сервер %s ПЕРЕЗАГРУЖЕН (по команде из бота) и снова работает.\n"
             "Аптайм: %s · Панель: %s" % (SRVNAME, sh("uptime -p | sed 's/up //'"), sh("systemctl is-active x-ui")))
    else:
        send("🟢 Бот диагностики запущен — сервер %s.\nНажмите /start для меню." % SRVNAME)

    offset = 0
    next_report = time.time() + INTERVAL * 3600
    next_alive = None  # посчитаем ниже: ежедневно 09:00 МСК = 06:00 UTC
    wal_bad = False
    last_wal_check = 0.0
    last_interval_seen = INTERVAL

    while True:
        try:
            r = tg("getUpdates", offset=offset, timeout=25,
                   allowed_updates=["message", "callback_query"])
            for u in r.get("result", []):
                offset = u["update_id"] + 1
                try:
                    if "callback_query" in u:
                        handle_callback(u["callback_query"])
                    elif "message" in u:
                        handle_text(u["message"])
                except Exception as e:
                    log("ошибка обработки: %r" % e)
                    try:
                        send("⚠️ Ошибка при обработке команды: %r" % e)
                    except Exception:
                        pass
        except Exception as e:
            log("ошибка getUpdates: %r" % e)
            time.sleep(5)

        now = time.time()

        # смена интервала (мог поменять другой процесс/владельца правка .env)
        env_now = load_env()
        try:
            iv = max(1, min(168, int(env_now.get("REPORT_INTERVAL_HOURS", INTERVAL))))
        except ValueError:
            iv = INTERVAL
        if iv != last_interval_seen:
            INTERVAL = iv
            last_interval_seen = iv
            next_report = now + INTERVAL * 3600
            log("интервал отчётов изменён на %d ч" % INTERVAL)

        # сторож — раз в минуту
        if now - last_wal_check >= 60:
            last_wal_check = now
            try:
                wal_bad = wal_watch_check(wal_bad)
            except Exception as e:
                log("wal check: %r" % e)

        # регулярный отчёт
        if now >= next_report:
            next_report = now + INTERVAL * 3600
            try:
                text = brief_status()
                link = gen_report_link("status")
                if link:
                    text += "\n\n🌐 Полный отчёт: " + link
                send("⏰ Регулярный отчёт (каждые %d ч):\n\n%s" % (INTERVAL, text), kbd(BACK_HOME))
            except Exception as e:
                log("periodic report: %r" % e)

        # «жив» ежедневно в 09:00 МСК (06:00 UTC)
        utcnow = datetime.datetime.utcnow()
        today_alive = utcnow.replace(hour=6, minute=0, second=0, microsecond=0)
        if utcnow >= today_alive:
            if next_alive is None or next_alive <= now:
                next_alive = time.time() + 24 * 3600 - ((utcnow - today_alive).total_seconds() % 86400)
                if (utcnow - today_alive).total_seconds() < 300:  # не более 5 мин назад
                    try:
                        daily_alive()
                    except Exception as e:
                        log("daily alive: %r" % e)


if __name__ == "__main__":
    main()
