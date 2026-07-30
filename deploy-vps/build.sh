#!/bin/bash
###############################################################################
# build.sh - 本地构建 Docker 镜像
# 在项目根目录 kaifangqian-base/ 下运行
###############################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKEND_DIR="$PROJECT_DIR/kaifangqian-parent"
WEB_DIR="$PROJECT_DIR/kaifangqian-web"
DEPLOY_DIR="$SCRIPT_DIR"

echo "============================================"
echo "  开放签 Docker 镜像构建"
echo "============================================"
echo "项目目录: $PROJECT_DIR"
echo ""

# ── 检查前置条件 ─────────────────────────────────────────────────
echo "[1/5] 检查构建环境..."

if ! command -v docker &>/dev/null; then
    echo "❌ Docker 未安装"; exit 1
fi

if ! command -v node &>/dev/null; then
    echo "❌ Node.js 未安装"; exit 1
fi

if ! command -v java &>/dev/null; then
    echo "❌ Java 未安装"; exit 1
fi

echo "✅ Docker, Node.js, Java 均可用"
echo ""

# ── 构建后端 JAR ─────────────────────────────────────────────────
echo "[2/5] 构建后端 JAR..."
cd "$BACKEND_DIR"

if [ ! -f "kaifangqian-system/target/kaifangqian.jar" ]; then
    echo "  执行 mvn clean package -DskipTests ..."
    mvn clean package -DskipTests -q
fi

if [ ! -f "kaifangqian-system/target/kaifangqian.jar" ]; then
    echo "❌ 后端 JAR 构建失败"; exit 1
fi
echo "✅ 后端 JAR 就绪"
echo ""

# ── 构建前端 ─────────────────────────────────────────────────────
echo "[3/5] 构建前端..."
BUILD_WEB_DIR="$DEPLOY_DIR/build/web"
rm -rf "$BUILD_WEB_DIR"

for app in opensign-web opensign-manage opensign-tenant opensign-message opensign-mobile; do
    APP_DIR="$WEB_DIR/$app"
    if [ -d "$APP_DIR" ]; then
        echo "  构建 $app ..."
        cd "$APP_DIR"
        npm install --silent 2>/dev/null
        npm run build --silent 2>/dev/null

        if [ -d "dist" ]; then
            mkdir -p "$BUILD_WEB_DIR/$app"
            cp -r dist/* "$BUILD_WEB_DIR/$app/"
            echo "  ✅ $app 构建完成"
        else
            echo "  ⚠️  $app 无 dist 目录，跳过"
        fi
    fi
done
echo "✅ 前端构建完成"
echo ""

# ── 构建后端 Docker 镜像 ─────────────────────────────────────────
echo "[4/5] 构建后端 Docker 镜像..."
cd "$BACKEND_DIR"

# 检查字体文件
FONT_DIR="$BACKEND_DIR/file"
if [ ! -f "$FONT_DIR/simsun.ttc" ]; then
    echo "⚠️  未找到中文字体文件 ($FONT_DIR/simsun.ttc)"
    echo "   请确保 $FONT_DIR/ 下有 simsun.ttc, simkai.ttf, simhei.ttf, simfang.ttf"
    echo "   继续构建（PDF 中文渲染可能异常）..."
fi

docker build -t kaifangqian-backend:latest .
echo "✅ 后端镜像构建完成"
echo ""

# ── 构建前端 Docker 镜像 ─────────────────────────────────────────
echo "[5/5] 构建前端 Docker 镜像..."
cd "$DEPLOY_DIR"

# 准备前端构建目录
rm -rf build/frontend
mkdir -p build/frontend

# 复制 nginx 配置
cp nginx-default.conf build/frontend/
cp Dockerfile.frontend build/frontend/Dockerfile

# 复制前端构建产物
for app in opensign-web opensign-manage opensign-tenant opensign-message opensign-mobile; do
    if [ -d "$BUILD_WEB_DIR/$app" ]; then
        cp -r "$BUILD_WEB_DIR/$app" "build/frontend/$app"
    fi
done

cd build/frontend
docker build -t kaifangqian-frontend:latest .
echo "✅ 前端镜像构建完成"
echo ""

# ── 清理构建临时文件 ─────────────────────────────────────────────
echo "清理构建临时文件..."
rm -rf "$DEPLOY_DIR/build"
echo "✅ 清理完成"
echo ""

echo "============================================"
echo "  构建完成！"
echo "  后端镜像: kaifangqian-backend:latest"
echo "  前端镜像: kaifangqian-frontend:latest"
echo ""
echo "  下一步: 将镜像导出并传输到 VPS"
echo "  docker save kaifangqian-backend:latest kaifangqian-frontend:latest | gzip > kq-images.tar.gz"
echo "============================================"
