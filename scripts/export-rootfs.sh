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