#!/usr/bin/with-contenv bash
scriptVersion="2.0"
scriptName="QueueCleaner"
dockerLogPath="/config/logs"

settings () {
  log "Import Script $1 Settings..."
  source "$1"
}

verifyConfig () {

	if [ "$enableQueueCleaner" != "true" ]; then
		log "Script is not enabled, enable by setting enableQueueCleaner to \"true\" by modifying the \"/config/<filename>.conf\" config file..."
		log "Sleeping (infinity)"
		sleep infinity
	fi

}

logfileSetup () {
  logFileName="$scriptName-$(date +"%Y_%m_%d_%I_%M_%p").txt"

  if [ ! -d "$dockerLogPath" ]; then
    mkdir -p "$dockerLogPath"
    chown ${PUID:-1000}:${PGID:-1000} "$dockerLogPath"
    chmod 777 "$dockerLogPath"
  fi

  if find "$dockerLogPath" -type f -iname "$scriptName-*.txt" | read; then
    # Keep only the last 5 log files for 6 active log files at any given time...
    rm -f $(ls -1t $dockerLogPath/$scriptName-* | tail -n +5)
    # delete log files older than 5 days
    find "$dockerLogPath" -type f -iname "$scriptName-*.txt" -mtime +5 -delete
  fi
  
  if [ ! -f "$dockerLogPath/$logFileName" ]; then
    echo "" > "$dockerLogPath/$logFileName"
    chown ${PUID:-1000}:${PGID:-1000} "$dockerLogPath/$logFileName"
    chmod 666 "$dockerLogPath/$logFileName"
  fi
}

log () {
  m_time=`date "+%F %T"`
  echo $m_time" :: $scriptName (v$scriptVersion) :: "$1
  echo $m_time" :: $scriptName (v$scriptVersion) :: "$1 >> "$dockerLogPath/$logFileName"
}


QueueCleanerProcess () {
  arrApp="$1"

  # Sonarr
  if [ "$arrApp" = "sonarr" ]; then
    arrUrl="$sonarrUrl"
    arrApiKey="$sonarrApiKey"
    arrApiVersion="v3"
    arrQueueData="$(curl -s "$arrUrl/api/$arrApiVersion/queue?page=1&pagesize=200&sortDirection=descending&sortKey=progress&includeUnknownSeriesItems=true&apikey=${arrApiKey}" | jq -r .records[])"
  fi

  # Sonarr
  if [ "$arrApp" = "sonarr-anime" ]; then
    arrUrl="$sonarranimeUrl"
    arrApiKey="$sonarranimeApiKey"
    arrApiVersion="v3"
    arrQueueData="$(curl -s "$arrUrl/api/$arrApiVersion/queue?page=1&pagesize=200&sortDirection=descending&sortKey=progress&includeUnknownSeriesItems=true&apikey=${arrApiKey}" | jq -r .records[])"
  fi

  # Radarr
  if [ "$arrApp" = "radarr" ]; then
    arrUrl="$radarrUrl"
    arrApiKey="$radarrApiKey"
    arrApiVersion="v3"
    arrQueueData="$(curl -s "$arrUrl/api/$arrApiVersion/queue?page=1&pagesize=200&sortDirection=descending&sortKey=progress&includeUnknownMovieItems=true&apikey=${arrApiKey}" | jq -r .records[])"
  fi

  # Lidarr
  if [ "$arrApp" = "lidarr" ]; then
    arrUrl="$lidarrUrl"
    arrApiKey="$lidarrApiKey"
    arrApiVersion="v1"
    arrQueueData="$(curl -s "$arrUrl/api/$arrApiVersion/queue?page=1&pagesize=200&sortDirection=descending&sortKey=progress&includeUnknownArtistItems=true&apikey=${arrApiKey}" | jq -r .records[])"
  fi

  arrQueueIdCount=$(echo "$arrQueueData" | jq -r ".id" | wc -l)
  # Exclude TBA items from the "Completed/Warning" cleanup list
  arrQueueCompletedIds=$(echo "$arrQueueData" | jq -r 'select(.status=="completed") | select(.trackedDownloadStatus=="warning") | select(.statusMessages | tostring | contains("TBA") | not) | .id')
  arrQueueIdsCompletedCount=$(echo "$arrQueueCompletedIds" | wc -w)
  arrQueueFailedIds=$(echo "$arrQueueData" | jq -r 'select(.status=="failed") | .id')
  arrQueueIdsFailedCount=$(echo "$arrQueueData" | jq -r 'select(.status=="failed") | .id' | wc -l)
  arrQueueStalledIds=$(echo "$arrQueueData" | jq -r 'select(.status=="stalled") | .id')
  arrQueueIdsStalledount=$(echo "$arrQueueData" | jq -r 'select(.status=="stalled") | .id' | wc -l)
  arrQueuedIds=$(echo "$arrQueueCompletedIds"; echo "$arrQueueFailedIds"; echo "$arrQueueStalledIds")
  arrQueueIdsCount=$(( $arrQueueIdsCompletedCount + $arrQueueIdsFailedCount + $arrQueueIdsStalledount ))

  if [ $arrQueueIdsCount -eq 0 ]; then
    log "$arrApp :: No items in queue to clean up"
  else
    for queueId in $(echo $arrQueuedIds); do
      arrQueueItemData="$(echo "$arrQueueData" | jq -r "select(.id==$queueId)")"
      arrQueueItemTitle="$(echo "$arrQueueItemData" | jq -r .title)"
	  log "$arrApp :: $queueId ($arrQueueItemTitle) :: Removing Failed Queue Item from $arrName..."
      deleteItem=$(curl -sX DELETE "$arrUrl/api/$arrApiVersion/queue/$queueId?removeFromClient=$removeFromClient&blocklist=$blocklist&skipRedownload=$skipRedownload&changeCategory=false&apikey=${arrApiKey}")
    done
  fi
}

for (( ; ; )); do
  let i++
  logfileSetup
  log "Starting..."
  confFiles=$(find /config -mindepth 1 -type f -name "*.conf")
  confFileCount=$(echo "$confFiles" | wc -l)

  if [ -z "$confFiles" ]; then
      log "ERROR :: No config files found, exiting..."
      exit
  fi

  for f in $confFiles; do
    count=$(($count+1))
    log "Processing \"$f\" config file"
    settings "$f"
    verifyConfig
    if [ ! -z "$radarrUrl" ]; then
      if [ ! -z "$radarrApiKey" ]; then
        QueueCleanerProcess "radarr"
      else
        log "ERROR :: Skipping Radarr, missing API Key..."
      fi
    else
      log "ERROR :: Skipping Radarr, missing URL..."
    fi
    if [ ! -z "$sonarrUrl" ]; then
      if [ ! -z "$sonarrApiKey" ]; then
        QueueCleanerProcess "sonarr"
      else
        log "ERROR :: Skipping Sonarr, missing API Key..."
      fi
    else
      log "ERROR :: Skipping Sonarr, missing URL..."
    fi
  done

  log "Sleeping $queueCleanerScriptInterval..."
  sleep $queueCleanerScriptInterval

done

exit
