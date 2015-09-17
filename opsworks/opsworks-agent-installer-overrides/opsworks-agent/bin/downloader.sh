#!/usr/bin/env bash
# utility for downloading files with retries

# define default values for optional parameter
MAX_FETCH_RETRIES=8
WGET_TIMEOUT=1200
DOWNLOAD_TIMEOUT=600
LOG_FILE="/dev/stderr"
DOWNLOAD_DIR_PREFIX="/tmp/opsworks-downloader"

USAGE_TEXT=<<EOL

  Usage: $0 -c <CHECKSUM_URL> -d <DOWNLOAD_DIR_PREFIX> -l <LOG_FILE>
            -r <MAX_FETCH_RETRIES> -t <DOWNLOAD_TIMEOUT>
            -u <TARGET_DOWNLOAD_URL> -w <WGET_TIMEOUT>

   -c URL of the checksum file to download for checking file integrity. (optional)
   -d Optional prefix for the name of the directory to download the files into. A temporary directory
      created with mktemp will be created under this path. If not given mktemp will use \$TMPDIR
   -l Absolute path to the log file. (default = /dev/stderr)
   -r Maximum number of retries. (default = 8)
   -t Timeout for downloading files. (default = 600 seconds)
   -u URL of the file to download.
   -w Wget timeout, value used for the -t option of wget. (default = 1200)
   -h Show this stuff.

   The script will try to download the given file and retry if it's size doesn't match
   expectations. For the instance agent the checksum file URL should be given. The script
   will fail if the SHA-1 of the downloaded file doesn't match the one in the checksum file.

   Per default a random directory in created with 'mktemp' will be used as the directory to download
   the files into. The directory name will look like '/tmp/opsworks-downloader.XXXXXXXX'.

EOL

usage(){
  echo "${USAGE_TEXT}"
}

gnu_cmd () {
  local _gnu_cmd=''
  local _cmd="$1"
  local _pattern=${2:-"GNU coreutils"}

  for alternative in $(which -a "${_cmd}" "g${_cmd}" "gnu${_cmd}" 2>/dev/null | uniq)
  do
    if [ -x "${alternative}" ] && [ -n "` ${alternative} --version | grep \"${_pattern}\"`" ]
    then
      _gnu_cmd="${alternative}"
    fi
  done

  if [ "$_gnu_cmd" == '' ]
  then
    echo "[ERROR] GNU ${_cmd} is not installed or not found in \$PATH" >> "${LOG_FILE}"
  else
    echo "${_gnu_cmd}"
  fi
}

log () {
  local _msg="$@"

  if [ -z "${gnu_date}" ]
  then
    gnu_date="$(gnu_cmd date)"
  fi

  echo "[ $( ${gnu_date} -u --rfc-2822 ) ] downloader: ${_msg}" >> "${LOG_FILE}"
}

# takes the prefix for the template for the mktemp command as a parameter. This must be
# a valid path. It must not exist, but we need to have access to it.
download_dir () {
  if [ -z "${gnu_mktemp}" ]
  then
    gnu_mktemp="$(gnu_cmd mktemp)"
  fi

  local _temp_dir=$( ${gnu_mktemp} -d "${DOWNLOAD_DIR_PREFIX}.XXXXXXXX" 2>&1 )

  if [ "$(echo "${_temp_dir}" | egrep -c "${DOWNLOAD_DIR_PREFIX}")" -eq '1' ]
  then
    log "Successfully created temporary download directory. (${_temp_dir})"
  else
    # $_temp_dir has the output of mktemp.
    log "[ERROR] Failed to create temp directory. (${_temp_dir})"
    exit 1
  fi

  DOWNLOAD_DIR="${_temp_dir}"
}

validate_input () {
  if [ -z "${PACKAGE_URL}" ]
  then
    log "[ERROR] Parameter missing."
    log "${USAGE_TEXT}"
    exit 1
  fi
}

initialize () {
  COUNTER=0
  STATUS=''

  download_dir
}

file_path () {
  local _file_url="$@"
  local _file_name="$( echo "${_file_url}" | awk -F'/' '{print $NF}' )"
  local _file_path="${DOWNLOAD_DIR}/${_file_name}"

  echo "${_file_path}"
}

match_checksum () {
  if [ -z "${CHECKSUM_URL}" ]
  then
    log "Checksum proof skipped."
    return 0
  else
    if `which shasum > /dev/null 2>&1`
    then
      local _file=$(file_path "${PACKAGE_URL}")
      export _file
      # The agent's checksum file format and the output of `shasum <FILE>`, will explain this line of code.
      $(shasum -s -a 1 -c <(awk -F'^SHA-1 ' '{print $2"  '$_file'" }' "$(file_path ${CHECKSUM_URL})"))

      local _exitcode=$?

      if [[ ${_exitcode} != 0 ]]
      then
        log "[ERROR] Checksum mismatch. (exitcode=${_exitcode})"
      else
        log "Checksum proof passed."
      fi

      return ${_exitcode}

    else
      log "[ERROR] shasum is not installed or not found in \$PATH"
      exit 1
    fi
  fi
}

