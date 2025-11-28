#!/usr/bin/env bash
# single.sh — Safe Extreme Performance profile for Kali (reversible)
# Usage: sudo bash single.sh
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/perf-backups-$TIMESTAMP"
REVERT_SH="/usr/local/sbin/perf-revert-$TIMESTAMP.sh"
LOG="/var/log/perf-optimize-$TIMESTAMP.log"

if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root. Use: sudo bash $SCRIPT_NAME"
  exit 1
fi

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

echo "[$(date +'%F %T')] Starting performance script" | tee -a "$LOG"

# --------------------
# Helper: backup file
# --------------------
backup_file() {
  local f="$1"
  if [ -e "$f" ]; then
    mkdir -p "$BACKUP_DIR$(dirname "$f")"
    cp -a "$f" "$BACKUP_DIR$f"
  fi
}

# --------------------
# 0. Save list of disabled services (for revert)
# --------------------
DISABLE_SERVICES=(
  "cups.service"
  "cups-browsed.service"
  "avahi-daemon.service"
  "ModemManager.service"
  "whoopsie.service"
  "apt-daily.timer"
  "apt-daily-upgrade.timer"
)

echo "Services to be disabled: ${DISABLE_SERVICES[*]}" | tee -a "$LOG"

# --------------------
# 1. Backup important configs
# --------------------
echo "Backing up configs to $BACKUP_DIR" | tee -a "$LOG"
backup_file /etc/sysctl.d/99-swappiness.conf
backup_file /etc/sysctl.d/99-perf.conf
backup_file /etc/default/zramswap
backup_file /etc/default/cpufrequtils
backup_file /etc/default/grub
backup_file /etc/systemd/system/systemd-networkd-wait-online.service
backup_file /etc/NetworkManager/NetworkManager.conf
backup_file /etc/apt/apt.conf.d/99performance || true

# --------------------
# 2. Install required packages
# --------------------
apt update || true
DEBIAN_FRONTEND=noninteractive apt install -y zram-tools cpufrequtils preload >/dev/null 2>&1 || {
  echo "apt install had errors — continuing (some packages may already be present)" | tee -a "$LOG"
}

# --------------------
# 3. Configure zram
# --------------------
echo "Configuring zram..." | tee -a "$LOG"
echo "PERCENT=75" > /etc/default/zramswap
chmod 644 /etc/default/zramswap

systemctl daemon-reload
systemctl enable --now zramswap.service >/dev/null 2>&1 || echo "Failed to enable zramswap (continuing)" | tee -a "$LOG"

# --------------------
# 4. Sysctl performance settings (swappiness + cache pressure)
# --------------------
echo "Writing sysctl perf config..." | tee -a "$LOG"
cat > /etc/sysctl.d/99-perf.conf <<'EOF'
# Performance tuning for low-RAM systems
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
chmod 644 /etc/sysctl.d/99-perf.conf
sysctl --system >/dev/null 2>&1 || true

# --------------------
# 5. CPU governor: set to performance
# --------------------
echo "Setting CPU governor to performance..." | tee -a "$LOG"
cat > /etc/default/cpufrequtils <<'EOF'
GOVERNOR="performance"
EOF
chmod 644 /etc/default/cpufrequtils
systemctl daemon-reload

# try start/restart cpufrequtils if available
if systemctl list-unit-files | grep -q '^cpufrequtils'; then
  systemctl enable --now cpufrequtils.service >/dev/null 2>&1 || true
fi

# set governor for current cores
if command -v cpufreq-set >/dev/null 2>&1; then
  for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    core=$(basename "$cpu")
    cpufreq-set -c "${core#cpu}" -g performance >/dev/null 2>&1 || true
  done
else
  # fallback: write to scaling_governor (suppress errors)
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$g" 2>/dev/null || true
  done
fi

# --------------------
# 6. Enable preload (app prefetcher)
# --------------------
echo "Enabling preload..." | tee -a "$LOG"
systemctl enable --now preload.service >/dev/null 2>&1 || true

# --------------------
# 7. Clean apt/journal
# --------------------
echo "Cleaning apt cache and old packages..." | tee -a "$LOG"
apt autoremove -y >/dev/null 2>&1 || true
apt autoclean -y >/dev/null 2>&1 || true
apt clean >/dev/null 2>&1 || true

echo "Vacuuming journal logs to 50M..." | tee -a "$LOG"
journalctl --vacuum-size=50M >/dev/null 2>&1 || true

