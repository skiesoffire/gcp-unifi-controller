#! /bin/bash
# shellcheck disable=SC2086,SC2154


# Version 2.0.0
# This is a startup script for UniFi Controller on Debian based Google Compute Engine instances.
# For instructions and how-to:  https://metis.fi/en/2018/02/unifi-on-gcp/
# For comments and code walkthrough:  https://metis.fi/en/2018/02/gcp-unifi-code/
#
# You may use this as you see fit as long as I am credited for my work.
# (c) 2018-2021 Petri Riihikallio Metis Oy

###########################################################
#
# Set up logging for unattended scripts and UniFi's MongoDB log
# Variables $LOG and $MONGOLOG are used later on in the script.
#
LOG="/var/log/unifi/gcp-unifi.log"
if [ ! -f /etc/logrotate.d/gcp-unifi.conf ]; then
	cat > /etc/logrotate.d/gcp-unifi.conf <<_EOF
$LOG {
	monthly
	rotate 4
	compress
}
_EOF
	echo "Script logrotate set up"
fi

MONGOLOG="/usr/lib/unifi/logs/mongod.log"
if [ ! -f /etc/logrotate.d/unifi-mongod.conf ]; then
	cat > /etc/logrotate.d/unifi-mongod.conf <<_EOF
$MONGOLOG {
	weekly
	rotate 10
	copytruncate
	delaycompress
	compress
	notifempty
	missingok
}
_EOF
	echo "MongoDB logrotate set up"
fi

###########################################################
#
# Turn off IPv6 for now
#
if [ ! -f /etc/sysctl.d/20-disableIPv6.conf ]; then
	echo "net.ipv6.conf.all.disable_ipv6=1" > /etc/sysctl.d/20-disableIPv6.conf
	sysctl --system > /dev/null
	echo "IPv6 disabled"
fi

