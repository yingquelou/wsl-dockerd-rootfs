#!/bin/sh
# ============================================================
# wsl-docker-host-access.sh
#
# 确保 Windows 能访问 WSL2 内 Docker 发布的端口 (mirrored 网络)
#
# 背景:
#   WSL2 networkingMode=mirrored 下, Windows localhost 流量经
#   loopback0 接口投递到 WSL。Docker 默认用 iptables DNAT 把
#   发布端口转发到容器, 但经 loopback0 进来的 127.0.0.0/8 包
#   被 DNAT 后回程路由异常, 导致 Windows 侧连接超时。
#
#   本脚本在 nat PREROUTING 顶部插入 RETURN 规则, 跳过 Docker
#   DNAT, 改由 docker-proxy (userland-proxy) 接管, 回程正常。
#
# IPv6 限制 (无法在 rootfs 层修复):
#   Windows localhost 优先解析为 ::1。Linux 内核 ipv6_rcv() 对
#   非环回接口 (loopback0 无 IFF_LOOPBACK 标志) 上的 ::1 包
#   硬编码丢弃, 在 netfilter 之前发生, 无法用 sysctl/iptables
#   绕过。Windows 侧需用 127.0.0.1 或依赖 Happy Eyeballs 回退。
#
# 用法:
#   wsl-docker-host-access.sh          # 应用一次
#   wsl-docker-host-access.sh --watch  # 持续重应用 (Docker 重建规则时保持)
# ============================================================

set -eu

INTERVAL="${WSL_DOCKER_HOST_ACCESS_INTERVAL:-5}"

# mirrored 模式下存在 loopback0 接口
is_mirrored() {
        [ -d /sys/class/net/loopback0 ]
}

rule_exists() {
        cmd="$1"; table="$2"; chain="$3"; shift 3
        "$cmd" -t "$table" -C "$chain" "$@" >/dev/null 2>&1
}

ensure_rule() {
        cmd="$1"; table="$2"; chain="$3"; shift 3
        "$cmd" -t "$table" -L "$chain" >/dev/null 2>&1 || return 0
        rule_exists "$cmd" "$table" "$chain" "$@" && return 0
        "$cmd" -t "$table" -I "$chain" "$@"
}

apply() {
        # Docker 容器互通依赖 IP 转发
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

        is_mirrored || return 0

        # IPv4: 跳过 loopback0 → 127.0.0.0/8 的 DNAT, 交给 docker-proxy
        ensure_rule iptables  nat PREROUTING -i loopback0 -d 127.0.0.0/8 -j RETURN
        ensure_rule iptables  nat DOCKER     -i loopback0 -d 127.0.0.0/8 -j RETURN

        # IPv6: ::1 在非环回接口被内核丢弃 (netfilter 前), 以下规则
        # 实际不会命中, 保留以备未来内核支持后自动生效
        ensure_rule ip6tables nat PREROUTING -i loopback0 -d ::1/128 -j RETURN
        ensure_rule ip6tables nat DOCKER     -i loopback0 -d ::1/128 -j RETURN
}

case "${1:-}" in
        --watch)
                while true; do
                        apply || true
                        sleep "$INTERVAL"
                done
                ;;
        *)
                apply
                ;;
esac
