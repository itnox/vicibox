#!/bin/bash
# ViciBox 12 setup script
# Improved from vici_changes.sh (originally written for ViciBox 11)
# Key differences vs ViciBox 11 version:
#   - Automatically adds Listen 81 and Listen 446 to Apache config
#   - Fixed crontab handling (old version was broken: sed -i with >> redirect is a no-op)
#   - Old VB-firewall cron lines are commented out, not silently dropped

# ---------------------------------------------------------------------------
# File locations
# ---------------------------------------------------------------------------
ASTGUICLIENT="/etc/astguiclient.conf"
ASTERISK_CONF="/etc/asterisk/http.conf"
ASTERISK_MODULES="/etc/asterisk/modules.conf"
APACHE_LISTEN_CONF="/etc/apache2/listen.conf"          # ViciBox 12 — port Listen directives live here
OVERRIDE_PATH="/srv/www/vhosts/dynportal/inc/defaults.inc.php"
SSH_PORT="2008"
SSH_CONFIG_FILE="/etc/ssh/sshd_config"
STR="01"
LOCAL_IP="127.0.0.1"
ALL_IP="0.0.0.0"

# ---------------------------------------------------------------------------
# Read DB credentials from astguiclient.conf
# ---------------------------------------------------------------------------
SERVER_IP=$(grep VARserver_ip  "$ASTGUICLIENT" | cut -d ">" -f2- | tr -d '[:space:]')
DB_HOST=$(grep VARDB_server    "$ASTGUICLIENT" | cut -d ">" -f2- | tr -d '[:space:]')
DB_USER=$(grep VARDB_user      "$ASTGUICLIENT" | cut -d ">" -f2- | tr -d '[:space:]')
DB_PASS=$(grep VARDB_pass      "$ASTGUICLIENT" | cut -d ">" -f2- | tr -d '[:space:]')
DB_PORT=$(grep VARDB_port      "$ASTGUICLIENT" | cut -d ">" -f2- | tr -d '[:space:]')
DB_NAME=$(grep VARDB_database  "$ASTGUICLIENT" | cut -d ">" -f2- | tr -d '[:space:]')

# ---------------------------------------------------------------------------
# Start / enable firewalld
# ---------------------------------------------------------------------------
sudo systemctl start firewalld
sudo systemctl enable firewalld

# ---------------------------------------------------------------------------
# Collect user input
# ---------------------------------------------------------------------------
echo
echo "Installing WebRTC (ViciBox 12)"
echo

echo -n "  Please enter your FQDN : "
read FQDN

echo
echo "     FQDN : $FQDN"
echo

echo -n "  How many Users you want to Create? "
read USERS
echo

SUGGESTED_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
echo "  Suggested random password: $SUGGESTED_PASS"
echo -n "  Please Enter Agent User Password (press Enter to use suggested): "
read -s AGENT_PASS
echo
[ -z "$AGENT_PASS" ] && AGENT_PASS="$SUGGESTED_PASS"

echo
echo -n "  Please Enter Agent Users Prefix (2 digits, e.g. 50) : "
read AGENT_USER_PREFIX
echo

# ---------------------------------------------------------------------------
# Asterisk / WebRTC
# ---------------------------------------------------------------------------
echo "   Making changes to Asterisk/http.conf..."
sed -i "/bindaddr=$LOCAL_IP/c\\bindaddr=$ALL_IP" "$ASTERISK_CONF"
sed -i "/;bindport=8088/c\\bindport=8088" "$ASTERISK_CONF"
echo "load => res_http_websocket.so" >> "$ASTERISK_MODULES"
echo "   done."

if [ "$(pgrep -c "^asterisk$")" -gt 0 ]; then
    echo "   Restarting Asterisk..."
    /usr/sbin/rasterisk -x 'module reload http'
    /sbin/service asterisk restart
    echo "   done."
fi

# ---------------------------------------------------------------------------
# Download ViciPhone webphone
# ---------------------------------------------------------------------------
echo
echo "   Downloading Webphone..."
git clone https://github.com/vicimikec/ViciPhone.git /var/tmp/ViciPhone
cp -r /var/tmp/ViciPhone/src /srv/www/htdocs/agc/viciphone
chmod -R 755 /srv/www/htdocs/agc/viciphone
echo "   Done."

# ---------------------------------------------------------------------------
# Apache — add Listen 81 next to Listen 80 (plain block)
#          add Listen 446 next to Listen 443 (inside <IfModule mod_ssl.c>)
# ---------------------------------------------------------------------------
echo
echo "   Configuring Apache listen ports (81, 446)..."

if ! grep -q "^Listen 81$" "$APACHE_LISTEN_CONF"; then
    # Insert "Listen 81" on the line immediately after "Listen 80"
    sed -i '/^Listen 80$/a Listen 81' "$APACHE_LISTEN_CONF"
    echo "   Added Listen 81 (after Listen 80)"
else
    echo "   Listen 81 already present, skipping."
fi

