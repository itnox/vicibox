#!/bin/bash

# === Terminal Colors ===
GREEN='\e[32m'
RED='\e[31m'
YELLOW='\e[33m'
CYAN='\e[36m'
NC='\e[0m'

# === Database Credentials ===
DBUSER="root"
DBPASS="ABC@xmenx1690"
DBNAME="asterisk"

# === Port Variables ===
tcp_ports="22 443 2008 80"
udp_ports="6071 5060 57889"

# === File Paths ===
SIP_CONF="/etc/asterisk/sip_custom.conf"
SIP_GENERAL="/etc/asterisk/sip.conf"

# === Helper Functions ===
reload_asterisk() {
    asterisk -rx "core reload"
}

change_sip_port() {
    echo -e "${CYAN}Changing SIP bindport to 57889...${NC}"
    if grep -q '^bindport=' "$SIP_GENERAL"; then
        sed -i 's/^bindport=.*/bindport=57889/' "$SIP_GENERAL"
    else
        echo 'bindport=57889' >> "$SIP_GENERAL"
    fi
    mysql -u"$DBUSER" -p"$DBPASS" "$DBNAME" -e "UPDATE sip SET data='57889' WHERE keyword='port';"
    reload_asterisk
    echo -e "${GREEN}✔ SIP port changed and reloaded.${NC}"
}

change_ssh_port() {
    echo -e "${CYAN}Changing SSH Port to 2008...${NC}"
    if grep -q '^Port ' /etc/ssh/sshd_config; then
        sed -i 's/^Port .*/Port 2008/' /etc/ssh/sshd_config
    else
        echo 'Port 2008' >> /etc/ssh/sshd_config
    fi
    systemctl restart sshd
    echo -e "${GREEN}✔ SSH port changed and sshd restarted.${NC}"
}

add_ip_whitelist() {
    while true; do
        read -p "Enter IP to whitelist on all ports: " ip
        for port in $tcp_ports; do iptables -I INPUT -p tcp --dport $port -s "$ip" -j ACCEPT; done
        for port in $udp_ports; do iptables -I INPUT -p udp --dport $port -s "$ip" -j ACCEPT; done
        echo -e "${GREEN}✔ IP $ip allowed on all ports.${NC}"
        read -p "Add another IP? (y/n): " more
        [[ "$more" =~ ^[Nn]$ ]] && break
    done
    service iptables save
}

check_extension_exists() {
    local ext=$1
    mysql -u"$DBUSER" -p"$DBPASS" -D"$DBNAME" -e "SELECT extension FROM users WHERE extension='$ext';" | grep -q "$ext"
}

add_extensions() {
    read -p "Enter extension START range: " START
    read -p "Enter extension END range: " END
    read -sp "Enter password to use for all extensions: " PASSWORD
    echo
    read -p "Change SIP port from default 5060? (y/n): " change_port

    for EXT in $(seq $START $END); do
        if check_extension_exists "$EXT"; then
            echo -e "${YELLOW}Extension $EXT already exists.${NC}"
            read -p "Do you want to remove and recreate it? (y/n): " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] || continue
            mysql -u"$DBUSER" -p"$DBPASS" "$DBNAME" -e "DELETE FROM users WHERE extension='$EXT';"
            mysql -u"$DBUSER" -p"$DBPASS" "$DBNAME" -e "DELETE FROM devices WHERE id='$EXT';"
            mysql -u"$DBUSER" -p"$DBPASS" "$DBNAME" -e "DELETE FROM sip WHERE id='$EXT';"
        fi

        mysql -u"$DBUSER" -p"$DBPASS" "$DBNAME" <<EOF
INSERT INTO users (extension, password, name, voicemail, sipname)
VALUES ('$EXT', '$PASSWORD', 'User $EXT', 'novm', '$EXT');
EOF

        if [[ "$change_port" =~ ^[Yy]$ ]]; then
            mysql -u"$DBUSER" -p"$DBPASS" "$DBNAME" -e "UPDATE sip SET data='57889' WHERE id='$EXT' AND keyword='port';"
        fi

        echo -e "${GREEN}✔ Extension $EXT created.${NC}"
    done
    reload_asterisk
}

# === Menu for Trunk Management ===
trunk_menu() {
    while true; do
        echo -e "\\n${CYAN}--- Trunk Management ---${NC}"
        echo "1. Add Extensions"
        echo "2. Add SIP Trunks"
        echo "3. Delete SIP Trunks"
        echo "4. List Extensions"
        echo "5. List SIP Trunks"
        echo "6. List Outbound Routes"
        echo "7. Delete Outbound Routes"
        echo "8. Back to Main Menu"
        read -p "Choose option [1-8]: " opt
        case $opt in
            1) add_extensions ;;
            2) echo -e "${YELLOW}(Trunk creation logic placeholder)${NC}" ;;
            3) echo -e "${YELLOW}(Trunk deletion logic placeholder)${NC}" ;;
            4) mysql -u"$DBUSER" -p"$DBPASS" -D"$DBNAME" -e "SELECT extension,name FROM users;" ;;
            5) grep -Po '^\\[\\K[^\\]]+' "$SIP_CONF" | nl ;;
            6) mysql -u"$DBUSER" -p"$DBPASS" -D"$DBNAME" -e "SELECT * FROM outbound_routes;" ;;
            7) echo -e "${YELLOW}(Outbound route deletion placeholder)${NC}" ;;
            8) break ;;
            *) echo -e "${RED}Invalid choice.${NC}" ;;
        esac
    done
}

# === Menu for Firewall ===
firewall_menu() {
    while true; do
        echo -e "\\n${CYAN}--- Firewall Management ---${NC}"
        echo "1. Add IP (Whitelist)"
        echo "2. Change SSH Port to 2008"
        echo "3. Change SIP Port to 57889"
        echo "4. Back to Main Menu"
        read -p "Choose option [1-4]: " opt
        case $opt in
            1) add_ip_whitelist ;;
            2) change_ssh_port ;;
            3) change_sip_port ;;
            4) break ;;
            *) echo -e "${RED}Invalid choice.${NC}" ;;
        esac
    done
}

# === Main Menu ===
while true; do
    echo -e "\\n${CYAN}========= Issabel Automation Main Menu =========${NC}"
    echo "1. Trunk Management"
    echo "2. Firewall Rules"
    echo "3. Exit"
    read -p "Select option [1-3]: " main
    case $main in
        1) trunk_menu ;;
        2) firewall_menu ;;
        3) echo "Goodbye."; exit 0 ;;
        *) echo -e "${RED}Invalid option. Try again.${NC}" ;;
    esac
done