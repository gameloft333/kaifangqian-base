#!/bin/bash
###############################################################################
# build-frontend-local.sh - 本地构建前端 (无需 Docker)
# 在 Windows/Git Bash 下运行，只需 Node.js
# 构建完成后生成 deploy-vps/build/web/ 目录，传到 VPS 即可
###############################################################################
#   在 VPS 上执行：                                                                                                                                                                                
#   ssh root@107.174.137.194                                                                                                                                                                    
  
#   # 先确认构建工具已安装
#   java -version && mvn -version && node -v

#   # 设置 npm 镜像
#   npm config set registry https://registry.npmmirror.com

#   # 逐个构建前端 (每个构建后清理 node_modules)
#   cd ~/dev/kaifangqian-base/kaifangqian-web

#   for app in opensign-mobile opensign-message opensign-tenant opensign-manage opensign-web; do
#       echo "=== 构建 $app ==="
#       cd ~/dev/kaifangqian-base/kaifangqian-web/$app
#       npm install --silent 2>/dev/null
#       NODE_OPTIONS="--max-old-space-size=384" npm run build --silent 2>/dev/null
#       rm -rf node_modules .vite
#       free -m | grep Mem
#       echo "---"
#   done

#   # 构建完成后构建 Docker 镜像
#   cd ~/dev/kaifangqian-base/deploy-vps
#   bash build-on-vps.sh

#   # 启动服务
#   bash 101_deploy.sh setup

#   这样整个流程都在 VPS 上完成，不依赖 Windows 本地环境。如果某个应用 OOM 了，swap 会兜底（慢一点但不会崩）。
###############################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
WEB_DIR="$PROJECT_DIR/kaifangqian-web"
BUILD_DIR="$SCRIPT_DIR/build/web"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ── 检查环境 ─────────────────────────────────────────────────────
if ! command -v node &>/dev/null; then
    error "Node.js 未安装"; exit 1
fi

info "Node.js: $(node -v), npm: $(npm -v)"
info "项目目录: $PROJECT_DIR"

# ── 确保构建目录存在 ────────────────────────────────────────────
mkdir -p "$BUILD_DIR"

