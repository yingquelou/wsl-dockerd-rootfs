下面给出完整的双系统方案。目录结构如下：

```
wsl-docker-rootfs/
├── Dockerfile.ubuntu      # 沿用上一版，稍作整理
├── Dockerfile.alpine      # 新增，Alpine + OpenRC
├── compose.yaml           # 一份配置同时构建两份 rootfs
└── scripts/
    └── export-rootfs.sh   # 一键导出两份 tar
```

所有可变项都集中在 `compose.yaml` 的 `build.args`，Dockerfile 内部只用 `ARG`，不硬编码任何源或路径。

---

## 📄 Dockerfile.ubuntu

和上一版基本一致，仅将文件顶部注释里的构建命令去掉（改由 compose 统一构建），其余不变。

```dockerfile
# ============================================================
# Ubuntu 24.04 + systemd + Docker Engine
# 由 compose.yaml 统一构建，所有可配置项通过 build.args 传入
# ============================================================

FROM ubuntu:24.04

# ============================================================
# 可配置参数
# ============================================================

ARG TZ=Asia/Shanghai
ARG LANG_CODE=zh_CN.UTF-8
ARG EXTRA_LANG=en_US.UTF-8

ARG HTTP_PROXY=""
ARG HTTPS_PROXY=""
ARG NO_PROXY="localhost,127.0.0.1,::1"

ARG UBUNTU_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/ubuntu
ARG UBUNTU_SECURITY_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/ubuntu
ARG DOCKER_CE_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/ubuntu

ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000
ARG USER_PASSWORD=dev
ARG ROOT_PASSWORD=wsl

ARG DOCKER_TCP_HOST=127.0.0.1
ARG DOCKER_TCP_PORT=2375
ARG DOCKER_REGISTRY_MIRRORS="https://docker.1panel.live,https://hub.rat.dev"
ARG DOCKER_LOG_MAX_SIZE=10m
ARG DOCKER_LOG_MAX_FILE=3

ARG WSL_DEFAULT_USER=dev
ARG WSL_AUTOMOUNT_ENABLED=true
ARG WSL_INTEROP_ENABLED=true

# ============================================================
# 构建逻辑
# ============================================================

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=${TZ} \
    LANG=${LANG_CODE} \
    HTTP_PROXY=${HTTP_PROXY} \
    HTTPS_PROXY=${HTTPS_PROXY} \
    NO_PROXY=${NO_PROXY} \
    http_proxy=${HTTP_PROXY} \
    https_proxy=${HTTPS_PROXY} \
    no_proxy=${NO_PROXY}

# ---------- 替换 APT 源 ----------
RUN set -eux; \
    if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then \
        sed -i "s|http://archive.ubuntu.com/ubuntu|${UBUNTU_MIRROR}|g" /etc/apt/sources.list.d/ubuntu.sources; \
        sed -i "s|http://security.ubuntu.com/ubuntu|${UBUNTU_SECURITY_MIRROR}|g" /etc/apt/sources.list.d/ubuntu.sources; \
        sed -i "s|https://archive.ubuntu.com/ubuntu|${UBUNTU_MIRROR}|g" /etc/apt/sources.list.d/ubuntu.sources; \
        sed -i "s|https://security.ubuntu.com/ubuntu|${UBUNTU_SECURITY_MIRROR}|g" /etc/apt/sources.list.d/ubuntu.sources; \
    fi; \
    if [ -f /etc/apt/sources.list ]; then \
        sed -i "s|http://archive.ubuntu.com/ubuntu|${UBUNTU_MIRROR}|g" /etc/apt/sources.list; \
        sed -i "s|http://security.ubuntu.com/ubuntu|${UBUNTU_SECURITY_MIRROR}|g" /etc/apt/sources.list; \
    fi

# ---------- 基础系统 ----------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg lsb-release apt-transport-https \
        software-properties-common systemd systemd-sysv sudo \
        vim nano wget git net-tools iproute2 iputils-ping dnsutils \
        bash-completion locales tzdata \
    && ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime \
    && echo ${TZ} > /etc/timezone \
    && locale-gen ${LANG_CODE} ${EXTRA_LANG} \
    && update-locale LANG=${LANG_CODE} \
    && rm -rf /var/lib/apt/lists/*

# ---------- Docker CE ----------
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL ${DOCKER_CE_MIRROR}/gpg \
       | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
       ${DOCKER_CE_MIRROR} \
       $(lsb_release -cs) stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# ---------- daemon.json ----------
RUN mkdir -p /etc/docker \
    && MIRRORS_JSON=$(echo "${DOCKER_REGISTRY_MIRRORS}" | awk -F',' '{ \
         printf "["; \
         for (i=1; i<=NF; i++) { \
           gsub(/^[ \t]+|[ \t]+$/, "", $i); \
           printf "\"%s\"", $i; \
           if (i<NF) printf ","; \
         } \
         printf "]"; \
       }') \
    && cat > /etc/docker/daemon.json <<EOF
{
  "hosts": [
    "unix:///var/run/docker.sock",
    "tcp://${DOCKER_TCP_HOST}:${DOCKER_TCP_PORT}"
  ],
  "tls": false,
  "registry-mirrors": ${MIRRORS_JSON},
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "${DOCKER_LOG_MAX_SIZE}",
    "max-file": "${DOCKER_LOG_MAX_FILE}"
  }
}
EOF

# ---------- wsl.conf ----------
RUN cat > /etc/wsl.conf <<EOF
[boot]
systemd=true

[user]
default=${WSL_DEFAULT_USER}

[automount]
enabled=${WSL_AUTOMOUNT_ENABLED}
mountFsTab=true
root=/mnt/
options=metadata,uid=${USER_UID},gid=${USER_GID},umask=0022,fmask=111,case=off

[network]
generateResolvConf=true

[interop]
enabled=${WSL_INTEROP_ENABLED}
appendWindowsPath=true
EOF

# ---------- 默认用户 ----------
RUN groupadd --gid ${USER_GID} ${USERNAME} \
    && useradd --uid ${USER_UID} --gid ${USER_GID} -m -s /bin/bash ${USERNAME} \
    && echo "${USERNAME}:${USER_PASSWORD}" | chpasswd \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME} \
    && usermod -aG docker ${USERNAME}

RUN echo "root:${ROOT_PASSWORD}" | chpasswd \
    && chsh -s /bin/bash root

RUN systemctl enable docker.service containerd.service

# ---------- 清空代理，避免污染 ----------
ENV HTTP_PROXY= HTTPS_PROXY= NO_PROXY= \
    http_proxy= https_proxy= no_proxy=

CMD ["/bin/bash"]
```

