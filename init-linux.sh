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
#   bash init-linux.sh [--dry-run]
#   sudo bash init-linux.sh [--dry-run]
#
# 选项：
#   -n, --dry-run   仅打印将要执行的命令，不真正执行（可以非 root 运行）。
#   -h, --help      显示帮助。
#
# 环境变量：
#   DRY_RUN=1   同 --dry-run。注意 sudo 默认会清除环境变量，
#               请使用 sudo DRY_RUN=1 bash ... 或 --dry-run。

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

usage() {
  cat <<'USAGE'
用法：bash init-linux.sh [--dry-run]

选项：
  -n, --dry-run   仅打印将要执行的命令，不真正执行（可以非 root 运行）
  -h, --help      显示帮助

通过管道运行时传递参数：
  curl -fsSL <url> | sudo bash -s -- --dry-run
USAGE
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      -n|--dry-run) DRY_RUN=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "未知参数：$1" ;;
    esac
    shift
  done
}

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "${YELLOW}[DRY_RUN]${RESET} $*"
  else
    "$@"
  fi
}

ensure_download_tool() {
  local context="$1"

  if command -v curl &>/dev/null || command -v wget &>/dev/null; then
    return 0
  fi

  info "[${context}] 未找到 curl/wget，正在安装 curl..."
  run apt-get update -qq
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl

  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi

  command -v curl &>/dev/null || command -v wget &>/dev/null \
    || die "[${context}] 无法找到 curl/wget，也未能自动安装 curl。"
}

download_to_file() {
  local url="$1"
  local output="$2"

  if command -v curl &>/dev/null; then
    curl -fsSL "${url}" -o "${output}"
  elif command -v wget &>/dev/null; then
    wget -qO "${output}" "${url}"
  else
    return 127
  fi
}

run_verified_script() {
  local context="$1"
  local url="$2"
  local expected_sha256="$3"
  local script_file
  local exit_status

  command -v sha256sum &>/dev/null \
    || die "[${context}] 未找到 sha256sum，无法校验下载内容。"

  script_file=$(mktemp)
  if ! download_to_file "${url}" "${script_file}"; then
    rm -f -- "${script_file}"
    die "[${context}] 脚本下载失败。"
  fi

  if ! printf '%s  %s\n' "${expected_sha256}" "${script_file}" \
    | sha256sum -c - &>/dev/null; then
    rm -f -- "${script_file}"
    die "[${context}] 脚本 SHA-256 校验失败，已拒绝执行。"
  fi

  if bash "${script_file}"; then
    rm -f -- "${script_file}"
  else
    exit_status=$?
    rm -f -- "${script_file}"
    return "${exit_status}"
  fi
}

# /dev/tty 在无控制终端时（cloud-init、cron、ssh 不带 -t）依然存在且权限可读，
# 但打开会失败，所以必须实际尝试打开才能判断是否可交互。
tty_available() {
  { : </dev/tty; } 2>/dev/null
}

is_interactive() {
  tty_available || [[ -t 0 ]]
}

prompt_input() {
  local prompt="$1"
  local result=""

  if tty_available; then
    read -r -p "${prompt}" result </dev/tty || true
  elif [[ -t 0 ]]; then
    read -r -p "${prompt}" result || true
  fi

  printf '%s' "${result}"
}

installed_time_daemon() {
  local pkg

  for pkg in chrony ntpsec ntp openntpd; do
    # shellcheck disable=SC2016  # ${Status} 是 dpkg-query 的格式字段
    if [[ "$(dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null)" == "install ok installed" ]]; then
      printf '%s' "${pkg}"
      return 0
    fi
  done

  return 1
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

# 创建 /swapfile 前要求根分区至少保留的剩余空间（MB）。
SWAP_MIN_FREE_MB=1024

container_type() {
  local virt

  if command -v systemd-detect-virt &>/dev/null; then
    virt=$(systemd-detect-virt --container 2>/dev/null) || return 1
    printf '%s' "${virt}"
    return 0
  fi

  if [[ -e /proc/user_beancounters && ! -e /proc/bc ]]; then
    printf 'openvz'
  elif [[ -e /.dockerenv || -e /run/.containerenv ]]; then
    printf 'container'
  else
    return 1
  fi
}

# 在 if 条件中调用时 set -e 不生效，因此每一步都显式检查返回值。
create_swapfile() {
  local size="$1"
  local size_mb="$2"

  : > /swapfile || return 1
  chmod 600 /swapfile || return 1

  # btrfs 上的 swapfile 必须是 NOCOW，且要在写入数据前设置。
  if [[ "$(stat -f -c %T / 2>/dev/null)" == "btrfs" ]]; then
    chattr +C /swapfile || return 1
  fi

  if ! { command -v fallocate &>/dev/null && fallocate -l "${size}" /swapfile; }; then
    warn "[SWAP] fallocate 不可用或失败，改用 dd 创建 /swapfile，速度可能较慢。"
    dd if=/dev/zero of=/swapfile bs=1M count="${size_mb}" status=progress || return 1
  fi

  mkswap /swapfile || return 1
  swapon /swapfile
}

add_swap_fstab_entry() {
  grep -Eq '^/swapfile[[:space:]]' /etc/fstab && return 0

  # 末行缺少换行符时先补一个，避免新条目与末行拼接。
  if [[ -s /etc/fstab && -n "$(tail -c 1 /etc/fstab)" ]]; then
    echo >> /etc/fstab
  fi
  printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
}

validate_ssh_public_key() {
  local public_key="$1"
  local key_file

  command -v ssh-keygen &>/dev/null \
    || die "[SSH] 未找到 ssh-keygen，无法校验 SSH 公钥。"

  key_file=$(mktemp)
  printf '%s\n' "${public_key}" > "${key_file}"

  if ! ssh-keygen -l -f "${key_file}" &>/dev/null; then
    rm -f -- "${key_file}"
    die "[SSH] 公钥格式无效，请检查是否粘贴完整。"
  fi

  rm -f -- "${key_file}"
}

# 调用方用 || 处理失败，此时 set -e 不生效，因此每一步都显式检查返回值。
install_authorized_key() {
  local user="$1"
  local public_key="$2"
  local home group ssh_dir keys_file

  home=$(getent passwd "${user}" | cut -d: -f6)
  if [[ -z "${home}" || ! -d "${home}" ]]; then
    err "[SSH] 无法确定用户 ${user} 的家目录。"
    return 1
  fi
  group=$(id -gn "${user}") || return 1
  ssh_dir="${home}/.ssh"
  keys_file="${ssh_dir}/authorized_keys"

  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "${YELLOW}[DRY_RUN]${RESET} install -o ${user} -g ${group} -m 700 -d ${ssh_dir}"
    echo "${YELLOW}[DRY_RUN]${RESET} append public key to ${keys_file} (chmod 600)"
    return 0
  fi

  install -o "${user}" -g "${group}" -m 700 -d "${ssh_dir}" || return 1
  touch "${keys_file}" || return 1
  chown "${user}:${group}" "${keys_file}" || return 1
  chmod 600 "${keys_file}" || return 1
  if grep -Fxq -- "${public_key}" "${keys_file}"; then
    ok "[SSH] 公钥已存在于 ${keys_file}，跳过重复写入。"
  else
    printf '%s\n' "${public_key}" >> "${keys_file}" || return 1
    ok "[SSH] 已写入公钥到 ${keys_file}。"
  fi
}

# 列出关闭密码登录后可能无法登录的非 root 用户：
# 有可登录 shell、设置了可用密码，但 ~/.ssh/authorized_keys 为空或不存在。
password_only_users() {
  local user hash home shell

  [[ -r /etc/shadow ]] || return 0

  while IFS=: read -r user hash _; do
    [[ "${user}" != "root" ]] || continue
    [[ -n "${hash}" && "${hash}" != [\!\*]* ]] || continue
    IFS=: read -r _ _ _ _ _ home shell <<< "$(getent passwd "${user}")"
    case "${shell}" in
      ""|*/nologin|*/false) continue ;;
    esac
    [[ ! -s "${home}/.ssh/authorized_keys" ]] || continue
    printf '%s\n' "${user}"
  done < /etc/shadow
}

write_sshd_managed_config() {
  local file="$1"
  local requested_port="$2"
  local root_login="$3"
  local previous_managed_port=""
  local temp_file

  previous_managed_port=$(awk '
    $0 == "# BEGIN init-linux managed SSH settings" { managed = 1; next }
    $0 == "# END init-linux managed SSH settings" { managed = 0; next }
    managed && $1 == "Port" { print $2; exit }
  ' "${file}")

  temp_file=$(mktemp "${file}.init-linux.XXXXXX")
  {
    echo "# BEGIN init-linux managed SSH settings"
    if [[ -n "${requested_port}" ]]; then
      printf 'Port %s\n' "${requested_port}"
    elif [[ -n "${previous_managed_port}" ]]; then
      printf 'Port %s\n' "${previous_managed_port}"
    fi
    printf 'PermitRootLogin %s\n' "${root_login}"
    echo "PubkeyAuthentication yes"
    echo "AuthenticationMethods publickey"
    echo "PasswordAuthentication no"
    echo "KbdInteractiveAuthentication no"
    echo "# END init-linux managed SSH settings"
    echo
    # Port 可以出现多次且会累加监听，指定新端口时注释掉文件中其他 Port 行，
    # 否则旧端口（如 22）仍会继续监听。
    awk -v disable_port="${requested_port:+1}" '
      $0 == "# BEGIN init-linux managed SSH settings" { skip = 1; next }
      $0 == "# END init-linux managed SSH settings" { skip = 0; next }
      skip { next }
      disable_port && tolower($0) ~ /^[ \t]*port([ \t]|=)/ {
        print "# " $0 "  # disabled by init-linux"
        next
      }
      { print }
    ' "${file}"
  } > "${temp_file}"

  chmod --reference="${file}" "${temp_file}"
  chown --reference="${file}" "${temp_file}"
  mv -f -- "${temp_file}" "${file}"
}

sshd_root_effective_config() {
  local config_file="${1:-/etc/ssh/sshd_config}"
  local host_name

  host_name=$(hostname 2>/dev/null || echo localhost)
  sshd -T -f "${config_file}" \
    -C "user=root,host=${host_name},addr=127.0.0.1" 2>/dev/null
}

# 当前已经比 prohibit-password 更严格（no / forced-commands-only）时保持不变，
# 避免把已禁止的 root 登录重新放开。判断时去掉本脚本之前写入的托管配置块，
# 否则重复运行时托管块会遮住管理员自己的设置。
choose_root_login_policy() {
  local current=""
  local stripped_config

  if command -v sshd &>/dev/null && [[ -r /etc/ssh/sshd_config ]]; then
    stripped_config=$(mktemp)
    awk '
      $0 == "# BEGIN init-linux managed SSH settings" { skip = 1; next }
      $0 == "# END init-linux managed SSH settings" { skip = 0; next }
      !skip { print }
    ' /etc/ssh/sshd_config > "${stripped_config}"
    current=$(sshd_root_effective_config "${stripped_config}" \
      | awk '$1 == "permitrootlogin" { print $2 }' || true)
    rm -f -- "${stripped_config}"
  fi

  case "${current}" in
    no|forced-commands-only) printf '%s' "${current}" ;;
    *) printf 'prohibit-password' ;;
  esac
}

verify_sshd_effective_config() {
  local root_login="$1"
  local root_login_pattern="${root_login}"
  local effective_config

  effective_config=$(sshd_root_effective_config) || return 1

  # 不覆盖 AuthorizedKeysFile，只确认 root 的有效配置仍会读取刚写入的公钥文件。
  grep -Eq '^authorizedkeysfile( .*)? (\.ssh/authorized_keys|%h/\.ssh/authorized_keys|/root/\.ssh/authorized_keys)( |$)' \
    <<< "${effective_config}" \
    || { err "[SSH] root 的 AuthorizedKeysFile 不包含 .ssh/authorized_keys，写入的公钥不会生效。"; return 1; }

  if [[ "${root_login}" == "prohibit-password" ]]; then
    root_login_pattern="(prohibit-password|without-password)"
  fi

  grep -Eq "^permitrootlogin ${root_login_pattern}\$" <<< "${effective_config}" \
    && grep -Fxq 'pubkeyauthentication yes' <<< "${effective_config}" \
    && grep -Fxq 'authenticationmethods publickey' <<< "${effective_config}" \
    && grep -Fxq 'passwordauthentication no' <<< "${effective_config}" \
    && grep -Fxq 'kbdinteractiveauthentication no' <<< "${effective_config}"
}

# sshd_config.d 等 Include 文件中的 Port 不会被本脚本修改，只做提示。
warn_extra_ssh_ports() {
  local requested_port="$1"
  local port
  local -a extra_ports=()

  while read -r port; do
    [[ "${port}" == "${requested_port}" ]] || extra_ports+=("${port}")
  done < <(sshd_root_effective_config | awk '$1 == "port" { print $2 }' || true)

  if (( ${#extra_ports[@]} > 0 )); then
    warn "[SSH] 除 ${requested_port} 外，sshd 仍会监听端口：${extra_ports[*]}"
    warn "[SSH] 这些 Port 来自 Include 的配置文件（如 /etc/ssh/sshd_config.d/），请按需手动移除。"
  fi
}

systemd_unit_is_loaded() {
  local unit="$1"
  local load_state

  load_state=$(systemctl show -p LoadState --value "${unit}" 2>/dev/null || true)
  [[ "${load_state}" == "loaded" ]]
}

restart_ssh_service() {
  local unit service

  # Ubuntu 22.10+ 默认由 ssh.socket 监听端口，Port 由 systemd generator 从
  # sshd_config 生成，必须 daemon-reload 并重启 socket，新端口才会生效。
  # 重启 socket 会连带重启 ssh.service（KillMode=process，不影响已有会话）。
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    systemctl daemon-reload \
      || die "[SSH] systemctl daemon-reload 失败，请检查 systemd 状态。"
    systemctl restart ssh.socket \
      || die "[SSH] systemctl restart ssh.socket 失败，请检查 SSH 服务状态。"
    ok "[SSH] 已执行 systemctl daemon-reload 和 systemctl restart ssh.socket。"
    return 0
  fi

  for unit in ssh.service sshd.service; do
    if systemd_unit_is_loaded "${unit}"; then
      service="${unit%.service}"
      if systemctl restart "${service}"; then
        ok "[SSH] 已执行 systemctl restart ${service}。"
        return 0
      fi

      die "[SSH] systemctl restart ${service} 失败，请检查 SSH 服务状态。"
    fi
  done

  warn "[SSH] 未找到 ssh/sshd systemd 服务，请手动重启 SSH 服务。"
}

check_ssh_port_listening() {
  local port="$1"

  command -v ss &>/dev/null || return 0

  if [[ -n "$(ss -Hltn "sport = :${port}" 2>/dev/null)" ]]; then
    ok "[SSH] 已确认端口 ${port} 正在监听。"
  else
    warn "[SSH] 未检测到端口 ${port} 处于监听状态，请检查 SSH 服务后再断开当前连接。"
  fi
}

should_run_step() {
  local name="$1"
  local answer

  if ! is_interactive; then
    return 0
  fi

  answer=$(prompt_input "[${name}] 默认执行，输入 n 跳过，按回车继续：[Y/n] ")
  [[ ! "${answer}" =~ ^[Nn]$ ]]
}

print_summary() {
  local title_level="$1"
  local title="$2"

  echo
  echo "════════════════════════════════════════════════════════════════"
  "${title_level}" "${title}"
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
}

# 异常退出时指出中断的步骤并输出总结。各步骤按顺序执行且结束时才更新状态，
# 因此第一个仍为"未执行"的步骤就是中断所在的步骤。
on_exit() {
  local status=$?
  local entry name var failed_step=""

  (( status != 0 )) || return 0
  [[ "${STEPS_STARTED:-0}" == "1" ]] || return 0

  for entry in "系统更新:STEP_SYSTEM_UPDATE" "时间同步:STEP_TIME_SYNC" \
    "SWAP:STEP_SWAP" "SSH:STEP_SSH" "Docker:STEP_DOCKER"; do
    name="${entry%%:*}"
    var="${entry#*:}"
    if [[ "${!var}" == "未执行" ]]; then
      printf -v "${var}" '%s' "失败"
      failed_step="${name}"
      break
    fi
  done

  echo >&2
  err "初始化在 [${failed_step:-未知}] 步骤中断（退出码 ${status}），后续步骤未执行。"
  print_summary err "初始化未完成" >&2
}

# 整个流程放在 main 中：通过 curl | bash 运行时，bash 会先读完整个函数再执行，
# 下载中断时不会执行被截断的脚本。
main() {
  STEPS_STARTED=0
  STEP_SYSTEM_UPDATE="未执行"
  STEP_TIME_SYNC="未执行"
  STEP_SWAP="未执行"
  STEP_SSH="未执行"
  STEP_DOCKER="未执行"
  trap on_exit EXIT

  # ---------------------------------------------------------------------------
  # 预检查
  # ---------------------------------------------------------------------------
  parse_args "$@"

  [[ -f /etc/os-release ]] || die "找不到 /etc/os-release，无法识别当前发行版。"
  # shellcheck source=/dev/null
  . /etc/os-release

  if [[ "${ID:-}" != "debian" && "${ID:-}" != "ubuntu" ]]; then
    die "不支持当前发行版（ID=${ID:-unknown}），本脚本仅支持 Debian 和 Ubuntu。"
  fi

  if [[ "${EUID}" -ne 0 ]]; then
    if [[ "${DRY_RUN}" == "1" ]]; then
      warn "当前不是 root，DRY_RUN 预览中部分检测（如 sshd 有效配置、/etc/shadow）可能不完整。"
    else
      die "请以 root 身份运行此脚本，例如：sudo bash $0"
    fi
  fi

  STEPS_STARTED=1

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

    TIME_DAEMON=$(installed_time_daemon || true)

    if [[ -n "${TIME_DAEMON}" ]]; then
      # systemd-timesyncd 与 chrony/ntpsec 等互相冲突，安装它会卸载现有对时服务
      # （云镜像常用 chrony 并配置了云厂商的时间源），因此保留现有服务。
      ok "[时间同步] 检测到已安装 ${TIME_DAEMON}，保留现有对时服务，不安装 systemd-timesyncd。"
    else
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
      fi
    fi

    if [[ "${DRY_RUN}" != "1" ]]; then
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
    SWAP_RESULT="已执行"
    CURRENT_SWAP=$(swapon --show=NAME,SIZE --noheadings 2>/dev/null || true)
    SWAP_CONTAINER=$(container_type || true)

    if [[ -n "${CURRENT_SWAP}" ]]; then
      ok "[SWAP] 检测到系统已存在 SWAP，跳过创建。"
      if [[ "${DRY_RUN}" != "1" ]]; then
        swapon --show
        free -m
      fi
    elif [[ -n "${SWAP_CONTAINER}" ]]; then
      warn "[SWAP] 检测到容器环境（${SWAP_CONTAINER}），容器内通常无法启用 SWAP，已跳过。"
      SWAP_RESULT="已跳过（容器环境）"
    else
      MEM_MB=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
      SWAP_SIZE=$(recommended_swap_size "${MEM_MB}")
      SWAP_SIZE_MB=$(swap_size_to_mb "${SWAP_SIZE}")

      info "[SWAP] 未检测到 SWAP，当前物理内存约 ${MEM_MB} MB。"

      if [[ -e /swapfile ]]; then
        warn "[SWAP] 检测到 /swapfile 已存在，将仅在确认其为有效 SWAP 文件后启用。"
        EXISTING_SWAP_TYPE=$(blkid -p -s TYPE -o value /swapfile 2>/dev/null || true)

        if [[ ! -f /swapfile || -L /swapfile ]]; then
          warn "[SWAP] /swapfile 不是普通文件或是符号链接，已拒绝操作。"
          SWAP_RESULT="失败"
        elif [[ "${EXISTING_SWAP_TYPE}" != "swap" ]]; then
          warn "[SWAP] 现有 /swapfile 没有有效的 SWAP 签名，为避免损坏数据未做改动。"
          SWAP_RESULT="失败"
        elif [[ "${DRY_RUN}" == "1" ]]; then
          echo "${YELLOW}[DRY_RUN]${RESET} chmod 600 /swapfile"
          echo "${YELLOW}[DRY_RUN]${RESET} swapon /swapfile"
          echo "${YELLOW}[DRY_RUN]${RESET} add '/swapfile none swap sw 0 0' to /etc/fstab if missing"
        elif chmod 600 /swapfile && swapon /swapfile; then
          add_swap_fstab_entry
          ok "[SWAP] 已启用现有 /swapfile。"
          swapon --show
          free -m
        else
          warn "[SWAP] 启用现有 /swapfile 失败。"
          SWAP_RESULT="失败"
        fi
      else
        SWAP_AVAIL_MB=$(df -Pm / | awk 'NR == 2 { print $4 }')

        if (( SWAP_AVAIL_MB < SWAP_SIZE_MB + SWAP_MIN_FREE_MB )); then
          warn "[SWAP] 根分区可用空间约 ${SWAP_AVAIL_MB} MB，创建 ${SWAP_SIZE} SWAP 后剩余将不足 ${SWAP_MIN_FREE_MB} MB，已跳过。"
          SWAP_RESULT="已跳过（磁盘空间不足）"
        elif [[ "${DRY_RUN}" == "1" ]]; then
          info "[SWAP] 将按通用推荐创建 ${SWAP_SIZE} 的 /swapfile ..."
          echo "${YELLOW}[DRY_RUN]${RESET} create /swapfile (chmod 600; chattr +C on btrfs)"
          echo "${YELLOW}[DRY_RUN]${RESET} fallocate -l ${SWAP_SIZE} /swapfile  # 失败时改用 dd"
          echo "${YELLOW}[DRY_RUN]${RESET} mkswap /swapfile && swapon /swapfile"
          echo "${YELLOW}[DRY_RUN]${RESET} add '/swapfile none swap sw 0 0' to /etc/fstab if missing"
        else
          info "[SWAP] 将按通用推荐创建 ${SWAP_SIZE} 的 /swapfile ..."
          if create_swapfile "${SWAP_SIZE}" "${SWAP_SIZE_MB}"; then
            add_swap_fstab_entry
            ok "[SWAP] 已创建并启用 ${SWAP_SIZE} 的 /swapfile。"
            swapon --show
            free -m
          else
            rm -f -- /swapfile
            warn "[SWAP] 创建或启用 /swapfile 失败，已删除未完成的文件，继续执行后续步骤。"
            SWAP_RESULT="失败"
          fi
        fi
      fi
    fi

    echo
    if [[ "${SWAP_RESULT}" == "已执行" ]]; then
      ok "[SWAP] 执行完成。"
    else
      warn "[SWAP] 结束：${SWAP_RESULT}。"
    fi
    STEP_SWAP="${SWAP_RESULT}"
  else
    warn "[SWAP] 已跳过。"
    STEP_SWAP="已跳过"
  fi

  # ---------------------------------------------------------------------------
  # 功能：SSH 公钥登录配置
  # ---------------------------------------------------------------------------
  if should_run_step "SSH"; then
    info "[SSH] 即将开始。"

    if ! is_interactive; then
      warn "[SSH] 当前不是交互终端，已跳过 SSH 配置。"
    else
      echo
      SSH_PUBLIC_KEY=$(prompt_input "[SSH] 请输入要写入的 SSH 公钥（直接回车跳过）：")

      if [[ -z "${SSH_PUBLIC_KEY}" ]]; then
        info "[SSH] 未输入公钥，已跳过 SSH 配置。"
      else
        validate_ssh_public_key "${SSH_PUBLIC_KEY}"
        SSH_PORT=$(prompt_input "[SSH] 请输入 SSH 端口（直接回车保持当前配置不变）：")

        if [[ -n "${SSH_PORT}" ]]; then
          [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || die "[SSH] SSH 端口必须是数字。"
          (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die "[SSH] SSH 端口必须在 1-65535 之间。"
        fi

        info "[SSH] 正在配置 root 用户的 SSH 公钥登录..."
        install_authorized_key root "${SSH_PUBLIC_KEY}" \
          || die "[SSH] 为 root 写入公钥失败。"

        if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] \
          && getent passwd "${SUDO_USER}" &>/dev/null; then
          SSH_SUDO_USER_KEY=$(prompt_input "[SSH] 检测到通过 sudo 运行（用户 ${SUDO_USER}），是否同时为该用户写入此公钥？[Y/n] ")
          if [[ ! "${SSH_SUDO_USER_KEY}" =~ ^[Nn]$ ]]; then
            install_authorized_key "${SUDO_USER}" "${SSH_PUBLIC_KEY}" \
              || warn "[SSH] 未能为 ${SUDO_USER} 写入公钥，已跳过。"
          fi
        fi

        echo
        warn "[SSH] 接下来的配置对所有用户生效：关闭密码登录，仅允许公钥登录。"
        mapfile -t SSH_AT_RISK_USERS < <(password_only_users)
        if (( ${#SSH_AT_RISK_USERS[@]} > 0 )); then
          warn "[SSH] 以下用户设置了密码但没有 ~/.ssh/authorized_keys，应用后将无法通过 SSH 登录："
          warn "[SSH]   ${SSH_AT_RISK_USERS[*]}"
        fi

        SSH_ROOT_LOGIN=$(choose_root_login_policy)
        if [[ "${SSH_ROOT_LOGIN}" != "prohibit-password" ]]; then
          warn "[SSH] 当前配置为 PermitRootLogin ${SSH_ROOT_LOGIN}，将保持不变，root 仍无法通过 SSH 公钥登录。"
          warn "[SSH] 请确认已有其他用户可以通过公钥登录。"
        fi

        SSH_CONFIRM=$(prompt_input "[SSH] 已写入公钥，准备关闭密码登录并应用 SSH 配置，是否继续？[y/N] ")
        if [[ ! "${SSH_CONFIRM}" =~ ^[Yy]$ ]]; then
          warn "[SSH] 已取消修改 sshd_config，仅保留公钥写入。"
        else
          info "[SSH] 正在更新 sshd_config ..."

          if [[ "${DRY_RUN}" == "1" ]]; then
            echo "${YELLOW}[DRY_RUN]${RESET} cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.<时间戳>"
            if [[ -n "${SSH_PORT}" ]]; then
              echo "${YELLOW}[DRY_RUN]${RESET} prepend managed Port ${SSH_PORT} before Include/Match directives"
              echo "${YELLOW}[DRY_RUN]${RESET} comment out other Port lines in /etc/ssh/sshd_config"
            else
              echo "${YELLOW}[DRY_RUN]${RESET} keep current Port setting"
            fi
            echo "${YELLOW}[DRY_RUN]${RESET} prepend managed SSH authentication settings (PermitRootLogin ${SSH_ROOT_LOGIN}) before Include/Match directives"
            echo "${YELLOW}[DRY_RUN]${RESET} sshd -t and verify effective root settings with sshd -T"
            echo "${YELLOW}[DRY_RUN]${RESET} systemctl daemon-reload && systemctl restart ssh.socket  # 若 ssh.socket 处于活动状态"
            echo "${YELLOW}[DRY_RUN]${RESET} systemctl restart ssh  # 否则，fallback: sshd"
          else
            [[ -f /etc/ssh/sshd_config ]] \
              || die "[SSH] 未找到 /etc/ssh/sshd_config。"
            command -v sshd &>/dev/null \
              || die "[SSH] 未找到 sshd，无法安全应用配置。"

            SSHD_BACKUP="/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
            cp -a /etc/ssh/sshd_config "${SSHD_BACKUP}"
            info "[SSH] 已备份原配置到 ${SSHD_BACKUP}"
            write_sshd_managed_config /etc/ssh/sshd_config "${SSH_PORT}" "${SSH_ROOT_LOGIN}"

            if ! sshd -t; then
              cp -a "${SSHD_BACKUP}" /etc/ssh/sshd_config
              die "[SSH] sshd_config 语法校验失败，已自动恢复备份。"
            fi

            if ! verify_sshd_effective_config "${SSH_ROOT_LOGIN}"; then
              cp -a "${SSHD_BACKUP}" /etc/ssh/sshd_config
              die "[SSH] root 的 SSH 有效配置未达到预期，已自动恢复备份。"
            fi

            restart_ssh_service
            if [[ -n "${SSH_PORT}" ]]; then
              warn_extra_ssh_ports "${SSH_PORT}"
              check_ssh_port_listening "${SSH_PORT}"
            fi

            ok "[SSH] SSH 配置已更新。"
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
    info "[Docker] 正在下载并校验固定版本的安装脚本..."
    DOCKER_INSTALL_COMMIT="5db2723069df6fc576c73a05975d95f73e7acaca"
    DOCKER_INSTALL_SHA256="1ae0b4898ef1b6cf36a28a477e9600d2e1affebcb2c7bd312b1a5fb8e0619cd2"
    DOCKER_INSTALL_URL="https://raw.githubusercontent.com/Unarmored7/install-docker/${DOCKER_INSTALL_COMMIT}/install-docker.sh"

    if [[ "${DRY_RUN}" == "1" ]]; then
      echo "${YELLOW}[DRY_RUN]${RESET} ensure curl/wget, install curl if both are missing"
      echo "${YELLOW}[DRY_RUN]${RESET} download ${DOCKER_INSTALL_URL} to a temporary file"
      echo "${YELLOW}[DRY_RUN]${RESET} verify SHA-256 ${DOCKER_INSTALL_SHA256}"
      echo "${YELLOW}[DRY_RUN]${RESET} execute the verified file, then remove it"
    else
      ensure_download_tool "Docker"
      run_verified_script "Docker" "${DOCKER_INSTALL_URL}" "${DOCKER_INSTALL_SHA256}"
    fi

    echo
    ok "[Docker] 执行完成。"
    STEP_DOCKER="已执行"
  else
    warn "[Docker] 已跳过。"
    STEP_DOCKER="已跳过"
  fi

  print_summary ok "初始化脚本执行结束"
}

main "$@"
