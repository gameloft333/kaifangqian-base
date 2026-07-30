#!/bin/bash
###############################################################################
# deploy.sh - VPS 部署脚本 (2C2G 优化)
# 用法: bash deploy.sh [命令]
#   命令:
#     build     - 在 VPS 上构建 Docker 镜像
#     setup     - 首次部署 (清理+swap+启动)
#     start     - 启动服务
#     stop      - 停止服务
#     restart   - 重启服务
#     status    - 查看状态
#     logs      - 查看日志
#     cleanup   - 清理磁盘空间
#     import    - 导入镜像 (从 kq-images.tar.gz)
#     https     - 配置 HTTPS (Cloudflare Origin SSL)
###############################################################################
#    VPS 上的部署步骤
#   # 1. 部署 Docker 服务
#   cd ~/kaifangqian-base/deploy-vps
#   bash deploy.sh setup
#   # 2. 配置 HTTPS (交互式，和 0025 一样的流程)
#   bash deploy.sh https
#   # 输入: 域名=gameai.dpdns.org, 子域名=kaifangqian, 端口=8806
#   # 证书: 从 cf-domain-cert.md 读取或手动粘贴
#   # 3. Cloudflare DNS 添加 A 记录
#   # kaifangqian.gameai.dpdns.org → <VPS IP> → 已代理
#   每个项目的 Nginx 配置都是独立文件 (/etc/nginx/sites-available/kaifangqian_gameai_dpdns_org)，证书也是独立的，完全不影响 pansou、netdiskplayer 等其他服务。
###############################################################################


set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
ENV_FILE="$SCRIPT_DIR/.env"
IMAGE_ARCHIVE="kq-images.tar.gz"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ── 环境检查 ─────────────────────────────────────────────────────
check_env() {
    if [ ! -f "$ENV_FILE" ]; then
        warn ".env 文件不存在，创建默认配置..."
        cat > "$ENV_FILE" << 'ENVEOF'
# 开放签 VPS 部署配置
MYSQL_ROOT_PASSWORD=kaifangqian2024
MYSQL_PASSWORD=kaifangqian2024
REDIS_PASSWORD=kaifangqian2024
ENVEOF
        info "已创建 .env，请按需修改密码后重新运行"
        exit 0
    fi

    if ! command -v docker &>/dev/null; then
        error "Docker 未安装"; exit 1
    fi

    if ! docker compose version &>/dev/null; then
        error "docker compose 不可用"; exit 1
    fi
}

# ── 清理磁盘空间 (不影响运行中的容器) ────────────────────────────
cleanup() {
    info "========== 清理磁盘空间 =========="

    # 清理已停止的容器
    local stopped=$(docker ps -a --filter "status=exited" --format "{{.ID}}" | head -20)
    if [ -n "$stopped" ]; then
        info "清理已停止的容器..."
        echo "$stopped" | xargs docker rm -f 2>/dev/null || true
    fi

    # 清理悬空镜像 (dangling)
    local dangling=$(docker images -f "dangling=true" -q | head -20)
    if [ -n "$dangling" ]; then
        info "清理悬空镜像..."
        echo "$dangling" | xargs docker rmi -f 2>/dev/null || true
    fi

    # 清理未使用的卷
    info "清理未使用的 Docker 卷..."
    docker volume prune -f 2>/dev/null || true

    # 清理未使用的网络
    docker network prune -f 2>/dev/null || true

    # 清理构建缓存
    info "清理 Docker 构建缓存..."
    docker builder prune -f --keep-storage=200MB 2>/dev/null || true

    # 清理系统日志 (保留最近3天)
    info "清理系统日志..."
    find /var/log -name "*.gz" -mtime +3 -delete 2>/dev/null || true
    find /var/log -name "*.old" -delete 2>/dev/null || true
    journalctl --vacuum-time=3d 2>/dev/null || true

    # 清理 apt 缓存
    info "清理 apt 缓存..."
    apt-get clean 2>/dev/null || true

    # 清理临时文件
    info "清理临时文件..."
    find /tmp -type f -mtime +7 -delete 2>/dev/null || true
    find /var/tmp -type f -mtime +7 -delete 2>/dev/null || true

    # 清理旧的镜像归档
    if [ -f "$SCRIPT_DIR/$IMAGE_ARCHIVE" ]; then
        info "清理镜像归档文件..."
        rm -f "$SCRIPT_DIR/$IMAGE_ARCHIVE"
    fi

    info "========== 清理完成 =========="
    echo ""
    df -h / | tail -1
    echo ""
    docker system df 2>/dev/null || true
}

# ── Swap 设置 ────────────────────────────────────────────────────
setup_swap() {
    local swap_size=${1:-4096}

    if [ "$(swapon --show | wc -l)" -gt 1 ]; then
        local current_swap=$(swapon --show --bytes | awk 'NR>1{s+=$3}END{printf "%.0f", s/1024/1024/1024}')
        info "Swap 已存在: ${current_swap}GB"
        return 0
    fi

    info "创建 ${swap_size}MB Swap..."
    fallocate -l "${swap_size}M" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    # 持久化
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    # 调整 swappiness (降低使用 swap 的倾向)
    sysctl vm.swappiness=10
    if ! grep -q 'vm.swappiness' /etc/sysctl.conf; then
        echo 'vm.swappiness=10' >> /etc/sysctl.conf
    fi

    info "Swap 设置完成"
    free -h
}

