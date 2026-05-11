# VM Metrics Reporter

A lightweight Bash monitoring agent installed on each Linux VM. Every minute it checks disk and RAM usage and decides whether to send an alert based on configurable thresholds and cooldown intervals. Alerts are routed through a central **n8n** server — **Telegram** for critical disk issues, **Email** for everything else. A **daily consolidated report** covering all monitored VMs is sent every morning.

---

## System Flow

```
┌──────────────────────────────────────────┐
│              Linux VM                    │
│                                          │
│  Cron (every minute)                     │
│       │                                  │
│       ▼                                  │
│  vm_metrics_reporter.sh --run            │
│       │                                  │
│       ├─ Collect disk % and RAM %        │
│       ├─ Check against thresholds        │
│       ├─ Check if interval has elapsed   │
│       │                                  │
│       ├─ NO  → skip silently             │
│       └─ YES → POST JSON to webhook ─────┼──────────────────────┐
└──────────────────────────────────────────┘                      │
                                                                  ▼
                                                   ┌─────────────────────────┐
                                                   │       n8n Server        │
                                                   │                         │
                                                   │  ALERT FLOW             │
                                                   │  1. Webhook             │
                                                   │  2. Alert or Daily?     │
                                                   │                         │
                                                   │  is_daily = false       │
                                                   │  3. Save VM to MySQL    │
                                                   │  4. Process Metrics     │
                                                   │  5. Disk >= 90%?        │
                                                   │     ├─ YES → Telegram   │
                                                   │     │      → Email      │
                                                   │     └─ NO  → Email only │
                                                   │                         │
                                                   │  DAILY REPORT FLOW      │
                                                   │  1. Schedule (8:00 AM)  │
                                                   │  2. Read VMs from MySQL │
                                                   │  3. Build Report        │
                                                   │  4. Has Data?           │
                                                   │     ├─ YES → Email      │
                                                   │     │      → Telegram   │
                                                   │     └─ NO  → skip       │
                                                   │  5. Clear MySQL table   │
                                                   └─────────────────────────┘
```

---

## Alert Thresholds

### Disk

The highest matching tier wins.

| Threshold | Severity     | Repeat Every | Channel          |
|-----------|--------------|-------------|------------------|
| >= 90%    | 🔴 CRITICAL  | 1 hour      | Telegram + Email |
| >= 80%    | 🟠 WARNING   | 6 hours     | Email            |
| >= 70%    | 🟡 NOTICE    | 12 hours    | Email            |
| >= 60%    | 🔵 INFO      | 24 hours    | Email            |
| < 60%     | ✅ OK        | No alert    | —                |

### RAM

Single threshold — if usage exceeds **80%**, an email is sent once every **24 hours**.

---

## Script Internal Flow

```
Cron fires
    │
    ▼
Acquire run lock
    ├─ Another instance still running? → exit silently
    └─ OK to proceed
            │
            ▼
    Collect disk % (df /) and RAM % (free -m)
            │
            ▼
    Find matching disk tier
    ├─ Below all tiers (<60%)? → clear state, skip
    ├─ Interval = 0? (test mode) → always send
    ├─ No state file? (first run) → send now, create file
    ├─ Time elapsed < interval? → log "next in ~Nh", skip
    └─ Time elapsed >= interval? → update timestamp → SEND
            │
            ▼
    Check RAM threshold (>80%)
    └─ Same timer logic as disk
            │
            ▼
    Nothing to send? → exit silently
            │
            ▼
    Build JSON payload → curl POST → n8n
            │
            ▼
    Log result → release lock
```

---

## Files on the Machine (after install)

```
/opt/vm-metrics/
├── vm_metrics_reporter.sh        ← installed script
└── state/
    ├── disk_tier_60              ← timestamp of last alert at >=60% tier
    ├── disk_tier_70              ← timestamp of last alert at >=70% tier
    ├── disk_tier_80              ← timestamp of last alert at >=80% tier
    ├── disk_tier_90              ← timestamp of last alert at >=90% tier
    └── ram_alert                 ← timestamp of last RAM alert

/var/log/vm_metrics_reporter.log  ← all activity logs
/etc/cron.d/vm_metrics_reporter   ← cron job (fires every minute + daily at 7:59 AM)
/tmp/vm_metrics_reporter.lock     ← run lock (auto-removed after each run)
```

