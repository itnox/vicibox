#!/bin/bash
# ViciBox 12 setup script
# Based on vici_changes.sh (ViciBox 11)

set -euo pipefail

# ---------------------------------------------------------------------------
# Error handler
# ---------------------------------------------------------------------------
trap 'echo; echo "   ERROR: Script failed at line $LINENO. Exiting." >&2' ERR

# ---------------------------------------------------------------------------
# Load secrets / configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$SCRIPT_DIR/install.conf"

[[ -f "$CONF_FILE" ]] || {
    echo "ERROR: $CONF_FILE not found."
    echo "       Copy install.conf.example to install.conf and fill in your values."
    exit 1
}
# shellcheck source=install.conf
source "$CONF_FILE"

# ---------------------------------------------------------------------------
# Constants (non-secret, safe to keep in script)
# ---------------------------------------------------------------------------
ASTGUICLIENT="/etc/astguiclient.conf"
ASTERISK_CONF="/etc/asterisk/http.conf"
ASTERISK_MODULES="/etc/asterisk/modules.conf"
ASTERISK_SIP_CONF="/etc/asterisk/sip-vicidial.conf"
APACHE_LISTEN_CONF="/etc/apache2/listen.conf"
OVERRIDE_PATH="/srv/www/vhosts/dynportal/inc/defaults.inc.php"
SSH_CONFIG_FILE="/etc/ssh/sshd_config"
LOCAL_IP="127.0.0.1"
ALL_IP="0.0.0.0"
LOGFILE="/var/log/vicibox12-setup-$(date +%Y%m%d-%H%M%S).log"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
die() { echo "   ERROR: $*" >&2; exit 1; }

# tr|head triggers SIGPIPE on tr (exit 141) which fails with pipefail.
# Run in a subshell with pipefail off so only head's exit code (0) is seen.
rand_pass() { ( set +o pipefail; tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-16}" ); }

_conf_val() { grep "$1" "$ASTGUICLIENT" | cut -d ">" -f2- | tr -d '[:space:]'; }

mysql_cmd() {
    mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" --execute="$1"
}

# ---------------------------------------------------------------------------
# Require root
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "This script must be run as root."

# ---------------------------------------------------------------------------
# Resolve public IP at runtime
# ---------------------------------------------------------------------------
SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null \
    || curl -s --max-time 5 api.ipify.org 2>/dev/null \
    || curl -s --max-time 5 checkip.amazonaws.com 2>/dev/null \
    || true)
