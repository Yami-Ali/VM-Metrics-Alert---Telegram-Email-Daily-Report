#!/bin/bash
# ================================================================
#  VM Metrics Reporter — n8n Webhook Edition
#  Compatible with: Ubuntu 20.04+ and Debian 10+
#
#  DISK alert tiers:
#    >= 90% → every 1h   → Telegram
#    >= 80% → every 6h   → Email
#    >= 70% → every 12h  → Email
#    >= 60% → every 24h  → Email
#    <  60% → no alert
#
#  RAM alert:
#    > 80% (used/total) → every 24h → Email
#
#  DOWNLOAD:
#    Manual: https://github.com/YOUR_ORG/vm-metrics-reporter
#    Git:    git clone https://github.com/YOUR_ORG/vm-metrics-reporter
#
#  QUICK START:
#    sudo bash vm_metrics_reporter.sh --install
# ================================================================

# ================================================================
#  USER DIRECTORY — edit this list to add/remove users
#  Format: "Full Name:email@domain.com"
# ================================================================
USERS=(
    "Ammar Alessa: ammar.aleessa@alkafeelomnnea.com"
    "Ahmed Al-Fadhul: ahmed.m.alfadhel@alkafeelomnnea.com"
    "Ali Alaa: ali.a.abbas@alkafeelomnnea.com"
    "Qasim: qasim.l.ghalib@alkafeelomnnea.com"
    "Ali Yami: ali.m.mahdi@alkafeelomnnea.com"
    "Abbas Mohammad: abbas.m.hamza@alkafeelomnnea.com"
    "Abdullah Raheem: abdullah.r.farhan@alkafeelomnnea.com"
    "mohammed albaqir: mohammed.albaqir.mahdi@alkafeelomnnea.com"
    "Mohamad Ali: mohammed.a.rahim@alkafeelomnnea.com"
    "Hussein Adnan: hussain.adnan.a@alkafeelomnnea.com"
    "Muhammad Nadhum: muhammad.n.hashim@alkafeelomnnea.com"
    "Huda Kareem: huda.k.rasool@alkafeelomnnea.com"
)

# ================================================================
#  CONFIGURATION — populated by --install wizard, do not edit manually
# ================================================================
N8N_WEBHOOK_URL="http://192.168.199.107:5678/webhook/508afee7-c80d-44b7-8bd2-6a9acecfb4ab"
VM_NAME=""
LOCATION=""
NETWORK_VERSION=""    # "old" | "new" | "Old & New Network"
OWNER_NAME=""         # VM owner full name  (To: in email)
OWNER_EMAIL=""        # VM owner email      (To: in email)
CC_EMAILS=""          # comma-separated CC addresses

# ================================================================
#  DISK ALERT TIERS — "THRESHOLD:INTERVAL_HOURS"  (highest first)
# ================================================================
DISK_TIERS="90:1 80:6 70:12 60:24"
# ⬇ TEST TIER — remove after testing (alerts at >10% every minute, triggers email+telegram)
#DISK_TIERS="90:1 80:6 70:12 60:24 10:0"

# ================================================================
#  RAM ALERT — simple single threshold
# ================================================================
RAM_ALERT_THRESHOLD=80
RAM_ALERT_INTERVAL=24

# ================================================================
#  INTERNAL
# ================================================================
INSTALL_DIR="/opt/vm-metrics"
STATE_DIR="/opt/vm-metrics/state"
LOG_FILE="/var/log/vm_metrics_reporter.log"
CRON_INTERVAL="* * * * *"
SCRIPT_PATH="$INSTALL_DIR/vm_metrics_reporter.sh"
CRON_FILE="/etc/cron.d/vm_metrics_reporter"
SKIP_INTERVAL_CHECK="false"   # set to "true" by --daily
DAILY_REPORT_TIME="0759"      # HHMM — must match the cron entry (used to skip --run at this minute)

# Lock is named uniquely for THIS script only — never conflicts with other cron scripts
RUN_LOCK_DIR="/tmp/vm_metrics_reporter.lock"

acquire_run_lock() {
    if mkdir "$RUN_LOCK_DIR" 2>/dev/null; then
        echo $$ > "$RUN_LOCK_DIR/pid"
        return 0
    fi
    local owner_pid
    owner_pid=$(cat "$RUN_LOCK_DIR/pid" 2>/dev/null)
    if [ -n "$owner_pid" ] && kill -0 "$owner_pid" 2>/dev/null; then
        return 1
    fi
    rm -rf "$RUN_LOCK_DIR"
    if mkdir "$RUN_LOCK_DIR" 2>/dev/null; then
        echo $$ > "$RUN_LOCK_DIR/pid"
        return 0
    fi
    return 1
}

release_run_lock() {
    rm -rf "$RUN_LOCK_DIR"
}

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOG_FILE"
    # Also print to terminal when run interactively (not from cron)
    [ -t 1 ] && echo "$msg"
}

get_timestamp() {
    if TZ="Asia/Baghdad" date >/dev/null 2>&1; then
        TZ="Asia/Baghdad" date +"%Y-%m-%d %I:%M:%S %p"
    else
        date -u +"%Y-%m-%dT%H:%M:%S"
    fi
}

get_disk_tier_interval() {
    local pct=$1
    for tier in $DISK_TIERS; do
        local threshold="${tier%%:*}"
        local interval="${tier##*:}"
        if [ "$pct" -ge "$threshold" ]; then
            echo "$interval"; return
        fi
    done
    echo "none"   # below all thresholds — no alert
}

get_disk_tier_label() {
    local pct=$1
    for tier in $DISK_TIERS; do
        local threshold="${tier%%:*}"
        if [ "$pct" -ge "$threshold" ]; then
            echo ">=${threshold}%"; return
        fi
    done
    echo "normal"
}

fmt_size() {
    awk "BEGIN {
        g = $1 + 0
        if (g >= 1024) printf \"%.1f TB\", g/1024
        else if (g >= 1) printf \"%.1f GB\", g
        else printf \"%d MB\", int(g*1024+0.5)
    }"
}

# Sets global SEND_DISK_PART="true"/"false" directly.
# $1 = usage_pct, $2 = sanitized mount key (e.g. "root", "data", "backup")
# Each mount gets its own independent state files: disk_tier_<key>_<threshold>
should_send_partition_alert() {
    local pct=$1
    local mount_key=$2

    # --daily bypasses all interval checks and always sends
    if [ "$SKIP_INTERVAL_CHECK" = "true" ]; then SEND_DISK_PART="true"; return; fi

    local interval_hours
    interval_hours=$(get_disk_tier_interval "$pct")

    # "none" = below all thresholds — clear this mount's state files, no alert
    if [ "$interval_hours" = "none" ]; then
        rm -f "$STATE_DIR"/disk_tier_${mount_key}_* 2>/dev/null
        SEND_DISK_PART="false"; return
    fi

    local active_threshold=""
    for tier in $DISK_TIERS; do
        local threshold="${tier%%:*}"
        if [ "$pct" -ge "$threshold" ]; then
            active_threshold="$threshold"; break
        fi
    done

    # Clear state files for other tiers of THIS mount only
    for tier in $DISK_TIERS; do
        local t="${tier%%:*}"
        [ "$t" != "$active_threshold" ] && rm -f "$STATE_DIR/disk_tier_${mount_key}_${t}" 2>/dev/null
    done

    local state_file="$STATE_DIR/disk_tier_${mount_key}_${active_threshold}"
    local now_epoch; now_epoch=$(date +%s)

    if [ ! -f "$state_file" ]; then
        mkdir -p "$STATE_DIR"
        echo "$now_epoch" > "$state_file"
        SEND_DISK_PART="true"; return
    fi

    local last_sent; last_sent=$(cat "$state_file" 2>/dev/null || echo 0)

    # interval 0 = every minute (no hour-based throttle, always send)
    if [ "$interval_hours" -eq 0 ] 2>/dev/null; then
        echo "$now_epoch" > "$state_file"
        SEND_DISK_PART="true"; return
    fi

    local elapsed_hours=$(( (now_epoch - last_sent) / 3600 ))

    if [ "$elapsed_hours" -ge "$interval_hours" ]; then
        echo "$now_epoch" > "$state_file"
        SEND_DISK_PART="true"
    else
        local next_in=$(( interval_hours - elapsed_hours ))
        log "⏭  Disk [$mount_key] ${pct}% (tier: >=${active_threshold}%, every ${interval_hours}h) — next alert in ~${next_in}h"
        SEND_DISK_PART="false"
    fi
}

