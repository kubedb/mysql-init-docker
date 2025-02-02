#!/bin/sh

if [[ -z "$TOPOLOGY" ]]; then
    RECOVERY_DONE_FILE="/tmp/recovery.done"
    if [[ "$PITR_RESTORE" == "true" ]]; then
        while true; do
            sleep 2
            echo "Point In Time Recovery In Progress. Waiting for $RECOVERY_DONE_FILE file"
            if [[ -e "$RECOVERY_DONE_FILE" ]]; then
                echo "$RECOVERY_DONE_FILE found."
                break
            fi
        done
    fi

    if [[ -e "$RECOVERY_DONE_FILE" ]]; then
        rm $RECOVERY_DONE_FILE
    fi
fi
