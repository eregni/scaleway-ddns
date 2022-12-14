#!/bin/bash
# TODO: more error logging -> when api is not reachable (2x) and when ip resolver is not reachable
# Script to update dns record with the scaleway API
# https://developers.scaleway.com/en/products/domain/dns/api/
#
# You need to copy the 'config-template' to 'config' and set the variables
# When it is run as a cron job add '-c' flag
# Use '--reset' to remove the cached ip

# CONSTANTS ######################################
API='https://api.scaleway.com/domain/v2beta1'
SCW_API_KEY='X-Auth-Token'
IP_LOG='/tmp/cached_ip'

# FUNCTIONS ######################################
function log_line() {
	echo "$(date "$DATE_FORMAT") - $1"
}

function delete_dns_record() {
	if [ $# -ne 1 ];then
		log_line '[ERROR] Function delete_dns_record: invalid nr of arguments'
		exit 1
	fi

	local id=$1
	local body
	body=$(cat <<-EOF
		{
			"changes": [
				{
					"delete": {
						"id": "$id"
					}
				}
			]
		}
		EOF
	)

	result=$(curl --silent --request PATCH --json "$body" --header "$SCW_API_KEY: $SCW_API_SECRET" "$url") || exit 1
	if [ "$(echo "$result" | jq -r '.message')" != "null" ];then
		log_line "[ERROR] Scaleway API: Problem with removal of dns record with id $id. API message: $(echo "$result" | jq '.message')"
		exit 1
	else
		log_line "[INFO] Scaleway API: Dns record with id $id removed"
	fi
}

function add_dns_a_record() {
	# First argument = ip address
	# Second argument (optional) = record name
	local name
	if [ $# -eq 2 ];then
		name=$2
	elif [ $# -gt 2 ] || [ $# -eq 0 ];then
		log_line '[ERROR] Function add_dns_a_record: invalid nr of arguments'
		exit 1
	fi

	local body
	body=$(cat <<-EOF
			{
				"changes": [
					{
						"add": {
							"records": [
								{
									"data": "$IP",
									"name": "$name",
									"ttl": 3600,
									"type": "A",
									"comment": "ddns script"
								}
							]
						}
					}
				]
			}
			EOF
		)

	local url="$API/dns-zones/$ZONE/records"
	local result
	result=$(curl --silent --request PATCH --json "$body" --header "$SCW_API_KEY: $SCW_API_SECRET" "$url") || exit 1
	if [ "$(echo "$result" | jq -r '.message')" != "null" ];then
		log_line "[ERROR] Scaleway API: Ip update failed. API message: $(echo "$result" | jq '.message')"
		exit 1
	else
		local domain
		if test -n "$name"; then domain=$name.$ZONE; else domain=$ZONE; fi
		log_line "[INFO] Scaleway API: Ip update succesfull for $domain. New record id: $(echo "$result" | jq -r '.records[0].id')"
	fi
}

function handle_dns_record(){
	local name
	# Argument is used to handle subdomain
	if [ $# -eq 1 ];then
		name=$1
	elif [ $# -gt 1 ];then
		log_line '[ERROR] Function update_dns_record: invalid nr of arguments'
		exit 1
	fi

	url="$API/dns-zones/$ZONE/records?project_id=$PROJECTID&type=A&name=$name&order_by=name_asc"
	records=$(curl --silent --header "X-Auth-Token: $SCW_API_SECRET" "$url") || exit 1
	count=$(echo "$records" | jq -r '.total_count')
	# Add new A record when there is none present
	if [ "$count" -le 0 ];then
		log_line "[INFO] ${name:-$ZONE}: No dns A record found. Creating new A record with ip $IP"
		add_dns_a_record "$IP" "$name"
	# Stop script when there are multiple A records present
	elif [ "$count" -ne 1 ] && test -n "$name";then # test -n "$name". Dirty tric -> cannot retrieve A record with empty name with scaleway api (scaleway removes the '@')
		log_line '[ERROR] Function update_dns_record: There should be no more than 1 A record'
		exit 1
	# Update ip on dns record
	else
		record_ip=$(echo "$records" | jq -r '.records[0].data')
		record_id=$(echo "$records" | jq -r '.records[0].id')
		if test "$record_ip" != "$IP";then
			log_line "[INFO] ${name:-$ZONE}: Updating existing dns record with id $record_id: $record_ip -> $IP"
			delete_dns_record "$record_id"
			add_dns_a_record "$IP" "$name"
		else
			log_line "[INFO] ${name:-$ZONE}: Dns record is already up-to-date. No update required"
		fi
	fi
}

# SCRIPT #########################################
shopt -s expand_aliases

cd "$(dirname "$0")" || exit 1

if ! test -e ./config;then
	echo 'No config file found. Copy the "config-template" file to "config" and set the variables'
	exit 1
fi

source ./config

if test -n "$CURL_PATH";then
	alias curl="$CURL_PATH"
fi

# stderr/stdout to tty and logfile
exec > >(tee -ia "$LOG")
exec 2>&1

if ! curl -V >> /dev/null;then
	log_line "[ERROR] Curl not found. Set path in the config file"
	exit 1
fi

if [ "$1" != "-c"  ];then
	log_line '[INFO] Manual run'
fi

if [ "$1" == "--reset"  ] || ! test -e $IP_LOG;then
	echo 'no ip cached' > $IP_LOG
fi

IP=$(curl --silent "$WAN_IP_RESOLVER") || exit 1

if test "$IP" != "$(cat $IP_LOG)";then
	log_line "[INFO] Ip has changed: $(cat $IP_LOG) -> $IP"
	handle_dns_record && echo "$IP" > $IP_LOG

elif [ "$1" != "-c"  ];then
	log_line "[INFO] Ip has not changed ($IP)"
fi

# shrink log file to max 200000 lines ~12MB
tail -n 200000 "$LOG" > "$LOG.tmp"
mv "$LOG.tmp" "$LOG"
