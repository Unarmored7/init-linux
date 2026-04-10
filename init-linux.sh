#!/usr/bin/env bash
#
# init-linux.sh
# =============
# Debian / Ubuntu 新系统初始化脚本。
#
# 当前功能：
#   1. 系统更新
#   2. 时间同步
#   3. SWAP 检查与创建
#   4. SSH 公钥登录配置
#   5. 安装 Docker
#
# 用法：
#   bash init-linux.sh
#   sudo bash init-linux.sh
#
# 环境变量：
#   DRY_RUN=1   仅打印将要执行的命令，不真正执行。

set -euo pipefail

# ---------------------------------------------------------------------------
# 日志辅助函数：当 stdout 连接终端时使用彩色输出，否则使用普通文本。
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && command -v tput &>/dev/null \
  && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
  RED=$(tput setaf 1)  GREEN=$(tput setaf 2)  YELLOW=$(tput setaf 3)
  CYAN=$(tput setaf 6) BOLD=$(tput bold)       RESET=$(tput sgr0)
else
  RED=""  GREEN=""  YELLOW=""  CYAN=""  BOLD=""  RESET=""
fi

info() { echo "${CYAN}${BOLD}[INFO]${RESET}  $*"; }
ok()   { echo "${GREEN}${BOLD}[ OK ]${RESET}  $*"; }
warn() { echo "${YELLOW}${BOLD}[WARN]${RESET}  $*" >&2; }
err()  { echo "${RED}${BOLD}[ERR ]${RESET}  $*" >&2; }
die()  { err "$@"; exit 1; }

# ---------------------------------------------------------------------------
# DRY_RUN 包装器：当 DRY_RUN=1 时，仅打印命令而不执行。
# ---------------------------------------------------------------------------
DRY_RUN="${DRY_RUN:-0}"

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "${YELLOW}[DRY_RUN]${RESET} $*"
  else
    "$@"
  fi
}

prompt_input() {
  local prompt="$1"
  local result

  if [[ -r /dev/tty ]]; then
    read -r -p "${prompt}" result </dev/tty
  elif [[ -t 0 ]]; then
    read -r -p "${prompt}" result
  else
    result=""
  fi

  printf '%s' "${result}"
}

recommended_swap_size() {
  local mem_mb="$1"

  if (( mem_mb <= 512 )); then
    echo "1G"
  elif (( mem_mb <= 1024 )); then
    echo "2G"
  elif (( mem_mb <= 6144 )); then
    echo "2G"
  elif (( mem_mb <= 16384 )); then
    echo "4G"
  elif (( mem_mb <= 65536 )); then
    echo "8G"
  elif (( mem_mb <= 131072 )); then
    echo "8G"
  else
    echo "16G"
  fi
}

swap_size_to_mb() {
  local size="$1"
  local value unit

  value="${size%[GgMm]}"
  unit="${size:${#value}}"

  case "${unit}" in
    G|g) echo $(( value * 1024 )) ;;
    M|m) echo "${value}" ;;
    *) die "无法识别 SWAP 大小格式：${size}" ;;
  esac
}

set_sshd_option() {
  local key="$1"
  local value="$2"
  local file="$3"

  if grep -Eq "^[#[:space:]]*${key}[[:space:]]+" "${file}"; then
    sed -i -E "s|^[#[:space:]]*${key}[[:space:]]+.*|${key} ${value}|" "${file}"
  else
    printf '%s %s\n' "${key}" "${value}" >> "${file}"
  fi
}

should_run_step() {
  local name="$1"
  local answer

  if [[ ! -r /dev/tty && ! -t 0 ]]; then
    return 0
  fi

  answer=$(prompt_input "[${name}] 默认执行，输入 n 跳过，按回车继续：[Y/n] ")
  [[ ! "${answer}" =~ ^[Nn]$ ]]
}

STEP_SYSTEM_UPDATE="未执行"
STEP_TIME_SYNC="未执行"
STEP_SWAP="未执行"
STEP_SSH="未执行"
STEP_DOCKER="未执行"

# ---------------------------------------------------------------------------
# 预检查
# ---------------------------------------------------------------------------
[[ -f /etc/os-release ]] || die "找不到 /etc/os-release，无法识别当前发行版。"
# shellcheck source=/dev/null
. /etc/os-release

