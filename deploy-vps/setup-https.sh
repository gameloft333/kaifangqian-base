#!/bin/bash
###############################################################################
# setup-https.sh - 开放签 HTTPS 配置 (Cloudflare Origin SSL)
# 基于 0025_setup-https.sh 适配，复用现有域名证书体系
# 每个项目独立配置，不影响其他服务
###############################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SSL_DIR="/etc/nginx/ssl"
SITES_DIR="/etc/nginx/sites-available"
SITES_ENABLED="/etc/nginx/sites-enabled"

# ── 工具函数 ─────────────────────────────────────────────────────
info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
step()    { echo -e "\n${GREEN}[$1/5] $2${NC}"; echo "--------------------------------------------"; }

ask_confirm() {
    local msg="$1" default="${2:-y}" hint="[Y/n]"
    [ "$default" = "n" ] && hint="[y/N]"
    while true; do
        read -rp "$(echo -e "${CYAN}  ? ${msg} ${hint}: ${NC}")" answer
        answer="${answer:-$default}"
        case "$answer" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
        esac
    done
}

# ── 前置检查 ─────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    error "请以 root 运行: sudo bash $0"
    exit 1
fi

echo -e "${CYAN}"
echo "============================================"
echo "  开放签 HTTPS 配置 (CF Origin SSL)"
echo "============================================"
echo -e "${NC}"

# ── Step 1: 收集配置 ─────────────────────────────────────────────
step 1 "收集配置信息"

# 域名
read -rp "$(echo -e "${CYAN}  域名 (如 gameai.dpdns.org): ${NC}")" DOMAIN
[ -z "$DOMAIN" ] && { error "域名不能为空"; exit 1; }

# 子域名
read -rp "$(echo -e "${CYAN}  子域名 (如 kaifangqian): ${NC}")" SUBDOMAIN
[ -z "$SUBDOMAIN" ] && { error "子域名不能为空"; exit 1; }

FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN}"

# VPS IP (自动检测)
AUTO_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s ip.sb 2>/dev/null || echo "")
if [ -n "$AUTO_IP" ]; then
    read -rp "$(echo -e "${CYAN}  检测到公网 IP: ${AUTO_IP}，使用此 IP? [Y/n]: ${NC}")" use_ip
    use_ip="${use_ip:-y}"
    if [[ "$use_ip" =~ ^[Nn] ]]; then
        read -rp "$(echo -e "${CYAN}  输入 VPS 公网 IP: ${NC}")" VPS_IP
    else
        VPS_IP="$AUTO_IP"
    fi
else
    read -rp "$(echo -e "${CYAN}  输入 VPS 公网 IP: ${NC}")" VPS_IP
fi

[ -z "$VPS_IP" ] && { error "VPS IP 不能为空"; exit 1; }

# 本地端口 (默认 8806 = 前端容器)
read -rp "$(echo -e "${CYAN}  本地端口 (默认 8806): ${NC}")" INPUT_PORT
SERVICE_PORT="${INPUT_PORT:-8806}"

# ── 生成安全文件名 (与其他项目隔离) ────────────────────────────────
SAFE_NAME=$(echo "${FULL_DOMAIN}" | tr '.' '_')
CERT_FILE="${SSL_DIR}/${SAFE_NAME}.crt"
KEY_FILE="${SSL_DIR}/${SAFE_NAME}.key"
NGINX_CONF="${SITES_DIR}/${SAFE_NAME}"
NGINX_ENABLED="${SITES_ENABLED}/${SAFE_NAME}"

echo ""
echo -e "${CYAN}  === 配置确认 ===${NC}"
echo -e "  域名:        ${GREEN}${FULL_DOMAIN}${NC}"
echo -e "  VPS IP:      ${GREEN}${VPS_IP}${NC}"
echo -e "  本地端口:    ${GREEN}${SERVICE_PORT}${NC}"
echo -e "  SSL 证书:    ${GREEN}${CERT_FILE}${NC}"
echo -e "  SSL 私钥:    ${GREEN}${KEY_FILE}${NC}"
echo -e "  Nginx 配置:  ${GREEN}${NGINX_CONF}${NC}"
echo ""