# ─────────────────────────────────────────────────────────────────
# Collect reportable disk entries.
# Output format (one line per entry):
#   PNAME|DISK|FS_TOTAL_B|AVAIL_B|USED_B|PCT|LABEL|WORST_MOUNT|PTYPE
#
#   PTYPE values:
#     LVM_ROOT   — LVM container whose LVs include /
#     LVM        — LVM container (no / inside)
#     DIRECT_ROOT — directly-mounted partition at /
#     DIRECT     — directly-mounted partition elsewhere
#     NET        — NFS / CIFS network mount
#
# For LVM containers: FS_TOTAL_B, AVAIL_B, USED_B are sums across all LVs.
# Falls back to df -BM if lsblk / python3 unavailable.
# NFS/CIFS mounts from df are always appended (lsblk never sees them).
_collect_partitions() {
    local _DF_FILTER='tmpfs|devtmpfs|udev|Filesystem|overlay|rootfs|shm|/dev/loop|/snap/'

    rm -f /tmp/vm_metrics_collect_error

    if ! command -v lsblk &>/dev/null; then
        echo "lsblk not found — install with: sudo apt-get install -y util-linux" > /tmp/vm_metrics_collect_error
        return
    fi

    if ! command -v python3 &>/dev/null; then
        echo "python3 not found — install with: sudo apt-get install -y python3" > /tmp/vm_metrics_collect_error
        return
    fi

    local _JSON
    _JSON=$(timeout 10 lsblk -b --json -o NAME,SIZE,FSAVAIL,FSUSED,TYPE,MOUNTPOINT 2>/dev/null)
    if [ -z "$_JSON" ]; then
        echo "lsblk returned no output — disk data unavailable" > /tmp/vm_metrics_collect_error
        return
    fi

    # ── Physical block devices via lsblk ──
    echo "$_JSON" | python3 -c "
import json, sys

def iv(v):
    try: return int(v) if v else 0
    except: return 0

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

for disk in data.get('blockdevices', []):
    dn = disk.get('name','')
    if disk.get('type') != 'disk': continue
    if dn.startswith('loop') or dn[:2] == 'sr': continue

    for part in disk.get('children', []):
        pt  = part.get('type','')
        if pt not in ('part','lvm','md'): continue

        pn  = part.get('name','')
        ps  = iv(part.get('size'))
        pa  = iv(part.get('fsavail'))
        pu  = iv(part.get('fsused'))
        pm  = (part.get('mountpoint') or '').strip()
        if pm in ('[SWAP]','SWAP'): pm = ''

        kids = [c for c in part.get('children', [])
                if c.get('type') in ('lvm','part','md')]

        if kids:
            ta = tu = wp = 0; wm = ''; has_root = False
            for lv in kids:
                la = iv(lv.get('fsavail')); lu = iv(lv.get('fsused'))
                lm = (lv.get('mountpoint') or '').strip()
                if lm in ('[SWAP]','SWAP',''): continue
                if lm == '/': has_root = True
                ta += la; tu += lu
                tf2 = la + lu
                if tf2 > 0:
                    lp = lu * 100 // tf2
                    if lp > wp: wp = lp; wm = lm
            tf = ta + tu
            pct = tu * 100 // tf if tf > 0 else 0
            ptype = 'LVM_ROOT' if has_root else 'LVM'
            print(f'{pn}|{dn}|{tf}|{ta}|{tu}|{pct}|{pn}|{wm}|{ptype}')
        elif pa > 0 or pu > 0:
            tf = pa + pu
            pct = pu * 100 // tf if tf > 0 else 0
            lb = pn
            ptype = 'DIRECT_ROOT' if pm == '/' else 'DIRECT'
            print(f'{pn}|{dn}|{tf}|{pa}|{pu}|{pct}|{lb}|{pm}|{ptype}')
" 2>/dev/null || { echo "lsblk JSON parse failed — disk data unavailable" > /tmp/vm_metrics_collect_error; return; }

    # ── Network mounts (NFS/CIFS) — lsblk never sees these ──
    while IFS= read -r _line; do
        local _dev _mp _sz _us _av _pt
        _dev=$(echo "$_line" | awk '{print $1}')
        [[ "$_dev" == *:* ]] || [[ "$_dev" == //* ]] || continue
        _mp=$(echo "$_line"  | awk '{print $6}')
        _sz=$(echo "$_line"  | awk '{gsub("M",""); printf "%.0f", $2*1048576}')
        _us=$(echo "$_line"  | awk '{gsub("M",""); printf "%.0f", $3*1048576}')
        _av=$(echo "$_line"  | awk '{gsub("M",""); printf "%.0f", $4*1048576}')
        _pt=$(echo "$_line"  | awk '{print $5}' | tr -d '%')
        [[ "$_pt" =~ ^[0-9]+$ ]] || continue
        echo "$_mp|net|$((_sz))|$((_av))|$((_us))|$_pt|$_mp|$_mp|NET"
    done < <(timeout 10 df -BM 2>/dev/null | grep -vE "$_DF_FILTER")
}

# ─────────────────────────────────────────────────────────────────
send_metrics() {

    TIMESTAMP=$(get_timestamp)
    RESOLVED_NAME="${VM_NAME:-$(hostname -f 2>/dev/null || hostname)}"
    PRIMARY_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    [ -z "$PRIMARY_IP" ] && PRIMARY_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$PRIMARY_IP" ] && PRIMARY_IP="unknown"
    ALL_IPS=$(hostname -I 2>/dev/null | tr ' ' ',' | sed 's/,$//')
    RESOLVED_LOCATION="${LOCATION:-not set}"

    # ── RAM ──────────────────────────────────────────────────────
    RAM_TOTAL_MB=$(free -m | awk '/^Mem:/ {print $2}')
    RAM_USED_MB=$(free  -m | awk '/^Mem:/ {print $3}')
    RAM_FREE_MB=$(( RAM_TOTAL_MB - RAM_USED_MB ))
    RAM_USAGE_PCT=$(awk "BEGIN {printf \"%.1f\", ($RAM_USED_MB/$RAM_TOTAL_MB)*100}")
    RAM_INT=$(awk "BEGIN {printf \"%d\",   ($RAM_USED_MB/$RAM_TOTAL_MB)*100}")
    RAM_TOTAL_GB=$(awk "BEGIN {printf \"%.2f\", $RAM_TOTAL_MB/1024}")
    RAM_USED_GB=$(awk  "BEGIN {printf \"%.2f\", $RAM_USED_MB/1024}")
    RAM_FREE_GB=$(awk  "BEGIN {printf \"%.2f\", $RAM_FREE_MB/1024}")

    # ── Disk — collect physical partitions (lsblk) + NFS mounts ─────
    _PARTS_DATA=$(_collect_partitions)

    # Populate disk.root from the root partition (LVM_ROOT or DIRECT_ROOT)
    DISK_TOTAL_GB="0.0"; DISK_USED_GB="0.0"; DISK_FREE_GB="0.0"; DISK_USAGE_PCT=0
    while IFS='|' read -r _pn _dk _fst _av _us _pt _lb _wm _pty; do
        [[ "$_pty" == *ROOT* ]] || continue
        DISK_TOTAL_GB=$(awk "BEGIN {printf \"%.1f\", $_fst/1073741824}")
        DISK_USED_GB=$(awk  "BEGIN {printf \"%.1f\", $_us/1073741824}")
        DISK_FREE_GB=$(awk  "BEGIN {printf \"%.1f\", $_av/1073741824}")
        DISK_USAGE_PCT="$_pt"
        break
    done <<< "$_PARTS_DATA"

    # Build all_mounts JSON array
    MOUNTS_JSON=""
    while IFS='|' read -r _pn _dk _fst _av _us _pt _lb _wm _pty; do
        [ -z "$_pn" ] && continue
        [[ "$_pt" =~ ^[0-9]+$ ]] || continue
        _tgb=$(awk "BEGIN {printf \"%.1f\", $_fst/1073741824}")
        _ugb=$(awk "BEGIN {printf \"%.1f\", $_us/1073741824}")
        _fgb=$(awk "BEGIN {printf \"%.1f\", $_av/1073741824}")
        entry="{\"mount\":\"$_lb\",\"total_gb\":$_tgb,\"used_gb\":$_ugb,\"free_gb\":$_fgb,\"usage_pct\":$_pt}"
        MOUNTS_JSON="${MOUNTS_JSON:+$MOUNTS_JSON,}$entry"
    done <<< "$_PARTS_DATA"

    # ── Per-partition disk alert check ───────────────────────────
    DISK_INT=${DISK_USAGE_PCT%.*}; DISK_INT=${DISK_INT:-0}
    SEND_DISK="false"
    SEND_RAM="false"
    DISK_ISSUES_JSON=""
    MAX_DISK_PCT=0

    # Each physical partition checked independently — its own state file keyed by partition name
    while IFS='|' read -r _pn _dk _fst _av _us _pt _lb _wm _pty; do
        [ -z "$_pn" ] && continue
        [[ "$_pt" =~ ^[0-9]+$ ]] || continue

        # State file key = partition name (sda1, sda4) or sanitised NFS mount
        _mount_key=$(echo "$_pn" | sed 's|^/||; s|/|_|g')
        [ -z "$_mount_key" ] && _mount_key="disk"

        SEND_DISK_PART="false"
        should_send_partition_alert "$_pt" "$_mount_key"

        if [ "$SEND_DISK_PART" = "true" ]; then
            SEND_DISK="true"
            _tier_label=$(get_disk_tier_label "$_pt")
            _interval=$(get_disk_tier_interval "$_pt")
            if   [ "$_pt" -ge 90 ]; then _sev="critical"
            elif [ "$_pt" -ge 80 ]; then _sev="warning"
            elif [ "$_pt" -ge 70 ]; then _sev="notice"
            elif [ "$_pt" -ge 60 ]; then _sev="info"
            else                          _sev="ok"; fi
            _ival=$([ "$_interval" = "none" ] && echo 0 || { [ "$_interval" = "0" ] && echo 0 || echo "$_interval"; })
            _fgb=$(awk "BEGIN {printf \"%.1f\", $_av/1073741824}")
            _tgb=$(awk "BEGIN {printf \"%.1f\", $_fst/1073741824}")
            _free_fmt=$(fmt_size "$_fgb")
            _total_fmt=$(fmt_size "$_tgb")
            # Alert label: "sda4 → /usr" for LVM, mount/partition name for direct/NFS
            if [[ "$_pty" == LVM* ]] && [ -n "$_wm" ]; then
                _alert_lbl="${_pn} → ${_wm}"
            else
                _alert_lbl="$_lb"
            fi
            _entry="{\"type\":\"DISK\",\"mount\":\"$_pn\",\"message\":\"${_alert_lbl} at ${_pt}% — ${_free_fmt} free of ${_total_fmt}\",\"severity\":\"$_sev\",\"tier\":\"$_tier_label\",\"alert_interval_hours\":$_ival}"
            DISK_ISSUES_JSON="${DISK_ISSUES_JSON:+$DISK_ISSUES_JSON,}$_entry"
            [ "$_pt" -gt "$MAX_DISK_PCT" ] && MAX_DISK_PCT=$_pt
        fi
    done <<< "$_PARTS_DATA"

    # If disk collection failed entirely, inject a critical error issue
    if [ -f /tmp/vm_metrics_collect_error ]; then
        _COLLECT_ERR=$(cat /tmp/vm_metrics_collect_error)
        log "⚠️  Disk monitoring unavailable: $_COLLECT_ERR"
        SEND_DISK="true"
        DISK_ISSUES_JSON="{\"type\":\"DISK\",\"mount\":\"unknown\",\"message\":\"Disk monitoring unavailable — ${_COLLECT_ERR}\",\"severity\":\"critical\",\"tier\":\"system\",\"alert_interval_hours\":1}"
        MAX_DISK_PCT=90
    fi

    # --daily forces RAM send regardless of threshold or interval
    [ "$SKIP_INTERVAL_CHECK" = "true" ] && SEND_RAM="true"

    # ── Check RAM ────────────────────────────────────────────────
    if [ "$RAM_INT" -gt "$RAM_ALERT_THRESHOLD" ]; then
        STATE_RAM="$STATE_DIR/ram_alert"
        NOW_E=$(date +%s)
        if [ ! -f "$STATE_RAM" ]; then
            mkdir -p "$STATE_DIR"
            echo "$NOW_E" > "$STATE_RAM"
            SEND_RAM="true"
        else
            LAST_RAM=$(cat "$STATE_RAM" 2>/dev/null || echo 0)
            ELAPSED=$(( (NOW_E - LAST_RAM) / 3600 ))
            if [ "$ELAPSED" -ge "$RAM_ALERT_INTERVAL" ]; then
                echo "$NOW_E" > "$STATE_RAM"
                SEND_RAM="true"
            else
                NEXT_RAM=$(( RAM_ALERT_INTERVAL - ELAPSED ))
                log "⏭  RAM ${RAM_USAGE_PCT}% (>${RAM_ALERT_THRESHOLD}%, every ${RAM_ALERT_INTERVAL}h) — next alert in ~${NEXT_RAM}h"
            fi
        fi
    else
        rm -f "$STATE_DIR/ram_alert" 2>/dev/null
    fi

    if [ "$SEND_DISK" != "true" ] && [ "$SEND_RAM" != "true" ]; then
        return 0
    fi

    # ── Build issues list ─────────────────────────────────────────
    # Disk issues already built per-partition in the loop above
    ISSUES_JSON="$DISK_ISSUES_JSON"
    HAS_ISSUES="false"
    MAX_PCT=$MAX_DISK_PCT
    [ "$SEND_DISK" = "true" ] && HAS_ISSUES="true"

    if [ "$SEND_RAM" = "true" ]; then
        HAS_ISSUES="true"
        if   [ "$RAM_INT" -ge 90 ]; then RAM_SEV="critical"
        elif [ "$RAM_INT" -ge 80 ]; then RAM_SEV="warning"
        elif [ "$RAM_INT" -ge 70 ]; then RAM_SEV="notice"
        elif [ "$RAM_INT" -ge 60 ]; then RAM_SEV="info"
        else                              RAM_SEV="ok"; fi
        _ram_free_fmt=$(fmt_size "$RAM_FREE_GB")
        _ram_total_fmt=$(fmt_size "$RAM_TOTAL_GB")
        RAM_ISSUE="{\"type\":\"RAM\",\"message\":\"RAM at ${RAM_USAGE_PCT}% — ${_ram_free_fmt} free of ${_ram_total_fmt} (${RAM_USED_MB}MB used / ${RAM_TOTAL_MB}MB total)\",\"severity\":\"$RAM_SEV\",\"tier\":\">80%\",\"alert_interval_hours\":$RAM_ALERT_INTERVAL}"
        ISSUES_JSON="${ISSUES_JSON:+$ISSUES_JSON,}$RAM_ISSUE"
        [ "$RAM_INT" -gt "$MAX_PCT" ] && MAX_PCT=$RAM_INT
    fi

    [ "$HAS_ISSUES" = "false" ] && return 0

    # ── Overall severity ──────────────────────────────────────────
    if   [ "$MAX_PCT" -ge 90 ]; then SEVERITY="CRITICAL"; SEVERITY_LABEL="🔴 CRITICAL"
    elif [ "$MAX_PCT" -ge 80 ]; then SEVERITY="WARNING";  SEVERITY_LABEL="🟠 WARNING"
    elif [ "$MAX_PCT" -ge 70 ]; then SEVERITY="NOTICE";   SEVERITY_LABEL="🟡 NOTICE"
    else                               SEVERITY="INFO";    SEVERITY_LABEL="🔵 INFO"
    fi

    IS_DAILY_FLAG="false"
    [ "$SKIP_INTERVAL_CHECK" = "true" ] && [ "$FORCE_SEND" != "true" ] && IS_DAILY_FLAG="true"

    PAYLOAD=$(cat <<EOF
{
  "vm_name": "$RESOLVED_NAME",
  "ip": { "primary": "$PRIMARY_IP", "all": "$ALL_IPS" },
  "location": "$RESOLVED_LOCATION",
  "timestamp": "$TIMESTAMP",
  "is_daily": $IS_DAILY_FLAG,
  "os_type": "linux",
  "has_issues": $HAS_ISSUES,
  "severity": "$SEVERITY",
  "network_version": "$NETWORK_VERSION",
  "owner": { "name": "$OWNER_NAME", "email": "$OWNER_EMAIL" },
  "cc_emails": "$CC_EMAILS",
  "resource_issues": [$ISSUES_JSON],
  "ram": {
    "total_gb": $RAM_TOTAL_GB,
    "used_gb": $RAM_USED_GB,
    "free_gb": $RAM_FREE_GB,
    "total_mb": $RAM_TOTAL_MB,
    "used_mb": $RAM_USED_MB,
    "free_mb": $RAM_FREE_MB,
    "usage_pct": $RAM_USAGE_PCT
  },
  "disk": {
    "root": {
      "total_gb": $DISK_TOTAL_GB,
      "used_gb": $DISK_USED_GB,
      "free_gb": $DISK_FREE_GB,
      "usage_pct": $DISK_USAGE_PCT
    },
    "all_mounts": [$MOUNTS_JSON]
  }
}
EOF
)

    log "🚨 Alert: $RESOLVED_NAME | Disk worst: ${MAX_DISK_PCT}% (root: ${DISK_USAGE_PCT}%) | RAM: ${RAM_USAGE_PCT}% | Net: $NETWORK_VERSION | Owner: $OWNER_NAME | $SEVERITY_LABEL"

    HTTP_STATUS=$(curl -s -o /tmp/vm_metrics_resp.txt -w "%{http_code}" \
        -X POST "$N8N_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        --max-time 30 \
        --retry 3 \
        --retry-delay 5)

    RESPONSE=$(cat /tmp/vm_metrics_resp.txt 2>/dev/null)

    if [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 300 ]; then
        log "✅ Alert sent (HTTP $HTTP_STATUS)"
    else
        log "❌ Failed (HTTP $HTTP_STATUS): $RESPONSE"
        exit 1
    fi
}

# ================================================================
#  INSTALL WIZARD — helper functions
# ================================================================

wizard_network() {
    echo ""
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║      Step 1 — Network Version        ║"
    echo "  ╚══════════════════════════════════════╝"
    echo ""
    echo "    1) Old Network"
    echo "    2) New Network"
    echo "    3) Old & New Network"
    echo ""
    while true; do
        read -rep "  Select [1-3]: " choice
        case "$choice" in
            1) NETWORK_VERSION="old";  echo "  ✅ Old Network selected";  break ;;
            2) NETWORK_VERSION="new";  echo "  ✅ New Network selected";  break ;;
            3) NETWORK_VERSION="Old & New Network"; echo "  ✅ Old & New Network Networks selected"; break ;;
            *) echo "  ⚠️  Please enter 1, 2, or 3" ;;
        esac
    done
}