if [[ "${ID:-}" != "debian" && "${ID:-}" != "ubuntu" ]]; then
  die "不支持当前发行版（ID=${ID:-unknown}），本脚本仅支持 Debian 和 Ubuntu。"
fi

# ---------------------------------------------------------------------------
# 功能：SSH 公钥登录配置
# ---------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
  die "请以 root 身份运行此脚本，例如：sudo bash $0"
fi

# ---------------------------------------------------------------------------
# 功能：系统更新
# ---------------------------------------------------------------------------
if should_run_step "系统更新"; then
  info "[系统更新] 即将开始。"
  info "[系统更新] 正在更新软件源..."
  run apt update

  info "[系统更新] 正在升级系统软件包..."
  run env DEBIAN_FRONTEND=noninteractive apt upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"

  echo
  ok "[系统更新] 执行完成：软件源已更新，系统已升级。"
  STEP_SYSTEM_UPDATE="已执行"
else
  warn "[系统更新] 已跳过。"
  STEP_SYSTEM_UPDATE="已跳过"
fi

# ---------------------------------------------------------------------------
# 功能：时间同步
# ---------------------------------------------------------------------------
if should_run_step "时间同步"; then
  info "[时间同步] 即将开始。"
  info "[时间同步] 正在设置时区为 Asia/Shanghai..."
  run timedatectl set-timezone Asia/Shanghai

  info "[时间同步] 正在安装 systemd-timesyncd..."
  run apt install -y systemd-timesyncd

  info "[时间同步] 正在启用自动对时..."
  run systemctl enable --now systemd-timesyncd

  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "${YELLOW}[DRY_RUN]${RESET} timedatectl set-ntp true"
  else
    if ! timedatectl set-ntp true; then
      warn "当前环境不支持通过 timedatectl 直接设置 NTP，已尽量启用 systemd-timesyncd。"
    fi
  fi

  if [[ "${DRY_RUN}" != "1" ]]; then
    TIMESYNCD_ENABLED=$(systemctl is-enabled systemd-timesyncd 2>/dev/null || true)
    TIMESYNCD_ACTIVE=$(systemctl is-active systemd-timesyncd 2>/dev/null || true)

    if [[ "${TIMESYNCD_ENABLED}" == "enabled" ]]; then
      ok "[时间同步] systemd-timesyncd 已设置为开机自启。"
    else
      warn "[时间同步] systemd-timesyncd 未确认开机自启，当前状态：${TIMESYNCD_ENABLED:-unknown}"
    fi

    if [[ "${TIMESYNCD_ACTIVE}" == "active" ]]; then
      ok "[时间同步] systemd-timesyncd 正在运行。"
    else
      warn "[时间同步] systemd-timesyncd 当前未处于运行状态：${TIMESYNCD_ACTIVE:-unknown}"
    fi

    info "[时间同步] 当前时间配置："
    timedatectl
    date
  fi

  echo
  ok "[时间同步] 执行完成：已设置时区，并已检查自动对时服务状态。"
  STEP_TIME_SYNC="已执行"
else
  warn "[时间同步] 已跳过。"
  STEP_TIME_SYNC="已跳过"
fi

