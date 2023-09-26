#!/bin/bash
# Переменные
DB_HOST="localhost"
DB_USER="root" #Пользователь всех баз данных
DB_PASSWORD="" #Пароль от пользователя 
#Настройки подключения FTP
SERVER="" #Сервер FTP
USER="" #Пользователь FTP
PASS="" #Пароль FTP
PORT="21" #На случай если нужно использовать SFTP 
WHERE2=""#Путь в FTP хранилище куда будут идти файлы

# Пути (Нипутю - тут не хватает котиков)
disk_path="/dev/vda2" # Для проверки места на диске
BACKUP_DIR="/backup/tmp.bk/db" # Папка куда будут идти бекапы
log_file="/var/log/sh_backup.log" # Лог файл

#Обработчик ошибок
handle_error() {
touch /var/log/sh_backup.log
    echo "Ошибка выполнения кода." >> "$log_file"  # Логирование ошибки в файл
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
# Проверка наличия пакета и установка
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
else
    echo "Не удалось определить пакетный менеджер для установки пакетов" >> "$log_file"
    exit 1
fi
# Проверка и установка пакетов
check_and_install_package "curlftpfs" "$package_manager"
check_and_install_package "rsync" "$package_manager"

#Проверка на наличие одной из четырёх панелей управления, если нет ниодной скрипт останавливается
if [ ! -d "/etc/vesta" ] && [ ! -d "/etc/hestia" ] && [ ! -d "/etc/cyberpanel" ] && [ ! -d "/usr/local/mgr5" ]; then
echo "На сервере нет панели управления" >> "$log_file"
exit 1
fi
# Выполнение запроса к базе данных MySQL и извлечение общего размера
query="SELECT SUM(data_length + index_length) FROM information_schema.TABLES WHERE table_schema NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys');"
db_size=$(mysql -h "$db_host" -u "$db_user" -p"$db_password" -N -s -e "$query")
# Получение доступного места на диске в килобайтах
available_space=$(df -k --output=avail "$disk_path" | tail -n 1)
# Получение размера бэкапа в килобайтах
backup_size=$(du -sk "$files_directory" | awk '{print $1}')
total_size=$((db_size + backup_size))
# Сравнение размера бэкапа с доступным местом
if [ "$total_size" -gt "$available_space" ]; then
echo "Недостаточно свободного места на диске. Бэкап не может быть создан." >> "$log_file"
exit 1
fi
#Проверка на наличие папки бекап, если нет создаст.
if [ ! -d "/backup" ]; then
mkdir -p "/backup"
fi
mkdir /backup/tmp.bk
mkdir /backup/tmp.bk/web
mkdir /backup/tmp.bk/db
#Проверка баз данных и исключение стандартных БД.
DB_LIST=$(mysql -h ${DB_HOST} -u ${DB_USER} -p${DB_PASSWORD} -e "SHOW DATABASES WHERE \`Database\` NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys');" | grep -v Database)

# Имя и путь для сохранения резервных копий

CURRENT_DATE=$(date +%Y-%m-%d)
BACKUP_PATH="${BACKUP_DIR}/db_backup_${CURRENT_DATE}.sql"
for DATABASE in ${DB_LIST}; do
    mysqldump -h ${DB_HOST} -u ${DB_USER} -p${DB_PASSWORD} --single-transaction --add-drop-table --create-options --disable-keys --extended-insert --quick --set-charset --routines --triggers ${DATABASE} > "$BACKUP_DIR/$DATABASE.sql"
done
# Проверка наличия папки VestaCP в директории /etc
if [ -d "/etc/vesta" ]; then
    echo "Найдена папка VestaCP в директории /etc" >> "$log_file"
	rsync -azhP --exclude='/hoome/backup' /home/* /backup/tmp.bk/we
        files_directory="/home" 
 fi
# Проверка наличия папки HestiaCP в директории /etc
if [ -d "/etc/hestia" ]; then
    echo "Найдена папка HestiaCP в директории /etc" >> "$log_file"
	rsync -azhP --exclude='/home/backup' /home/* /backup/tmp.bk/web
        files_directory="/home" 
fi
if [ -d "/etc/cyberpanel" ]; then
    echo "Найдена папка CyberPanel в директории /etc"  >> "$log_file"
	rsync -azhP  /home/* /backup/tmp.bk/web
        files_directory="/home" 
fi
# Проверка наличия папки mgr5 в директории /usr/local
if [ -d "/usr/local/mgr5" ]; then
    echo "Найдена папка mgr5 в директории /usr/local" >> "$log_file"
	rsync -azhP /var/www/www-root/data/www/* /backup/tmp.bk/web
        files_directory="/home" 
fi
echo "Архивирование" >> "$log_file"
tar -cf /backup_$(date +%Y-%m-%d).tar.gz /backup/tmp.bk
echo "Подключение" >> "$log_file"
curlftpfs -o allow_other ${USER}:${PASS}@${SERVER}:$PORT /mnt
echo "Копирование" >> "$log_file"
cp /backup/*.tar.gz /${WHERE2}
echo "Копирование завершено" >> "$log_file"
umount /mnt
cleanup_folder
echo "Скрипт завершён" >> "$log_file"
