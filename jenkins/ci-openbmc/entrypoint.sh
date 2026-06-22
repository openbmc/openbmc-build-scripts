#!/bin/bash
# entrypoint.sh - Container entrypoint that dynamically maps the internal
# container runtime account to the host Jenkins user's UID and GID.
# This prevents host filesystem permission pollution and eliminates
# "I have no name!" container runtime shell errors.

USER_ID=${LOCAL_UID:-1000}
GROUP_ID=${LOCAL_GID:-1000}

if getent group "$GROUP_ID" >/dev/null; then
    GROUP_NAME=$(getent group "$GROUP_ID" | cut -d: -f1)
else
    GROUP_NAME="hostgroup"
    groupadd -g "$GROUP_ID" "$GROUP_NAME"
fi

if getent passwd "$USER_ID" >/dev/null; then
    CURRENT_NAME=$(getent passwd "$USER_ID" | cut -d: -f1)
    if [ -n "$LOCAL_USER" ] && [ "$CURRENT_NAME" != "$LOCAL_USER" ]; then
        usermod -l "$LOCAL_USER" "$CURRENT_NAME"
        USER_NAME="$LOCAL_USER"
    else
        USER_NAME="$CURRENT_NAME"
    fi
else
    USER_NAME=${LOCAL_USER:-hostuser}
    useradd -u "$USER_ID" -g "$GROUP_ID" -s /bin/bash -m "$USER_NAME"
fi

export HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
export USER="$USER_NAME"
export LOGNAME="$USER_NAME"

exec gosu "$USER_NAME" "$@"
