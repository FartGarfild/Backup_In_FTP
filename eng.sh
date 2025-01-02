#!/bin/bash
# Variables
DB_HOST="localhost"
DB_USER="root" # User for all databases
DB_PASSWORD="" # Password for the user (usually located at /root/.my.cnf)
# FTP connection settings
SERVER="" # FTP server
USER="" # FTP user
PASS="" # FTP password
WHERE2="/backup" # Path in FTP storage where files will be uploaded
TRANSPORT_METHOD="0" # 0 for standard FTP, 1 for SFTP (SSH) connection (less secure but faster method).
SKIP_MYSQL_BACKUP="false" # If there are no databases on the server, set to true.

KEEP_FILES=3 # Number of backups to keep.
MAX_FTP_SIZE="75" # FTP storage size in GB.
# Paths
disk_path="/dev/vda1" # For checking disk space (check with 'df -h' to see which disk / is, then specify here)
BACKUP_DIR="/backup/tmp.bk/db" # Folder where backups will go
log_file="/var/log/sh_backup.log" # Log file
FILESPATH="/" # Path to the folder that will be copied

# These variables should not be edited.
CURRENT_DATE=$(date +%Y-%m-%d)
LOCK_FILE="/var/lock/backup.lock" # Needed to prevent the script from running while another process is active.

# Clearing script logs on startup. (So the logs don’t fill up the disk and only display the latest entries).
> "$log_file"

# Error handler
handle_error() {
    touch /var/log/sh_backup.log
    echo "ERROR: $(date '+%Y-%m-%d %H:%M:%S') An error occurred during execution (code: $?)" >> "$log_file"  # Add error code (logging)
    cleanup_folder
    umount /mnt
    exit 1
}
# Set error handler
trap 'handle_error' ERR
# Preventing multiple instances of the script from running.
if [ -e "$LOCK_FILE" ]; then
    echo " $(date '+%Y-%m-%d %H:%M:%S') Previous backup process is still running" >> "$log_file"
    exit 1
fi

touch "$LOCK_FILE"
trap 'rm -f $LOCK_FILE' EXIT