wizard_owner() {
    echo ""
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║     Step 2 — VM Owner (To: email)    ║"
    echo "  ╚══════════════════════════════════════╝"
    echo ""
    local i=1
    for entry in "${USERS[@]}"; do
        local uname="${entry%%:*}"
        local uemail="${entry##*:}"
        printf "    %2d)  %-24s %s\n" "$i" "$uname" "<$uemail>"
        (( i++ ))
    done
    echo ""
    while true; do
        read -rep "  Select owner [1-${#USERS[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#USERS[@]}" ]; then
            local entry="${USERS[$((choice-1))]}"
            OWNER_NAME="${entry%%:*}"
            OWNER_EMAIL="${entry##*:}"
            echo "  ✅ Owner → $OWNER_NAME <$OWNER_EMAIL>"
            break
        fi
        echo "  ⚠️  Invalid — enter a number between 1 and ${#USERS[@]}"
    done
}

wizard_cc() {
    echo ""
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║      Step 3 — CC Recipients          ║"
    echo "  ╚══════════════════════════════════════╝"
    echo "  (Enter numbers separated by spaces, or press Enter to skip)"
    echo ""
    local i=1
    for entry in "${USERS[@]}"; do
        local uname="${entry%%:*}"
        local uemail="${entry##*:}"
        if [ "$uemail" = "$OWNER_EMAIL" ]; then
            printf "    %2d)  %-24s %s  ← owner\n" "$i" "$uname" "<$uemail>"
        else
            printf "    %2d)  %-24s %s\n" "$i" "$uname" "<$uemail>"
        fi
        (( i++ ))
    done
    echo ""
    CC_EMAILS=""
    while true; do
        read -rep "  Select CC users [e.g. 2 3 5] or Enter to skip: " raw
        if [ -z "$raw" ]; then
            echo "  ✅ No CC recipients selected"
            break
        fi
        local valid=true
        local selected_emails=""
        local selected_names=""
        for tok in $raw; do
            if [[ "$tok" =~ ^[0-9]+$ ]] && [ "$tok" -ge 1 ] && [ "$tok" -le "${#USERS[@]}" ]; then
                local entry="${USERS[$((tok-1))]}"
                local uemail="${entry##*:}"
                local uname="${entry%%:*}"
                selected_emails="${selected_emails:+$selected_emails,}$uemail"
                selected_names="${selected_names:+$selected_names, }$uname"
            else
                echo "  ⚠️  Invalid number: $tok — try again"
                valid=false
                break
            fi
        done
        if [ "$valid" = "true" ]; then
            CC_EMAILS="$selected_emails"
            [ -n "$selected_names" ] && echo "  ✅ CC → $selected_names"
            break
        fi
    done
}