Each state file holds a single Unix timestamp — the last time an alert was sent for that tier.

---

## Prerequisites

### On each VM
- Ubuntu 20.04+ or Debian 10+
- `curl`, `free`, `df`, `awk`, `ip`, `sed` (standard on most distros)
- `cron` daemon running

### n8n Server
- n8n instance with:
  - **MySQL** connector (for daily report snapshots)
  - **SMTP Email** connector
  - **Telegram Bot** connector
  - **Webhook** node to receive metrics

---

## Installation

### Step 1 — Edit the script before installing

Open the script and update the `USERS` list and `N8N_WEBHOOK_URL` to your n8n webhook Production URL:

```bash
nano ~/vm_metrics_reporter.sh
```

Key values to set:

```bash
# Paste your n8n webhook Production URL here
N8N_WEBHOOK_URL="http://YOUR_N8N_SERVER:5678/webhook/YOUR_WEBHOOK_ID"

# Add your team members in "Full Name:email@domain.com" format
USERS=(
    "John Smith:john.smith@company.com",
    "Jane Doe:jane.doe@company.com"
)
```

### Step 2 — Run the install wizard

```bash
sudo bash vm_metrics_reporter.sh --install
```

The wizard walks through 4 steps:

| Step | What it configures |
|------|--------------------|
| 1 — Network Version | Old / New / Old & New Network |
| 2 — VM Owner | Primary `To:` email recipient |
| 3 — CC Recipients | Additional addresses (optional, press Enter to skip) |
| 4 — VM Identity | Display name and physical location (e.g. `Rack-A Hilla DC1`) |

> Re-running `--install` is safe at any time — it updates the configuration without reinstalling from scratch.

### Step 3 — Verify the installation

```bash
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --status
```

Expected output:

```
========================================================
  VM Metrics Reporter — Status
========================================================
  Script:   ✅ /opt/vm-metrics/vm_metrics_reporter.sh
  Cron:     ✅ Active
  Webhook:  http://192.168.x.x:5678/webhook/...

  Configuration:
    VM Name:     prod-server-01
    Location:    Rack-A Hilla DC1
    Network:     new
    Owner (To:): John Smith <john.smith@company.com>
    CC:          admin@company.com

  --- Live Snapshot ---
    RAM:      21.4% | 1.65GB used / 7.71GB total
    Disk (/): 46% used (26G free of 49G)
    Disk Tier: ✅ OK (< 60% — no alert)
```

If cron shows ✅ Active and the snapshot looks correct, the installation is complete.

---

## Commands

### Status

Show current config, live disk/RAM snapshot, last alert timestamps, and last 20 log lines.

```bash
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --status
```

### Force Send

Clear all timers and send a real alert immediately, regardless of intervals.

```bash
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --force
```

### Simulate — Alert

Send a test alert with fake disk and RAM values. Does **not** touch real state files or timers — safe to run any time.

```bash
# Syntax: --simulate [disk%] [ram%]

sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --simulate 92 50   # CRITICAL → Telegram + Email
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --simulate 85 75   # WARNING  → Email only
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --simulate 72 50   # NOTICE   → Email only
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --simulate 65 50   # INFO     → Email only
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --simulate 50 85   # RAM only → Email only
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --simulate 5 50    # Nothing sent (below all tiers)
```

### Simulate — Daily Report

Send a test daily report with fake data. Uses `is_daily=true` so n8n routes it through the daily report flow.

```bash
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --simulate-daily           # OK status
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --simulate-daily 85 70     # High disk
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --simulate-daily 92 50     # CRITICAL disk
```

### Uninstall

Remove everything the script created on this machine (script, state files, cron job, log file, lock directory).

```bash
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --uninstall
```

Verify it is clean:

```bash
ls /opt/
ls /etc/cron.d/
ls /var/log/ | grep vm_metrics
```

---

## n8n Workflow Setup

