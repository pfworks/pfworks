#!/bin/bash
# DHCP Testing Script for Bridge/VLAN Traffic
# Usage: ./bridge-dhcp-test.sh [-t|--tui] <MAC_ADDRESS> <BRIDGE_NAME>

# ── Parse flags ──────────────────────────────────────────────────────
TUI_MODE=0
while [[ "${1:-}" == -* ]]; do
    case "$1" in
        -t|--tui) TUI_MODE=1; shift ;;
        -h|--help)
            echo "Usage: $0 [-t|--tui] <MAC_ADDRESS> <BRIDGE_NAME>"
            echo "  -t, --tui    Run in TUI mode with split-screen display"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Root check ───────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

if [ $# -ne 2 ]; then
    echo "Usage: $0 [-t|--tui] <MAC_ADDRESS> <BRIDGE_NAME>"
    echo "Example: $0 00:18:3e:42:0c:1e br314"
    echo "Example: $0 -t 00:18:3e:42:0c:1e br314"
    exit 1
fi

MAC_ADDRESS="$1"
BRIDGE_NAME="$2"

if ! [[ $MAC_ADDRESS =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; then
    echo "Invalid MAC address format. Use format: 00:18:3e:42:0c:1e"
    exit 1
fi

# ── Unique names ─────────────────────────────────────────────────────
RANDOM_ID=$(shuf -i 1000-9999 -n 1)
VETH_HOST="vhost$RANDOM_ID"
VETH_GUEST="vguest$RANDOM_ID"
NAMESPACE="dhcpns$RANDOM_ID"
LEASE_FILE="/var/lib/dhcp/dhclient.leases"

# ── Colors ───────────────────────────────────────────────────────────
C_RED=$'\e[31m'
C_GREEN=$'\e[32m'
C_YELLOW=$'\e[33m'
C_BLUE=$'\e[34m'
C_BOLD=$'\e[1m'
C_NC=$'\e[0m'

# ══════════════════════════════════════════════════════════════════════
# CLI MODE
# ══════════════════════════════════════════════════════════════════════
if (( ! TUI_MODE )); then

print_header() { echo -e "\n${C_BLUE}=== $1 ===${C_NC}"; }
print_success() { echo -e "${C_GREEN}✅ $1${C_NC}"; }
print_error()   { echo -e "${C_RED}❌ $1${C_NC}"; }
print_warning() { echo -e "${C_YELLOW}⚠️  $1${C_NC}"; }
print_info()    { echo -e "${C_BLUE}ℹ️  $1${C_NC}"; }

cleanup() {
    print_header "Cleaning Up"
    pkill -f "dhclient.*$VETH_GUEST" 2>/dev/null
    if ip netns list | grep -q "$NAMESPACE"; then
        ip netns exec $NAMESPACE dhclient -r $VETH_GUEST 2>/dev/null
        ip netns del $NAMESPACE 2>/dev/null
        print_info "Removed network namespace: $NAMESPACE"
    fi
    if ip link show $VETH_HOST &>/dev/null; then
        ip link del $VETH_HOST 2>/dev/null
        print_info "Removed VETH pair: $VETH_HOST"
    fi
    print_success "Cleanup completed"
}
trap cleanup EXIT

print_header "DHCP Test for Tagged VLAN Traffic"
print_info "MAC Address: $MAC_ADDRESS"
print_info "Bridge: $BRIDGE_NAME"
print_info "VETH Pair: $VETH_HOST <-> $VETH_GUEST"
print_info "Namespace: $NAMESPACE"
print_info "Date: $(date)"
echo

# Check bridge
print_header "Checking Bridge Configuration"
if ! ip link show $BRIDGE_NAME &>/dev/null; then
    print_error "Bridge $BRIDGE_NAME does not exist"
    print_info "Available bridges:"
    brctl show | grep -v "^bridge name" | awk '{print $1}' | grep -v "^$"
    exit 1
fi
print_success "Bridge $BRIDGE_NAME exists"

BRIDGE_STATE=$(ip link show $BRIDGE_NAME | grep -o "state [A-Z]*" | cut -d' ' -f2)
if [ "$BRIDGE_STATE" != "UP" ]; then
    print_error "Bridge $BRIDGE_NAME is not UP (state: $BRIDGE_STATE)"
    exit 1
fi
print_success "Bridge $BRIDGE_NAME is UP"

print_info "Bridge members:"
brctl show $BRIDGE_NAME | tail -n +2 | while read line; do
    if [ -n "$line" ]; then
        interface=$(echo $line | awk '{print $NF}')
        [ -n "$interface" ] && [ "$interface" != "$BRIDGE_NAME" ] && print_info "  - $interface"
    fi
done

# Create namespace & veth
print_header "Network Namespace DHCP Test"
print_info "Creating network namespace: $NAMESPACE"
if ! ip netns add $NAMESPACE; then
    print_error "Failed to create network namespace"
    exit 1
fi

print_info "Creating VETH pair: $VETH_HOST <-> $VETH_GUEST"
if ! ip link add $VETH_HOST type veth peer name $VETH_GUEST; then
    print_error "Failed to create VETH pair"
    exit 1
fi
print_success "VETH pair created successfully"

ip link set $VETH_HOST up
ip link set $VETH_HOST master $BRIDGE_NAME
ip link set $VETH_GUEST netns $NAMESPACE
ip netns exec $NAMESPACE ip link set dev $VETH_GUEST address $MAC_ADDRESS
ip netns exec $NAMESPACE ip link set $VETH_GUEST up
ip netns exec $NAMESPACE ip link set lo up

GUEST_STATE=$(ip netns exec $NAMESPACE ip link show $VETH_GUEST | grep -o "state [A-Z]*" | cut -d' ' -f2)
print_info "Guest interface state: $GUEST_STATE"

if ip netns exec $NAMESPACE ip link show $VETH_GUEST | grep -q "LOWER_UP"; then
    print_success "Guest interface has carrier"
else
    print_warning "Guest interface has no carrier"
fi

# DHCP
print_info "Attempting DHCP request in namespace (timeout: 30 seconds)"
echo "DHCP client output:"
echo "===================="
timeout 30 ip netns exec $NAMESPACE dhclient -v -1 $VETH_GUEST 2>&1

echo
print_header "Results Analysis"

IP_ASSIGNED=$(ip netns exec $NAMESPACE ip addr show $VETH_GUEST | grep "inet " | awk '{print $2}' | cut -d'/' -f1)

if [ -n "$IP_ASSIGNED" ]; then
    print_success "DHCP SUCCESS: IP address assigned"
    print_info "Assigned IP: $IP_ASSIGNED"

    GATEWAY=$(ip netns exec $NAMESPACE ip route | grep default | awk '{print $3}')
    [ -n "$GATEWAY" ] && print_info "Gateway: $GATEWAY"

    LEASE_BLOCK=$(awk "/interface \"$VETH_GUEST\"/{found=1} found{buf=buf\"\n\"\$0} /^}/{if(found){last=buf; buf=\"\"; found=0}} END{print last}" "$LEASE_FILE" 2>/dev/null)
    DNS_SERVERS=$(echo "$LEASE_BLOCK" | grep "option domain-name-servers" | sed 's/.*domain-name-servers //;s/[;,]/ /g' | xargs)
    DOMAIN=$(echo "$LEASE_BLOCK" | grep "option domain-name " | sed 's/.*domain-name "//;s/".*//')
    NTP_SERVERS=$(echo "$LEASE_BLOCK" | grep "option ntp-servers" | sed 's/.*ntp-servers //;s/[;,]/ /g' | xargs)

    [ -n "$DNS_SERVERS" ] && print_info "DNS Servers (from DHCP): $DNS_SERVERS"
    [ -n "$DOMAIN" ]      && print_info "Domain (from DHCP): $DOMAIN"
    [ -n "$NTP_SERVERS" ] && print_info "NTP Servers (from DHCP): $NTP_SERVERS"

    print_info "Testing connectivity..."
    if [ -n "$GATEWAY" ] && ip netns exec $NAMESPACE ping -c 3 -W 2 $GATEWAY &>/dev/null; then
        print_success "Gateway connectivity: OK"
    else
        print_warning "Gateway connectivity: FAILED"
    fi

    if ip netns exec $NAMESPACE ping -c 3 -W 2 8.8.8.8 &>/dev/null; then
        print_success "Internet connectivity: OK"
    else
        print_warning "Internet connectivity: FAILED"
    fi

    FIRST_NS=$(echo "$DNS_SERVERS" | awk '{print $1}')
    if [ -n "$FIRST_NS" ] && ip netns exec $NAMESPACE nslookup google.com "$FIRST_NS" &>/dev/null; then
        print_success "DNS resolution (via DHCP nameserver $FIRST_NS): OK"
    elif [ -n "$FIRST_NS" ]; then
        print_warning "DNS resolution (via DHCP nameserver $FIRST_NS): FAILED"
    else
        print_warning "DNS resolution: No nameservers provided by DHCP"
    fi
else
    print_error "DHCP FAILED: No IP address assigned"
    INTERFACE_STATE=$(ip netns exec $NAMESPACE ip link show $VETH_GUEST | grep -o "state [A-Z]*" | cut -d' ' -f2)
    print_info "Interface state: $INTERFACE_STATE"
    if ip netns exec $NAMESPACE ip link show $VETH_GUEST | grep -q "LOWER_UP"; then
        print_info "Interface has carrier: YES"
    else
        print_warning "Interface has carrier: NO"
    fi
    print_info "Interface details:"
    ip netns exec $NAMESPACE ip addr show $VETH_GUEST | sed 's/^/    /'
fi

print_header "Test Summary"
print_info "Bridge: $BRIDGE_NAME"
print_info "MAC Address: $MAC_ADDRESS"

if [ -n "$IP_ASSIGNED" ]; then
    print_success "DHCP TEST PASSED"
    print_info "Assigned IP: $IP_ASSIGNED"
    [ -n "$GATEWAY" ] && print_info "Gateway: $GATEWAY"
else
    print_error "DHCP TEST FAILED"
    echo
    print_info "Possible issues:"
    print_info "- DHCP server not reachable through this bridge"
    print_info "- MAC address not recognized by DHCP server"
    print_info "- VLAN configuration issues"
    print_info "- Network connectivity problems"
fi

print_header "Test Completed"
print_info "All temporary interfaces and namespaces cleaned up"

[ -n "$IP_ASSIGNED" ] && exit 0 || exit 1

fi

# ══════════════════════════════════════════════════════════════════════
# TUI MODE
# ══════════════════════════════════════════════════════════════════════

TOP_LINES=()
BOT_LINES=()
TERM_LINES=$(tput lines)
TERM_COLS=$(tput cols)
DIVIDER_ROW=$(( TERM_LINES / 2 ))
BLANK_LINE=$(printf '%*s' "$TERM_COLS" '')
TOP_SCROLL=0
TOP_FOLLOW=1

move_to() { printf '\033[%d;%dH' "$1" "$2"; }
clear_line() { printf '\e[0m\r%s\r' "$BLANK_LINE"; }

draw_divider() {
    move_to "$DIVIDER_ROW" 1
    clear_line
    local label=" Results "
    local label_len=${#label}
    local left=2
    local right=$(( TERM_COLS - left - label_len ))
    printf '\033[0m'
    printf '%.0s─' $(seq 1 "$left")
    printf "${C_BOLD}${C_BLUE}%s${C_NC}" "$label"
    printf '%.0s─' $(seq 1 "$right")
    printf "${C_NC}"
}

draw_top() {
    local max_lines=$(( DIVIDER_ROW - 2 ))
    local total=${#TOP_LINES[@]}
    local start

    if (( TOP_FOLLOW )); then
        start=$(( total - max_lines ))
        (( start < 0 )) && start=0
        TOP_SCROLL=$start
    else
        start=$TOP_SCROLL
    fi

    local scroll_info=""
    if (( total > max_lines )); then
        local end=$(( start + max_lines ))
        (( end > total )) && end=$total
        scroll_info=" [${start}-${end}/${total} ↑↓/j/k q]"
    fi
    move_to 1 1
    clear_line
    printf '\033[0m'
    printf "${C_BOLD}${C_BLUE} DHCP Transaction${C_NC}  │ MAC: %s  Bridge: %s%s" "$MAC_ADDRESS" "$BRIDGE_NAME" "$scroll_info"

    for (( i=0; i<max_lines; i++ )); do
        local idx=$(( start + i ))
        move_to $(( i + 2 )) 1
        printf '\033[0m'
        clear_line
        if (( idx >= 0 && idx < total )); then
            printf '\033[0m%s\033[0m' "${TOP_LINES[$idx]}"
        fi
    done
}

draw_bottom() {
    local max_lines=$(( TERM_LINES - DIVIDER_ROW - 1 ))
    local total=${#BOT_LINES[@]}
    local start=0
    if (( total > max_lines )); then
        start=$(( total - max_lines ))
    fi
    for (( i=0; i<max_lines; i++ )); do
        local idx=$(( start + i ))
        move_to $(( DIVIDER_ROW + 1 + i )) 1
        printf '\033[0m'
        clear_line
        if (( idx < total )); then
            printf '\033[0m%s\033[0m' "${BOT_LINES[$idx]}"
        fi
    done
}

refresh() {
    draw_divider
    draw_top
    draw_bottom
}

scroll_top_up() {
    TOP_FOLLOW=0
    (( TOP_SCROLL > 0 )) && (( TOP_SCROLL-- ))
    refresh
}

scroll_top_down() {
    local max_lines=$(( DIVIDER_ROW - 2 ))
    local total=${#TOP_LINES[@]}
    local max_scroll=$(( total - max_lines ))
    (( max_scroll < 0 )) && max_scroll=0
    TOP_FOLLOW=0
    (( TOP_SCROLL < max_scroll )) && (( TOP_SCROLL++ ))
    (( TOP_SCROLL >= max_scroll )) && TOP_FOLLOW=1
    refresh
}

log_top() { TOP_LINES+=("$1"); TOP_FOLLOW=1; refresh; }
log_bot() { BOT_LINES+=("$1"); refresh; }

cleanup() {
    pkill -f "dhclient.*$VETH_GUEST" 2>/dev/null
    if ip netns list 2>/dev/null | grep -q "$NAMESPACE"; then
        ip netns exec "$NAMESPACE" dhclient -r "$VETH_GUEST" 2>/dev/null
        ip netns del "$NAMESPACE" 2>/dev/null
    fi
    if ip link show "$VETH_HOST" &>/dev/null; then
        ip link del "$VETH_HOST" 2>/dev/null
    fi
    tput cnorm 2>/dev/null
    stty echo 2>/dev/null
}
trap cleanup EXIT

# Init TUI
tput civis
for (( i=1; i<=TERM_LINES; i++ )); do
    move_to "$i" 1
    printf '%s' "$BLANK_LINE"
done
move_to 1 1
refresh

# Check bridge
log_top "${C_BLUE}Checking bridge ${BRIDGE_NAME}...${C_NC}"

if ! ip link show "$BRIDGE_NAME" &>/dev/null; then
    log_top "${C_RED}✗ Bridge $BRIDGE_NAME does not exist${C_NC}"
    log_bot "${C_RED}✗ ABORTED — bridge not found${C_NC}"
    read -rsn1 -p ""
    exit 1
fi

BRIDGE_STATE=$(ip link show "$BRIDGE_NAME" | grep -o "state [A-Z]*" | cut -d' ' -f2)
if [ "$BRIDGE_STATE" != "UP" ]; then
    log_top "${C_RED}✗ Bridge $BRIDGE_NAME is $BRIDGE_STATE${C_NC}"
    log_bot "${C_RED}✗ ABORTED — bridge not UP${C_NC}"
    read -rsn1 -p ""
    exit 1
fi

log_top "${C_GREEN}✓ Bridge $BRIDGE_NAME is UP${C_NC}"

while IFS= read -r member; do
    [ -n "$member" ] && [ "$member" != "$BRIDGE_NAME" ] && \
        log_top "  member: $member"
done < <(brctl show "$BRIDGE_NAME" 2>/dev/null | tail -n +2 | awk '{print $NF}')

# Create namespace & veth
log_top "${C_BLUE}Creating namespace $NAMESPACE${C_NC}"
if ! ip netns add "$NAMESPACE"; then
    log_top "${C_RED}✗ Failed to create namespace${C_NC}"
    log_bot "${C_RED}✗ ABORTED${C_NC}"
    read -rsn1 -p ""
    exit 1
fi

log_top "${C_BLUE}Creating veth pair $VETH_HOST ↔ $VETH_GUEST${C_NC}"
if ! ip link add "$VETH_HOST" type veth peer name "$VETH_GUEST"; then
    log_top "${C_RED}✗ Failed to create veth pair${C_NC}"
    log_bot "${C_RED}✗ ABORTED${C_NC}"
    read -rsn1 -p ""
    exit 1
fi

ip link set "$VETH_HOST" up
ip link set "$VETH_HOST" master "$BRIDGE_NAME"
ip link set "$VETH_GUEST" netns "$NAMESPACE"
ip netns exec "$NAMESPACE" ip link set dev "$VETH_GUEST" address "$MAC_ADDRESS"
ip netns exec "$NAMESPACE" ip link set "$VETH_GUEST" up
ip netns exec "$NAMESPACE" ip link set lo up

log_top "${C_GREEN}✓ Network setup complete${C_NC}"

if ip netns exec "$NAMESPACE" ip link show "$VETH_GUEST" | grep -q "LOWER_UP"; then
    log_top "${C_GREEN}✓ Carrier detected${C_NC}"
else
    log_top "${C_YELLOW}⚠ No carrier on $VETH_GUEST${C_NC}"
fi

# DHCP transaction
log_top ""
log_top "${C_BOLD}Starting DHCP (timeout 30s)...${C_NC}"

while IFS= read -r line; do
    log_top "  ${line}"
done < <(timeout 30 ip netns exec "$NAMESPACE" dhclient -v -1 "$VETH_GUEST" 2>&1)

# Gather results
IP_ASSIGNED=$(ip netns exec "$NAMESPACE" ip addr show "$VETH_GUEST" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)

if [ -n "$IP_ASSIGNED" ]; then
    EXIT_CODE=0
    log_top ""
    log_top "${C_GREEN}✓ DHCPACK — bound to $IP_ASSIGNED${C_NC}"

    GATEWAY=$(ip netns exec "$NAMESPACE" ip route 2>/dev/null | grep default | awk '{print $3}')

    LEASE_BLOCK=$(awk "/interface \"$VETH_GUEST\"/{found=1} found{buf=buf\"\n\"\$0} /^}/{if(found){last=buf; buf=\"\"; found=0}} END{print last}" "$LEASE_FILE" 2>/dev/null)
    DNS_SERVERS=$(echo "$LEASE_BLOCK" | grep "option domain-name-servers" | sed 's/.*domain-name-servers //;s/[;,]/ /g' | xargs)
    DOMAIN=$(echo "$LEASE_BLOCK" | grep "option domain-name " | sed 's/.*domain-name "//;s/".*//')
    NTP_SERVERS=$(echo "$LEASE_BLOCK" | grep "option ntp-servers" | sed 's/.*ntp-servers //;s/[;,]/ /g' | xargs)

    log_bot "${C_GREEN}${C_BOLD}✓ DHCP TEST PASSED${C_NC}"
    log_bot ""
    log_bot "  ${C_BOLD}IP Address:${C_NC}   $IP_ASSIGNED"
    [ -n "$GATEWAY" ]     && log_bot "  ${C_BOLD}Gateway:${C_NC}      $GATEWAY"
    [ -n "$DNS_SERVERS" ] && log_bot "  ${C_BOLD}DNS Servers:${C_NC}  $DNS_SERVERS"
    [ -n "$DOMAIN" ]      && log_bot "  ${C_BOLD}Domain:${C_NC}       $DOMAIN"
    [ -n "$NTP_SERVERS" ] && log_bot "  ${C_BOLD}NTP Servers:${C_NC}  $NTP_SERVERS"
    log_bot ""

    log_top ""
    log_top "${C_BLUE}Testing connectivity...${C_NC}"

    if [ -n "$GATEWAY" ] && ip netns exec "$NAMESPACE" ping -c 2 -W 2 "$GATEWAY" &>/dev/null; then
        log_top "  ${C_GREEN}✓ Gateway ping OK${C_NC}"
        log_bot "  ${C_GREEN}✓${C_NC} Gateway ping    ${C_GREEN}OK${C_NC}"
    else
        log_top "  ${C_YELLOW}⚠ Gateway ping failed${C_NC}"
        log_bot "  ${C_YELLOW}⚠${C_NC} Gateway ping    ${C_YELLOW}FAIL${C_NC}"
    fi

    if ip netns exec "$NAMESPACE" ping -c 2 -W 2 8.8.8.8 &>/dev/null; then
        log_top "  ${C_GREEN}✓ Internet ping OK${C_NC}"
        log_bot "  ${C_GREEN}✓${C_NC} Internet ping   ${C_GREEN}OK${C_NC}"
    else
        log_top "  ${C_YELLOW}⚠ Internet ping failed${C_NC}"
        log_bot "  ${C_YELLOW}⚠${C_NC} Internet ping   ${C_YELLOW}FAIL${C_NC}"
    fi

    FIRST_NS=$(echo "$DNS_SERVERS" | awk '{print $1}')
    if [ -n "$FIRST_NS" ] && ip netns exec "$NAMESPACE" nslookup google.com "$FIRST_NS" &>/dev/null; then
        log_top "  ${C_GREEN}✓ DNS resolution OK (via $FIRST_NS)${C_NC}"
        log_bot "  ${C_GREEN}✓${C_NC} DNS resolution  ${C_GREEN}OK${C_NC} (via $FIRST_NS)"
    elif [ -n "$FIRST_NS" ]; then
        log_top "  ${C_YELLOW}⚠ DNS resolution failed (via $FIRST_NS)${C_NC}"
        log_bot "  ${C_YELLOW}⚠${C_NC} DNS resolution  ${C_YELLOW}FAIL${C_NC} (via $FIRST_NS)"
    else
        log_bot "  ${C_YELLOW}⚠${C_NC} DNS resolution  ${C_YELLOW}N/A${C_NC} (no nameservers from DHCP)"
    fi
else
    EXIT_CODE=1
    log_top ""
    log_top "${C_RED}✗ No IP assigned${C_NC}"

    log_bot "${C_RED}${C_BOLD}✗ DHCP TEST FAILED${C_NC}"
    log_bot ""
    log_bot "  No IP address was assigned via DHCP."
    log_bot ""
    log_bot "  Possible causes:"
    log_bot "  - DHCP server not reachable through this bridge"
    log_bot "  - MAC address not recognized by DHCP server"
    log_bot "  - VLAN configuration issues"
    log_bot "  - Network connectivity problems"

    IFACE_STATE=$(ip netns exec "$NAMESPACE" ip link show "$VETH_GUEST" 2>/dev/null | grep -o "state [A-Z]*" | cut -d' ' -f2)
    HAS_CARRIER="NO"
    ip netns exec "$NAMESPACE" ip link show "$VETH_GUEST" 2>/dev/null | grep -q "LOWER_UP" && HAS_CARRIER="YES"
    log_bot ""
    log_bot "  Interface state: $IFACE_STATE  Carrier: $HAS_CARRIER"
fi

# Interactive scroll loop
log_top ""
refresh

while true; do
    read -rsn1 key
    case "$key" in
        q|Q) break ;;
        k)   scroll_top_up ;;
        j)   scroll_top_down ;;
        $'\x1b')
            read -rsn2 -t 0.1 rest
            case "$rest" in
                '[A') scroll_top_up ;;
                '[B') scroll_top_down ;;
            esac
            ;;
    esac
done

exit $EXIT_CODE
