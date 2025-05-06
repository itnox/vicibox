#!/bin/bash

# ViciDial CID Group Management Script

# Get info so we can make DB updates
SERVER_IP=`cat /etc/astguiclient.conf | grep VARserver_ip | cut -d ">" -f2- | tr -d '[:space:]'`
DB_HOST=`cat /etc/astguiclient.conf | grep VARDB_server | cut -d ">" -f2- | tr -d '[:space:]'`
DB_USER=`cat /etc/astguiclient.conf | grep VARDB_user | cut -d ">" -f2- | tr -d '[:space:]'`
DB_PASS=`cat /etc/astguiclient.conf | grep VARDB_pass | cut -d ">" -f2- | tr -d '[:space:]'`
DB_PORT=`cat /etc/astguiclient.conf | grep VARDB_port | cut -d ">" -f2- | tr -d '[:space:]'`
DB_NAME=`cat /etc/astguiclient.conf | grep VARDB_database | cut -d ">" -f2- | tr -d '[:space:]'`

function list_cid_groups() {
    echo
    echo "Existing CID Groups:"
    mysql -u $DB_USER -p$DB_PASS -D $DB_NAME -e "SELECT cid_group_id FROM vicidial_cid_groups;"
    echo
}

function create_cid_group() {
    echo
    echo "CID Group Bulk Upload"
    echo
	
	echo
    echo "Available .txt files in current directory:"
    ls *.txt 2>/dev/null
    echo

    read -p "Please Enter CID Group Name: " CID_GROUP

    if [ -z "$CID_GROUP" ]; then
        echo "CID Group name cannot be empty!"
        return
    fi

    echo
    echo "Available .txt files in current directory:"
    ls *.txt 2>/dev/null
    echo

    read -p "Enter the name of the text file to insert DIDs from: " FILE_NAME

    if [ ! -f "$FILE_NAME" ]; then
        echo "File '$FILE_NAME' not found. Cancelling."
        return
    fi

    COUNT=$(wc -l < "$FILE_NAME")
    echo "Your DIDs Count is $COUNT"
    
    read -p "Do you want to proceed with inserting DIDs into CID Group '$CID_GROUP'? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Operation cancelled."
        return
    fi

    mysql -u $DB_USER -p$DB_PASS $DB_NAME --execute="INSERT INTO vicidial_cid_groups (cid_group_id, cid_group_notes, cid_group_type, user_group, cid_auto_rotate_minutes, cid_auto_rotate_minimum, cid_auto_rotate_calls, cid_last_auto_rotate) VALUES ('$CID_GROUP', 'New CID Group Created by Script', 'none', '---ALL---', '0', '0', '0', NULL);"

    while IFS= read -r line; do
        echo "Processing: $line"
        mysql -u $DB_USER -p$DB_PASS $DB_NAME --execute="INSERT INTO vicidial_campaign_cid_areacodes (campaign_id, areacode, outbound_cid, active, cid_description) SELECT cg.cid_group_id AS campaign_id, 'none', '$line', 'Y', 'USA' FROM vicidial_cid_groups cg WHERE cg.cid_group_id = '$CID_GROUP';"
    done < "$FILE_NAME"

    echo "All Done!"
}

function delete_cid_group() {
    list_cid_groups

    read -p "Enter the CID Group Name to delete: " DEL_CID_GROUP

    if [ -z "$DEL_CID_GROUP" ]; then
        echo "No CID Group name entered. Cancelling."
        return
    fi

    read -p "Are you sure you want to delete CID Group '$DEL_CID_GROUP'? [y/N]: " CONFIRM

    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        mysql -u $DB_USER -p$DB_PASS $DB_NAME --execute="DELETE FROM vicidial_campaign_cid_areacodes WHERE campaign_id='$DEL_CID_GROUP';"
        mysql -u $DB_USER -p$DB_PASS $DB_NAME --execute="DELETE FROM vicidial_cid_groups WHERE cid_group_id='$DEL_CID_GROUP';"
        echo "CID Group '$DEL_CID_GROUP' deleted successfully."
    else
        echo "Deletion cancelled."
    fi
}

while true; do
    echo
    echo "Please choose an action:"
    echo "1) Create new CID Group"
    echo "2) Delete CID Group"
    echo "3) Exit"
    read -p "Enter your choice [1-3]: " ACTION

    case $ACTION in
        1) create_cid_group ;;
        2) delete_cid_group ;;
        3) echo "Exiting script. Goodbye!"; exit 0 ;;
        *) echo "Invalid choice. Please try again." ;;
    esac
done
