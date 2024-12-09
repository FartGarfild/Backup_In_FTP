#!/bin/bash
# Переменные
DB_HOST="localhost"
DB_USER="root" #Пользователь всех баз данных
DB_PASSWORD="" #Пароль от пользователя (обычно находится по пути /root/.my.cnf)
#Настройки подключения FTP
SERVER="" #Сервер FTP
USER="" #Пользователь FTP
PASS="" #Пароль FTP
PORT="21" #На случай если нужно использовать SFTP 
WHERE2="/backup" #Путь в FTP хранилище куда будут идти файлы
MAX_FTP_SIZE="" #Размер FTP хранилища в ГБ.


# Пути
disk_path="/dev/vda1" # Для проверки места на диске (Проверяйте через df -h  какой диск /, его нужно прописать сюда)
BACKUP_DIR="/backup/tmp.bk/db" # Папка куда будут идти бекапы
log_file="/var/log/sh_backup.log" # Лог файл
FILESPATH="/"#Путь к папке которая будет копироваться

#Обработчик ошибок
handle_error() {
touch /var/log/sh_backup.log
    echo "ERROR." >> "$log_file"  # Логирование ошибки в файл
    cleanup_folder
    exit 1
}
# Установка обработчика ошибки
trap 'handle_error' ERR
#Очистка если скрипт завершился ошибкой
cleanup_folder() {
rm -rf /backup/tmp.bk
rm /backup/*.tar.gz
}
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
                echo "Не удалось определить пакетный менеджер для установки пакета $package_name" >> "$log_file"
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
    echo "Не удалось определить пакетный менеджер для установки пакетов" >> "$log_file"
    exit 1
fi
# Проверка и установка пакетов
check_and_install_package "curlftpfs" "$package_manager"
check_and_install_package "rsync" "$package_manager"
#Проверка указаны ли доступы FTP.
if [ -z "$SERVER" ] || [ -z "$USER" ] || [ -z "$PASS" ]; then
    echo "Не указаны параметры FTP подключения" >> "$log_file"
    exit 1
fi
# Проверка доступов mysql.
if ! mysql -h "${DB_HOST}" -u "${DB_USER}" -p"${DB_PASSWORD}" -e "SELECT 1" &> /dev/null; then
    echo "Ошибка подключения к базе данных" >> "$log_file"
    exit 1
fi
# Подключение к БД.
echo "Подключение" >> "$log_file"
curlftpfs -o allow_other ${USER}:${PASS}@${SERVER}:$PORT /mnt
if [ ! -w "/backup" ]; then
    echo "Недостаточно прав для записи в директорию /backup" >> "$log_file"
	umount /mnt
	cleanup_folder
    exit 1
fi
# Выполнение запроса к базе данных MySQL и извлечение общего размера
query="SELECT SUM(data_length + index_length) FROM information_schema.TABLES WHERE table_schema NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys');"
db_size=$(mysql -h "${DB_HOST}" -u "${DB_USER}" -p"${DB_PASSWORD}" -N -s -e "$query")

#Проверка на наличие папки бекап, если нет создаст.
if [ ! -d "/backup" ]; then
mkdir -p "/backup"
fi
mkdir /backup/tmp.bk
mkdir /backup/tmp.bk/web
mkdir /backup/tmp.bk/db

gb_to_kb() {
    echo $((${1} * 1024 * 1024))
}
# Получение максимального размера FTP хранилища в килобайтах
max_ftp_size_kb=$(gb_to_kb "$MAX_FTP_SIZE")
# Получение доступного места на диске в килобайтах
available_space=$(df -k --output=avail "$disk_path" | tail -n 1)
# Получение размера бэкапа в килобайтах
backup_size=$(du -sk "${FILESPATH}" | awk '{print $1}')
total_size=$((db_size + backup_size))
# Проверка места на диске
if [ "$total_size" -gt "$available_space" ]; then
    echo "Недостаточно свободного места на диске. Бэкап не может быть создан." >> "$log_file"
	cleanup_folder
    exit 1
fi
# Проверка размера бэкапа относительно максимального размера FTP хранилища
if [ "$total_size" -gt "$max_ftp_size_kb" ]; then
    echo "Размер бэкапа превышает максимальный размер FTP хранилища ($MAX_FTP_SIZE ГБ)." >> "$log_file"
	cleanup_folder
    exit 1
fi

#Проверка баз данных и исключение стандартных БД.
DB_LIST=$(mysql -h ${DB_HOST} -u ${DB_USER} -p${DB_PASSWORD} -e "SHOW DATABASES WHERE \`Database\` NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys');" | grep -v Database)

# Имя и путь для сохранения резервных копий
CURRENT_DATE=$(date +%Y-%m-%d)
BACKUP_PATH="${BACKUP_DIR}/db_backup_${CURRENT_DATE}.sql"
for DATABASE in ${DB_LIST}; do
    mysqldump -h ${DB_HOST} -u ${DB_USER} -p${DB_PASSWORD} --single-transaction --add-drop-table --create-options --disable-keys --extended-insert --quick --set-charset --routines --triggers ${DATABASE} > "${BACKUP_DIR}/${DATABASE}.sql"
done
# Само копирование файлов
echo "Копирование файлов сайтов" >> "$log_file"
rsync -azhP ${FILESPATH} /backup/tmp.bk/web
echo "Архивирование" >> "$log_file"
tar -cf /backup/backup_$(date +%Y-%m-%d).tar.gz /backup/tmp.bk
echo "Копирование" >> "$log_file"
rsync -azhP /backup/*.tar.gz /mnt/${WHERE2}
echo "Копирование завершено" >> "$log_file"
umount /mnt
cleanup_folder
echo "Скрипт завершён" >> "$log_file"
