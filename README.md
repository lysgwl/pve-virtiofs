# pve-virtiofs
pve-virtiofs-hook

# 宿主机与虚拟机之间的通信机制说明

### 通信架构
#### 宿主机侧
virtiofsd 作为守护进程运行，通过 Unix Socket（如 /run/virtiofsd/102-user_data.sock）暴露共享目录。
#### 虚拟机侧
使用 vhost-user-fs-pci 虚拟设备连接到宿主机 Socket，并通过内核的 virtiofs 驱动挂载文件系统。

### 数据通道
#### 共享内存（Shared Memory）
- 宿主机和虚拟机通过 memory-backend-memfd 对象共享内存区域，用于零拷贝传输文件数据。
- 内存大小由虚拟机配置的 memory 参数决定（默认 4GB）。
#### Virtio 协议层
- 虚拟机通过 PCI 设备（vhost-user-fs-pci）与宿主机 virtiofsd 建立通信。
- tag 参数（如 user_data）用于标识共享目录，需与挂载命令中的标签一致。

### 性能优化
#### 线程池配置
脚本中通过 --thread-pool-size=16 指定线程数，可根据宿主机 CPU 核心数调整。
#### 缓存策略
使用 --cache=auto 自动管理元数据和数据缓存，提升高频访问文件的性能。

### 注意事项
#### 目录权限隔离
确保宿主机共享目录（如 /mnt/user/data）的权限仅限于必要用户，避免虚拟机越权访问。
#### Socket 文件权限
virtiofsd 生成的 Socket 文件需限制为 qemu 用户或相关组访问，防止未授权进程连接。

### 故障排查
#### 服务状态检查
systemctl status virtiofs-102-user_data.service
#### Socket 连通性验证
sudo ss -a | grep virtiofsd
#### 虚拟机内核日志
dmesg | grep virtiofs