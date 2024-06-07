SCRIPT_NAME=$(basename "$0")
LOCK_FILE=/tmp/${SCRIPT_NAME}.lock
LOG_DIR="${SPACEFX_DIR}/logs/core-fileserver"
SHARE_DIR="${SPACEFX_DIR}/core-fileserver"
SCRIPT_START_TIME=$(date "+%Y%m%d_%H%M%S")
CACHE_DIR=/tmp/cache
UPDATE_FOUND=false

# Pull in the environment variable set by kubernetes
source "/proc/1/environ"

############################################################
# Reset the log file by renaming it with a timestamp and
# creating a new empty log file
############################################################
function reset_log() {
    local timestamp=$(date "+%Y%m%d_%H%M%S")
    local logFile="${SCRIPT_NAME}.log.${timestamp}"

    if [[ ! -d "${LOG_DIR}" ]]; then
        run_a_script "mkdir -p ${LOG_DIR}" --disable_log
    fi

    run_a_script "touch ${LOG_DIR}/${logFile}" --disable_log
    run_a_script "chmod u=rw,g=rw,o=rw ${LOG_DIR}/${logFile}" --disable_log

    LOG_FILE="${LOG_DIR}/${logFile}"
}

############################################################
# Log a message to both stdout and the log file with a
# specified log level
############################################################
function log() {
    # log informational messages to stdout
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local log_entry="${1}"
    local received_log_level="INFO"
    local full_log_entry=""
    local log_raw=false

    local configured_log_level=0
    case ${LOG_LEVEL^^} in
        ERROR)
            configured_log_level=4
            ;;
        WARN)
            configured_log_level=3
            ;;
        INFO)
            configured_log_level=2
            ;;
        DEBUG)
            configured_log_level=1
            ;;
        *)
            configured_log_level=0
            ;;
    esac

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --info)
                received_log_level="INFO"
                received_log_level_int=2
                ;;
            --debug)
                received_log_level="DEBUG"
                received_log_level_int=1
                ;;
            --warn)
                received_log_level="WARN"
                received_log_level_int=3
                ;;
            --error)
                received_log_level="ERROR"
                received_log_level_int=4
                ;;
            --trace)
                received_log_level="TRACE"
                received_log_level_int=0
                ;;
            --raw)
                log_raw=true
                ;;
        esac
        shift
    done

    if [[ ${log_raw} == false ]]; then
        full_log_entry="[${SCRIPT_NAME}] [${received_log_level}] ${timestamp}: ${log_entry}"
    else
        full_log_entry="${log_entry}"
    fi

    # Our log level isn't high enough - don't write it to the screen
    if [[ ${received_log_level_int} -lt ${configured_log_level} ]]; then
        return
    fi

    if [[ -n "${LOG_FILE}" ]]; then
        echo "${full_log_entry}" | tee -a "${LOG_FILE}"
    else
        echo "${full_log_entry}"
    fi


}

# Log an informational message to stdout and the log file
function info_log() {
    log "${1}" --info
}

# Log a trace message to stdout and the log file
function trace_log() {
    log "${1}" --trace
}

# Log an debug message to stdout and the log file
function debug_log() {
    log "${1}" --debug
}

# Log an warning message to stdout and the log file
function warn_log() {
    log "${1}" --warn
}

# Log an error message to stdout and the log file
function error_log() {
    log "${1}" --error
}

# Log a critical error and exit the script with a non-zero return code
function exit_with_error() {
    # log a message to stderr and exit 1
    error_log "${1}"
    exit 1
}


