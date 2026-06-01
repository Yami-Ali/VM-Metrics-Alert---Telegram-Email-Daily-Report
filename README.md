# VM Metrics Reporter

A lightweight monitoring agent for **Linux** (Bash) and **Windows** (PowerShell) VMs. Every minute it checks disk and RAM usage and decides whether to send an alert based on configurable thresholds and cooldown timers. Alerts are routed through a single central **n8n** server — **Telegram** for critical disk issues, **Email** for everything else. A **daily consolidated report** covering all monitored VMs (Linux and Windows mixed) is sent every morning.

---

## Quick Install

Pick the right command for your VM's OS, run it once, and follow the 4-step wizard.

---

### 🐧 Linux

> Requires: Ubuntu 20.04+ or Debian 10+ — run as **root** or with **sudo**

```bash
bash <(curl -fsSL https://gist.githubusercontent.com/Yami-Ali/de460e9b35a727e1257f08e93a90ce5b/raw/c089243fcae2ed1e2f4d7e1ac9aefb16ef43ce39/install.sh)
```

This command:
1. Uninstalls any existing installation (safe to re-run)
2. Downloads the script from this repository
3. Runs the install wizard

---

### 🪟 Windows

> Requires: Windows 10 / 11 / Server 2016 / 2019 / 2022 — open **PowerShell as Administrator**

```powershell
$p="$env:TEMP\vm_w.ps1"; $b=(Invoke-WebRequest "https://raw.githubusercontent.com/Yami-Ali/vm-metrics-windows/main/vm_metrics_reporter_windows.ps1" -UseBasicParsing).RawContentStream.ToArray(); if($b[0] -ne 0xEF){$b=[byte[]](0xEF,0xBB,0xBF)+$b}; [System.IO.File]::WriteAllBytes($p,$b); PowerShell -ExecutionPolicy Bypass -File $p --install
```

