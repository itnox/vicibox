#!/usr/bin/env bash
set -u
umask 077
ASTGUICLIENT=/etc/astguiclient.conf
ASTERISK_CONF=/etc/asterisk/http.conf
ASTERISK_MODULES=/etc/asterisk/modules.conf
OVERRIDE_PATH=/srv/www/vhosts/dynportal/inc/defaults.inc.php
SSH_CONFIG_FILE=/etc/ssh/sshd_config
SSH_PORT=2008
LOG_FILE=/var/log/vici_changes.log
SERVER_IP='' ASTERISK_IP='' DB_HOST='' DB_USER='' DB_PASS='' DB_PORT='' DB_NAME=''
DB_CNF='' FQDN='' AGENT_PASS='' AGENT_USER_PREFIX='' MASTER_PASS='' LAST_USERS=''
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE" 2>/dev/null || :; }
info() { printf '\n=== %s ===\n' "$*"; log "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; log "ERROR $*"; }
require_file() { [[ -f "$1" ]] || { err "Missing $1"; return 1; }; }
confirm() { local x; read -r -p "$1 [y/N]: " x; [[ "${x,,}" == y || "${x,,}" == yes ]]; }
read_config() {
  require_file "$ASTGUICLIENT" || return 1
  local key val
  for key in VARserver_ip VARDB_server VARDB_user VARDB_pass VARDB_port VARDB_database; do
    val=$(awk -v k="$key" '$1==k {sub(/^[^>]*>/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit}' "$ASTGUICLIENT")
    case "$key" in
      VARserver_ip) SERVER_IP=$val;; VARDB_server) DB_HOST=$val;; VARDB_user) DB_USER=$val;;
      VARDB_pass) DB_PASS=$val;; VARDB_port) DB_PORT=$val;; VARDB_database) DB_NAME=$val;;
    esac
  done
  [[ -n "$SERVER_IP" && -n "$DB_HOST" && -n "$DB_USER" && -n "$DB_NAME" ]] || { err 'Incomplete DB configuration'; return 1; }
  [[ "$DB_PORT" =~ ^[0-9]+$ ]] || DB_PORT=3306
}
prepare_db() {
  [[ -n "$DB_CNF" && -f "$DB_CNF" ]] && return 0
  read_config || return 1
  DB_CNF=$(mktemp /tmp/vici-db.XXXXXXXX) || return 1
  chmod 600 "$DB_CNF"
  { printf '[client]\n'; printf 'host=%s\nport=%s\nuser=%s\n' "$DB_HOST" "$DB_PORT" "$DB_USER"; printf 'password="%s"\n' "${DB_PASS//\"/\\\"}"; } > "$DB_CNF"
}
cleanup() { [[ -n "$DB_CNF" ]] && rm -f "$DB_CNF"; }
trap cleanup EXIT
sql_quote() { local x=${1//\\/\\\\}; x=${x//\'/\'\'}; printf "'%s'" "$x"; }
db_query() { prepare_db || return 1; mysql --defaults-extra-file="$DB_CNF" --batch --skip-column-names "$DB_NAME" --execute="$1"; }
db_exec() {
  local description=$1 sql=$2 output
  log "DB WRITE $description"
  if ! output=$(db_query "$sql" 2>&1); then err "DB failed ($description): $output"; return 1; fi
}
valid_ip() {
  local ip=$1 octet; local -a parts
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a parts <<< "$ip"
  for octet in "${parts[@]}"; do (( ${#octet} <= 3 && 10#$octet <= 255 )) || return 1; done
}
ask_fqdn() {
  while :; do
    read -r -p 'FQDN: ' FQDN
    [[ "$FQDN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ && "$FQDN" == *.* && "$FQDN" != *..* ]] && return 0
    err 'Invalid FQDN'
  done
}
ask_asterisk_ip() {
  local x ip description i; local -a ips=() descriptions=()
  while :; do
    read -r -p 'Please enter the Asterisk server IP (press Enter to pick from servers list): ' x
    if [[ -n "$x" ]]; then valid_ip "$x" && { ASTERISK_IP=$x; return 0; }; err 'Invalid IPv4'; continue; fi
    ips=(); descriptions=()
    while IFS=$'\t' read -r ip description; do [[ -n "$ip" ]] && { ips+=("$ip"); descriptions+=("$description"); }; done < <(db_query "SELECT server_ip,server_description FROM servers WHERE active='Y' ORDER BY server_ip" 2>/dev/null)
    ((${#ips[@]})) || { err 'No active servers found'; continue; }
    for i in "${!ips[@]}"; do printf '%d) %s %s %s\n' "$((i+1))" "${ips[i]}" "${descriptions[i]}" "$( [[ "${ips[i]}" == "$SERVER_IP" ]] && echo '(this box)' )"; done
    read -r -p 'Select server number: ' x
    if [[ "$x" =~ ^[0-9]+$ ]] && ((x>=1 && x<=${#ips[@]})); then ASTERISK_IP=${ips[x-1]}; return 0; fi
    err 'Invalid selection'
  done
}
random_pass() { local p; p=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16) || :; [[ ${#p} == 16 ]] || return 1; printf '%s' "$p"; }
ask_password() {
  local suggestion; suggestion=$(random_pass) || return 1
  printf 'Suggested random password: %s\n' "$suggestion"
  read -r -s -p 'Password (Enter to auto-generate): ' AGENT_PASS; printf '\n'
  AGENT_PASS=${AGENT_PASS:-$suggestion}
}
ask_count_prefix() {
  local count
  while :; do read -r -p 'How many users? [1]: ' count; count=${count:-1}; [[ "$count" =~ ^[0-9]+$ ]] && ((count>=1 && count<=99)) && break; err 'Enter 1-99'; done
  USERS_COUNT=$count
  while :; do read -r -p 'Agent user prefix (2 digits): ' AGENT_USER_PREFIX; [[ "$AGENT_USER_PREFIX" =~ ^[0-9]{2}$ ]] && break; err 'Exactly 2 digits required'; done
}
configure_http_local() {
  require_file "$ASTERISK_CONF" && require_file "$ASTERISK_MODULES" || return 1
  if grep -Eq '^[;#]?[[:space:]]*bindaddr=' "$ASTERISK_CONF"; then sed -i -E 's/^[;#]?[[:space:]]*bindaddr=.*/bindaddr=0.0.0.0/' "$ASTERISK_CONF" || return 1; else printf '\nbindaddr=0.0.0.0\n' >> "$ASTERISK_CONF"; fi
  if grep -Eq '^[;#]?[[:space:]]*bindport=' "$ASTERISK_CONF"; then sed -i -E 's/^[;#]?[[:space:]]*bindport=.*/bindport=8088/' "$ASTERISK_CONF" || return 1; else printf '\nbindport=8088\n' >> "$ASTERISK_CONF"; fi
  grep -Fqx 'load => res_http_websocket.so' "$ASTERISK_MODULES" || printf '\nload => res_http_websocket.so\n' >> "$ASTERISK_MODULES"
  log "FILE EDIT $ASTERISK_CONF $ASTERISK_MODULES"
  if pgrep -x asterisk >/dev/null; then
    asterisk -rx 'module reload http' && log 'SERVICE reload Asterisk HTTP' || err 'Asterisk module reload failed'
    systemctl restart asterisk && log 'SERVICE restart Asterisk' || return 1
  fi
}
install_webphone() {
  local dest=/srv/www/htdocs/agc/viciphone tmp
  [[ -f "$dest/viciphone.php" ]] && { info 'ViciPhone already installed'; return 0; }
  tmp=$(mktemp -d /var/tmp/viciphone.XXXXXXXX) || return 1
  if ! git clone --depth 1 https://github.com/vicimikec/ViciPhone.git "$tmp/repo" || [[ ! -d "$tmp/repo/src" ]]; then rm -rf "$tmp"; err 'Clone failed'; return 1; fi
  mkdir -p "$dest" && cp -a "$tmp/repo/src/." "$dest/" && chmod -R 755 "$dest" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"; log "FILE EDIT installed ViciPhone at $dest"
}
set_webphone_url() {
  [[ -n "$FQDN" ]] || ask_fqdn
  db_exec 'webphone settings' "UPDATE system_settings SET default_webphone='1',webphone_url=$(sql_quote "https://$FQDN/agc/viciphone/viciphone.php"),auto_dial_limit='20';"
}
set_local_limits() { db_exec 'local trunk and CPS limits' "UPDATE servers SET max_vicidial_trunks='150',outbound_calls_per_second='50' WHERE server_ip=$(sql_quote "$SERVER_IP");"; }
set_master_permissions() {
  local columns='view_reports alter_agent_interface_options modify_users change_agent_campaign delete_users modify_usergroups delete_user_groups modify_lists delete_lists load_leads modify_leads export_gdpr_leads download_lists export_reports delete_from_dnc modify_campaigns campaign_detail modify_dial_prefix delete_campaigns modify_ingroups delete_ingroups modify_inbound_dids delete_inbound_dids modify_custom_dialplans modify_remoteagents delete_remote_agents modify_scripts delete_scripts modify_filters delete_filters ast_admin_access ast_delete_phones modify_call_times delete_call_times modify_servers modify_shifts modify_phones modify_carriers modify_labels modify_colors modify_statuses modify_voicemail modify_audiostore modify_moh modify_tts modify_contacts callcard_admin add_timeclock_log modify_timeclock_log delete_timeclock_log manager_shift_enforcement_override pause_code_approval vdc_agent_api_access'
  local col updates="user='master'"
  for col in $columns; do updates+=",$col='1'"; done
  db_exec 'master privileges' "UPDATE vicidial_users SET $updates WHERE user_id='1';"
}
create_users_and_phones() {
  local count=$1 prefix=$2 password=$3 rtc=$4 asterisk_ip=$5 template=$6 start=${7:-1}
  local i suffix username existing usql psql created=0
  valid_ip "$asterisk_ip" || { err 'Invalid Asterisk IP'; return 1; }
  for ((i=start;i<start+count;i++)); do
    ((i<=99)) || { err 'Two-digit suffix exhausted'; return 1; }
    printf -v suffix '%02d' "$i"; username="${prefix}${suffix}"
    existing=$(db_query "SELECT COUNT(*) FROM vicidial_users WHERE user=$(sql_quote "$username");") || return 1
    [[ "$existing" == 0 ]] || { printf 'Skipping existing user %s\n' "$username"; continue; }
    existing=$(db_query "SELECT COUNT(*) FROM phones WHERE extension=$(sql_quote "$username");") || return 1
    [[ "$existing" == 0 ]] || { err "Phone $username exists; skipping"; continue; }
    usql="INSERT INTO vicidial_users (user,pass,full_name,user_level,user_group,phone_login,phone_pass,load_leads,campaign_detail,ast_admin_access,modify_users,agentcall_manual) VALUES ($(sql_quote "$username"),$(sql_quote "$password"),$(sql_quote "$username"),1,'ADMIN',$(sql_quote "$username"),$(sql_quote "$password"),0,0,0,0,1);"
    psql="INSERT INTO phones (extension,dialplan_number,voicemail_id,server_ip,login,pass,status,active,phone_type,fullname,protocol,local_gmt,company,picture,messages,old_messages,outbound_cid,conf_secret,phone_ip,computer_ip,is_webphone,template_id) VALUES ($(sql_quote "$username"),$(sql_quote "$username"),$(sql_quote "$username"),$(sql_quote "$asterisk_ip"),$(sql_quote "$username"),$(sql_quote "$password"),'ACTIVE','Y','',$(sql_quote "$username"),'SIP','-5.00','','',0,0,'',$(sql_quote "$password"),'','',$(sql_quote "$rtc"),$(sql_quote "$template"));"
    # A transaction prevents an orphan user if phone insertion fails.
    db_exec "user and phone $username" "START TRANSACTION; $usql $psql COMMIT;" || return 1
    printf '%-10s %-12s %-18s %-16s %s\n' "$username" "$username" "$password" "$asterisk_ip" "$rtc"
    LAST_USERS+=" $username"; ((created+=1))
  done
  printf 'Created %d pairs.\n' "$created"
}
user_section() {
  local rtc=$1 cluster=$2 start maxval suggested template=''
  info "Users and phones: WebRTC=$rtc cluster=$cluster"
  prepare_db || return 1
  if [[ "$cluster" == Y ]]; then
    ask_asterisk_ip || return 1
    printf 'WARNING: Remote Asterisk %s needs separate HTTP/WebSocket setup.\n' "$ASTERISK_IP"
    if confirm 'Print remote commands?'; then print_remote_commands; fi
  else ASTERISK_IP=$SERVER_IP; fi
  ask_count_prefix || return 1
  ask_password || return 1
  maxval=$(db_query "SELECT COALESCE(MAX(CAST(RIGHT(user,2) AS UNSIGNED)),0) FROM vicidial_users WHERE user REGEXP '^${AGENT_USER_PREFIX}[0-9][0-9]$';") || return 1
  suggested=$((maxval+1))
  while :; do read -r -p "Starting suffix [$suggested]: " start; start=${start:-$suggested}; [[ "$start" =~ ^[0-9]+$ ]] && ((start>=1 && start<=99)) && break; err 'Suffix must be 1-99'; done
  if [[ "$rtc" == Y ]]; then read -r -p "Template ID [$(hostname -s)-RTC]: " template; template=${template:-$(hostname -s)-RTC}; fi
  LAST_USERS=''
  printf '%-10s %-12s %-18s %-16s %s\n' USER PHONE PASSWORD ASTERISK_IP WEBRTC
  create_users_and_phones "$USERS_COUNT" "$AGENT_USER_PREFIX" "$AGENT_PASS" "$rtc" "$ASTERISK_IP" "$template" "$start"
}
add_users_webRTC_single() { user_section Y N; }
add_users_noWebRTC_single() { user_section N N; }
add_users_webRTC_cluster() { user_section Y Y; }
add_users_noWebRTC_cluster() { user_section N Y; }
print_remote_commands() {
  cat <<'COMMANDS'
Run on the Asterisk server after checking its configuration:
sed -i "/bindaddr=/c\\bindaddr=0.0.0.0" /etc/asterisk/http.conf
sed -i "/;bindport=8088/c\\bindport=8088" /etc/asterisk/http.conf
echo "load => res_http_websocket.so" >> /etc/asterisk/modules.conf
asterisk -rx 'module reload http'
COMMANDS
}
cluster_changes() {
  local description prefix existing
  info 'Cluster changes'
  prepare_db || return 1
  ask_asterisk_ip || return 1
  if [[ "$ASTERISK_IP" == "$SERVER_IP" ]]; then
    command -v asterisk >/dev/null && asterisk -rx 'core show version' >/dev/null || { err 'Local Asterisk check failed'; return 1; }
  else
    if ! timeout 4 bash -c 'echo >/dev/tcp/"$1"/3306' _ "$ASTERISK_IP" 2>/dev/null; then
      err 'Remote port 3306 unreachable. Note: remote Asterisk may use a centralized DB; this test alone is not authoritative.'
      confirm 'Continue despite failed connectivity check?' || return 1
    fi
  fi
  existing=$(db_query "SELECT COUNT(*) FROM servers WHERE server_ip=$(sql_quote "$ASTERISK_IP");") || return 1
  if [[ "$existing" == 0 ]]; then
    read -r -p 'Remote server description: ' description
    while :; do read -r -p 'Remote server prefix (alphanumeric): ' prefix; [[ "$prefix" =~ ^[A-Za-z0-9]+$ ]] && break; err 'Invalid prefix'; done
    db_exec 'register remote server' "INSERT INTO servers (server_ip,server_description,server_prefix,active) VALUES ($(sql_quote "$ASTERISK_IP"),$(sql_quote "$description"),$(sql_quote "$prefix"),'Y');" || return 1
  else info 'Server already registered; no overwrite'; fi
  ask_fqdn || return 1
  set_webphone_url && set_local_limits || return 1
  printf '\nLocal http.conf has NOT been modified.\n'
  print_remote_commands
}
campaign_setup() {
  info 'Campaign 454, carrier, AMD'
  prepare_db || return 1
  local carrier_ip account dialplan
  if confirm 'Use a remote Asterisk server for carrier?'; then ask_asterisk_ip || return 1; else ASTERISK_IP=$SERVER_IP; fi
  carrier_ip=$ASTERISK_IP
  account=$(printf '[Globilinks]\r\ndisallow=all\r\nallow=ulaw\r\nallow=g729\r\ntype=peer\r\nhost=185.188.124.88\r\nport=5060\r\ndtmfmode=rfc2833\r\ncanreinvite=no\r\ninsecure=port,invite\r\ncontext=trunkinbound')
  dialplan=$(printf 'exten => _94162X.,1,AGI(agi://127.0.0.1:4577/call_log)\r\nexten => _94162X.,2,Dial(${VOIP}/${EXTEN:5},60,tTor)\r\nexten => _94162X.,3,Hangup')
  db_exec 'Globilinks carrier upsert' "INSERT INTO vicidial_server_carriers (carrier_id,carrier_name,registration_string,template_id,account_entry,protocol,globals_string,dialplan_entry,server_ip,active,carrier_description,user_group) VALUES ('Globilinks','Globilinks','','--NONE--',$(sql_quote "$account"),'SIP','',$(sql_quote "$dialplan"),$(sql_quote "$carrier_ip"),'Y','','---ALL---') ON DUPLICATE KEY UPDATE carrier_name=VALUES(carrier_name),account_entry=VALUES(account_entry),dialplan_entry=VALUES(dialplan_entry),server_ip=VALUES(server_ip),active=VALUES(active);" || return 1
  db_exec 'campaign 454 upsert' "INSERT INTO vicidial_campaigns (campaign_id,campaign_name,campaign_description,active,next_agent_call,local_call_time,dial_method) VALUES ('454','USA-Campaign','Customer Services','Y','longest_wait_time','24hours','RATIO') ON DUPLICATE KEY UPDATE campaign_name=VALUES(campaign_name),campaign_description=VALUES(campaign_description),active=VALUES(active),next_agent_call=VALUES(next_agent_call),local_call_time=VALUES(local_call_time),dial_method=VALUES(dial_method);" || return 1
  db_exec 'campaign 454 options' "UPDATE vicidial_campaigns SET dial_prefix='74',manual_dial_prefix='68',campaign_vdad_exten='8369',campaign_recording='ALLCALLS',waitforsilence_options='2000,2,30',amd_type='AMD',amd_agent_route_options='ENABLED',no_hopper_leads_logins='Y',hopper_level='1000' WHERE campaign_id='454';" || return 1
  db_exec 'AMD container upsert' "INSERT INTO vicidial_settings_containers (container_id,container_notes,container_type,user_group,container_entry) VALUES ('AMD_AGENT_OPT_454','AMD agent options for 454 campaign','AMD_AGENT_OPTIONS','---ALL---','HUMAN,HUMAN\\r\\nNOTSURE,TOOLONG\\r\\nMACHINE,INITIALSILENCE') ON DUPLICATE KEY UPDATE container_notes=VALUES(container_notes),container_type=VALUES(container_type),user_group=VALUES(user_group),container_entry=VALUES(container_entry);" || return 1
  db_exec 'remove obsolete callin/gs102 phones' "DELETE FROM phones WHERE extension IN ('callin','gs102');"
}
firewall_only() {
  info 'Firewall rules'
  command -v firewall-cmd >/dev/null || { err 'firewall-cmd missing'; return 1; }
  systemctl enable --now firewalld || { err 'firewalld failed to start'; return 1; }
  local service zone port
  for service in apache2 apache2-ssl; do
    if firewall-cmd --zone=public --permanent --query-service="$service" >/dev/null 2>&1; then
      firewall-cmd --zone=public --permanent --remove-service="$service" || return 1
      log "FIREWALL remove service $service"
    fi
  done
  for service in dynportal dynportal-ssl; do
    firewall-cmd --zone=public --permanent --add-service="$service" || { err "Missing firewall service definition: $service"; return 1; }
    log "FIREWALL add $service"
  done
  for zone in public external; do
    firewall-cmd --zone="$zone" --permanent --add-port="$SSH_PORT/tcp" || return 1
    log "FIREWALL add $SSH_PORT/tcp $zone"
  done
  firewall-cmd --zone=public --permanent --add-port=8089/tcp || return 1
  # Do not remove SSH service until new port and sshd configuration are verified.
  if sshd -T 2>/dev/null | grep -Eq "^port $SSH_PORT$"; then
    firewall-cmd --zone=public --permanent --remove-service=ssh || return 1
    log 'FIREWALL remove default SSH service'
  else printf 'Retaining SSH service: sshd is not confirmed on new port.\n'; fi
  firewall-cmd --reload || return 1
  log 'FIREWALL reload'
}
ssh_port_only() {
  info 'SSH port change'
  require_file "$SSH_CONFIG_FILE" || return 1
  if ! grep -Eq "^[[:space:]]*Port[[:space:]]+$SSH_PORT([[:space:]]|$)" "$SSH_CONFIG_FILE"; then
    cp -a "$SSH_CONFIG_FILE" "${SSH_CONFIG_FILE}.vici.bak" || return 1
    sed -i -E '/^[[:space:]]*#?[[:space:]]*Port[[:space:]]+[0-9]+([[:space:]]|$)/d' "$SSH_CONFIG_FILE" || return 1
    printf '\nPort %s\n' "$SSH_PORT" >> "$SSH_CONFIG_FILE"
    log "FILE EDIT $SSH_CONFIG_FILE"
  fi
  if ! sshd -t; then err 'Invalid sshd config; restoring backup if present'; [[ -f "${SSH_CONFIG_FILE}.vici.bak" ]] && cp -a "${SSH_CONFIG_FILE}.vici.bak" "$SSH_CONFIG_FILE"; return 1; fi
  # Open firewall before changing sshd listener to reduce lockout risk.
  if command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
    firewall-cmd --zone=public --permanent --add-port="$SSH_PORT/tcp" && firewall-cmd --reload || return 1
  fi
  systemctl restart sshd && log 'SERVICE restart sshd' || { err 'sshd restart failed'; return 1; }
  printf 'Verify a NEW SSH session on port %s before closing this one.\n' "$SSH_PORT"
}
configure_cron() {
  local tmp final
  tmp=$(mktemp) && final=$(mktemp) || return 1
  crontab -l 2>/dev/null > "$tmp" || :
  grep -v '/usr/bin/VB-firewall' "$tmp" > "$final" || :
  printf '%s\n' '* * * * * /usr/bin/VB-firewall --white --dynamic --quiet' '@reboot /usr/bin/VB-firewall --white --dynamic --quiet' >> "$final"
  crontab "$final" || { rm -f "$tmp" "$final"; return 1; }
  rm -f "$tmp" "$final"; log 'CRON replaced VB-firewall jobs'
}
dynportal_only() {
  info 'DynPortal redirect settings'
  require_file "$OVERRIDE_PATH" || return 1
  ask_fqdn || return 1
  local url admin
  url="https://$FQDN/vicidial/welcome.php"; admin="https://$FQDN/vicidial/admin.php"
  cp -a "$OVERRIDE_PATH" "${OVERRIDE_PATH}.vici.bak" || return 1
  # Replace current values regardless of whether a previous run changed them.
  sed -i -E "s|\\\$PORTAL_redirecturl='[^']*';|\\\$PORTAL_redirecturl='$url';|; s|\\\$PORTAL_redirectadmin='[^']*';|\\\$PORTAL_redirectadmin='$admin';|" "$OVERRIDE_PATH" || return 1
  log "FILE EDIT $OVERRIDE_PATH"
  configure_cron || return 1
  if [[ -d /var/spool/asterisk ]]; then chmod 755 /var/spool/asterisk && log 'FILE MODE /var/spool/asterisk 755'; fi
}
initial_setup() {
  info 'Initial setup (single-node Asterisk)'
  prepare_db || return 1
  ask_fqdn || return 1
  configure_http_local && install_webphone && set_webphone_url && set_local_limits && set_master_permissions || return 1
  # Keep the FQDN from this section; no second prompt.
  dynportal_apply_existing_fqdn || return 1
  ssh_port_only && firewall_only
}
dynportal_apply_existing_fqdn() {
  # Reuse existing FQDN without asking again.
  require_file "$OVERRIDE_PATH" || return 1
  cp -a "$OVERRIDE_PATH" "${OVERRIDE_PATH}.vici.bak" || return 1
  sed -i -E "s|\\\$PORTAL_redirecturl='[^']*';|\\\$PORTAL_redirecturl='https://$FQDN/vicidial/welcome.php';|; s|\\\$PORTAL_redirectadmin='[^']*';|\\\$PORTAL_redirectadmin='https://$FQDN/vicidial/admin.php';|" "$OVERRIDE_PATH" || return 1
  log "FILE EDIT $OVERRIDE_PATH"
  configure_cron || return 1
  [[ ! -d /var/spool/asterisk ]] || { chmod 755 /var/spool/asterisk && log 'FILE MODE recording directory'; }
}
show_summary() {
  info 'Credentials / summary'
  read_config || return 1
  printf 'Local server: %s\nAsterisk: %s\nFQDN: %s\nLog: %s\n' "$SERVER_IP" "${ASTERISK_IP:-$SERVER_IP}" "${FQDN:-not set this session}" "$LOG_FILE"
  [[ -z "$FQDN" ]] || printf 'Portal: https://%s/vicidial/welcome.php\nAdmin: https://%s/vicidial/admin.php\n' "$FQDN" "$FQDN"
  printf 'Admin user: master\n'
  MASTER_PASS=$(random_pass) || return 1
  printf 'Suggested master password (NOT applied to DB): %s\n' "$MASTER_PASS"
  [[ -z "$LAST_USERS" ]] || printf 'Created users this session:%s\nAgent password: %s\n' "$LAST_USERS" "$AGENT_PASS"
}
reboot_server() {
  info 'Reboot server'
  confirm 'Schedule reboot in 10 seconds?' || return 0
  printf 'Rebooting in 10 seconds; type CANCEL then Enter to abort.\n'
  local answer=''
  read -r -t 10 answer || :
  [[ "${answer,,}" == cancel || "${answer,,}" == n || "${answer,,}" == no ]] && { printf 'Cancelled.\n'; return 0; }
  log 'SERVICE reboot requested'
  systemctl reboot
}
main_menu() {
  local choice
  while :; do
    cat <<'MENU'

1)  Initial Setup (firewall, Asterisk HTTP/WebSocket, DynPortal, SSH port)
2)  Add Users + Phones with WebRTC (single node)
3)  Add Users + Phones without WebRTC (single node)
4)  Add Users + Phones with WebRTC (cluster)
5)  Add Users + Phones without WebRTC (cluster)
6)  Cluster Changes (configure this box as a cluster member)
7)  Campaign Setup (create/update 454 campaign, carriers, AMD)
8)  Firewall Rules Only
9)  SSH Port Change Only
10) DynPortal Redirect Settings Only
11) Show Credentials / Summary
12) Reboot Server
0)  Exit
MENU
    read -r -p 'Choice: ' choice || break
    case "$choice" in
      1) initial_setup || err 'Initial setup incomplete';;
      2) add_users_webRTC_single || err 'User creation failed';;
      3) add_users_noWebRTC_single || err 'User creation failed';;
      4) add_users_webRTC_cluster || err 'User creation failed';;
      5) add_users_noWebRTC_cluster || err 'User creation failed';;
      6) cluster_changes || err 'Cluster changes failed';;
      7) campaign_setup || err 'Campaign setup failed';;
      8) firewall_only || err 'Firewall setup failed';;
      9) ssh_port_only || err 'SSH setup failed';;
      10) dynportal_only || err 'DynPortal setup failed';;
      11) show_summary || err 'Summary failed';;
      12) reboot_server || err 'Reboot failed';;
      0) break;;
      *) err 'Invalid menu option';;
    esac
  done
  printf 'Log file: %s\n' "$LOG_FILE"
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ $EUID -eq 0 ]] || { err 'Run as root'; exit 1; }
  main_menu
fi