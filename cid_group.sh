#!/bin/bash

# ViciDial credentials
echo
echo "CID Group Bulk Upload"
echo

echo
echo
echo -n "  Please Enter CID Group Name : "
read CID_GROUP
echo
echo

COUNT=$(cat cid.txt | wc -l)
echo "Your DIDs Count is $COUNT"

# Get info so we can make DB updates
SERVER_IP=`cat /etc/astguiclient.conf | grep VARserver_ip | cut -d ">" -f2- | tr -d '[:space:]'`
DB_HOST=`cat /etc/astguiclient.conf | grep VARDB_server | cut -d ">" -f2- | tr -d '[:space:]'`
DB_USER=`cat /etc/astguiclient.conf | grep VARDB_user | cut -d ">" -f2- | tr -d '[:space:]'`
DB_PASS=`cat /etc/astguiclient.conf | grep VARDB_pass | cut -d ">" -f2- | tr -d '[:space:]'`
DB_PORT=`cat /etc/astguiclient.conf | grep VARDB_port | cut -d ">" -f2- | tr -d '[:space:]'`
DB_NAME=`cat /etc/astguiclient.conf | grep VARDB_database | cut -d ">" -f2- | tr -d '[:space:]'`

mysql -u $DB_USER -p$DB_PASS $DB_NAME --execute="INSERT INTO vicidial_cid_groups (cid_group_id, cid_group_notes, cid_group_type, user_group, cid_auto_rotate_minutes, cid_auto_rotate_minimum, cid_auto_rotate_calls, cid_last_auto_rotate) values ('$CID_GROUP','New CID Group Created by Script', 'none', '---ALL---', '0', '0', '0','NULL');"


for (( i = 1; i <= $COUNT; i++ ))
do
    read line
    echo "Processing: $line"
    mysql -u $DB_USER -p$DB_PASS $DB_NAME --execute="INSERT INTO vicidial_campaign_cid_areacodes (campaign_id, areacode, outbound_cid, active, cid_description) SELECT cg.cid_group_id AS campaign_id, 'none' AS areacode, '$line' AS outbound_cid, 'Y' AS active, 'USA' AS cid_description FROM vicidial_cid_groups cg WHERE cg.cid_group_id = '$CID_GROUP';"
done < cid.txt


echo "ALL Done!"
