#!/bin/bash

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#                                                                             #
#                    SteamOS Easy NFS Mount Tool                              #
#                                                                             #
#   Based on SteamOS-Mount-Tool by Delil-A11yX                                #
#   https://github.com/Delil-A11yX/SteamOS-Mount-Tool                         #
#                                                                             #
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

MOUNT_BASE="/var/mnt"
UNIT_DIR="/etc/systemd/system"
SCAN_TIMEOUT=15
MANUAL_PATH="Type a path by hand"

# --- Helpers ---

pause_and_exit() {
    echo
    read -rp "Press Enter to exit."
    exit "${1:-0}"
}

# Turn any text into a safe folder name: lower-case, only a-z 0-9 . _ -
clean_name() {
    local name
    name=$(iconv -f UTF-8 -t ASCII//TRANSLIT <<<"$1" 2>/dev/null) || name="$1"
    local LC_ALL=C
    name="${name,,}"
    name="${name//[^a-z0-9._-]/-}"
    while [[ "$name" == *--* ]]; do name="${name//--/-}"; done
    while [[ "$name" == [-.]* ]]; do name="${name#?}"; done
    while [[ "$name" == *[-.] ]]; do name="${name%?}"; done
    echo "$name"
}

# True if the server answers on the NFS port (2049).
nfs_port_open() {
    # The single quotes are on purpose: the host is passed in as $0 so the
    # inner shell expands it, not this one.
    # shellcheck disable=SC2016
    timeout 3 bash -c 'exec 3<>"/dev/tcp/$0/2049"' "$1" 2>/dev/null
}

# showmount prints "<export path>   <allowed clients>". The client list never
# has spaces in it, so drop the last field and keep the rest as the path.
list_exports() {
    local host="$1" output rc
    # showmount ignores the normal stop signal while it waits, so use KILL.
    output=$(timeout -s KILL "$SCAN_TIMEOUT" showmount -e --no-headers "$host" 2>&1)
    rc=$?
    if [ $rc -ne 0 ]; then
        if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then
            output="No answer after ${SCAN_TIMEOUT} seconds."
        fi
        echo "$output" >&2
        return 1
    fi
    echo "$output" | sed -E 's/[[:space:]]+[^[:space:]]+$//' | grep -v '^[[:space:]]*$'
}

# Drop a trailing '/' so "/games" and "/games/" count as the same share.
norm_path() {
    local path="$1"
    while [[ "$path" == */ && "$path" != "/" ]]; do path="${path%/}"; done
    printf '%s' "$path"
}

# Split "server:/path" (or "[ipv6]:/path") into SPLIT_HOST and SPLIT_PATH.
split_source() {
    local raw="$1"
    if [[ "$raw" == \[*\]:/* ]]; then
        SPLIT_HOST="${raw%%]:*}"
        SPLIT_HOST="${SPLIT_HOST#[}"
        SPLIT_PATH="${raw#*]:}"
    elif [[ "$raw" == *:/* ]]; then
        SPLIT_HOST="${raw%%:/*}"
        SPLIT_PATH="/${raw#*:/}"
    else
        return 1
    fi
    [ -n "$SPLIT_HOST" ]
}

# True if two server addresses point at the same machine. The same server can
# be written as an IP, a short name or an FQDN, so also compare the addresses
# each name looks up to.
same_host() {
    local first="${1#[}" second="${2#[}" ips address
    first="${first%]}"
    second="${second%]}"
    [ "${first,,}" == "${second,,}" ] && return 0

    ips=$(getent ahosts "$second" 2>/dev/null | awk '{print $1}' | sort -u)
    [ -n "$ips" ] || return 1
    while read -r address; do
        [ -n "$address" ] || continue
        grep -qxF "$address" <<<"$ips" && return 0
    done < <(getent ahosts "$first" 2>/dev/null | awk '{print $1}' | sort -u)
    return 1
}

# Every NFS share this device already has, as "<source><tab><mount point>".
# Looks at systemd mount units, /etc/fstab, and what is mounted right now.
existing_nfs_mounts() {
    local file what where

    for file in "$UNIT_DIR"/*.mount; do
        [ -f "$file" ] || continue
        grep -qiE '^[[:space:]]*Type[[:space:]]*=[[:space:]]*nfs4?[[:space:]]*$' "$file" || continue
        what=$(sed -n -E 's/^[[:space:]]*What[[:space:]]*=[[:space:]]*//p' "$file" | head -n1)
        where=$(sed -n -E 's/^[[:space:]]*Where[[:space:]]*=[[:space:]]*//p' "$file" | head -n1)
        # A '%' is doubled inside unit files, so put it back to a single one.
        [ -n "$what" ] && printf '%s\t%s\n' "${what//%%/%}" "${where//%%/%}"
    done

    if [ -r /etc/fstab ]; then
        awk '$1 !~ /^#/ && ($3 == "nfs" || $3 == "nfs4") { print $1 "\t" $2 }' /etc/fstab
    fi

    findmnt --list --raw -t nfs,nfs4 -o SOURCE,TARGET -n 2>/dev/null |
        awk 'NF >= 2 { print $1 "\t" $2 }'
}

# --- Main Function ---
main() {
    # Writing to /etc/systemd/system needs root. Re-run with sudo if needed.
    if [ "$EUID" -ne 0 ]; then
        me=$(id -un)
        if passwd -S "$me" 2>/dev/null | grep -q "^$me NP "; then
            echo "This tool needs admin rights, but '$me' has no password yet."
            echo "Run 'passwd' in Konsole to set one, then start this tool again."
            pause_and_exit 1
        fi
        echo "This tool needs admin rights. Enter your password for '$me' (sudo)."
        if ! sudo -v; then
            echo "Could not get admin rights."
            pause_and_exit 1
        fi
        exec sudo bash "$0" "$@"
    fi

    clear
    echo "====================================================="
    echo "           Steam Deck Easy NFS Mount Tool"
    echo "====================================================="
    echo
    echo "This script will help you permanently auto-mount"
    echo "an NFS share on your SteamOS device."
    echo

    for tool in showmount mount.nfs systemd-escape; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "Error: '$tool' was not found. It is needed to set up NFS mounts."
            pause_and_exit 1
        fi
    done

    # --- Server Selection ---
    while true; do
        read -rp "Enter the IP address or name (FQDN) of your NFS server: " server
        # Accept pasted forms too: nfs://host/path, host:/path, [ipv6]:/path
        server="${server//[[:space:]]/}"
        [[ "${server,,}" == nfs://* ]] && server="${server:6}"
        server="${server%%/*}"
        [[ "$server" == *[!:]: ]] && server="${server%:}"
        server="${server#[}"
        server="${server%]}"

        if [ -z "$server" ]; then
            echo "No server entered. Aborting."
            pause_and_exit 1
        fi

        # A leading zero would make an IP number octal (010 = 8), so remove it.
        if [[ "$server" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
            server="$((10#${BASH_REMATCH[1]})).$((10#${BASH_REMATCH[2]})).$((10#${BASH_REMATCH[3]})).$((10#${BASH_REMATCH[4]}))"
        elif [[ "$server" =~ ^[0-9.]+$ ]]; then
            echo "'$server' is not a full IP address (it needs 4 numbers, like 192.168.1.10)."
            continue
        fi

        if ! getent ahosts "$server" >/dev/null 2>&1; then
            echo "Could not find '$server'. Check the spelling and your network, then try again."
            continue
        fi

        if ! nfs_port_open "$server"; then
            echo "$server does not answer on the NFS port (2049)."
            echo "Check the address and that NFS is turned on on the server, then try again."
            continue
        fi
        break
    done

    # IPv6 addresses need square brackets in "server:/path".
    if [[ "$server" == *:* ]]; then
        NFS_HOST="[$server]"
    else
        NFS_HOST="$server"
    fi

    # --- Share Selection ---
    echo
    echo "Scanning $server for shares..."
    echo "-----------------------------------------------------"

    mapfile -t shares < <(list_exports "$server")

    # Find the shares from this server that are already set up here, so they
    # can be left out of the list below.
    declare -A already_here=()
    while IFS=$'\t' read -r found_source found_where; do
        [ -n "$found_source" ] || continue
        split_source "$found_source" || continue
        same_host "$SPLIT_HOST" "$server" || continue
        # A real mount point always starts with '/', so '?' means "not known".
        already_here["$(norm_path "$SPLIT_PATH")"]="${found_where:-?}"
    done < <(existing_nfs_mounts)

    remaining=()
    hidden=()
    for share in "${shares[@]}"; do
        [ -n "$share" ] || continue
        share_key=$(norm_path "$share")
        share_where="${already_here["$share_key"]}"
        if [ -z "$share_where" ]; then
            remaining+=("$share")
        elif [ "$share_where" == "?" ]; then
            hidden+=("$share")
        else
            hidden+=("$share   (set up at $share_where)")
        fi
    done
    shares=("${remaining[@]}")

    if [ ${#hidden[@]} -gt 0 ]; then
        echo "These shares are already set up on this device, so they are not"
        echo "in the list below:"
        printf '    %s\n' "${hidden[@]}"
        echo
    fi

    if [ ${#shares[@]} -eq 0 ]; then
        if [ ${#hidden[@]} -gt 0 ]; then
            echo "Every share $server offers is already set up."
            echo "You can still type a path by hand, or cancel."
        else
            echo "No shares were listed by $server."
            echo "Some servers (NFSv4 only) do not share their list. If you know"
            echo "the path of the share, you can still type it in."
        fi
    fi

    echo "Please select the share you want to set up:"
    PS3="Enter the number of the share: "
    COLUMNS=1
    select choice in "${shares[@]}" "$MANUAL_PATH" "Cancel"; do
        if [ "$choice" == "Cancel" ]; then
            echo "Operation cancelled."
            exit 0
        elif [ "$choice" == "$MANUAL_PATH" ]; then
            while true; do
                read -rp "Enter the share path on the server (e.g. /mnt/user/games), or press Enter to go back: " choice
                if [ -n "$choice" ] && [[ "$choice" != /* ]]; then
                    echo "The path must start with '/'."
                    continue
                fi
                # An empty answer means "go back", so there is nothing to check.
                [ -n "$choice" ] || break
                manual_key=$(norm_path "$choice")
                manual_where="${already_here["$manual_key"]}"
                if [ -n "$manual_where" ]; then
                    if [ "$manual_where" == "?" ]; then
                        echo "$choice from $server is already set up on this device."
                    else
                        echo "$choice from $server is already set up at $manual_where."
                    fi
                    read -rp "Set it up again anyway? [y/N]: " answer
                    [[ "$answer" =~ ^[Yy] ]] || continue
                fi
                break
            done
            [ -n "$choice" ] && break
            echo "Enter the number of the share (press Enter to show the list again)."
        elif [ -n "$choice" ]; then
            break
        else
            echo "Invalid selection. Please try again."
        fi
    done

    # Ctrl-D ends the menu without a choice.
    if [[ "$choice" != /* ]]; then
        echo "No share selected. Aborting."
        pause_and_exit 1
    fi

    EXPORT_PATH="$choice"
    NFS_SOURCE="$NFS_HOST:$EXPORT_PATH"

    echo "-----------------------------------------------------"
    echo "Selected Server: $server"
    echo "Selected Share:  $EXPORT_PATH"
    echo "-----------------------------------------------------"

    # --- Get Mount Name ---
    default_name=$(clean_name "$(basename -- "$EXPORT_PATH")")
    offer_default=1
    replacing=0
    while true; do
        if [ $offer_default -eq 1 ] && [ -n "$default_name" ]; then
            read -rp "Mount it as '$default_name'? Press Enter to accept or type a new name: " new_name
            [ -z "$new_name" ] && new_name="$default_name"
        else
            read -rp "Enter a short, simple name for this share (e.g. 'games', no spaces), or press Enter to cancel: " new_name
            if [ -z "$new_name" ]; then
                echo "Operation cancelled."
                pause_and_exit 0
            fi
        fi
        offer_default=0

        mount_name=$(clean_name "$new_name")
        if [ -z "$mount_name" ]; then
            echo "That name has no usable letters or numbers. Please try again."
            continue
        fi

        MOUNT_PATH="$MOUNT_BASE/$mount_name"
        # systemd needs the unit name to match the path exactly (a '-' becomes '\x2d').
        UNIT_FILENAME=$(systemd-escape --path --suffix=mount "$MOUNT_PATH")
        UNIT_FILE_PATH="$UNIT_DIR/$UNIT_FILENAME"

        if [ -e "$UNIT_FILE_PATH" ] || [ -L "$UNIT_FILE_PATH" ]; then
            old_type=$(sed -n 's/^Type=//p' "$UNIT_FILE_PATH" 2>/dev/null)
            if [[ "$old_type" != nfs && "$old_type" != nfs4 ]]; then
                echo "The name '$mount_name' is already used by a mount that is not an"
                echo "NFS share (Type=${old_type:-unknown}), such as a local drive. Please pick a different name."
                continue
            fi
            echo "An NFS mount called '$mount_name' already exists:"
            grep -E '^What=' "$UNIT_FILE_PATH" | sed 's/^/    /'
            read -rp "Replace it? [y/N]: " answer
            if [[ "$answer" =~ ^[Yy] ]]; then
                replacing=1
                break
            fi
            echo "Please pick a different name."
        elif mountpoint -q "$MOUNT_PATH"; then
            echo "Something else is already mounted at $MOUNT_PATH. Please pick a different name."
        elif [ -d "$MOUNT_PATH" ] && [ -n "$(ls -A "$MOUNT_PATH" 2>/dev/null)" ]; then
            echo "Warning: $MOUNT_PATH already has files in it."
            echo "   They will be hidden (not deleted) while the share is mounted."
            read -rp "Continue anyway? [y/N]: " answer
            [[ "$answer" =~ ^[Yy] ]] && break
            echo "Please pick a different name."
        else
            break
        fi
    done

    # --- Create and Apply Configuration ---
    # Unmount the old share first. If it is busy, stop here and change nothing.
    if [ $replacing -eq 1 ] && systemctl is-active --quiet "$UNIT_FILENAME"; then
        echo "Unmounting the current $MOUNT_PATH..."
        if ! systemctl stop "$UNIT_FILENAME" || mountpoint -q "$MOUNT_PATH"; then
            echo "Error: $MOUNT_PATH is in use, so it could not be replaced."
            echo "   Close anything using it (Steam, a game, a file manager, a terminal"
            echo "   in that folder) and try again."
            pause_and_exit 1
        fi
    fi

    echo "Creating mount folder at $MOUNT_PATH..."
    mkdir -p "$MOUNT_PATH"

    echo "Creating systemd mount file for $MOUNT_PATH..."

    # '%' has a special meaning in unit files, so it must be doubled.
    cat > "$UNIT_FILE_PATH" <<EOF
[Unit]
Description=Mount NFS share ${NFS_SOURCE//%/%%}
Wants=network-online.target
After=network-online.target

[Mount]
What=${NFS_SOURCE//%/%%}
Where=$MOUNT_PATH
Type=nfs
Options=defaults,_netdev,nofail
TimeoutSec=30

[Install]
WantedBy=remote-fs.target
EOF

    echo "Activating the new service..."
    systemctl daemon-reload
    # reenable also clears boot links left by an older version of this unit.
    systemctl reenable "$UNIT_FILENAME" 2>/dev/null ||
        echo "Warning: could not enable the mount, so it may not come back after a reboot."

    echo "-----------------------------------------------------"
    if systemctl start "$UNIT_FILENAME" && findmnt -n -t nfs,nfs4 "$MOUNT_PATH" >/dev/null; then
        echo "✅ Success! Your NFS share is now mounted at $MOUNT_PATH"
        findmnt -n -o SOURCE,FSTYPE "$MOUNT_PATH" | sed 's/^/   /'
        echo "   It will mount again at each boot when the server can be reached."
        echo "   If the folder is ever empty (for example you started up away from"
        echo "   home), reconnect to your network and run:"
        echo "   sudo systemctl start $MOUNT_PATH"
        pause_and_exit 0
    fi

    server_ip=$(getent ahosts "$server" | awk 'NR==1 {print $1}')
    my_ip=$(ip -o route get "$server_ip" 2>/dev/null | sed -n 's/.* src \([^ ]*\).*/\1/p')
    echo "❌ Error! The share could not be mounted."
    journalctl -u "$UNIT_FILENAME" -n 5 --no-pager -o cat 2>/dev/null | sed 's/^/   /'
    echo "   Make sure the server allows this device (${my_ip:-its IP address}) for this share."
    echo "   Check the status with: systemctl status $MOUNT_PATH"
    pause_and_exit 1
}

# --- Run the main function ---
main "$@"
