#!/bin/bash
# =============================================================================
# ViciBox Fix Script v3.0
# Fixes:
#   1)  Time sync (system + MySQL + ViciDial)
#   2)  SSH access after DynPortal auth (firewall)
#   3)  ViciDial user levels (5001-5020)
#   4)  Hostname resolution
#   5)  Asterisk SIP externip + SERVER_EXTERNAL_IP placeholder
#   6)  Asterisk WebRTC/WSS TLS cert
#   7)  Disable broken Asterisk modules (no DAHDI)
#   8)  Restart Asterisk
#   9)  Fail2Ban (SSH + SIP brute force)
#   10) Apache DynPortal ports (81 + 446)
#   11) Disable VB-firewall cron jobs
#   12) Restart web server
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${GREEN}[OK]${NC}  $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[FAIL]${NC} $1"; }
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
section() {
    echo -e "\n${BLUE}══════════════════════════════════════════${NC}"
    echo -e "${BLUE} $1${NC}"
    echo -e "${BLUE}══════════════════════════════════════════${NC}"
}

# ── Config — edit these for your setup ───────────────────────────────────────
TIMEZONE="America/New_York"
DB_USER="root"
DB_PASS=""
DB_NAME="master"
SSH_PORT="2008"
DYNPORTAL_ZONE="external"
PUBLIC_ZONE="public"
SERVER_IP="94.130.37.67"
HOSTNAME="dialer201"
ACME_DIR="/root/.acme.sh"
DOMAIN=""   # auto-detected if blank

mysql_cmd() {
    [ -z "$DB_PASS" ] && mysql -u"$DB_USER" "$@" || mysql -u"$DB_USER" -p"$DB_PASS" "$@"
}

if [ "$EUID" -ne 0 ]; then
    error "Please run as root"
    exit 1
fi

echo -e "${BLUE}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║       ViciBox Fix Script v3.0            ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${NC}"

# =============================================================================
section "STEP 1 — System Time Sync"
# =============================================================================

info "Setting timezone to $TIMEZONE"
timedatectl set-timezone "$TIMEZONE" && log "Timezone set to $TIMEZONE" || error "Failed to set timezone"

info "Starting chronyd"
systemctl enable chronyd --now &>/dev/null
systemctl is-active --quiet chronyd && log "chronyd running" || warn "chronyd not running"

info "Forcing NTP sync"
chronyc makestep &>/dev/null && log "NTP sync forced" || \
    { ntpdate -u pool.ntp.org &>/dev/null && log "ntpdate sync done" || error "NTP sync failed"; }

hwclock --systohc && log "Hardware clock synced"
info "System time: $(date)"

# =============================================================================
section "STEP 2 — MySQL Time Sync"
# =============================================================================

if ! mysql_cmd -e "SELECT 1;" &>/dev/null; then
    error "Cannot connect to MySQL — skipping MySQL fixes"
else
    log "MySQL connection OK"

    if ! mysql_cmd -e "USE $DB_NAME;" &>/dev/null; then
        warn "DB '$DB_NAME' not found — searching"
        FOUND=$(mysql_cmd -e "SELECT table_schema FROM information_schema.tables WHERE table_name='system_settings' LIMIT 1;" 2>/dev/null | tail -1)
        [ -n "$FOUND" ] && [ "$FOUND" != "table_schema" ] && \
            DB_NAME="$FOUND" && log "Found DB: $DB_NAME" || \
            { error "ViciDial DB not found"; DB_NAME=""; }
    else
        log "Using database: $DB_NAME"
    fi

    if [ -n "$DB_NAME" ]; then
        # Load timezone tables
        command -v mysql_tzinfo_to_sql &>/dev/null && \
            mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql_cmd mysql &>/dev/null && \
            log "Timezone tables loaded" || warn "mysql_tzinfo_to_sql not found"

        # Set MySQL timezone
        mysql_cmd -e "SET GLOBAL time_zone = 'SYSTEM'; FLUSH PRIVILEGES;" &>/dev/null && \
            log "MySQL timezone set to SYSTEM" || warn "SYSTEM tz failed"

        # Update ViciDial settings
        mysql_cmd "$DB_NAME" -e "UPDATE system_settings SET reload_timestamp = NOW() LIMIT 1;" &>/dev/null && \
            log "reload_timestamp updated"

        mysql_cmd "$DB_NAME" -e "UPDATE system_settings SET vicidial_agent_disable='NOT_ACTIVE' LIMIT 1;" &>/dev/null && \
            log "vicidial_agent_disable set to NOT_ACTIVE"

        mysql_cmd "$DB_NAME" -e "UPDATE system_settings SET default_local_gmt='+5.00', default_voicemail_timezone='pakistan' LIMIT 1;" &>/dev/null && \
            log "ViciDial GMT offset set to +5.00"

        # Install cron to keep reload_timestamp fresh every minute
        cat > /etc/cron.d/vici-timesync << EOF