---

## 📄 Dockerfile.alpine

Alpine 用 OpenRC 替代 systemd，其余思路与 Ubuntu 版一致。

```dockerfile
# ============================================================
# Alpine + OpenRC + Docker Engine
# 轻量，导入 WSL 后约 100MB 左右
# ============================================================

FROM alpine:3.20

# ============================================================
# 可配置参数
# ============================================================

ARG TZ=Asia/Shanghai
ARG ALPINE_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/alpine
ARG ALPINE_VERSION=v3.20

ARG HTTP_PROXY=""
ARG HTTPS_PROXY=""
ARG NO_PROXY="localhost,127.0.0.1,::1"

ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000
ARG USER_PASSWORD=dev
ARG ROOT_PASSWORD=wsl

ARG DOCKER_TCP_HOST=127.0.0.1
ARG DOCKER_TCP_PORT=2375
ARG DOCKER_REGISTRY_MIRRORS="https://docker.1panel.live,https://hub.rat.dev"
ARG DOCKER_LOG_MAX_SIZE=10m
ARG DOCKER_LOG_MAX_FILE=3

ARG WSL_DEFAULT_USER=dev
ARG WSL_AUTOMOUNT_ENABLED=true
ARG WSL_INTEROP_ENABLED=true

# ============================================================
# 构建逻辑
# ============================================================

ENV TZ=${TZ} \
    HTTP_PROXY=${HTTP_PROXY} \
    HTTPS_PROXY=${HTTPS_PROXY} \
    NO_PROXY=${NO_PROXY} \
    http_proxy=${HTTP_PROXY} \
    https_proxy=${HTTPS_PROXY} \
    no_proxy=${NO_PROXY}

# ---------- 替换 APK 源（直接重写，避免解析原文件） ----------
RUN printf '%s/%s/main\n%s/%s/community\n' \
        "${ALPINE_MIRROR}" "${ALPINE_VERSION}" \
        "${ALPINE_MIRROR}" "${ALPINE_VERSION}" \
        > /etc/apk/repositories \
    && cat /etc/apk/repositories

# ---------- 基础系统 ----------
RUN apk update && apk add --no-cache \
        bash bash-completion \
        curl ca-certificates openssl \
        gnupg \
        sudo \
        tzdata \
        vim nano wget git \
        net-tools iproute2 bind-tools \
        procps \
        util-linux \
        openrc \
        rsyslog \
    && cp /usr/share/zoneinfo/${TZ} /etc/localtime \
    && echo ${TZ} > /etc/timezone

# ---------- Docker Engine + CLI + Compose ----------
RUN apk add --no-cache \
        docker \
        docker-cli \
        docker-cli-buildx \
        docker-cli-compose \
        containerd \
        runc \
        iptables \
        ip6tables

# ---------- daemon.json ----------
RUN mkdir -p /etc/docker \
    && MIRRORS_JSON=$(echo "${DOCKER_REGISTRY_MIRRORS}" | awk -F',' '{ \
         printf "["; \
         for (i=1; i<=NF; i++) { \
           gsub(/^[ \t]+|[ \t]+$/, "", $i); \
           printf "\"%s\"", $i; \
           if (i<NF) printf ","; \
         } \
         printf "]"; \
       }') \
    && cat > /etc/docker/daemon.json <<EOF
{
  "hosts": [
    "unix:///var/run/docker.sock",
    "tcp://${DOCKER_TCP_HOST}:${DOCKER_TCP_PORT}"
  ],
  "tls": false,
  "registry-mirrors": ${MIRRORS_JSON},
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "${DOCKER_LOG_MAX_SIZE}",
    "max-file": "${DOCKER_LOG_MAX_FILE}"
  }
}
EOF

# ---------- wsl.conf ----------
# Alpine 无 systemd，用 OpenRC；通过 boot.command 拉起默认 runlevel
RUN cat > /etc/wsl.conf <<EOF
[boot]
command = /sbin/openrc default

[user]
default=${WSL_DEFAULT_USER}

[automount]
enabled=${WSL_AUTOMOUNT_ENABLED}
mountFsTab=true
root=/mnt/
options=metadata,uid=${USER_UID},gid=${USER_GID},umask=0022,fmask=111,case=off

[network]
generateResolvConf=true

[interop]
enabled=${WSL_INTEROP_ENABLED}
appendWindowsPath=true
EOF

# ---------- 默认用户 ----------
RUN addgroup -g ${USER_GID} ${USERNAME} \
    && adduser -u ${USER_UID} -G ${USERNAME} -s /bin/bash -D ${USERNAME} \
    && echo "${USERNAME}:${USER_PASSWORD}" | chpasswd \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME} \
    && addgroup ${USERNAME} docker

RUN echo "root:${ROOT_PASSWORD}" | chpasswd

# ---------- 启用 OpenRC 服务 ----------
# rc-update 在构建容器内可能因 /run 未挂载而报错，用 ln 兜底
RUN mkdir -p /etc/runlevels/default /etc/runlevels/boot /etc/runlevels/sysinit \
    && (rc-update add docker default || \
        ln -sf /etc/init.d/docker /etc/runlevels/default/docker) \
    && (rc-update add containerd default || \
        ln -sf /etc/init.d/containerd /etc/runlevels/default/containerd) \
    && ln -sf /etc/init.d/networking /etc/runlevels/boot/networking 2>/dev/null || true

# ---------- 清空代理 ----------
ENV HTTP_PROXY= HTTPS_PROXY= NO_PROXY= \
    http_proxy= https_proxy= no_proxy=

CMD ["/bin/sh"]
```