# Cleanup if the script fails
cleanup_folder() {
    [ -d "/backup/tmp.bk" ] && rm -rf /backup/tmp.bk
    [ "$(ls /backup/*.tar.gz 2>/dev/null)" ] && rm /backup/*.tar.gz
}

# Checking if FTP access details are provided.
if [ -z "$SERVER" ] || [ -z "$USER" ] || [ -z "$PASS" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') FTP connection details are not provided" >> "$log_file"
    exit 1
fi
# Checking MySQL access.
if ! mysql -h "${DB_HOST}" -u "${DB_USER}" -p"${DB_PASSWORD}" -e "SELECT 1" &> /dev/null; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') Database connection error" >> "$log_file"
    exit 1
fi

# Check and install packages
install_package() {
    local package_name="$1”
    if ! command -v “$package_name” > /dev/null; then
        echo “Installing package $package_name...” >> “$log_file”
        sudo “$package_manager” install -y “$package_name”
    fi
}

# Define the package manager
if command -v apt-get > /dev/null; then
    package_manager="apt-get”
elif command -v yum > /dev/null; then
    package_manager="yum”
elif command -v dnf > /dev/null; then
    package_manager="dnf”
else
    echo “$(date ‘+%Y-%m-%d %H:%M:%S’) Failed to detect package manager to install packages” >> “$log_file”
    exit 1
fi

# Install the required packages depending on the transport method
if [ “$TRANSPORT_METHOD” = “0” ]; then
    install_package “curlftpfs”
    install_package “rsync”
    echo “$(date ‘+%Y-%m-%d %H:%M:%S’) Connecting via curlftpfs” >> “$log_file”
    curlftpfs -o allow_other ${USER}:${PASS}@${SERVER}:/ /mnt
else
    install_package “sshfs”
    install_package “sshpass”
    install_package “rsync”
    echo “$(date ‘+%Y-%m-%d %H:%M:%S’) Connecting via sshfs” >> “$log_file”
    sshpass -p “${PASS}” sshfs ${USER}@${SERVER}:/ /mnt
fi

# Checking if mount is successful.
if ! mountpoint -q /mnt; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') Mounting error" >> "$log_file"
    cleanup_folder
    exit 1
fi

# Running a query to MySQL database and retrieving the total size
query="SELECT SUM(data_length + index_length) FROM information_schema.TABLES WHERE table_schema NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys');"
db_size=$(mysql -h "${DB_HOST}" -u "${DB_USER}" -p"${DB_PASSWORD}" -N -s -e "$query")

# Checking if backup folder exists, if not it will be created.
if [ ! -d "/backup" ]; then
    mkdir -p /backup/tmp.bk/{web,db}
else
    if [ ! -w "/backup" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') Insufficient permissions to write to /backup directory" >> "$log_file"
        umount /mnt
        cleanup_folder
        exit 1
    fi
fi

# Converting to kilobytes.
gb_to_kb() {
    echo $((${1} * 1024 * 1024))
}

# Getting the maximum FTP storage size in kilobytes
max_ftp_size_kb=$(($(gb_to_kb "$MAX_FTP_SIZE") * 95 / 100))
# Getting the available disk space in kilobytes
available_space=$(df -k --output=avail "$disk_path" | tail -n 1)
# Getting the backup size in kilobytes
backup_size=$(du -sk "${FILESPATH}" | awk '{print $1}')
total_size=$((db_size + backup_size))
# Checking disk space
if [ "$total_size" -gt "$available_space" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') Insufficient free space on the disk. Backup cannot be created." >> "$log_file"
	cleanup_folder
    exit 1
fi
# Checking the backup size against the maximum FTP storage size
if [ "$total_size" -gt "$max_ftp_size_kb" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') Backup size exceeds the maximum FTP storage size ($MAX_FTP_SIZE GB)." >> "$log_file"
	cleanup_folder
    exit 1
fi

if [ "$SKIP_MYSQL_BACKUP" != "true" ]; then
    DB_LIST=$(mysql -h ${DB_HOST} -u ${DB_USER} -p${DB_PASSWORD} -e "SHOW DATABASES;" -s --skip-column-names | grep -v -E '^(information_schema|mysql|performance_schema|sys)$')
    
    # Name and path for saving backups
    BACKUP_PATH="${BACKUP_DIR}/db_backup_${CURRENT_DATE}.sql"

    # Backing up each database
    for DATABASE in ${DB_LIST}; do
        mysqldump -h ${DB_HOST} -u ${DB_USER} -p${DB_PASSWORD} --single-transaction --add-drop-table --create-options --disable-keys --extended-insert --quick --set-charset --routines --triggers ${DATABASE} > "${BACKUP_DIR}/${DATABASE}.sql"
    done
    echo "$(date '+%Y-%m-%d %H:%M:%S') MySQL backup completed" >> "$log_file"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') MySQL backup skipped" >> "$log_file"
fi

# File copying itself
echo "$(date '+%Y-%m-%d %H:%M:%S') Copying website files" >> "$log_file"
if ! rsync -azhP ${FILESPATH} /backup/tmp.bk/web; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') Error copying website files" >> "$log_file"
    cleanup_folder
    exit 1
fi
echo "$(date '+%Y-%m-%d %H:%M:%S') Archiving archive directly to FTP" >> "$log_file"
tar -czf "/mnt/${WHERE2}/backup_$(date +%Y-%m-%d).tar.gz" /backup/tmp.bk || {
    echo "$(date '+%Y-%m-%d %H:%M:%S') Error creating archive" >> "$log_file"
    cleanup_folder
    exit 1
}
# File rotation
ls -t "/mnt/${WHERE2}/backup_*.tar.gz" | tail -n +$((KEEP_FILES + 1)) | xargs -r -I {} sh -c 'rm -f "{}" && echo "{} removed" >> "$log_file"'
echo "$(date '+%Y-%m-%d %H:%M:%S') Copying finished" >> "$log_file"
umount /mnt
cleanup_folder
echo "$(date '+%Y-%m-%d %H:%M:%S') Script completed" >> "$log_file"
