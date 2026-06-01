#!/bin/bash
sudo bash /opt/vm-metrics/vm_metrics_reporter.sh --uninstall 2>/dev/null
curl -fsSL "https://raw.githubusercontent.com/Yami-Ali/VM-Metrics-Alert---Telegram-Email-Daily-Report/main/vm_metrics_reporter.sh" -o vm_metrics_reporter.sh
sed -i 's/\r//' vm_metrics_reporter.sh
sudo bash vm_metrics_reporter.sh --install