### Import the workflow

1. In n8n, go to **Settings → Import Workflow**
2. Import `VM Metrics Alert - Telegram & Email & Daily Report.json`
3. Activate the workflow
4. Copy the **Webhook** node's Production URL and paste it into `N8N_WEBHOOK_URL` in the script

### Alert Flow Nodes

| Node | Type | What it does |
|------|------|-------------|
| **Webhook** | Webhook | Receives POST from the script. HTTP Method: POST, Respond: Immediately |
| **Alert or Daily?** | IF | Routes on `is_daily` — `true` → daily path, `false` → alert path |
| **Prepare VM for MySQL** | Code | Formats VM data into a clean row for DB insert |
| **Save VM to MySQL** | executeQuery | Inserts current metrics into the `vm_reports` table |
| **Process Metrics** | Code | Parses payload, builds Telegram message, email subject, severity color, owner/CC fields |
| **Disk >= 90%?** | IF | Routes to Telegram + Email if critical, Email only otherwise |
| **Telegram Alert** | Telegram | Sends HTML-formatted message with progress bars. Uses `parse_mode: HTML` |
| **Email Alert** | Email | Sends HTML template to owner + CC. `appendAttribution: false` removes n8n branding |

Email fields:
```
To:      {{ $json.ownerEmail }}
Subject: {{ $json.emailSubject }}
CC:      {{ $json.ccEmails }}
```

> The HTML in `Email template n8n.html` is only for the **Email Alert** node.

### Daily Report Flow Nodes

| Node | Type | What it does |
|------|------|-------------|
| **Schedule Trigger** | Schedule | Fires at 8:00 AM every day (`0 0 8 * * *`) |
| **Read VMs from MySQL** | executeQuery | Reads all rows from `vm_reports` table |
| **Build Consolidated Report** | Code | Builds full HTML table — one row per VM with status, RAM, disk, issues, timestamp |
| **Has Data?** | IF | Skips sending if no VMs reported that day |
| **Send Daily Report Email** | Email | Sends consolidated report to configured addresses (independent from per-VM owner) |
| **Telegram Daily Report** | Telegram | Sends Telegram summary of the daily report |
| **Clear VMs from MySQL** | executeQuery | Runs `DELETE FROM vm_reports` — resets table for next day |

> The daily report email recipients are configured directly in the **Send Daily Report Email** node — enter addresses separated by commas. This is independent from the per-alert `ownerEmail`.

### Telegram Bot Setup

1. Message **@BotFather** on Telegram → create a bot → copy the token
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

Once running, create a **MySQL credential** in n8n with the same values and click **Test Connection** — you should see "Connection tested successfully" before saving.

A ready-to-run example command is in [`mysql-compose.bash`](mysql-compose.bash).

---

## Timezone Fix

If alert timestamps or the daily report schedule show the wrong time, add these to the n8n service in `docker-compose.yml`:

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

---

## Notifications

### Telegram Message (CRITICAL only — disk >= 90%)

```
🚨 VM INFRASTRUCTURE MONITOR
──────────────────────────────
💻 prod-server-01   📍 Rack-A Hilla DC1
🌐 192.168.x.x   🕐 2026-02-28 11:05 PM +03
Status: 🟥 CRITICAL
──────────────────────────────
💾 RAM USAGE
████████████████████  92%
Used: 7.6GB  |  Free: 0.7GB  |  Total: 8.3GB

💿 DISK USAGE (/)
█████████████████░░░  85%
Used: 42GB  |  Free: 7GB  |  Total: 49GB
──────────────────────────────
⚠️ ACTIVE ISSUES
🟥 RAM at 92% — repeats every 1h
🟧 Disk at 85% — repeats every 6h
```

### Alert Email

Sent for all severity levels. Header color reflects severity (red/orange/yellow/blue). Body shows usage bars, exact GB values, and active issues with repeat intervals.

### Daily Report Email

Sent once per day. Consolidated table of all VMs that reported during the day — hostname, IP, status color, RAM bar, disk bar, active issues, and timestamp per row.

---

## Logs and Monitoring

### Watch the live log