###########################################################
#
# Update DynDNS as early in the script as possible
#
ddns=$(curl -fs -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/ddns-url")
if [ ${ddns} ]; then
	curl -fs ${ddns}
	echo "Dynamic DNS accessed"
fi
###########################################################
#
# Create the config.gateway.json using version stored in bucket.
# Checks gateway-json-url key for gcp storage url
#
gatewayjsonurl=$(curl -fs -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/gateway-json-url")
if [ ${gatewayjsonurl} ]; then
	# ensure data/sites/default directory exists, if not create it.
	mkdir -p /usr/lib/unifi/data/sites/default
	# copy json from bucket
	gsutil cp ${gatewayjsonurl} /usr/lib/unifi/data/sites/default/config.gateway.json
	# ensure correct permissions
	chown -R unifi:unifi /usr/lib/unifi/data/sites/default/config.gateway.json
	echo "config.gateway.json file has been staged."
fi
###########################################################
#
# Create a swap file for small memory instances and increase /run
#
if [ ! -f /swapfile ]; then
	memory=$(free -m | grep "^Mem:" | tr -s " " | cut -d " " -f 2)
	echo "${memory} megabytes of memory detected"
	if [ -z ${memory} ] || [ "0${memory}" -lt "2048" ]; then
		fallocate -l 2G /swapfile
		chmod 600 /swapfile
		mkswap /swapfile >/dev/null
		swapon /swapfile
		echo '/swapfile none swap sw 0 0' >> /etc/fstab
		echo 'tmpfs /run tmpfs rw,nodev,nosuid,size=400M 0 0' >> /etc/fstab
		mount -o remount,rw,nodev,nosuid,size=400M tmpfs /run
		echo "Swap file created"
	fi
fi

###########################################################
#
# Install stuff
#

# set to non-interactive debian
export DEBIAN_FRONTEND="noninteractive"

# HAVEGEd is straightforward
haveged=$(dpkg-query -W --showformat='${Status}\n' haveged 2>/dev/null)
if [ "x${haveged}" != "xinstall ok installed" ]; then 
	if apt-get -qq install -y haveged >/dev/null; then
		echo "Haveged installed"
	fi
fi
certbot=$(dpkg-query -W --showformat='${Status}\n' certbot 2>/dev/null)
if [ "x${certbot}" != "xinstall ok installed" ]; then
if (apt-get -qq install -y certbot >/dev/null) || (apt-get -qq install -y certbot >/dev/null); then
		echo "CertBot installed"
	fi
fi

# UniFi needs https support, custom repo and APT update first
apt-get -qq install -y ca-certificates apt-transport-https >/dev/null
unifi=$(dpkg-query -W --showformat='${Status}\n' unifi 2>/dev/null)
if [ "x${unifi}" != "xinstall ok installed" ]; then
	#Unifi repo
	echo "deb http://www.ubnt.com/downloads/unifi/debian stable ubiquiti" > /etc/apt/sources.list.d/unifi.list
	curl -Lfs -o /etc/apt/trusted.gpg.d/unifi-repo.gpg https://dl.ubnt.com/unifi/unifi-repo.gpg

	#Mongo3.6 repo
	echo "deb http://repo.mongodb.org/apt/debian stretch/mongodb-org/3.6 main" > /etc/apt/sources.list.d/mongodb-org-3.6.list
	curl -Lfs https://www.mongodb.org/static/pgp/server-3.6.asc | sudo apt-key add -
	
	#Java 8 repo & install (no longer needed. latest unifi supports java 11)
	#curl -fsSL "https://adoptopenjdk.jfrog.io/adoptopenjdk/api/gpg/key/public" | sudo gpg --dearmor --yes -o /usr/share/keyrings/adoptopenjdk-archive-keyring.gpg
	#echo "deb [signed-by=/usr/share/keyrings/adoptopenjdk-archive-keyring.gpg] https://adoptopenjdk.jfrog.io/adoptopenjdk/deb bullseye main" | sudo tee /etc/apt/sources.list.d/adoptopenjdk.list
       	#apt-get -qq install -y adoptopenjdk-8-hotspot >/dev/null
	
	apt-get -qq update -y >/dev/null
	if apt-get -qq install -y unifi >/dev/null; then
		echo "Unifi installed"
	fi
	systemctl stop mongodb
	systemctl disable mongodb
fi

# Lighttpd needs a config file and a reload
httpd=$(dpkg-query -W --showformat='${Status}\n' lighttpd 2>/dev/null)
if [ "x${httpd}" != "xinstall ok installed" ]; then
	if apt-get -qq install -y lighttpd >/dev/null; then
		cat > /etc/lighttpd/conf-enabled/10-unifi-redirect.conf <<_EOF
\$HTTP["scheme"] == "http" {
    \$HTTP["host"] =~ ".*" {
        url.redirect = (".*" => "https://%0:8443")
    }
}
_EOF
		systemctl reload-or-restart lighttpd
		echo "Lighttpd installed"
	fi
fi

# Fail2Ban needs three files and a reload
f2b=$(dpkg-query -W --showformat='${Status}\n' fail2ban 2>/dev/null)
if [ "x${f2b}" != "xinstall ok installed" ]; then 
	if apt-get -qq install -y fail2ban >/dev/null; then
			echo "Fail2Ban installed"
	fi
	if [ ! -f /etc/fail2ban/filter.d/unifi-controller.conf ]; then
		cat > /etc/fail2ban/filter.d/unifi-controller.conf <<_EOF
[Definition]
failregex = ^.* Failed .* login for .* from <HOST>\s*$
_EOF
		cat > /etc/fail2ban/jail.d/unifi-controller.conf <<_EOF
[unifi-controller]
filter   = unifi-controller
port     = 8443
logpath  = /var/log/unifi/server.log
_EOF
	fi
	# The .local file will be installed in any case
	cat > /etc/fail2ban/jail.d/unifi-controller.local <<_EOF
[unifi-controller]
enabled  = true
maxretry = 3
bantime  = 3600
findtime = 3600
_EOF
	systemctl reload-or-restart fail2ban
fi

###########################################################
#
# APT maintenance (runs only at reboot)
#
apt-get -qq autoremove --purge
apt-get -qq clean
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

###########################################################
#
# Set the time zone
#
tz=$(curl -fs -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/timezone")
if [ ${tz} ] && [ -f /usr/share/zoneinfo/${tz} ]; then
	apt-get -qq install -y dbus >/dev/null
	if ! systemctl start dbus; then
		echo "Trying to start dbus"
		sleep 15
		systemctl start dbus
	fi
	if timedatectl set-timezone $tz; then echo "Localtime set to ${tz}"; fi
	systemctl reload-or-restart rsyslog
fi

###########################################################
#
# Set up automatic repair for broken MongoDB on boot
#
if [ ! -f /usr/local/sbin/unifidb-repair.sh ]; then
	cat > /usr/local/sbin/unifidb-repair.sh <<_EOF
#! /bin/sh
if ! pgrep mongod; then
	if [ -f /var/lib/unifi/db/mongod.lock ] \
	|| [ -f /var/lib/unifi/db/WiredTiger.lock ] \
	|| [ -f /var/run/unifi/db.needsRepair ] \
	|| [ -f /var/run/unifi/launcher.looping ]; then
		if [ -f /var/lib/unifi/db/mongod.lock ]; then rm -f /var/lib/unifi/db/mongod.lock; fi
		if [ -f /var/lib/unifi/db/WiredTiger.lock ]; then rm -f /var/lib/unifi/db/WiredTiger.lock; fi
		if [ -f /var/run/unifi/db.needsRepair ]; then rm -f /var/run/unifi/db.needsRepair; fi
		if [ -f /var/run/unifi/launcher.looping ]; then rm -f /var/run/unifi/launcher.looping; fi
		echo >> $LOG
		echo "Repairing Unifi DB on \$(date)" >> $LOG
		su -c "/usr/bin/mongod --repair --dbpath /var/lib/unifi/db --smallfiles --logappend --logpath ${MONGOLOG} 2>>$LOG" unifi
	fi
else
	echo "MongoDB is running. Exiting..."
	exit 1
fi
exit 0
_EOF
	chmod a+x /usr/local/sbin/unifidb-repair.sh

#	cat > /etc/systemd/system/unifidb-repair.service <<_EOF
#[Unit]
#Description=Repair UniFi MongoDB database at boot
#Before=unifi.service mongodb.service
#After=network-online.target
#Wants=network-online.target
#[Service]
#Type=oneshot
#ExecStart=/usr/local/sbin/unifidb-repair.sh
#[Install]
#WantedBy=multi-user.target
#_EOF
#	systemctl enable unifidb-repair.service
	echo "Unifi DB autorepair set up"
fi

###########################################################
#
# Set up daily rsync of auto-backup to a bucket after 01:00
#
bucket=$(curl -fs -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/bucket")
if [ ${bucket} ]; then
	cat > /etc/systemd/system/unifi-backup.service <<_EOF
[Unit]
Description=Daily backup to ${bucket} service
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/bin/gsutil -m rsync -r -d /var/lib/unifi/backup gs://$bucket
_EOF

	cat > /etc/systemd/system/unifi-backup.timer <<_EOF
[Unit]
Description=Daily backup to ${bucket} timer
[Timer]
OnCalendar=1:00
RandomizedDelaySec=30m
[Install]
WantedBy=timers.target
_EOF
	systemctl daemon-reload
	systemctl start unifi-backup.timer
	echo "Backups to ${bucket} set up"
fi

# also sync backup files on startup so we can restore from backup on first boot
/usr/bin/gsutil -m rsync -r -d gs://$bucket /var/lib/unifi/backup

###########################################################
#
# Adjust Java heap (advanced setup)
#
# xms=$(curl -fs -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/xms")
# xmx=$(curl -fs -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/xmx")
# if [ ${xms} ] || [ ${xmx} ]; then touch /usr/share/misc/java-heap-adjusted; fi
#
# if [ -e /usr/share/misc/java-heap-adjusted ]; then
#	 if [ "0${xms}" -lt 100 ]; then xms=1024; fi
#	 if grep -e "^\s*unifi.xms=[0-9]" /var/lib/unifi/system.properties >/dev/null; then
#	 	sed -i -e "s/^[[:space:]]*unifi.xms=[[:digit:]]\+/unifi.xms=${xms}/" /var/lib/unifi/system.properties
#	 else
#	 	echo "unifi.xms=${xms}" >>/var/lib/unifi/system.properties
#	 fi
#	 message=" xms=${xms}"
#	 
#	 if [ "0${xmx}" -lt "${xms}" ]; then xmx=${xms}; fi
#	 if grep -e "^\s*unifi.xmx=[0-9]" /var/lib/unifi/system.properties >/dev/null; then
#	 	sed -i -e "s/^[[:space:]]*unifi.xmx=[[:digit:]]\+/unifi.xmx=${xmx}/" /var/lib/unifi/system.properties
#	 else
#	 	echo "unifi.xmx=${xmx}" >>/var/lib/unifi/system.properties
#	 fi
#	 message="${message} xmx=${xmx}"
#	 
#	 if [ -n "${message}" ]; then
#	 	echo "Java heap set to:${message}"
#	 fi
#	 systemctl restart unifi
# fi


###########################################################
#
# Set up Let's Encrypt
#
dnsname=$(curl -fs -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/dns-name")
if [ -z ${dnsname} ]; then exit 0; fi
privkey=/etc/letsencrypt/live/${dnsname}/privkey.pem
pubcrt=/etc/letsencrypt/live/${dnsname}/cert.pem
chain=/etc/letsencrypt/live/${dnsname}/chain.pem
caroot=/usr/share/misc/ca_root.pem

# Write the cross signed root certificate to disk
cat > $caroot <<_EOF
-----BEGIN CERTIFICATE-----
MIIFYDCCA0igAwIBAgIQCgFCgAAAAUUjyES1AAAAAjANBgkqhkiG9w0BAQsFADBK
MQswCQYDVQQGEwJVUzESMBAGA1UEChMJSWRlblRydXN0MScwJQYDVQQDEx5JZGVu
VHJ1c3QgQ29tbWVyY2lhbCBSb290IENBIDEwHhcNMTQwMTE2MTgxMjIzWhcNMzQw
MTE2MTgxMjIzWjBKMQswCQYDVQQGEwJVUzESMBAGA1UEChMJSWRlblRydXN0MScw
JQYDVQQDEx5JZGVuVHJ1c3QgQ29tbWVyY2lhbCBSb290IENBIDEwggIiMA0GCSqG
SIb3DQEBAQUAA4ICDwAwggIKAoICAQCnUBneP5k91DNG8W9RYYKyqU+PZ4ldhNlT
3Qwo2dfw/66VQ3KZ+bVdfIrBQuExUHTRgQ18zZshq0PirK1ehm7zCYofWjK9ouuU
+ehcCuz/mNKvcbO0U59Oh++SvL3sTzIwiEsXXlfEU8L2ApeN2WIrvyQfYo3fw7gp
S0l4PJNgiCL8mdo2yMKi1CxUAGc1bnO/AljwpN3lsKImesrgNqUZFvX9t++uP0D1
bVoE/c40yiTcdCMbXTMTEl3EASX2MN0CXZ/g1Ue9tOsbobtJSdifWwLziuQkkORi
T0/Br4sOdBeo0XKIanoBScy0RnnGF7HamB4HWfp1IYVl3ZBWzvurpWCdxJ35UrCL
vYf5jysjCiN2O/cz4ckA82n5S6LgTrx+kzmEB/dEcH7+B1rlsazRGMzyNeVJSQjK
Vsk9+w8YfYs7wRPCTY/JTw436R+hDmrfYi7LNQZReSzIJTj0+kuniVyc0uMNOYZK
dHzVWYfCP04MXFL0PfdSgvHqo6z9STQaKPNBiDoT7uje/5kdX7rL6B7yuVBgwDHT
c+XvvqDtMwt0viAgxGds8AgDelWAf0ZOlqf0Hj7h9tgJ4TNkK2PXMl6f+cB7D3hv
l7yTmvmcEpB4eoCHFddydJxVdHixuuFucAS6T6C6aMN7/zHwcz09lCqxC0EOoP5N
iGVreTO01wIDAQABo0IwQDAOBgNVHQ8BAf8EBAMCAQYwDwYDVR0TAQH/BAUwAwEB
/zAdBgNVHQ4EFgQU7UQZwNPwBovupHu+QucmVMiONnYwDQYJKoZIhvcNAQELBQAD
ggIBAA2ukDL2pkt8RHYZYR4nKM1eVO8lvOMIkPkp165oCOGUAFjvLi5+U1KMtlwH
6oi6mYtQlNeCgN9hCQCTrQ0U5s7B8jeUeLBfnLOic7iPBZM4zY0+sLj7wM+x8uwt
LRvM7Kqas6pgghstO8OEPVeKlh6cdbjTMM1gCIOQ045U8U1mwF10A0Cj7oV+wh93
nAbowacYXVKV7cndJZ5t+qntozo00Fl72u1Q8zW/7esUTTHHYPTa8Yec4kjixsU3
+wYQ+nVZZjFHKdp2mhzpgq7vmrlR94gjmmmVYjzlVYA211QC//G5Xc7UI2/YRYRK
W2XviQzdFKcgyxilJbQN+QHwotL0AMh0jqEqSI5l2xPE4iUXfeu+h1sXIFRRk0pT
AwvsXcoz7WL9RccvW9xYoIA55vrX/hMUpu09lEpCdNTDd1lzzY9GvlU47/rokTLq
l1gEIt44w8y8bckzOmoKaT+gyOpyj4xjhiO9bTyWnpXgSUyqorkqG5w2gXjtw+hG
4iZZRHUe2XWJUc0QhJ1hYMtd+ZciTY6Y5uN/9lu7rs3KSoFrXgvzUeF0K+l+J6fZ
mUlO+KWA2yUPHGNiiskzZ2s8EIPGrd6ozRaOjfAHN3Gf8qv8QfXBi+wAN10J5U6A
7/qxXDgGpRtK4dw4LTzcqx+QGtVKnO7RcGzM7vRX+Bi6hG6H
-----END CERTIFICATE-----
_EOF

# Write pre and post hooks to stop Lighttpd for the renewal
if [ ! -d /etc/letsencrypt/renewal-hooks/pre ]; then
	mkdir -p /etc/letsencrypt/renewal-hooks/pre
fi
cat > /etc/letsencrypt/renewal-hooks/pre/lighttpd <<_EOF
#! /bin/sh
systemctl stop lighttpd
_EOF
chmod a+x /etc/letsencrypt/renewal-hooks/pre/lighttpd

if [ ! -d /etc/letsencrypt/renewal-hooks/post ]; then
	mkdir -p /etc/letsencrypt/renewal-hooks/post
fi
cat > /etc/letsencrypt/renewal-hooks/post/lighttpd <<_EOF
#! /bin/sh
systemctl start lighttpd
_EOF
chmod a+x /etc/letsencrypt/renewal-hooks/post/lighttpd

# Write the deploy hook to import the cert into Java
if [ ! -d /etc/letsencrypt/renewal-hooks/deploy ]; then
	mkdir -p /etc/letsencrypt/renewal-hooks/deploy
fi
cat > /etc/letsencrypt/renewal-hooks/deploy/unifi <<_EOF
#! /bin/bash

if [ -e $privkey ] && [ -e $pubcrt ] && [ -e $chain ]; then

	echo >> $LOG
	echo "Importing new certificate on \$(date)" >> $LOG
	
	p12=\$(mktemp)
	combo=\$(mktemp)
	cat $pubcrt <(echo) $chain <(echo) $caroot > \${combo}
	
	if ! openssl pkcs12 -export \\
	-in \${combo} \\
	-inkey $privkey \\
	-CAfile $chain \\
	-out \${p12} -passout pass:aircontrolenterprise \\
	-caname root -name unifi >/dev/null ; then
		echo "OpenSSL export failed" >> $LOG
		exit 1
	fi
	
	if ! keytool -delete -alias unifi \\
	-keystore /var/lib/unifi/keystore \\
	-deststorepass aircontrolenterprise >/dev/null ; then
		echo "KeyTool delete failed" >> $LOG
	fi
	
	if ! keytool -importkeystore \\
	-srckeystore \${p12} \\
	-srcstoretype pkcs12 \\
	-srcstorepass aircontrolenterprise \\
	-destkeystore /var/lib/unifi/keystore \\
	-deststorepass aircontrolenterprise \\
	-destkeypass aircontrolenterprise \\
	-alias unifi -trustcacerts >/dev/null; then
		echo "KeyTool import failed" >> $LOG
		exit 2
	fi
	
	systemctl stop unifi
	if ! java -jar /usr/lib/unifi/lib/ace.jar import_cert \\
	$pubcrt $chain $caroot >/dev/null; then
		echo "Java import_cert failed" >> $LOG
		systemctl start unifi
		exit 3
	fi
	systemctl start unifi
	rm -f \${p12}
	rm -f \${combo}
	echo "Success" >> $LOG
else
	echo "Certificate files missing" >> $LOG
	exit 4
fi
_EOF
chmod a+x /etc/letsencrypt/renewal-hooks/deploy/unifi

# Write a script to acquire the first certificate (for a systemd timer)
cat > /usr/local/sbin/certbotrun.sh <<_EOF
#! /bin/sh
extIP=\$(curl -fs -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip")
dnsIP=\$(getent hosts ${dnsname} | cut -d " " -f 1)

echo >> $LOG
echo "CertBot run on \$(date)" >> $LOG
if [ x\${extIP} = x\${dnsIP} ]; then
	if [ ! -d /etc/letsencrypt/live/${dnsname} ]; then
		systemctl stop lighttpd
		if certbot certonly -d $dnsname --standalone --agree-tos --register-unsafely-without-email >> $LOG; then
			echo "Received certificate for ${dnsname}" >> $LOG
		fi
		systemctl start lighttpd
	fi
	if /etc/letsencrypt/renewal-hooks/deploy/unifi; then
		systemctl stop certbotrun.timer
		echo "Certificate installed for ${dnsname}" >> $LOG
	fi
else
	echo "No action because ${dnsname} doesn't resolve to ${extIP}" >> $LOG
fi
_EOF
chmod a+x /usr/local/sbin/certbotrun.sh

# Write the systemd unit files
if [ ! -f /etc/systemd/system/certbotrun.timer ]; then
	cat > /etc/systemd/system/certbotrun.timer <<_EOF
[Unit]
Description=Run CertBot hourly until success
[Timer]
OnCalendar=hourly
RandomizedDelaySec=15m
[Install]
WantedBy=timers.target
_EOF
	systemctl daemon-reload

	cat > /etc/systemd/system/certbotrun.service <<_EOF
[Unit]
Description=Run CertBot hourly until success
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/certbotrun.sh
_EOF
fi

# Start the above
if [ ! -d /etc/letsencrypt/live/${dnsname} ]; then
	if ! /usr/local/sbin/certbotrun.sh; then
		echo "Installing hourly CertBot run"
		systemctl start certbotrun.timer
	fi
fi

# Install GCP Ops agent & configure
curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
sudo bash add-google-cloud-ops-agent-repo.sh --also-install

if [ -f /etc/google-cloud-ops-agent/config.yaml ]; then
sudo tee /etc/google-cloud-ops-agent/config.yaml > /dev/null << EOF
metrics:
  receivers:
    mongodb:
      type: mongodb
      insecure: true
      endpoint: localhost:27117
  service:
    pipelines:
      mongo:
        receivers: [mongodb]
logging:
  receivers:
    mongodb:
      type: mongodb
      include_paths: [/var/log/unifi/mongod.log*]
  service:
    pipelines:
      mongo:
        receivers: [mongodb]
EOF

sudo service google-cloud-ops-agent restart
sleep 30
fi

# Signal in logs startup completed
echo startup script completed!

# show all installed versions for debugging
echo running version report...
echo essentials:
java -version
mongod -version
echo unifi: "$(/usr/lib/unifi/bin/ubnt-apttool showpkgver unifi)"

echo secondary:
dpkg-query -W haveged lighttpd ca-certificates fail2ban

echo report complete.