# ─────────────────────────────────────────────────────────────────
#  Patch a variable value in the installed script file
# ─────────────────────────────────────────────────────────────────
patch_var() {
    local varname="$1"
    local value="$2"
    local file="$3"
    sed -i "s|^${varname}=\".*\"|${varname}=\"${value}\"|" "$file"
}

# ─────────────────────────────────────────────────────────────────
install() {
    echo ""
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║       VM Metrics Reporter — Install          ║"
    echo "  ╚══════════════════════════════════════════════╝"

    if [ -f /etc/os-release ]; then
        OS_NAME=$(. /etc/os-release && echo "$PRETTY_NAME")
        echo "  OS: $OS_NAME"
    fi

    for cmd in curl free df awk ip sed lsblk python3; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "  ⚠️  Missing: $cmd — install with: sudo apt-get install -y $cmd"
        fi
    done

    if [ "$N8N_WEBHOOK_URL" = "http://YOUR_SERVER_IP:5678/webhook/508afee7-c80d-44b7-8bd2-6a9acecfb4ab" ]; then
        echo ""
        echo "  ⚠️  N8N_WEBHOOK_URL is still the default placeholder!"
        read -rep "  Continue anyway? (y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
    fi

    # ── Run wizard steps ──────────────────────────────────────────
    wizard_network
    wizard_owner
    wizard_cc

    # ── VM Name & Location ────────────────────────────────────────
    echo ""
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║      Step 4 — VM Identity            ║"
    echo "  ╚══════════════════════════════════════╝"
    echo ""
    DEFAULT_HOSTNAME=$(hostname -f 2>/dev/null || hostname)
    read -rep "  VM Name [default: $DEFAULT_HOSTNAME]: " input_name
    VM_NAME="${input_name:-$DEFAULT_HOSTNAME}"

    read -rep "  Location (e.g. Rack-A Hilla): " input_loc
    LOCATION="${input_loc:-not set}"

    # ── Copy & patch ──────────────────────────────────────────────
    mkdir -p "$INSTALL_DIR" "$STATE_DIR"
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"

    patch_var "NETWORK_VERSION" "$NETWORK_VERSION" "$SCRIPT_PATH"
    patch_var "OWNER_NAME"      "$OWNER_NAME"      "$SCRIPT_PATH"
    patch_var "OWNER_EMAIL"     "$OWNER_EMAIL"     "$SCRIPT_PATH"
    patch_var "CC_EMAILS"       "$CC_EMAILS"       "$SCRIPT_PATH"
    patch_var "VM_NAME"         "$VM_NAME"         "$SCRIPT_PATH"
    patch_var "LOCATION"        "$LOCATION"        "$SCRIPT_PATH"

    # ── Cron ─────────────────────────────────────────────────────
    _DAILY_H="${DAILY_REPORT_TIME:0:2}"
    _DAILY_M="${DAILY_REPORT_TIME:2:2}"
    printf '# VM Metrics Reporter\n%s root %s --run >> %s 2>&1\n%s %s * * * root %s --daily >> %s 2>&1\n\n' \
        "$CRON_INTERVAL" "$SCRIPT_PATH" "$LOG_FILE" \
        "$_DAILY_M" "$_DAILY_H" "$SCRIPT_PATH" "$LOG_FILE" > "$CRON_FILE"
    chmod 644 "$CRON_FILE"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable cron 2>/dev/null || systemctl enable crond 2>/dev/null || true
        systemctl start  cron 2>/dev/null || systemctl start  crond 2>/dev/null || true
    fi

    # ── Summary ───────────────────────────────────────────────────
    echo ""
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║              Install Summary                 ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo ""
    echo "  ✅ Script:     $SCRIPT_PATH"
    echo "  ✅ Cron:       every minute (sends based on tier intervals)"
    echo "  ✅ Daily:      every day at 7:59 AM (full status, always sends)"
    echo "  ✅ Log:        $LOG_FILE"
    echo "  ✅ State dir:  $STATE_DIR"
    echo ""
    echo "  📋 Configuration:"
    echo "     VM Name:     $VM_NAME"
    echo "     Location:    $LOCATION"
    echo "     Network:     $NETWORK_VERSION"
    echo "     Owner (To:): $OWNER_NAME <$OWNER_EMAIL>"
    if [ -n "$CC_EMAILS" ]; then
        echo "     CC:          $CC_EMAILS"
    else
        echo "     CC:          (none)"
    fi
    echo ""
    echo "  📊 Alert tiers:"
    echo "     Disk >= 90%  → every 1h   → Telegram"
    echo "     Disk >= 80%  → every 6h   → Email"
    echo "     Disk >= 70%  → every 12h  → Email"
    echo "     Disk >= 60%  → every 24h  → Email"
    echo "     Disk <  60%  → no alert"
    echo "     RAM  >  ${RAM_ALERT_THRESHOLD}%   → every ${RAM_ALERT_INTERVAL}h   → Email"
    echo "     Daily report → 7:59 AM    → always sends"
    echo ""
}