---

## 📄 compose.yaml

一份文件，两套 rootfs，所有配置集中管理。

```yaml
name: wsl-docker-rootfs

x-common-args: &common-args
  TZ: Asia/Shanghai
  USERNAME: dev
  USER_UID: "1000"
  USER_GID: "1000"
  USER_PASSWORD: dev
  ROOT_PASSWORD: wsl
  DOCKER_TCP_HOST: 127.0.0.1
  DOCKER_TCP_PORT: "2375"
  DOCKER_REGISTRY_MIRRORS: "https://docker.1panel.live,https://hub.rat.dev"
  DOCKER_LOG_MAX_SIZE: 10m
  DOCKER_LOG_MAX_FILE: "3"
  WSL_DEFAULT_USER: dev
  WSL_AUTOMOUNT_ENABLED: "true"
  WSL_INTEROP_ENABLED: "true"

services:

  ubuntu-rootfs:
    build:
      context: .
      dockerfile: Dockerfile.ubuntu
      args:
        <<: *common-args
        # 系统相关
        LANG_CODE: zh_CN.UTF-8
        EXTRA_LANG: en_US.UTF-8
        # APT / Docker CE 源
        UBUNTU_MIRROR: https://mirrors.tuna.tsinghua.edu.cn/ubuntu
        UBUNTU_SECURITY_MIRROR: https://mirrors.tuna.tsinghua.edu.cn/ubuntu
        DOCKER_CE_MIRROR: https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/ubuntu
        # 构建时代理（按需取消注释）
        # HTTP_PROXY: http://192.168.1.100:7890
        # HTTPS_PROXY: http://192.168.1.100:7890
    image: wsl-docker-rootfs:ubuntu
    container_name: wsl-rootfs-ubuntu
    command: ["/bin/bash"]

  alpine-rootfs:
    build:
      context: .
      dockerfile: Dockerfile.alpine
      args:
        <<: *common-args
        # Alpine 源
        ALPINE_MIRROR: https://mirrors.tuna.tsinghua.edu.cn/alpine
        ALPINE_VERSION: v3.20
        # 构建时代理（按需取消注释）
        # HTTP_PROXY: http://192.168.1.100:7890
        # HTTPS_PROXY: http://192.168.1.100:7890
    image: wsl-docker-rootfs:alpine
    container_name: wsl-rootfs-alpine
    command: ["/bin/sh"]
```

