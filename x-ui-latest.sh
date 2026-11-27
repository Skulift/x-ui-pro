#!/bin/bash
#################### x-ui-pro v2.4.3 @ github.com/GFW4Fun ##############################################
##############################INFO######################################################################
msg_ok() { echo -e "\e[1;42m $1 \e[0m";}
msg_err() { echo -e "\e[1;41m $1 \e[0m";}
msg_inf() { echo -e "\e[1;34m$1\e[0m";}
echo;msg_inf '           ___    _   _   _  '	;
msg_inf		 ' \/ __ | |  | __ |_) |_) / \ '	;
msg_inf		 ' /\    |_| _|_   |   | \ \_/ '	; echo
##################################Variables#############################################################
XUIDB="/etc/x-ui/x-ui.db";domain="";INSTALL="n";PNLNUM=1;CFALLOW="n";CLASH=0;CUSTOMWEBSUB=0
Pak=$(type apt &>/dev/null && echo "apt" || echo "yum")
panel_version=v3.11.0
hy2_enabled=yes
hy2_port=443
hy2_mode=install
hy2_domain=
hy2_cert=
hy2_key=
hy2_panel_url=
backup_only=no
skip_ufw=no
skip_sysctl=no
argument_count=$#
##################################generate ports and paths#############################################################
get_port() {
	echo $(( ((RANDOM<<15)|RANDOM) % 49152 + 10000 ))
}

gen_random_string() {
    local length="$1"
    head -c 4096 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "$length"
    echo
}
check_free() {
	local port=$1
	[[ -n $(ss -H -ltn "sport = :$port") ]]
	return $?
}

make_port() {
	while true; do
		PORT=$(get_port)
		if ! check_free $PORT; then 
			echo $PORT
			break
		fi
	done
}

reality_domain=

################################Get arguments###########################################################
while [ "$#" -gt 0 ]; do
  case "$1" in
    --add-hy2) hy2_mode=add; shift; continue;;
    --no-hy2) hy2_enabled=no; shift; continue;;
    --enable-db-backups) backup_only=yes; shift; continue;;
    --skip-ufw) skip_ufw=yes; shift; continue;;
    --skip-sysctl) skip_sysctl=yes; shift; continue;;
    --help|-h)
      cat <<'USAGE'
Fresh installation (Debian/Ubuntu, systemd):
  sudo bash x-ui-latest.sh -install yes [-subdomain HOST -reality_domain HOST]
    [--hy2-port PORT] [--hy2-domain HOST --hy2-cert FULLCHAIN --hy2-key PRIVATE_KEY]
    [--no-hy2] [--skip-ufw] [--skip-sysctl]
Add Hy2 to an existing 3x-ui installation:
  sudo bash x-ui-latest.sh --add-hy2 --panel-url https://HOST/PANEL_PATH/
    --hy2-domain HOST [--hy2-port PORT] [--hy2-cert FULLCHAIN --hy2-key PRIVATE_KEY]
    [--skip-ufw]
Enable daily database backups on an existing installation:
  sudo bash x-ui-latest.sh --enable-db-backups
USAGE
      exit 0;;
  esac
  if [[ $# -lt 2 || $2 == -* ]]; then
    msg_err "Missing value for $1"
    exit 2
  fi
  case "$1" in
    --panel-url) hy2_panel_url="$2"; shift 2;;
    --hy2-domain) hy2_domain="$2"; shift 2;;
    --hy2-port) hy2_port="$2"; shift 2;;
    --hy2-cert) hy2_cert="$2"; shift 2;;
    --hy2-key) hy2_key="$2"; shift 2;;
    --*) msg_err "Unknown option: $1"; exit 2;;
    -auto_domain) AUTODOMAIN="$2"; shift 2;;
    -install) INSTALL="$2"; shift 2;;
    -panel) PNLNUM="$2"; shift 2;;
    -subdomain) domain="$2"; shift 2;;
    -reality_domain) reality_domain="$2"; shift 2;;
    -ONLY_CF_IP_ALLOW) CFALLOW="$2"; shift 2;;
    -websub) CUSTOMWEBSUB="$2"; shift 2;;
    -clash) CLASH="$2"; shift 2;;
    *) msg_err "Unknown option: $1"; exit 2;;
  esac
done


fail() {
    msg_err "$*" >&2
    exit 1
}

enable_db_backups() {
    local backup_dir=/var/backups/x-ui-pro
    local backup_script=/usr/local/sbin/x-ui-pro-db-backup
    local unit_dir=/etc/systemd/system
    [[ -s $XUIDB ]] || fail "Cannot find the 3x-ui SQLite database at $XUIDB."
    command -v sqlite3 >/dev/null || fail "Install the sqlite3 package to enable database backups."
    install -d -m 0700 -o root -g root "$backup_dir" || fail "Cannot create the backup directory."

    cat > "$backup_script" <<'BACKUP_SCRIPT' || fail "Cannot write the database backup script."
#!/bin/bash
set -eu
umask 077

database=$1
backup_dir=$2
if [[ ! -s $database ]]; then
    printf 'Database missing or empty: %s\n' "$database" >&2
    exit 1
fi

cd "$backup_dir"
filename="x-ui-$(date +%F).db"
temp_file=$(mktemp .x-ui-backup.XXXXXXXX)
trap 'rm -f -- "$temp_file" "${temp_file}-journal"' EXIT
trap 'exit 1' HUP INT TERM
sqlite3 -batch -bail -readonly -cmd '.timeout 5000' "$database" ".backup '$temp_file'"
mv -fT -- "$temp_file" "$filename"

find . -maxdepth 1 -type f -name 'x-ui-????-??-??.db' -mmin +10079 -delete
printf 'Database backup saved to %s/%s\n' "$backup_dir" "$filename"
BACKUP_SCRIPT
    chmod 0750 "$backup_script" || fail "Cannot set permissions on the database backup script."

    cat > "$unit_dir/x-ui-pro-db-backup.service" <<BACKUP_SERVICE || fail "Cannot write the database backup service."
[Unit]
Description=Back up the 3x-ui database

[Service]
Type=oneshot
ExecStart=$backup_script $XUIDB $backup_dir
TimeoutStartSec=5min
BACKUP_SERVICE

    cat > "$unit_dir/x-ui-pro-db-backup.timer" <<'BACKUP_TIMER' || fail "Cannot write the database backup timer."
[Unit]
Description=Daily 3x-ui database backup

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
BACKUP_TIMER

    systemctl daemon-reload &&
        systemctl start x-ui-pro-db-backup.service &&
        systemctl enable --now x-ui-pro-db-backup.timer ||
        fail "Could not enable database backups. Check journalctl -u x-ui-pro-db-backup.service."
    printf 'Daily database backups enabled in %s (7-day retention).\n' "$backup_dir"
}