```bash
tail -f /var/log/vm_metrics_reporter.log
```

### Log examples

Alert sent:
```
[2026-02-28 23:05:01] 🚨 Alert: prod-srv | Disk: 65% | RAM: 21% | 🔵 INFO
[2026-02-28 23:05:01] ✅ Alert sent (HTTP 200)
```

Interval not elapsed (normal — happens every minute):
```
[2026-02-28 23:06:01] ⏭  Disk 65% (tier: >=60%, every 24h) — next alert in ~24h
```

Simulate command:
```
[2026-02-28 23:07:35] 🧪 SIMULATE: disk=92% | ram=50% | 🔴 CRITICAL
[2026-02-28 23:07:35] ✅ Simulated alert sent (HTTP 200)
```

Webhook unreachable:
```
[2026-02-28 23:08:01] ❌ Failed (HTTP 000):
```

### Check the cron job

```bash
cat /etc/cron.d/vm_metrics_reporter
```

### Check state file timestamps

```bash
for f in /opt/vm-metrics/state/*; do
    echo "$f → $(date -d @$(cat $f) '+%Y-%m-%d %H:%M:%S')"
done
```

---

## Testing

### Enable test mode

Adds an extra tier that fires every minute for any disk usage above 10% — useful to verify cron, Telegram, and Email are all working without waiting for real thresholds.

Edit the installed script:

```bash
sudo nano /opt/vm-metrics/vm_metrics_reporter.sh
```

Swap the `DISK_TIERS` line:

```bash
# Comment out production:
#DISK_TIERS="90:1 80:6 70:12 60:24"

# Uncomment test line:
DISK_TIERS="90:1 80:6 70:12 60:24 10:0"
```

Reinstall to apply:

```bash
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --install
```

`--status` should now show:
```
Disk Tier: >=10% → every 1 minute
```

Watch the log — you should see one alert per minute with no duplicates.

### Disable test mode

```bash
sudo nano /opt/vm-metrics/vm_metrics_reporter.sh

# Uncomment production:
DISK_TIERS="90:1 80:6 70:12 60:24"

# Comment out test:
#DISK_TIERS="90:1 80:6 70:12 60:24 10:0"
```

Reinstall:

```bash
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --install
```

---

## Troubleshooting

**No alerts arriving at all**

Check if the webhook is reachable, then force a send:

```bash
curl -s http://YOUR_N8N_SERVER:5678/healthz

sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --force
tail -20 /var/log/vm_metrics_reporter.log
```

---

**Script seems stuck and won't run**

The lock directory may be stale from a crashed run. Remove it:

```bash
sudo rm -rf /tmp/vm_metrics_reporter.lock
```

---

**Alerts sent too often or not often enough**

View current timestamps and reset timers if needed:

```bash
# View
for f in /opt/vm-metrics/state/*; do
    echo "$f → $(date -d @$(cat $f) '+%Y-%m-%d %H:%M:%S')"
done

# Reset all timers (next cron tick will send fresh)
sudo rm -f /opt/vm-metrics/state/*
```

---

**Daily report not arriving**

Check the MySQL container and the `vm_reports` table:

```bash
docker ps | grep n8n_db

docker exec -it n8n_db mysql -u mysql -pmysql n8n -e "SELECT * FROM vm_reports;"
```

If the table is empty, no VM sent data that day — run `--simulate-daily` to test the full flow.

---

**Timestamps showing wrong time**

Set the timezone in `docker-compose.yml` and restart:

```yaml
environment:
  - GENERIC_TIMEZONE=Asia/Baghdad
  - TZ=Asia/Baghdad
```

```bash
docker compose restart n8n
```

---

**Need to update config (owner, location, network version)**

Just re-run the install wizard:

```bash
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --install
```

---

## File Structure

```
vm_metrics_reporter .sh                                  # Main monitoring script
VM Metrics Alert - Telegram & Email & Daily Report.json  # n8n workflow export
Email template n8n.html                                  # Alert email HTML template
mysql-compose.bash                                       # MySQL Docker run command
commands.txt                                             # Quick command reference
```

---

## License

This project is private. All rights reserved.