# ── 导入镜像 ────────────────────────────────────────────────────
import_images() {
    local archive_path="$SCRIPT_DIR/$IMAGE_ARCHIVE"

    # 也检查上级目录
    if [ ! -f "$archive_path" ] && [ -f "$(dirname "$SCRIPT_DIR")/$IMAGE_ARCHIVE" ]; then
        archive_path="$(dirname "$SCRIPT_DIR")/$IMAGE_ARCHIVE"
    fi

    if [ ! -f "$archive_path" ]; then
        error "镜像归档文件不存在: $IMAGE_ARCHIVE"
        echo "请先在本地运行 build.sh 构建，然后:"
        echo "  docker save kaifangqian-backend:latest kaifangqian-frontend:latest | gzip > $IMAGE_ARCHIVE"
        echo "  scp $IMAGE_ARCHIVE root@<vps-ip>:$SCRIPT_DIR/"
        exit 1
    fi

    info "导入 Docker 镜像..."
    gunzip -c "$archive_path" | docker load
    info "镜像导入完成"
    docker images | grep kaifangqian
}

# ── 检查必需镜像是否存在 ─────────────────────────────────────────
check_images() {
    local missing=()

    if ! docker image inspect kaifangqian-backend:latest &>/dev/null; then
        missing+=("kaifangqian-backend:latest")
    fi
    if ! docker image inspect kaifangqian-frontend:latest &>/dev/null; then
        missing+=("kaifangqian-frontend:latest")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        error "缺少以下 Docker 镜像:"
        for img in "${missing[@]}"; do
            echo "  - $img"
        done
        echo ""
        echo "  请先通过以下方式之一准备镜像:"
        echo ""
        echo "  方式1: 本地构建后传输到 VPS"
        echo "    # 本地执行:"
        echo "    cd deploy-vps && bash build.sh"
        echo "    docker save kaifangqian-backend:latest kaifangqian-frontend:latest | gzip > kq-images.tar.gz"
        echo "    scp kq-images.tar.gz root@<vps-ip>:$(dirname "$SCRIPT_DIR")/"
        echo ""
        echo "  方式2: 在 VPS 上直接构建 (需要 Java + Maven + Node.js)"
        echo "    cd $(dirname "$SCRIPT_DIR")/kaifangqian-parent && mvn clean package -DskipTests"
        echo "    docker build -t kaifangqian-backend:latest ."
        echo "    cd $(dirname "$SCRIPT_DIR")/deploy-vps && bash build.sh"
        echo ""
        return 1
    fi

    info "镜像检查通过"
    return 0
}

# ── 首次部署 ────────────────────────────────────────────────────
setup() {
    info "========== 首次部署 =========="

    # 1. 清理空间
    cleanup

    # 2. 设置 Swap
    setup_swap 4096

    # 3. 检查镜像
    if ! check_images; then
        exit 1
    fi

    # 4. 启动服务
    info "启动服务..."
    cd "$SCRIPT_DIR"
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d

    # 5. 等待健康检查
    info "等待服务就绪..."
    local max_wait=120
    local waited=0
    while [ $waited -lt $max_wait ]; do
        if docker compose -f "$COMPOSE_FILE" ps | grep -q "healthy"; then
            local healthy=$(docker compose -f "$COMPOSE_FILE" ps | grep -c "healthy" || true)
            if [ "$healthy" -ge 3 ]; then
                info "所有服务就绪!"
                break
            fi
        fi
        sleep 5
        waited=$((waited + 5))
        echo -ne "\r  等待中... ${waited}s/${max_wait}s"
    done
    echo ""

    show_status
}

# ── 启动 ────────────────────────────────────────────────────────
start() {
    info "启动服务..."
    if ! check_images; then
        exit 1
    fi
    cd "$SCRIPT_DIR"
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d
    sleep 5
    show_status
}

# ── 停止 ────────────────────────────────────────────────────────
stop() {
    info "停止服务..."
    cd "$SCRIPT_DIR"
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down
    info "服务已停止"
}

# ── 重启 ────────────────────────────────────────────────────────
restart() {
    stop
    sleep 3
    start
}

# ── 状态 ────────────────────────────────────────────────────────
show_status() {
    echo ""
    info "========== 服务状态 =========="
    cd "$SCRIPT_DIR"
    docker compose -f "$COMPOSE_FILE" ps
    echo ""
    info "内存使用:"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" \
        $(docker compose -f "$COMPOSE_FILE" ps -q 2>/dev/null | xargs -r docker inspect --format='{{.Name}}' 2>/dev/null | sed 's/^\///') \
        2>/dev/null || true
    echo ""
    info "磁盘:"
    df -h / | tail -1
}

# ── 日志 ────────────────────────────────────────────────────────
show_logs() {
    cd "$SCRIPT_DIR"
    docker compose -f "$COMPOSE_FILE" logs --tail=50 -f
}

# ── 主入口 ──────────────────────────────────────────────────────
check_env

case "${1:-help}" in
    build)   bash "$SCRIPT_DIR/build-on-vps.sh" ;;
    setup)   setup ;;
    start)   start ;;
    stop)    stop ;;
    restart) restart ;;
    status)  show_status ;;
    logs)    show_logs ;;
    cleanup) cleanup ;;
    import)  import_images ;;
    https)   bash "$SCRIPT_DIR/setup-https.sh" ;;
    *)
        echo "用法: $0 {build|setup|start|stop|restart|status|logs|cleanup|import|https}"
        echo ""
        echo "  build   - 在 VPS 上构建 Docker 镜像 (自动安装/清理构建工具)"
        echo "  setup   - 首次部署 (清理+swap+启动)"
        echo "  start   - 启动服务"
        echo "  stop    - 停止服务"
        echo "  restart - 重启服务"
        echo "  status  - 查看服务状态和内存使用"
        echo "  logs    - 查看日志"
        echo "  cleanup - 清理磁盘空间"
        echo "  import  - 导入 Docker 镜像"
        echo "  https   - 配置 HTTPS (Cloudflare Origin SSL)"
        ;;
esac
