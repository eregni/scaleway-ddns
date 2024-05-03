#!/bin/bash
# Script to update dns record with the scaleway API
# https://developers.scaleway.com/en/products/domain/dns/api/
#
# You need to copy the 'config-template' to 'config' and set the variables
# When it is run as a cron job add '-c' flag
# Use '--reset' to remove the cached ip

cd "$(dirname "$0")" || exit 1

if ! test -e ./config;then
	echo 'No config file found. Copy the "config-template" file to "config" and set the variables'
	exit 1
fi

# shellcheck disable=SC1091
source ./config

# stderr/stdout to tty and logfile
exec > >(tee -ia "$LOG")
exec 2>&1

# Check for curl
if ! curl -V >> /dev/null;then
	log_line '[ERROR] Curl not found.'
	exit 1
fi

# CONSTANTS ######################################
readonly API='https://api.scaleway.com/domain/v2beta1'
readonly SCW_API_KEY_HEADER="X-Auth-Token: $SCW_API_SECRET"
readonly IP_LOG='/tmp/cached_ip'
readonly RE_IP='^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]|[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]|[0-9])$'
readonly TIMEOUT=5

# FUNCTIONS ######################################
function log_line() {
	echo "$(date "$DATE_FORMAT") - $1"
}

function mail_log(){
	if ! $MAILS;then
		return
	fi
	if grep -e "^$(date '+%a %e %b %Y %H').* Alert mail send to $MAIL_TO" $LOG >> /dev/null; then
		return  # Limit alert mails to one every hour
	fi
	if [ $# -ne 1 ];then
		log_line '[ERROR] Function mail_log: invalid nr of arguments. Need an email body'
		exit 1
	fi
	echo "Update scaleway ip script: $1" | mail -s 'update scaleway ip' "$MAIL_TO"
	log_line "[INFO] Mail send to $MAIL_TO"

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
	
	local url="$API/dns-zones/$zone/records?project_id=$PROJECTID"
	local result
	result=$(curl --connect-timeout "$TIMEOUT" --silent --request PATCH --json "$body" --header "$SCW_API_KEY_HEADER" "$url")
	if [ "$(echo "$result" | jq -r '.message')" != "null" ];then
		log_line "[ERROR] Scaleway API: Problem with removal of dns record with id $id. API message: $(echo "$result" | jq '.message')"
		echo "$result"
		mail_log "There was a problem during the last DNS A record update. Please check the logs"
		exit 1
	else
		log_line "[INFO] Scaleway API: Dns record with id $id removed"
	fi
}

function add_dns_a_record() {
	# First argument = ip address
	if [ $# -ne 2 ];then
		log_line '[ERROR] Function add_dns_a_record: invalid nr of arguments. Need an ip and a zone'
		exit 1
	fi
	
	local ip=$1
	local zone=$2
	local body
	body=$(cat <<-EOF
			{
				"changes": [
					{
						"add": {
							"records": [
								{
									"data": "$ip",
									"name": "",
									"ttl": 3600,
									"type": "A",
									"comment": "scaleway ddns script"
								}
							]
						}
					}
				]
			}
			EOF
		)

	local url="$API/dns-zones/$zone/records"
	local result
	result=$(curl --connect-timeout "$TIMEOUT" --silent --request PATCH --json "$body" --header "$SCW_API_KEY_HEADER" "$url")
	if [ "$(echo "$result" | jq -r '.message')" != "null" ];then
		log_line "[ERROR] Scaleway API: Ip update failed. API message: $(echo "$result" | jq '.message')"
		mail_log "There was a problem during the last DNS A record update for domain $zone. Please check the logs"
		exit 1
	else
		log_line "[INFO] Scaleway API: Ip update succesfull for $zone. New record id: $(echo "$result" | jq -r '.records[0].id')"
		#mail_log "DNS A record has been updated for $zone. New ip = $ip"
	fi
}

function handle_dns_record(){
	if [ $# -ne 1 ];then
		log_line '[ERROR] Function update_dns_record: requires dns zone as argument'
		exit 1
	fi

	local zone=$1
	local url="$API/dns-zones/$zone/records?project_id=$PROJECTID&type=A&order_by=name_asc"
	local records
	records=$(curl --connect-timeout "$TIMEOUT" --silent --header "$SCW_API_KEY_HEADER" "$url")
    # shellcheck disable=SC2181
	if [ $? -ne 0 ];then
		log_line "[ERROR] Scaleway API: Failed to get DNS A record."
		mail_log "There was a problem during the last DNS A record update. Please check the logs"
		exit 1
	fi

	count=$(echo "$records" | jq -r '.total_count')
	# Add new A record when there is none present
	if [ "$count" -le 0 ];then
		log_line "[INFO] $zone: No dns A record found. Creating new A record with ip $IP"
		add_dns_a_record "$IP" "$zone"
	# Stop script when there are multiple A records present
	elif [ "$count" -ne 1 ] && test -n "$zone";then # test -n "$zone". Dirty tric -> cannot retrieve A record with empty name with scaleway api (scaleway removes the '@')
		log_line '[ERROR] Function update_dns_record: There should be no more than 1 A record'
		exit 1
	# Update ip on dns record
	else
		record_ip=$(echo "$records" | jq -r '.records[0].data')
		record_id=$(echo "$records" | jq -r '.records[0].id')
		if test "$record_ip" != "$IP";then
			log_line "[INFO] $zone: Updating existing dns record with id $record_id: $record_ip -> $IP"
			delete_dns_record "$record_id"
			add_dns_a_record "$IP" "$zone"
		else
			log_line "[INFO] ${zone:-$zone}: Dns record is already up-to-date. No update required"
		fi
	fi
}

# SCRIPT #########################################

# Check internet connection
if ! ping -c 1 9.9.9.9 >> /dev/null;then
  log_line '[ERROR] Network connection not OK. Aborting...'
  exit 1
fi

if [ "$1" != "-c"  ];then
	log_line '[INFO] Manual run'
fi

if [ "$1" == "--reset"  ] || ! test -e $IP_LOG;then
	echo "" > $IP_LOG
fi

# Resolve and check wan ip. update dns if necessary
RETRY=0
while [ $RETRY -lt 3 ];do
	IP=$(curl --connect-timeout "$TIMEOUT" --silent "$WAN_IP_RESOLVER")
	if [[ $IP  =~ $RE_IP ]];then
		break
	fi
	((RETRY=RETRY+1))
done
if ! [[ $IP =~ $RE_IP ]];then
	mail_log "There was a problem during the last DNS A record update. Please check the logs"
	log_line "[ERROR] Respone '$IP' from $WAN_IP_RESOLVER was not a valid ip. Aborted after multiple attempts"
	exit 1
fi

if test "$IP" != "$(cat $IP_LOG)";then
	if test "$(cat $IP_LOG)" == "";then 
		log_line "[INFO] No ip cached. Checking DNS record"
	else
		log_line "[INFO] Ip has changed: $(cat $IP_LOG) -> $IP"
	fi
	for domain in "${DOMAINS[@]}"; do
		handle_dns_record "$domain" && echo "$IP" > $IP_LOG
	done
elif [ "$1" != "-c"  ];then
	log_line "[INFO] Ip has not changed ($IP)"
fi

# shrink log file to max 200000 lines ~12MB
tail -n 200000 "$LOG" > "$LOG.tmp"
mv "$LOG.tmp" "$LOG"
