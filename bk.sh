#!/bin/bash
# Переменные
DB_HOST="localhost"
DB_USER="root" #Пользователь всех баз данных
DB_PASSWORD="" #Пароль от пользователя (обычно находится по пути /root/.my.cnf)
#Настройки подключения FTP
SERVER="" #Сервер FTP
USER="" #Пользователь FTP
PASS="" #Пароль FTP
WHERE2="/backup" #Путь в FTP хранилище куда будут идти файлы
TRANSPORT_METHOD="0" # 0 Для использования обычного FTP, 1 для подключения по SFTP (SSH) (Менее безопасный но более быстрый метод).
SKIP_MYSQL_BACKUP="false" # Если на сервере нет баз данных то смените на true.

KEEP_FILES=3 # Количество бекапов.
MAX_FTP_SIZE="75" #Размер FTP хранилища в ГБ.
# Пути
disk_path="/dev/vda1" # Для проверки места на диске (Проверяйте через df -h  какой диск /, его нужно прописать сюда)
BACKUP_DIR="/backup/tmp.bk/db" # Папка куда будут идти бекапы
log_file="/var/log/sh_backup.log" # Лог файл
FILESPATH="/"#Путь к папке которая будет копироваться

# Эти переменные не редактировать.
CURRENT_DATE=$(date +%Y-%m-%d)
LOCK_FILE="/var/lock/backup.lock" # Нужен чтобы не запускался скрипт пока уже запущен другой процесс.

# Зачистка логов скрипта при запуске. ( Что бы логи не заняли всё место на диске а отображались лишь последние).
> "$log_file"

#Обработчик ошибок
handle_error() {
    touch /var/log/sh_backup.log
    echo "ERROR: $(date '+%Y-%m-%d %H:%M:%S') Произошла ошибка на этапе выполнения (код: $?)" >> "$log_file"  # Добавить код ошибки ( логирование )
    cleanup_folder
    umount /mnt
    exit 1
}
# Установка обработчика ошибки
trap 'handle_error' ERR
# Предотвращения запуска нескольких екземпляров скрипта.
if [ -e "$LOCK_FILE" ]; then
    echo " $(date '+%Y-%m-%d %H:%M:%S') Предыдущий процесс бэкапа всё ещё выполняется" >> "$log_file"
    exit 1
fi

touch "$LOCK_FILE"
trap 'rm -f $LOCK_FILE' EXIT

