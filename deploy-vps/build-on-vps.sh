#!/bin/bash
###############################################################################
# build-on-vps.sh - 在 VPS 上直接构建 Docker 镜像
# 适用于本地无法构建的场景 (如 Windows 无 Docker)
# 自动安装构建工具 → 构建后端/前端 → 清理工具 → 释放空间
###############################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ── 前置检查 ─────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    error "请以 root 运行: sudo bash $0"
    exit 1
fi

if ! command -v docker &>/dev/null; then
    error "Docker 未安装"; exit 1
fi

echo -e "${GREEN}"
echo "============================================"
echo "  开放签 VPS 端构建"
echo "  临时安装工具 → 构建镜像 → 清理释放空间"
echo "============================================"
echo -e "${NC}"

# ── Step 1: 安装构建工具 ────────────────────────────────────────
echo ""
info "[1/5] 安装构建工具..."

# 检测包管理器
if command -v apt-get &>/dev/null; then
    PKG="apt-get"
elif command -v yum &>/dev/null; then
    PKG="yum"
else
    error "不支持的包管理器"; exit 1
fi

$PKG update -y -qq

# Java 8 (后端构建需要)
if ! command -v java &>/dev/null; then
    info "安装 OpenJDK 8..."
    if [ "$PKG" = "apt-get" ]; then
        $PKG install -y -qq openjdk-8-jdk-headless
    else
        $PKG install -y -qq java-1.8.0-openjdk-devel
    fi
fi
info "Java: $(java -version 2>&1 | head -1)"

# Maven (后端构建需要)
if ! command -v mvn &>/dev/null; then
    info "安装 Maven..."
    if [ "$PKG" = "apt-get" ]; then
        $PKG install -y -qq maven
    else
        cd /tmp
        curl -sL https://dlcdn.apache.org/maven/maven-3/3.9.9/binaries/apache-maven-3.9.9-bin.tar.gz | tar xz
        mv apache-maven-3.9.9 /opt/maven
        ln -sf /opt/maven/bin/mvn /usr/local/bin/mvn
    fi
fi
info "Maven: $(mvn -version 2>&1 | head -1)"

# Node.js + npm (前端构建需要)
if ! command -v node &>/dev/null; then
    info "安装 Node.js..."
    if [ "$PKG" = "apt-get" ]; then
        $PKG install -y -qq nodejs npm
    else
        curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
        $PKG install -y -qq nodejs
    fi
fi
info "Node.js: $(node -v), npm: $(npm -v)"

# ── Step 2: 构建后端 JAR ────────────────────────────────────────
echo ""
info "[2/5] 构建后端 JAR..."
cd "$PROJECT_DIR/kaifangqian-parent"

# 检查字体文件
if [ ! -f "file/simsun.ttc" ]; then
    warn "未找到中文字体文件 (file/simsun.ttc)"
    warn "PDF 中文渲染可能异常，继续构建..."
fi

# Maven 构建 (限制内存防止 OOM)
export MAVEN_OPTS="-Xms256m -Xmx512m -XX:+UseG1GC"
mvn clean package -DskipTests -q 2>&1 | tail -5

if [ ! -f "kaifangqian-system/target/kaifangqian.jar" ]; then
    error "后端 JAR 构建失败"
    exit 1
fi
info "后端 JAR 构建完成: $(du -h kaifangqian-system/target/kaifangqian.jar | cut -f1)"

# ── Step 3: 构建后端 Docker 镜像 ────────────────────────────────
echo ""
info "[3/5] 构建后端 Docker 镜像..."
docker build -t kaifangqian-backend:latest .
info "后端镜像构建完成"

# ── Step 4: 构建前端 ────────────────────────────────────────────
echo ""
info "[4/5] 构建前端..."
WEB_DIR="$PROJECT_DIR/kaifangqian-web"
BUILD_DIR="$SCRIPT_DIR/build/web"
rm -rf "$BUILD_DIR"

for app in opensign-web opensign-manage opensign-tenant opensign-message opensign-mobile; do
    APP_DIR="$WEB_DIR/$app"
    if [ -d "$APP_DIR" ]; then
        echo "  构建 $app ..."
        cd "$APP_DIR"
        npm install --silent 2>/dev/null
        npm run build --silent 2>/dev/null

        if [ -d "dist" ]; then
            mkdir -p "$BUILD_DIR/$app"
            cp -r dist/* "$BUILD_DIR/$app/"
            echo "  ✅ $app 完成"
        else
            echo "  ⚠️  $app 无 dist，跳过"
        fi
    fi
done
info "前端构建完成"

# ── Step 5: 构建前端 Docker 镜像 ────────────────────────────────
echo ""
info "[5/5] 构建前端 Docker 镜像..."
cd "$SCRIPT_DIR"

rm -rf build/frontend
mkdir -p build/frontend
cp nginx-default.conf build/frontend/
cp Dockerfile.frontend build/frontend/Dockerfile

for app in opensign-web opensign-manage opensign-tenant opensign-message opensign-mobile; do
    if [ -d "$BUILD_DIR/$app" ]; then
        cp -r "$BUILD_DIR/$app" "build/frontend/$app"
    fi
done

cd build/frontend
docker build -t kaifangqian-frontend:latest .
info "前端镜像构建完成"

# ── 清理构建临时文件 ─────────────────────────────────────────────
echo ""
info "清理构建临时文件..."
rm -rf "$SCRIPT_DIR/build"
rm -rf "$PROJECT_DIR/kaifangqian-parent/kaifangqian-system/target"
info "临时文件已清理"

# ── 显示结果 ─────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  构建完成!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
docker images | grep kaifangqian
echo ""
echo -e "  下一步:"
echo -e "  bash $SCRIPT_DIR/101_deploy.sh setup"
echo ""

# ── 清理构建工具 (可选) ──────────────────────────────────────────
echo ""
read -rp "$(echo -e "${YELLOW}是否卸载构建工具 (Java/Maven/Node.js) 释放空间? [y/N]: ${NC}")" cleanup_tools
if [[ "$cleanup_tools" =~ ^[Yy] ]]; then
    info "卸载构建工具..."
    if [ "$PKG" = "apt-get" ]; then
        $PKG remove -y -qq openjdk-8-jdk-headless maven nodejs npm 2>/dev/null || true
        $PKG autoremove -y -qq 2>/dev/null || true
    else
        rm -rf /opt/maven /usr/local/bin/mvn
        yum remove -y java-1.8.0-openjdk-devel nodejs 2>/dev/null || true
    fi
    info "构建工具已卸载"
    df -h / | tail -1
fi
