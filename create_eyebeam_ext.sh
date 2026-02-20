#!/bin/bash

# ========= USER INPUT SECTION =========
echo -n "  Please enter your START EXT : "
read START_EXT
echo
echo -n "  Please enter your END EXT : "
read END_EXT
echo
echo -n "  Please enter your END PASSWORD : "
read PASSWORD
echo
SERVER_IP=`cat /etc/astguiclient.conf | grep VARserver_ip | cut -d ">" -f2- | tr -d '[:space:]'`

# Get info so we can make DB updates
SERVER_IP=`cat /etc/astguiclient.conf | grep VARserver_ip | cut -d ">" -f2- | tr -d '[:space:]'`
DB_HOST=`cat /etc/astguiclient.conf | grep VARDB_server | cut -d ">" -f2- | tr -d '[:space:]'`
DB_USER=`cat /etc/astguiclient.conf | grep VARDB_user | cut -d ">" -f2- | tr -d '[:space:]'`
DB_PASS=`cat /etc/astguiclient.conf | grep VARDB_pass | cut -d ">" -f2- | tr -d '[:space:]'`
DB_PORT=`cat /etc/astguiclient.conf | grep VARDB_port | cut -d ">" -f2- | tr -d '[:space:]'`
DB_NAME=`cat /etc/astguiclient.conf | grep VARDB_database | cut -d ">" -f2- | tr -d '[:space:]'`
# ======================================

echo "Creating VICIdial users from $START_EXT to $END_EXT ..."
echo

for (( EXT=$START_EXT; EXT<=$END_EXT; EXT++ ))
do

mysql -u$DB_USER -p$DB_PASS $DB_NAME <<EOF

INSERT INTO vicidial_users
(user,pass,full_name,user_level,user_group,phone_login,phone_pass,load_leads,campaign_detail,ast_admin_access,modify_users)
VALUES
('$EXT','$PASSWORD','$EXT','1','ADMIN','$EXT','$PASSWORD','0','0','0','0');

INSERT INTO phones
(extension,dialplan_number,voicemail_id,server_ip,login,pass,status,active,phone_type,fullname,protocol,local_gmt,company,picture,messages,old_messages,outbound_cid,conf_secret,phone_ip,computer_ip)
VALUES
('$EXT','$EXT','$EXT','$SERVER_IP','$EXT','$PASSWORD','ACTIVE','Y','','$EXT','SIP','-5.00','','','0','0','',''$PASSWORD'','','');

EOF

echo "Created User & Phone: $EXT"

done

echo
echo "All users created successfully."
