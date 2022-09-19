#!/bin/bash

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

function curl_command() {
	local result
	result=$(curl --silent CRASH HERE "$@")
	if [ $? -ne 0 ] ;then
		log_line "[ERROR] Problem with curl command"
		exit 1
	fi
	echo "$result"
}

function set_dns_a_record() {
	local record_id
	if [ $# -eq 2 ];then
		record_id="\"id\": \"$2\","
		echo "$record_id"
	elif [ $# -ne 1 ];then
		log_line '[ERROR] Function set_dns_a_record: invalid nr of arguments'
		exit 1
	fi
	local ip=$1
	local body
	body=$(cat <<-EOF 
			{
				"changes": [
					{
						"add": {
							"records": [
								{
									${record_id:-}
									"data": "$ip",
									"name": "",
									"priority": 5,
									"ttl": 14400,
									"type": "A",
									"comment": "test A record"
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
	result=$(curl_command --request PATCH --json "$body" --header "$SCW_API_KEY: $SCW_API_SECRET" "$url")
	if [ "$(echo "$result" | jq -r '.records[0].id')" == "null" ];then
		log_line "[ERROR] Scaleway API: Ip update failed. API message: $(echo "$result" | jq '.message')"
		exit 1
	else
		log_line '[INFO] Scaleway API: Ip update succesfull'
	fi
}

# SCRIPT #########################################
cd "$(dirname "$0")" || exit 1

if ! test -e ./config;then
	echo 'No config file found. Copy the "config-template" file to "config" and set the variables'
	exit 1
fi

source ./config

# stderr/stdout to tty and logfile
exec > >(tee -ia "$LOG")
exec 2>&1

if [ "$1" != "-c"  ];then
  log_line '[INFO] Manual run'
fi

if [ "$1" == "--reset"  ] || ! test -e $IP_LOG;then
	echo 'no ip cached' > $IP_LOG
fi

ip=$(curl_command "$WAN_IP_RESOLVER")

if test "$ip" != "$(cat $IP_LOG)";then
	log_line "[INFO] Ip has changed: $(cat $IP_LOG) -> $ip"
	url="$API/dns-zones/$ZONE/records?project_id=$PROJECTID&type=A"
	records=$(curl_command --header "X-Auth-Token: $SCW_API_SECRET" "$url")
	count=$(echo "$records" | jq -r '.total_count')
	# Add new A record when there is none present
	if [ $count -le 0 ];then
		log_line "[INFO] No dns A record found. Creating new record with ip $ip"
		set_dns_a_record "$ip"
	# Stop script when there are multiple A records present
	elif [ $count -ne 1 ];then
		log_line '[ERROR] There should be no more than 1 A record'
		exit 1
	# Update ip on dns record
	else
		record_ip=$(echo "$records" | jq -r '.records[0].data')
		record_id=$(echo "$records" | jq -r '.records[0].id')
		log_line "[INFO] Updating existing dns record with id $record_id: $record_ip -> $ip"
		if test "$record_ip" != "$ip";then
			set_dns_a_record "$ip" "$record_id"
		else
			log_line '[INFO] Dns record is already up-to-date. No update required'
		fi
	fi

	echo "$ip" > $IP_LOG

elif [ "$1" != "-c"  ];then
	log_line "[INFO] Ip has not changed ($ip)"
fi

# shrink log file to max 200000 lines ~12MB
tail -n 200000 "$LOG" > "$LOG.tmp"
mv "$LOG.tmp" "$LOG"