if ! ask_confirm "确认以上配置?" "y"; then
    echo "已取消。"; exit 0
fi

# ── Step 2: 检查 Nginx ───────────────────────────────────────────
step 2 "检查 Nginx"

if command -v nginx &>/dev/null; then
    info "Nginx 已安装: $(nginx -v 2>&1)"
else
    warn "Nginx 未安装，正在安装..."
    apt-get update -y && apt-get install -y nginx
    info "Nginx 安装完成"
fi

# ── Step 3: 配置 SSL 证书 ────────────────────────────────────────
step 3 "配置 Cloudflare Origin 证书"

mkdir -p "$SSL_DIR"

# 解析证书文件 (cert + key 在同一文件)
parse_cert_file() {
    local file="$1"
    sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' "$file" > "$CERT_FILE"
    sed -n '/-----BEGIN .*PRIVATE KEY-----/,/-----END .*PRIVATE KEY-----/p' "$file" > "$KEY_FILE"
    grep -q "BEGIN CERTIFICATE" "$CERT_FILE" && grep -q "PRIVATE KEY" "$KEY_FILE"
}

# 自动查找证书文件
CERT_INPUT=""
for f in "${PWD}/cf-domain-cert.md" "${HOME}/cf-domain-cert.md" "${HOME}/Downloads/cf-domain-cert.md"; do
    if [ -f "$f" ]; then
        CERT_INPUT="$f"
        info "找到证书文件: $f"
        break
    fi
done

if [ -n "$CERT_INPUT" ]; then
    if ask_confirm "使用此证书文件?" "y"; then
        if parse_cert_file "$CERT_INPUT"; then
            info "证书和私钥已提取"
        else
            warn "证书解析失败，切换到手动输入"
            CERT_INPUT=""
        fi
    else
        CERT_INPUT=""
    fi
fi

# 手动输入
if [ -z "$CERT_INPUT" ]; then
    echo ""
    echo -e "${CYAN}  输入证书文件路径 (或直接粘贴内容):${NC}"
    echo -e "${CYAN}  按 Enter 跳过，手动粘贴:${NC}"
    read -rp "  证书: " CERT_MANUAL

    if [ -n "$CERT_MANUAL" ]; then
        if [ -f "$CERT_MANUAL" ]; then
            if grep -q "PRIVATE KEY" "$CERT_MANUAL" 2>/dev/null; then
                parse_cert_file "$CERT_MANUAL" && info "证书和私钥已提取"
            else
                cp "$CERT_MANUAL" "$CERT_FILE"
                info "证书已复制"
            fi
        elif echo "$CERT_MANUAL" | grep -q "BEGIN CERTIFICATE"; then
            echo "$CERT_MANUAL" > "$CERT_FILE"
            info "证书已保存"
        else
            error "无效输入"; exit 1
        fi
    else
        echo -e "${CYAN}  粘贴完整证书 (空行结束):${NC}"
        > "$CERT_FILE"
        while IFS= read -r line; do
            [ -z "$line" ] && break
            echo "$line" >> "$CERT_FILE"
        done
        grep -q "BEGIN CERTIFICATE" "$CERT_FILE" || { error "无效证书"; exit 1; }
        info "证书已保存"
    fi
fi

# 检查是否需要单独输入私钥
if [ ! -f "$KEY_FILE" ] || [ ! -s "$KEY_FILE" ]; then
    echo -e "${CYAN}  输入私钥文件路径 (或直接粘贴内容):${NC}"
    read -rp "  私钥: " KEY_MANUAL

    if [ -n "$KEY_MANUAL" ]; then
        if [ -f "$KEY_MANUAL" ]; then
            cp "$KEY_MANUAL" "$KEY_FILE"
        elif echo "$KEY_MANUAL" | grep -q "BEGIN"; then
            echo "$KEY_MANUAL" > "$KEY_FILE"
        else
            error "无效输入"; exit 1
        fi
    else
        echo -e "${CYAN}  粘贴完整私钥 (空行结束):${NC}"
        > "$KEY_FILE"
        while IFS= read -r line; do
            [ -z "$line" ] && break
            echo "$line" >> "$KEY_FILE"
        done
        grep -q "BEGIN" "$KEY_FILE" || { error "无效私钥"; exit 1; }
    fi