if ! grep -q "^[[:space:]]*Listen 446$" "$APACHE_LISTEN_CONF"; then
    # Insert "Listen 446" on the line immediately after "Listen 443" (inside SSL block)
    sed -i '/^[[:space:]]*Listen 443$/a\\t\t\t\tListen 446' "$APACHE_LISTEN_CONF"
    echo "   Added Listen 446 (after Listen 443)"
else
    echo "   Listen 446 already present, skipping."
fi

echo "   Reloading Apache..."
sudo systemctl reload apache2
echo "   Done."

# ---------------------------------------------------------------------------
# ViciDial DB changes
# ---------------------------------------------------------------------------
echo
echo "   Making changes to ViciDial..."
mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" --execute="update system_settings set default_webphone='1', webphone_url='https://$FQDN/agc/viciphone/viciphone.php', auto_dial_limit='20';"
mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" --execute="update servers set max_vicidial_trunks='150', outbound_calls_per_second='50' where server_ip='$SERVER_IP';"
mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" --execute="update vicidial_users set user='master', view_reports='1', alter_agent_interface_options='1', modify_users='1', change_agent_campaign='1', delete_users='1', modify_usergroups='1', delete_user_groups='1', modify_lists='1', delete_lists='1', load_leads='1', modify_leads='1', export_gdpr_leads='1', download_lists='1', export_reports='1', delete_from_dnc='1', modify_campaigns='1', campaign_detail='1', modify_dial_prefix='1', delete_campaigns='1', modify_ingroups='1', delete_ingroups='1', modify_inbound_dids='1', delete_inbound_dids='1', modify_custom_dialplans='1', modify_remoteagents='1', delete_remote_agents='1', modify_scripts='1', delete_scripts='1', modify_filters='1', delete_filters='1', ast_admin_access='1', ast_delete_phones='1', modify_call_times='1', delete_call_times='1', modify_servers='1', modify_shifts='1', modify_phones='1', modify_carriers='1', modify_labels='1', modify_colors='1', modify_statuses='1', modify_voicemail='1', modify_audiostore='1', modify_moh='1', modify_tts='1', modify_contacts='1', callcard_admin='1', add_timeclock_log='1', modify_timeclock_log='1', delete_timeclock_log='1', manager_shift_enforcement_override='1', pause_code_approval='1', vdc_agent_api_access='1' where user_id='1';"
mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" --execute="insert into vicidial_server_carriers (carrier_id, carrier_name, registration_string,template_id,account_entry,protocol,globals_string,dialplan_entry,server_ip,active,carrier_description,user_group) values('Globilinks', 'Globilinks', '', '--NONE--','[Globilinks]\r\ndisallow=all\r\nallow=ulaw\r\nallow=g729\r\ntype=peer\r\nhost=185.188.124.88\r\nport=5060\r\ndtmfmode=rfc2833\r\ncanreinvite=no\r\ninsecure=port,invite\r\ncontext=trunkinbound','SIP','','exten => _94162X.,1,AGI(agi://127.0.0.1:4577/call_log)\r\nexten => _94162X.,2,Dial(\${VOIP}/\${EXTEN:5},60,tTor)\r\nexten => _94162X.,3,Hangup','$SERVER_IP','Y','','---ALL---');"
echo "   Done."

# ---------------------------------------------------------------------------
# Create agent users
# ---------------------------------------------------------------------------
echo
echo "   Creating Users..."
for (( i = 1; i <= USERS; i++ )); do
    USER_SUFFIX=$(printf "%02d" $i)
    mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" --execute="insert into vicidial_users (user,pass,full_name,user_level,user_group,phone_login,phone_pass,load_leads,campaign_detail,ast_admin_access,modify_users,agentcall_manual) values('$AGENT_USER_PREFIX$USER_SUFFIX','$AGENT_PASS','$AGENT_USER_PREFIX$USER_SUFFIX','1','ADMIN','$AGENT_USER_PREFIX$USER_SUFFIX','$AGENT_PASS','0','0','0','0','1');"
done
echo "   Done."

# ---------------------------------------------------------------------------
# Create phones
# ---------------------------------------------------------------------------
echo
echo "   Creating Phones..."
for (( i = 1; i <= USERS; i++ )); do
    USER_SUFFIX=$(printf "%02d" $i)
    mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" --execute="insert into phones (extension,dialplan_number,voicemail_id,server_ip,login,pass,status,active,phone_type,fullname,protocol,local_gmt,company,picture,messages,old_messages,outbound_cid,conf_secret,phone_ip,computer_ip,is_webphone,template_id) values('$AGENT_USER_PREFIX$USER_SUFFIX','$AGENT_USER_PREFIX$USER_SUFFIX','$AGENT_USER_PREFIX$USER_SUFFIX','$SERVER_IP','$AGENT_USER_PREFIX$USER_SUFFIX','$AGENT_PASS','ACTIVE','Y','','$AGENT_USER_PREFIX$USER_SUFFIX','SIP','-5.00','','','0','0','','$AGENT_PASS','','','Y','${HOSTNAME}-RTC');"
done
echo "   Done."