# ViciDial time sync — keeps reload_timestamp fresh
* * * * * root mysql -uroot $DB_NAME -e "UPDATE system_settings SET reload_timestamp = NOW() LIMIT 1;" > /dev/null 2>&1
EOF
        chmod 644 /etc/cron.d/vici-timesync
        systemctl restart crond &>/dev/null || systemctl restart cron &>/dev/null
        log "Cron job installed — reload_timestamp updates every minute"

        # Restart MariaDB
        systemctl restart mariadb &>/dev/null || systemctl restart mysql &>/dev/null
        log "MariaDB restarted"

        # Verify sync
        SYS=$(date +%s)
        DB=$(mysql_cmd -e "SELECT UNIX_TIMESTAMP(NOW());" "$DB_NAME" 2>/dev/null | tail -1)
        echo "$DB" | grep -qE '^[0-9]+$' && {
            DIFF=$((SYS - DB)); ABS=${DIFF#-}
            [ "$ABS" -le 10 ] && log "Time in sync (diff=${DIFF}s)" || warn "Time diff=${DIFF}s"
        } || warn "Could not verify MySQL time"
    fi
fi

# =============================================================================
section "STEP 3 — Firewall: Fix SSH + WebRTC After DynPortal Auth"
# =============================================================================

if command -v firewall-cmd &>/dev/null; then
    systemctl is-active --quiet firewalld || systemctl start firewalld

    for PORT in "$SSH_PORT/tcp" "8089/tcp" "81/tcp" "446/tcp"; do
        firewall-cmd --zone="$PUBLIC_ZONE" --add-port="$PORT" --permanent &>/dev/null
        firewall-cmd --zone="$DYNPORTAL_ZONE" --add-port="$PORT" --permanent &>/dev/null
    done

    firewall-cmd --reload &>/dev/null
    log "Ports opened: $SSH_PORT, 8089, 81, 446 in public + external zones"
    log "Public zone ports  : $(firewall-cmd --zone=$PUBLIC_ZONE --list-ports 2>/dev/null)"
    log "External zone ports: $(firewall-cmd --zone=$DYNPORTAL_ZONE --list-ports 2>/dev/null)"
else
    iptables -I INPUT 1 -p tcp --dport "$SSH_PORT" -j ACCEPT
    iptables-save > /etc/iptables/rules.v4 2>/dev/null
    log "iptables rule added for port $SSH_PORT"
fi

# =============================================================================
section "STEP 4 — Update ViciDial User Levels"
# =============================================================================

if [ -n "$DB_NAME" ] && mysql_cmd "$DB_NAME" -e "SELECT 1;" &>/dev/null; then
    mysql_cmd "$DB_NAME" -e "UPDATE vicidial_users SET user_level=2 WHERE user BETWEEN 5001 AND 5020;" &>/dev/null
    USERS=$(mysql_cmd "$DB_NAME" -e "SELECT user, full_name, user_level FROM vicidial_users WHERE user BETWEEN 5001 AND 5020;" 2>/dev/null)
    [ -n "$USERS" ] && log "Users updated (user_level=2):" && echo "$USERS" || \
        warn "No users found between 5001 and 5020"
else
    error "MySQL not available — skipping user level update"
fi

# =============================================================================
section "STEP 5 — Fix Hostname Resolution"
# =============================================================================

info "Fixing /etc/hosts for $HOSTNAME"
if ! grep -q "^127.0.0.1 $HOSTNAME" /etc/hosts; then
    echo "127.0.0.1 $HOSTNAME" >> /etc/hosts
    log "Added 127.0.0.1 $HOSTNAME to /etc/hosts"
fi
if ! grep -q "^$SERVER_IP $HOSTNAME" /etc/hosts; then
    echo "$SERVER_IP $HOSTNAME" >> /etc/hosts
    log "Added $SERVER_IP $HOSTNAME to /etc/hosts"
fi
hostnamectl set-hostname "$HOSTNAME" &>/dev/null
ping -c1 -W1 "$HOSTNAME" &>/dev/null && log "Hostname $HOSTNAME resolves OK" || warn "Hostname still not resolving"

# =============================================================================
section "STEP 6 — Fix Asterisk SIP Config"
# =============================================================================

info "Checking Asterisk SIP externip"
if ! grep -q "^externip=$SERVER_IP" /etc/asterisk/sip.conf; then
    grep -q "^externip=" /etc/asterisk/sip.conf && \
        sed -i "s/^externip=.*/externip=$SERVER_IP/" /etc/asterisk/sip.conf || \
        sed -i "/^bindaddr=0.0.0.0/a externip=$SERVER_IP" /etc/asterisk/sip.conf
    log "externip set to $SERVER_IP"
else
    log "externip already correct"
fi

info "Fixing SERVER_EXTERNAL_IP placeholders"
COUNT=$(grep -rl "SERVER_EXTERNAL_IP" /etc/asterisk/ 2>/dev/null | wc -l)
if [ "$COUNT" -gt 0 ]; then
    grep -rl "SERVER_EXTERNAL_IP" /etc/asterisk/ | xargs sed -i "s/SERVER_EXTERNAL_IP/$SERVER_IP/g"
    log "Fixed $COUNT file(s) with SERVER_EXTERNAL_IP placeholder"
else
    log "No SERVER_EXTERNAL_IP placeholders found"
fi

# =============================================================================
section "STEP 7 — Fix Asterisk WebRTC/WSS TLS Cert"
# =============================================================================

info "Detecting ACME certificate domain"
if [ -z "$DOMAIN" ]; then
    DOMAIN=$(find "$ACME_DIR" -name "*.cer" ! -name "ca.cer" ! -name "fullchain.cer" 2>/dev/null | \
        head -1 | xargs -I{} dirname {} | xargs basename 2>/dev/null)
fi

if [ -n "$DOMAIN" ] && [ -d "$ACME_DIR/$DOMAIN" ]; then
    log "Found domain: $DOMAIN"
    CERT_DIR="$ACME_DIR/$DOMAIN"
    FULLCHAIN="$CERT_DIR/fullchain.cer"
    PRIVKEY="$CERT_DIR/$DOMAIN.key"

    # Create combined PEM for Asterisk HTTP
    cat "$FULLCHAIN" "$PRIVKEY" > /etc/asterisk/asterisk.pem
    chmod 600 /etc/asterisk/asterisk.pem
    log "Combined PEM created at /etc/asterisk/asterisk.pem"

    # Update http.conf
    sed -i "s|tlscertfile=.*|tlscertfile=/etc/asterisk/asterisk.pem|" /etc/asterisk/http.conf
    sed -i "s|tlsprivatekey=.*|tlsprivatekey=/etc/asterisk/asterisk.pem|" /etc/asterisk/http.conf
    log "http.conf updated with combined PEM"

    # Fix DTLS cert in sip-vicidial.conf — use fullchain for all extensions
    sed -i "s|dtlscertfile=.*\.cer|dtlscertfile=$FULLCHAIN|g" /etc/asterisk/sip-vicidial.conf
    log "DTLS certs updated to fullchain.cer in sip-vicidial.conf"

    # Show cert expiry
    EXPIRY=$(openssl x509 -in "$FULLCHAIN" -noout -enddate 2>/dev/null | cut -d= -f2)
    log "Certificate expires: $EXPIRY"
else
    warn "No ACME cert found in $ACME_DIR — skipping WebRTC cert fix"
fi

# =============================================================================
section "STEP 8 — Disable Broken/Unused Asterisk Modules"
# =============================================================================

MODULES_CONF="/etc/asterisk/modules.conf"
info "Disabling broken/unused modules"

NOLOAD_MODULES=(
    "chan_dahdi.so"
    "res_timing_dahdi.so"
    "codec_dahdi.so"
    "res_odbc_transaction.so"
    "res_pjsip_phoneprov_provider.so"
    "res_hep_rtcp.so"
    "res_hep_pjsip.so"
)

for MOD in "${NOLOAD_MODULES[@]}"; do
    if ! grep -q "noload => $MOD" "$MODULES_CONF"; then
        echo "noload => $MOD" >> "$MODULES_CONF"
        log "Disabled: $MOD"
    else
        log "Already disabled: $MOD"
    fi
done

mkdir -p /var/lib/asterisk/quiet-mp3
mkdir -p /var/log/asterisk
touch /var/log/asterisk/full
log "Created missing directories and log file"

# =============================================================================
section "STEP 9 — Restart Asterisk"
# =============================================================================

info "Restarting Asterisk"
systemctl restart asterisk &>/dev/null
sleep 5

if systemctl is-active --quiet asterisk; then
    log "Asterisk running"
    asterisk -rx "core show uptime" 2>/dev/null
else
    error "Asterisk failed to restart"
    journalctl -u asterisk --no-pager -n 10
fi

ss -tlnp | grep -q 8089 && log "WebRTC port 8089 is listening" || warn "Port 8089 not listening"
asterisk -rx "sip reload" &>/dev/null && log "SIP reloaded"

# =============================================================================
section "STEP 10 — Install & Configure Fail2Ban"
# =============================================================================

if ! command -v fail2ban-client &>/dev/null; then
    info "Installing fail2ban"
    zypper install -y fail2ban &>/dev/null && log "fail2ban installed" || error "fail2ban install failed"
fi

cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 3600
findtime = 60
maxretry = 5
ignoreip = 127.0.0.1/8 ::1
banaction = firewallcmd-ipset

[sshd]
enabled  = true
port     = 2008
filter   = sshd
logpath  = /var/log/messages
maxretry = 5
bantime  = 3600

[asterisk]
enabled  = true
filter   = asterisk
logpath  = /var/log/asterisk/full
maxretry = 5
findtime = 60
bantime  = 86400
port     = 5060,5061
EOF

cat > /etc/fail2ban/filter.d/asterisk.conf << 'EOF'
[Definition]
failregex = NOTICE.* .*: Registration from '.*' failed for '<HOST>:.*' - Wrong password
            NOTICE.* .*: Registration from '.*' failed for '<HOST>:.*' - No matching peer found
            NOTICE.* .*: Registration from '.*' failed for '<HOST>:.*' - Username/auth name mismatch
            NOTICE.* .*: Registration from '.*' failed for '<HOST>:.*' - Device does not match ACL
            NOTICE.* .*: Host <HOST> failed MD5 authentication for .*
            NOTICE.* .*: Failed to authenticate user .*@<HOST>
ignoreregex =
EOF

log "Fail2ban config written"
systemctl enable fail2ban --now &>/dev/null
sleep 2
systemctl is-active --quiet fail2ban && \
    { log "Fail2ban running"; fail2ban-client status 2>/dev/null; } || \
    { error "Fail2ban failed"; journalctl -u fail2ban --no-pager -n 5; }

# =============================================================================
section "STEP 11 — Apache DynPortal Ports (81 + 446)"
# =============================================================================

LISTEN_CONF="/etc/apache2/listen.conf"
info "Adding ports 81 and 446 to $LISTEN_CONF"

for PORT in 81 446; do
    if ! grep -q "^Listen $PORT$" "$LISTEN_CONF"; then
        echo "Listen $PORT" >> "$LISTEN_CONF"
        log "Added Listen $PORT to $LISTEN_CONF"
    else
        log "Listen $PORT already present"
    fi
done

# Verify Apache config is valid
apache2ctl configtest &>/dev/null && log "Apache config OK" || \
    { apachectl configtest 2>&1 | head -5; warn "Apache config has warnings"; }

# =============================================================================
section "STEP 12 — Disable VB-Firewall Cron Jobs"
# =============================================================================

info "Commenting out VB-firewall cron entries"

# Check root crontab
if crontab -l 2>/dev/null | grep -q "VB-firewall"; then
    crontab -l | \
        sed 's|^\(@reboot /usr/bin/VB-firewall.*\)|#\1|' | \
        sed 's|^\(0 \*/6 \* \* \* /usr/bin/VB-firewall.*\)|#\1|' | \
        crontab -
    log "VB-firewall cron entries commented out in root crontab"
else
    log "No VB-firewall entries in root crontab"
fi

# Also check /etc/cron.d/
for CRONFILE in /etc/cron.d/*; do
    if grep -q "VB-firewall" "$CRONFILE" 2>/dev/null; then
        sed -i 's|^\(@reboot.*VB-firewall.*\)|#\1|' "$CRONFILE"
        sed -i 's|^\(0 \*/6.*VB-firewall.*\)|#\1|' "$CRONFILE"
        log "VB-firewall entries commented in $CRONFILE"
    fi
