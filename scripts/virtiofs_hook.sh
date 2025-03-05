#!/bin/bash
set -euo pipefail

# 服务名称
VIRTIOFS_SERVICE_NAME="virtiofs"

# VirtioFS Socket 路径
VIRTIOFS_SOCKET_PATH="/run/${VIRTIOFS_SERVICE_NAME}d"

# VirtioFS 服务路径
VIRTIOFS_SERVICE_PATH="/etc/systemd/system"

# VirtioFS 脚本路径
VIRTIOFS_SCRIPT_PATH=$(dirname "$(readlink -f "$0")")

# VirtioFS 配置文件
VIRTIOFS_CONF_FILE="/mnt/other/snippets/${VIRTIOFS_SERVICE_NAME}.conf"

# 全局关联数组存储共享目录
declare -gA VIRTIOFS_SHARES

# 安装Virtio-FS环境
install_virtiofs_env()
{
	echo "[INFO] 安装 ${VIRTIOFS_SERVICE_NAME} 服务环境..."
	
	echo "[SUCCESS] 安装 ${VIRTIOFS_SERVICE_NAME} 环境完成!"
	return 0
}

# 获取配置信息
get_virtiofs_conf()
{
	local vmid=$1
	echo "[INFO] 获取 ${VIRTIOFS_SERVICE_NAME} 服务配置..."
	
	[[ ! -f "${VIRTIOFS_CONF_FILE}" ]] && return 1

	# 解析目录配置
	while IFS=':' read -r vm_id paths; do
		if [[ "${vm_id}" == "${vmid}" ]]; then
			# 去空格后分割
			IFS=',' read -ra path_arr <<< "${paths// /}"
			
			for path in "${path_arr[@]}"; do
				# 去除开头的斜杠
				local trim_path="${path#/}"
				IFS='/' read -ra parts_arr <<< "${trim_path}"
				
				local parts_num=${#parts_arr[@]}
				if [[ ${parts_num} -eq 0 ]]; then
					echo "[ERROR] 无效路径配置, 请检查! ${path}" >&2
					continue
				fi
				
				local share_id=""
				if [[ ${parts_num} -ge 2 ]]; then
					share_id="${parts_arr[-2]}_${parts_arr[-1]}"
				else
					share_id="${parts_arr[0]}"
				fi
				
				VIRTIOFS_SHARES["${share_id}"]="${path}"
			done
			
			break
		fi
	done < <(grep -v '^#' "${VIRTIOFS_CONF_FILE}")
	
	return 0
}

# 获取虚拟机配置
get_vm_config()
{
	local vmid=$1
	
	if [ -z "$vmid" ]; then
        return 1
    fi
	
	# 嵌入 Perl 代码
	local vm_conf=$(perl -e '
		use strict;
		use warnings;
		use PVE::QemuServer;
        use PVE::QemuConfig;
        use JSON;
		
		# 获取虚拟机 ID 
        my $vmid = shift;
		
		my $conf;
		eval {
            $conf = PVE::QemuConfig->load_config($vmid);
        };
		
		if ($@) {
            print STDERR "[ERROR] 加载配置时出错: $@\n";
            exit 1;
        }
		
		print encode_json($conf);
	' "${vmid}")
	
	# 检查 Perl 代码执行状态
	if [ $? -ne 0 ]; then
        echo "[ERROR] 获取虚拟机(VM:${vmid})出错，请检查!" >&2
        return 1
    fi
	
	echo "${vm_conf}"
	return 0
}

# 设置虚拟机配置
set_vm_config()
{
	local vmid=$1 vmargs=$2
	
	# 嵌入 Perl 代码
	perl -e '
		use strict;
        use warnings;
        use PVE::QemuConfig;
		
		# 获取命令行参数
        my ($vmid, $vfs_args) = @ARGV;
		
		# 加载配置
		my $conf = PVE::QemuConfig->load_config(${vmid});
		
		#print "##$conf->{args}##\n";
		#print "##$vfs_args##\n";
		
		if (defined($conf->{args}) && not $conf->{args} =~ /$vfs_args/)
		{
			$conf->{args} .= " $vfs_args";
		}
		else
		{
			$conf->{args} = " $vfs_args";
		}
		
		# 写入配置
        PVE::QemuConfig->write_config($vmid, $conf);
		
	' "${vmid}" "${vmargs}"
	
	# 检查 Perl 代码执行状态
	if [ $? -ne 0 ]; then
        echo "[ERROR] 设置虚拟机(VM:${vmid})出错，请检查!" >&2
        return 1
    fi
	
	return 0
}

# 清空虚拟机配置
clean_vm_config()
{
	local vmid=$1 vmcfg=$2
	
	# 嵌入 Perl 代码
	perl -e '
		use strict;
        use warnings;
        use PVE::QemuConfig;
		
		# 获取命令行参数
        my ($vmid, $vfs_args) = @ARGV;
		
		# 加载配置
		my $conf = PVE::QemuConfig->load_config(${vmid});
		
		if ($conf->{args} =~ /$vfs_args/)
		{
			$conf->{args} =~ s/\ *$vfs_args//g;
			print $conf->{args};
			
			$conf->{args} = undef if $conf->{args} =~ /^$/;
			if (defined $conf->{args})
			{
				print "conf->args = $conf->{args}\n";
			}
			else
			{
				print "conf->args = undef\n";
			}
			
			PVE::QemuConfig->write_config($vmid, $conf) if defined($conf->{args});
		}
	' "${vmid}" "${vmcfg}"
	
	# 检查 Perl 代码执行状态
	if [ $? -ne 0 ]; then
        echo "[ERROR] 设置虚拟机(VM:${vmid})出错，请检查!" >&2
    fi
}

# 生成systemd服务单元
generate_systemd_unit()
{
	local vmid=$1
	declare -n shares_ref=$2
	
	echo "[INFO] 生成 ${VIRTIOFS_SERVICE_NAME} 服务单元..."
	
	for share_id in "${!shares_ref[@]}"; do
		local share_path="${shares_ref[${share_id}]}"
		[ ! -d "${share_path}" ] && continue
		
		local unit_name="${VIRTIOFS_SERVICE_NAME}-${share_id}@${vmid}"
		local unit_file="${VIRTIOFS_SERVICE_PATH}/${unit_name}.service"
		
		if [ ! -f "${unit_file}" ]; then
			local socket_path="${VIRTIOFS_SOCKET_PATH}/${vmid}-${share_id}.sock"
			local pid_file="${VIRTIOFS_SOCKET_PATH}/${vmid}-${share_id}.pid"
			
			cat > ${unit_file} <<EOF
[Unit]
Description=Virtio-FS for VM ${vmid}
StopWhenUnneeded=true

[Service]
Type=simple
RuntimeDirectory=${VIRTIOFS_SERVICE_NAME}d
PIDFile=${pid_file}
ExecStart=/usr/libexec/virtiofsd \\
	--socket-path=${socket_path} \\
	--shared-dir=${share_path} \\
	--cache=auto \\
	--announce-submounts \\
	--inode-file-handles=mandatory \\
	--thread-pool-size=16

[Install]
RequiredBy=${vmid}.scope
EOF
			systemctl daemon-reload
			systemctl enable --now "${unit_name}.service" &>/dev/null
		fi
		
		systemctl start "${unit_name}.service" &>/dev/null
	done
}

# 生成 QEMU 设备参数
generate_qemu_args()
{
	local vmid=$1 vmcfg=$2
	declare -n shares_ref=$3

	# 从虚拟机配置动态获取内存大小
	local vm_memory=$(echo "${vmcfg}" | jq -r '.memory? // empty')
	vm_memory=${vm_memory:-4096}  # 默认 4G
	
	# 唯一 ID
	local mem_id="mem-${vmid}"
	
	# 固定参数部分
	local qemu_args=""
	qemu_args+="-object memory-backend-memfd,id=${mem_id},size=${vm_memory}M,share=on -numa node,memdev=${mem_id}"
	
	# 动态设备参数设置
	local char_id=0
	for share_id in "${!shares_ref[@]}"; do
		local share_path="${shares_ref[$share_id]}"
		[ ! -d "${share_path}" ] && continue
		
		local socket_path="${VIRTIOFS_SOCKET_PATH}/${vmid}-${share_id}.sock"
		
		# 构建设备参数
		qemu_args+=" -chardev socket,id=char${char_id},path=${socket_path}"
		qemu_args+=" -device vhost-user-fs-pci,chardev=char${char_id},tag=${share_id}"
		
		((char_id++))
	done
	
	[[ $char_id -eq 0 ]] && {
        echo "[ERROR] 未生成有效设备参数，请检查!" >&2
        return 1
    }
	
	# 添加唯一标记
	echo "$qemu_args"
	return 0
}

# 设置Virtio-FS环境
set_virtiofs_env()
{
	local vmid=$1 vmcfg=$2
	echo "[INFO] 设置 ${VIRTIOFS_SERVICE_NAME} 服务..."
	
	if [ ! -d "${VIRTIOFS_SOCKET_PATH}" ]; then
		mkdir -p "${VIRTIOFS_SOCKET_PATH}"
	fi
	
	# 生成共享目录的服务单元
	generate_systemd_unit "${vmid}" VIRTIOFS_SHARES
	
	# 生成 QEMU 设备参数
	echo "[INFO] 生成 ${VIRTIOFS_SERVICE_NAME} 设备参数..."
	if ! qemu_args=$(generate_qemu_args "${vmid}" "${vmcfg}" VIRTIOFS_SHARES); then
		echo "[ERROR] 生成 QEMU 参数失败, 请检查!"
		return 1
	fi
	
	# 更新虚拟机配置
	echo "[INFO] 更新虚拟机(VM:${vmid})参数..." >&2
	if ! set_vm_config "${vmid}" "${qemu_args}"; then
		echo "[ERROR] 设置 QEMU 参数失败, 请检查!"
		return 1
	fi
	
	echo "[SUCCESS] 设置 ${VIRTIOFS_SERVICE_NAME} 服务完成!"
	return 0
}

# 处理 pre-start 阶段
handle_pre_start()
{
	local vmid=$1 vmconf=$2
	echo "[INFO] 设置虚拟机(VM:${vmid}) ${VIRTIOFS_SERVICE_NAME} 服务..."
	
	if ! get_virtiofs_conf "${vmid}"; then
		echo "[ERROR] 获取虚拟机(VM:${vmid})配置失败, 请检查!"  >&2
		return 1
	fi
	
	if ! set_virtiofs_env "${vmid}" "${vmconf}"; then
		return 1
	fi
	
	return 0
}

# 处理 post-start 阶段
handle_post_start()
{
	local vmid=$1 vmconf=$2
	
	# 定义要移除的virtiofs相关参数模式
	local patterns=(
		"-object memory-backend-memfd,id=mem[^ ]+"
		"-object memory-backend-memfd,id=mem-${vmid}[^ ]+"
		"-numa node,memdev=mem"
		"-numa node,memdev=mem-${vmid}"
		"-chardev socket,id=char[0-9]+"
		"-device vhost-user-fs-pci,tag=[^ ]+"
	)
	
	# 获取当前args配置
    local current_args=$(echo "${vmconf}" | jq -r '.args? // empty')
    [ -z "${current_args}" ] && return
	
	# 构建sed替换命令
	local cmd_pattern=("sed")
	for pattern in "${patterns[@]}"; do
		cmd_pattern+=(-e "s/\\<${pattern}\\>//g")
	done

	# 使用sed删除标记之间的内容（包括标记本身）
    local new_args=$("${cmd_pattern[@]}" <<< "${current_args}" | tr -s ' ')
	
	# 更新虚拟机配置
    clean_vm_config "${vmid}" "${new_args}"
}

# 处理 post-stop 阶段
handle_post_stop()
{
	local vmid=$1

	# 清理systemd服务
	local service_pattern="${VIRTIOFS_SERVICE_PATH}/${VIRTIOFS_SERVICE_NAME}-*${vmid}.service"
	for service_file in ${service_pattern}; do
		[ -f "${service_file}" ] || continue
		
		local service_name=$(basename "${service_file%.*}")
		
		systemctl stop "${service_name}" 2>/dev/null || true
		systemctl disable "$service_name" 2>/dev/null || true
		rm -f "${service_file}"
	done
	
	# 清理socket文件
	local socket_pattern="${VIRTIOFS_SOCKET_PATH}/${vmid}-*.sock"
    rm -f ${socket_pattern} 2>/dev/null
	
	# 清理pid文件
	local pid_file="${VIRTIOFS_SOCKET_PATH}/${vmid}-*.pid"
	rm -f ${pid_file} 2>/dev/null
	
	systemctl daemon-reload
}

# 逻辑执行函数
main()
{
	local vmid=$1
	local phase=$2
	
	# 获取虚拟机配置
	local vm_conf=$(get_vm_config "${vmid}")
	
	if [ $? -ne 0 ] || [ -z "${vm_conf}" ]; then
		echo "[ERROR] 获取虚拟机(VM:${vmid})配置失败, 请检查!" >&2
		exit 1
	fi
	
	case "$phase" in
		"pre-start")
			#echo "pre-start"
			handle_pre_start "${vmid}" "${vm_conf}"
			;;
		  "post-start")
			#echo "post-start"
			handle_post_start "${vmid}" "${vm_conf}"
			;;
		  "pre-stop")
			echo "VM $vmid 即将停止..."
			;;
		  "post-stop")
			#echo "post-stop"
			handle_post_stop "${vmid}"
			;;
	esac
}

# 执行主逻辑
main "$@"