#!/bin/bash
# DHCP Testing Script for Tagged VLAN Traffic (Simplified)
# Usage: ./test-dhcp-simple.sh <MAC_ADDRESS> <BRIDGE_NAME>

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

print_header() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

print_success() {
    print_status $GREEN "✅ $1"
}

print_error() {
    print_status $RED "❌ $1"
}

print_warning() {
    print_status $YELLOW "⚠️  $1"
}

print_info() {
    print_status $BLUE "ℹ️  $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root"
   exit 1
fi

# Check arguments
if [ $# -ne 2 ]; then
    echo "Usage: $0 <MAC_ADDRESS> <BRIDGE_NAME>"
    echo "Example: $0 00:18:3e:42:0c:1e br314"
    exit 1
fi

MAC_ADDRESS="$1"
BRIDGE_NAME="$2"

# Generate short unique names (max 15 chars for Linux interfaces)
RANDOM_ID=$(shuf -i 1000-9999 -n 1)
VETH_HOST="vhost$RANDOM_ID"
VETH_GUEST="vguest$RANDOM_ID"
NAMESPACE="dhcpns$RANDOM_ID"

# Validate MAC address format
if ! [[ $MAC_ADDRESS =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; then
    print_error "Invalid MAC address format. Use format: 00:18:3e:42:0c:1e"
    exit 1
fi

# Cleanup function
cleanup() {
    print_header "Cleaning Up"
    
    # Stop any running dhclient processes
    pkill -f "dhclient.*$VETH_GUEST" 2>/dev/null
    
    # Clean up network namespace
    if ip netns list | grep -q "$NAMESPACE"; then
        ip netns exec $NAMESPACE dhclient -r $VETH_GUEST 2>/dev/null
        ip netns del $NAMESPACE 2>/dev/null
        print_info "Removed network namespace: $NAMESPACE"
    fi
    
    # Clean up VETH pair
    if ip link show $VETH_HOST &>/dev/null; then
        ip link del $VETH_HOST 2>/dev/null
        print_info "Removed VETH pair: $VETH_HOST"
    fi
    
    # Clean up temp files
    # (no temp files to clean in current approach)
    
    print_success "Cleanup completed"
}

# Set trap for cleanup on exit
trap cleanup EXIT

print_header "DHCP Test for Tagged VLAN Traffic"
print_info "MAC Address: $MAC_ADDRESS"
print_info "Bridge: $BRIDGE_NAME"
print_info "VETH Pair: $VETH_HOST <-> $VETH_GUEST"
print_info "Namespace: $NAMESPACE"
print_info "Date: $(date)"
echo

# Check if bridge exists
print_header "Checking Bridge Configuration"
if ! ip link show $BRIDGE_NAME &>/dev/null; then
    print_error "Bridge $BRIDGE_NAME does not exist"
    print_info "Available bridges:"
    brctl show | grep -v "^bridge name" | awk '{print $1}' | grep -v "^$"
    exit 1
fi

print_success "Bridge $BRIDGE_NAME exists"

# Check bridge status
BRIDGE_STATE=$(ip link show $BRIDGE_NAME | grep -o "state [A-Z]*" | cut -d' ' -f2)
if [ "$BRIDGE_STATE" != "UP" ]; then
    print_error "Bridge $BRIDGE_NAME is not UP (state: $BRIDGE_STATE)"
    exit 1
fi

print_success "Bridge $BRIDGE_NAME is UP"

# Show bridge configuration
print_info "Bridge members:"
brctl show $BRIDGE_NAME | tail -n +2 | while read line; do
    if [ -n "$line" ]; then
        interface=$(echo $line | awk '{print $NF}')
        if [ -n "$interface" ] && [ "$interface" != "$BRIDGE_NAME" ]; then
            print_info "  - $interface"
        fi
    fi
done

# Network Namespace DHCP Test
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

print_info "Configuring host side interface"
ip link set $VETH_HOST up
ip link set $VETH_HOST master $BRIDGE_NAME

print_info "Moving guest interface to namespace"
ip link set $VETH_GUEST netns $NAMESPACE

print_info "Configuring guest interface in namespace"
ip netns exec $NAMESPACE ip link set dev $VETH_GUEST address $MAC_ADDRESS
ip netns exec $NAMESPACE ip link set $VETH_GUEST up
ip netns exec $NAMESPACE ip link set lo up

# Verify interface configuration
GUEST_STATE=$(ip netns exec $NAMESPACE ip link show $VETH_GUEST | grep -o "state [A-Z]*" | cut -d' ' -f2)
print_info "Guest interface state: $GUEST_STATE"

if ip netns exec $NAMESPACE ip link show $VETH_GUEST | grep -q "LOWER_UP"; then
    print_success "Guest interface has carrier"
else
    print_warning "Guest interface has no carrier"
fi

# Default lease file location
LEASE_FILE="/var/lib/dhcp/dhclient.leases"

print_info "Attempting DHCP request in namespace (timeout: 30 seconds)"
echo "DHCP client output:"
echo "===================="

# Try DHCP with timeout
if timeout 30 ip netns exec $NAMESPACE dhclient -v -1 $VETH_GUEST 2>&1; then
    DHCP_SUCCESS=true
else
    DHCP_SUCCESS=false
fi

echo
print_header "Results Analysis"

# Check if IP was assigned
IP_ASSIGNED=$(ip netns exec $NAMESPACE ip addr show $VETH_GUEST | grep "inet " | awk '{print $2}' | cut -d'/' -f1)

if [ -n "$IP_ASSIGNED" ]; then
    print_success "DHCP SUCCESS: IP address assigned"
    print_info "Assigned IP: $IP_ASSIGNED"
    
    # Get additional network information
    GATEWAY=$(ip netns exec $NAMESPACE ip route | grep default | awk '{print $3}')
    if [ -n "$GATEWAY" ]; then
        print_info "Gateway: $GATEWAY"
    fi
    
    # Extract the last lease block for our interface from the host lease file
    LEASE_BLOCK=$(awk "/interface \"$VETH_GUEST\"/{found=1} found{buf=buf\"\n\"\$0} /^}/{if(found){last=buf; buf=\"\"; found=0}} END{print last}" "$LEASE_FILE" 2>/dev/null)

    # Check DNS from DHCP lease
    DNS_SERVERS=$(echo "$LEASE_BLOCK" | grep "option domain-name-servers" | sed 's/.*domain-name-servers //;s/[;,]/ /g' | xargs)
    if [ -n "$DNS_SERVERS" ]; then
        print_info "DNS Servers (from DHCP): $DNS_SERVERS"
    fi
    
    # Check domain from DHCP lease
    DOMAIN=$(echo "$LEASE_BLOCK" | grep "option domain-name " | sed 's/.*domain-name "//;s/".*//')
    if [ -n "$DOMAIN" ]; then
        print_info "Domain (from DHCP): $DOMAIN"
    fi

    # Check NTP from DHCP lease
    NTP_SERVERS=$(echo "$LEASE_BLOCK" | grep "option ntp-servers" | sed 's/.*ntp-servers //;s/[;,]/ /g' | xargs)
    if [ -n "$NTP_SERVERS" ]; then
        print_info "NTP Servers (from DHCP): $NTP_SERVERS"
    fi
    
    # Test connectivity
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
    
    # Test DNS resolution using DHCP-provided nameservers
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
    
    # Check interface status
    INTERFACE_STATE=$(ip netns exec $NAMESPACE ip link show $VETH_GUEST | grep -o "state [A-Z]*" | cut -d' ' -f2)
    print_info "Interface state: $INTERFACE_STATE"
    
    # Check for carrier
    if ip netns exec $NAMESPACE ip link show $VETH_GUEST | grep -q "LOWER_UP"; then
        print_info "Interface has carrier: YES"
    else
        print_warning "Interface has carrier: NO"
    fi
    
    # Show interface details for debugging
    print_info "Interface details:"
    ip netns exec $NAMESPACE ip addr show $VETH_GUEST | sed 's/^/    /'
fi

# Summary
print_header "Test Summary"
print_info "Bridge: $BRIDGE_NAME"
print_info "MAC Address: $MAC_ADDRESS"
print_info "Test Method: Network Namespace with VETH pair"

if [ -n "$IP_ASSIGNED" ]; then
    print_success "DHCP TEST PASSED"
    print_info "The bridge $BRIDGE_NAME supports DHCP for MAC $MAC_ADDRESS"
    print_info "Assigned IP: $IP_ASSIGNED"
    if [ -n "$GATEWAY" ]; then
        print_info "Gateway: $GATEWAY"
    fi
else
    print_error "DHCP TEST FAILED"
    print_info "The bridge $BRIDGE_NAME does not provide DHCP for MAC $MAC_ADDRESS"
    echo
    print_info "Possible issues:"
    print_info "- DHCP server not reachable through this bridge"
    print_info "- MAC address not recognized by DHCP server"
    print_info "- VLAN configuration issues"
    print_info "- Network connectivity problems"
fi

print_header "Test Completed"
print_info "All temporary interfaces and namespaces cleaned up"

if [ -n "$IP_ASSIGNED" ]; then
    exit 0
else
    exit 1
fi
