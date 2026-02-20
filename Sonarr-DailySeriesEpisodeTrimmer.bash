#!/usr/bin/env bash
scriptVersion="1.3"
scriptName="Sonarr-DailySeriesEpisodeTrimmer"
dockerLogPath="/config/logs"

settings () {
  log "Import Script $1 Settings..."
  source "$1"
  arrUrl="$sonarrUrl"
  arrApiKey="$sonarrApiKey"
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

verifyConfig () {

  if [ "$enableDailySeriesEpisodeTrimmer" != "true" ]; then
	log "Script is not enabled, enable by setting enableDailySeriesEpisodeTrimmer to \"true\" by modifying the \"/config/settings.conf\" config file..."
	log "Sleeping (infinity)"
	sleep infinity
  fi

}

DailySeriesTrimmerProcess () {
    log "Get Sonarr Series List"
    sonarrSeriesList=$(curl -s --header "X-Api-Key:"${arrApiKey} --request GET  "$arrUrl/api/v3/series")
    sonarrSeriesIds=$(echo "${sonarrSeriesList}" | jq -r '.[] |.id')
    sonarrSeriesTotal=$(echo "${sonarrSeriesIds}" | wc -l)
    loopCount=0
    for id in $(echo $sonarrSeriesIds); do
        loopCount=$(( $loopCount + 1 ))
        seriesId=$id
        seriesData=$(curl -s "$arrUrl/api/v3/series/$seriesId?apikey=$arrApiKey")
        seriesTitle=$(echo $seriesData | jq -r ".title")
        seriesType=$(echo $seriesData | jq -r ".seriesType")
        seriesTags=$(echo $seriesData | jq -r ".tags[]")
        # If sonarr series is tagged, match via tag to support series that are not considered daily
        if [ -z "$sonarrSeriesEpisodeTrimmerTag" ]; then
            tagMatch="false"
        else
            tagMatch="false"
            for tagId in $seriesTags; do
                tagLabel="$(curl -s "$arrUrl/api/v3/tag/$tagId?apikey=$arrApiKey" | jq -r ".label")"
                if  [ "$sonarrSeriesEpisodeTrimmerTag" == "$tagLabel" ]; then
                    tagMatch="true"
                    break
                fi
            done
        fi

        # Verify series is marked as "daily" type by sonarr, skip if not...
        if [ $seriesType != "daily" ] && [ "$tagMatch" == "false" ]; then
            log "$loopCount/$sonarrSeriesTotal :: $seriesTitle (ID:$seriesId) :: ERROR :: Series does not match TYPE: Daily or TAG: $sonarrSeriesEpisodeTrimmerTag, skipping..."
            continue
        fi

        seriesEpisodeData=$(curl -s "$arrUrl/api/v3/episode?seriesId=$seriesId&apikey=$arrApiKey")
        seriesEpisodeIds=$(echo "$seriesEpisodeData" | jq -r " . | sort_by(.airDate) | reverse | .[] | select(.hasFile==true) | .id")
        seriesEpisodeIdsCount=$(echo "$seriesEpisodeIds" | wc -l)

        # If non-daily series, set maximum episode count to match latest season total episode count
        if [ $seriesType != "daily" ]; then
            maximumDailyEpisodes=$(echo "$seriesData" | jq -r ".seasons | map(select(.seasonNumber > 0 and .statistics.totalEpisodeCount > 1)) | sort_by(.seasonNumber) | reverse | .[].statistics.totalEpisodeCount" | head -n1)
        fi

        # Skip processing if less than the maximumDailyEpisodes setting were found to be downloaded
        if [ $seriesEpisodeIdsCount -lt $maximumDailyEpisodes ]; then
            log "$loopCount/$sonarrSeriesTotal :: $seriesTitle (ID:$seriesId) :: ERROR :: Series has not exceeded $maximumDailyEpisodes downloaded episodes ($seriesEpisodeIdsCount files found), skipping..."
            continue
        fi

        # Begin processing "daily" series type
        seriesEpisodeData=$(curl -s "$arrUrl/api/v3/episode?seriesId=$seriesId&apikey=$arrApiKey")
        seriesEpisodeIds=$(echo "$seriesEpisodeData"| jq -r " . | sort_by(.airDate) | reverse | .[] | select(.hasFile==true) | .id")
        processId=0
        seriesRefreshRequired=false
        for id in $seriesEpisodeIds; do
            processId=$(( $processId + 1 ))
            episodeData=$(curl -s "$arrUrl/api/v3/episode/$id?apikey=$arrApiKey")
            episodeSeriesId=$(echo "$episodeData" | jq -r ".seriesId")
            if [ $processId -gt $maximumDailyEpisodes ]; then
                episodeTitle=$(echo "$episodeData" | jq -r ".title")
                episodeSeasonNumber=$(echo "$episodeData" | jq -r ".seasonNumber")
                episodeNumber=$(echo "$episodeData" | jq -r ".episodeNumber")
                episodeAirDate=$(echo "$episodeData" | jq -r ".airDate")
                episodeFileId=$(echo "$episodeData" | jq -r ".episodeFileId")
                
                # Unmonitor downloaded episode if greater than 14 downloaded episodes
                log "$loopCount/$sonarrSeriesTotal :: $seriesTitle (ID:$episodeSeriesId) :: S${episodeSeasonNumber}E${episodeNumber} :: $episodeTitle :: Unmonitored Episode ID :: $id"
                umonitorEpisode=$(curl -s "$arrUrl/api/v3/episode/monitor?apikey=$arrApiKey" -X PUT -H 'Content-Type: application/json'  --data-raw "{\"episodeIds\":[$id],\"monitored\":false}")

                # Delete downloaded episode if greater than 14 downloaded episodes
                log "$loopCount/$sonarrSeriesTotal :: $seriesTitle (ID:$episodeSeriesId) :: S${episodeSeasonNumber}E${episodeNumber} :: $episodeTitle :: Deleted File ID :: $episodeFileId"
                deleteFile=$(curl -s "$arrUrl/api/v3/episodefile/$episodeFileId?apikey=$arrApiKey" -X DELETE)
                seriesRefreshRequired=true
            else
                # Skip if less than required 14 downloaded episodes exist
                log "$loopCount/$sonarrSeriesTotal :: $seriesTitle (ID:$episodeSeriesId) :: Skipping Episode ID :: $id"
            fi
        done
        if [ "$seriesRefreshRequired" = "true" ]; then
            # Refresh Series after changes
            log "$loopCount/$sonarrSeriesTotal :: $seriesTitle (ID:$episodeSeriesId) :: Refresh Series"
            refreshSeries=$(curl -s "$arrUrl/api/v3/command?apikey=$arrApiKey" -X POST --data-raw "{\"name\":\"RefreshSeries\",\"seriesId\":$episodeSeriesId}")
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
        settings "$f"
        verifyConfig
        if [ ! -z "$arrUrl" ]; then
            if [ ! -z "$arrApiKey" ]; then
                DailySeriesTrimmerProcess
            else
                log "ERROR :: Skipping Sonarr, missing API Key..."
            fi
        else
            log "ERROR :: Skipping Sonarr, missing URL..."
        fi
    done
	log "Script sleeping for $dailySeriesEpisodeTrimmerScriptInterval..."
	sleep $dailySeriesEpisodeTrimmerScriptInterval
done
exit