valid_domain() {
    [[ $1 =~ ^([[:alnum:]]([[:alnum:]-]{0,61}[[:alnum:]])?\.)+[[:alpha:]][[:alnum:]-]{0,61}[[:alnum:]]$ && ${#1} -le 253 ]]
}

check_udp_port() {
    local listeners
    listeners=$(ss -H -aun "sport = :$hy2_port") || fail "Could not check UDP listeners."
    [[ -z $listeners ]] || fail "UDP $hy2_port is already in use. Choose --hy2-port."
}

panel_request() {
    local method=$1 path=$2
    shift 2
    curl -fsS --noproxy '*' --connect-timeout 5 --max-time 25 "${hy2_resolve[@]}" \
        -b "$session_file" -c "$session_file" -H 'X-Requested-With: XMLHttpRequest' \
        -H "X-CSRF-Token: $csrf" -X "$method" "$hy2_panel_url/$path" "$@"
}

verify_subscriptions() {
    local raw decoded json
    local -a request=(--noproxy '*' --resolve "$domain:443:127.0.0.1"
                     -fsS --retry 3 --connect-timeout 5 --max-time 15)
    raw=$(curl "${request[@]}" -H 'User-Agent: v2rayN/7.0' "$sub_uri$hy2_sub_id") ||
        fail "The public URL for the standard subscription did not respond."
    decoded=$(printf '%s' "$raw" | base64 -d) ||
        fail "The standard subscription did not return a Base64 config."
    grep -q '^hysteria2://' <<<"$decoded" ||
        fail "The standard subscription is missing the Hysteria 2 link."
    json=$(curl "${request[@]}" -H 'User-Agent: v2rayN/7.0' "$json_uri$hy2_sub_id") ||
        fail "The public URL for the JSON subscription did not respond."
    jq -e 'any(.. | objects; .protocol? == "hysteria" or .protocol? == "hysteria2")' >/dev/null <<<"$json" ||
        fail "The JSON subscription did not return a JSON config."
}

add_hy2() (
    umask 077
    local work_dir session_file csrf= result inbounds auth mask email subid payload
    local cert_fingerprint key_fingerprint
    [[ $hy2_panel_url =~ ^https?://[[:alnum:].:-]+(/[[:alnum:]_.~-]+)*/?$ ]] ||
        fail "Set --panel-url to the HTTPS URL of your panel, including its base path."
    hy2_panel_url=${hy2_panel_url%/}
    if [[ $hy2_panel_url == http://* && ! $hy2_panel_url =~ ^http://(127\.0\.0\.1|localhost)(:[0-9]+)?(/|$) ]]; then
        fail "Use HTTPS for a remote panel URL."
    fi
    valid_domain "$hy2_domain" || fail "Set --hy2-domain to a valid DNS hostname."
    work_dir=$(mktemp -d) || fail "Could not create a temporary session directory."
    trap 'rm -f "$work_dir/cookies"; rmdir "$work_dir"' EXIT
    session_file=$work_dir/cookies
    touch "$session_file" || fail "Could not create session file."
    csrf=$(panel_request GET csrf-token --retry 4 --retry-connrefused | jq -er '.obj | strings') ||
        fail "Unable to open a 3x-ui session. Check the panel URL and version."
    local two_factor=
    if [[ -z ${hy2_username:-} ]]; then
        read -r -p '3x-ui username: ' hy2_username </dev/tty || fail "Cannot read panel login."
        read -r -s -p '3x-ui password: ' hy2_password </dev/tty || fail "Cannot read panel password."
        printf '\n' >&2
        read -r -s -p '3x-ui 2FA code (Enter if disabled): ' two_factor </dev/tty ||
            fail "Cannot read the 2FA code."
        printf '\n' >&2
    fi
    result=$(printf '%s\0%s\0%s\0' "$hy2_username" "$hy2_password" "$two_factor" |
        jq -Rs 'split("\u0000") | {username:.[0],password:.[1],twoFactorCode:(.[2] // "")}' |
        panel_request POST login -H 'Content-Type: application/json' --data-binary @-) ||
        fail "3x-ui login request failed."
    jq -e '.success == true' >/dev/null <<<"$result" || fail "3x-ui refused the login."
    csrf=$(panel_request GET csrf-token | jq -er '.obj | strings') || fail "Could not refresh the panel session."
    inbounds=$(panel_request GET panel/api/inbounds/list) || fail "Could not list 3x-ui inbounds."
    jq -e '.success == true and (.obj | type == "array" or . == null)' >/dev/null <<<"$inbounds" ||
        fail "3x-ui returned an invalid inbound list."
    if jq -e '.obj[]? | select(.protocol == "hysteria" and .remark == "Hysteria 2 (x-ui-pro)" and (.nodeId // 0) == 0)' \
        >/dev/null <<<"$inbounds"; then
        fail "Managed Hy2 already exists. Its settings and links were preserved. Use 3x-ui to view or edit it."
    fi
    check_udp_port

    hy2_cert=${hy2_cert:-/etc/letsencrypt/live/$hy2_domain/fullchain.pem}
    hy2_key=${hy2_key:-/etc/letsencrypt/live/$hy2_domain/privkey.pem}
    openssl x509 -in "$hy2_cert" -checkend 0 -noout >/dev/null &&
        openssl x509 -in "$hy2_cert" -checkhost "$hy2_domain" -noout |
            grep -q 'does match certificate' ||
        fail "Provide an unexpired certificate for $hy2_domain (--hy2-cert and --hy2-key)."
    cert_fingerprint=$(openssl x509 -in "$hy2_cert" -pubkey -noout) &&
        key_fingerprint=$(openssl pkey -in "$hy2_key" -pubout) &&
        [[ $cert_fingerprint == "$key_fingerprint" ]] || fail "The certificate and key do not match."

    if [[ $hy2_mode == add ]]; then
        [[ -f $XUIDB ]] || fail "This add mode requires a local 3x-ui SQLite database at $XUIDB."
        local backup
        backup=$(mktemp /etc/x-ui/x-ui-before-hy2.XXXXXXXX) || fail "Cannot allocate backup."
        sqlite3 -bail "$XUIDB" ".backup '$backup'" || fail "3x-ui database backup failed."
        printf 'Database backup: %s\n' "$backup" >&2
    fi

    auth=$(openssl rand -hex 24) && mask=$(openssl rand -hex 24) &&
        subid=$(openssl rand -hex 12) && email="hy2-$(openssl rand -hex 6)" ||
        fail "Could not generate Hysteria 2 credentials."
    payload=$(printf '%s\n%s\n' "$auth" "$mask" |
        jq -Rs --argjson port "$hy2_port" --arg host "$hy2_domain" \
            --arg cert "$hy2_cert" --arg key "$hy2_key" --arg email "$email" --arg sid "$subid" '
        split("\n") as [$auth, $mask] | {
            remark:"Hysteria 2 (x-ui-pro)", enable:true, port:$port,
            listen:"", protocol:"hysteria",
            shareAddrStrategy:"custom",shareAddr:$host,
            settings:({version:2,clients:[{email:$email, auth:$auth,subId:$sid,enable:true}]} | tojson),
            streamSettings:({
                network:"hysteria", hysteriaSettings:{version:2,udpIdleTimeout:60},
                security:"tls",tlsSettings:{
                    serverName:$host, minVersion:"1.3", alpn:["h3"],
                    certificates:[{certificateFile:$cert,keyFile:$key,usage:"encipherment"}]
                },
                finalmask:{udp:[{type:"salamander",settings:{password:$mask}}]}
            } | tojson), sniffing:({enabled:false} | tojson)
        }') || fail "Could not build the Hy2 inbound."
    result=$(printf '%s' "$payload" |
        panel_request POST panel/api/inbounds/add -H 'Content-Type: application/json' --data-binary @-) ||
        fail "Could not submit the Hy2 inbound."
    jq -e '.success == true' >/dev/null <<<"$result" || {
        jq -r '.msg // "3x-ui rejected the Hy2 inbound."' >&2 <<<"$result"
        fail "Hysteria 2 creation failed."
    }

    local listening attempt
    listening=$(ss -H -aunp "sport = :$hy2_port")
    if [[ $listening != *xray* ]]; then
        result=$(panel_request POST panel/api/server/restartXrayService) &&
            jq -e '.success == true' >/dev/null <<<"$result" ||
            fail "Hy2 was saved, but the panel could not restart Xray. Check its logs."
    fi
    for (( attempt=0; attempt<20; attempt++ )); do
        listening=$(ss -H -aunp "sport = :$hy2_port")
        [[ $listening == *xray* ]] && break
        sleep 1
    done
    [[ $listening == *xray* ]] ||
        fail "Hy2 was created, but Xray did not open UDP $hy2_port. Check journalctl -u x-ui."

    if [[ $hy2_mode == add && $skip_ufw == no ]] && command -v ufw >/dev/null &&
        LANG=C ufw status | grep -q '^Status: active'; then
        ufw allow "$hy2_port/udp" >&2 || fail "Could not update UFW for Hy2."
    fi
    printf '%s\n' "$subid"
    printf 'hysteria2://%s@%s:%s/?sni=%s&obfs=salamander&obfs-password=%s#Hysteria-2\n' \
        "$auth" "$hy2_domain" "$hy2_port" "$hy2_domain" "$mask"
)

if [[ $EUID -ne 0 ]]; then
    fail "Run this script as root (sudo bash)."
fi
[[ $hy2_port =~ ^[1-9][0-9]{0,4}$ && $hy2_port -le 65535 ]] ||
    fail "Invalid UDP port. Use a value from 1 to 65535."
exec 9>/run/lock/x-ui-pro-install.lock
flock -n 9 || fail "Another x-ui-pro operation is running."
if [[ $backup_only == yes ]]; then
    [[ $argument_count -eq 1 ]] || fail "Use --enable-db-backups by itself."
    enable_db_backups
    exit 0
fi
hy2_resolve=()
if [[ $hy2_mode == add ]]; then
    [[ $hy2_enabled == yes ]] || fail "--add-hy2 cannot be combined with --no-hy2."
    for command in curl jq openssl sqlite3 ss; do
        command -v "$command" >/dev/null || fail "Missing dependency: $command"
    done
    hy2_result=$(add_hy2) || exit 1
    printf 'Hysteria 2: %s\n' "${hy2_result#*$'\n'}"
    exit 0
fi


if [[ -e $XUIDB || -e /usr/local/x-ui/x-ui || -e /etc/systemd/system/x-ui.service ]]; then
    fail "Existing 3x-ui found. Use --add-hy2 to keep its configuration."
fi

# --- get public IPv4 early (for auto-domain mode)
IP4_REGEX="^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"
IP4=$(ip route get 8.8.8.8 2>&1 | grep -Po -- 'src \K\S*')
[[ $IP4 =~ $IP4_REGEX ]] || IP4=$(curl -s ipv4.icanhazip.com | tr -d '[:space:]')


if [[ ${AUTODOMAIN} == *"y"* ]]; then
    # panel domain: x.x.x.x.cdn-one.org
    domain="${IP4}.cdn-one.org"

    # reality domain: x-x-x-x.cdn-one.org
    reality_domain="${IP4//./-}.cdn-one.org"
fi


##############################Domain Validations########################################################
while true; do	
	if [[ -n "$domain" ]]; then
		break
	fi
	echo -en "Enter available subdomain (sub.domain.tld): " && read domain 
done

domain=$(echo "$domain" 2>&1 | tr -d '[:space:]' )
SubDomain=$(echo "$domain" 2>&1 | sed 's/^[^ ]* \|\..*//g')
MainDomain=$(echo "$domain" 2>&1 | sed 's/.*\.\([^.]*\..*\)$/\1/')

if [[ "${SubDomain}.${MainDomain}" != "${domain}" ]] ; then
	MainDomain=${domain}
fi

while true; do	
	if [[ -n "$reality_domain" ]]; then
		break
	fi
	echo -en "Enter available subdomain for REALITY (sub.domain.tld): " && read reality_domain 
done

reality_domain=$(echo "$reality_domain" 2>&1 | tr -d '[:space:]' )
RealitySubDomain=$(echo "$reality_domain" 2>&1 | sed 's/^[^ ]* \|\..*//g')
RealityMainDomain=$(echo "$reality_domain" 2>&1 | sed 's/.*\.\([^.]*\..*\)$/\1/')

if [[ "${RealitySubDomain}.${RealityMainDomain}" != "${reality_domain}" ]] ; then
	RealityMainDomain=${reality_domain}
fi

valid_domain "$domain" && valid_domain "$reality_domain" || fail "Enter valid DNS hostnames."
[[ ${domain,,} != "${reality_domain,,}" ]] || fail "Panel and REALITY domains must be different."
if [[ $hy2_enabled == yes ]]; then
    hy2_domain=$(printf '%s' "${hy2_domain:-$domain}" | tr '[:upper:]' '[:lower:]')
    valid_domain "$hy2_domain" || fail "Enter a valid Hy2 hostname."
fi
###############################Install Packages#########################################################
check_nginx_https_config() {
    local listeners config
    listeners=$(ss -H -ltnp 'sport = :443') || fail "Could not inspect TCP 443."
    [[ $listeners == *'"nginx"'* ]] || return 0
    config=$(nginx -T) || fail "Could not read the Nginx configuration."
    awk '
        { sub(/#.*/, ""); gsub(/;/, " ") }
        $1 == "listen" && $2 ~ /(^|:)443$/ {
            udp = 0
            for (i = 3; i <= NF; i++) if ($i == "udp") udp = 1
            if (!udp) found = 1
        }
        END { exit !found }
    ' <<<"$config" ||
        fail "Nginx is serving TCP 443, but the configuration on disk has no TCP 443 listener. Restore the active configuration before retrying."
}

if command -v nginx >/dev/null && command -v ss >/dev/null; then
    check_nginx_https_config
fi
if [[ ${INSTALL} == *"y"* ]]; then

         version=$(grep -oP '(?<=VERSION_ID=")[0-9]+' /etc/os-release)

         # Проверяем, является ли версия 20 или 22
        if [[ "$version" == "20" || "$version" == "22" ]]; then
              echo "Версия системы: Ubuntu $version"
        fi

	$Pak -y update

	packages=(curl wget jq bash sudo nginx-full certbot python3-certbot-nginx sqlite3 iproute2 openssl ca-certificates)
	[[ $skip_ufw == yes ]] || packages+=(ufw)
	$Pak -y install "${packages[@]}" || fail "Package installation failed."

	systemctl daemon-reload && systemctl enable --now nginx
fi
command -v ss >/dev/null || fail "Missing iproute2. Re-run with -install yes."
[[ -s /etc/ssl/certs/ca-certificates.crt ]] || fail "Install the ca-certificates package before continuing."
[[ $hy2_enabled == no ]] || check_udp_port
##################################GET SERVER IPv4-6#####################################################
IP4_REGEX="^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"
IP6_REGEX="([a-f0-9:]+:+)+[a-f0-9]+"
IP4=$(ip route get 8.8.8.8 2>&1 | grep -Po -- 'src \K\S*')
IP6=$(ip route get 2620:fe::fe 2>&1 | grep -Po -- 'src \K\S*')
[[ $IP4 =~ $IP4_REGEX ]] || IP4=$(curl -s ipv4.icanhazip.com);
[[ $IP6 =~ $IP6_REGEX ]] || IP6=$(curl -s ipv6.icanhazip.com);
##############################Install SSL###############################################################

resolve_to_ip () {
    local host="$1"
    # get first A-record
    local a
    a=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}')
    [[ -n "$a" ]] && [[ "$a" == "$IP4" ]]
}

if [[ ${AUTODOMAIN} == *"y"* ]]; then
    if ! resolve_to_ip "$domain"; then
        msg_err "Auto-domain $domain does not resolve to this server IP ($IP4). Fix DNS/service and retry."
        exit 1
    fi
    if ! resolve_to_ip "$reality_domain"; then
        msg_err "Auto-domain $reality_domain does not resolve to this server IP ($IP4). Fix DNS/service and retry."
        exit 1
    fi
fi


certbot_hosts=("$domain" "$reality_domain")
if [[ $hy2_enabled == yes && -z $hy2_cert && -z $hy2_key &&
      $hy2_domain != "$domain" && $hy2_domain != "$reality_domain" ]]; then
    certbot_hosts+=("$hy2_domain")
fi
[[ -z $hy2_cert && -z $hy2_key || -n $hy2_cert && -n $hy2_key ]] ||
    fail "Provide both --hy2-cert and --hy2-key."

issue_certificates() (
    local available=/etc/nginx/sites-available/80.conf enabled=/etc/nginx/sites-enabled/80.conf
    local backup host changed=no nginx_action= keep_config=no

    check_nginx_https_config
    nginx -t || fail "Fix the existing Nginx configuration before requesting certificates."
    install -d -m 0755 /var/lib/letsencrypt/.well-known/acme-challenge \
        /etc/nginx/sites-available /etc/nginx/sites-enabled || fail "Could not prepare the ACME webroot."
    backup=$(mktemp -d /etc/nginx/sites-available/.x-ui-pro-acme.XXXXXXXX) || fail "Could not stage the ACME configuration."

    restore_acme_config() {
        rm -f -- "$available" "$enabled" || return 1
        if [[ -e $backup/available || -L $backup/available ]]; then
            cp -a -- "$backup/available" "$available" || return 1
        fi
        if [[ -e $backup/enabled || -L $backup/enabled ]]; then
            cp -a -- "$backup/enabled" "$enabled" || return 1
        fi
        case $nginx_action in
            reload) nginx -t && systemctl reload nginx;;
            start) systemctl stop nginx;;
        esac
    }
    finish_acme() {
        if [[ $changed == yes && $keep_config == no ]] && ! restore_acme_config; then
            msg_err "Could not restore the ACME configuration. Backup: $backup" >&2
            return
        fi
        rm -f -- "$backup/available" "$backup/enabled" "$backup/staged"
        rmdir -- "$backup"
    }
    trap finish_acme EXIT
    trap 'exit 1' HUP INT TERM
    for host in "$available" "$enabled"; do
        [[ ! -d $host || -L $host ]] || fail "Expected an Nginx configuration file at $host."
    done
    if [[ -e $available || -L $available ]]; then
        cp -a -- "$available" "$backup/available" || fail "Could not save the existing ACME configuration."
    fi
    if [[ -e $enabled || -L $enabled ]]; then
        cp -a -- "$enabled" "$backup/enabled" || fail "Could not save the enabled ACME configuration."
    fi
    cat > "$backup/staged" <<EOF || fail "Could not write the ACME configuration."
server {
    listen 80;
    listen [::]:80;
    server_name ${certbot_hosts[*]};
    location ^~ /.well-known/acme-challenge/ { root /var/lib/letsencrypt; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
    changed=yes
    mv -fT -- "$backup/staged" "$available" && ln -sfn -- "$available" "$enabled" ||
        fail "Could not enable the ACME configuration."
    nginx -t || fail "Could not validate the ACME configuration."
    if systemctl is-active --quiet nginx; then
        nginx_action=reload
    else
        nginx_action=start
    fi
    systemctl "$nginx_action" nginx || fail "Could not serve the ACME challenge."
    for host in "${certbot_hosts[@]}"; do
        certbot certonly --webroot -w /var/lib/letsencrypt --non-interactive --agree-tos \
            --register-unsafely-without-email --keep-until-expiring --cert-name "$host" -d "$host" ||
            fail "Could not issue certificate for $host. Review Certbot's error before retrying."
    done
    keep_config=yes
)
issue_certificates || exit 1
################################# Access to configs only with cloudflare#################################

ports=()
for name in sub_port panel_port ws_port trojan_port; do
    while :; do
        candidate=$(make_port)
        [[ " ${ports[*]} " != *" $candidate "* && $candidate != 8443 && $candidate != 9443 ]] && break
    done
    ports+=("$candidate")
    printf -v "$name" '%s' "$candidate"
done
for name in web_path sub2singbox_path sub_path json_path panel_path ws_path trojan_path xhttp_path; do
    printf -v "$name" '%s' "$(openssl rand -hex 12)"
done
config_username=$(openssl rand -hex 10)
config_password=$(openssl rand -hex 24)
#################################Nginx Config###########################################################
mkdir -p /root/cert/${domain}
chmod 755 /root/cert/*

ln -s /etc/letsencrypt/live/${domain}/fullchain.pem /root/cert/${domain}/fullchain.pem
ln -s /etc/letsencrypt/live/${domain}/privkey.pem /root/cert/${domain}/privkey.pem

mkdir -p /etc/nginx/stream-enabled
cat > "/etc/nginx/stream-enabled/stream.conf" << EOF
map \$ssl_preread_server_name \$sni_name {
    hostnames;
    ${reality_domain}      xray;
    ${domain}           www;
    default              xray;
}

upstream xray {
    server 127.0.0.1:8443;
}

upstream www {
    server 127.0.0.1:7443;
}

server {
    proxy_protocol on;
    set_real_ip_from unix:;
    listen          443;
	listen         [::]:443;
    proxy_pass      \$sni_name;
    ssl_preread     on;
}

EOF

grep -xqFR "stream { include /etc/nginx/stream-enabled/*.conf; }" /etc/nginx/* ||echo "stream { include /etc/nginx/stream-enabled/*.conf; }" >> /etc/nginx/nginx.conf
grep -xqFR "load_module modules/ngx_stream_module.so;" /etc/nginx/* || sed -i '1s/^/load_module \/usr\/lib\/nginx\/modules\/ngx_stream_module.so; /' /etc/nginx/nginx.conf
grep -xqFR "worker_rlimit_nofile 16384;" /etc/nginx/* ||echo "worker_rlimit_nofile 16384;" >> /etc/nginx/nginx.conf
sed -i "/worker_connections/c\worker_connections 4096;" /etc/nginx/nginx.conf
cat > "/etc/nginx/sites-available/${domain}" << EOF
server {
	server_tokens off;
	server_name ${domain};
	listen 7443 ssl http2 proxy_protocol;
	listen [::]:7443 ssl http2 proxy_protocol;
	index index.html index.htm index.php index.nginx-debian.html;
	root /var/www/x-ui-pro/;
	ssl_protocols TLSv1.2 TLSv1.3;
	ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
	ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
	ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
	if (\$host !~* ^(.+\.)?$domain\$ ){return 444;}
	if (\$scheme ~* https) {set \$safe 1;}
	if (\$ssl_server_name !~* ^(.+\.)?$domain\$ ) {set \$safe "\${safe}0"; }
	if (\$safe = 10){return 444;}
	if (\$request_uri ~ "(\"|'|\`|~|,|:|;|%|\\$|&&|\?\?|0x00|0X00|\||\\|\{|\}|\[|\]|<|>|\.\.\.|\.\.\/|\/\/\/)"){set \$hack 1;}
	error_page 400 401 402 403 500 501 502 503 504 =404 /404;
	proxy_intercept_errors on;
	#X-UI Admin Panel
	location /${panel_path}/ {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Upgrade websocket;
        proxy_set_header Connection Upgrade;		
        proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        proxy_pass https://127.0.0.1:${panel_port};
		break;
	}
        location /${panel_path} {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Upgrade websocket;
        proxy_set_header Connection Upgrade;		
        proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        proxy_pass https://127.0.0.1:${panel_port};
		break;
	}
	include /etc/nginx/snippets/includes.conf;

}
EOF

cat > "/etc/nginx/snippets/includes.conf" << EOF
        proxy_ssl_server_name on;
        proxy_ssl_name $domain;
        proxy_ssl_verify on;
        proxy_ssl_verify_depth 3;
        proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;

  	#sub2sing-box
	location /${sub2singbox_path}/ {
		proxy_redirect off;
		proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$remote_addr;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_pass http://127.0.0.1:8080/;
		}
    # Path to open clash.yaml and generate YAML
    location ~ ^/${web_path}/clashmeta/(.+)$ {
        default_type text/plain;
        ssi on;
        ssi_types text/plain;
        set \$subid \$1;
        root /var/www/subpage;
        try_files /clash.yaml =404;
    }
    # web
    location ~ ^/${web_path} {
        root /var/www/subpage;
        index index.html;
        try_files \$uri \$uri/ /index.html =404;
    }
 	#Subscription Path (simple/encode)
        location /${sub_path} {
                if (\$hack = 1) {return 404;}
                proxy_redirect off;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_pass https://127.0.0.1:${sub_port};
                break;
        }
	location ^~ /${sub_path}/ {
                if (\$hack = 1) {return 404;}
                proxy_redirect off;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_pass https://127.0.0.1:${sub_port};
                break;
        }
	location /assets/ {
                if (\$hack = 1) {return 404;}
                proxy_redirect off;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_pass https://127.0.0.1:${sub_port};
                break;
        }
	location /assets {
                if (\$hack = 1) {return 404;}
                proxy_redirect off;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_pass https://127.0.0.1:${sub_port};
                break;
        }
	#Subscription Path (json/fragment)
        location /${json_path} {
                if (\$hack = 1) {return 404;}
                proxy_redirect off;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_pass https://127.0.0.1:${sub_port};
                break;
        }
	location ^~ /${json_path}/ {
                if (\$hack = 1) {return 404;}
                proxy_redirect off;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_pass https://127.0.0.1:${sub_port};
                break;
        }
        #XHTTP
        location /${xhttp_path} {
          grpc_pass grpc://unix:/dev/shm/uds2023.sock;
          grpc_buffer_size         16k;
          grpc_socket_keepalive    on;
          grpc_read_timeout        1h;
          grpc_send_timeout        1h;
          grpc_set_header Connection         "";
          grpc_set_header X-Forwarded-For    \$proxy_add_x_forwarded_for;
          grpc_set_header X-Forwarded-Proto  \$scheme;
          grpc_set_header X-Forwarded-Port   \$server_port;
          grpc_set_header Host               \$host;
          grpc_set_header X-Forwarded-Host   \$host;
          }
 	#Xray Config Path
	location ~ ^/(?<fwdport>${ws_port}|${trojan_port})/(?<fwdpath>.*)\$ {
		if (\$hack = 1) {return 404;}
		client_max_body_size 0;
		client_body_timeout 1d;
		grpc_read_timeout 1d;
		grpc_socket_keepalive on;
		proxy_read_timeout 1d;
		proxy_http_version 1.1;
		proxy_buffering off;
		proxy_request_buffering off;
		proxy_socket_keepalive on;
		proxy_set_header Upgrade \$http_upgrade;
		proxy_set_header Connection "upgrade";
		proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$remote_addr;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		#proxy_set_header CF-IPCountry \$http_cf_ipcountry;
		#proxy_set_header CF-IP \$realip_remote_addr;
		if (\$content_type ~* "GRPC") {
			grpc_pass grpc://127.0.0.1:\$fwdport;
			break;
		}
		if (\$http_upgrade ~* "(WEBSOCKET|WS)") {
			proxy_pass http://127.0.0.1:\$fwdport;
			break;
	        }
		if (\$request_method ~* ^(PUT|POST|GET)\$) {
			proxy_pass http://127.0.0.1:\$fwdport;
			break;
		}
	}
	location / { try_files \$uri \$uri/ =404; }
EOF

cat > "/etc/nginx/sites-available/${reality_domain}" << EOF
server {
	server_tokens off;
	server_name ${reality_domain};
	listen 9443 ssl http2;
	listen [::]:9443 ssl http2;
	index index.html index.htm index.php index.nginx-debian.html;
	root /var/www/x-ui-pro/;
	ssl_protocols TLSv1.2 TLSv1.3;
	ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
	ssl_certificate /etc/letsencrypt/live/$reality_domain/fullchain.pem;
	ssl_certificate_key /etc/letsencrypt/live/$reality_domain/privkey.pem;
	if (\$host !~* ^(.+\.)?${reality_domain}\$ ){return 444;}
	if (\$scheme ~* https) {set \$safe 1;}
	if (\$ssl_server_name !~* ^(.+\.)?${reality_domain}\$ ) {set \$safe "\${safe}0"; }
	if (\$safe = 10){return 444;}
	if (\$request_uri ~ "(\"|'|\`|~|,|:|;|%|\\$|&&|\?\?|0x00|0X00|\||\\|\{|\}|\[|\]|<|>|\.\.\.|\.\.\/|\/\/\/)"){set \$hack 1;}
	error_page 400 401 402 403 500 501 502 503 504 =404 /404;
	proxy_intercept_errors on;
	#X-UI Admin Panel
	location /${panel_path}/ {
		proxy_redirect off;
		proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$remote_addr;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_pass https://127.0.0.1:${panel_port};
		break;
	}
        location /$panel_path {
		proxy_redirect off;
		proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$remote_addr;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_pass https://127.0.0.1:${panel_port};
		break;
	}
include /etc/nginx/snippets/includes.conf;
}
EOF
##################################Check Nginx status####################################################
if [[ -f "/etc/nginx/sites-available/${domain}" ]]; then
	unlink "/etc/nginx/sites-enabled/default" >/dev/null 2>&1
	rm -f "/etc/nginx/sites-enabled/default" "/etc/nginx/sites-available/default"
	ln -s "/etc/nginx/sites-available/${domain}" "/etc/nginx/sites-enabled/" 2>/dev/null
        ln -s "/etc/nginx/sites-available/${reality_domain}" "/etc/nginx/sites-enabled/" 2>/dev/null
else
	msg_err "${domain} nginx config not exist!" && exit 1
fi

nginx -t || fail "Could not validate the Nginx configuration."
systemctl reload nginx || fail "Could not load the Nginx configuration."


##############################generate uri's###########################################################
sub_uri=https://${domain}/${sub_path}/
json_uri=https://${domain}/${json_path}/
##############################generate keys###########################################################
shor=($(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8))

########################################Update X-UI Port/Path for first INSTALL#########################
UPDATE_XUIDB(){
if [[ -f $XUIDB ]]; then
        output=$(/usr/local/x-ui/bin/xray-linux-$(arch) x25519) || fail "Xray key generation failed."

        private_key=$(echo "$output" | grep "^PrivateKey:" | awk '{print $2}')
        public_key=$(echo "$output" | awk -F ': *' '/^(Password( \(PublicKey\))?|PublicKey):/ {print $2; exit}')

        [[ -n $private_key && -n $public_key ]] || fail "Invalid Xray key output."
	trojan_pass=$(gen_random_string 10)
        emoji_flag=$(LC_ALL=en_US.UTF-8 curl -s https://ipwho.is/ | jq -r '.flag.emoji')
        sqlite3 -bail "$XUIDB" <<EOF || fail "Could not write initial 3x-ui settings."
BEGIN IMMEDIATE;
DELETE FROM settings WHERE key IN ('subPort','subListen','subPath','subURI',
    'subJsonEnable','subJsonPath','subJsonURI','subClashEnable','subEnable',
    'subDomain','subCertFile','subKeyFile','subEncrypt','webListen','webDomain',
    'webCertFile','webKeyFile');
             INSERT INTO "settings" ("key", "value") VALUES ("subListen", '127.0.0.1'), ("subJsonEnable", 'true');
             INSERT INTO "settings" ("key", "value") VALUES ("subPort",  '${sub_port}');
	     INSERT INTO "settings" ("key", "value") VALUES ("subPath",  '/${sub_path}/');
	     INSERT INTO "settings" ("key", "value") VALUES ("subURI",  '${sub_uri}');
             INSERT INTO "settings" ("key", "value") VALUES ("subJsonPath",  '/${json_path}/');
	     INSERT INTO "settings" ("key", "value") VALUES ("subJsonURI",  '${json_uri}');
		 INSERT INTO "settings" ("key", "value") VALUES ("subClashEnable",  'false');
		 INSERT INTO "settings" ("key", "value") VALUES ("subEnableRouting",  'false');
             INSERT INTO "settings" ("key", "value") VALUES ("subEnable",  'true');
             INSERT INTO "settings" ("key", "value") VALUES ("webListen",  '127.0.0.1');
	     INSERT INTO "settings" ("key", "value") VALUES ("webDomain",  '');
             INSERT INTO "settings" ("key", "value") VALUES ("webCertFile",  '');
	     INSERT INTO "settings" ("key", "value") VALUES ("webKeyFile",  '');
      	     INSERT INTO "settings" ("key", "value") VALUES ("sessionMaxAge",  '60');
             INSERT INTO "settings" ("key", "value") VALUES ("pageSize",  '50');
             INSERT INTO "settings" ("key", "value") VALUES ("expireDiff",  '0');
             INSERT INTO "settings" ("key", "value") VALUES ("trafficDiff",  '0');
             INSERT INTO "settings" ("key", "value") VALUES ("remarkModel",  '-ieo');
             INSERT INTO "settings" ("key", "value") VALUES ("tgBotEnable",  'false');
             INSERT INTO "settings" ("key", "value") VALUES ("tgBotToken",  '');
             INSERT INTO "settings" ("key", "value") VALUES ("tgBotProxy",  '');
             INSERT INTO "settings" ("key", "value") VALUES ("tgBotAPIServer",  '');
	     INSERT INTO "settings" ("key", "value") VALUES ("tgBotChatId",  '');
             INSERT INTO "settings" ("key", "value") VALUES ("tgRunTime",  '@daily');
	     INSERT INTO "settings" ("key", "value") VALUES ("tgBotBackup",  'false');
             INSERT INTO "settings" ("key", "value") VALUES ("tgBotLoginNotify",  'true');
	     INSERT INTO "settings" ("key", "value") VALUES ("tgCpu",  '80');
             INSERT INTO "settings" ("key", "value") VALUES ("tgLang",  'en-US');
	     INSERT INTO "settings" ("key", "value") VALUES ("timeLocation",  'Europe/Moscow');
             INSERT INTO "settings" ("key", "value") VALUES ("secretEnable",  'false');
	     INSERT INTO "settings" ("key", "value") VALUES ("subDomain",  '');
             INSERT INTO "settings" ("key", "value") VALUES ("subCertFile",  '/etc/letsencrypt/live/$domain/fullchain.pem');
	     INSERT INTO "settings" ("key", "value") VALUES ("subKeyFile",  '/etc/letsencrypt/live/$domain/privkey.pem');
             INSERT INTO "settings" ("key", "value") VALUES ("subUpdates",  '12');
	     INSERT INTO "settings" ("key", "value") VALUES ("subEncrypt",  'true');
             INSERT INTO "settings" ("key", "value") VALUES ("subShowInfo",  'true');
	     INSERT INTO "settings" ("key", "value") VALUES ("subJsonFragment",  '');
             INSERT INTO "settings" ("key", "value") VALUES ("subJsonNoises",  '');
	     INSERT INTO "settings" ("key", "value") VALUES ("subJsonMux",  '');
             INSERT INTO "settings" ("key", "value") VALUES ("subJsonRules",  '');
	     INSERT INTO "settings" ("key", "value") VALUES ("datepicker",  'gregorian');
             INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
             '1',
	     '0',
             '0',
	     '0',
             '${emoji_flag} reality',
	     '1',
             '0',
	     '',
             '8443',
	     'vless',
             '{
	     "clients": [

  ],
  "decryption": "none",
  "fallbacks": []
}',
	     '{
  "network": "tcp",
  "security": "reality",
  "externalProxy": [
    {
      "forceTls": "same",
      "dest": "${domain}",
      "port": 443,
      "remark": ""
    }
  ],
  "realitySettings": {
    "show": false,
    "xver": 0,
    "target": "127.0.0.1:9443",
    "serverNames": [
      "$reality_domain"
    ],
    "privateKey": "${private_key}",
    "minClient": "",
    "maxClient": "",
    "maxTimediff": 0,
    "shortIds": [
      "${shor[0]}",
      "${shor[1]}",
      "${shor[2]}",
      "${shor[3]}",
      "${shor[4]}",
      "${shor[5]}",
      "${shor[6]}",
      "${shor[7]}"
    ],
    "settings": {
      "publicKey": "${public_key}",
      "fingerprint": "chrome",
      "serverName": "",
      "spiderX": "/"
    }
  },
  "tcpSettings": {
    "acceptProxyProtocol": true,
    "header": {
      "type": "none"
    }
  }
}',
             'inbound-8443',
	     '{
  "enabled": false,
  "destOverride": [
    "http",
    "tls",
    "quic",
    "fakedns"
  ],
  "metadataOnly": false,
  "routeOnly": false
}'
	     );
      INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
             '1',
	     '0',
             '0',
	     '0',
             '${emoji_flag} ws',
	     '1',
             '0',
	     '',
             '${ws_port}',
	     'vless',
             '{
  "clients": [
  ],
  "decryption": "none",
  "fallbacks": []
}','{
  "network": "ws",
  "security": "none",
  "externalProxy": [
    {
      "forceTls": "tls",
      "dest": "${domain}",
      "port": 443,
      "remark": ""
    }
  ],
  "wsSettings": {
    "acceptProxyProtocol": false,
    "path": "/${ws_port}/${ws_path}",
    "host": "${domain}",
    "headers": {}
  }
}',
             'inbound-${ws_port}',
	     '{
  "enabled": false,
  "destOverride": [
    "http",
    "tls",
    "quic",
    "fakedns"
  ],
  "metadataOnly": false,
  "routeOnly": false
}'
	     );
      INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
             '1',
	     '0',
             '0',
	     '0',
             '${emoji_flag} xhttp',
	     '0',
             '0',
	     '/dev/shm/uds2023.sock,0666',
             '0',
	     'vless',
             '{
  "clients": [
  ],
  "decryption": "none",
  "fallbacks": []
}','{
  "network": "xhttp",
  "security": "none",
  "externalProxy": [
    {
      "forceTls": "tls",
      "dest": "${domain}",
      "port": 443,
      "remark": ""
    }
  ],
  "xhttpSettings": {
    "path": "/${xhttp_path}",
    "host": "${domain}",
    "headers": {},
    "scMaxBufferedPosts": 30,
    "scMaxEachPostBytes": "1000000",
    "noSSEHeader": false,
    "xPaddingBytes": "100-1000",
    "mode": "packet-up"
  },
  "sockopt": {
    "acceptProxyProtocol": false,
    "tcpFastOpen": true,
    "mark": 0,
    "tproxy": "off",
    "tcpMptcp": true,
    "tcpNoDelay": true,
    "domainStrategy": "UseIP",
    "tcpMaxSeg": 1440,
    "dialerProxy": "",
    "tcpKeepAliveInterval": 0,
    "tcpKeepAliveIdle": 300,
    "tcpUserTimeout": 10000,
    "tcpcongestion": "bbr",
    "V6Only": false,
    "tcpWindowClamp": 600,
    "interface": ""
  }
}',
             'inbound-/dev/shm/uds2023.sock,0666:0|',
	     '{
  "enabled": true,
  "destOverride": [
    "http",
    "tls",
    "quic",
    "fakedns"
  ],
  "metadataOnly": false,
  "routeOnly": false
}'
	     );
	INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
	     '1',
	     '0',
         '0',
	     '0',
         '${emoji_flag} trojan-grpc',
	     '1',
         '0',
		 '',
		 '${trojan_port}',
		 'trojan',
		 '{
  "clients": [
  ],
  "fallbacks": []
}',
'{
  "network": "grpc",
  "security": "none",
  "externalProxy": [
    {
      "forceTls": "tls",
      "dest": "${domain}",
      "port": 443,
      "remark": ""
    }
  ],
  "grpcSettings": {
    "serviceName": "/${trojan_port}/${trojan_path}",
    "authority": "${domain}",
    "multiMode": false
  }
}',
'inbound-${trojan_port}',
'{
  "enabled": false,
  "destOverride": [
    "http",
    "tls",
    "quic",
    "fakedns"
  ],
  "metadataOnly": false,
  "routeOnly": false
}'
	);
COMMIT;
EOF
else
	msg_err "x-ui.db file not exist! Maybe x-ui isn't installed." && exit 1;
fi
}
arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86) echo '386' ;;
        armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
        armv7* | armv7 | arm) echo 'armv7' ;;
        armv6* | armv6) echo 'armv6' ;;
        armv5* | armv5) echo 'armv5' ;;
        s390x) echo 's390x' ;;
        *) echo -e "${green}Unsupported CPU architecture! ${plain}" && rm -f install.sh && exit 1 ;;
    esac
}

install_panel() {
    local asset="x-ui-linux-$(arch).tar.gz"
    local base="https://github.com/MHSanaei/3x-ui/releases/download/$panel_version"
    local stage expected actual
    stage=$(mktemp -d) || fail "Could not create download directory."
    curl -fsSL --retry 3 "$base/$asset" -o "$stage/$asset" &&
        curl -fsSL --retry 3 "$base/$asset.sha256" -o "$stage/checksum" ||
        fail "Could not download 3x-ui $panel_version and its checksum."
    expected=$(awk 'NR==1 {print $1}' "$stage/checksum")
    actual=$(sha256sum "$stage/$asset" | awk '{print $1}')
    [[ $expected =~ ^[[:xdigit:]]{64}$ && $expected == "$actual" ]] ||
        fail "3x-ui archive checksum mismatch."
    tar -xzf "$stage/$asset" -C /usr/local/ || fail "Could not extract 3x-ui."
    rm -f "$stage/$asset" "$stage/checksum"
    rmdir "$stage"
    install -m 0755 /usr/local/x-ui/x-ui.sh /usr/bin/x-ui ||
        fail "Could not install x-ui management command."
    install -m 0644 /usr/local/x-ui/x-ui.service.debian /etc/systemd/system/x-ui.service ||
        fail "Could not install x-ui service."
    /usr/local/x-ui/x-ui setting -username "$config_username" -password "$config_password" \
        -port "$panel_port" -webBasePath "$panel_path" || fail "Could not initialize the panel."
    UPDATE_XUIDB
    /usr/local/x-ui/x-ui cert -webCert "/etc/letsencrypt/live/$domain/fullchain.pem" \
        -webCertKey "/etc/letsencrypt/live/$domain/privkey.pem" ||
        fail "Could not configure the panel certificate."
    systemctl daemon-reload && systemctl enable --now x-ui ||
        fail "Could not start the panel."
}

install_panel
if [[ $hy2_enabled == yes ]]; then
    hy2_panel_url="https://$domain:$panel_port/$panel_path"
    hy2_resolve=(--resolve "$domain:$panel_port:127.0.0.1")
    hy2_username=$config_username
    hy2_password=$config_password
    hy2_result=$(add_hy2) || exit 1
    hy2_sub_id=$(printf '%s\n' "$hy2_result" | head -n1)
    hy2_link=$(printf '%s\n' "$hy2_result" | tail -n1)
fi
enable_db_backups

######################enable bbr and tune system########################################################
if [[ $skip_sysctl == no ]]; then
    echo "net.core.default_qdisc=fq" | tee -a /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" | tee -a /etc/sysctl.conf
    echo "fs.file-max=2097152" | tee -a /etc/sysctl.conf
    echo "net.ipv4.tcp_timestamps = 1" | tee -a /etc/sysctl.conf
    echo "net.ipv4.tcp_sack = 1" | tee -a /etc/sysctl.conf
    echo "net.ipv4.tcp_window_scaling = 1" | tee -a /etc/sysctl.conf
    echo "net.core.rmem_max = 16777216" | tee -a /etc/sysctl.conf
    echo "net.core.wmem_max = 16777216" | tee -a /etc/sysctl.conf
    echo "net.ipv4.tcp_rmem = 4096 87380 16777216" | tee -a /etc/sysctl.conf
    echo "net.ipv4.tcp_wmem = 4096 65536 16777216" | tee -a /etc/sysctl.conf

    sysctl -p
fi


######################install_sub2sing-box#################################################################

if pgrep -x "sub2sing-box" > /dev/null; then
    echo "kill sub2sing-box..."
    pkill -x "sub2sing-box"
fi
if [ -f "/usr/bin/sub2sing-box" ]; then
    echo "delete sub2sing-box..."
    rm -f /usr/bin/sub2sing-box
fi
wget -P /root/ https://github.com/legiz-ru/sub2sing-box/releases/download/v0.0.9/sub2sing-box_0.0.9_linux_amd64.tar.gz
tar -xvzf /root/sub2sing-box_0.0.9_linux_amd64.tar.gz -C /root/ --strip-components=1 sub2sing-box_0.0.9_linux_amd64/sub2sing-box
mv /root/sub2sing-box /usr/bin/
chmod +x /usr/bin/sub2sing-box
rm /root/sub2sing-box_0.0.9_linux_amd64.tar.gz
su -c "/usr/bin/sub2sing-box server --bind 127.0.0.1 --port 8080 & disown" root

######################install_fake_site#################################################################

FAKE_SITE_TMP=$(mktemp -d)
if wget -qO "$FAKE_SITE_TMP/repo.tar.gz" "https://github.com/mozaroc/3x-ui-pro/archive/refs/heads/main.tar.gz" \
	&& tar -xzf "$FAKE_SITE_TMP/repo.tar.gz" -C "$FAKE_SITE_TMP" --strip-components=3 "3x-ui-pro-main/assets/fake-sites"; then
	FAKE_SITES=("$FAKE_SITE_TMP"/site-*/)
	FAKE_SITE="${FAKE_SITES[$((RANDOM % ${#FAKE_SITES[@]}))]}"
	msg_inf "Random fake site template: $(basename "$FAKE_SITE")"
	mkdir -p /var/www/x-ui-pro
	cp -a "$FAKE_SITE". /var/www/x-ui-pro/
	msg_ok "Fake site installed successfully!"
else
	msg_err "Failed to download fake site templates!"
fi
rm -rf "$FAKE_SITE_TMP"

######################install_web_sub_page##############################################################

URL_SUB_PAGE=( "https://github.com/legiz-ru/x-ui-pro/raw/master/sub-3x-ui.html"
		"https://github.com/legiz-ru/x-ui-pro/raw/master/sub-3x-ui-classical.html"
	)
URL_CLASH_SUB=( "https://github.com/legiz-ru/x-ui-pro/raw/master/clash/clash.yaml"
		"https://github.com/legiz-ru/x-ui-pro/raw/master/clash/clash_skrepysh.yaml"
		"https://github.com/legiz-ru/x-ui-pro/raw/master/clash/clash_fullproxy_without_ru.yaml"
  		"https://github.com/legiz-ru/x-ui-pro/raw/master/clash/clash_refilter_ech.yaml"
	)
DEST_DIR_SUB_PAGE="/var/www/subpage"
DEST_FILE_SUB_PAGE="$DEST_DIR_SUB_PAGE/index.html"
DEST_FILE_CLASH_SUB="$DEST_DIR_SUB_PAGE/clash.yaml"

sudo mkdir -p "$DEST_DIR_SUB_PAGE"

curl -fsSL "${URL_CLASH_SUB[$CLASH]}" -o "$DEST_FILE_CLASH_SUB" || fail "Could not download the Clash subscription template."
curl -fsSL "${URL_SUB_PAGE[$CUSTOMWEBSUB]}" -o "$DEST_FILE_SUB_PAGE" || fail "Could not download the subscription page."

sed -i "s/\${DOMAIN}/$domain/g" "$DEST_FILE_SUB_PAGE"
sed -i "s/\${DOMAIN}/$domain/g" "$DEST_FILE_CLASH_SUB"
sed -i "s#\${SUB_JSON_PATH}#$json_path#g" "$DEST_FILE_SUB_PAGE"
sed -i "s#\${SUB_PATH}#$sub_path#g" "$DEST_FILE_SUB_PAGE"
sed -i "s#\${SUB_PATH}#$sub_path#g" "$DEST_FILE_CLASH_SUB"
sed -i "s|sub.legiz.ru|$domain/$sub2singbox_path|g" "$DEST_FILE_SUB_PAGE"

#while true; do	
#	if [[ -n "$tg_escaped_link" ]]; then
#		break
#	fi
#	echo -en "Enter your support link for web sub page (example https://t.me/durov/ ): " && read tg_escaped_link
#done

#sed -i -e "s|https://t.me/gozargah_marzban|$tg_escaped_link|g" -e "s|https://github.com/Gozargah/Marzban#donation|$tg_escaped_link|g" "$DEST_FILE_SUB_PAGE"

######################cronjob for ssl/reload service/cloudflareips######################################
install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/x-ui-pro <<'CERTBOT_HOOK'
#!/bin/sh
systemctl reload nginx
systemctl restart x-ui
CERTBOT_HOOK
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/x-ui-pro
existing_crontab=$(crontab -l 2>/dev/null || :)
if ! grep -Fq '/usr/bin/sub2sing-box server' <<<"$existing_crontab"; then
    { printf '%s\n' "$existing_crontab"; printf '%s\n' '@reboot /usr/bin/sub2sing-box server --bind 127.0.0.1 --port 8080 > /dev/null 2>&1'; } | crontab -
fi
##################################ufw###################################################################
if [[ $skip_ufw == no ]]; then
    ufw_udp_port=443
    [[ $hy2_enabled == no ]] || ufw_udp_port=$hy2_port
    ufw allow 22/tcp && ufw allow 80/tcp && ufw allow 443/tcp &&
        ufw allow "$ufw_udp_port/udp" && ufw --force enable ||
        fail "Could not configure UFW."
fi
if [[ $hy2_enabled == yes ]]; then
    verify_subscriptions
fi
##################################Show Details##########################################################

if systemctl is-active --quiet x-ui; then
	printf '0\n' | x-ui | grep --color=never -i ':'
	msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
	nginx -T | grep -i 'ssl_certificate\|ssl_certificate_key'
	msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
	certbot certificates | grep -i 'Path:\|Domains:\|Expiry Date:'

#	msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
#	if [[ -n $IP4 ]] && [[ "$IP4" =~ $IP4_REGEX ]]; then 
#		msg_inf "IPv4: http://$IP4:$PORT/$RNDSTR/"
#	fi
#	if [[ -n $IP6 ]] && [[ "$IP6" =~ $IP6_REGEX ]]; then 
#		msg_inf "IPv6: http://[$IP6]:$PORT/$RNDSTR/"
#	fi

 msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
	msg_inf "X-UI Secure Panel: https://${domain}/${panel_path}/\n"
 	echo -e "Username:  ${config_username} \n" 
	echo -e "Password:  ${config_password} \n" 
	msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
    if [[ $hy2_enabled == yes ]]; then
        printf 'Web subscription page: %s\n' "https://${domain}/${web_path}?name=${hy2_sub_id}"
        printf 'Hysteria 2: %s\n' "$hy2_link"
    else
        printf 'Web subscription page: %s\n' "https://${domain}/${web_path}?name=<subId>"
    fi
    msg_inf "Your local sub2sing-box instance: https://${domain}/$sub2singbox_path/\n"
  msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
	msg_inf "Please Save this Screen!!"	
else
	nginx -t && printf '0\n' | x-ui | grep --color=never -i ':'
	msg_err "sqlite and x-ui to be checked, try on a new clean linux! "
fi
#################################################N-joy##################################################

