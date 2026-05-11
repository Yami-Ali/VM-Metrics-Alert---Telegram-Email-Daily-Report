#!/bin/bash
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --uninstall 2>/dev/null
sudo timedatectl set-timezone Asia/Baghdad
sudo timedatectl set-ntp true
curl -fsSL "https://raw.githubusercontent.com/Yami-Ali/VM-Metrics-Alert---Telegram-Email-Daily-Report/main/vm_metrics_reporter%20.sh" -o vm_metrics_reporter.sh
sed -i 's/\r//' vm_metrics_reporter.sh
sudo bash vm_metrics_reporter.sh --install
