# 开放签 VPS 部署方案 (2C2G OOM-Optimized)

## 架构图

```
                    Cloudflare (SSL, CDN, WAF)
                            │
                            │ HTTPS (443)
                            ▼
                ┌─── Host Nginx (SSL 终结) ───┐
                │  /etc/nginx/sites-available/ │
                │  kaifangqian_gameai_dpdns_org│
                └────────────┬────────────────┘
                             │ HTTP (8806)
                             ▼
                ┌─── Docker Frontend ──────────┐
                │  nginx:alpine (容器内)        │
                │  ├── 静态文件 (SPA)           │
                │  ├── /resrun-paas → 后端代理  │
                │  └── WebSocket 代理           │
                └────────────┬────────────────┘
                             │ Docker 内部网络
                             ▼
                ┌─── Docker Backend ───────────┐
                │  Spring Boot (8899)          │
                │  ├── PDF 签名/处理            │
                │  ├── JWT 认证                │
                │  └── Shiro 权限              │
                └────┬───────────┬────────────┘
                     │           │
                     ▼           ▼
              ┌── MySQL ──┐ ┌── Redis ──┐
              │  (3306)   │ │  (6379)   │
              └───────────┘ └───────────┘
```

**请求链路**: 客户端 → CF (HTTPS) → Host nginx (SSL 终结, 443) → Docker Frontend (8806) → Docker Backend (8899)

## 内存分配方案

| 组件 | 限制 | 保留 | 用途 |
|------|------|------|------|
| MySQL | 350MB | 200MB | 数据库 (innodb_buffer_pool=128M) |
| Backend | 480MB | 300MB | Spring Boot (Xmx=384m) |
| Redis | 80MB | 40MB | 缓存 (maxmemory=64mb, LRU) |
| Frontend | 64MB | 32MB | Nginx 静态服务 |
| **合计** | **974MB** | **572MB** | — |

预留: OS + 已有容器 ~350MB + 4GB Swap 安全网

## 文件结构

```
deploy-vps/
├── docker-compose.yml        # 服务编排 (OOM 优化)
├── Dockerfile.frontend       # 前端镜像定义
├── nginx-default.conf        # 容器内 Nginx 配置 (SPA + API 代理)
├── nginx-https.conf.template # Host Nginx HTTPS 配置模板 (CF Origin SSL)
├── build.sh                  # 本地构建脚本 (需本地有 Docker)
├── build-on-vps.sh           # VPS 端构建脚本 (自动安装/清理工具)
├── 101_deploy.sh             # VPS 部署/管理脚本
├── setup-https.sh            # HTTPS 一键配置 (复用 0025 逻辑)
├── .env                      # 环境变量 (密码)
├── .env.example              # 环境变量模板
└── README.md                 # 本文档
```

## 快速开始

### 方式一：VPS 上直接构建（推荐）

适用于本地没有 Docker 或资源紧张的场景。VPS 上自动安装构建工具、构建镜像、清理工具。

```bash
# 1. 克隆项目到 VPS
git clone https://gitee.com/kaifangqian/kaifangqian-base.git
cd kaifangqian-base/deploy-vps

# 2. 修改密码
vim .env

# 3. 在 VPS 上构建镜像 (自动安装 Java/Maven/Node.js，构建后可选卸载)
bash 101_deploy.sh build

# 4. 启动服务
bash 101_deploy.sh setup
```

### 方式二：本地构建 + 传输到 VPS

适用于本地有 Docker 的场景。

```bash
# 1. 本地构建镜像
cd deploy-vps
bash build.sh

# 2. 导出镜像
docker save kaifangqian-backend:latest kaifangqian-frontend:latest | gzip > kq-images.tar.gz

# 3. 传输到 VPS
scp kq-images.tar.gz root@<vps-ip>:~/kaifangqian-base/

# 4. SSH 到 VPS 部署
ssh root@<vps-ip>
cd ~/kaifangqian-base/deploy-vps

# 5. 修改密码
vim .env

# 6. 导入镜像 + 启动
bash 101_deploy.sh import
bash 101_deploy.sh setup
```

## HTTPS 配置 (Cloudflare Origin SSL)

部署完成后，使用 HTTPS 配置脚本绑定域名：

```bash
cd ~/kaifangqian-base/deploy-vps
bash setup-https.sh
```

脚本会交互式引导你完成：
1. 输入域名和子域名 (如 `kaifangqian.gameai.dpdns.org`)
2. 自动检测 VPS 公网 IP
3. 本地端口默认 `8806` (前端容器)
4. 从 `cf-domain-cert.md` 读取 CF Origin 证书，或手动粘贴
5. 自动生成 Nginx HTTPS 配置 (443 → 8806)
6. 重启 Nginx

**DNS 配置 (在 Cloudflare)**:
```
类型: A
名称: kaifangqian
内容: <Vps-Ip>
代理状态: 已代理 (橙色云朵)
SSL/TLS: 完全 (严格)
```

配置完成后访问: `https://kaifangqian.gameai.dpdns.org/`

## 访问地址

### HTTP (直接访问, 仅限开发测试)
- 签署主应用: http://<vps-ip>:8806/
- 企业管理端: http://<vps-ip>:8806/manage
- 租户管理: http://<vps-ip>:8806/tenant
- 消息服务: http://<vps-ip>:8806/message
- 移动端: http://<vps-ip>:8806/mobile

### HTTPS (配置完成后)
- 签署主应用: https://kaifangqian.gameai.dpdns.org/
- 企业管理端: https://kaifangqian.gameai.dpdns.org/manage
- 租户管理: https://kaifangqian.gameai.dpdns.org/tenant
- 消息服务: https://kaifangqian.gameai.dpdns.org/message
- 移动端: https://kaifangqian.gameai.dpdns.org/mobile

## 管理命令

```bash
bash 101_deploy.sh build     # 在 VPS 上构建镜像 (自动安装/清理构建工具)
bash 101_deploy.sh setup     # 首次部署 (清理+swap+启动)
bash 101_deploy.sh start     # 启动服务
bash 101_deploy.sh stop      # 停止服务
bash 101_deploy.sh restart   # 重启服务
bash 101_deploy.sh status    # 查看状态和内存使用
bash 101_deploy.sh logs      # 查看日志
bash 101_deploy.sh cleanup   # 清理磁盘空间
bash 101_deploy.sh import    # 导入镜像
bash 101_deploy.sh https     # 配置 HTTPS
```

## OOM 防护措施

1. **硬性内存限制** — 每个容器设置 `deploy.resources.limits.memory`
2. **JVM 内存控制** — G1GC + MaxRAMPercentage=75% + HeapDumpOnOOM
3. **MySQL 轻量化** — innodb_buffer_pool=128M, max_connections=30, 关闭慢查询日志
4. **Redis 淘汰策略** — maxmemory=64mb + allkeys-lru 自动淘汰
5. **Swap 安全网** — 4GB swap + swappiness=10
6. **健康检查** — 所有服务配置 healthcheck，自动重启不健康实例

## 与其他项目共存

本部署方案完全独立，不影响 VPS 上其他 Docker 服务：

| 项目 | 域名 | 端口 | Nginx 配置 |
|------|------|------|-----------|
| pansou | pansou.gameai.dpdns.org | 8888 | 独立配置文件 |
| netdiskplayer | np.gameai.dpdns.org | 5000 | 独立配置文件 |
| **kaifangqian** | **kaifangqian.gameai.dpdns.org** | **8806** | **独立配置文件** |

每个项目通过子域名 + 独立端口 + 独立 Nginx 配置文件完全隔离。

## 注意事项

- 首次启动后端可能需要 60-90 秒初始化
- 建议修改 `.env` 中的默认密码
- 开发测试环境使用，不建议生产环境
- 如果 OOM 频发，可调低后端 Xmx 或增加 VPS 内存
- Host Nginx 配置由 `0025_setup-https.sh` 或 `setup-https.sh` 管理，不影响其他项目