# ─────────────────────────────────────────────────────────────────
#  Read a single variable value out of an installed script file
# ─────────────────────────────────────────────────────────────────
read_installed_var() {
    local varname="$1"
    local file="$2"
    grep "^${varname}=" "$file" | cut -d'"' -f2
}

# ─────────────────────────────────────────────────────────────────
update() {
    echo ""
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║       VM Metrics Reporter — Update           ║"
    echo "  ╚══════════════════════════════════════════════╝"

    # ── Verify the script is installed ───────────────────────────
    if [ ! -f "$SCRIPT_PATH" ]; then
        echo ""
        echo "  ❌ No installed script found at: $SCRIPT_PATH"
        echo "     Run --install first, then use --update for future upgrades."
        exit 1
    fi

    # ── Read every config value from the installed script ─────────
    echo ""
    echo "  📖 Reading config from installed script..."

    OLD_VM_NAME=$(       read_installed_var "VM_NAME"         "$SCRIPT_PATH")
    OLD_LOCATION=$(      read_installed_var "LOCATION"        "$SCRIPT_PATH")
    OLD_NETWORK_VERSION=$(read_installed_var "NETWORK_VERSION" "$SCRIPT_PATH")
    OLD_OWNER_NAME=$(    read_installed_var "OWNER_NAME"      "$SCRIPT_PATH")
    OLD_OWNER_EMAIL=$(   read_installed_var "OWNER_EMAIL"     "$SCRIPT_PATH")
    OLD_CC_EMAILS=$(     read_installed_var "CC_EMAILS"       "$SCRIPT_PATH")

    echo ""
    echo "  ✅ Config read from installed script:"
    echo "     VM Name:   ${OLD_VM_NAME:-(not set)}"
    echo "     Location:  ${OLD_LOCATION:-(not set)}"
    echo "     Network:   ${OLD_NETWORK_VERSION:-(not set)}"
    echo "     Owner:     ${OLD_OWNER_NAME:-(not set)} <${OLD_OWNER_EMAIL:-(not set)}>"
    echo "     CC:        ${OLD_CC_EMAILS:-(none)}"
    echo ""

    # ── Confirm before proceeding ─────────────────────────────────
    read -rep "  ❓ Proceed with update? (Y/n): " confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && { echo "  ⏹  Update cancelled."; exit 0; }

    # ── Backup the currently installed script ─────────────────────
    BACKUP_PATH="${SCRIPT_PATH}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$SCRIPT_PATH" "$BACKUP_PATH"
    echo "  💾 Backup saved → $BACKUP_PATH"

    # ── Install the new script ────────────────────────────────────
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    echo "  ✅ New script installed → $SCRIPT_PATH"

    # ── Re-apply the saved config ─────────────────────────────────
    patch_var "VM_NAME"          "$OLD_VM_NAME"          "$SCRIPT_PATH"
    patch_var "LOCATION"         "$OLD_LOCATION"         "$SCRIPT_PATH"
    patch_var "NETWORK_VERSION"  "$OLD_NETWORK_VERSION"  "$SCRIPT_PATH"
    patch_var "OWNER_NAME"       "$OLD_OWNER_NAME"       "$SCRIPT_PATH"
    patch_var "OWNER_EMAIL"      "$OLD_OWNER_EMAIL"      "$SCRIPT_PATH"
    patch_var "CC_EMAILS"        "$OLD_CC_EMAILS"        "$SCRIPT_PATH"
    echo "  ✅ Config restored (no wizard needed)"

    # ── Summary ───────────────────────────────────────────────────
    echo ""
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║             Update Complete ✅               ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo ""
    echo "  Script:   $SCRIPT_PATH"
    echo "  Backup:   $BACKUP_PATH"
    echo ""
    echo "  Config carried over:"
    echo "    VM Name:   ${OLD_VM_NAME:-(not set)}"
    echo "    Location:  ${OLD_LOCATION:-(not set)}"
    echo "    Network:   ${OLD_NETWORK_VERSION:-(not set)}"
    echo "    Owner:     ${OLD_OWNER_NAME:-(not set)} <${OLD_OWNER_EMAIL:-(not set)}>"
    echo "    CC:        ${OLD_CC_EMAILS:-(none)}"
    echo ""
    echo "  Run --status to verify everything is working."
    echo ""
}

# ─────────────────────────────────────────────────────────────────
uninstall() {
    echo "Uninstalling VM Metrics Reporter..."
    rm -f  "$CRON_FILE"                        # cron job
    rm -f  "$SCRIPT_PATH"                      # installed script
    rm -rf "$STATE_DIR"                        # all state/timer files
    rm -rf "$RUN_LOCK_DIR"                     # lock dir if stuck
    rm -f  "/tmp/vm_metrics_resp.txt"          # curl temp file
    rm -f  "$LOG_FILE"                         # log file
    rmdir  --ignore-fail-on-non-empty "$INSTALL_DIR" 2>/dev/null  # dir if empty
    echo "✅ Uninstalled. Everything removed:"
    echo "   - $CRON_FILE"
    echo "   - $SCRIPT_PATH"
    echo "   - $STATE_DIR"
    echo "   - $LOG_FILE"
}

