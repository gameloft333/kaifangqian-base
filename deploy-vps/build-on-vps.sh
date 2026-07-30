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

# ── Step 1: 检测并安装构建工具 ──────────────────────────────────
echo ""
info "[1/5] 检测构建工具..."

# 检测包管理器
if command -v apt-get &>/dev/null; then
    PKG="apt-get"
elif command -v yum &>/dev/null; then
    PKG="yum"
else
    error "不支持的包管理器"; exit 1
fi

INSTALLED=()
NEED_INSTALL=()

# Java 8
if command -v java &>/dev/null; then
    INSTALLED+=("Java: $(java -version 2>&1 | head -1)")
else
    NEED_INSTALL+=("java")
fi

# Maven
if command -v mvn &>/dev/null; then
    INSTALLED+=("Maven: $(mvn -version 2>&1 | head -1)")
else
    NEED_INSTALL+=("maven")
fi

# Node.js + npm
if command -v node &>/dev/null; then
    INSTALLED+=("Node.js: $(node -v), npm: $(npm -v)")
else
    NEED_INSTALL+=("nodejs")
fi

# 显示检测结果
if [ ${#INSTALLED[@]} -gt 0 ]; then
    info "已安装:"
    for item in "${INSTALLED[@]}"; do
        echo "  ✓ $item"
    done
fi

# 按需安装
if [ ${#NEED_INSTALL[@]} -gt 0 ]; then
    info "需要安装: ${NEED_INSTALL[*]}"
    $PKG update -y -qq

    for tool in "${NEED_INSTALL[@]}"; do
        case "$tool" in
            java)
                info "安装 OpenJDK 8..."
                if [ "$PKG" = "apt-get" ]; then
                    $PKG install -y -qq openjdk-8-jdk-headless
                else
                    $PKG install -y -qq java-1.8.0-openjdk-devel
                fi
                ;;
            maven)
                info "安装 Maven..."
                if [ "$PKG" = "apt-get" ]; then
                    $PKG install -y -qq maven
                else
                    cd /tmp
                    curl -sL https://dlcdn.apache.org/maven/maven-3/3.9.9/binaries/apache-maven-3.9.9-bin.tar.gz | tar xz
                    mv apache-maven-3.9.9 /opt/maven
                    ln -sf /opt/maven/bin/mvn /usr/local/bin/mvn
                fi
                ;;
            nodejs)
                info "安装 Node.js..."
                if [ "$PKG" = "apt-get" ]; then
                    $PKG install -y -qq nodejs npm
                else
                    curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
                    $PKG install -y -qq nodejs
                fi
                ;;
        esac
    done
else
    info "所有构建工具已就绪，无需安装"
fi

# 最终验证
echo ""
info "工具版本:"
java -version 2>&1 | head -1
mvn -version 2>&1 | head -1
node -v
npm -v

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

# ── Step 4: 构建前端 (逐个构建，构建后立即清理释放内存) ──────────
echo ""
info "[4/5] 构建前端 (逐个构建防 OOM)..."
WEB_DIR="$PROJECT_DIR/kaifangqian-web"
BUILD_DIR="$SCRIPT_DIR/build/web"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# 限制 Node.js 内存 (Vite 构建内存密集)
export NODE_OPTIONS="--max-old-space-size=512"

APPS=(opensign-web opensign-manage opensign-tenant opensign-message opensign-mobile)
TOTAL=${#APPS[@]}
COUNT=0

for app in "${APPS[@]}"; do
    APP_DIR="$WEB_DIR/$app"
    COUNT=$((COUNT + 1))

    if [ -d "$APP_DIR" ]; then
        echo ""
        info "  [$COUNT/$TOTAL] 构建 $app ..."
        cd "$APP_DIR"

        npm install --silent 2>/dev/null
        npm run build --silent 2>/dev/null

        if [ -d "dist" ]; then
            mkdir -p "$BUILD_DIR/$app"
            cp -r dist/* "$BUILD_DIR/$app/"
            info "  ✓ $app 构建完成"
        else
            warn "  ✗ $app 构建失败 (可能 OOM)，跳过"
        fi

        # 立即清理: 删除 node_modules 和 dist 释放内存/磁盘
        rm -rf node_modules dist .vite
        info "  已清理 $app 临时文件"

        # 打印当前内存状态
        free -m | grep Mem
    fi
done

unset NODE_OPTIONS
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

# ── 清理构建工具 (仅卸载本次安装的) ──────────────────────────────
if [ ${#NEED_INSTALL[@]} -gt 0 ]; then
    echo ""
    read -rp "$(echo -e "${YELLOW}是否卸载本次安装的构建工具 (${NEED_INSTALL[*]}) 释放空间? [y/N]: ${NC}")" cleanup_tools
    if [[ "$cleanup_tools" =~ ^[Yy] ]]; then
        info "卸载本次安装的构建工具..."
        for tool in "${NEED_INSTALL[@]}"; do
            case "$tool" in
                java)
                    if [ "$PKG" = "apt-get" ]; then
                        $PKG remove -y -qq openjdk-8-jdk-headless 2>/dev/null || true
                    else
                        $PKG remove -y -qq java-1.8.0-openjdk-devel 2>/dev/null || true
                    fi
                    ;;
                maven)
                    if [ "$PKG" = "apt-get" ]; then
                        $PKG remove -y -qq maven 2>/dev/null || true
                    else
                        rm -rf /opt/maven /usr/local/bin/mvn
                    fi
                    ;;
                nodejs)
                    if [ "$PKG" = "apt-get" ]; then
                        $PKG remove -y -qq nodejs npm 2>/dev/null || true
                    else
                        $PKG remove -y -qq nodejs 2>/dev/null || true
                    fi
                    ;;
            esac
        done
        $PKG autoremove -y -qq 2>/dev/null || true
        info "构建工具已卸载"
        df -h / | tail -1
    fi
else
    info "所有构建工具均为系统已有，无需清理"
fi
