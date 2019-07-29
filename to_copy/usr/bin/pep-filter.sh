#!/bin/bash -x

BASE_DIR=$(cd $(dirname "$0") && pwd -P)
SCRIPT_NAME=$(basename "$0")

FILTERS_DIR="/etc/encryptme/filters"
DOMAIN_RE="^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}"
CIDR_RE="([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]{1,3})?"
# CIDR_RE='[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\/[0-9]\{1,\}'
TMP_DIR="/tmp/$SCRIPT_NAME.$$" && mkdir -p "$TMP_DIR" \
    || fail "Failed to create tempory directory '$TMP_DIR'"


# JFK NOTES:
# - ensure domains/IPs persist after reboot, container restart, etc
# -

usage() {
    cat << EOF
usage: $SCRIPT_NAME ACTION ARGS

Automated DNS and IPv4 CIDR filtering based on arbitrary lists. Reads STDIN
for a list of domains or IPv4 CIDR ranges.

  - Domains are sync'd in '$FILTERS_DIR' and read by the DNS filter socket server
  - IP sets are created and used in iptables to filter out IPs; writes rules to:
     - /etc/iptables.save
     - /etc/ipset.save

ACTIONS:

    append NAME  Add domains/ips to a block list
    replace NAME Replace all domains/ips in a block list with new ones
    prune NAME   Delete domains/ips from a block list
    reset        Remove all domain and IP filtering

EXAMPLES:

    # Add the list 'security'
    $SCRIPT_NAME add security < /opt/lists/security.txt
    echo 'google.com' | ./$SCRIPT_NAME add security

    # Stop filtering all domains/IPs in 'security' list
    $SCRIPT_NAME delete -l security

    # Reset everything to stop all filtering
    $SCRIPT_NAME reset
EOF

}