# ---------------------------------------------------------------------------
# 功能：SWAP 检查与创建
# ---------------------------------------------------------------------------
if should_run_step "SWAP"; then
  info "[SWAP] 即将开始。"
  CURRENT_SWAP=$(swapon --show=NAME,SIZE --noheadings 2>/dev/null || true)

  if [[ -n "${CURRENT_SWAP}" ]]; then
    ok "[SWAP] 检测到系统已存在 SWAP，跳过创建。"
    if [[ "${DRY_RUN}" != "1" ]]; then
      swapon --show
      free -m
    fi
  else
    MEM_MB=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
    SWAP_SIZE=$(recommended_swap_size "${MEM_MB}")
    SWAP_SIZE_MB=$(swap_size_to_mb "${SWAP_SIZE}")

    info "[SWAP] 未检测到 SWAP，当前物理内存约 ${MEM_MB} MB。"
    info "[SWAP] 将按通用推荐创建 ${SWAP_SIZE} 的 /swapfile ..."

    if [[ -e /swapfile ]]; then
      warn "[SWAP] 检测到 /swapfile 已存在，将尝试直接启用并写入开机挂载。"

      if [[ "${DRY_RUN}" == "1" ]]; then
        echo "${YELLOW}[DRY_RUN]${RESET} chmod 600 /swapfile"
        echo "${YELLOW}[DRY_RUN]${RESET} mkswap /swapfile"
        echo "${YELLOW}[DRY_RUN]${RESET} swapon /swapfile"
        echo "${YELLOW}[DRY_RUN]${RESET} grep -q '^/swapfile ' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >> /etc/fstab"
      else
        chmod 600 /swapfile
        if ! blkid /swapfile 2>/dev/null | grep -q 'TYPE="swap"'; then
          mkswap /swapfile
        fi
        swapon /swapfile
        grep -q '^/swapfile ' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
        ok "[SWAP] 已启用现有 /swapfile。"
        swapon --show
        free -m
      fi
    else
      if command -v fallocate &>/dev/null; then
        run fallocate -l "${SWAP_SIZE}" /swapfile
      else
        warn "[SWAP] 未找到 fallocate，改用 dd 创建 /swapfile，速度可能较慢。"
        run dd if=/dev/zero of=/swapfile bs=1M count="${SWAP_SIZE_MB}" status=progress
      fi

      run chmod 600 /swapfile
      run mkswap /swapfile
      run swapon /swapfile

      if [[ "${DRY_RUN}" == "1" ]]; then
        echo "${YELLOW}[DRY_RUN]${RESET} grep -q '^/swapfile ' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >> /etc/fstab"
      else
        grep -q '^/swapfile ' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
      fi

      if [[ "${DRY_RUN}" != "1" ]]; then
        ok "[SWAP] 已创建并启用 ${SWAP_SIZE} 的 /swapfile。"
        swapon --show
        free -m
      fi
    fi
  fi

  echo
  ok "[SWAP] 执行完成。"
  STEP_SWAP="已执行"
else
  warn "[SWAP] 已跳过。"
  STEP_SWAP="已跳过"
fi

# ---------------------------------------------------------------------------
# 功能：SSH 公钥登录配置
# ---------------------------------------------------------------------------
if should_run_step "SSH"; then
  info "[SSH] 即将开始。"

  if [[ ! -r /dev/tty && ! -t 0 ]]; then
    warn "[SSH] 当前不是交互终端，已跳过 SSH 配置。"
  else
    echo
    SSH_PUBLIC_KEY=$(prompt_input "[SSH] 请输入要写入的 SSH 公钥（直接回车跳过）：")

    if [[ -z "${SSH_PUBLIC_KEY}" ]]; then
      info "[SSH] 未输入公钥，已跳过 SSH 配置。"
    else
      SSH_PORT=$(prompt_input "[SSH] 请输入 SSH 端口（直接回车保持当前配置不变）：")

      if [[ -n "${SSH_PORT}" ]]; then
        [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || die "[SSH] SSH 端口必须是数字。"
        (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die "[SSH] SSH 端口必须在 1-65535 之间。"
      fi

      info "[SSH] 正在配置 root 用户的 SSH 公钥登录..."

      if [[ "${DRY_RUN}" == "1" ]]; then
        echo "${YELLOW}[DRY_RUN]${RESET} install -m 700 -d /root/.ssh"
        echo "${YELLOW}[DRY_RUN]${RESET} write public key to /root/.ssh/authorized_keys"
        echo "${YELLOW}[DRY_RUN]${RESET} chmod 600 /root/.ssh/authorized_keys"
      else
        install -m 700 -d /root/.ssh
        touch /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
        if grep -Fxq -- "${SSH_PUBLIC_KEY}" /root/.ssh/authorized_keys; then
          ok "[SSH] 公钥已存在于 /root/.ssh/authorized_keys，跳过重复写入。"
        else
          printf '%s\n' "${SSH_PUBLIC_KEY}" >> /root/.ssh/authorized_keys
          ok "[SSH] 已写入公钥到 /root/.ssh/authorized_keys。"
        fi
      fi

      SSH_CONFIRM=$(prompt_input "[SSH] 已写入公钥，准备关闭密码登录并应用 SSH 配置，是否继续？[y/N] ")
      if [[ ! "${SSH_CONFIRM}" =~ ^[Yy]$ ]]; then
        warn "[SSH] 已取消修改 sshd_config，仅保留公钥写入。"
      else
        info "[SSH] 正在更新 sshd_config ..."

        if [[ "${DRY_RUN}" == "1" ]]; then
          echo "${YELLOW}[DRY_RUN]${RESET} cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak"
          if [[ -n "${SSH_PORT}" ]]; then
            echo "${YELLOW}[DRY_RUN]${RESET} set Port ${SSH_PORT}"
          else
            echo "${YELLOW}[DRY_RUN]${RESET} keep current Port setting"
          fi
          echo "${YELLOW}[DRY_RUN]${RESET} set PermitRootLogin prohibit-password"
          echo "${YELLOW}[DRY_RUN]${RESET} set PubkeyAuthentication yes"
          echo "${YELLOW}[DRY_RUN]${RESET} set PasswordAuthentication no"
          echo "${YELLOW}[DRY_RUN]${RESET} sshd -t"
          echo "${YELLOW}[DRY_RUN]${RESET} systemctl restart ssh"
        else
          cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
          if [[ -n "${SSH_PORT}" ]]; then
            set_sshd_option "Port" "${SSH_PORT}" /etc/ssh/sshd_config
          fi
          set_sshd_option "PermitRootLogin" "prohibit-password" /etc/ssh/sshd_config
          set_sshd_option "PubkeyAuthentication" "yes" /etc/ssh/sshd_config
          set_sshd_option "PasswordAuthentication" "no" /etc/ssh/sshd_config

          if command -v sshd &>/dev/null; then
            sshd -t || die "[SSH] sshd_config 校验失败，已保留备份：/etc/ssh/sshd_config.bak"
          fi

          if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
            systemctl restart ssh
          elif systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
            systemctl restart sshd
          else
            warn "[SSH] 未找到 ssh/sshd systemd 服务，请手动重启 SSH 服务。"
          fi

          ok "[SSH] SSH 配置已更新并尝试重启服务。"
        fi

        warn "[SSH] 请不要立即关闭当前连接。"
        if [[ -n "${SSH_PORT}" ]]; then
          warn "[SSH] 请先使用新端口 ${SSH_PORT} 和公钥重新开一个终端测试登录。"
        else
          warn "[SSH] 请先使用当前端口和公钥重新开一个终端测试登录。"
        fi
      fi
    fi
  fi

  echo
  ok "[SSH] 执行完成。"
  STEP_SSH="已执行"
else
  warn "[SSH] 已跳过。"
  STEP_SSH="已跳过"
fi

# ---------------------------------------------------------------------------
# 功能：安装 Docker
# ---------------------------------------------------------------------------
if should_run_step "Docker"; then
  info "[Docker] 即将开始。"
  info "[Docker] 正在调用远程安装脚本..."

  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "${YELLOW}[DRY_RUN]${RESET} wget -qO- https://raw.githubusercontent.com/Unarmored7/install-docker/main/install-docker.sh | bash"
  else
    wget -qO- https://raw.githubusercontent.com/Unarmored7/install-docker/main/install-docker.sh | bash
  fi

  echo
  ok "[Docker] 执行完成。"
  STEP_DOCKER="已执行"
else
  warn "[Docker] 已跳过。"
  STEP_DOCKER="已跳过"
fi

echo
echo "════════════════════════════════════════════════════════════════"
ok "初始化脚本执行结束"
echo "────────────────────────────────────────────────────────────────"
info "系统更新 : ${STEP_SYSTEM_UPDATE}"
info "时间同步 : ${STEP_TIME_SYNC}"
info "SWAP     : ${STEP_SWAP}"
info "SSH      : ${STEP_SSH}"
info "Docker   : ${STEP_DOCKER}"
if [[ "${DRY_RUN}" == "1" ]]; then
  warn "当前为 DRY_RUN 模式，以上操作仅做了命令预览。"
fi
echo "════════════════════════════════════════════════════════════════"
