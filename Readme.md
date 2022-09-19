## scaleway-ddns

Simple script to update dns A record with the scaleway API  
API docs: https://developers.scaleway.com/en/products/domain/dns/api/

You need to copy the 'config-template' to 'config' and set the variables  
Cron example that runs every 5 mins:  
*/5 * * * *     [PATH TO SCRIPT FOLDER]/scaleway-ddns/scaleway-ddns.sh -c  

When it is run as a cron job add '-c' flag. This generates less log lines  
Use '--reset' flag to remove the locally cached ip. This will force check/update the dns record