# --------------------
# 8. Disable/mask nonessential services (safe list)
# --------------------
echo "Disabling non-essential services (kept Bluetooth enabled) ..." | tee -a "$LOG"
for svc in "${DISABLE_SERVICES[@]}"; do
  if systemctl list-unit-files | grep -q "^${svc}"; then
    echo "Disabling $svc" | tee -a "$LOG"
    systemctl disable --now "$svc" >/dev/null 2>&1 || true
  else
    echo "Service $svc not present — skipping" | tee -a "$LOG"
  fi
done

# Speed up boot: mask systemd-networkd-wait-online.service to avoid long waits
if systemctl list-unit-files | grep -q systemd-networkd-wait-online.service; then
  echo "Masking systemd-networkd-wait-online.service" | tee -a "$LOG"
  systemctl mask systemd-networkd-wait-online.service >/dev/null 2>&1 || true
fi

# --------------------
# 9. Minor UI tweaks for XFCE (disable compositor)
# --------------------
if command -v xfconf-query >/dev/null 2>&1; then
  echo "Disabling XFWM compositor (makes desktop snappier)..." | tee -a "$LOG"
  xfconf-query -c xfwm4 -p /general/use_compositing -s false >/dev/null 2>&1 || true
fi

# --------------------
# 10. Optional: reduce frequent apt timers to avoid background I/O
# --------------------
echo "Disabling apt daily timers (to reduce background I/O)..." | tee -a "$LOG"
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true

# --------------------
# 11. Boot optimization
# --------------------
echo "Masking systemd-networkd-wait-online.service (if present) to speed boot..." | tee -a "$LOG"
systemctl mask systemd-networkd-wait-online.service >/dev/null 2>&1 || true

# --------------------
# 12. Create revert script (safe restore)
# --------------------
echo "Creating revert script at $REVERT_SH" | tee -a "$LOG"
cat > "$REVERT_SH" <<'REVERT_EOF'
#!/usr/bin/env bash
set -euo pipefail
BACKUP_DIR="@BACKUP_DIR@"
if [ ! -d "$BACKUP_DIR" ]; then
  echo "Backup directory $BACKUP_DIR not found. Manual revert required."
  exit 1
fi
# Restore configs if present
cp -a "$BACKUP_DIR"/etc/sysctl.d/99-swappiness.conf /etc/sysctl.d/99-swappiness.conf 2>/dev/null || true
cp -a "$BACKUP_DIR"/etc/sysctl.d/99-perf.conf /etc/sysctl.d/99-perf.conf 2>/dev/null || true
cp -a "$BACKUP_DIR"/etc/default/zramswap /etc/default/zramswap 2>/dev/null || true
cp -a "$BACKUP_DIR"/etc/default/cpufrequtils /etc/default/cpufrequtils 2>/dev/null || true

# Re-enable services we disabled (best-effort)
SERVICES=(cups.service cups-browsed.service avahi-daemon.service ModemManager.service whoopsie.service apt-daily.timer apt-daily-upgrade.timer)
for s in "${SERVICES[@]}"; do
  if systemctl list-unit-files | grep -q "^${s}"; then
    systemctl unmask "$s" >/dev/null 2>&1 || true
    systemctl enable --now "$s" >/dev/null 2>&1 || true
  fi
done

# Unmask network wait online if previously masked
systemctl unmask systemd-networkd-wait-online.service >/dev/null 2>&1 || true

echo "To fully revert zram/preload you may need to disable zramswap.service and preload.service manually:"
echo "  sudo systemctl disable --now zramswap.service preload.service"
echo "Revert script finished."
REVERT_EOF

# inject actual BACKUP_DIR into the revert script
sed -i "s|@BACKUP_DIR@|$BACKUP_DIR|g" "$REVERT_SH"
chmod 750 "$REVERT_SH"

# --------------------
# 13. Final sync & summary
# --------------------
echo "Syncing filesystem and summarizing changes..." | tee -a "$LOG"
sync

cat > "$BACKUP_DIR/README" <<EOF
Performance optimization backup created on $TIMESTAMP.
Backups of original config files (if they existed) are in this folder and subfolders.
To revert most changes run:
  sudo bash $REVERT_SH
Files backed up from this run:
$(ls -R "$BACKUP_DIR" | sed 's/^/ - /')
EOF

echo "Optimization complete. A revert helper is created at: $REVERT_SH" | tee -a "$LOG"
echo "Backup folder: $BACKUP_DIR" | tee -a "$LOG"
echo "Log file: $LOG" | tee -a "$LOG"
echo "Reboot recommended to apply all changes (especially governor & zram):"
echo "  sudo reboot"

exit 0
