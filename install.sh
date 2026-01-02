#!/bin/bash
# ==============================================================================
# Arch Linux 初始化脚本 (Based on Chezmoi)
#
# 该脚本用于在最小化 Arch Linux 安装后初始化环境。
# 主要功能：
#   - 基础环境检查 (网络)
#   - 安装必要依赖 (Git, Chezmoi)
#   - 使用 Chezmoi 拉取并应用配置 (Dotfiles)
# ==============================================================================

set -euo pipefail

print_banner() {
    clear
    cat << "EOF"
    ███████╗██╗   ██╗ ██████╗ █████╗ ███╗   ███╗ ██████╗ ██████╗ ███████╗
    ██╔════╝╚██╗ ██╔╝██╔════╝██╔══██╗████╗ ████║██╔═══██╗██╔══██╗██╔════╝
    ███████╗ ╚████╔╝ ██║     ███████║██╔████╔██║██║   ██║██████╔╝█████╗
    ╚════██║  ╚██╔╝  ██║     ██╔══██║██║╚██╔╝██║██║   ██║██╔══██╗██╔══╝
    ███████║   ██║   ╚██████╗██║  ██║██║ ╚═╝ ██║╚██████╔╝██║  ██║███████╗
    ╚══════╝   ╚═╝    ╚═════╝╚═╝  ╚═╝╚═╝     ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝
EOF
    echo -e "    ${BOLD_CYAN}Arch Linux Installer v${VERSION} by Sycamore${RESET}\n"
}

# ==============================================================================
# 1. 全局变量与配置
# ==============================================================================

VERSION="0.1.0"
# GitHub 用户名
DEFAULT_USERNAME="0Sycamores"

# ==============================================================================
# 2. TUI 颜色与样式定义 (Ported from livecd.sh)
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
    
    DIM='\033[2m'
    
    INFO="${BOLD_BLUE}"
    SUCCESS="${BOLD_GREEN}"
    WARNING="${BOLD_YELLOW}"
    ERROR="${BOLD_RED}"
    HEADER="${BOLD_MAGENTA}"
    PROMPT="${BOLD_CYAN}"
else
    RESET=''
    BOLD_RED='' BOLD_GREEN='' BOLD_YELLOW='' BOLD_BLUE='' BOLD_MAGENTA='' BOLD_CYAN='' BOLD_WHITE=''
    DIM=''
    INFO='' SUCCESS='' WARNING='' ERROR='' HEADER='' PROMPT=''
fi

# ==============================================================================
# 3. 核心工具函数 (Ported from livecd.sh)
# ==============================================================================

info() {
    echo -e "${INFO}[INFO]${RESET} $*"
}

success() {
    echo -e "${SUCCESS}[SUCCESS]${RESET} $*"
}

warn() {
    echo -e "${WARNING}[WARNING]${RESET} $*"
}

error() {
    echo -e "${ERROR}[ERROR]${RESET} $*" >&2
}

print_section_title() {
    local title="$1"
    echo -e "${HEADER}[SECTION]${RESET} ${BOLD_WHITE}${title}${RESET}"
}

# 执行命令并显示带有缓冲区的输出
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
    # 注意：这里使用了临时文件来捕获退出码，因为管道会吞掉子进程的退出码
    # 或者使用 { ... } 2>&1 | ... 的方式，但在 bash 中获取管道中第一个命令的退出码较麻烦 (${PIPESTATUS[0]})
    
    set +e # 临时关闭 set -e 以便手动处理错误
    {
        "${cmd[@]}" 2>&1 | while IFS= read -r line; do
            buffer+=("${line:0:110}")
            if [[ ${#buffer[@]} -gt ${max_lines} ]]; then
                buffer=("${buffer[@]:1}")
            fi

            if [[ ${line_count} -gt 0 ]]; then
                for ((i=0; i<line_count; i++)); do
                    echo -ne "\033[1A\033[2K"
                done
            fi

            line_count=${#buffer[@]}
            for output_line in "${buffer[@]}"; do
                echo -e "${DIM}  │ ${output_line}${RESET}"
            done
        done
        
    }
    local exit_code=${PIPESTATUS[0]}
    set -e # 恢复 set -e

    if [[ ${line_count} -gt 0 ]]; then
        for ((i=0; i<line_count; i++)); do
            echo -ne "\033[1A\033[2K"
        done
    fi

    if [[ ${exit_code} -eq 0 ]]; then
        success "${description} completed"
    else
        error "${description} failed (exit code: ${exit_code})"
        return ${exit_code}
    fi
}

# ==============================================================================
# 4. 主要功能模块
# ==============================================================================

# 检查网络连接
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

# 检查并安装依赖 (Git, Chezmoi)
install_dependencies() {
    print_section_title "Dependency Installation"

    local deps_to_install=()

    if ! command -v git &> /dev/null; then
        deps_to_install+=(git)
    fi

    if ! command -v chezmoi &> /dev/null; then
        deps_to_install+=(chezmoi)
    fi

    if [[ ${#deps_to_install[@]} -gt 0 ]]; then
        info "Installing missing dependencies: ${deps_to_install[*]}"
        
        # 检查是否有 sudo
        local sudo_cmd=""
        if command -v sudo &> /dev/null && [[ $EUID -ne 0 ]]; then
            sudo_cmd="sudo"
        fi

        run_command "Installing packages" $sudo_cmd pacman -Syu --noconfirm --needed "${deps_to_install[@]}"
    else
        success "All dependencies (git, chezmoi) are already installed."
    fi
    echo ""
}

# 使用 Chezmoi 初始化
init_chezmoi() {
    print_section_title "Dotfiles Initialization"

    local target="$1"
    
    if [[ -z "$target" ]]; then
        error "No target repository specified."
        exit 1
    fi

    info "Target: ${BOLD_WHITE}${target}${RESET}"

    if [[ -d "$HOME/.local/share/chezmoi" ]]; then
        info "Chezmoi directory already exists."
        run_command "Updating and applying dotfiles" chezmoi update --apply
    else
        info "Initializing chezmoi..."
        run_command "Initializing and applying dotfiles" chezmoi init --apply "$target"
    fi
    
    echo ""
}

# 脚本完成提示
finish() {
    print_section_title "Initialization Complete"
    echo -e "${SUCCESS}System initialization finished successfully!${RESET}"
    echo -e "Please restart your shell or log out and log back in to see all changes."
    echo ""
}

# ==============================================================================
# 5. 主流程
# ==============================================================================

main() {
    check_network
    # TODO 优选源
    # TODO 快照保护
    # TODO 设置全局默认文本编辑器 创建普通用户 开启32位源 archlinuxcn源
    # TODO 判断GITHUB连通性，配置DAE DAED
    install_dependencies
    init_chezmoi "$DOTFILES_REPO"
    finish
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi