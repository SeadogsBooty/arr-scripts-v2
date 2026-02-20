#!/usr/bin/with-contenv bash
scriptVersion="2.2"
scriptName="Huntarr"
dockerLogPath="/config/logs"

settings () {
  log "Import Script $1 Settings..."
  source "$1"
}

verifyConfig () {

	if [ "$enableHuntarr" != "true" ]; then
		log "Script is not enabled, enable by setting enableHuntarr to \"true\" by modifying the \"$1\" config file..."
		log "Sleeping $huntarrScriptInterval..."
  		sleep $huntarrScriptInterval
		exit
	fi

}

logfileSetup () {
  logFileName="$scriptName-$(date +"%Y_%m_%d-%I_%p").txt"

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

HuntarrRadarr () {
    arrApp="Radarr"
    arrUrl="$radarrUrl"
    arrApiVersion="v3"
    arrApiKey="$radarrApiKey"
}

HuntarrSonarr () {
    arrApp="Sonarr"
    arrUrl="$sonarrUrl"
    arrApiVersion="v3"
    arrApiKey="$sonarrApiKey"    
}

ArrAppStatusCheck () {
    arrQueue=$(curl -s "$arrUrl/api/$arrApiVersion/queue?page=1&pageSize=100&apikey=${arrApiKey}")
    arrQueueTotalRecords=$(echo "$arrQueue" | jq -r '.records[] | select(.status!="completed") | .id' | wc -l)
    if [ $arrQueueTotalRecords -ge 3 ]; then
        touch "/config/huntarr-break"
        return
    fi
    arrTaskCount=$(curl -s "$arrUrl/api/$arrApiVersion/command?apikey=${arrApiKey}" | jq -r '.[] | select(.status=="started") | .name' | wc -l)
    if [ $arrTaskCount -ge 3 ]; then
        touch "/config/huntarr-break"
        return
    fi

}

HuntarrAPILimitFile () {
    # Create base directory for various functions/process
    if [ ! -d "/config/huntarr" ]; then
        mkdir -p "/config/huntarr" 
        chown ${PUID:-1000}:${PGID:-1000} "/config/huntarr"
    fi
    apiLimitFile="Huntarr-api-search-count-$(date +"%Y_%m_%d").txt"
    if [ ! -f "/config/huntarr/$apiLimitFile" ]; then
        echo -n "0" > "/config/huntarr/$apiLimitFile"
        chown ${PUID:-1000}:${PGID:-1000} "/config/huntarr/$apiLimitFile"
    fi

    if find "/config/huntarr" -type f -iname "Huntarr-api-search-count-*.txt" | read; then
        # Keep only the last 5 log files for 6 active log files at any given time...
        rm -f $(ls -1t /config/huntarr/Huntarr-api-search-count-* | tail -n +5)
        # delete log files older than 5 days
        find "/config/huntarr"  -type f -iname "Huntarr-api-search-count-*.txt" -mtime +5 -delete
    fi
}

HuntarrProcess () {
    
    # Create base directory for various functions/process
    if [ ! -d "/config/huntarr" ]; then
        mkdir -p "/config/huntarr" 
    fi

    # Indexer API Limit Process
    HuntarrAPILimitFile

    # check if API limit has been reached
    if [ -f "/config/huntarr/$apiLimitFile" ]; then
        currentApiCounter=$(cat "/config/huntarr/$apiLimitFile")
        if [ $currentApiCounter -ge $huntarrDailyApiSearchLimit ]; then
            log "$arrApp :: Daily API Limit reached... "
            return
        fi
    fi

    # Check if Arr application is too busy...
    if [ -f "/config/huntarr-break" ]; then
        rm "/config/huntarr-break"
    fi
    ArrAppStatusCheck
    if [ -f "/config/huntarr-break" ]; then
        rm "/config/huntarr-break"
        log "$arrApp App busy..."
        return
    fi

    # Gather Missing and Cutoff items for processing...
    # Radarr
    if [ "$arrApp" == "Radarr" ]; then

        # missing list
        missingList=$(wget --timeout=0 -q -O - "$arrUrl/api/$arrApiVersion/wanted/missing?page=1&pagesize=10&sortDirection=ascending&sortKey=movies.lastSearchTime&monitored=true&apikey=${arrApiKey}" | jq -r '.records[]')
       
        # cutoff list
        cutoffList=$(wget --timeout=0 -q -O - "$arrUrl/api/$arrApiVersion/wanted/cutoff?page=1&pagesize=10&sortDirection=ascending&sortKey=movies.lastSearchTime&monitored=true&apikey=${arrApiKey}" | jq -r '.records[]')
    
    fi

    # Sonarr
    if [ "$arrApp" == "Sonarr" ]; then

        # missing list
        missingList=$(wget --timeout=0 -q -O - "$arrUrl/api/$arrApiVersion/wanted/missing?page=1&pagesize=10&sortDirection=ascending&sortKey=episodes.lastSearchTime&monitored=true&apikey=${arrApiKey}" | jq -r '.records[]')

        # cutoff list
        cutoffList=$(wget --timeout=0 -q -O - "$arrUrl/api/$arrApiVersion/wanted/cutoff?page=1&pagesize=10&sortDirection=ascending&sortKey=episodes.lastSearchTime&monitored=true&apikey=${arrApiKey}" | jq -r '.records[]')  
    
    fi

    arrItemListData=$(echo  "$missingList" "$cutoffList")
    arrItemIds=$(echo "$arrItemListData" | jq -r .id)
    arrItemCount=$(echo "$arrItemIds" | wc -l) 

    # Begin Processing Missing and Cutoff items
    processNumber=0
    for arrItemId in $(echo "$arrItemIds"); do
        processNumber=$(($processNumber + 1))

        # check if API limit has been reached
        if [ -f "/config/huntarr/$apiLimitFile" ]; then
            currentApiCounter=$(cat "/config/huntarr/$apiLimitFile")
            if [ $currentApiCounter -ge $huntarrDailyApiSearchLimit ]; then
                log "$arrApp :: Daily API Limit reached..."
                break
            fi
        fi

        # Check for previous search
        if [ -f "/config/huntarr/$settingsFileName/$arrApp/$arrItemId" ]; then
            continue
        fi

        # Check if Arr application is too busy...
        ArrAppStatusCheck
        if [ -f "/config/huntarr-break" ]; then
            rm "/config/huntarr-break"
            log "$arrApp :: $arrApp App busy..."
            return
        fi   

        # Perform Search
        arrItemData=$(echo "$arrItemListData" | jq -r "select(.id==$arrItemId)")
        arrItemTitle=$(echo "$arrItemData" | jq -r .title)
        
        log "$arrApp :: $arrItemTitle ($arrItemId) :: Searching..."

        # Radarr
        if [ "$arrApp" == "Radarr" ]; then
            automatedSearchTrigger=$(curl -s "$arrUrl/api/$arrApiVersion/command" -X POST -H 'Content-Type: application/json' -H "X-Api-Key: $arrApiKey" --data-raw "{\"name\":\"MoviesSearch\",\"movieIds\":[$arrItemId]}")
        fi

        # Sonarr
        if [ "$arrApp" == "Sonarr" ]; then
            automatedSearchTrigger=$(curl -s "$arrUrl/api/$arrApiVersion/command" -X POST -H 'Content-Type: application/json' -H "X-Api-Key: $arrApiKey" --data-raw "{\"name\":\"EpisodeSearch\",\"episodeIds\":[$arrItemId]}")
        fi

        # update API search count
        echo -n "$(($currentApiCounter + 1))" > "/config/huntarr/$apiLimitFile"

        # create log folder for searched items
        if [ ! -d "/config/huntarr/$settingsFileName/$arrApp" ]; then
            mkdir -p "/config/huntarr/$settingsFileName/$arrApp"
            chown ${PUID:-1000}:${PGID:-1000} "/config/huntarr/$settingsFileName/$arrApp"
        fi

        # create log of searched item
        if [ ! -f "/config/huntarr/$settingsFileName/$arrApp/$arrItemId" ]; then
            touch "/config/huntarr/$settingsFileName/$arrApp/$arrItemId"
            chown ${PUID:-1000}:${PGID:-1000} "/config/huntarr/$settingsFileName/$arrApp/$arrItemId"
        fi        
    done
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
    settingsFileName=$(basename "${f%.*}")
    settings "$f"
    verifyConfig "$f"
    if [ ! -z "$radarrUrl" ]; then
      if [ ! -z "$radarrApiKey" ]; then
        HuntarrRadarr
        HuntarrProcess
      else
        log "ERROR :: Skipping Radarr, missing API Key..."
      fi
    else
      log "ERROR :: Skipping Radarr, missing URL..."
    fi
    if [ ! -z "$sonarrUrl" ]; then
      if [ ! -z "$sonarrApiKey" ]; then
        HuntarrSonarr
        HuntarrProcess
      else
        log "ERROR :: Skipping Sonarr, missing API Key..."
      fi
    else
      log "ERROR :: Skipping Sonarr, missing URL..."
    fi
  done

  log "Sleeping $huntarrScriptInterval..."
  sleep $huntarrScriptInterval

done

exit