[[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "Could not determine public IP (tried ifconfig.me, api.ipify.org, checkip.amazonaws.com)."
echo "   Public IP: $SERVER_IP"

# ---------------------------------------------------------------------------
# Fixed / generated values (not in install.conf)
# ---------------------------------------------------------------------------
AGENT_USER_PREFIX="50"   # agent IDs will be 5001, 5002, …
AGENT_PASS=$(rand_pass 12)

# ---------------------------------------------------------------------------
# Validate required config values from install.conf
# ---------------------------------------------------------------------------
for var in FQDN VB_DB_USERNAME VB_DB_PASSWORD VB_DB_NAME \
           VB_DB_CUSTOM_USERNAME VB_DB_CUSTOM_PASSWORD \
           VB_DB_SLAVE_USER VB_DB_SLAVE_PASS USERS; do
    [[ -n "${!var:-}" ]] || die "install.conf: $var is not set."
done

[[ "$FQDN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || die "install.conf: FQDN '$FQDN' is not a valid domain."
[[ "$USERS" =~ ^[1-9][0-9]*$ ]]                               || die "install.conf: USERS must be a positive integer."

# Generate master admin password (always random for security)
MASTER_PASS=$(rand_pass 16)

# ---------------------------------------------------------------------------
# Prerequisite command checks
# ---------------------------------------------------------------------------
for cmd in mysql git vicibox-ssl vicibox-install firewall-cmd; do
    command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
done

# ---------------------------------------------------------------------------
# Step 1 — Run vicibox-install (skip if DB already exists)
# ---------------------------------------------------------------------------
echo
echo "=== Step 1: ViciBox Install ==="

_db_exists() {
    mysql -uroot -e "SHOW DATABASES LIKE '${VB_DB_NAME}';" 2>/dev/null \
        | grep -q "$VB_DB_NAME"
}

if _db_exists; then
    echo "   Database '$VB_DB_NAME' already exists — vicibox-install already ran."
    echo "   Skipping vicibox-install."
else
    echo "   Running vicibox-install (non-interactive, answers piped from install.conf)..."

    # Build answers in the exact order vicibox-install expects them.
    # The installer's getlocalip() only matches RFC-1918 ranges.
    #   Case A — no RFC-1918 interface IP (public-only server):
    #     getlocalip fails → installer asks for IP first → we provide SERVER_IP
    #     then in expert mode it re-confirms → Y
    #   Case B — RFC-1918 IP exists (e.g. VM bridge 192.168.x.x):
    #     getlocalip finds the private IP, skips the IP prompt
    #     first question is "continue?" → then expert mode → "use detected IP?"
    #     we answer n, then provide the correct public SERVER_IP
    _LAN_IP=$(ip -4 addr show 2>/dev/null \
        | awk '/inet / {print $2}' | cut -d/ -f1 \
        | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' \
        | head -1 || true)

    ANSWERS_FILE="/tmp/vicibox-install-answers.$$"

    if [[ -z "$_LAN_IP" ]]; then
        # Case A: no RFC-1918 IP — IP prompt fires first
        echo "   Case A: public-only server — sending IP as first answer."
        cat > "$ANSWERS_FILE" << EOF
${SERVER_IP}
y
y
Y
y
n
n
${VB_DB_USERNAME}
${VB_DB_PASSWORD}
${VB_DB_NAME}
${VB_DB_CUSTOM_USERNAME}
${VB_DB_CUSTOM_PASSWORD}
${VB_DB_PORT}
${VB_DB_SLAVE_USER}
${VB_DB_SLAVE_PASS}
y
y
y
n
n
n
Y
EOF
    else
        # Case B: RFC-1918 IP found ($_LAN_IP) — installer skips IP prompt,
        # first question is "continue?"; in expert mode we reject the private IP
        echo "   Case B: RFC-1918 IP $_LAN_IP detected — overriding with public IP $SERVER_IP."
        cat > "$ANSWERS_FILE" << EOF
y
y
n
${SERVER_IP}
y
n
n
${VB_DB_USERNAME}
${VB_DB_PASSWORD}
${VB_DB_NAME}
${VB_DB_CUSTOM_USERNAME}
${VB_DB_CUSTOM_PASSWORD}
${VB_DB_PORT}
${VB_DB_SLAVE_USER}
${VB_DB_SLAVE_PASS}
y
y
y
n
n
n
Y
EOF
    fi

    vicibox-install < "$ANSWERS_FILE" | tee -a "$LOGFILE"
    rm -f "$ANSWERS_FILE"
    echo "   vicibox-install complete."
fi

# ---------------------------------------------------------------------------
# Step 2 — Start and enable firewalld
# ---------------------------------------------------------------------------
echo
echo "=== Step 2: Firewalld ==="
systemctl start firewalld
systemctl enable firewalld
echo "   Done."

# ---------------------------------------------------------------------------
# Step 3 — Prerequisite file checks (created by vicibox-install)
# ---------------------------------------------------------------------------
for f in "$ASTGUICLIENT" "$ASTERISK_CONF" "$ASTERISK_MODULES" \
          "$APACHE_LISTEN_CONF" "$OVERRIDE_PATH" "$SSH_CONFIG_FILE"; do
    [[ -f "$f" ]] || die "Required file not found: $f  (did vicibox-install complete successfully?)"
done

# ---------------------------------------------------------------------------
# Step 4 — Read DB credentials from astguiclient.conf
# ---------------------------------------------------------------------------
echo
echo "=== Step 4: Reading DB credentials ==="
DB_HOST=$(_conf_val VARDB_server)
DB_USER=$(_conf_val VARDB_user)
DB_PASS=$(_conf_val VARDB_pass)
DB_PORT=$(_conf_val VARDB_port)
DB_NAME=$(_conf_val VARDB_database)

for var in DB_HOST DB_USER DB_PASS DB_PORT DB_NAME; do
    [[ -n "${!var}" ]] || die "Could not read $var from $ASTGUICLIENT"
done

# Verify DB connectivity
mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
    -e "SELECT 1" &>/dev/null \
    || die "Cannot connect to MySQL at $DB_HOST:$DB_PORT as $DB_USER."

echo "   DB connection OK."

# ---------------------------------------------------------------------------
# Step 5 — Apply SSL
# vicibox-ssl always uses interactive `read` prompts — pipe answers via stdin.
# The IP-mismatch prompt is conditional, so we pre-check DNS to pick the
# right number of answers (6 without mismatch, 7 with).
# ---------------------------------------------------------------------------
echo
echo "=== Step 5: SSL ==="
if [[ "${SKIP_SSL:-0}" == "1" ]]; then
    echo "   SKIP_SSL=1 — skipping (set SKIP_SSL=0 in install.conf once FQDN has DNS)."
else
    echo "   Applying SSL Certificate for $FQDN..."
    _RESOLVED=$(dig +short "$FQDN" 2>/dev/null | tail -1)
    _SSL_ANSWERS="/tmp/vb-ssl-answers.$$"
    if [[ "$_RESOLVED" == "$SERVER_IP" ]]; then
        # DNS resolves correctly — no mismatch prompt
        # Prompts: email → FQDN → generate(y) → enable(y) → redirect(n) → crontab(y)
        printf '%s\n%s\ny\ny\nn\ny\n' "${SSL_EMAIL}" "$FQDN" > "$_SSL_ANSWERS"
    else
        # DNS mismatch or unresolved — extra y to continue despite mismatch
        # Prompts: email → FQDN → continue-mismatch(y) → generate(y) → enable(y) → redirect(n) → crontab(y)
        printf '%s\n%s\ny\ny\ny\nn\ny\n' "${SSL_EMAIL}" "$FQDN" > "$_SSL_ANSWERS"
    fi
    vicibox-ssl < "$_SSL_ANSWERS"
    rm -f "$_SSL_ANSWERS"
    echo "   Done."
fi

# ---------------------------------------------------------------------------
# Step 6 — WebRTC (Asterisk http.conf)
# Use grep-first guards so the seds are idempotent regardless of current state.
# ---------------------------------------------------------------------------
echo
echo "=== Step 6: WebRTC ==="
grep -q "^bindaddr=$ALL_IP" "$ASTERISK_CONF" || \
    sed -i "/^bindaddr=/c\\bindaddr=$ALL_IP" "$ASTERISK_CONF"
grep -q "^bindport=8088" "$ASTERISK_CONF" || \
    sed -i "s/^;*bindport=.*/bindport=8088/" "$ASTERISK_CONF"
grep -q "^load => res_http_websocket.so" "$ASTERISK_MODULES" || \
    echo "load => res_http_websocket.so" >> "$ASTERISK_MODULES"

if pgrep -x asterisk &>/dev/null; then
    echo "   Restarting Asterisk..."
    /usr/sbin/rasterisk -x 'module reload http'
    /sbin/service asterisk restart
fi
echo "   Done."

# ---------------------------------------------------------------------------
# Step 7 — ViciPhone webphone
# ---------------------------------------------------------------------------
echo
echo "=== Step 7: ViciPhone ==="
VICIPHONE_DIR="/var/tmp/ViciPhone"
VICIPHONE_DEST="/srv/www/htdocs/agc/viciphone"
if [[ -d "$VICIPHONE_DIR/.git" ]]; then
    git -C "$VICIPHONE_DIR" pull --ff-only
else
    rm -rf "$VICIPHONE_DIR"
    git clone https://github.com/vicimikec/ViciPhone.git "$VICIPHONE_DIR"
fi
cp -r "$VICIPHONE_DIR/src" "$VICIPHONE_DEST"
chmod -R 755 "$VICIPHONE_DEST"
echo "   Done."

# ---------------------------------------------------------------------------
# Step 8 — Apache listen ports (81, 446)
# ---------------------------------------------------------------------------
echo
echo "=== Step 8: Apache ports ==="
if ! grep -q "^Listen 81$" "$APACHE_LISTEN_CONF"; then
    sed -i '/^Listen 80$/a Listen 81' "$APACHE_LISTEN_CONF"
    echo "   Added Listen 81."
else
    echo "   Listen 81 already present."
fi

if ! grep -q "^[[:space:]]*Listen 446$" "$APACHE_LISTEN_CONF"; then
    sed -i '/^[[:space:]]*Listen 443$/a\\t\t\t\tListen 446' "$APACHE_LISTEN_CONF"
    echo "   Added Listen 446."
else
    echo "   Listen 446 already present."
fi

systemctl reload apache2
echo "   Done."

# ---------------------------------------------------------------------------
# Step 9 — ViciDial DB changes
# ---------------------------------------------------------------------------
echo
echo "=== Step 9: ViciDial DB ==="

mysql_cmd "UPDATE system_settings SET
    default_webphone='1',
    webphone_url='https://$FQDN/agc/viciphone/viciphone.php',
    auto_dial_limit='20';"

mysql_cmd "UPDATE servers SET
    max_vicidial_trunks='150',
    outbound_calls_per_second='50'
  WHERE server_ip='$SERVER_IP';"

mysql_cmd "UPDATE vicidial_users SET
    user='master', pass='$MASTER_PASS',
    force_change_password='N',
    view_reports='1', alter_agent_interface_options='1', modify_users='1',
    change_agent_campaign='1', delete_users='1', modify_usergroups='1',
    delete_user_groups='1', modify_lists='1', delete_lists='1',
    load_leads='1', modify_leads='1', export_gdpr_leads='1',
    download_lists='1', export_reports='1', delete_from_dnc='1',
    modify_campaigns='1', campaign_detail='1', modify_dial_prefix='1',
    delete_campaigns='1', modify_ingroups='1', delete_ingroups='1',
    modify_inbound_dids='1', delete_inbound_dids='1',
    modify_custom_dialplans='1', modify_remoteagents='1',
    delete_remote_agents='1', modify_scripts='1', delete_scripts='1',
    modify_filters='1', delete_filters='1', ast_admin_access='1',
    ast_delete_phones='1', modify_call_times='1', delete_call_times='1',
    modify_servers='1', modify_shifts='1', modify_phones='1',
    modify_carriers='1', modify_labels='1', modify_colors='1',
    modify_statuses='1', modify_voicemail='1', modify_audiostore='1',
    modify_moh='1', modify_tts='1', modify_contacts='1',
    callcard_admin='1', add_timeclock_log='1', modify_timeclock_log='1',
    delete_timeclock_log='1', manager_shift_enforcement_override='1',
    pause_code_approval='1', vdc_agent_api_access='1'
  WHERE user='6666';"

# Skip the ViciDial initial setup wizard — admin.php shows the copyright/license
# page when first_login_trigger='Y', then the password-change form at ADD=999996.
# Since we already set passwords and full permissions above, bypass it entirely.
mysql_cmd "UPDATE system_settings SET
    first_login_trigger='N',
    default_phone_registration_password='$AGENT_PASS',
    default_phone_login_password='$AGENT_PASS',
    default_server_password='$AGENT_PASS';"

mysql_cmd "INSERT IGNORE INTO vicidial_server_carriers (
    carrier_id, carrier_name, registration_string, template_id, account_entry,
    protocol, globals_string, dialplan_entry, server_ip, active,
    carrier_description, user_group)
  VALUES (
    'Globilinks', 'Globilinks', '', '--NONE--',
    '[Globilinks]\r\ndisallow=all\r\nallow=ulaw\r\nallow=g729\r\ntype=peer\r\nhost=185.188.124.88\r\nport=5060\r\ndtmfmode=rfc2833\r\ncanreinvite=no\r\ninsecure=port,invite\r\ncontext=trunkinbound',
    'SIP', '',
    'exten => _94162X.,1,AGI(agi://127.0.0.1:4577/call_log)\r\nexten => _94162X.,2,Dial(\${VOIP}/\${EXTEN:5},60,tTor)\r\nexten => _94162X.,3,Hangup',
    '$SERVER_IP', 'Y', '', '---ALL---');"

echo "   Done."

# ---------------------------------------------------------------------------
# Step 10 — Create agent users + phones (batched)
# ---------------------------------------------------------------------------
echo
echo "=== Step 10: Agent users ($USERS users, prefix $AGENT_USER_PREFIX) ==="

USER_SQL="INSERT IGNORE INTO vicidial_users
    (user,pass,full_name,user_level,user_group,phone_login,phone_pass,
     load_leads,campaign_detail,ast_admin_access,modify_users,agentcall_manual)
  VALUES"

PHONE_SQL="INSERT IGNORE INTO phones
    (extension,dialplan_number,voicemail_id,server_ip,login,pass,status,active,
     phone_type,fullname,protocol,local_gmt,company,picture,messages,old_messages,
     outbound_cid,conf_secret,phone_ip,computer_ip,is_webphone,template_id,phone_context)
  VALUES"

for (( i = 1; i <= USERS; i++ )); do
    U=$(printf "%02d" $i)
    SEP=$( (( i < USERS )) && echo "," || echo "" )
    USER_SQL+=" ('$AGENT_USER_PREFIX$U','$AGENT_PASS','$AGENT_USER_PREFIX$U','2','ADMIN',
      '$AGENT_USER_PREFIX$U','$AGENT_PASS','0','0','0','0','1')${SEP}"
    PHONE_SQL+=" ('$AGENT_USER_PREFIX$U','$AGENT_USER_PREFIX$U','$AGENT_USER_PREFIX$U',
      '$SERVER_IP','$AGENT_USER_PREFIX$U','$AGENT_PASS','ACTIVE','Y','',
      '$AGENT_USER_PREFIX$U','SIP','-5.00','','','0','0','','$AGENT_PASS','','',
      'Y','${HOSTNAME}-RTC','default')${SEP}"
done

mysql_cmd "$USER_SQL;"
mysql_cmd "$PHONE_SQL;"
echo "   Done."

# ---------------------------------------------------------------------------
# Step 11 — Phone SIP context fixup
# Ensure all phone peers use context=default in DB and sip-vicidial.conf.
# Phones inserted above already have phone_context='default'; this step also
# fixes any pre-existing phones and patches the SIP config file directly.
# ---------------------------------------------------------------------------
echo
echo "=== Step 11: Phone SIP context ==="

_PHONE_LIST="/tmp/vicidial_phones.$$"

mysql_cmd "UPDATE phones SET phone_context='default'
  WHERE phone_context IS NULL OR phone_context != 'default';"

mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
    -N -B -e "SELECT DISTINCT extension FROM phones
              WHERE extension IS NOT NULL AND extension != ''
              ORDER BY extension;" > "$_PHONE_LIST"

_PHONE_COUNT=$(wc -l < "$_PHONE_LIST" | tr -d ' ')
echo "   Phones in DB: $_PHONE_COUNT"

if [[ -f "$ASTERISK_SIP_CONF" && "$_PHONE_COUNT" -gt 0 ]]; then
    # Rebuild SIP configs so newly inserted phones appear in the file first
    [[ -x /usr/share/astguiclient/ADMIN_keepalive_ALL.pl ]] && \
        /usr/share/astguiclient/ADMIN_keepalive_ALL.pl &>/dev/null || true

    cp -a "$ASTERISK_SIP_CONF" "${ASTERISK_SIP_CONF}.bak.$(date +%Y%m%d-%H%M%S)"

    # Patch each phone peer block: replace existing context line or insert one
    awk -v ctx="default" -v list="$_PHONE_LIST" '
    BEGIN {
        while ((getline line < list) > 0) {
            gsub(/^[ \t]+|[ \t]+$/, "", line)
            if (line != "") phone[line] = 1
        }
        close(list)
        inphone = 0; context_seen = 0
    }
    function flush_context() {
        if (inphone == 1 && context_seen == 0) { print "context=" ctx; context_seen = 1 }
    }
    /^[[:space:]]*\[[^]]+\]/ {
        if (inphone == 1) flush_context()
        section = $0
        gsub(/^[[:space:]]*\[/, "", section)
        gsub(/\].*$/, "", section)
        inphone = (section in phone) ? 1 : 0
        context_seen = 0
        print; next
    }
    {
        if (inphone == 1 && $0 ~ /^[[:space:]]*context[[:space:]]*(=|=>)/) {
            print "context=" ctx; context_seen = 1; next
        }
        print
    }
    END { if (inphone == 1) flush_context() }
    ' "$ASTERISK_SIP_CONF" > /tmp/sip-patch.$$ \
        && cat /tmp/sip-patch.$$ > "$ASTERISK_SIP_CONF" \
        && rm -f /tmp/sip-patch.$$

    echo "   SIP file patched."
else
    echo "   SIP file not found or no phones — skipping SIP file patch."
fi

if pgrep -x asterisk &>/dev/null; then
    asterisk -rx "sip reload"      >/dev/null 2>&1 || true
    asterisk -rx "dialplan reload" >/dev/null 2>&1 || true
    sleep 3

    _BAD_PEERS=()
    while read -r EXT; do
        [[ -z "$EXT" ]] && continue
        _CTX=$(asterisk -rx "sip show peer $EXT" 2>/dev/null \
               | awk -F: '/^Context/ {gsub(/ /, "", $2); print $2; exit}')
        [[ "$_CTX" == "trunkinbound" ]] && _BAD_PEERS+=("$EXT")
    done < "$_PHONE_LIST"

    if [[ ${#_BAD_PEERS[@]} -gt 0 ]]; then
        echo "   WARNING: ${#_BAD_PEERS[@]} peer(s) still trunkinbound: ${_BAD_PEERS[*]}"
        echo "   Restarting Asterisk to force config reload..."
        /sbin/service asterisk restart
        sleep 7
    else
        echo "   OK: all phone peers report context=default."
    fi
fi

rm -f "$_PHONE_LIST"
echo "   Done."

# ---------------------------------------------------------------------------
# Step 12 — Create campaign
# ---------------------------------------------------------------------------
echo
echo "=== Step 12: Campaign ==="
mysql_cmd "INSERT IGNORE INTO vicidial_campaigns
    (campaign_id,campaign_name,campaign_description,active,next_agent_call,local_call_time,dial_method)
  VALUES ('454','USA-Campaign','Customer Services','Y','longest_wait_time','24hours','RATIO');"

mysql_cmd "UPDATE vicidial_campaigns SET
    dial_prefix='74', manual_dial_prefix='68', campaign_vdad_exten='8369',
    campaign_recording='ALLCALLS', waitforsilence_options='2000,2,30',
    amd_type='AMD', amd_agent_route_options='ENABLED',
    no_hopper_leads_logins='Y', hopper_level='1000'
  WHERE campaign_id='454';"

mysql_cmd "INSERT IGNORE INTO vicidial_settings_containers
    (container_id,container_notes,container_type,user_group,container_entry)
  VALUES ('AMD_AGENT_OPT_454','AMD agent options for 454 campaign',
    'AMD_AGENT_OPTIONS','---ALL---',
    'HUMAN,HUMAN\r\nNOTSURE,TOOLONG\r\nMACHINE,INITIALSILENCE');"

mysql_cmd "DELETE FROM phones WHERE extension IN ('callin', 'gs102');"
echo "   Done."

# ---------------------------------------------------------------------------
# Step 13 — DynPortal crontab
# ---------------------------------------------------------------------------
echo
echo "=== Step 13: DynPortal crontab ==="
crontab -l 2>/dev/null > /tmp/rootcronold || touch /tmp/rootcronold

sed '/^[^#].*VB-firewall/s/^/#/' /tmp/rootcronold > /tmp/rootcron

CRON_DYNAMIC="* * * * * /usr/bin/VB-firewall --white --dynamic --quiet"
CRON_REBOOT="@reboot  /usr/bin/VB-firewall --white --dynamic --quiet"

grep -qF "$CRON_DYNAMIC" /tmp/rootcron || echo "$CRON_DYNAMIC" >> /tmp/rootcron
grep -qF "$CRON_REBOOT"  /tmp/rootcron || echo "$CRON_REBOOT"  >> /tmp/rootcron

crontab /tmp/rootcron
echo "   Old VB-firewall cron jobs commented out. New entries added."
echo "   Backup saved to /tmp/rootcronold"
echo "   Done."

# ---------------------------------------------------------------------------
# Step 14 — Recording access
# ---------------------------------------------------------------------------
echo
echo "=== Step 14: Recording access ==="
chmod 755 /var/spool/asterisk
echo "   Done."

# ---------------------------------------------------------------------------
# Step 15 — DynPortal redirect
# ---------------------------------------------------------------------------
echo
echo "=== Step 15: DynPortal redirect ==="
# Match any current value between the quotes so this step is idempotent on re-runs.
sed -i "s|\$PORTAL_redirecturl='[^']*'|\$PORTAL_redirecturl='https://$FQDN/vicidial/welcome.php'|" \
    "$OVERRIDE_PATH"
sed -i "s|\$PORTAL_redirectadmin='[^']*'|\$PORTAL_redirectadmin='https://$FQDN/vicidial/admin.php'|" \
    "$OVERRIDE_PATH"
echo "   Done."

# ---------------------------------------------------------------------------
# Save credentials — done here so the log exists even if later steps are skipped
# ---------------------------------------------------------------------------
LAST_USER="${AGENT_USER_PREFIX}$(printf "%02d" "$USERS")"
{
    echo "================================================================"
    echo "  ViciBox 12 Setup Log — $(date)"
    echo "================================================================"
    echo "  FQDN        : $FQDN"
    echo "  Admin user  : master"
    echo "  Admin pass  : $MASTER_PASS"
    echo "  Agent users : ${AGENT_USER_PREFIX}01 to $LAST_USER"
    echo "  Agent pass  : $AGENT_PASS"
    echo "  SSH port    : $SSH_PORT"
    echo "================================================================"
} | tee -a "$LOGFILE"
chmod 600 "$LOGFILE"

# ---------------------------------------------------------------------------
# Step 16 — SSH port
# ---------------------------------------------------------------------------
echo
echo "=== Step 16: SSH port → ${SSH_PORT} ==="
if grep -qE "^#?Port " "$SSH_CONFIG_FILE"; then
    sed -i -E "s/^#?Port .*/Port ${SSH_PORT}/" "$SSH_CONFIG_FILE"
else
    echo "Port ${SSH_PORT}" >> "$SSH_CONFIG_FILE"
fi
/sbin/service sshd restart
echo "   Done."

# ---------------------------------------------------------------------------
# Step 17 — Firewall rules
# ---------------------------------------------------------------------------
echo
echo "=== Step 17: Firewall ==="
firewall-cmd --zone=public --remove-service=apache2     --permanent 2>/dev/null || true
firewall-cmd --zone=public --remove-service=apache2-ssl --permanent 2>/dev/null || true
firewall-cmd --zone=public --add-service=dynportal      --permanent
firewall-cmd --zone=public --add-service=dynportal-ssl  --permanent
firewall-cmd --zone=public --add-port="${SSH_PORT}/tcp" --permanent
firewall-cmd --zone=external --add-port="${SSH_PORT}/tcp" --permanent
firewall-cmd --zone=public --add-port=8089/tcp          --permanent
firewall-cmd --zone=public --remove-service=ssh         --permanent
firewall-cmd --reload
echo "   Done."

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "================================================================"
echo "  Setup Complete"
echo "================================================================"
echo
echo "  Customer URLs:"
echo "    http://$FQDN:81/valid8.php"
echo "    https://$FQDN:446/valid8.php"
echo "    https://$FQDN/vicidial/welcome.php"
echo
echo "  Admin Credentials:"
echo "    user : master"
echo "    pass : $MASTER_PASS"
echo
echo "  Agent Credentials:"
echo "    user : ${AGENT_USER_PREFIX}01  to  $LAST_USER"
echo "    pass : $AGENT_PASS"
echo
echo "  Credentials saved to: $LOGFILE"
echo "================================================================"

# ---------------------------------------------------------------------------
# Reboot prompt
# ---------------------------------------------------------------------------
echo
echo -n "   Do you want to reboot the server? (N/y) : "
read PROMPT
if [[ "${PROMPT,,}" == "y" ]]; then
    echo "   Rebooting Server in 10 seconds..."
    sleep 10
    reboot
else
    echo "   Please reboot the server manually."
fi
echo
echo "  Done."
