#!/bin/bash
# ==============================================================================
# Arch Linux 初始化脚本
#
# 该脚本用于在最小化 Arch Linux 安装后初始化环境。
# 主要功能：
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
GITHUB_AVAILABLE="false"
SYSTEM_COUNTRY_CODE="CN"

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

# 带快照保护的任务执行器
# 用法: run_with_snapshot "步骤名称" 命令 [参数...]
run_with_snapshot() {
    local step_name="$1"
    shift
    local cmd=("$@")
    
    # 定义快照描述标记
    local pre_desc="Pre ${step_name}"
    local post_desc="Post ${step_name}"
    
    info "Checking snapshot state for '${step_name}'..."
    
    # 获取现有的 root 配置快照列表
    local snap_list
    if ! snap_list=$(sudo snapper -c root list --columns number,description 2>/dev/null); then
        warn "Snapper not configured or failed to list. Running command without snapshot protection."
        "${cmd[@]}"
        return $?
    fi
    
    # 提取快照 ID (取最后匹配的一个)
    local pre_id
    pre_id=$(echo "$snap_list" | grep "${pre_desc}" | awk '{print $1}' | tail -n 1)
    local post_id
    post_id=$(echo "$snap_list" | grep "${post_desc}" | awk '{print $1}' | tail -n 1)
    
    # --- 情况 A: 任务已完成 ---
    if [[ -n "$pre_id" && -n "$post_id" ]]; then
        success "Step '${step_name}' already completed (Snapshots #${pre_id} & #${post_id}). Skipping."
        return 0
        
    # --- 情况 B: 上次任务未完成 (只有前置快照) ---
    elif [[ -n "$pre_id" ]]; then
        warn "Incomplete execution detected for '${step_name}' (Found Pre-snapshot #${pre_id} but no Post-snapshot)."
        
        echo -e -n "${PROMPT}Do you want to restore the pre-installation snapshot? [y/N] ${RESET}"
        read -r choice
        choice=${choice:-N}
        
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            info "Restoring snapshot #${pre_id}..."
            
            # 使用 undochange 恢复差异 (将当前系统状态 0 恢复为 snapshot ID 的状态)
            # 注意：这需要文件系统处于可写状态
            if run_command "Restoring system state" sudo snapper -c root undochange "${pre_id}..0"; then
                success "System restored to state before '${step_name}'."
                
                echo -e -n "${PROMPT}Reboot system now? [Y/n] ${RESET}"
                read -r reboot_choice
                reboot_choice=${reboot_choice:-Y}
                
                if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then
                    info "Rebooting..."
                    sudo reboot
                else
                    info "Please manually reboot or restart the script."
                    exit 0
                fi
            else
                error "Failed to restore snapshot."
                exit 1
            fi
        else
            info "Skipping pre-snapshot creation, retrying installation..."
            # 直接执行命令，成功后补创建后置快照
            if "${cmd[@]}"; then
                run_command "Creating post-snapshot" sudo snapper -c root create --description "${post_desc}"
            else
                error "Step '${step_name}' failed during retry."
                return 1
            fi
        fi
        
    # --- 情况 C: 正常执行 (无快照记录) ---
    else
        run_command "Creating pre-snapshot" sudo snapper -c root create --description "${pre_desc}"
        
        if "${cmd[@]}"; then
            run_command "Creating post-snapshot" sudo snapper -c root create --description "${post_desc}"
        else
            error "Step '${step_name}' failed."
            # 失败时不创建后置快照，这样下次运行就会进入"情况 B"
            return 1
        fi
    fi
}


# ==============================================================================
# 4. 主要功能模块
# ==============================================================================

# 写入预设的中国镜像源列表作为备选
write_china_mirrors() {
    info "Writing preset China mirrors to /etc/pacman.d/mirrorlist..."
    sudo tee /etc/pacman.d/mirrorlist > /dev/null <<'EOF'
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

# 环境检查 (Distro, FS, Network, GitHub)
check_environment() {
    print_section_title "Environment Checks"

    # 0. 检查用户身份
    info "Checking user identity..."
    if [[ $EUID -eq 0 ]]; then
        error "This script must be run as a normal user, not root."
        exit 1
    else
        success "Running as normal user: $(whoami)"
    fi

    # 1. 检查发行版
    info "Checking distribution..."
    if [[ -f /etc/os-release ]] && grep -q "ID=arch" /etc/os-release; then
        success "Arch Linux detected"
    else
        error "This script is designed for Arch Linux only."
        exit 1
    fi

    # 2. 检查根文件系统
    info "Checking root filesystem..."
    local root_fs_type
    if command -v findmnt &> /dev/null; then
        root_fs_type=$(findmnt -n -o FSTYPE /)
    else
        root_fs_type=$(stat -f -c %T /)
    fi
    
    if [[ "$root_fs_type" == "btrfs" ]]; then
        success "Root filesystem is btrfs"
    else
        error "Root filesystem must be btrfs (detected: $root_fs_type)"
        exit 1
    fi

    # 3. 检查网络连通性
    info "Checking network connectivity..."
    if ping -c 1 -W 2 223.5.5.5 &> /dev/null || ping -c 1 -W 2 8.8.8.8 &> /dev/null; then
        success "Network is connected"
    else
        error "Network is unreachable!"
        exit 1
    fi

}

# 检查 GitHub 连通性 (独立方法，支持代理)
check_github_connection() {
    print_section_title "GitHub Connection"

    echo -e -n "${PROMPT}Do you want to configure a proxy? [y/N] ${RESET}"
    read -r choice
    # 回车默认选 N
    choice=${choice:-N}

    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo -e -n "${PROMPT}Enter proxy URL (e.g., 192.168.50.1:10808): ${RESET}"
        read -r proxy_url
        if [[ -n "$proxy_url" ]]; then
            # 如果不包含协议头，默认添加 http://
            if [[ ! "$proxy_url" =~ ^[a-zA-Z]+:// ]]; then
                proxy_url="http://${proxy_url}"
            fi
            
            export http_proxy="$proxy_url"
            export https_proxy="$proxy_url"
            export all_proxy="$proxy_url"
            info "Proxy configured: $proxy_url"
        else
            warn "No proxy URL entered, skipping proxy configuration."
        fi
    else
        info "Skipping proxy configuration."
    fi

    local test_domain="github.com"
    info "Checking connectivity to ${test_domain}..."
    
    # 使用 curl 测试连通性(支持代理)，回退到 ping
    if curl -I --connect-timeout 5 -s "https://${test_domain}" >/dev/null || ping -c 1 -W 2 "${test_domain}" &> /dev/null; then
        GITHUB_AVAILABLE="true"
        success "GitHub connection is stable"
    else
        GITHUB_AVAILABLE="false"
        warn "Failed to connect to ${test_domain}. Some features may not work."
    fi
}

# 优选数据源
optimize_mirrors() {
    print_section_title "Optimizing Mirrors"
    
    # 尝试安装 reflector 如果不存在
    if ! command -v reflector &> /dev/null; then
         info "Reflector not found. Attempting to install..."
         run_command "Installing reflector" sudo pacman -S --noconfirm --needed reflector || true
    fi

    if ! (grep -q "generated by Reflector" /etc/pacman.d/mirrorlist || grep -q "China Mirrors - Sycamore Preset" /etc/pacman.d/mirrorlist); then
        
        # 询问是否覆盖
        echo -e -n "${PROMPT}Existing mirrorlist found. Optimize with Reflector? [Y/n] ${RESET}"
        read -r choice
        choice=${choice:-Y}
        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
            info "Skipping mirror optimization."
            return 0
        fi

        if command -v reflector &> /dev/null; then
            info "Using country code: ${SYSTEM_COUNTRY_CODE}"
            local reflector_cmd=("sudo" "reflector" "-c" "${SYSTEM_COUNTRY_CODE}" "-a" "12" "-f" "10" "--protocol" "http,https" "--sort" "score" "--save" "/etc/pacman.d/mirrorlist" "--verbose")
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
            warn "Reflector tool not found. Using preset China mirrors..."
            write_china_mirrors
        fi
    else
        success "Mirrors already optimized, skipping"
    fi
    
    # 同步数据库
    run_command "Syncing pacman databases" sudo pacman -Syy
}

# 初始化 Snapper 快照系统
setup_snapper() {
    print_section_title "Initializing Snapper"

    # 1. 安装 snapper
    if ! command -v snapper &> /dev/null; then
         info "Snapper not found. Installing..."
         run_command "Installing snapper" sudo pacman -S --noconfirm --needed snapper
    fi

    # 2. 初始化配置
    if ! sudo snapper list-configs | grep -q "root"; then
        info "Configuring snapper for root..."
        
        # 这里的处理是为了兼容 @snapshots 子卷模式
        # Snapper 默认会创建 .snapshots 子卷，但我们希望使用 @snapshots 挂载到 /.snapshots
        
        # 卸载可能存在的挂载
        if mountpoint -q /.snapshots; then
            run_command "Unmounting /.snapshots" sudo umount /.snapshots
        fi
        
        # 移除目录（如果存在），但为了安全起见，我们先尝试 rmdir (只删空目录)
        # 如果非空，则重命名备份，防止误删用户数据
        if [[ -d /.snapshots ]]; then
             if ! sudo rmdir /.snapshots 2>/dev/null; then
                 local backup_name="/.snapshots.backup.$(date +%Y%m%d%H%M%S)"
                 warn "/.snapshots is not empty. Backing up to ${backup_name}..."
                 run_command "Backing up old .snapshots" sudo mv /.snapshots "${backup_name}"
             else
                 info "Removed empty /.snapshots directory"
             fi
        fi

        # 创建配置
        run_command "Creating snapper config" sudo snapper -c root create-config /
        
        # 检查布局模式：如果 fstab 中存在 /.snapshots，则使用 Flat Layout (推荐)
        # 否则保持 Snapper 默认的 Nested Layout
        if grep -q "/.snapshots" /etc/fstab; then
            info "Flat layout detected in fstab. Configuring..."
            
            # 1. 删除 snapper 自动创建的嵌套子卷
            run_command "Deleting auto-created subvolume" sudo btrfs subvolume delete /.snapshots
            run_command "Recreating mountpoint" sudo mkdir /.snapshots
            
            # 2. 挂载独立的 @snapshots 子卷
            if run_command "Remounting @snapshots" sudo mount /.snapshots; then
                run_command "Setting permissions" sudo chmod 750 /.snapshots
                success "Snapper configured (Flat Layout)"
            else
                # 挂载失败，这是严重错误 (用户配置了 fstab 但无法挂载)
                error "Failed to remount /.snapshots. Aborting to prevent data pollution."
                return 1
            fi
        else
             info "No /.snapshots in fstab. Using default Nested Layout."
             success "Snapper configured (Nested Layout)"
        fi
        
        # 3. 配置保留策略
        info "Applying retention policy..."
        
        # 配置 Snapper 策略 (权限、自动化、保留规则)
        sudo snapper -c root set-config \
            ALLOW_GROUPS="wheel" \
            TIMELINE_CREATE="yes" \
            TIMELINE_CLEANUP="yes" \
            NUMBER_LIMIT="10" \
            NUMBER_LIMIT_IMPORTANT="5" \
            TIMELINE_LIMIT_HOURLY="5" \
            TIMELINE_LIMIT_DAILY="7" \
            TIMELINE_LIMIT_WEEKLY="0" \
            TIMELINE_LIMIT_MONTHLY="0" \
            TIMELINE_LIMIT_YEARLY="0"

        success "Retention policy applied"

    else
        info "Snapper already configured"
    fi
    
    # 3. 处理 /home 配置 (如果也是 Btrfs)
    # 检测 /home 是否挂载点且为 btrfs
    if mountpoint -q /home; then
        local home_fs_type
        if command -v findmnt &> /dev/null; then
            home_fs_type=$(findmnt -n -o FSTYPE /home)
        else
            home_fs_type=$(stat -f -c %T /home)
        fi
        
        if [[ "$home_fs_type" == "btrfs" ]]; then
            info "/home is btrfs. Configuring snapper for home..."
            
            if ! sudo snapper list-configs | grep -q "home"; then
                run_command "Creating snapper config for home" sudo snapper -c home create-config /home
                
                # 设置相同的策略
                sudo snapper -c home set-config \
                    ALLOW_GROUPS="wheel" \
                    TIMELINE_CREATE="yes" \
                    TIMELINE_CLEANUP="yes" \
                    NUMBER_LIMIT="10" \
                    NUMBER_LIMIT_IMPORTANT="5" \
                    TIMELINE_LIMIT_HOURLY="5" \
                    TIMELINE_LIMIT_DAILY="7" \
                    TIMELINE_LIMIT_WEEKLY="0" \
                    TIMELINE_LIMIT_MONTHLY="0" \
                    TIMELINE_LIMIT_YEARLY="0"
                
                success "Snapper configured for /home"
                
            else
                info "Snapper for /home already configured"
            fi
        fi
    fi

    # 4. 创建初始快照
    info "Creating initial snapshots..."
    
    # Root Snapshot
    # 检查是否存在描述为 "System Initialized" 的快照
    if sudo snapper -c root list | grep -q "Pre System Initialized"; then
        info "Root snapshot 'System Initialized' already exists, skipping."
    else
        run_command "Creating initial root snapshot" sudo snapper -c root create --description "Pre System Initialized"
    fi
    
    # Home Snapshot (if configured)
    if sudo snapper list-configs | grep -q "home"; then
        if sudo snapper -c home list | grep -q "Pre System Initialized"; then
             info "Home snapshot 'System Initialized' already exists, skipping."
        else
             run_command "Creating initial home snapshot" sudo snapper -c home create --description "Pre System Initialized"
        fi
    fi

    success "Initial snapshots verified"
}

# 设置全局默认编辑器
setup_editor() {
    print_section_title "Configuring Default Editor"

    # 安装 nvim
    if ! command -v nvim &> /dev/null; then
        info "Neovim not found. Installing..."
        run_command "Installing neovim" sudo pacman -S --noconfirm --needed neovim
    fi

    info "Setting global default editor to nvim..."
    
    local env_file="/etc/environment"
    
    # 设置 EDITOR 和 VISUAL
    for var in EDITOR VISUAL; do
        if grep -q "^${var}=" "$env_file"; then
            info "${var} already set in ${env_file}, skipping override."
        else
            run_command "Adding ${var}" bash -c "echo '${var}=nvim' | sudo tee -a $env_file"
        fi
    done
    
    success "Global editor set to nvim"
}


# 开启 32 位源 (Multilib)
enable_multilib() {
    print_section_title "Enabling Multilib Repository"

    if grep -q "^\[multilib\]" /etc/pacman.conf; then
        info "Multilib repository already enabled."
    else
        info "Enabling multilib repository..."
        # 取消注释 [multilib] 和紧随其后的 Include 行
        # 这里的 sed 命令会查找从 [multilib] 到 Include 之间的行，并去掉行首的 #
        if run_command "Modifying pacman.conf" sudo sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf; then
            run_command "Syncing databases" sudo pacman -Syy
            success "Multilib repository enabled"
        else
            error "Failed to enable multilib repository"
        fi
    fi
}

# 添加 Arch Linux CN 源
setup_archlinuxcn() {
    print_section_title "Adding Arch Linux CN Repository"

    # 1. 创建 mirrorlist 文件
    local cn_mirrorlist="/etc/pacman.d/archlinuxcn-mirrorlist"
    
    if [[ -f "$cn_mirrorlist" ]]; then
        info "${cn_mirrorlist} already exists, skipping creation."
    else
        info "Creating ${cn_mirrorlist}..."
        # 写入高质量国内源列表
        sudo tee "$cn_mirrorlist" > /dev/null <<'EOF'
## Arch Linux CN Mirrors
Server = https://mirrors.ustc.edu.cn/archlinuxcn/$arch
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/$arch
Server = https://mirrors.sjtug.sjtu.edu.cn/archlinuxcn/$arch
Server = https://mirrors.aliyun.com/archlinuxcn/$arch
EOF
    fi

    # 2. 配置 pacman.conf
    local need_sync=false
    
    if grep -q "^\[archlinuxcn\]" /etc/pacman.conf; then
        info "Arch Linux CN repository already enabled in pacman.conf."
    else
        info "Adding [archlinuxcn] to pacman.conf..."
        # 追加配置到 pacman.conf，引用 mirrorlist 文件
        run_command "Appending config to pacman.conf" bash -c "cat <<EOF | sudo tee -a /etc/pacman.conf

[archlinuxcn]
Include = ${cn_mirrorlist}
EOF"
        need_sync=true
    fi
        
    # 3. 安装 keyring
    if ! pacman -Qq archlinuxcn-keyring &> /dev/null; then
        info "archlinuxcn-keyring is missing."
        need_sync=true
    fi
    
    if [[ "$need_sync" == "true" ]]; then
        info "Syncing databases and installing keyring..."
        # 先更新数据库以便 pacman 知道新仓库
        run_command "Syncing databases" sudo pacman -Sy
        # 先确保官方 keyring 是最新的，避免签名验证问题
        run_command "Updating archlinux-keyring" sudo pacman -S --noconfirm --needed archlinux-keyring
        
        if run_command "Installing keyring" sudo pacman -S --noconfirm --needed archlinuxcn-keyring; then
            success "Arch Linux CN repository added and keyring installed"
        else
            error "Failed to install archlinuxcn-keyring. You may need to manually fix keys."
            return 1
        fi
    else
        success "Arch Linux CN setup already complete"
    fi
}

# 配置音视频固件和服务
setup_av() {
    print_section_title "Configuring Audio/Video Firmware & Services"

    # 检查核心服务是否已运行
    if systemctl --user is-active --quiet pipewire && \
       systemctl --user is-active --quiet pipewire-pulse && \
       systemctl --user is-active --quiet wireplumber; then
        success "PipeWire services already running, skipping."
        return 0
    fi

    info "Installing PipeWire stack and firmware..."
    local packages=(
        "pipewire"
        "pipewire-alsa"
        "pipewire-pulse"
        "pipewire-jack"
        "wireplumber"
        "alsa-utils"
        "sof-firmware"
        "alsa-firmware"
    )

    if run_command "Installing packages" sudo pacman -S --noconfirm --needed "${packages[@]}"; then
        info "Enabling PipeWire services..."
        # 启用 PipeWire 相关用户服务
        run_command "Enabling pipewire" systemctl --user enable --now pipewire
        run_command "Enabling pipewire-pulse" systemctl --user enable --now pipewire-pulse
        run_command "Enabling wireplumber" systemctl --user enable --now wireplumber
        
        success "Audio/Video firmware and services configured"
    else
        error "Failed to install Audio/Video packages"
        return 1
    fi
}

# 配置性能模式切换 (power-profiles-daemon)
setup_power_management() {
    print_section_title "Configuring Power Profiles"

    # 检查服务是否已激活
    if systemctl is-active --quiet power-profiles-daemon; then
        success "power-profiles-daemon is already active."
        return 0
    fi

    info "Installing power-profiles-daemon..."
    if run_command "Installing package" sudo pacman -S --noconfirm --needed power-profiles-daemon; then
        
        # 为了防止冲突，禁用其他电源管理工具
        for conflicting_service in tlp auto-cpufreq; do
            if systemctl is-active --quiet "${conflicting_service}"; then
                warn "${conflicting_service} detected. Disabling it to prevent conflicts..."
                run_command "Disabling ${conflicting_service}" sudo systemctl disable --now "${conflicting_service}"
            fi
        done

        run_command "Enabling service" sudo systemctl enable --now power-profiles-daemon.service
        success "Power profiles daemon configured"
    else
        error "Failed to install power-profiles-daemon"
        return 1
    fi
}

# 配置蓝牙
setup_bluetooth() {
    print_section_title "Configuring Bluetooth"

    # 检查服务是否已激活
    if systemctl is-active --quiet bluetooth; then
        success "Bluetooth service is already active."
        return 0
    fi

    info "Installing bluez bluetui packages..."
    if run_command "Installing bluez" sudo pacman -S --noconfirm --needed bluez bluetui; then
        info "Enabling bluetooth service..."
        run_command "Enabling service" sudo systemctl enable --now bluetooth.service
        success "Bluetooth configured"
    else
        error "Failed to install bluetooth packages"
        return 1
    fi
}

# 配置 Flatpak
setup_flatpak() {
    print_section_title "Configuring Flatpak"

    # 1. 检查是否安装
    if ! command -v flatpak &> /dev/null; then
        info "Installing flatpak..."
        if ! run_command "Installing flatpak" sudo pacman -S --noconfirm --needed flatpak; then
            error "Failed to install flatpak"
            return 1
        fi
    else
        info "Flatpak already installed"
    fi

    # 2. 添加 Flathub 及其国内镜像
    info "Configuring Flathub remote..."
    
    # 检查是否已经添加了 flathub
    if flatpak remote-list | grep -q "flathub"; then
        info "Flathub remote already exists."
    else
        # 添加官方 flathub (作为基础)
        run_command "Adding Flathub remote" sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    fi

    # 3. 设置 SJTU 镜像 (提升国内下载速度)
    # 修改 remote url 指向镜像
    info "Setting Flathub mirror to SJTU..."
    if run_command "Setting mirror" sudo flatpak remote-modify flathub --url=https://mirror.sjtu.edu.cn/flathub; then
        success "Flatpak configured with SJTU mirror"
    else
        warn "Failed to set SJTU mirror, falling back to default"
    fi
}

# ==============================================================================
# 5. 主流程
# ==============================================================================

main() {
    trap handle_interrupt SIGINT
    print_banner
    
    check_environment
    check_github_connection
    optimize_mirrors
    enable_multilib
    setup_snapper
    run_with_snapshot "Setup Editor" setup_editor
    run_with_snapshot "Setup ArchLinuxCN" setup_archlinuxcn
    run_with_snapshot "Setup AV" setup_av
    run_with_snapshot "Setup Bluetooth" setup_bluetooth
    run_with_snapshot "Setup Flatpak" setup_flatpak
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi