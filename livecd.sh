#!/bin/bash
# ==============================================================================
# Arch Linux 安装脚本
#
# 该脚本用于半自动化安装最小化 Arch Linux 系统。
# 主要功能包括：
#   - 基础环境检查 (网络, 时间)
#   - 镜像源优化 (Reflector / 预设国内源)
#   - 磁盘分区与格式化 (Btrfs, GPT, UEFI)
#   - 基础系统安装 (Pacstrap)
#   - 系统配置 (主机名, 时区, 语言, 网络, ZRAM, 用户等)
#   - 引导加载程序安装 (GRUB)
# ==============================================================================

set -euo pipefail

# ==============================================================================
# 1. 全局变量与配置
# ==============================================================================

VERSION="0.1.0"
AUTO_INSTALL=false
TARGET_DISK=""
PART_EFI=""
PART_ROOT=""
TARGET_USER=""

# 配置项
SYSTEM_COUNTRY_CODE="CN"
EFI_PART_SIZE="1024M"
DEFAULT_HOSTNAME="archlinux"
TIMEZONE="Asia/Shanghai"

# ==============================================================================
# 2. TUI 颜色与样式定义
# ==============================================================================

if [[ -t 1 ]] && command -v tput &> /dev/null && tput setaf 1 &> /dev/null; then
    RESET='\033[0m'
    
    BOLD_RED='\033[1;31m'
    BOLD_GREEN='\033[1;32m'
    BOLD_YELLOW='\033[1;33m'
    BOLD_BLUE='\033[1;34m'
    BOLD_MAGENTA='\033[1;35m'
    BOLD_CYAN='\033[1;36m'
    BOLD_WHITE='\033[1;37m'
    BG_RED='\033[41m'
    
    DIM='\033[2m'
    
    INFO="${BOLD_BLUE}"
    SUCCESS="${BOLD_GREEN}"
    WARNING="${BOLD_YELLOW}"
    ERROR="${BOLD_RED}"
    HEADER="${BOLD_MAGENTA}"
    PROMPT="${BOLD_CYAN}"
else
    RESET=''
    BOLD_RED='' BOLD_GREEN='' BOLD_YELLOW='' BOLD_BLUE='' BOLD_MAGENTA='' BOLD_CYAN='' BOLD_WHITE='' BG_RED=''
    DIM=''
    INFO='' SUCCESS='' WARNING='' ERROR='' HEADER='' PROMPT=''
fi

# ==============================================================================
# 3. 核心工具函数
# ==============================================================================

# 输出信息日志
info() {
    echo -e "${INFO}[INFO]${RESET} $*"
}

# 输出成功日志
success() {
    echo -e "${SUCCESS}[SUCCESS]${RESET} $*"
}

# 输出警告日志
warn() {
    echo -e "${WARNING}[WARNING]${RESET} $*"
}

# 输出错误日志
error() {
    echo -e "${ERROR}[ERROR]${RESET} $*" >&2
}

# 脚本退出时的清理工作，卸载挂载点
cleanup() {
    # 检查 /mnt 是否挂载，若是则尝试递归卸载
    if mountpoint -q /mnt; then
        echo ""
        info "Cleaning up mounted filesystems..."
        umount -R /mnt 2>/dev/null || true
    fi
}

# 处理中断信号 (Ctrl+C)
handle_interrupt() {
    echo ""
    warn "Operation cancelled by user"
    exit 130
}

# 打印带有样式的章节标题
print_section_title() {
    local title="$1"
    echo -e "${HEADER}[SECTION]${RESET} ${BOLD_WHITE}${title}${RESET}"
}

