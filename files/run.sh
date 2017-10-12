#!/bin/bash

BASE_DIR=$(cd $(dirname "$0") && pwd -P)
SCRIPT_NAME=$(basename "$0")

# main vars
ENCRYPTME_DIR="${ENCRYPTME_DIR:-/etc/encryptme}"
ENCRYPTME_API_URL="${ENCRYPTME_API_URL:-}"
ENCRYPTME_CONF="${ENCRYPTME_DIR}/encyptme.conf"
ENCRYPTME_PKI_DIR="${ENCRYPTME_PKI_DIR:-$ENCRYPTME_DIR/pki}"
ENCRYPTME_DATA_DIR="${ENCRYPTME_DATA_DIR:-$ENCRYPTME_DIR/data}"
ENCRYPTME_DNS_CHECK=0
DISABLE_LETSENCRYPT=0
LETSENCRYPT_STAGING=${LETSENCRYPT_STAGING:-0}
VERBOSE=${ENCRYPTME_VERBOSE:-0}


# helpers
fail() {
    echo "${1:-failed}" >&1
    exit ${2:-1}
}

cmd() {
    [ $VERBOSE -gt 0 ] && echo "$   $@" >&2
    "$@"
}

rem() {
    [ $VERBOSE -gt 0 ] && echo "# $@" >&2
    return 0
}

rundaemon () {
    if (( $(ps -ef | grep -v grep | grep $1 | wc -l) == 0 )); then
        rem "starting" "$@"
        "$@"
    fi
}

encryptme_server() {
    local args=(--config $ENCRYPTME_CONF "$@")
    if [ -n "$ENCRYPTME_API_URL" ]; then
        args=(--base_url "$ENCRYPTME_API_URL" "${args[@]}")
    fi
    cmd cloak-server "${args[@]}"
}


# sanity checks and basic init
if [ ! -d "$ENCRYPTME_DIR" ]; then
    fail "ENCRYPTME_DIR '$ENCRYPTME_DIR' must exist" 1
elif [ ! -w "$ENCRYPTME_DIR" ]; then
    fail "ENCRYPTME_DIR '$ENCRYPTME_DIR' must be writable" 2
fi
cmd mkdir -p "$ENCRYPTME_PKI_DIR"/crls
if [ ! -d "$ENCRYPTME_PKI_DIR" ]; then
    fail "ENCRYPTME_PKI_DIR '$ENCRYPTME_PKI_DIR' did not exist and count not be created" 3
fi
if [ -z "$ENCRYPTME_EMAIL" -a "$DISABLE_LETSENCRYPT" != 1 ]; then
    fail "ENCRYPTME_EMAIL must be set if DISABLE_LETSENCRYPT is not set" 4
fi
cmd mkdir -p "$ENCRYPTME_DATA_DIR" \
    || fail "Failed to create Encrypt.me data dir '$ENCRYPTME_DATA_DIR'" 5


# Run an configured Encrypt.me private end-point server (must have run 'config' first)

set -eo pipefail
IFS=$'\n\t'