YAML 锚点 `&common-args` / `<<: *common-args` 让两份构建共享同一批通用参数，只需在 `x-common-args` 处改一次。

---

## 📄 scripts/export-rootfs.sh

一键构建、创建容器、导出 tar、清理。

```bash
#!/usr/bin/env bash
# 用法: ./scripts/export-rootfs.sh [输出目录]
set -euo pipefail

OUT_DIR="${1:-./dist}"
mkdir -p "${OUT_DIR}"

cd "$(dirname "$0")/.."

echo "==> 构建两个镜像"
docker compose build

echo "==> 创建容器"
docker compose create

echo "==> 导出 rootfs"
for name in wsl-rootfs-ubuntu wsl-rootfs-alpine; do
  short="${name#wsl-rootfs-}"
  echo "    - ${name} -> ${OUT_DIR}/rootfs-${short}.tar"
  docker export "${name}" -o "${OUT_DIR}/rootfs-${short}.tar"
  gzip -9 "${OUT_DIR}/rootfs-${short}.tar"
done

echo "==> 清理容器"
docker compose rm -f

echo
echo "完成。产物:"
ls -lh "${OUT_DIR}"
```

执行：

```bash
chmod +x scripts/export-rootfs.sh
./scripts/export-rootfs.sh
```

产物：

```
dist/
├── rootfs-ubuntu.tar.gz
└── rootfs-alpine.tar.gz
```

---

## 🐧 导入 WSL

在管理员 PowerShell 中：

```powershell
# Ubuntu 版
mkdir C:\WSL\Ubuntu-Docker
wsl --import Ubuntu-Docker C:\WSL\Ubuntu-Docker C:\path\to\rootfs-ubuntu.tar.gz --version 2

# Alpine 版
mkdir C:\WSL\Alpine-Docker
wsl --import Alpine-Docker C:\WSL\Alpine-Docker C:\path\to\rootfs-alpine.tar.gz --version 2
```

Windows 侧 `.wslconfig` 建议启用镜像网络：

```ini
[wsl2]
networkingMode=mirrored
```

---

## ✅ 启动与验证

### Ubuntu 版

```bash
wsl -d Ubuntu-Docker
# 内部：
ps -p 1 -o comm=          # systemd
systemctl status docker
docker version
```

### Alpine 版

```bash
wsl -d Alpine-Docker
# 内部：
ps -p 1 -o comm=          # init（WSL 的 init）
rc-service docker status
docker version
```

Alpine 版没有 systemd，PID 1 是 WSL 的 `/init`，OpenRC 由 `wsl.conf` 的 `boot.command` 拉起，Docker 服务由 OpenRC 管理。

---

## 🔍 两版差异速查

| 维度 | Ubuntu 版 | Alpine 版 |
|---|---|---|
| 基础镜像 | `ubuntu:24.04` | `alpine:3.20` |
| init 系统 | systemd | OpenRC |
| 服务管理 | `systemctl` | `rc-service` / `rc-update` |
| 包管理 | apt | apk |
| Docker 来源 | Docker 官方 CE 源 | Alpine community 仓库 |
| rootfs 体积 | ~300MB+ | ~100MB 左右 |
| 默认 shell | bash | bash（已装） |
| WSL 启动命令 | `systemd=true` | `boot.command = /sbin/openrc default` |

---

## 💡 注意事项

- **Alpine 的 docker 版本** 由 Alpine 仓库决定，通常是稳定版，但可能比 Docker 官方最新版略旧。如果一定要用最新 Docker CE，可以再加一个 Alpine 的 Docker CE 源（`https://download.docker.com/linux/alpine/v3.20`），不过目前 community 仓库已足够。
- **OpenRC 在 WSL 中的行为**：`boot.command` 会在 WSL 启动时执行一次，`openrc default` 完成后会退出，服务作为后台进程继续运行。这是 WSL + Alpine 的常见做法。
- **镜像加速地址**：默认给的 `docker.1panel.live` 和 `hub.rat.dev` 可能随时失效，建议替换为自己可用的地址，或直接改成公司内网 registry mirror。
- **两份 rootfs 互不干扰**，可同时导入 WSL，各自独立运行 Docker 守护进程，使用不同的 TCP 端口即可（若需要同时跑两个，把其中一个的 `DOCKER_TCP_PORT` 改成 2376）。
- **代理只在构建阶段生效**，导入后 WSL 环境干净，不会继承 `HTTP_PROXY`。