# ─────────────────────────────────────────────────────────────────
status() {
    echo "========================================================"
    echo "  VM Metrics Reporter — Status"
    echo "========================================================"
    echo "  Script:   $([ -f "$SCRIPT_PATH" ] && echo "✅ $SCRIPT_PATH" || echo "❌ Not installed")"
    echo "  Cron:     $([ -f "$CRON_FILE" ] && echo "✅ Active" || echo "❌ Not found")"
    echo "  Webhook:  $N8N_WEBHOOK_URL"
    echo ""
    echo "  Configuration:"
    echo "    VM Name:     ${VM_NAME:-⚠️  not set}"
    echo "    Location:    ${LOCATION:-⚠️  not set}"
    echo "    Network:     ${NETWORK_VERSION:-⚠️  not set}"
    echo "    Owner (To:): ${OWNER_NAME:-⚠️  not set} <${OWNER_EMAIL:-}>"
    echo "    CC:          ${CC_EMAILS:-(none)}"
    echo ""

    RESOLVED_NAME="${VM_NAME:-$(hostname)}"
    PRIMARY_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)

    R_TOTAL=$(free -m | awk '/^Mem:/ {print $2}')
    R_USED=$(free  -m | awk '/^Mem:/ {print $3}')
    R_FREE=$(( R_TOTAL - R_USED ))
    R_PCT=$(awk "BEGIN {printf \"%.1f\", ($R_USED/$R_TOTAL)*100}")
    R_INT=$(awk "BEGIN {printf \"%d\",   ($R_USED/$R_TOTAL)*100}")
    R_TOTAL_GB=$(awk "BEGIN {printf \"%.2f\", $R_TOTAL/1024}")
    R_USED_GB=$(awk  "BEGIN {printf \"%.2f\", $R_USED/1024}")
    R_FREE_GB=$(awk  "BEGIN {printf \"%.2f\", $R_FREE/1024}")

    echo "  --- Live Snapshot ---"
    echo "    VM Name:  $RESOLVED_NAME"
    echo "    IP:       ${PRIMARY_IP:-unknown}"
    echo "    RAM:      ${R_PCT}% | ${R_USED_GB}GB used / ${R_TOTAL_GB}GB total / ${R_FREE_GB}GB free"
    if [ "$R_INT" -gt "$RAM_ALERT_THRESHOLD" ]; then
        echo "    RAM Alert: 🔴 ACTIVE (>${RAM_ALERT_THRESHOLD}%) → every ${RAM_ALERT_INTERVAL}h"
    else
        echo "    RAM Alert: ✅ OK (<=${RAM_ALERT_THRESHOLD}% — no alert)"
    fi
    echo "    Drives — physical layout (lsblk):"
    while IFS= read -r _lline; do
        echo "      $_lline"
    done < <(lsblk -o NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null)
    echo ""
    echo "    Drives — alert status:"
    while IFS='|' read -r _pn _dk _fst _av _us _pt _lb _wm _pty; do
        [ -z "$_pn" ] && continue
        [[ "$_pt" =~ ^[0-9]+$ ]] || continue
        _intv=$(get_disk_tier_interval "$_pt")
        _tier=$(get_disk_tier_label "$_pt")
        if [ "$_intv" != "none" ]; then
            _tier_str="$_tier → every $([ "$_intv" = "0" ] && echo "1 min" || echo "${_intv}h")"
        else
            _tier_str="✅ OK (< 60% — no alert)"
        fi
        _tgb=$(awk "BEGIN {printf \"%.1f\", $_fst/1073741824}")
        _ugb=$(awk "BEGIN {printf \"%.1f\", $_us/1073741824}")
        _fgb=$(awk "BEGIN {printf \"%.1f\", $_av/1073741824}")
        # Show partition name + worst mount for LVM containers
        if [[ "$_pty" == LVM* ]] && [ -n "$_wm" ]; then
            _display_name="${_pn} (worst: ${_wm})"
        else
            _display_name="$_lb"
        fi
        echo "      $_display_name  ${_pt}% | ${_ugb}GB used / ${_tgb}GB total / ${_fgb}GB free | $_tier_str"
    done < <(_collect_partitions)
    if [ -f /tmp/vm_metrics_collect_error ]; then
        echo "    ⚠️  Disk collection failed: $(cat /tmp/vm_metrics_collect_error)"
    fi
    echo "    Uptime:   $(awk '{d=int($1/86400);h=int(($1%86400)/3600);m=int(($1%3600)/60); printf "%dd %dh %dm",d,h,m}' /proc/uptime)"
    echo ""
    echo "  --- Last Alert Times ---"
    if ls "$STATE_DIR"/ 2>/dev/null | grep -q .; then
        for f in "$STATE_DIR"/*; do
            [ -f "$f" ] || continue
            fname=$(basename "$f")
            ts=$(cat "$f")
            human=$(date -d "@$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "epoch=$ts")
            echo "    $fname: last sent $human"
        done
    else
        echo "    (no alerts sent yet)"
    fi
    echo ""
    echo "  --- Last 20 Log Entries ---"
    tail -20 "$LOG_FILE" 2>/dev/null || echo "  (no logs yet)"
}

# ─────────────────────────────────────────────────────────────────
simulate() {
    local DISK_PCT="${2:-85}"
    local RAM_PCT="${3:-75}"
    echo "Simulating: Disk=${DISK_PCT}% | RAM=${RAM_PCT}%"

    TIMESTAMP=$(get_timestamp)
    RESOLVED_NAME="${VM_NAME:-$(hostname -f 2>/dev/null || hostname)}"
    PRIMARY_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    [ -z "$PRIMARY_IP" ] && PRIMARY_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

    DISK_INTERVAL=$(get_disk_tier_interval "$DISK_PCT")
    DISK_TIER=$(get_disk_tier_label "$DISK_PCT")
    ISSUES_JSON=""
    HAS_ISSUES="false"
    MAX_PCT=0

    # ── Collect real partition data; find root partition for override ──
    _SIM_PARTS=$(_collect_partitions)
    if [ -f /tmp/vm_metrics_collect_error ]; then
        echo "⚠️  Disk collection failed: $(cat /tmp/vm_metrics_collect_error)"
        log "⚠️  Disk collection failed: $(cat /tmp/vm_metrics_collect_error)"
    fi
    _SIM_ROOT_PART=""; _SIM_ROOT_FST_B=0; _SIM_ROOT_AVAIL_B=0; _SIM_ROOT_USED_B=0
    _SIM_ROOT_WORST=""; _SIM_ROOT_PTY=""
    while IFS='|' read -r _pn _dk _fst _av _us _pt _lb _wm _pty; do
        [[ "$_pty" == *ROOT* ]] || continue
        _SIM_ROOT_PART="$_pn"; _SIM_ROOT_FST_B="$_fst"
        _SIM_ROOT_AVAIL_B="$_av"; _SIM_ROOT_USED_B="$_us"
        _SIM_ROOT_WORST="$_wm"; _SIM_ROOT_PTY="$_pty"
        break
    done <<< "$_SIM_PARTS"
    # Compute simulated root sizes based on DISK_PCT% of real fs total
    _SIM_ROOT_TOTAL=$(awk "BEGIN {printf \"%.1f\", ${_SIM_ROOT_FST_B:-21474836480}/1073741824}")
    _SIM_ROOT_USED_B_S=$(awk "BEGIN {printf \"%.0f\", ${_SIM_ROOT_FST_B:-21474836480}*$DISK_PCT/100}")
    _SIM_ROOT_AVAIL_B_S=$(( ${_SIM_ROOT_FST_B:-21474836480} - ${_SIM_ROOT_USED_B_S:-0} ))
    _SIM_ROOT_USED=$(awk "BEGIN {printf \"%.1f\", ${_SIM_ROOT_USED_B_S:-0}/1073741824}")
    _SIM_ROOT_FREE=$(awk "BEGIN {printf \"%.1f\", ${_SIM_ROOT_AVAIL_B_S:-0}/1073741824}")
    # Alert label for root: "sda4 → /usr" or just partition/mount name
    if [[ "$_SIM_ROOT_PTY" == LVM* ]] && [ -n "$_SIM_ROOT_WORST" ]; then
        _SIM_ROOT_LABEL="${_SIM_ROOT_PART} → ${_SIM_ROOT_WORST}"
    else
        _SIM_ROOT_LABEL="${_SIM_ROOT_PART:-disk}"
    fi

    if [ "$DISK_INTERVAL" != "none" ]; then
        HAS_ISSUES="true"
        if   [ "$DISK_PCT" -ge 90 ]; then D_SEV="critical"
        elif [ "$DISK_PCT" -ge 80 ]; then D_SEV="warning"
        elif [ "$DISK_PCT" -ge 70 ]; then D_SEV="notice"
        elif [ "$DISK_PCT" -ge 60 ]; then D_SEV="info"
        else                               D_SEV="test"; fi
        SIM_INTERVAL_VAL=$([ "$DISK_INTERVAL" = "0" ] && echo 0 || echo "$DISK_INTERVAL")
        ISSUES_JSON="{\"type\":\"DISK\",\"message\":\"${_SIM_ROOT_LABEL} at ${DISK_PCT}% — ${_SIM_ROOT_FREE}GB free of ${_SIM_ROOT_TOTAL}GB\",\"severity\":\"$D_SEV\",\"tier\":\"$DISK_TIER\",\"alert_interval_hours\":$SIM_INTERVAL_VAL}"
        MAX_PCT=$DISK_PCT
    fi

    if [ "$RAM_PCT" -gt "$RAM_ALERT_THRESHOLD" ]; then
        HAS_ISSUES="true"
        R_TOTAL_SIM=8500
        R_USED_SIM=$(awk "BEGIN {printf \"%d\", $RAM_PCT * 8500 / 100}")
        R_FREE_SIM=$(( R_TOTAL_SIM - R_USED_SIM ))
        R_USED_GB=$(awk "BEGIN {printf \"%.2f\", $R_USED_SIM/1024}")
        R_FREE_GB=$(awk "BEGIN {printf \"%.2f\", $R_FREE_SIM/1024}")
        RAM_ISSUE="{\"type\":\"RAM\",\"message\":\"RAM at ${RAM_PCT}% — ${R_FREE_GB}GB free of 8.30GB (${R_USED_SIM}MB used / ${R_TOTAL_SIM}MB total)\",\"severity\":\"warning\",\"tier\":\">80%\",\"alert_interval_hours\":$RAM_ALERT_INTERVAL}"
        ISSUES_JSON="${ISSUES_JSON:+$ISSUES_JSON,}$RAM_ISSUE"
        [ "$RAM_PCT" -gt "$MAX_PCT" ] && MAX_PCT=$RAM_PCT
    fi

    if [ "$HAS_ISSUES" = "false" ]; then
        echo "ℹ️  Disk ${DISK_PCT}% and RAM ${RAM_PCT}% are both below thresholds. No alert would be sent."
        exit 0
    fi

    if   [ "$MAX_PCT" -ge 90 ]; then SEV_LABEL="🔴 CRITICAL"; SEVERITY="CRITICAL"
    elif [ "$MAX_PCT" -ge 80 ]; then SEV_LABEL="🟠 WARNING";  SEVERITY="WARNING"
    elif [ "$MAX_PCT" -ge 70 ]; then SEV_LABEL="🟡 NOTICE";   SEVERITY="NOTICE"
    else                               SEV_LABEL="🔵 INFO";    SEVERITY="INFO"; fi

    # Build SIM_MOUNTS_JSON — override root partition, keep all others real
    SIM_MOUNTS_JSON=""
    while IFS='|' read -r _pn _dk _fst _av _us _pt _lb _wm _pty; do
        [ -z "$_pn" ] && continue; [[ "$_pt" =~ ^[0-9]+$ ]] || continue
        if [ "$_pn" = "$_SIM_ROOT_PART" ] && [[ "$_pty" == *ROOT* ]]; then
            _entry="{\"mount\":\"$_lb\",\"total_gb\":${_SIM_ROOT_TOTAL},\"used_gb\":${_SIM_ROOT_USED},\"free_gb\":${_SIM_ROOT_FREE},\"usage_pct\":${DISK_PCT}}"
        else
            _tgb=$(awk "BEGIN {printf \"%.1f\", $_fst/1073741824}")
            _ugb=$(awk "BEGIN {printf \"%.1f\", $_us/1073741824}")
            _fgb=$(awk "BEGIN {printf \"%.1f\", $_av/1073741824}")
            _entry="{\"mount\":\"$_lb\",\"total_gb\":$_tgb,\"used_gb\":$_ugb,\"free_gb\":$_fgb,\"usage_pct\":$_pt}"
        fi
        SIM_MOUNTS_JSON="${SIM_MOUNTS_JSON:+$SIM_MOUNTS_JSON,}$_entry"
    done <<< "$_SIM_PARTS"
    [ -z "$SIM_MOUNTS_JSON" ] && SIM_MOUNTS_JSON="{\"mount\":\"${_SIM_ROOT_PART:-disk}\",\"total_gb\":${_SIM_ROOT_TOTAL:-20},\"used_gb\":${_SIM_ROOT_USED:-17},\"free_gb\":${_SIM_ROOT_FREE:-3},\"usage_pct\":${DISK_PCT}}"

    PAYLOAD=$(cat <<SIMPAYLOAD
{
  "vm_name": "$RESOLVED_NAME",
  "ip": { "primary": "$PRIMARY_IP", "all": "$PRIMARY_IP" },
  "location": "${LOCATION:-not set}",
  "timestamp": "$TIMESTAMP",
  "is_daily": false,
  "os_type": "linux",
  "has_issues": true,
  "severity": "$SEVERITY",
  "network_version": "$NETWORK_VERSION",
  "owner": { "name": "$OWNER_NAME", "email": "$OWNER_EMAIL" },
  "cc_emails": "$CC_EMAILS",
  "resource_issues": [$ISSUES_JSON],
  "ram": {
    "total_gb": 8.30,
    "used_gb": ${R_USED_GB:-6.63},
    "free_gb": ${R_FREE_GB:-1.67},
    "total_mb": ${R_TOTAL_SIM:-8500},
    "used_mb": ${R_USED_SIM:-7000},
    "free_mb": ${R_FREE_SIM:-1500},
    "usage_pct": $RAM_PCT
  },
  "disk": {
    "root": { "total_gb": ${_SIM_ROOT_TOTAL:-20}, "used_gb": ${_SIM_ROOT_USED:-17}, "free_gb": ${_SIM_ROOT_FREE:-3}, "usage_pct": $DISK_PCT },
    "all_mounts": [$SIM_MOUNTS_JSON]
  }
}
SIMPAYLOAD
)

    log "🧪 SIMULATE: disk=${DISK_PCT}% | ram=${RAM_PCT}% | net=$NETWORK_VERSION | owner=$OWNER_NAME | $SEV_LABEL"

    HTTP_STATUS=$(curl -s -o /tmp/vm_metrics_resp.txt -w "%{http_code}" \
        -X POST "$N8N_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        --max-time 30)

    RESPONSE=$(cat /tmp/vm_metrics_resp.txt 2>/dev/null)
    if [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 300 ]; then
        log "✅ Simulated alert sent (HTTP $HTTP_STATUS)"
        echo "✅ Done — check Telegram & Email"
    else
        log "❌ Failed (HTTP $HTTP_STATUS): $RESPONSE"
    fi
}

# ─────────────────────────────────────────────────────────────────
simulate_daily() {
    local DISK_PCT="${2:-55}"
    local RAM_PCT="${3:-60}"
    echo "Simulating DAILY report: Disk=${DISK_PCT}% | RAM=${RAM_PCT}% | is_daily=true"

    TIMESTAMP=$(get_timestamp)
    RESOLVED_NAME="${VM_NAME:-$(hostname -f 2>/dev/null || hostname)}"
    PRIMARY_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    [ -z "$PRIMARY_IP" ] && PRIMARY_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

    DISK_INTERVAL=$(get_disk_tier_interval "$DISK_PCT")
    DISK_TIER=$(get_disk_tier_label "$DISK_PCT")

    # ── Collect real partition data; find root partition for override ──
    _SIM_PARTS=$(_collect_partitions)
    if [ -f /tmp/vm_metrics_collect_error ]; then
        echo "⚠️  Disk collection failed: $(cat /tmp/vm_metrics_collect_error)"
        log "⚠️  Disk collection failed: $(cat /tmp/vm_metrics_collect_error)"
    fi
    _SIM_ROOT_PART=""; _SIM_ROOT_FST_B=0
    _SIM_ROOT_WORST=""; _SIM_ROOT_PTY=""
    while IFS='|' read -r _pn _dk _fst _av _us _pt _lb _wm _pty; do
        [[ "$_pty" == *ROOT* ]] || continue
        _SIM_ROOT_PART="$_pn"; _SIM_ROOT_FST_B="$_fst"
        _SIM_ROOT_WORST="$_wm"; _SIM_ROOT_PTY="$_pty"
        break
    done <<< "$_SIM_PARTS"
    _SIM_ROOT_TOTAL=$(awk "BEGIN {printf \"%.1f\", ${_SIM_ROOT_FST_B:-21474836480}/1073741824}")
    _SIM_ROOT_USED_B_S=$(awk "BEGIN {printf \"%.0f\", ${_SIM_ROOT_FST_B:-21474836480}*$DISK_PCT/100}")
    _SIM_ROOT_AVAIL_B_S=$(( ${_SIM_ROOT_FST_B:-21474836480} - ${_SIM_ROOT_USED_B_S:-0} ))
    _SIM_ROOT_USED=$(awk "BEGIN {printf \"%.1f\", ${_SIM_ROOT_USED_B_S:-0}/1073741824}")
    _SIM_ROOT_FREE=$(awk "BEGIN {printf \"%.1f\", ${_SIM_ROOT_AVAIL_B_S:-0}/1073741824}")
    if [[ "$_SIM_ROOT_PTY" == LVM* ]] && [ -n "$_SIM_ROOT_WORST" ]; then
        _SIM_ROOT_LABEL="${_SIM_ROOT_PART} → ${_SIM_ROOT_WORST}"
    else
        _SIM_ROOT_LABEL="${_SIM_ROOT_PART:-disk}"
    fi

    # Daily always includes disk — even if below all alert tiers
    if   [ "$DISK_PCT" -ge 90 ]; then D_SEV="critical"
    elif [ "$DISK_PCT" -ge 80 ]; then D_SEV="warning"
    elif [ "$DISK_PCT" -ge 70 ]; then D_SEV="notice"
    elif [ "$DISK_PCT" -ge 60 ]; then D_SEV="info"
    else                               D_SEV="ok"; fi
    SIM_INTERVAL_VAL=$([ "$DISK_INTERVAL" = "none" ] && echo 0 || { [ "$DISK_INTERVAL" = "0" ] && echo 0 || echo "$DISK_INTERVAL"; })
    ISSUES_JSON="{\"type\":\"DISK\",\"message\":\"${_SIM_ROOT_LABEL} at ${DISK_PCT}% — ${_SIM_ROOT_FREE}GB free of ${_SIM_ROOT_TOTAL}GB\",\"severity\":\"$D_SEV\",\"tier\":\"$DISK_TIER\",\"alert_interval_hours\":$SIM_INTERVAL_VAL}"
    MAX_PCT=$DISK_PCT

    # Daily always includes RAM
    R_TOTAL_SIM=8500
    R_USED_SIM=$(awk "BEGIN {printf \"%d\", $RAM_PCT * 8500 / 100}")
    R_FREE_SIM=$(( R_TOTAL_SIM - R_USED_SIM ))
    R_USED_GB=$(awk "BEGIN {printf \"%.2f\", $R_USED_SIM/1024}")
    R_FREE_GB=$(awk "BEGIN {printf \"%.2f\", $R_FREE_SIM/1024}")
    if [ "$RAM_PCT" -gt "$RAM_ALERT_THRESHOLD" ]; then RAM_SEV="warning"; else RAM_SEV="ok"; fi
    RAM_ISSUE="{\"type\":\"RAM\",\"message\":\"RAM at ${RAM_PCT}% — ${R_FREE_GB}GB free of 8.30GB (${R_USED_SIM}MB used / ${R_TOTAL_SIM}MB total)\",\"severity\":\"$RAM_SEV\",\"tier\":\">80%\",\"alert_interval_hours\":$RAM_ALERT_INTERVAL}"
    ISSUES_JSON="${ISSUES_JSON},${RAM_ISSUE}"
    [ "$RAM_PCT" -gt "$MAX_PCT" ] && MAX_PCT=$RAM_PCT

    if   [ "$MAX_PCT" -ge 90 ]; then SEV_LABEL="🔴 CRITICAL"; SEVERITY="CRITICAL"
    elif [ "$MAX_PCT" -ge 80 ]; then SEV_LABEL="🟠 WARNING";  SEVERITY="WARNING"
    elif [ "$MAX_PCT" -ge 70 ]; then SEV_LABEL="🟡 NOTICE";   SEVERITY="NOTICE"
    else                               SEV_LABEL="🔵 INFO";    SEVERITY="INFO"; fi

    # Build SIM_MOUNTS_JSON — override root partition, keep all others real
    SIM_MOUNTS_JSON=""
    while IFS='|' read -r _pn _dk _fst _av _us _pt _lb _wm _pty; do
        [ -z "$_pn" ] && continue; [[ "$_pt" =~ ^[0-9]+$ ]] || continue
        if [ "$_pn" = "$_SIM_ROOT_PART" ] && [[ "$_pty" == *ROOT* ]]; then
            _entry="{\"mount\":\"$_lb\",\"total_gb\":${_SIM_ROOT_TOTAL},\"used_gb\":${_SIM_ROOT_USED},\"free_gb\":${_SIM_ROOT_FREE},\"usage_pct\":${DISK_PCT}}"
        else
            _tgb=$(awk "BEGIN {printf \"%.1f\", $_fst/1073741824}")
            _ugb=$(awk "BEGIN {printf \"%.1f\", $_us/1073741824}")
            _fgb=$(awk "BEGIN {printf \"%.1f\", $_av/1073741824}")
            _entry="{\"mount\":\"$_lb\",\"total_gb\":$_tgb,\"used_gb\":$_ugb,\"free_gb\":$_fgb,\"usage_pct\":$_pt}"
        fi
        SIM_MOUNTS_JSON="${SIM_MOUNTS_JSON:+$SIM_MOUNTS_JSON,}$_entry"
    done <<< "$_SIM_PARTS"
    [ -z "$SIM_MOUNTS_JSON" ] && SIM_MOUNTS_JSON="{\"mount\":\"${_SIM_ROOT_PART:-disk}\",\"total_gb\":${_SIM_ROOT_TOTAL:-20},\"used_gb\":${_SIM_ROOT_USED:-11},\"free_gb\":${_SIM_ROOT_FREE:-9},\"usage_pct\":${DISK_PCT}}"

    PAYLOAD=$(cat <<SIMPAYLOAD
{
  "vm_name": "$RESOLVED_NAME",
  "ip": { "primary": "$PRIMARY_IP", "all": "$PRIMARY_IP" },
  "location": "${LOCATION:-not set}",
  "timestamp": "$TIMESTAMP",
  "is_daily": true,
  "os_type": "linux",
  "has_issues": true,
  "severity": "$SEVERITY",
  "network_version": "$NETWORK_VERSION",
  "owner": { "name": "$OWNER_NAME", "email": "$OWNER_EMAIL" },
  "cc_emails": "$CC_EMAILS",
  "resource_issues": [$ISSUES_JSON],
  "ram": {
    "total_gb": 8.30,
    "used_gb": ${R_USED_GB:-5.10},
    "free_gb": ${R_FREE_GB:-3.20},
    "total_mb": ${R_TOTAL_SIM:-8500},
    "used_mb": ${R_USED_SIM:-5100},
    "free_mb": ${R_FREE_SIM:-3400},
    "usage_pct": $RAM_PCT
  },
  "disk": {
    "root": { "total_gb": ${_SIM_ROOT_TOTAL:-20}, "used_gb": ${_SIM_ROOT_USED:-11}, "free_gb": ${_SIM_ROOT_FREE:-9}, "usage_pct": $DISK_PCT },
    "all_mounts": [$SIM_MOUNTS_JSON]
  }
}
SIMPAYLOAD
)

    log "🧪 SIMULATE-DAILY: disk=${DISK_PCT}% | ram=${RAM_PCT}% | is_daily=true | net=$NETWORK_VERSION | owner=$OWNER_NAME | $SEV_LABEL"

    HTTP_STATUS=$(curl -s -o /tmp/vm_metrics_resp.txt -w "%{http_code}" \
        -X POST "$N8N_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        --max-time 30)

    RESPONSE=$(cat /tmp/vm_metrics_resp.txt 2>/dev/null)
    if [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 300 ]; then
        log "✅ Simulated daily report sent (HTTP $HTTP_STATUS)"
        echo "✅ Done — check n8n (is_daily=true, no Telegram/Email alert expected)"
    else
        log "❌ Failed (HTTP $HTTP_STATUS): $RESPONSE"
    fi
}

# ─────────────────────────────────────────────────────────────────
case "${1:-}" in
    --install)   install ;;
    --update)    update ;;
    --uninstall) uninstall ;;
    --run)
        [ "$(date '+%H%M')" = "$DAILY_REPORT_TIME" ] && exit 0
        if acquire_run_lock; then
            trap 'release_run_lock' EXIT
            send_metrics
        fi
        ;;
    --daily)
        SKIP_INTERVAL_CHECK="true"
        log "📅 Daily 7:59 AM report — sending full status..."
        # Retry for up to 30s in case the per-minute --run cron fired at the same second
        _daily_locked=false
        for _i in 1 2 3 4 5 6; do
            if acquire_run_lock; then
                _daily_locked=true
                break
            fi
            sleep 5
        done
        if [ "$_daily_locked" = "true" ]; then
            trap 'release_run_lock' EXIT
            send_metrics
        else
            log "❌ Daily report failed: could not acquire lock"
        fi
        ;;
    --force)
        rm -f "$STATE_DIR"/disk_tier_* "$STATE_DIR/ram_alert" 2>/dev/null
        log "🔧 Forced: cleared state, sending now..."
        SKIP_INTERVAL_CHECK="true"
        FORCE_SEND="true"
        if acquire_run_lock; then
            trap 'release_run_lock' EXIT
            send_metrics
        else
            log "❌ Force failed: could not acquire lock"
        fi
        ;;
    --status)           status ;;
    --simulate)         simulate "$@" ;;
    --simulate-daily)   simulate_daily "$@" ;;
    *)
        echo ""
        echo "  VM Metrics Reporter"
        echo "  Compatible: Ubuntu 20.04+ / Debian 10+"
        echo "  Usage: $0 [OPTION]"
        echo ""
        echo "    --install                  Run setup wizard + install cron"
        echo "    --update                   Install new version, keep existing config"
        echo "    --uninstall                Remove everything"
        echo "    --run                      Run check (sends only if interval elapsed)"
        echo "    --daily                    Send full status now (ignores all intervals)"
        echo "    --force                    Send immediately, ignore all timers"
        echo "    --status                   Show config + live snapshot + last alerts"
        echo "    --simulate [D] [R]         Test alert: D=disk%, R=ram% (defaults: 85 75)"
        echo "                                 --simulate 92        (disk 92%, Telegram+Email)"
        echo "                                 --simulate 85 85     (disk 85%, Email)"
        echo "                                 --simulate 65 50     (disk 65%, Email)"
        echo "                                 --simulate 5 50      (nothing sent — below all tiers)"
        echo "    --simulate-daily [D] [R]   Test daily report: always sends, is_daily=true"
        echo "                                 --simulate-daily          (disk 55%, RAM 60%)"
        echo "                                 --simulate-daily 85 70    (disk 85%, RAM 70%)"
        echo "                                 --simulate-daily 92 50    (disk 92%, RAM 50%)"
        echo ""
        echo "  Disk tiers:"
        echo "    >= 90%  →  every 1h   → Telegram"
        echo "    >= 80%  →  every 6h   → Email"
        echo "    >= 70%  →  every 12h  → Email"
        echo "    >= 60%  →  every 24h  → Email"
        echo "    <  60%  →  no alert"
        echo ""
        echo "  RAM: > ${RAM_ALERT_THRESHOLD}% (used/total) → every ${RAM_ALERT_INTERVAL}h → Email"
        echo "  Daily: 7:59 AM every day → always sends full status (is_daily=true)"
        echo ""
        ;;
esac