This command:
1. Downloads the script from the [vm-metrics-windows](https://github.com/Yami-Ali/vm-metrics-windows) repository
2. Preserves correct UTF-8 encoding (required for emoji support in alerts)
3. Runs the install wizard
4. Creates two Task Scheduler tasks under the SYSTEM account

---

### Install Wizard — 4 Steps (both OS)

| Step | What it configures |
|------|--------------------|
| 1 — Network Version | Old / New / Old & New |
| 2 — VM Owner | Primary `To:` email recipient |
| 3 — CC Recipients | Additional addresses (optional, press Enter to skip) |
| 4 — VM Identity | Display name and physical location (e.g. `Rack-A Hilla DC1`) |

---

## How It Works

```
┌─────────────────────────────┐     ┌──────────────────────────────┐
│         Linux VM            │     │        Windows VM            │
│                             │     │                              │
│  cron (every minute)        │     │  Task Scheduler (every min)  │
│  └─ vm_metrics_reporter.sh  │     │  └─ vm_metrics_reporter_     │
│       --run                 │     │       windows.ps1  --run     │
│                             │     │                              │
│  • Checks disk /            │     │  • Checks all drives C: D:…  │
│  • Checks RAM               │     │  • Checks RAM                │
│  • Compares thresholds      │     │  • Compares thresholds       │
│  • Checks cooldown timer    │     │  • Checks cooldown timer     │
│  └─ POST JSON to webhook ───┼─────┼──► POST JSON to webhook      │
└─────────────────────────────┘     └──────────────────────────────┘
                                                │
                                                ▼
                                   ┌────────────────────────┐
                                   │       n8n Server       │
                                   │                        │
                                   │  ALERT FLOW            │
                                   │  1. Webhook            │
                                   │  2. Alert or Daily?    │
                                   │  3. Save to MySQL      │
                                   │  4. Process Metrics    │
                                   │  5. Disk >= 90%?       │
                                   │     ├─ YES → Telegram  │
                                   │     │      → Email     │
                                   │     └─ NO  → Email     │
                                   │                        │
                                   │  DAILY REPORT FLOW     │
                                   │  1. Schedule 7:59 AM   │
                                   │  2. Read from MySQL    │
                                   │  3. Build Report       │
                                   │  4. Email + Telegram   │
                                   │  5. Clear MySQL table  │
                                   └────────────────────────┘
```

---

## Alert Thresholds

Same thresholds on both Linux and Windows.

### Disk

| Threshold | Severity     | Repeat Every | Channel          |
|-----------|--------------|--------------|------------------|
| >= 90%    | 🔴 CRITICAL  | 1 hour       | Telegram + Email |
| >= 80%    | 🟠 WARNING   | 6 hours      | Email only       |
| >= 70%    | 🟡 NOTICE    | 12 hours     | Email only       |
| >= 60%    | 🔵 INFO      | 24 hours     | Email only       |
| < 60%     | ✅ OK        | No alert     | —                |

> **Linux** monitors the root partition `/` only.
> **Windows** monitors every drive independently — C:, D:, E: each have their own timers.

### RAM

Single threshold — if usage exceeds **80%**, an email is sent once every **24 hours**.

---

## Linux

### Files on the Machine

```
/opt/vm-metrics/
├── vm_metrics_reporter.sh        ← installed script
└── state/
    ├── disk_tier_60              ← timestamp of last alert at >=60%
    ├── disk_tier_70              ← timestamp of last alert at >=70%
    ├── disk_tier_80              ← timestamp of last alert at >=80%
    ├── disk_tier_90              ← timestamp of last alert at >=90%
    └── ram_alert                 ← timestamp of last RAM alert

/var/log/vm_metrics_reporter.log  ← all activity logs
/etc/cron.d/vm_metrics_reporter   ← cron job (every minute + daily at 7:59 AM)
/tmp/vm_metrics_reporter.lock     ← run lock (auto-removed after each run)
```

### Commands

```bash
# Check status — config + live snapshot + last alert times + last 20 log lines
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --status

# Force send — clear all timers and send a real alert immediately
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --force

# Simulate alert — test with fake disk/RAM values (safe, no state changes)
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --simulate 92 50   # CRITICAL → Telegram + Email
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --simulate 85 75   # WARNING  → Email only
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --simulate 72 50   # NOTICE   → Email only
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --simulate 65 50   # INFO     → Email only
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --simulate 50 85   # RAM only → Email only
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --simulate 5 50    # Nothing sent (below all tiers)

# Simulate daily report
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --simulate-daily
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --simulate-daily 85 70
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --simulate-daily 92 50

# Uninstall — removes script, cron job, state files, log, lock
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --uninstall
```

### Update

Re-run the Quick Install command — it uninstalls the old version automatically before installing the new one.

### Logs

```bash
# Watch live
tail -f /var/log/vm_metrics_reporter.log

# View last 20 lines
tail -20 /var/log/vm_metrics_reporter.log
```

### Troubleshooting (Linux)

**No alerts arriving**
```bash
curl -s http://YOUR_N8N_SERVER:5678/healthz
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --force
tail -20 /var/log/vm_metrics_reporter.log
```

**Script stuck / won't run**
```bash
sudo rm -rf /tmp/vm_metrics_reporter.lock
```

**Reset alert timers**
```bash
sudo rm -f /opt/vm-metrics/state/*
```

**Check state file timestamps**
```bash
for f in /opt/vm-metrics/state/*; do
    echo "$f → $(date -d @$(cat $f) '+%Y-%m-%d %H:%M:%S')"
done
```

**Daily report not arriving**

Check the MySQL table — if empty, no VMs sent data that day:
```bash
docker exec -it n8n_db mysql -u mysql -pmysql n8n -e "SELECT * FROM vm_reports;"
```
Then run `--simulate-daily` to test the full flow.

**Timestamps showing wrong time**

Set timezone in `docker-compose.yml` and restart n8n:
```yaml
environment:
  - GENERIC_TIMEZONE=Asia/Baghdad
  - TZ=Asia/Baghdad
```

---

## Windows

### Files on the Machine

```
C:\Program Files\vm-metrics\
└── vm_metrics_reporter_windows.ps1     ← installed script

C:\ProgramData\vm-metrics\
├── vm_metrics.log                      ← all activity logs
├── run.lock                            ← run lock (auto-removed after each run)
└── state\
    ├── disk_C_tier_90                  ← last alert: C: at >=90%
    ├── disk_C_tier_80                  ← last alert: C: at >=80%
    ├── disk_C_tier_70                  ← last alert: C: at >=70%
    ├── disk_C_tier_60                  ← last alert: C: at >=60%
    ├── disk_D_tier_90                  ← per-drive, per-tier (created as needed)
    └── ram_alert                       ← last RAM alert timestamp

Task Scheduler\
├── VM-Metrics-Run                      ← every minute → --run
└── VM-Metrics-Daily                    ← daily at 7:59 AM → --daily
```

### Commands

All commands must be run in **PowerShell as Administrator**.

```powershell
# Check status — config + live snapshot of all drives + last alert times
PowerShell -ExecutionPolicy Bypass -File "C:\Program Files\vm-metrics\vm_metrics_reporter_windows.ps1" --status

# Force send — clear all timers and send a real alert immediately
PowerShell -ExecutionPolicy Bypass -File "C:\Program Files\vm-metrics\vm_metrics_reporter_windows.ps1" --force

# Simulate alert — C: overridden with fake %, all other drives show real values
PowerShell -ExecutionPolicy Bypass -File "C:\Program Files\vm-metrics\vm_metrics_reporter_windows.ps1" --simulate 92 50   # CRITICAL → Telegram + Email
PowerShell -ExecutionPolicy Bypass -File "C:\Program Files\vm-metrics\vm_metrics_reporter_windows.ps1" --simulate 85 75   # WARNING  → Email only
PowerShell -ExecutionPolicy Bypass -File "C:\Program Files\vm-metrics\vm_metrics_reporter_windows.ps1" --simulate 72 50   # NOTICE   → Email only
PowerShell -ExecutionPolicy Bypass -File "C:\Program Files\vm-metrics\vm_metrics_reporter_windows.ps1" --simulate 65 50   # INFO     → Email only
PowerShell -ExecutionPolicy Bypass -File "C:\Program Files\vm-metrics\vm_metrics_reporter_windows.ps1" --simulate 50 85   # RAM only → Email only

# Simulate daily report
PowerShell -ExecutionPolicy Bypass -File "C:\Program Files\vm-metrics\vm_metrics_reporter_windows.ps1" --simulate-daily
PowerShell -ExecutionPolicy Bypass -File "C:\Program Files\vm-metrics\vm_metrics_reporter_windows.ps1" --simulate-daily 85 70
PowerShell -ExecutionPolicy Bypass -File "C:\Program Files\vm-metrics\vm_metrics_reporter_windows.ps1" --simulate-daily 92 50

# Uninstall — removes tasks, script, state files, log
PowerShell -ExecutionPolicy Bypass -File "C:\Program Files\vm-metrics\vm_metrics_reporter_windows.ps1" --uninstall
```

### Update / Re-install

Run both steps in **PowerShell as Administrator**:

**Step 1 — Uninstall:**
```powershell
PowerShell -ExecutionPolicy Bypass -File "C:\Program Files\vm-metrics\vm_metrics_reporter_windows.ps1" --uninstall
```

**Step 2 — Download and install latest:**
```powershell
$p="$env:TEMP\vm_w.ps1"; $b=(Invoke-WebRequest "https://raw.githubusercontent.com/Yami-Ali/vm-metrics-windows/main/vm_metrics_reporter_windows.ps1" -UseBasicParsing).RawContentStream.ToArray(); if($b[0] -ne 0xEF){$b=[byte[]](0xEF,0xBB,0xBF)+$b}; [System.IO.File]::WriteAllBytes($p,$b); PowerShell -ExecutionPolicy Bypass -File $p --install
```

### Logs

```powershell
# Watch live
Get-Content "C:\ProgramData\vm-metrics\vm_metrics.log" -Tail 20 -Wait

# View last 20 lines
Get-Content "C:\ProgramData\vm-metrics\vm_metrics.log" -Tail 20
```

### Troubleshooting (Windows)

**Execution policy error**

Always use `PowerShell -ExecutionPolicy Bypass -File "..."` — do not use `& "..."` in a restricted shell.

**No alerts arriving**
```powershell
Get-ScheduledTask -TaskName "VM-Metrics-Run"
PowerShell -ExecutionPolicy Bypass -File "C:\Program Files\vm-metrics\vm_metrics_reporter_windows.ps1" --force
Get-Content "C:\ProgramData\vm-metrics\vm_metrics.log" -Tail 20
```

**Wrong IP address shown**

The script picks the adapter with an active default gateway — VMware, VPN, and TAP virtual adapters are automatically skipped. Run `--status` to see which IP is detected. If still wrong, run `ipconfig` and confirm which adapter has the correct default gateway set.

**Script stuck / won't run**
```powershell
Remove-Item "C:\ProgramData\vm-metrics\run.lock" -Force -ErrorAction SilentlyContinue
```

**Reset alert timers**
```powershell
# View last alert times
Get-ChildItem "C:\ProgramData\vm-metrics\state\" | ForEach-Object {
    $ts = Get-Content $_.FullName
    "$($_.Name) → $([DateTimeOffset]::FromUnixTimeSeconds($ts).LocalDateTime)"
}

# Reset all timers
Remove-Item "C:\ProgramData\vm-metrics\state\*" -Force
```

**Daily report not arriving**
```powershell
PowerShell -ExecutionPolicy Bypass -File "C:\Program Files\vm-metrics\vm_metrics_reporter_windows.ps1" --simulate-daily
```
If simulate works but scheduled report doesn't — open Task Scheduler, find `VM-Metrics-Daily`, confirm it is enabled and last run result is `0x0`.

---

## Notifications

### Telegram Message (CRITICAL — disk >= 90% on any drive)

```
🚨 VM INFRASTRUCTURE MONITOR
──────────────────────────────────────────────
💻 PROD-SERVER-01   📍 Rack-A Hilla DC1
🌐 IP: 192.168.1.50   🕓 2026-05-13 11:00:00 AM
👤 Owner: Ali Yami (ali@company.com)   🔗 Network: new
🪟 OS: Windows   Status: 🟥 CRITICAL
──────────────────────────────────────────────
💾 RAM USAGE
████████░░░░░░░░░░░░  42%
Used: 13.3 GB  |  Free: 18.4 GB  |  Total: 31.7 GB

💿 DISK USAGE (All Drives)
C:  ████████████████████  92%
Used: 92.0 GB  |  Free: 8.0 GB  |  Total: 100.0 GB

D:  ████░░░░░░░░░░░░░░░░  22%
Used: 220 GB  |  Free: 780 GB  |  Total: 1000 GB
──────────────────────────────────────────────
⚠️ ACTIVE ISSUES
🟥 Drive C: at 92% -8.0GB free of 100.0GB (repeats every 1h)
──────────────────────────────────────────────
VM Metrics Reporter – Auto-generated alert
```

> Linux shows a single `💿 DISK USAGE (/)` block instead of per-drive.

### Alert Email

Sent for all severity levels (CRITICAL, WARNING, NOTICE, INFO). The header color matches severity (red / orange / yellow / blue / green). Body includes:
- VM name, IP, location, OS badge, status
- RAM usage bar + exact GB values
- Disk usage bar per drive (Windows) or for `/` (Linux)
- Active issues list with repeat intervals

### Daily Report Email

Sent every morning at **7:59 AM**. One consolidated HTML table covering every Linux and Windows VM that sent data that day — hostname, IP, OS icon, status color, RAM bar, disk bar (worst drive), active issues, and timestamp per row.

---

## n8n Workflow Setup

One workflow handles both Linux and Windows VMs.

### Import

1. In n8n go to **Workflows → Import**
2. Import `VM Metrics Alert - Telegram & Email & Daily Report.json`
3. Open the workflow and activate it
4. Copy the **Webhook** node's Production URL
5. Paste that URL as `N8N_WEBHOOK_URL` in each script before installing

### Workflow Nodes

#### Alert Flow

| Node | What it does |
|------|-------------|
| **Webhook** | Receives POST from the script. HTTP Method: POST, Respond: Immediately |
| **Alert or Daily?** | Routes on `is_daily` — `true` → daily path, `false` → alert path |
| **Prepare VM for MySQL** | Formats VM data into a clean row for DB insert |
| **Save VM to MySQL** | Inserts current metrics into the `vm_reports` table |
| **Process Metrics** | Parses payload, builds Telegram message + email HTML, determines severity, OS badge, per-drive disk blocks |
| **Disk >= 90%?** | CRITICAL → Telegram + Email, otherwise Email only |
| **Telegram Alert** | Sends HTML-formatted message with progress bars (`parse_mode: HTML`) |
| **Email Alert** | Sends HTML email to owner + CC. `appendAttribution: false` |

#### Daily Report Flow

| Node | What it does |
|------|-------------|
| **Schedule Trigger** | Fires at 7:59 AM every day |
| **Read VMs from MySQL** | Reads all rows from `vm_reports` |
| **Build Consolidated Report** | Builds HTML table — one row per VM with OS icon, status, bars, issues, timestamp |
| **Has Data?** | Skips sending if no VMs reported that day |
| **Send Daily Report Email** | Sends consolidated report to configured addresses |
| **Telegram Daily Report** | Sends Telegram summary |
| **Clear VMs from MySQL** | Runs `DELETE FROM vm_reports` — resets for next day |

### Email Node Fields

```
From:    coren8n@yourdomain.com
To:      {{ $json.ownerEmail }}
Subject: {{ $json.emailSubject }}
CC:      {{ $json.ccEmails }}
```

### Telegram Bot Setup

1. Message **@BotFather** on Telegram → create a bot → copy the **token**
2. Message **@userinfobot** → copy your **Chat ID**
3. Add both to the Telegram credential in n8n

---

## MySQL Setup

The daily report requires a MySQL container reachable by n8n. Run once on the n8n host:

```bash
docker run -d \
  --name n8n_db \
  --restart unless-stopped \
  --network <your-docker-network> \
  -e MYSQL_ROOT_PASSWORD=<root-pass> \
  -e MYSQL_DATABASE=<db-name> \
  -e MYSQL_USER=<db-user> \
  -e MYSQL_PASSWORD=<db-pass> \
  -v mysql_data:/var/lib/mysql \
  mysql:8.0
```

> Change `--network` to match your n8n container's Docker network.

Once running, create a **MySQL credential** in n8n with the same values and click **Test Connection**.

The `vm_reports` table is created automatically on first use. It stores one row per VM per day and is cleared every morning after the daily report is sent.

---

## Timezone Setup

If timestamps or the daily report schedule show the wrong time, set the timezone in `docker-compose.yml`:

```yaml
environment:
  - GENERIC_TIMEZONE=Asia/Baghdad
  - TZ=Asia/Baghdad
```

Then restart n8n:

```bash
docker compose down
docker compose up -d
```

Linux VMs set their timezone automatically during install (`Asia/Baghdad` via `timedatectl`).

Windows VMs use the **Arabian Standard Time** timezone zone for timestamps.

---

## Comparison Table

| Feature | 🐧 Linux | 🪟 Windows |
|---------|----------|------------|
| Script | `vm_metrics_reporter.sh` (Bash) | `vm_metrics_reporter_windows.ps1` (PowerShell) |
| OS support | Ubuntu 20.04+ / Debian 10+ | Win 10 / 11 / Server 2016–2022 |
| Disk monitoring | Root `/` only | All drives (C:, D:, E: ...) each independently |
| Scheduler | cron (`/etc/cron.d/`) | Task Scheduler (SYSTEM account) |
| Install path | `/opt/vm-metrics/` | `C:\Program Files\vm-metrics\` |
| State files | `/opt/vm-metrics/state/` | `C:\ProgramData\vm-metrics\state\` |
| Log file | `/var/log/vm_metrics_reporter.log` | `C:\ProgramData\vm-metrics\vm_metrics.log` |
| n8n workflow | ✅ Shared | ✅ Shared |
| MySQL | ✅ Shared | ✅ Shared |
| Telegram | ✅ | ✅ |
| Email | ✅ | ✅ |
| Daily report | ✅ | ✅ |

---

## Repository Structure

```
vm_metrics_reporter .sh                                  ← Linux monitoring script (Bash)
vm_metrics_reporter_windows.ps1                          ← Windows monitoring script (PowerShell)
VM Metrics Alert - Telegram & Email & Daily Report.json  ← n8n workflow export
mysql-compose.bash                                       ← MySQL Docker run command
```

---

## License

This project is private. All rights reserved.
