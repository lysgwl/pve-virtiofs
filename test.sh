systemctl status virtiofs-user_data@102.service

systemctl status  virtiofsd-102-data@.service

systemctl daemon-reload 

systemctl list-units | grep virtiofs-102

qm config 102 | grep args

qm set 102 --delete args

qm set 102 --args ""

# 移除hook关联
qm set 100 --hookscript none

/usr/libexec/virtiofsd --socket-path=/var/run/virtiofs/102-user_data.sock --shared-dir=/mnt/user/data

mount -t virtiofs user_data /app/data
	
mount -t virtiofs data /mnt/data

user_data /app/data virtiofs defaults,_netdev 0 0

journalctl -u virtiofs-102-user_data.service

journalctl -u virtiofs-102-* -f

journalctl -b | grep "mount.*virtiofs"

根据以上脚本，结合以上命令操作，编写virtiofs服务网络共享挂载的TODO信息，并对virtiofs服务宿主机和虚拟机之间通信加以说明。