# 执行命令并显示带有缓冲区的输出，处理错误
run_command() {
    local description="${1:-Executing command}"
    shift
    local cmd=("$@")
    local max_lines=5
    local line_count=0
    local buffer=()

    info "${description}..."
    echo -e "${DIM}> ${cmd[*]}${RESET}"

    # 执行命令并捕获输出
    {
        "${cmd[@]}" 2>&1 | while IFS= read -r line; do
            # 更新缓冲区（保留最后5行，截断超长行）
            buffer+=("${line:0:110}")
            if [[ ${#buffer[@]} -gt ${max_lines} ]]; then
                buffer=("${buffer[@]:1}")
            fi

            # 清除旧输出
            if [[ ${line_count} -gt 0 ]]; then
                for ((i=0; i<line_count; i++)); do
                    echo -ne "\033[1A\033[2K"
                done
            fi

            # 显示缓冲区内容
            line_count=${#buffer[@]}
            for output_line in "${buffer[@]}"; do
                echo -e "${DIM}  │ ${output_line}${RESET}"
            done
        done

        # 返回退出码
        return ${PIPESTATUS[0]}
    }

    local exit_code=$?

    # 清除最后显示
    if [[ ${line_count} -gt 0 ]]; then
        for ((i=0; i<line_count; i++)); do
            echo -ne "\033[1A\033[2K"
        done
    fi

    if [[ ${exit_code} -eq 0 ]]; then
        success "${description} completed"
    else
        error "${description} failed (exit code: ${exit_code})"
    fi

    return ${exit_code}
}

# ==============================================================================
# 4. 通用辅助函数
# ==============================================================================

# 写入预设的中国镜像源列表作为备选
write_china_mirrors() {
    info "Writing preset China mirrors to /etc/pacman.d/mirrorlist..."
    cat > /etc/pacman.d/mirrorlist <<'EOF'
# 国内镜像源 - Sycamore 预设
Server = https://mirrors.ustc.edu.cn/archlinux/$repo/os/$arch
Server = http://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.aliyun.com/archlinux/$repo/os/$arch
Server = http://mirrors.cqu.edu.cn/archlinux/$repo/os/$arch
Server = http://mirrors.nju.edu.cn/archlinux/$repo/os/$arch
Server = http://mirrors.aliyun.com/archlinux/$repo/os/$arch
Server = http://mirrors.hust.edu.cn/archlinux/$repo/os/$arch
Server = http://mirrors.zju.edu.cn/archlinux/$repo/os/$arch
Server = http://mirrors.shanghaitech.edu.cn/archlinux/$repo/os/$arch
EOF
    success "Preset China mirrors applied"
}

# ==============================================================================
# 5. 主要功能
# ==============================================================================

# 检查 UEFI 引导模式，否则退出
check_uefi() {
    print_section_title "UEFI Boot Check"
    info "Checking boot mode..."
    
    if [[ -d /sys/firmware/efi/efivars ]]; then
        success "UEFI boot mode detected"
        echo ""
    else
        error "This script ONLY supports UEFI boot mode!"
        error "Current environment appears to be Legacy BIOS."
        error "Please enable 'EFI' or 'UEFI' in your virtual machine settings and reboot."
        exit 1
    fi
}

# 检查网络连接状态
check_network() {
    print_section_title "Network Check"
    info "Checking network connectivity..."

    if ping -c 1 -W 2 223.5.5.5 &> /dev/null || ping -c 1 -W 2 8.8.8.8 &> /dev/null; then
        success "Network is connected"
        echo ""
    else
        error "Network is unreachable!"
        error "Please check your network connection and try again."
        exit 1
    fi
}

# 同步系统时间 (NTP)
sync_time() {
    print_section_title "Time Synchronization"
    run_command "Enabling NTP" timedatectl set-ntp true
    success "Time synchronized successfully"
    echo ""
}

# 优化镜像源列表，使用 reflector 筛选最快源
update_mirrorlist() {
    print_section_title "Mirror List Optimization"

    if grep -q "generated by Reflector" /etc/pacman.d/mirrorlist || grep -q "Sycamore" /etc/pacman.d/mirrorlist; then
        success "Mirror list already optimized, skipping..."
        echo ""
        return 0
    fi

    info "Using country code: ${SYSTEM_COUNTRY_CODE}"

    # 按速率排序以选择最快源
    local reflector_cmd=("reflector" "-c" "${SYSTEM_COUNTRY_CODE}" "-a" "12" "-f" "10" "--protocol" "http,https" "--sort" "score" "--save" "/etc/pacman.d/mirrorlist" "--verbose")
    
    local success=false
    local max_retries=3
    
    for ((i=0; i<=max_retries; i++)); do
        if run_command "Updating mirror list to fastest servers..." "${reflector_cmd[@]}"; then
            success=true
            break
        fi
        
        if [[ $i -lt $max_retries ]]; then
            warn "Reflector command failed. Retrying ($((i+1))/$max_retries)..."
        fi
    done
    
    if [[ "$success" == "false" ]]; then
        warn "Failed to update mirror list via reflector after $((max_retries+1)) attempts"
        warn "Falling back to preset China mirrors..."
        write_china_mirrors
    else
        success "Mirror list optimized successfully"
    fi
    
    echo ""
}

# 更新系统基础工具 (pacman, keyring, archinstall)
update_tools() {
    print_section_title "System Tools Update"

    run_command "Synchronizing package databases..." pacman -Sy

    run_command "Updating archlinux-keyring..." pacman -S --noconfirm --needed archlinux-keyring

    run_command "Updating archinstall..." pacman -S --noconfirm --needed archinstall

    success "System tools updated successfully"
    echo ""
}

# 交互式选择目标安装磁盘，并检测潜在的 Windows 系统
select_disk() {
    print_section_title "Disk Selection"
    
    info "Scanning for available disks..."
    local disks_output
    # 列出磁盘设备 (排除 loop/rom，仅限 disk 类型)
    if ! disks_output=$(lsblk -d -n -p -r -o NAME,SIZE,TYPE,MODEL -e 7,11 2>/dev/null | awk '$3 == "disk"'); then
        error "Failed to list disks using lsblk"
        return 1
    fi

    if [[ -z "$disks_output" ]]; then
        error "No suitable disks found!"
        exit 1
    fi
    
    local disk_array=()
    local i=1
    
    echo -e "${BOLD_CYAN}Available Disks:${RESET}"
    
    # 解析设备列表
    while read -r dev size type model; do
        disk_array+=("$dev")
        echo -e "  ${BOLD_MAGENTA}[$i]${RESET} ${BOLD_GREEN}${dev}${RESET}  ${BOLD_YELLOW}[${size}]${RESET}  ${model}"
        ((i++))
    done <<< "$disks_output"

    # 交互选择磁盘
    while true; do
        echo -e -n "${PROMPT}Enter disk number to install to (1-${#disk_array[@]}) or 'exit' to quit: ${RESET}"
        read -r input_num
        
        if [[ "$input_num" == "exit" ]]; then
            warn "Installation aborted by user."
            exit 0
        fi

        # 验证数字输入
        if ! [[ "$input_num" =~ ^[0-9]+$ ]]; then
            error "Invalid input. Please enter a number."
            continue
        fi

        # 验证范围
        if (( input_num < 1 || input_num > ${#disk_array[@]} )); then
            error "Invalid selection. Please enter a number between 1 and ${#disk_array[@]}."
            continue
        fi

        local selected_disk="${disk_array[$((input_num-1))]}"

        # 检查设备存在性
        if [[ ! -b "$selected_disk" ]]; then
            error "Device '$selected_disk' not found (unexpected)."
            continue
        fi
        
        # 检测 Windows 系统 (通过 MSR 分区或 NTFS 文件系统)
        local windows_detected=false
        if lsblk -n -o PARTTYPE "$selected_disk" 2>/dev/null | grep -iq "E3C9E316-0B5C-4DB8-817D-F92DF00215AE"; then
            windows_detected=true
        elif lsblk -n -o FSTYPE "$selected_disk" 2>/dev/null | grep -iq "ntfs"; then
            windows_detected=true
        fi

        # 用户确认
        echo -e ""
        if [[ "$windows_detected" == "true" ]]; then
            echo -e "${BG_RED}${BOLD_WHITE} DANGER: POTENTIAL WINDOWS INSTALLATION DETECTED ON ${selected_disk}! ${RESET}"
            echo -e "${BG_RED}${BOLD_WHITE}         PROCEEDING WILL DESTROY YOUR WINDOWS SYSTEM!         ${RESET}"
            echo -e ""
        fi
        echo -e "${BG_RED}${BOLD_WHITE} WARNING: ALL DATA ON ${selected_disk} WILL BE DESTROYED! ${RESET}"
        echo -e -n "${PROMPT}Type 'yes' to confirm: ${RESET}"
        read -r confirm
        
        if [[ "$confirm" == "yes" ]]; then
            TARGET_DISK="$selected_disk"
            success "Target disk selected: $TARGET_DISK"
            break
        fi
        warn "Selection not confirmed."
    done
}

# 对选定磁盘进行分区 (GPT, EFI, Root)
partition_disk() {
    print_section_title "Disk Partitioning"
    
    if [[ -z "${TARGET_DISK}" ]]; then
        error "No target disk selected. Exiting."
        exit 1
    fi

    info "Partitioning ${TARGET_DISK}..."
    
    # 确定分区前缀 (NVMe 设备需加 'p')
    local part_prefix="${TARGET_DISK}"
    if [[ "${TARGET_DISK}" =~ [0-9]$ ]]; then
        part_prefix="${TARGET_DISK}p"
    fi
    
    PART_EFI="${part_prefix}1"
    PART_ROOT="${part_prefix}2"

    # 清空磁盘并建立 GPT 分区表
    run_command "Wiping signatures" wipefs --all --force "${TARGET_DISK}"
    run_command "Zapping disk" sgdisk -Z "${TARGET_DISK}"
    run_command "Creating GPT" sgdisk -o "${TARGET_DISK}"
    
    # 创建 EFI 分区
    run_command "Creating EFI partition (${EFI_PART_SIZE})" sgdisk -n 1:0:+${EFI_PART_SIZE} -t 1:ef00 -c 1:"EFI" "${TARGET_DISK}"
    
    # 创建 Root 分区 (剩余空间)
    run_command "Creating Root partition (Btrfs)" sgdisk -n 2:0:0 -t 2:8300 -c 2:"Root" "${TARGET_DISK}"
    
    # 等待设备节点生成
    run_command "Waiting for device nodes" udevadm settle
    
    info "Formatting partitions..."
    run_command "Formatting EFI (${PART_EFI})" mkfs.fat -F32 "${PART_EFI}"
    run_command "Formatting Root (${PART_ROOT})" mkfs.btrfs -f "${PART_ROOT}"
    
    success "Disk partitioning and formatting completed"
    echo ""
}

# 创建 Btrfs 子卷
create_subvolumes() {
    print_section_title "Subvolume Creation"
    
    info "Creating Btrfs subvolumes on ${PART_ROOT}..."
    
    # 挂载 Root 分区
    run_command "Mounting root partition" mount "${PART_ROOT}" /mnt
    
    # 创建 Btrfs 子卷 (@, @home, @log, @pkg, @snapshots)
    run_command "Creating @ subvolume" btrfs subvolume create /mnt/@
    run_command "Creating @home subvolume" btrfs subvolume create /mnt/@home
    run_command "Creating @log subvolume" btrfs subvolume create /mnt/@log
    run_command "Creating @pkg subvolume" btrfs subvolume create /mnt/@pkg
    run_command "Creating @snapshots subvolume" btrfs subvolume create /mnt/@snapshots
    
    # 卸载 Root 分区
    run_command "Unmounting root partition" umount /mnt
    
    success "Subvolumes created successfully"
    echo ""
}

# 挂载文件系统及子卷
mount_filesystems() {
    print_section_title "Mounting Filesystems"
    
    info "Mounting subvolumes..."
    
    # 挂载 @ 到 /mnt (启用 zstd 压缩)
    local mount_opts="noatime,compress=zstd:1,space_cache=v2"
    
    run_command "Mounting @ to /mnt" mount -o "${mount_opts},subvol=@" "${PART_ROOT}" /mnt
    
    # 创建目录结构
    run_command "Creating directories" mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,efi}
    
    # 挂载其他子卷
    run_command "Mounting @home" mount -o "${mount_opts},subvol=@home" "${PART_ROOT}" /mnt/home
    run_command "Mounting @log" mount -o "${mount_opts},subvol=@log" "${PART_ROOT}" /mnt/var/log
    run_command "Mounting @pkg" mount -o "${mount_opts},subvol=@pkg" "${PART_ROOT}" /mnt/var/cache/pacman/pkg
    run_command "Mounting @snapshots" mount -o "${mount_opts},subvol=@snapshots" "${PART_ROOT}" /mnt/.snapshots
    
    # 挂载 EFI 分区到 /efi
    info "Mounting EFI partition..."
    run_command "Mounting EFI to /mnt/efi" mount "${PART_EFI}" /mnt/efi
    
    success "All filesystems mounted successfully"
    echo ""
}

# 安装基础系统及核心软件包 (pacstrap)
install_base() {
    print_section_title "Base System Installation"
    
    # 1. 安装核心包 (内核、固件、基础工具)
    info "Step 1/3: Installing core packages..."
    local core_pkgs=(base linux-zen linux-zen-headers linux-firmware base-devel btrfs-progs)
    run_command "Installing core packages" pacstrap -K /mnt "${core_pkgs[@]}"

    # 应用镜像源配置
    info "Copying optimized mirrorlist to new system..."
    cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist

    # 2. 安装 CPU 微码
    info "Step 2/3: Detecting and installing CPU microcode..."
    local ucode_pkg=()
    local cpu_vendor
    cpu_vendor=$(grep -m1 "vendor_id" /proc/cpuinfo | awk '{print $3}')
    
    if [[ "$cpu_vendor" == "GenuineIntel" ]]; then
        info "Intel CPU detected"
        ucode_pkg=(intel-ucode)
    elif [[ "$cpu_vendor" == "AuthenticAMD" ]]; then
        info "AMD CPU detected"
        ucode_pkg=(amd-ucode)
    else
        warn "Unknown CPU vendor: $cpu_vendor. Installing both microcodes for safety."
        ucode_pkg=(amd-ucode intel-ucode)
    fi
    
    run_command "Installing microcode (${ucode_pkg[*]})" pacstrap /mnt "${ucode_pkg[@]}"

    # 3. 安装常用工具 (引导、网络、编辑器等)
    info "Step 3/3: Installing additional tools..."
    local extra_pkgs=(grub efibootmgr dosfstools neovim networkmanager os-prober exfat-utils zram-generator)
    run_command "Installing additional tools" pacstrap /mnt "${extra_pkgs[@]}"
    
    # 4. 检测虚拟化环境并安装增强工具
    info "Checking for virtualization environment..."
    if command -v systemd-detect-virt >/dev/null; then
        local virt_type
        virt_type=$(systemd-detect-virt || echo "none")
        local virt_pkgs=()
        local virt_services=()

        case "$virt_type" in
            kvm|qemu)
                info "Virtualization: KVM/QEMU detected"
                virt_pkgs+=(qemu-guest-agent)
                virt_services+=(qemu-guest-agent)
                ;;
            vmware)
                info "Virtualization: VMware detected"
                virt_pkgs+=(open-vm-tools gtkmm3)
                virt_services+=(vmtoolsd)
                ;;
            oracle)
                info "Virtualization: VirtualBox detected"
                virt_pkgs+=(virtualbox-guest-utils)
                virt_services+=(vboxservice)
                ;;
            microsoft)
                info "Virtualization: Hyper-V detected"
                virt_pkgs+=(hyperv)
                virt_services+=(hv_fcopy_daemon hv_kvp_daemon hv_vss_daemon)
                ;;
        esac

        if [[ ${#virt_pkgs[@]} -gt 0 ]]; then
            run_command "Installing guest tools (${virt_pkgs[*]})" pacstrap /mnt "${virt_pkgs[@]}"
            for srv in "${virt_services[@]}"; do
                run_command "Enabling service: $srv" arch-chroot /mnt systemctl enable "$srv"
            done
        fi
    fi

    success "Base system installation completed"
    echo ""
}

# 生成 fstab 文件
generate_fstab() {
    print_section_title "Generating Fstab"
    
    info "Generating /etc/fstab using UUIDs..."
    
    # 确保目录存在
    mkdir -p /mnt/etc
    
    # 生成 fstab
    if genfstab -U /mnt >> /mnt/etc/fstab; then
        success "Fstab generated successfully"
    else
        error "Failed to generate fstab"
        exit 1
    fi
    echo ""
}

# 配置系统 (主机名, 时区, 语言, 网络, ZRAM)
configure_system() {
    print_section_title "System Configuration"

    # 1. 设置主机名
    info "Configuring hostname..."
    local hostname="${DEFAULT_HOSTNAME}"
    while true; do
        echo -e -n "${PROMPT}Enter hostname [${hostname}]: ${RESET}"
        read -r input_hostname
        
        if [[ -z "$input_hostname" ]]; then
            break
        fi

        # 验证主机名 (字母数字和连字符)
        if [[ "$input_hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
            hostname="$input_hostname"
            break
        else
            error "Invalid hostname. Use alphanumeric characters and hyphens only."
        fi
    done
    
    echo "$hostname" > /mnt/etc/hostname
    cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${hostname}.localdomain ${hostname}
EOF
    success "Hostname set to '$hostname'"

    # 2. 设置时区
    info "Configuring timezone to ${TIMEZONE}..."
    if run_command "Setting timezone to ${TIMEZONE}" arch-chroot /mnt ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime; then
        run_command "Syncing hardware clock" arch-chroot /mnt hwclock --systohc
    else
        warn "Failed to set timezone."
    fi

    # 3. 设置语言环境
    info "Configuring localization..."
    # 启用 en_US 和 zh_CN
    sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /mnt/etc/locale.gen
    sed -i 's/^#zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /mnt/etc/locale.gen
    
    run_command "Generating locales" arch-chroot /mnt locale-gen
    
    echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf
    success "Locale generated and configured (LANG=en_US.UTF-8)"

    # 4. 启用网络服务
    info "Enabling NetworkManager..."
    run_command "Enabling NetworkManager" arch-chroot /mnt systemctl enable NetworkManager
    
    echo ""

    # 5. 配置 ZRAM
    info "Configuring ZRAM..."
    cat > /mnt/etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
EOF
    success "ZRAM configured (50% RAM, zstd)"
    echo ""
}

# 设置 Root 用户密码
configure_root() {
    print_section_title "Root Password Setup"
    
    info "Setting password for 'root' user..."
    
    # 交互式设置 Root 密码
    if arch-chroot /mnt passwd; then
        success "Root password set successfully"
    else
        warn "Failed to set root password. You may need to set it manually later."
    fi
    echo ""
}

# 创建并配置普通用户 (sudo 权限)
configure_user() {
    print_section_title "User Account Setup"

    info "Creating a standard user account..."

    local username=""
    while [[ -z "$username" ]]; do
        echo -e -n "${PROMPT}Enter username: ${RESET}"
        read -r input_user
        
        # 验证用户名格式
        if [[ "$input_user" =~ ^[a-z][a-z0-9_-]*$ ]]; then
            username="$input_user"
        else
            error "Invalid username. Must start with a lowercase letter and contain only lowercase letters, numbers, underscores, or hyphens."
        fi
    done

    if run_command "Creating user '$username'" arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$username"; then
        TARGET_USER="$username"
        info "Setting password for '$username'..."
        # 交互式设置密码
        if arch-chroot /mnt passwd "$username"; then
            success "User '$username' created and password set"
        else
            warn "Failed to set password for '$username'. You may need to set it manually."
        fi
        
        # 配置 sudo 权限
        info "Configuring sudo privileges for wheel group..."
        # 创建 sudoers 配置
        echo "%wheel ALL=(ALL:ALL) ALL" > /mnt/etc/sudoers.d/wheel
        chmod 440 /mnt/etc/sudoers.d/wheel
        success "Sudo privileges granted to wheel group"
    else
        error "Failed to create user '$username'"
    fi
    echo ""
}

# 安装并配置 GRUB 引导加载程序
install_bootloader() {
    print_section_title "Bootloader Installation"
    
    info "Configuring and installing GRUB..."
    
    # 检查 GRUB 配置
    if [[ ! -f /mnt/etc/default/grub ]]; then
        error "GRUB configuration file not found at /mnt/etc/default/grub!"
        error "This indicates that the GRUB package was not installed correctly."
        exit 1
    fi

    info "Configuring /etc/default/grub..."
    
    # 1. 启用多系统探测
    sed -i 's/^#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' /mnt/etc/default/grub
    if ! grep -q "GRUB_DISABLE_OS_PROBER=false" /mnt/etc/default/grub; then
            echo "GRUB_DISABLE_OS_PROBER=false" >> /mnt/etc/default/grub
    fi
    
    # 2. 记忆上次启动项
    sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /mnt/etc/default/grub
    if ! grep -q "GRUB_SAVEDEFAULT=true" /mnt/etc/default/grub; then
            echo "GRUB_SAVEDEFAULT=true" >> /mnt/etc/default/grub
    fi
    
    # 3. 优化内核参数 (日志级别、禁用看门狗)
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=5 nowatchdog modprobe.blacklist=iTCO_wdt,sp5100_tco /' /mnt/etc/default/grub
    
    # 安装 GRUB 到 ESP
    run_command "Installing GRUB to EFI" arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/efi --boot-directory=/efi --bootloader-id=Arch
    
    # 生成 GRUB 配置
    run_command "Generating GRUB config" arch-chroot /mnt grub-mkconfig -o /efi/grub/grub.cfg
    
    success "Bootloader installed successfully"
    echo ""
}

# 显示安装完成信息并提示重启
installation_complete() {
    print_section_title "Installation Complete"
    
    echo -e "${SUCCESS}Arch Linux installation has finished successfully!${RESET}"
    echo -e ""
    echo -e "${INFO}Key Information:${RESET}"
    echo -e "  • Hostname:      ${BOLD_WHITE}${hostname:-$(cat /mnt/etc/hostname 2>/dev/null)}${RESET}"
    echo -e "  • Root User:     ${BOLD_WHITE}root${RESET}"
    echo -e "  • User Account:  ${BOLD_WHITE}${TARGET_USER}${RESET}"
    echo -e "  • Target Disk:   ${BOLD_WHITE}${TARGET_DISK}${RESET}"
    echo -e ""
    echo -e "${WARNING}Please remove the installation media before restarting.${RESET}"
    echo -e ""
    
    while true; do
        echo -e -n "${PROMPT}Do you want to reboot now? [Y/n] ${RESET}"
        read -r choice
        choice=${choice:-Y}
        
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            info "Rebooting system..."
            reboot
            break
        elif [[ "$choice" =~ ^[Nn]$ ]]; then
            info "You can verify the installation in /mnt"
            info "Type 'reboot' to restart the system when ready."
            break
        else
            warn "Please enter Y or n."
        fi
    done
}

# 主函数：按顺序执行安装步骤
main() {
    trap cleanup EXIT
    trap handle_interrupt SIGINT
    check_uefi
    check_network
    sync_time
    update_mirrorlist
    update_tools
    select_disk
    partition_disk
    create_subvolumes
    mount_filesystems
    install_base
    generate_fstab
    configure_system
    configure_root
    configure_user
    install_bootloader
    installation_complete
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi