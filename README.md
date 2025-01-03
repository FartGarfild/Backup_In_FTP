# Backup_In_FTP
Requires rsync and Curlftpfs (or rsync, sshfs and sshpass), it will install the missing software if it is not available.
This script is untested, so it may contain bugs and work incorrectly.
The essence of the script is to backup files from any directory that will be specified in the script and databases to a third-party FTP storage or other server. 
You can disable mysql copying if there is no database server.