############################################################
# Helper function to run a script with/without sudo
# args
# position 1     : the command to run.  i.e. "docker container ls"
# position 2     : the variable to return the results of the script to for further processing
# --ignore_error : allow the script to continue even if the return code is not 0
# --disable_log  : prevent the output from writing to the log and screen
# --no_sudo      : prevent using sudo, even if it's available
############################################################
function run_a_script() {
    if [[ "$#" -eq 0 ]]; then
        exit_with_error "Missing run script to execute.  Please use function like run_a_script 'ls /'"
    fi

    local run_script="$1"
    local  __returnVar=$2
    RETURN_CODE=""
    # We're passing flags and not a return value.  Reset the return variable here
    if [[ "${__returnVar:0:2}" == "--" ]]; then
        __returnVar=""
    fi

    # Reset the __returnVar to empty just incase we're reusing variables somewhere
    if [[ -n ${__returnVar} ]]; then
        eval $__returnVar=""
    fi

    local log_enabled=true
    local ignore_error=false
    local no_sudo=false
    local returnResult=""

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --ignore_error)
                ignore_error=true
                ;;
            --disable_log)
                log_enabled=false
                ;;
            --no_sudo)
                no_sudo=true
                ;;
        esac
        shift
    done

    local run_cmd
    run_cmd="${run_script}"


    if [[ "${log_enabled}" == true ]]; then
        debug_log "Running '${run_cmd}'..."
    fi


    returnResult=$(eval "${run_cmd}")

    sub_exit_code=${PIPESTATUS[0]}
    RETURN_CODE=${PIPESTATUS[0]}
    if [[ -n ${__returnVar} ]]; then
        eval $__returnVar="'$returnResult'"
    fi

    if [[ "${log_enabled}" == true ]]; then
        debug_log "...'${run_cmd}' finished.  Exit code: ${sub_exit_code}"
        if [[ -z ${returnResult} ]]; then
            returnResult="null"
        fi
        debug_log "...'${run_cmd}' result.  Result: ${returnResult}"
    fi


    if [[ "${ignore_error}" == true ]]; then
        return
    fi

    if [[ $sub_exit_code -gt 0 ]]; then
        exit_with_error "Script failed.  Received return code of '${sub_exit_code}'.  Command ran: '${run_script}'.  See previous errors and retry"
    fi
}

############################################################
# Creates a new directory and grants access to it
############################################################
function create_directory() {
    if [[ "$#" -eq 0 ]]; then
        exit_with_error "Missing directory path to create.  Please use function like create_directory path_to_directory"
    fi

    local dir_to_create=$1

    if [[ -d "${dir_to_create}" ]]; then
        return
    fi

    run_a_script "mkdir -p ${dir_to_create}" --disable_log
    run_a_script "chmod -R 777 ${dir_to_create}" --disable_log
    run_a_script "chown -R ${USER:-$(id -un)} ${dir_to_create}" --disable_log
}


############################################################
# Generate the spacefx-config.json file used by the rest of the scripts
############################################################
function _setup_initial_directory() {
    local local_dir=$1

    if [[ -z "${local_dir}" ]]; then
        exit_with_error "A parameter is required for _setup_initial_directory.  Example: _setup_initial_directory bin"
    fi

    if [[ ! -d "${SPACEFX_DIR}/${local_dir}" ]]; then
       trace_log "Creating directory '${SPACEFX_DIR}/${local_dir}'..."
       create_directory "${SPACEFX_DIR}/${local_dir}"
       trace_log "...successfully created directory '${SPACEFX_DIR}/${local_dir}'"
    fi
}


