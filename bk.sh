#!/bin/bash
if [ ! -d "/etc/VestaCP" ] && [ ! -d "/etc/HestiaCP" ] && [ ! -d "/etc/cyberpanel" ] && [ ! -d "/usr/local/mgr5" ]; then
exit 1
fi
if [ ! -d "/backup" ]; then
mkdir -p "$FOLDER_PATH"
fi
cd /backup
mkdir /backup/tmp.bk
mkdir /backup/tmp.bk/web
mkdir /backup/tmp.bk/db

#Нужен для проверки какие БД есть на сервере и исключения ненужных.
DB_HOST="localhost"
DB_USER="root" #Пользователь баз данных
DB_PASSWORD="" #Пароль от пользователя 

#From FTP
USER="" #Пользователь FTP
PASS="" #Пароль FTP
SERVER="" #Сервер FTP
WHERE2=""#Путь в FTP хранилище куда будут идти файлы


DB_LIST=$(mysql -h $DB_HOST -u $DB_USER -p$DB_PASSWORD -e "SHOW DATABASES WHERE \`Database\` NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys');" | grep -v Database)

# Имя и путь для сохранения резервных копий
BACKUP_DIR="/backup/tmp.bk/db"
CURRENT_DATE=$(date +%Y-%m-%d)
BACKUP_PATH="$BACKUP_DIR/db_backup_$CURRENT_DATE.sql"
for DATABASE in $DB_LIST; do
    mysqldump -h $DB_HOST -u $DB_USER -p$DB_PASSWORD $DATABASE > "$BACKUP_DIR/$DATABASE.sql"
done
# Проверка наличия папки VestaCP в директории /etc
if [ -d "/etc/VestaCP" ]; then
    echo "Найдена папка VestaCP в директории /etc"
    # Ваши действия для VestaCP
	rsync -azhP /home/admin/web* /backup/tmp.bk/web
fi
# Проверка наличия папки HestiaCP в директории /etc
if [ -d "/etc/HestiaCP" ]; then
    echo "Найдена папка HestiaCP в директории /etc"
    # Ваши действия для HestiaCP
	rsync -azhP /home/admin/web* /backup/tmp.bk/web
fi
if [ -d "/etc/cyberpanel" ]; then
    echo "Найдена папка CyberPanel в директории /etc"
    # Ваши действия для HestiaCP
	rsync -azhP /home/* /backup/tmp.bk/web
fi
# Проверка наличия папки mgr5 в директории /usr/local
if [ -d "/usr/local/mgr5" ]; then
    echo "Найдена папка mgr5 в директории /usr/local"
    # Ваши действия для ISPManager
	rsync -azhP /var/www/www-root/data/www/* /backup/tmp.bk/web
fi

tar -cf /backup_$(date +%Y-%m-%d).tar.gz /backup/tmp.bk
curlftpfs -o allow_other $USER:$PASS@SERVER:21 /mnt
rsync -azhP /backup/*.tar.gz /$WHERE2
unmount /mnt
rm -rf /backup/tmp.bk