fi

chmod 600 "$KEY_FILE" && chmod 644 "$CERT_FILE"

# 验证证书密钥匹配
CERT_MOD=$(openssl x509 -noout -modulus -in "$CERT_FILE" 2>/dev/null | md5sum)
KEY_MOD=$(openssl rsa -noout -modulus -in "$KEY_FILE" 2>/dev/null | md5sum)
if [ "$CERT_MOD" = "$KEY_MOD" ]; then
    info "证书和私钥匹配"
else
    error "证书和私钥不匹配! 请重新粘贴"; exit 1
fi

# ── Step 4: 生成 Nginx HTTPS 配置 ────────────────────────────────
step 4 "生成 Nginx HTTPS 配置"

cat > "$NGINX_CONF" << NGINX_EOF
# 开放签 HTTPS 反向代理 - ${FULL_DOMAIN}
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 与其他项目完全隔离 (独立证书文件 + 独立配置文件)

server {
    listen 443 ssl http2;
    server_name ${FULL_DOMAIN};

    ssl_certificate     ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    client_max_body_size 100M;

    # WebSocket 代理
    location /resrun-paas/websocket {
        proxy_pass http://127.0.0.1:${SERVICE_PORT};
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    # API 代理 (前端容器的 nginx 已处理转发到后端)
    location /resrun-paas {
        proxy_pass http://127.0.0.1:${SERVICE_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 30s;
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
    }

    # SPA 静态文件 + 所有子路径
    location / {
        proxy_pass http://127.0.0.1:${SERVICE_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

server {
    listen 80;
    server_name ${FULL_DOMAIN};
    return 301 https://\$host\$request_uri;
}
NGINX_EOF

info "Nginx 配置已写入: ${NGINX_CONF}"

# 启用站点
if [ ! -f "$NGINX_ENABLED" ]; then
    ln -s "$NGINX_CONF" "$NGINX_ENABLED"
    info "站点已启用"
else
    warn "站点已启用，跳过"
fi

# ── Step 5: 测试 & 重启 Nginx ────────────────────────────────────
step 5 "测试并重启 Nginx"

if nginx -t 2>&1; then
    info "Nginx 配置测试通过"
else
    error "Nginx 配置测试失败"; exit 1
fi

systemctl restart nginx
systemctl enable nginx
info "Nginx 已重启并设为开机自启"

# ── 完成 ─────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  HTTPS 配置完成!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "  ${CYAN}HTTPS 地址:${NC} https://${FULL_DOMAIN}/"
echo ""
echo -e "  ${CYAN}DNS 配置 (Cloudflare):${NC}"
echo -e "    类型: A"
echo -e "    名称: ${SUBDOMAIN}"
echo -e "    内容: ${VPS_IP}"
echo -e "    代理: 已代理 (橙色云朵)"
echo -e "    SSL:  完全 (严格)"
echo ""
echo -e "  ${CYAN}文件清单 (独立于其他项目):${NC}"
echo -e "    SSL 证书:  ${GREEN}${CERT_FILE}${NC}"
echo -e "    SSL 私钥:  ${GREEN}${KEY_FILE}${NC}"
echo -e "    Nginx:     ${GREEN}${NGINX_CONF}${NC}"
echo ""
echo -e "  ${CYAN}常用命令:${NC}"
echo -e "    nginx -t                          # 测试配置"
echo -e "    systemctl restart nginx           # 重启 Nginx"
echo -e "    tail -f /var/log/nginx/error.log  # 查看错误"
echo -e "    nano ${NGINX_CONF}    # 编辑配置"
echo ""
echo -e "  ${CYAN}添加其他项目:${NC}"
echo -e "    再次运行此脚本，使用不同子域名即可"
echo -e "    每个项目独立证书 + 独立配置，互不干扰"
echo ""