############################################################
# Delete all old logs by checking for last 5 modified
############################################################
function cleanup_old_logs() {
    maximumNumOfLogs=5

    if [[ -f "${SPACEFX_SECRET_DIR}/maximumNumOfLogs" ]]; then
        run_a_script "cat ${SPACEFX_SECRET_DIR}/maximumNumOfLogs" maximumNumOfLogs
        maximumNumOfLogs=${maximumNumOfLogs//\"/}  # Remove the quotes from the string
        maximumNumOfLogs=$((maximumNumOfLogs)) # Cast as an integer
        maximumNumOfLogs=$((maximumNumOfLogs + 1)) # Add one to account for the lastest file
    fi

    info_log "Cleaning old logs by removing all but the last ${maximumNumOfLogs} logs..."

    run_a_script "ls ${LOG_DIR} -t -l | grep '^-' | awk '{print \$NF}' | tail -n +${maximumNumOfLogs}" stale_logs

    for logfile in $stale_logs; do
        debug_log "Removing '${LOG_DIR}/${logfile}'..."
	    rm "${LOG_DIR}/${logfile}" -rf
        debug_log "...successfully removed '${LOG_DIR}/${logfile}'"
    done

    info_log "Old logs cleaned"
}

############################################################
# Convert the number from the configuration into its bytes equivalent
############################################################
function calculate_share_disk_quota() {
    info_log "START: ${FUNCNAME[0]}"

    debug_log "Calculating configured disk quota from '${SPACEFX_SECRET_DIR}/xferDirectoryQuota'..."
    run_a_script "cat ${SPACEFX_SECRET_DIR}/xferDirectoryQuota" SHARE_DISK_QUOTA

    SHARE_DISK_QUOTA=${SHARE_DISK_QUOTA//\"/}  # Remove the quotes from the string

    debug_log "Disk Quota: ${SHARE_DISK_QUOTA}.  Converting to kilobytes..."
    # Convert the 10Gi to the bytes equivalent
    SHARE_DISK_QUOTA=$(echo ${SHARE_DISK_QUOTA} | numfmt --from=iec)

    # Convert it again to kilobytes
    SHARE_DISK_QUOTA=$(( SHARE_DISK_QUOTA / 1024 ))
    info_log "Disk Quota in kilobytes: ${SHARE_DISK_QUOTA} kb"

    info_log "END: ${FUNCNAME[0]}"
}

############################################################
# Check if users have been added or modified
############################################################
function check_users() {
    info_log "START: ${FUNCNAME[0]}"
    userFiles_to_process=()

    info_log "Scanning for users at '${SPACEFX_SECRET_DIR}'..."

    local id=""
    local group=""
    local gid=""

    run_a_script "find -L '${SPACEFX_SECRET_DIR:?}/' -mindepth 1 -maxdepth 1  -iname \"user-*\" -type f" all_user_files --disable_log

    for userFile in $all_user_files; do
        usernameFile=$(basename $userFile)
        run_a_script "stat -c %Y $userFile" mod_time --disable_log
        time_diff=$((current_time - mod_time))

        # This file has already been processed.  Skip it
        if [[ -f "${CACHE_DIR}/${usernameFile}.${mod_time}" ]]; then
            continue;
        fi
        info_log "Found new user to process '${userFile}'"
        userFiles_to_process+=($usernameFile)
    done

    if [[ ${#userFiles_to_process[@]} -eq 0 ]]; then
       info_log "No changes to users detected.  Nothing to do"
       info_log "END: ${FUNCNAME[0]}"
       return
    fi

    UPDATE_FOUND=true

    debug_log "Caching users (/etc/passwd)..."
    run_a_script "cut -d: -f1 /etc/passwd" current_users --disable_log
    debug_log "...successfully cached users."

    info_log "Processing new users..."
    for i in "${!userFiles_to_process[@]}"; do
        usernameFile=${userFiles_to_process[i]}
        username=${usernameFile#user-}
        info_log "...processing '${username}'"

        if [[ $current_users != *${username}* ]]; then
            debug_log "...not found in users.  Adding '${username}'..."
            run_a_script "adduser -D -H ${group:+-G $group} ${id:+-u $id} '$username'"
            debug_log "...successfully added '${username}'"
        fi

        debug_log "...setting password for '${username}'..."
        run_a_script "cat ${SPACEFX_SECRET_DIR:?}/${usernameFile}" password --disable_log
        run_a_script "smbpasswd -a '${username}'<<SPACEFX_UPDATE_END
${password}
${password}
SPACEFX_UPDATE_END" --disable_log

        debug_log "...successfully set password for '${username}'"

        check_user_share_config "${username}"

        debug_log "...calculating and storing mod time to detect changes..."
        run_a_script "stat -c %Y ${SPACEFX_SECRET_DIR:?}/${usernameFile}" userfile_mod_time
        debug_log "...modtime for '${username}' calculated as '${userfile_mod_time}'.  Storing to '${CACHE_DIR}/${usernameFile}.${userfile_mod_time}'..."
        run_a_script "touch ${CACHE_DIR}/${usernameFile}.${userfile_mod_time}"

        info_log "...successfully processed '${username}'"



    done

    info_log "END: ${FUNCNAME[0]}"
}

############################################################
# Add / check a share for a user
############################################################
function check_user_share_config() {
    info_log "START: ${FUNCNAME[0]}"
    local username="${1}"

    info_log "Processing shares for user '${username}'..."
    local source_template="/templates/_template"

    if [[ ! -f "${SHARE_DIR}/${username}.conf" ]]; then
        debug_log "...'${SHARE_DIR}/${username}.conf' not found..."

        # Hostsvc-link debugshims are prefixed with hostsvc-link.  This
        # allows use to use the hostsvc-link template for the alternate debug shims used
        # by hostsvc-link plugin development
        if [[ "${username}" == "hostsvc-link"* ]]; then
            debug_log "...hostsvc-link found.  Using special template '/templates/_template_hostsvc-link' found."
            source_template="/templates/_template_hostsvc-link"
        fi


        if [[ -f "/templates/_template_${username}" ]]; then
            debug_log "...special template '/templates/_template_${username}' found."
            source_template="/templates/_template_${username}"
        fi

        debug_log "...reading template '${source_template}'..."

        run_a_script "cat ${source_template}" source_template_contents

        debug_log "...updating template values..."
        source_template_contents="${source_template_contents//_templateUser/$username}"
        source_template_contents="${source_template_contents//_templateMaxDiskSize/$SHARE_DISK_QUOTA}"
        source_template_contents="${source_template_contents//_templateSpaceFxDir/$SPACEFX_DIR}"


        debug_log "...writing to '${SHARE_DIR}/${username}.conf'..."
        run_a_script "tee ${SHARE_DIR}/${username}.conf > /dev/null << SPACEFX_UPDATE_END
${source_template_contents}
SPACEFX_UPDATE_END" --no_sudo

        debug_log "...successfully added '${SHARE_DIR}/${username}.conf'"
    fi

    info_log "...scanning and provisioning any missing shares for '${SHARE_DIR}/${username}.conf'..."

    while IFS= read -r line; do
        if [[ "$line" == *"path"* ]]; then
            # Remove everything before the equals size
            path="${line#*=}"

            # And remove the trailing slash if there is one
            path=${path%/}

            # Remove the leading and trailing spaces
            path="${path#"${path%%[![:space:]]*}"}"
            path="${path%"${path##*[![:space:]]}"}"

            info_log "...checking for path '${path}'..."

            if [[ ! -d "${path}" ]]; then
                info_log "...'${path}' not found.  Creating '${path}'..."
                run_a_script "mkdir -p ${path}"
                info_log "...successfully created '${path}'"
            else
                info_log "...'${path}' already exists"
            fi

            # Only update the perms if the username is in the path
            # This stops hostsvc-link from taking all the perms
            # And prevents an extra inbox/output/tmp on the main xfer directory
            if [[ "${path}" == *"$username"* ]]; then
                if [[ $path == *"xfer"* ]]; then
                    debug_log "...xfer directory detected.  Checking / validating inbox/outbox/tmp subdirectories..."
                    [[ ! -d "${path}/inbox" ]] && run_a_script "mkdir -m 777 -p ${path}/inbox"
                    [[ ! -d "${path}/outbox" ]] && run_a_script "mkdir -m 777 -p ${path}/outbox"
                    [[ ! -d "${path}/tmp" ]] && run_a_script "mkdir -m 777 -p ${path}/tmp"
                    debug_log "...'${path}/inbox', '${path}/output', '${path}/tmp' sucessfully created"
                fi

                info_log "Updating permissions and ownership..."
                run_a_script "chown -Rh smbuser: ${path}"
                info_log "...successfully set ownership on '${path}' to '${username}'"
            fi
        fi
    done < "${SHARE_DIR}/${username}.conf"


    info_log "END: ${FUNCNAME[0]}"
}

############################################################
# Trigger the smb daemon to reload the config
############################################################
function reload_smb_config() {
    info_log "START: ${FUNCNAME[0]}"

    if [[ "${UPDATE_FOUND}" == false ]]; then
        info_log "No update found.  Nothing to do"
        info_log "END: ${FUNCNAME[0]}"
        return
    fi

    info_log "UPDATE_FOUND='true'.  Triggering config reload for new shares to take effect..."

    debug_log "Rebuilding '/etc/samba/includes.conf'"

    [[ -f "/etc/samba/includes.conf" ]] && run_a_script "rm /etc/samba/includes.conf"

    run_a_script "find -L '${SHARE_DIR}/' -mindepth 1 -maxdepth 1  -iname \"*.conf\" -type f" all_config_files --disable_log

    for configFile in $all_config_files; do
        debug_log "...adding '${configFile}' to '/etc/samba/includes.conf'..."
        run_a_script "tee -a /etc/samba/includes.conf > /dev/null << SPACEFX_UPDATE_END
include = ${configFile}
SPACEFX_UPDATE_END"
        debug_log "...successfully added '${configFile}' to '/etc/samba/includes.conf'"
    done

    debug_log "...Successfully rebuilt '/etc/samba/includes.conf'"

    debug_log "Triggering smb to reload config..."
    run_a_script "smbcontrol all reload-config"
    debug_log "...SMB successfully reloaded config."

    info_log "Successfully triggered config reload.  New shares are online."

    info_log "END: ${FUNCNAME[0]}"
}

function main(){
    touch "${LOCK_FILE}"
    reset_log

    # Get the log level, remove quotes and uppercase the result
    run_a_script "cat ${SPACEFX_SECRET_DIR}/logLevel" LOG_LEVEL --disable_log
    LOG_LEVEL=${LOG_LEVEL//\"/}
    LOG_LEVEL=${LOG_LEVEL^^}

    info_log "START: ${SCRIPT_NAME}"
    info_log "------------------------------------------"
    info_log "CONFIG VALUES:"
    info_log "LOG_LEVEL                   ${LOG_LEVEL}"
    info_log "LOG_DIR:                    ${LOG_DIR}"
    info_log "CACHE_DIR:                  ${CACHE_DIR}"
    info_log "SPACEFX_DIR:                ${SPACEFX_DIR}"
    info_log "SHARE_DIR:                  ${SHARE_DIR}"
    info_log "SPACEFX_SECRET_DIR:         ${SPACEFX_SECRET_DIR}"


    _setup_initial_directory "core-fileserver"
    _setup_initial_directory "xfer"
    _setup_initial_directory "plugins"

    [[ ! -d "${SHARE_DIR}" ]]; run_a_script "mkdir -p ${SHARE_DIR}"

    create_directory ${CACHE_DIR}

    if [[ -f "${SHARE_DIR}/reset" ]]; then
        warn_log "Found '${SHARE_DIR}/reset'.  Forcing re-processing of all users and shares..."
        [[ -d "${CACHE_DIR}" ]] && run_a_script "rm ${CACHE_DIR}/*" --ignore_error
        [[ -d "${SHARE_DIR}" ]] && run_a_script "rm ${SHARE_DIR}/*" --ignore_error

        [[ -f "/etc/samba/includes.conf" ]] && run_a_script "rm /etc/samba/includes.conf"

        UPDATE_FOUND=true
        info_log "...successfully reset."
    fi

    cleanup_old_logs
    calculate_share_disk_quota
    check_users
    reload_smb_config



    [[ -f "${LOCK_FILE}" ]] && run_a_script "rm ${LOCK_FILE}" --disable_log

    info_log "------------------------------------------"
    info_log "END: ${SCRIPT_NAME}"
}

if [[ -f "${LOCK_FILE}" ]]; then
    echo "Detected another instance of ${SCRIPT_NAME} already running.  Ending execution to prevent duplication"
    exit 0
fi

main