#Очистка если скрипт завершился ошибкой
cleanup_folder() {
    [ -d "/backup/tmp.bk" ] && rm -rf /backup/tmp.bk
    [ "$(ls /backup/*.tar.gz 2>/dev/null)" ] && rm /backup/*.tar.gz
}

#Проверка указаны ли доступы FTP.
if [ -z "$SERVER" ] || [ -z "$USER" ] || [ -z "$PASS" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') Не указаны параметры FTP подключения" >> "$log_file"
    exit 1
fi
# Проверка доступов mysql.
if ! mysql -h "${DB_HOST}" -u "${DB_USER}" -p"${DB_PASSWORD}" -e "SELECT 1" &> /dev/null; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') Ошибка подключения к базе данных" >> "$log_file"
    exit 1
fi

# Проверка пакетов.
check_and_install_package() {
    local package_name="$1"
    local package_manager="$2"
    if ! command -v "$package_name" > /dev/null; then
        echo "Установка пакета $package_name..." >> "$log_file"
         case "$package_manager" in
            apt)
                sudo apt-get update
                sudo apt-get install -y "$package_name"
                ;;
            yum)
                sudo yum install -y "$package_name"
                ;;
			dnf)
                sudo dnf install -y "$package_name"
                ;;
            *)
                echo " $(date '+%Y-%m-%d %H:%M:%S') Не удалось определить пакетный менеджер для установки пакета $package_name" >> "$log_file"
                ;;
        esac
    fi
}

# Проверка пакетного менеджера
if command -v apt-get > /dev/null; then
    package_manager="apt"
elif command -v yum > /dev/null; then
    package_manager="yum"
elif command -v dnf > /dev/null; then
    package_manager="dnf"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') Не удалось определить пакетный менеджер для установки пакетов" >> "$log_file"
    exit 1
fi

# Проверка и установка пакетов
if [ "$TRANSPORT_METHOD" = "0" ]; then
    check_and_install_package "curlftpfs" "$package_manager"
    check_and_install_package "rsync" "$package_manager"
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') Подключение через curlftpfs" >> "$log_file"
    curlftpfs -o allow_other ${USER}:${PASS}@${SERVER}:/ /mnt
else
    check_and_install_package "sshfs" "$package_manager"
    check_and_install_package "sshpass" "$package_manager"
    check_and_install_package "rsync" "$package_manager"

        echo "$(date '+%Y-%m-%d %H:%M:%S') Подключение через sshfs" >> "$log_file"
    sshpass -p "${PASS}" sshfs ${USER}@${SERVER}:/ /mnt
fi

# Проверка монтирования.
if ! mountpoint -q /mnt; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') Ошибка монтирования" >> "$log_file"
    cleanup_folder
    exit 1
fi

# Выполнение запроса к базе данных MySQL и извлечение общего размера
query="SELECT SUM(data_length + index_length) FROM information_schema.TABLES WHERE table_schema NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys');"
db_size=$(mysql -h "${DB_HOST}" -u "${DB_USER}" -p"${DB_PASSWORD}" -N -s -e "$query")

#Проверка на наличие папки бекап, если нет создаст.
if [ ! -d "/backup" ]; then
    mkdir -p /backup/tmp.bk/{web,db}
else
    if [ ! -w "/backup" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') Недостаточно прав для записи в директорию /backup" >> "$log_file"
        umount /mnt
        cleanup_folder
        exit 1
    fi
fi

# Пересчёт в килобайты.
gb_to_kb() {
    echo $((${1} * 1024 * 1024))
}

# Получение максимального размера FTP хранилища в килобайтах
max_ftp_size_kb=$(($(gb_to_kb "$MAX_FTP_SIZE") * 95 / 100))
# Получение доступного места на диске в килобайтах
available_space=$(df -k --output=avail "$disk_path" | tail -n 1)
# Получение размера бэкапа в килобайтах
backup_size=$(du -sk "${FILESPATH}" | awk '{print $1}')
total_size=$((db_size + backup_size))
# Проверка места на диске
if [ "$total_size" -gt "$available_space" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') Недостаточно свободного места на диске. Бэкап не может быть создан." >> "$log_file"
	cleanup_folder
    exit 1
fi
# Проверка размера бэкапа относительно максимального размера FTP хранилища
if [ "$total_size" -gt "$max_ftp_size_kb" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') Размер бэкапа превышает максимальный размер FTP хранилища ($MAX_FTP_SIZE ГБ)." >> "$log_file"
	cleanup_folder
    exit 1
fi

if [ "$SKIP_MYSQL_BACKUP" != "true" ]; then
    DB_LIST=$(mysql -h ${DB_HOST} -u ${DB_USER} -p${DB_PASSWORD} -e "SHOW DATABASES;" -s --skip-column-names | grep -v -E '^(information_schema|mysql|performance_schema|sys)$')
    
    # Имя и путь для сохранения резервных копий
    BACKUP_PATH="${BACKUP_DIR}/db_backup_${CURRENT_DATE}.sql"

    # Резервное копирование каждой базы данных
    for DATABASE in ${DB_LIST}; do
        mysqldump -h ${DB_HOST} -u ${DB_USER} -p${DB_PASSWORD} --single-transaction --add-drop-table --create-options --disable-keys --extended-insert --quick --set-charset --routines --triggers ${DATABASE} > "${BACKUP_DIR}/${DATABASE}.sql"
    done
    echo "$(date '+%Y-%m-%d %H:%M:%S') Резервное копирование MySQL завершено" >> "$log_file"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') Резервное копирование MySQL пропущено" >> "$log_file"
fi

# Само копирование файлов
echo "$(date '+%Y-%m-%d %H:%M:%S') Копирование файлов сайтов" >> "$log_file"
if ! rsync -azhP ${FILESPATH} /backup/tmp.bk/web; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') Ошибка при копировании файлов сайтов" >> "$log_file"
    cleanup_folder
    exit 1
fi
echo "$(date '+%Y-%m-%d %H:%M:%S') Архивирование архива напрямую в FTP" >> "$log_file"
tar -czf "/mnt/${WHERE2}/backup_$(date +%Y-%m-%d).tar.gz" /backup/tmp.bk || {
    echo "$(date '+%Y-%m-%d %H:%M:%S') Ошибка при создании архива" >> "$log_file"
    cleanup_folder
    exit 1
}
# Ротация файлов
ls -t "/mnt/${WHERE2}/backup_*.tar.gz" | tail -n +$((KEEP_FILES + 1)) | xargs -r -I {} sh -c 'rm -f "{}" && echo "{} удалён" >> "$log_file"'
echo "$(date '+%Y-%m-%d %H:%M:%S') Копирование завершено" >> "$log_file"
umount /mnt
cleanup_folder
echo "$(date '+%Y-%m-%d %H:%M:%S') Скрипт завершён" >> "$log_file"
