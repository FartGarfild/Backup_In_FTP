#!/bin/bash
# Variables
DB_HOST="localhost"
DB_USER="root" # User of all databases
DB_PASSWORD="" # User password (usually found at /root/.my.cnf)
# FTP connection settings
SERVER="" # FTP server
USER="" # FTP user
PASS="" # FTP password
WHERE2="/backup" # Path in the FTP storage where files will be sent
TRANSPORT_METHOD="0" # 0 for using regular FTP, 1 for connecting via SFTP (SSH) (less secure but faster method).
SKIP_MYSQL_BACKUP="false" # Set to true if there are no databases on the server.

KEEP_FILES=3 # Number of backups.
MAX_FTP_SIZE="75" # FTP storage size in GB.
# Paths
disk_path="/dev/vda1" # To check disk space (Check which disk is / using df -h and specify it here)
BACKUP_DIR="/backup/tmp.bk/db" # Folder where backups will be stored
log_file="/var/log/sh_backup.log" # Log file
FILESPATH="/" # Path to the folder to be copied

# These variables should not be edited.
CURRENT_DATE=$(date +%Y-%m-%d)
LOCK_FILE="/var/lock/backup.lock" # Ensures that another script process does not start while one is already running.

# Log cleanup at script start. (Prevents logs from taking up all disk space and only shows recent logs).
> "$log_file"

# Error handler
handle_error() {
    touch /var/log/sh_backup.log
    echo "ERROR: $(date '+%Y-%m-%d %H:%M:%S') An error occurred during execution (code: $?)" >> "$log_file"  # Log the error code
    cleanup_folder
    umount /mnt
    exit 1
}
# Set error handler
trap 'handle_error' ERR
# Prevent multiple instances of the script from running.
if [ -e "$LOCK_FILE" ]; then
    echo " $(date '+%Y-%m-%d %H:%M:%S') The previous backup process is still running" >> "$log_file"
    exit 1
fi

touch "$LOCK_FILE"
trap 'rm -f $LOCK_FILE' EXIT

# Cleanup in case of script error
cleanup_folder() {
    [ -d "/backup/tmp.bk" ] && rm -rf /backup/tmp.bk
    [ "$(ls /backup/*.tar.gz 2>/dev/null)" ] && rm /backup/*.tar.gz
}

# Check if FTP credentials are specified.
if [ -z "$SERVER" ] || [ -z "$USER" ] || [ -z "$PASS" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') FTP connection parameters are not specified" >> "$log_file"
    exit 1
fi
# Check MySQL credentials.
if [ "$SKIP_MYSQL_BACKUP" != "true" ]; then
    if ! mysql -h "${DB_HOST}" -u "${DB_USER}" -p"${DB_PASSWORD}" -e "SELECT 1" &> /dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') Error connecting to the database" >> "$log_file"
        exit 1
    fi