case "$1" in
    /*)
        exec "$@"
        ;;
    bash*)
        exec "$@"
        ;;
esac

# register the server
if [ -f "$ENCRYPTME_CONF" ]; then
    rem "Instance is already registered; skipping" >&2
else
    opt_ENCRYPTME_EMAIL=--email
    opt_ENCRYPTME_PASSWORD=--password
    opt_ENCRYPTME_TARGET_ID=--target
    opt_ENCRYPTME_SERVER_NAME=--name
    args=""
    missing=""
    set ""
    for var in ENCRYPTME_EMAIL ENCRYPTME_PASSWORD ENCRYPTME_TARGET_ID \
               ENCRYPTME_SERVER_NAME; do
        value="${!var}"
        if [ -z "$value" ]; then
            missing="$missing $var"
        else
            arg_var_name="opt_$var"
            set - "$@" "${!arg_var_name}" "$value"
        fi
    done
    shift

    if [ ! -t 1 -a ! -z "$missing" ]; then
        fail "Not on a TTY and missing env vars: $missing" 3
    fi

    # creates /etc/encryptme.conf
    if encryptme_server register "$@"; then
        rem "Registered"
    else
        fail "Registration failed" 4
    fi
    set -
    shift
fi


# request certificate approval
if [ -f "$ENCRYPTME_PKI_DIR/cloak.pem" ]; then
    rem "Private key is already generated"
else
    rem "Requesting certificate (and waiting for approval)"
    encryptme_server req --key "$ENCRYPTME_PKI_DIR/cloak.pem"
fi


# download PKI certificates
if [ -f "$ENCRYPTME_PKI_DIR/crls.pem" ]; then
    rem "PKI certificates are already downloaded."
else
    rem "Requesting approval for PKI certs"
    encryptme_server pki --force --out "$ENCRYPTME_PKI_DIR" --wait
    rem "Downloading PKI certs"
    encryptme_server crls --infile "$ENCRYPTME_PKI_DIR/crl_urls.txt" \
        --out "$ENCRYPTME_PKI_DIR/crls" \
        --format pem \
        --post-hook "cat '$ENCRYPTME_PKI_DIR'/crls/*.pem > '$ENCRYPTME_PKI_DIR/crls.pem'"
fi


# ensure we have DH params generated
if [ ! -f "$ENCRYPTME_PKI_DIR/dh2048.pem" ]; then
    rem "Generating DH Params"
    openssl dhparam -out "$ENCRYPTME_PKI_DIR/dh2048.pem" 2048
fi


# Symlink certificates and keys to ipsec.d directory
if [ ! -L "/etc/ipsec.d/certs/cloak.pem" ]; then
    ln -s "$ENCRYPTME_PKI_DIR/crls.pem" "/etc/ipsec.d/crls/crls.pem"
    ln -s "$ENCRYPTME_PKI_DIR/anchor.pem" "/etc/ipsec.d/cacerts/cloak-anchor.pem"
    ln -s "$ENCRYPTME_PKI_DIR/client_ca.pem" "/etc/ipsec.d/cacerts/cloak-client-ca.pem"
    ln -s "$ENCRYPTME_PKI_DIR/server.pem" "/etc/ipsec.d/certs/cloak.pem"
    ln -s "$ENCRYPTME_PKI_DIR/cloak.pem" "/etc/ipsec.d/private/cloak.pem"
fi


# Gather server/config information (e.g. FQDNs, open VPN settings)
rem "Getting server info"
encryptme_server info --json | json_pp | tee "$ENCRYPTME_DATA_DIR/server.json"
if [ ! -s "$ENCRYPTME_DATA_DIR/server.json" ]; then
    fail "Failed to get or parse server 'info' API response" 5
fi

jq -r '.target.ikev2[].fqdn, .target.openvpn[].fqdn' \
    < "$ENCRYPTME_DATA_DIR/server.json" \
    | sort -u > "$ENCRYPTME_DATA_DIR/fqdns"
FQDNS=$(cat "$ENCRYPTME_DATA_DIR/fqdns") || fail "Failed to fetch FQDNS"
FQDN=${FQDNS%% *}


# Test FQDNs match IPs on this system
# TODO: ensure this to be reliable on DO and AWS
# TODO: Note this is only valid for AWS http://169.254.169.254 is at Amazon
DNSOK=1
DNS=0.0.0.0
if [ $ENCRYPTME_DNS_CHECK -ne 0 ]; then
    EXTIP=$(curl --connect-timeout 5 -s http://169.254.169.254/latest/meta-data/public-ipv4)
    for hostname in $FQDNS; do
        rem "Checking DNS for FQDN '$hostname'"
        DNS=`kdig +short A $hostname | egrep '^[0-9]+\.'`
        if [ ! -z "$DNS" ]; then
            rem "Found IP '$DNS' for $hostname"
            if ip addr show | grep "$DNS" > /dev/null; then
                rem "Looks good: Found IP '$DNS' on local system"
            elif [ "$DNS" == "$EXTIP" ]; then
                rem "Looks good: '$DNS' matches with external IP of `hostname`"
            else
                DNSOK=0
                rem "WARNING: Could not find '$DNS' on the local system.  DNS mismatch?"
            fi
        else
            rem "WARNING: $hostname does not resolve"
            DNSOK=0
        fi
    done
fi


# Perform letsencrypt if not disabled
# Also runs renewals if a cert exists
LETSENCRYPT=0
if [ -z "${DISABLE_LETSENCRYPT:-}" -o "${DISABLE_LETSENCRYPT:-}" = "0" ]; then
    LETSENCRYPT=1
    if [ "$DNSOK" = 0 ]; then
        rem "WARNING: DNS issues found, it is unlikely letsencrypt will succeed."
    fi

    set - --non-interactive --email "$ENCRYPTME_EMAIL" --agree-tos certonly
    set - "$@" $(for fqdn in $FQDNS; do printf -- '-d %q' "$fqdn"; done)
    if [ ! -z "$LETSENCRYPT_STAGING" ]; then
        set - "$@" --staging
    fi
    set - "$@" --expand --standalone --standalone-supported-challenges http-01

    # temporarily allow in HTTP traffic to perform domain verification
    /sbin/iptables -A INPUT -p tcp --dport http -j ACCEPT
    if [ ! -f "/etc/letsencrypt/live/$FQDN/fullchain.pem" ]; then
        rem "Getting certificate for $FQDN"
        rem "Letsencrypt arguments: " "$@"
        letsencrypt "$@"
        set -
    else
        letsencrypt renew
    fi
    /sbin/iptables -D INPUT -p tcp --dport http -j ACCEPT

    cp "/etc/letsencrypt/live/$FQDN/privkey.pem" \
        /etc/ipsec.d/private/letsencrypt.pem \
        || fail "Failed to copy privkey.pem to IPSec config dir"
    cp "/etc/letsencrypt/live/$FQDN/fullchain.pem" \
        /etc/ipsec.d/certs/letsencrypt.pem \
        || fail "Failed to copy letsencrypt.pem to IPSec config dir"
fi


# Start services
rundaemon cron
rundaemon unbound -d &

# Silence warning
chmod 700 /etc/encryptme/pki/cloak.pem

# Ensure networking is setup properly
sysctl -w net.ipv4.ip_forward=1

# Host needs various modules loaded..
for mod in ah4 ah6 esp4 esp6 xfrm4_tunnel xfrm6_tunnel xfrm_user \
    ip_tunnel xfrm4_mode_tunnel xfrm6_mode_tunnel \
    pcrypt xfrm_ipcomp deflate; do
        modprobe $mod;
done

# generate IP tables rules
/bin/template.py \
    -d "$ENCRYPTME_DATA_DIR/server.json" \
    -s /etc/iptables.rules.j2 \
    -o /etc/iptables.rules \
    -v ipaddress=$DNS
# TODO this leaves extra rules around
/sbin/iptables-restore --noflush < /etc/iptables.rules


rem "Configuring and launching OpenVPN"
get_openvpn_conf() {
    out=$(cat "$ENCRYPTME_DATA_DIR/server.json" | jq ".target.openvpn[$1]")
    if [ "$out" = null ]; then
        echo ""
    else
        echo "$out"
    fi
}
n=0
conf="$(get_openvpn_conf $n)"
while [ ! -z "$conf" ]; do
    echo "$conf" > "$ENCRYPTME_DATA_DIR/openvpn.$n.json"
    /bin/template.py \
        -d /tmp/openvpn.$n.json \
        -s /etc/openvpn/openvpn.conf.j2 \
        -o /etc/openvpn/server-$n.conf
    rem "Started OpenVPN instance #$n"
    mkdir -p /var/run/openvpn
    mkfifo /var/run/openvpn/server-0.sock
    rundaemon /usr/sbin/openvpn \
        --status /var/run/openvpn/server-$n.status 10 \
         --cd /etc/openvpn \
         --script-security 2 \
         --config /etc/openvpn/server-$n.conf \
         --writepid /var/run/openvpn/server-$n.pid \
         --management /var/run/openvpn/server-$n.sock unix \
         &
    n=$[ $n + 1 ]
    conf="$(get_openvpn_conf $n)"
done


rem "Configuring and starting strongSwan"
/bin/template.py \
    -d "$ENCRYPTME_DATA_DIR/server.json" \
    -s /etc/ipsec.conf.j2 \
    -o /etc/ipsec.conf \
    -v letsencrypt=$LETSENCRYPT
/bin/template.py \
    -d "$ENCRYPTME_DATA_DIR/server.json" \
    -s /etc/ipsec.secrets.j2 \
    -o /etc/ipsec.secrets \
    -v letsencrypt=$LETSENCRYPT
/usr/sbin/ipsec start
#/usr/sbin/ipsec reload
#/usr/sbin/ipsec rereadcacerts
#/usr/sbin/ipsec rereadcrls


[ ${ENCRYPTME_INIT_ONLY:-0} = "1" ] && {
    rem "Init complete; run './go.sh run' to start"
    exit 0
}

rem "Start-up complete"
while true; do
    date
    sleep 300
done

