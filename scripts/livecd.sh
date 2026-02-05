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

print_banner() {
    clear
    echo -e "${BOLD_RED}"
    cat << "EOF"
    ███████╗██╗   ██╗ ██████╗ █████╗ ███╗   ███╗ ██████╗ ██████╗ ███████╗
    ██╔════╝╚██╗ ██╔╝██╔════╝██╔══██╗████╗ ████║██╔═══██╗██╔══██╗██╔════╝
    ███████╗ ╚████╔╝ ██║     ███████║██╔████╔██║██║   ██║██████╔╝█████╗
    ╚════██║  ╚██╔╝  ██║     ██╔══██║██║╚██╔╝██║██║   ██║██╔══██╗██╔══╝
    ███████║   ██║   ╚██████╗██║  ██║██║ ╚═╝ ██║╚██████╔╝██║  ██║███████╗
    ╚══════╝   ╚═╝    ╚═════╝╚═╝  ╚═╝╚═╝     ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝
EOF
    echo -e "${RESET}"
    echo -e "    ${BOLD_CYAN}Arch Linux Installer v${VERSION} by Sycamore${RESET}\n"
}

# ==============================================================================
# 1. 全局变量与配置
# ==============================================================================

VERSION="0.1.1"
TARGET_DISK=""
PART_EFI=""
PART_ROOT=""
TARGET_USER=""