check_size () {
  if [ -e "$(file_path "${PACKAGE_URL}" )" ]
  then

    if [ -z "${gnu_stat}" ]
    then
      gnu_stat="$(gnu_cmd 'stat')"
    fi

    local _actual_size=$(${gnu_stat} --format="%s" $(file_path "${PACKAGE_URL}" ))
    local _http_headers="`curl -sI "${PACKAGE_URL}"`"
    if [ "$?" -ne "0" ]
    then
      log "[ERROR] Failed to fetch content length from ${PACKAGE_URL} - curl returned exitcode $?"
      return $?
    fi

    local _expected_size="`echo -n "${_http_headers}" | awk '/^Content-Length/ {print $2}' | tr -d '\r'`"

    if [ "${_expected_size}" -eq "${_actual_size}" ]
    then
      log "File size test passed."
      return 0
    else
      local _ix_amz_id="$(echo -n "${_http_headers}" | awk '/^x-amz-id-2/ {print $2}' | tr -d '\r')"
      local _x_amz_request_id="$(echo -n "${_http_headers}" | awk '/^x-amz-request-id/ {print $2}' | tr -d '\r')"

      log "[ERROR] File size test failed. (ix-amz-id-2: ${_ix_amz_id} - x-amz-request-id: ${_x_amz_request_id})"
      return 1
    fi
  else
    log "[ERROR] File size test failed, no file to check."
    return 1
  fi
}

# call it with an URL as param to download files and store them in /tmp
wget_cmd () {
  local _url="$1"

  if [ -z "${gnu_timeout}" ]
  then
    gnu_timeout="$(gnu_cmd 'timeout')"
  fi

  if [ -z "${gnu_wget}" ]
  then
    gnu_wget=$(gnu_cmd 'wget' 'GNU Wget')
  fi

  local _timeout_cmd="${gnu_timeout} --signal=SIGTERM"
  local _wget_cmd="${gnu_wget} -nv -T ${WGET_TIMEOUT} --directory-prefix=${DOWNLOAD_DIR}"

  # download files, watch the download time using gnu timeout
  ${_timeout_cmd} "${DOWNLOAD_TIMEOUT}" ${_wget_cmd} "${_url}" >> "${LOG_FILE}" 2>&1
}

fetch_packages () {
  wget_cmd "${PACKAGE_URL}"

  if [ -n "${CHECKSUM_URL}" ]
  then
    wget_cmd "${CHECKSUM_URL}"
  fi
}

fetch_with_checksum () {
  if [ "${COUNTER}" -lt "${MAX_FETCH_RETRIES}" ]
  then
    fetch_packages

    # if download failed, retry.
    local _seconds=0
    if $(check_size) && $(match_checksum)
    then
     STATUS='success'
     log "Successfully downloaded ${PACKAGE_URL}"
    else
       (( _seconds = $COUNTER * 5 ))
       (( COUNTER++ ))
       log "Retrying download after ${_seconds} seconds"
       sleep "${_seconds}"

       log "Deleting content of directory ${DOWNLOAD_DIR}"
       rm -f ${DOWNLOAD_DIR}/*

       # recursice call
       fetch_with_checksum
    fi
  fi
}

downloaded_file_path () {
  if [ "${STATUS}" == 'success' ]
  then
    file_path "${PACKAGE_URL}"
  else
    log "[ERROR] No file was downloaded."
    return 1
  fi
}

######
##
## Main block

while getopts "c:d:r:l:t:u:h" optname
do
  case "$optname" in
    "c")
      # URL for the checksumm to download
      CHECKSUM_URL="${OPTARG:-''}"
      ;;
    "u")
      # URL for the package to download
      PACKAGE_URL="${OPTARG}"
      ;;
    "l")
      LOG_FILE="${OPTARG:-${LOG_FILE}}"
      ;;
    "r")
      MAX_FETCH_RETRIES="${OPTARG:-${MAX_FETCH_RETRIES}}"
      ;;
    "t")
      DOWNLOAD_TIMEOUT="${OPTARG:-${DOWNLOAD_TIMEOUT}}"
      ;;
    "d")
      DOWNLOAD_DIR_PREFIX="${OPTARG:-${DOWNLOAD_DIR_PREFIX}}"
      ;;
    "w")
      WGET_TIMEOUT="${OPTARG:-${WGET_TIMEOUT}}"
      ;;
    "h")
      usage
      exit 0
      ;;
    *)
      echo "Unknown error while processing options"
      usage
      exit 1
      ;;
  esac
done

validate_input
initialize
fetch_with_checksum
downloaded_file_path