done

# Verify
info "Current VB-firewall cron status:"
crontab -l 2>/dev/null | grep -i "VB-firewall" || echo "  (none in root crontab)"
grep -r "VB-firewall" /etc/cron.d/ 2>/dev/null || echo "  (none in /etc/cron.d/)"

# =============================================================================
section "STEP 13 — Restart Web Server"
# =============================================================================

info "Restarting Apache"
systemctl restart apache2 &>/dev/null || systemctl restart httpd &>/dev/null
sleep 2
systemctl is-active --quiet apache2 && log "Apache running" || \
    systemctl is-active --quiet httpd && log "httpd running" || error "Web server failed to start"

# Verify all ports listening
info "Apache listening ports:"
ss -tlnp | grep -E "httpd|apache" | awk '{print $4}' | sort

# =============================================================================
section "FINAL STATUS"
# =============================================================================

echo ""
echo -e "${BLUE}  ┌─────────────────────────────────────────┐${NC}"
echo -e "${BLUE}  │           System Status                 │${NC}"
echo -e "${BLUE}  └─────────────────────────────────────────┘${NC}"
echo -e "${BLUE}  System Time   :${NC} $(date)"
echo -e "${BLUE}  Timezone      :${NC} $(timedatectl | grep 'Time zone' | awk '{print $3}')"
echo -e "${BLUE}  MySQL Time    :${NC} $(mysql_cmd -e 'SELECT NOW();' "$DB_NAME" 2>/dev/null | tail -1)"
echo -e "${BLUE}  SSH Port      :${NC} $(ss -tlnp | grep ":$SSH_PORT" | awk '{print $4}' | head -1)"
echo -e "${BLUE}  WebRTC 8089   :${NC} $(ss -tlnp | grep ':8089' | awk '{print $4}' | head -1)"
echo -e "${BLUE}  DynPortal 81  :${NC} $(ss -tlnp | grep ':81 ' | awk '{print $4}' | head -1)"
echo -e "${BLUE}  DynPortal 446 :${NC} $(ss -tlnp | grep ':446 ' | awk '{print $4}' | head -1)"
echo -e "${BLUE}  Chrony        :${NC} $(systemctl is-active chronyd)"
echo -e "${BLUE}  MariaDB       :${NC} $(systemctl is-active mariadb 2>/dev/null || systemctl is-active mysql 2>/dev/null)"
echo -e "${BLUE}  Asterisk      :${NC} $(systemctl is-active asterisk)"
echo -e "${BLUE}  Apache        :${NC} $(systemctl is-active apache2 2>/dev/null || systemctl is-active httpd 2>/dev/null)"
echo -e "${BLUE}  Fail2Ban      :${NC} $(systemctl is-active fail2ban)"
echo -e "${BLUE}  Hostname      :${NC} $(hostname)"
echo -e "${BLUE}  VB-Firewall   :${NC} $(crontab -l 2>/dev/null | grep -c "^[^#].*VB-firewall" || echo 0) active cron entries"
echo ""
log "All fixes applied. Please refresh ViciDial in your browser."
echo ""