# 配置项
SYSTEM_COUNTRY_CODE="CN"
EFI_PART_SIZE="1024M"
DEFAULT_HOSTNAME="yukino"
TIMEZONE="Asia/Shanghai"
MOUNT_OPTS="noatime,compress=zstd"

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
    echo -e "${INFO}[   INFO]${RESET} $*"
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
    echo -e "${ERROR}[  ERROR]${RESET} $*" >&2
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
    local max_lines=15
    local line_count=0
    local buffer=()
    local exit_code=0

    info "${description}..."
    echo -e "${DIM}> ${cmd[*]}${RESET}"

    # 使用 Process Substitution 和协议流来避免子 shell 变量丢失问题
    # 并在流末尾附加退出码
    while IFS= read -r line; do
        # 检查是否为注入的退出码标记
        if [[ "$line" =~ ^___EXIT_CODE:([0-9]+)$ ]]; then
            exit_code="${BASH_REMATCH[1]}"
            continue
        fi

        # 更新缓冲区
        if [[ ${#line} -gt 110 ]]; then
            buffer+=("${line:0:107}...")
        else
            buffer+=("$line")
        fi
        
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
    done < <( "${cmd[@]}" 2>&1; echo "___EXIT_CODE:$?" )

    # 清除最后显示的 TUI 缓冲区
    if [[ ${line_count} -gt 0 ]]; then
        for ((i=0; i<line_count; i++)); do
            echo -ne "\033[1A\033[2K"
        done
    fi

    if [[ ${exit_code} -eq 0 ]]; then
        success "${description} completed"
    else
        error "${description} failed (exit code: ${exit_code})"
        # 失败时重新显示最后捕获的日志，方便调试
        for output_line in "${buffer[@]}"; do
            echo -e "${DIM}  │ ${output_line}${RESET}"
        done
    fi

    return ${exit_code}
}

# ==============================================================================
# 4. 通用辅助函数
# ==============================================================================

# 检查依赖工具
check_dependencies() {
    local deps=(reflector sgdisk wipefs btrfs genfstab arch-chroot grep sed awk lsblk mountpoint)
    local missing=()
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required dependencies: ${missing[*]}"
        exit 1
    fi
}

# 写入预设的中国镜像源列表作为备选
write_china_mirrors() {
    info "Writing preset China mirrors to /etc/pacman.d/mirrorlist..."
    cat > /etc/pacman.d/mirrorlist <<'EOF'
# China Mirrors - Sycamore Preset
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

# 基础环境检查 (UEFI, 网络, 时间)
perform_base_checks() {
    print_section_title "Base System Checks"

    # 1. 检查 UEFI
    info "Step 1/3: Checking boot mode..."
    if [[ -d /sys/firmware/efi/efivars ]]; then
        success "UEFI boot mode detected"
    else
        error "This script ONLY supports UEFI boot mode!"
        error "Current environment appears to be Legacy BIOS."
        exit 1
    fi
    echo ""

    # 2. 检查网络
    info "Step 2/3: Checking network connectivity..."
    if ping -c 1 -W 2 223.5.5.5 &> /dev/null || ping -c 1 -W 2 8.8.8.8 &> /dev/null; then
        success "Network is connected"
    else
        error "Network is unreachable!"
        exit 1
    fi
    echo ""

    # 3. 同步时间
    info "Step 3/3: Synchronizing system time..."
    run_command "Enabling NTP" timedatectl set-ntp true
    success "Time synchronized"
    echo ""
}

# 环境准备 (镜像源, 工具)
prepare_environment() {
    print_section_title "Environment Preparation"
    
    info "Checking dependencies..."
    check_dependencies

    # 1. 优化镜像源
    info "Step 1/2: Optimizing mirror list..."
    if ! (grep -q "generated by Reflector" /etc/pacman.d/mirrorlist || grep -q "China Mirrors - Sycamore Preset" /etc/pacman.d/mirrorlist); then
        info "Using country code: ${SYSTEM_COUNTRY_CODE}"
        local reflector_cmd=("reflector" "-c" "${SYSTEM_COUNTRY_CODE}" "-a" "12" "-f" "10" "--protocol" "http,https" "--sort" "score" "--save" "/etc/pacman.d/mirrorlist" "--verbose")
        local reflector_success=false
        local max_retries=3
        
        for ((i=0; i<=max_retries; i++)); do
            if run_command "Updating mirror list..." "${reflector_cmd[@]}"; then
                reflector_success=true; break
            fi
            [[ $i -lt $max_retries ]] && warn "Reflector failed. Retrying..."
        done
        
        if [[ "$reflector_success" == "false" ]]; then
            warn "Reflector failed. Using preset China mirrors..."
            write_china_mirrors
        else
            success "Mirrors optimized"
        fi
    else
        success "Mirrors already optimized, skipping"
    fi
    echo ""

    # 2. 更新工具
    info "Step 2/2: Updating system tools..."
    run_command "Syncing DBs" pacman -Sy
    run_command "Updating keyring" pacman -S --noconfirm --needed archlinux-keyring
    run_command "Updating archinstall" pacman -S --noconfirm --needed archinstall
    success "Tools updated"
    echo ""
}

# 磁盘准备 (选择, 分区, 格式化)
prepare_disk() {
    print_section_title "Disk Preparation"

    # 1. 选择磁盘
    info "Step 1/2: Selecting target disk..."
    info "Scanning for available disks..."
    local disks_output
    if ! disks_output=$(lsblk -d -n -p -r -o NAME,SIZE,TYPE,MODEL -e 7,11 2>/dev/null | awk '$3 == "disk"'); then
        error "Failed to list disks"
        exit 1
    fi

    if [[ -z "$disks_output" ]]; then
        error "No suitable disks found!"
        exit 1
    fi
    
    local disk_array=()
    local i=1
    echo -e "${BOLD_CYAN}Available Disks:${RESET}"
    while read -r dev size type model; do
        disk_array+=("$dev")
        echo -e "  ${BOLD_MAGENTA}[$i]${RESET} ${BOLD_GREEN}${dev}${RESET}  ${BOLD_YELLOW}[${size}]${RESET}  ${model}"
        ((i++))
    done <<< "$disks_output"

    while true; do
        echo -e -n "${PROMPT}Enter disk number (1-${#disk_array[@]}) or 'exit': ${RESET}"
        read -r input_num
        [[ "$input_num" == "exit" ]] && { warn "Aborted."; exit 0; }
        
        if [[ "$input_num" =~ ^[0-9]+$ ]] && (( input_num >= 1 && input_num <= ${#disk_array[@]} )); then
            local selected_disk="${disk_array[$((input_num-1))]}"
            [[ ! -b "$selected_disk" ]] && { error "Device not found"; continue; }
            
            # Windows Check
            local windows_detected=false
            # Check for Microsoft Reserved Partition (MSR) and Microsoft Basic Data (often NTFS)
            if lsblk -n -o PARTTYPE "$selected_disk" 2>/dev/null | grep -iqE "E3C9E316-0B5C-4DB8-817D-F92DF00215AE|EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"; then
                windows_detected=true
            elif lsblk -n -o FSTYPE "$selected_disk" 2>/dev/null | grep -iq "ntfs"; then
                windows_detected=true
            fi

            echo -e ""
            if [[ "$windows_detected" == "true" ]]; then
                echo -e "${BG_RED}${BOLD_WHITE} DANGER: POTENTIAL WINDOWS DETECTED ON ${selected_disk}! ${RESET}"
            fi
            echo -e "${BG_RED}${BOLD_WHITE} WARNING: ALL DATA ON ${selected_disk} WILL BE DESTROYED! ${RESET}"
            echo -e -n "${PROMPT}Type 'yes' to confirm: ${RESET}"
            read -r confirm
            if [[ "$confirm" == "yes" ]]; then
                TARGET_DISK="$selected_disk"
                success "Selected: $TARGET_DISK"
                break
            fi
        fi
        error "Invalid selection."
    done
    echo ""

    # 2. 分区与格式化
    info "Step 2/2: Partitioning and formatting..."
    local part_prefix="${TARGET_DISK}"
    [[ "${TARGET_DISK}" =~ [0-9]$ ]] && part_prefix="${TARGET_DISK}p"
    PART_EFI="${part_prefix}1"
    PART_ROOT="${part_prefix}2"

    run_command "Wiping signatures" wipefs --all --force "${TARGET_DISK}"
    run_command "Zapping disk" sgdisk -Z "${TARGET_DISK}"
    run_command "Creating GPT" sgdisk -o "${TARGET_DISK}"
    run_command "Creating EFI (${EFI_PART_SIZE})" sgdisk -n 1:0:+${EFI_PART_SIZE} -t 1:ef00 -c 1:"EFI" "${TARGET_DISK}"
    run_command "Creating Root (Btrfs)" sgdisk -n 2:0:0 -t 2:8300 -c 2:"Root" "${TARGET_DISK}"
    run_command "Waiting for nodes" udevadm settle
    
    info "Formatting..."
    run_command "Formatting EFI" mkfs.fat -F32 "${PART_EFI}"
    run_command "Formatting Root" mkfs.btrfs -f "${PART_ROOT}"
    
    success "Disk prepared successfully"
    echo ""
}

# 文件系统设置 (子卷, 挂载)
setup_filesystems() {
    print_section_title "Filesystem Setup"
    
    # 1. 创建子卷
    info "Step 1/2: Creating Btrfs subvolumes..."
    run_command "Mounting root (tmp)" mount "${PART_ROOT}" /mnt
    run_command "Creating @" btrfs subvolume create /mnt/@
    run_command "Creating @home" btrfs subvolume create /mnt/@home
    run_command "Creating @log" btrfs subvolume create /mnt/@log
    run_command "Creating @pkg" btrfs subvolume create /mnt/@pkg
    run_command "Creating @snapshots" btrfs subvolume create /mnt/@snapshots
    run_command "Creating @games" btrfs subvolume create /mnt/@games
    run_command "Disabling CoW (@games)" chattr +C /mnt/@games
    run_command "Creating @videos" btrfs subvolume create /mnt/@videos
    run_command "Disabling CoW (@videos)" chattr +C /mnt/@videos
    run_command "Creating @downloads" btrfs subvolume create /mnt/@downloads
    run_command "Disabling CoW (@downloads)" chattr +C /mnt/@downloads
    
    if mountpoint -q /mnt; then
        run_command "Unmounting root (tmp)" umount /mnt
    fi
    echo ""

    # 2. 挂载
    info "Step 2/2: Mounting filesystems..."
    run_command "Mounting @ (/mnt)" mount -o "${MOUNT_OPTS},subvol=@" "${PART_ROOT}" /mnt
    run_command "Creating dirs" mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,boot}
    
    run_command "Mounting @home" mount -o "${MOUNT_OPTS},subvol=@home" "${PART_ROOT}" /mnt/home
    run_command "Mounting @log" mount -o "${MOUNT_OPTS},subvol=@log" "${PART_ROOT}" /mnt/var/log
    run_command "Mounting @pkg" mount -o "${MOUNT_OPTS},subvol=@pkg" "${PART_ROOT}" /mnt/var/cache/pacman/pkg
    run_command "Mounting @snapshots" mount -o "${MOUNT_OPTS},subvol=@snapshots" "${PART_ROOT}" /mnt/.snapshots
    
    run_command "Mounting EFI" mount "${PART_EFI}" /mnt/boot
    
    success "Filesystems ready"
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
    local extra_pkgs=(
        efibootmgr dosfstools networkmanager plymouth
        zram-generator fastfetch reflector 
        noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-jetbrains-mono-nerd
    )
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

# 用户配置 (Root, 普通用户)
configure_users() {
    print_section_title "User Configuration"

    # 1. Root 密码
    info "Step 1/2: Setting Root password..."
    if arch-chroot /mnt passwd; then
        success "Root password set"
    else
        error "Failed to set root password."
        exit 1
    fi
    echo ""

    # 2. 创建普通用户
    info "Step 2/2: Creating standard user..."
    local username=""
    while [[ -z "$username" ]]; do
        echo -e -n "${PROMPT}Enter username [sycamore]: ${RESET}"
        read -r input_user
        input_user="${input_user:-sycamore}"

        if [[ "$input_user" =~ ^[a-z][a-z0-9_-]*$ ]]; then
            username="$input_user"
        else
            error "Invalid format. Use lowercase letters, numbers, hyphens only."
        fi
    done

    if run_command "Creating user '$username'" arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$username"; then
        TARGET_USER="$username"
        info "Setting password for '$username'..."
        arch-chroot /mnt passwd "$username" || { error "Failed to set password for $username"; exit 1; }
        
        # sudo
        echo "%wheel ALL=(ALL:ALL) ALL" > /mnt/etc/sudoers.d/wheel
        chmod 440 /mnt/etc/sudoers.d/wheel
        
        # @games 挂载
        info "Mounting @games to /home/${username}/Games..."
        local games_dir="/mnt/home/${username}/Games"
        run_command "Creating dir" mkdir -p "${games_dir}"
        run_command "Mounting @games" mount -o "${MOUNT_OPTS},subvol=@games" "${PART_ROOT}" "${games_dir}"
        run_command "Setting perms" arch-chroot /mnt chown "${username}:${username}" "/home/${username}/Games"

        # @videos 挂载
        info "Mounting @videos to /home/${username}/Videos..."
        local videos_dir="/mnt/home/${username}/Videos"
        run_command "Creating dir" mkdir -p "${videos_dir}"
        run_command "Mounting @videos" mount -o "${MOUNT_OPTS},subvol=@videos" "${PART_ROOT}" "${videos_dir}"
        run_command "Setting perms" arch-chroot /mnt chown "${username}:${username}" "/home/${username}/Videos"

        # @downloads 挂载
        info "Mounting @downloads to /home/${username}/Downloads..."
        local downloads_dir="/mnt/home/${username}/Downloads"
        run_command "Creating dir" mkdir -p "${downloads_dir}"
        run_command "Mounting @downloads" mount -o "${MOUNT_OPTS},subvol=@downloads" "${PART_ROOT}" "${downloads_dir}"
        run_command "Setting perms" arch-chroot /mnt chown "${username}:${username}" "/home/${username}/Downloads"
        
        success "User configured and extra subvolumes (@games, @videos, @downloads) mounted"
    else
        error "Failed to create user"
    fi
    echo ""
}

# 生成 fstab 文件
generate_fstab() {
    print_section_title "Generating Fstab"
    
    info "Generating /etc/fstab using UUIDs..."
    
    # 确保目录存在
    mkdir -p /mnt/etc
    
    # 生成 fstab
    if genfstab -U /mnt > /mnt/etc/fstab; then
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
        error "Failed to set timezone."
        exit 1
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
swap-priority = 100
fs-type = swap
EOF
    success "ZRAM configured (50% RAM, zstd)"
    echo ""

    # 6. 配置 Plymouth 钩子
    info "Adding Plymouth to mkinitcpio hooks..."
    # 确保在 udev 之后添加 plymouth
    sed -i 's/^HOOKS=(base udev/HOOKS=(base udev plymouth/' /mnt/etc/mkinitcpio.conf
    run_command "Regenerating initramfs with Plymouth" arch-chroot /mnt mkinitcpio -P
    echo ""
}

# 安装并配置 systemd-boot 引导加载程序与 Plymouth 动画
install_bootloader() {
    print_section_title "Bootloader Installation (systemd-boot)"
    
    info "Installing systemd-boot..."
    # 1. 初始化 systemd-boot
    run_command "Installing bootctl" arch-chroot /mnt bootctl install

    # 2. 配置 loader.conf
    info "Configuring loader.conf..."
    cat > /mnt/boot/loader/loader.conf <<EOF
default arch.conf
timeout 0
console-mode max
editor no
EOF

    # 3. 创建启动条目 arch.conf
    local root_uuid
    root_uuid="$(blkid -s UUID -o value "${PART_ROOT}")"

    # systemd-boot：如果 entry 中引用了不存在的 initrd，会直接报错并中止引导。
    # 因此这里根据实际安装到 ESP(/mnt/boot) 的微码镜像动态生成 initrd 列表。
    local initrd_lines=()
    if [[ -f /mnt/boot/intel-ucode.img ]]; then
        initrd_lines+=("initrd  /intel-ucode.img")
    fi
    if [[ -f /mnt/boot/amd-ucode.img ]]; then
        initrd_lines+=("initrd  /amd-ucode.img")
    fi
    initrd_lines+=("initrd  /initramfs-linux-zen.img")

    local initrd_block
    initrd_block="$(printf '%s\n' "${initrd_lines[@]}")"
    # 去掉最后一个换行，避免 heredoc 中出现多余空行
    initrd_block="${initrd_block%$'\n'}"

    mkdir -p /mnt/boot/loader/entries

    info "Creating Arch Linux boot entry..."
    cat > /mnt/boot/loader/entries/arch.conf <<EOF
title   Arch Linux
linux   /vmlinuz-linux-zen
${initrd_block}
options root=UUID=${root_uuid} rw rootflags=subvol=@ zswap.enabled=0 loglevel=3 quiet splash vt.global_cursor_default=0 rd.udev.log_level=3 rd.vconsole.log_level=3
EOF
    
    # 4. 配置 Plymouth (启动动画使用 bgrt 主题以显示主板 Logo)
    info "Configuring Plymouth theme..."
    run_command "Setting Plymouth theme" arch-chroot /mnt plymouth-set-default-theme -R bgrt
    
    success "Bootloader and Splash configured successfully"
    echo ""
}

# 显示安装完成信息并提示重启
installation_complete() {
    print_section_title "Installation Complete"
    
    echo -e "${SUCCESS}Arch Linux installation has finished successfully!${RESET}"
    echo -e ""
    echo -e "${INFO}Key Information:${RESET}"
    local final_hostname
    if [[ -f /mnt/etc/hostname ]]; then
        final_hostname=$(cat /mnt/etc/hostname)
    else
        final_hostname="unknown"
    fi
    echo -e "  • Hostname:      ${BOLD_WHITE}${final_hostname}${RESET}"
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
    print_banner
    perform_base_checks
    prepare_environment
    prepare_disk
    setup_filesystems
    install_base
    configure_users
    generate_fstab
    configure_system
    install_bootloader
    installation_complete
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi