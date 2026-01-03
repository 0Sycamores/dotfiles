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

        # 更新缓冲区（保留最后5行，截断超长行）
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

# 检查基础网络连通性 (Ping IP)
check_connectivity() {
    print_section_title "Checking Network Connectivity"
    
    info "Pinging public DNS servers..."
    if ping -c 1 -W 2 223.5.5.5 &> /dev/null || ping -c 1 -W 2 8.8.8.8 &> /dev/null; then
        success "Network is connected"
    else
        error "Network is unreachable!"
        exit 1
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

# 检查 GitHub 连通性
check_github_connectivity() {
    print_section_title "Checking GitHub Connectivity"

    local test_domain="github.com"
    
    if run_command "Checking connectivity to ${test_domain}" ping -c 4 -W 2 "${test_domain}"; then
        GITHUB_AVAILABLE="true"
        success "GitHub connection is stable"
    else
        GITHUB_AVAILABLE="false"
        error "Failed to connect to ${test_domain}"
        warn "GitHub is not reachable. Some features may not work."
    fi
} 

# ==============================================================================
# 5. 主流程
# ==============================================================================

main() {
    trap handle_interrupt SIGINT
    print_banner
    
    check_connectivity
    optimize_mirrors
    check_github_connectivity
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi