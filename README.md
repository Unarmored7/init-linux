# init-linux.sh

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell: Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash&logoColor=white)](init-linux.sh)
[![Platform](https://img.shields.io/badge/Platform-Debian%20|%20Ubuntu-A81D33?logo=debian&logoColor=white)](#运行要求)

一个用于在 **Debian / Ubuntu** 新装系统上执行初始化配置的一键脚本。

脚本按模块化方式执行常用初始化任务，适合新 VPS 或新系统上线后的首轮配置。每个功能默认执行，支持交互式跳过，并在脚本末尾输出本次执行总结。

当前已包含以下功能：

| 功能 | 说明 |
|------|------|
| **系统更新** | 执行 `apt update` 和 `apt upgrade -y` |
| **时间同步** | 设置时区为 `Asia/Shanghai`，安装并启用 `systemd-timesyncd` |
| **SWAP** | 检查系统是否已有 SWAP，没有则自动按推荐大小创建 `/swapfile` |
| **SSH** | 交互式写入 SSH 公钥，并可选关闭密码登录 |
| **Docker** | 直接调用 `install-docker` 脚本安装 Docker |

---

## 快速开始

```bash
wget -qO- https://raw.githubusercontent.com/Unarmored7/init-linux/main/init-linux.sh | bash
```

<details>
<summary>其他运行方式</summary>

使用 `curl`：

```bash
curl -fsSL https://raw.githubusercontent.com/Unarmored7/init-linux/main/init-linux.sh | bash
```

下载到本地后执行：

```bash
bash init-linux.sh
```

> **Note:** 非 root 用户执行时，请使用 `sudo bash`。

</details>

---

## 运行要求

| 项目 | 要求 |
|------|------|
| **发行版** | Debian / Ubuntu |
| **权限** | root |
| **网络** | 需要能访问 Debian / Ubuntu 软件源，以及 GitHub Raw |

---

## 交互方式

脚本中的每个功能都会先给出确认提示：

```text
[功能名] 默认执行，输入 n 跳过，按回车继续：[Y/n]
```

规则如下：

| 输入 | 行为 |
|------|------|
| 直接回车 | 执行该项 |
| `y` / `Y` | 执行该项 |
| `n` / `N` | 跳过该项 |

执行完成后，脚本末尾会输出本次初始化的总结状态。

---

## 当前流程

### 1. 系统更新

执行：

```bash
apt update
apt upgrade -y
```

### 2. 时间同步

执行内容包括：

- 设置时区为 `Asia/Shanghai`
- 安装 `systemd-timesyncd`
- 启用自动对时
- 输出 `timedatectl` 和 `date` 结果

### 3. SWAP

执行逻辑：

- 检查当前系统是否已有 SWAP
- 如果已有，则跳过创建并输出当前状态
- 如果没有，则根据物理内存自动推荐 SWAP 大小
- 自动创建 `/swapfile`
- 写入 `/etc/fstab` 实现开机自动挂载

默认采用通用推荐策略：

| 物理内存 | 推荐 SWAP |
|----------|-----------|
| `<= 512M` | `1G` |
| `<= 1G` | `2G` |
| `<= 6G` | `2G` |
| `<= 16G` | `4G` |
| `<= 128G` | `8G` |
| `> 128G` | `16G` |

### 4. SSH

执行逻辑：

- 交互输入 SSH 公钥
- 可选输入新 SSH 端口，直接回车则保持当前端口不变
- 写入 `/root/.ssh/authorized_keys`
- 可选关闭密码登录并修改 `sshd_config`
- 修改前自动备份配置
- 尝试校验配置并重启 SSH 服务

### 5. Docker

直接调用以下远程脚本：

```bash
wget -qO- https://raw.githubusercontent.com/Unarmored7/install-docker/main/install-docker.sh | bash
```

---

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `DRY_RUN` | `0` | 设为 `1` 时仅打印将要执行的命令，不真正执行 |

```bash
DRY_RUN=1 bash init-linux.sh
```

---

## 输出总结

脚本结束时会输出每个功能的执行结果，例如：

```text
系统更新 : 已执行
时间同步 : 已跳过
SWAP     : 已执行
SSH      : 已执行
Docker   : 已跳过
```

便于快速确认本次初始化做了哪些操作。

---

## 许可证

[MIT](LICENSE)