# ---------------------------------------------------------------------------
# Create campaign
# ---------------------------------------------------------------------------
echo
echo "   Creating Campaign..."
mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" --execute="insert into vicidial_campaigns (campaign_id,campaign_name,campaign_description,active,next_agent_call,local_call_time,dial_method) values ('454','USA-Campaign','Customer Services','Y','longest_wait_time','24hours','RATIO');"
mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" --execute="update vicidial_campaigns set dial_prefix='74', manual_dial_prefix='68', campaign_vdad_exten='8369', campaign_recording='ALLCALLS', waitforsilence_options='2000,2,30', amd_type='AMD', amd_agent_route_options='ENABLED', no_hopper_leads_logins='Y', hopper_level='1000' where campaign_id='454';"
mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" --execute="INSERT INTO vicidial_settings_containers(container_id,container_notes,container_type,user_group,container_entry) VALUES ('AMD_AGENT_OPT_454','AMD agent options for 454 campaign','AMD_AGENT_OPTIONS','---ALL---','HUMAN,HUMAN\r\nNOTSURE,TOOLONG\r\nMACHINE,INITIALSILENCE');"
mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" --execute="DELETE FROM phones WHERE extension IN ('callin', 'gs102');"
echo "   Done."

# ---------------------------------------------------------------------------
# Crontab — comment out old VB-firewall jobs, add new whitelist-only job
#
# The ViciBox 11 script was broken here:
#   - /tmp/rootcron was never seeded with the current crontab
#   - "sed -i ... >> /tmp/rootcron" is invalid (sed -i edits in-place, produces no stdout)
# Fixed approach:
#   1. Dump current crontab to /tmp/rootcronold (backup)
#   2. Comment out any existing VB-firewall lines  →  /tmp/rootcron
#   3. Append new cron entries
#   4. Install new crontab
# ---------------------------------------------------------------------------
echo
echo "   Updating crontab..."
crontab -l 2>/dev/null > /tmp/rootcronold || touch /tmp/rootcronold

# Comment out all existing VB-firewall entries (preserve them, just disable)
# Pattern: match any line that contains VB-firewall and does NOT already start with #
sed '/^[^#].*VB-firewall/s/^/#/' /tmp/rootcronold > /tmp/rootcron

echo '' >> /tmp/rootcron
echo "### Checking firewall every minute for new IPs (added by vici_changes_vb12.sh)" >> /tmp/rootcron
echo "* * * * * /usr/bin/VB-firewall --white --dynamic --quiet" >> /tmp/rootcron
echo "@reboot  /usr/bin/VB-firewall --white --dynamic --quiet" >> /tmp/rootcron

crontab /tmp/rootcron
echo "   Old VB-firewall cron jobs commented out. New entries added."
echo "   Backup of previous crontab saved to /tmp/rootcronold"
echo "   Done."

# ---------------------------------------------------------------------------
# Recording access
# ---------------------------------------------------------------------------
echo
echo "   Granting Recording Access..."
sudo chmod 755 /var/spool/asterisk
echo "   Done."

# ---------------------------------------------------------------------------
# DynPortal redirect settings
# ---------------------------------------------------------------------------
echo
echo "   Redirect Settings..."
sed -i "s|\$PORTAL_redirecturl='X';|\$PORTAL_redirecturl='https://$FQDN/vicidial/welcome.php';|" "$OVERRIDE_PATH"
sed -i "s|\$PORTAL_redirectadmin='https://server.ip/vicidial/admin.php';|\$PORTAL_redirectadmin='https://$FQDN/vicidial/admin.php';|" "$OVERRIDE_PATH"
echo "   Done."

# ---------------------------------------------------------------------------
# SSH port
# ---------------------------------------------------------------------------
echo
echo "   Changing SSH PORT to $SSH_PORT..."
sudo sed -i "s/^#Port 22/Port $SSH_PORT/" "$SSH_CONFIG_FILE"
/sbin/service sshd restart
echo "   Done."

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------
echo
echo "   Firewall Changes..."
sudo firewall-cmd --zone=public --remove-service=apache2 --permanent
sudo firewall-cmd --zone=public --remove-service=apache2-ssl --permanent
sudo firewall-cmd --zone=public --add-service=dynportal --permanent
sudo firewall-cmd --zone=public --add-service=dynportal-ssl --permanent
sudo firewall-cmd --zone=public --add-port=2008/tcp --permanent
sudo firewall-cmd --zone=public --add-port=8089/tcp --permanent
sudo firewall-cmd --zone=public --remove-service=ssh --permanent
sudo firewall-cmd --reload
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
echo
echo "  Agent Credentials:"
echo "    user : $AGENT_USER_PREFIX$STR  to  $AGENT_USER_PREFIX$(printf "%02d" $USERS)"
echo "    pass : $AGENT_PASS"
echo "================================================================"

# ---------------------------------------------------------------------------
# Reboot prompt
# ---------------------------------------------------------------------------
echo
echo -n "   Do you want to reboot the server? (N/y) : "
read PROMPT
if [ "${PROMPT,,}" == "y" ]; then
    echo "   Rebooting Server in 10 seconds..."
    sleep 10
    sudo reboot
else
    echo "   Please reboot the server manually."
fi
echo
echo "  Done."