cleanup() {
    [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR" &>/dev/null
}


fail() {
    echo "! $1" >&2
    cleanup
    exit 1
}


reload_filter() {
    local cmd="/usr/local/unbound-1.7/sbin/filter_server.py"
    "$cmd" stop
    "$cmd" start
}


add_ips() {
    local list_name="$1"
    local tmp_ip_file="$TMP_DIR/$list_name.cidr.old"

    # create the ipset list if needed
    /usr/sbin/ipset list | grep -q -w "$list_name" || {
        /usr/sbin/ipset -N "$list_name" hash:net \
            || fail "Failed to create ipset $list_name"
    }

    # create the rule for this list, if needed
    /usr/sbin/iptables-save | grep -Eq -- "--match-set \<$list_name\>" || {
        /usr/sbin/iptables -I ENCRYPTME 2 -m set --match-set "$list_name" dst -j DROP \
            || fail "Failed to insert iptables rule $list_name"
    }

    # add only new IPs to the rule (duplicates are bad!)
    ipset list "$list_name" \
        | grep -Eo "$CIDR_RE" \
        | sort -u > "$tmp_ip_file" \
        || fail "Failed to get IP list for '$list'"
    comm -13 "$tmp_ip_file" - | while read cidr; do
        /usr/sbin/ipset -A "$list_name" "$cidr"
    done
    rm "$tmp_ip_file" &>/dev/null
}


add_domains() {
    local list_name="$1"
    local new_domain_file="$2"
    local tmp_domain_file="$TMP_DIR/domains.old"
    local domain_file="$FILTERS_DIR/$list_name.blacklist"

    touch "$tmp_domain_file" || fail "Failed to create temp domain file"
    mkdir -p "$FILTERS_DIR" \
        || fail "Failed to create blacklists directory"

    # keep things clean add keep dupes scrubbed out as we update the domain list
    [ -s '$domain_file' ] && \
        cat "$domain_file" | sort -u > "$tmp_domain_file"

    cat "$tmp_domain_file" "$new_domain_file" | sort -u > "$domain_file" \
        || fail "Failed to write $domain_file"
    reload_filter \
       || fail "Failed to reload dns-filter"
}


prune_list() {
    local list_name="$1"
    local domain_file="$FILTERS_DIR/$list_name.blacklist"

    # delete the IP table rule and ipset list
    /sbin/ipset list | grep -q "^Name: $list_name$" && {
       /sbin/iptables-save | grep -Eq -- "--match-set \<$list_name\>" && {
          /sbin/iptables -D ENCRYPTME -m set --match-set "$list_name" dst -j DROP
       }
       /sbin/ipset destroy "$list_name"
    }

    # delete a domain blacklist file
    [ -f "$domain_file" ] && {
       rm -f "$domain_file"
       reload_filter
    }
    return 0
}


reset_filters() {
    list_name="${1:-}"  # if set, deletes a specific list
    # delete all ipset lists and iptables rules
    /sbin/ipset list | awk '$1 == "Name:" { print $2}' | while read list_name; do
       #if [ "$list" == "whitelist" ]; then
       #   /sbin/iptables -D ENCRYPTME -m set --match-set "$list" dst -j ACCEPT \
       #      || fail "Failed to delete iptables rule for the list $list"
       #   docker exec -i encryptme truncate -s 0 /usr/local/unbound-1.7/etc/unbound/whitelist.txt \
       #      || fail "Failed to delete domain list $list.txt"
       #else
      /sbin/iptables -D ENCRYPTME -m set --match-set "$list" dst -j DROP \
          || fail "Failed to delete iptables rule for the list $list"
       /sbin/ipset destroy "$list" \
          || fail "Failed to delete ipset $list"
    done

    # remove our domain blacklists
    rm -rf "$FILTERS_DIR" \
       || fail "Failed to delete domain lists"

    reload_filter
}


# JKF: support this later
#whitelist_ip () {
#    /sbin/ipset list whitelist | grep -q "$whitelist_me"
#    if [ $? -eq 1 ]; then
#       /sbin/ipset -A whitelist "$whitelist_me" \
#          || fail "Failed to whitelist IP $whitelist_me"
#    else
#       fail "$whitelist_me exists in whitelist"
#    fi
#}
#
#whitelist_domain () {
#    docker exec -it encryptme grep -q "$whitelist_me" /usr/local/unbound-1.7/etc/unbound/whitelist.txt
#    if [ $? -eq 1 ]; then
#       docker exec -it encryptme bash -c "echo "$whitelist_me" >> /usr/local/unbound-1.7/etc/unbound/whitelist.txt" \
#          || fail "Failed to whitelist domain $whitelist_me"
#       reload_filter || fail "Failed to reload dns-filter"
#    else
#       fail "$whitelist_me exists in whitelist"
#    fi
#}


# reads stdin to parse IPv4 CIDR ranges and domain names and filter them out
append_list() {
    local list_name="$1"
    local cidr_file="$TMP_DIR/$list_name.cidr"
    local domain_file="$TMP_DIR/$list_name.domains"

    # each line must be a domain name or a IPv4 CIDR range
    while read item; do
        echo "$item" | grep -Eq "$CIDR_RE" && echo "$item" >> "$cidr_file"
        [ $? = 1 ] && echo "$item" | grep -Eq "$DOMAIN_RE" && \
            echo "$item" >> "$domain_file"
    done

    [ -s "$cidr_file" ] && cat "$cidr_file" | sort -u | add_ips "$list_name"
    [ -s "$domain_file" ] &&  add_domains "$list_name" "$domain_file"
}


# ===========================================================================

[ $# -ge 1 ] || {
    usage
    fail "No action given"
}
case "$1" in
    append|replace|prune|reset)
        action="$1"
        shift
        ;;
    *)
        usage
        fail "Invalid action: '$1'"
esac

# JKF: consider later
#/sbin/ipset list | grep -q whitelist
#if [ $? -eq 1 ]; then
#   /sbin/ipset -N whitelist iphash \
#      || fail "Failed to create ipset whitelist"
#fi
#
#/sbin/iptables-save | grep -q whitelist
#if [ $? -eq 1 ]; then
#   /sbin/iptables -I ENCRYPTME -m set --match-set whitelist dst -j ACCEPT \
#      || fail "Failed to insert iptables rule"
#fi


[ "$action" = "append" ] && {
    [ $# -eq 1 ] || fail "No list name given to append to"
    list_name="$1" && shift
    append_list "$list_name"
}

[ "$action" = "replace" ] && {
    [ $# -eq 1 ] || fail "No list name given to replace"
    list_name="$1" && shift
    prune_list "$list_name"
    append_list "$list_name"
}

[ "$action" = "prune" ] && {
    [ $# -eq 1 ] || fail "No list name given to prune from"
    list_name="$1" && shift
    prune_list "$list_name"
}

[ "$action" = "reset" ] && {
    reset_filters
}

# ensure our IP tables are up-to-date so we can restore them on restart
/usr/sbin/iptables-save > /etc/iptables.save \
   || fail "Failed to write /etc/iptables.save"
/usr/sbin/ipset save > /etc/ipset.save \
   || fail "Failed to write /etc/ipset.save"

cleanup

exit 0