#!/bin/bash
source "/proc/1/environ"

# Start the samba server
smbd --no-process-group

# Pull the pollingTimeSecs and remove the quotes
POLLING_TIME_SECS=$(cat ${SPACEFX_SECRET_DIR}/pollingTimeSecs)
POLLING_TIME_SECS=${POLLING_TIME_SECS//\"/}

# Loop every 5 seconds to trigger the core-fileserver.sh
while true; do
    /core-fileserver.sh || true
    echo ""
    echo ""
    echo "core-fileserver.sh completed.  Rerunning in '${POLLING_TIME_SECS}' seconds..."
    echo ""
    echo ""
    sleep ${POLLING_TIME_SECS}
done