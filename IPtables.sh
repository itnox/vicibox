#!/bin/bash

# Default allowed rules
DEFAULT_RULES=(
    "185.188.124.88 5060 udp SIP_Server"
    "10.0.0.0/8 5060,10000:20000 udp Local_Network"
    "192.168.0.0/16 5060,10000:20000 udp Local_Network"
    "172.16.0.0/12 5060,10000:20000 udp Local_Network"
)

RULES_FILE="/etc/iptables/rules.v4"

# Ensure iptables is installed
if ! command -v iptables >/dev/null 2>&1; then
    echo "iptables is not installed. Please install it first."
    exit 1
fi

check_iptables_service() {
    echo "Checking iptables service status..."

    if systemctl list-units --full -all | grep 'iptables.service'; then
        echo "iptables service found."

        if ! systemctl is-active --quiet iptables; then
            echo "iptables service is not active. Starting it now..."
            systemctl start iptables && echo "iptables started."
        fi

        if ! systemctl is-enabled --quiet iptables; then
            echo "Enabling iptables service on boot..."
            systemctl enable iptables && echo "iptables enabled."
        fi
    else
        echo "iptables service not installed. Installing iptables-services..."
        yum install -y iptables-services
        systemctl start iptables
        systemctl enable iptables
    fi
}

check_iptables_service

# Backup current iptables
backup_iptables() {
    iptables-save > /etc/iptables/rules.backup.$(date +%F_%T)
    echo "Backup created."
}

# Flush and apply default DROP policy
initialize_iptables() {
    iptables -F
    iptables -X
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT
}

# Add default allow rules
apply_default_rules() {
    for rule in "${DEFAULT_RULES[@]}"; do
        ip=$(echo $rule | awk '{print $1}')
        ports=$(echo $rule | awk '{print $2}')
        proto=$(echo $rule | awk '{print $3}')
        desc=$(echo $rule | awk '{print $4}')
        
        IFS=',' read -ra port_list <<< "$ports"
        for port in "${port_list[@]}"; do
            iptables -A INPUT -p $proto -s $ip --dport $port -j ACCEPT
        done
    done
}

# List current allowed rules
list_rules() {
    echo "Current iptables rules:"
    iptables -S | grep ACCEPT
}

# Add a custom rule
add_rule() {
    read -p "Enter IP address to allow: " ip
    read -p "Enter ports (comma-separated, e.g. 5060,10000:20000,443): " ports
    read -p "Enter protocol (tcp/udp): " proto
    read -p "Enter description: " desc

    # Split ports by comma
    IFS=',' read -ra port_list <<< "$ports"

    for port in "${port_list[@]}"; do
        # Trim possible whitespace
        port=$(echo "$port" | xargs)
        iptables -A INPUT -p "$proto" -s "$ip" --dport "$port" -j ACCEPT
        echo "Rule added: $ip $port $proto $desc"
    done
}

# Delete rule
delete_rule() {
    echo "Listing all ACCEPT rules with line numbers..."
    mapfile -t rules < <(iptables -S INPUT | grep " -j ACCEPT")
    
    if [ ${#rules[@]} -eq 0 ]; then
        echo "No ACCEPT rules found to delete."
        return
    fi

    for i in "${!rules[@]}"; do
        echo "$((i+1)). ${rules[$i]}"
    done

    read -p "Enter the rule number to delete: " rule_num
    index=$((rule_num-1))

    if [ "$index" -ge 0 ] && [ "$index" -lt "${#rules[@]}" ]; then
        rule="${rules[$index]}"
        # Remove '-A' and replace with '-D'
        delete_rule=$(echo "$rule" | sed 's/^-A /-D /')
        iptables $delete_rule && echo "Rule deleted successfully." || echo "Failed to delete rule."
    else
        echo "Invalid rule number."
    fi
}


# Test if IP:PORT is allowed (local test)
test_access() {
    read -p "Enter IP to test: " ip
    read -p "Enter port: " port
    nc -zv -w 3 $ip $port && echo "Access successful" || echo "Access denied or timed out"
}

# Save iptables rules
save_rules() {
    iptables-save > /etc/sysconfig/iptables
    echo "Rules saved to /etc/sysconfig/iptables"
}

# Menu
while true; do
    echo ""
    echo "===== IPTABLES MANAGER ====="
    echo "1. Initialize and apply default rules"
    echo "2. Add IP rule"
    echo "3. Delete IP rule"
    echo "4. List rules"
    echo "5. Test access"
    echo "6. Save and apply rules"
    echo "7. Exit"
    echo "============================"
    read -p "Choose an option [1-7]: " opt

    case $opt in
        1)
            backup_iptables
            initialize_iptables
            apply_default_rules
            echo "Defaults applied and other traffic blocked."
            ;;
        2)
            add_rule
            ;;
        3)
            delete_rule
            ;;
        4)
            list_rules
            ;;
        5)
            test_access
            ;;
        6)
            save_rules
            echo "Changes saved and applied."
            ;;
        7)
            echo "Exiting."
            exit 0
            ;;
        *)
            echo "Invalid option."
            ;;
    esac

    read -p "Do you want to perform another action? (y/n): " again
    [[ "$again" != "y" ]] && break
done