# ── 逐个构建 ────────────────────────────────────────────────────
APPS=(opensign-web opensign-manage opensign-tenant opensign-message opensign-mobile)
TOTAL=${#APPS[@]}
COUNT=0
FAILED=()

for app in "${APPS[@]}"; do
    APP_DIR="$WEB_DIR/$app"
    COUNT=$((COUNT + 1))

    if [ ! -d "$APP_DIR" ]; then
        warn "[$COUNT/$TOTAL] $app 目录不存在，跳过"
        continue
    fi

    cd "$APP_DIR"

    # ── 变更检测: 源码没变则跳过 ──
    NEED_BUILD=false
    if [ ! -d "$BUILD_DIR/$app" ] || [ -z "$(ls -A "$BUILD_DIR/$app" 2>/dev/null)" ]; then
        NEED_BUILD=true
        info "[$COUNT/$TOTAL] $app 无构建产物，需要构建"
    else
        # 检查源码是否有更新 (比较 .js/.vue/.ts/.json 文件修改时间)
        BUILD_TIME=$(stat -c %Y "$BUILD_DIR/$app" 2>/dev/null || stat -f %m "$BUILD_DIR/$app" 2>/dev/null || echo 0)
        SRC_TIME=$(find "$APP_DIR/src" -name "*.vue" -o -name "*.ts" -o -name "*.js" 2>/dev/null | head -1 | xargs stat -c %Y 2>/dev/null || \
                   find "$APP_DIR/src" -name "*.vue" -o -name "*.ts" -o -name "*.js" 2>/dev/null | head -1 | xargs stat -f %m 2>/dev/null || echo 0)
        PKG_TIME=$(stat -c %Y "$APP_DIR/package.json" 2>/dev/null || stat -f %m "$APP_DIR/package.json" 2>/dev/null || echo 0)

        # 取最新的源码时间
        for t in "$SRC_TIME" "$PKG_TIME"; do
            if [ "$t" -gt "${NEWEST_SRC:-0}" ] 2>/dev/null; then
                NEWEST_SRC=$t
            fi
        done

        if [ "${NEWEST_SRC:-0}" -gt "$BUILD_TIME" ] 2>/dev/null; then
            NEED_BUILD=true
            info "[$COUNT/$TOTAL] $app 源码有变化，需要重新构建"
        else
            info "[$COUNT/$TOTAL] $app 源码无变化，跳过"
        fi
    fi

    if [ "$NEED_BUILD" = false ]; then
        continue
    fi

    echo ""
    info "[$COUNT/$TOTAL] 构建 $app ..."

    # 安装依赖 (检查 node_modules 是否完整)
    NEED_INSTALL=false
    if [ ! -d "node_modules" ] || [ ! -f "node_modules/.bin/cross-env" ]; then
        NEED_INSTALL=true
    fi

    if [ "$NEED_INSTALL" = true ]; then
        info "  安装依赖..."
        set +e
        NPM_OUTPUT=$(NODE_OPTIONS="--max-old-space-size=512" npm install --legacy-peer-deps 2>&1)
        NPM_EXIT=$?
        set -e
        # 如果安装失败且包含 Invalid Version，删除 lock 文件重试
        if [ $NPM_EXIT -ne 0 ] && echo "$NPM_OUTPUT" | grep -q "Invalid Version"; then
            warn "  lock 文件损坏，删除后重试..."
            rm -f package-lock.json
            rm -rf node_modules
            set +e
            NPM_OUTPUT=$(NODE_OPTIONS="--max-old-space-size=512" npm install --legacy-peer-deps 2>&1)
            NPM_EXIT=$?
            set -e
        fi
        if [ $NPM_EXIT -ne 0 ]; then
            warn "  ✗ $app 依赖安装失败 (exit=$NPM_EXIT)，跳过"
            echo "$NPM_OUTPUT" | tail -15
            FAILED+=("$app")
            continue
        fi
    fi

    # 构建
    info "  构建中..."
    set +e
    BUILD_OUTPUT=$(NODE_OPTIONS="--max-old-space-size=2048" npm run build 2>&1)
    BUILD_EXIT=$?
    set -e

    if [ $BUILD_EXIT -eq 0 ] && [ -d "dist" ]; then
        mkdir -p "$BUILD_DIR/$app"
        cp -r dist/* "$BUILD_DIR/$app/"
        info "  ✓ $app 构建完成 ($(du -sh dist | cut -f1))"
    else
        warn "  ✗ $app 构建失败 (exit=$BUILD_EXIT)"
        echo "$BUILD_OUTPUT" | tail -10
        FAILED+=("$app")
    fi

    # 清理 dist 和 .vite (保留 node_modules)
    rm -rf dist .vite
done

# ── 结果 ─────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}============================================${NC}"
if [ ${#FAILED[@]} -gt 0 ]; then
    echo -e "${YELLOW}  构建完成，但有失败: ${FAILED[*]}${NC}"
else
    echo -e "${GREEN}  全部构建成功!${NC}"
fi
echo -e "${GREEN}============================================${NC}"
echo ""
info "构建产物: $BUILD_DIR"
ls -la "$BUILD_DIR"/ 2>/dev/null || true
echo ""
info "下一步: 将 build/web/ 传到 VPS"
echo "  scp -r $BUILD_DIR root@<vps-ip>:~/dev/kaifangqian-base/deploy-vps/build/"
echo ""
info "然后在 VPS 上构建前端 Docker 镜像:"
echo "  cd ~/dev/kaifangqian-base/deploy-vps"
echo "  bash build-on-vps.sh  (会自动检测并只构建 Docker 镜像)"
