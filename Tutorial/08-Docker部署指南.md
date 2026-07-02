# 08 · Docker 部署指南

> 把 CE-Lite 部署到服务器有两条路：**官方离线包（最快）** 与 **源码自建镜像（适合二次开发）**。本章分别给出完整步骤。

## 部署模型（先理解再动手）

无论哪条路，运行时架构都一样：

```
              ┌──────────────────────────────────────┐
              │  cloudexplorer-core 容器（1 个）       │
              │   ┌─────────┐ ┌────────┐ ┌──────────┐ │
   :9000 ───► │   │ gateway │ │ eureka │ │ mgmt-ctr │ │  ← 三个 jar 同容器
              │   └─────────┘ └────────┘ └──────────┘ │
              └────────┬──────────────┬───────────────┘
                       │              │
              ┌────────▼──────┐  ┌────▼─────┐  ┌──────────┐
              │  MySQL (外部)  │  │ Redis    │  │ ES(可选) │
              │  ce / ce_quartz│  │ db=2     │  │          │
              └────────────────┘  └──────────┘  └──────────┘
                       ▲
              ┌────────┴────────┐
              │ apps/extra/*.jar │  ← vm-service 等业务模块（core 自动加载）
              └─────────────────┘
```

关键事实（来自仓库源码 `run-core.sh` + `cloudexplorer.properties`）：

- **一个 core 容器**内跑 eureka(8761) + gateway(9000) + management-center(9010) 三个进程。
- **MySQL / Redis / ES 是外部依赖**，core 镜像不含它们。官方离线包会额外起 mysql/redis/elk 容器；源码自建则需自己提供。
- 业务模块（vm-service 等）以 jar 形式放在 `/opt/cloudexplorer/apps/extra/`，core 启动时按 `modules` 清单自动拉起。

## 仓库里的三个构建脚本（仅"源码自建"路径用到）

| 脚本 | 作用 | 产出 |
|----|----|----|
| `build-core-image.sh` | 把 eureka+gateway+management-center 三 jar 打进 `cloudexplorer-core` 镜像并 push | 镜像 `${CE_IMAGE_REPOSITORY}cloudexplorer-core:${ver}` |
| `build-core-docker-compose.sh` | 生成跑该镜像的 `docker-compose-core.yml` | `target/docker-compose-core.yml` |
| `build-service-packages.sh` | 把 services/ 下各模块打成 tar.gz（jar + yml + modules 清单） | `target/services/*.tar.gz` |

> 这三个脚本是**构建/发布**用的，不是给部署者一键拉起的。端到端部署者请优先用官方离线包。

---

## 路径 A：官方离线包一键部署（推荐）

适合"只想把它跑起来用"。全程在**目标服务器**执行，不需从源码编译。

### A.1 环境要求

- Ubuntu 22.04（推荐）或 CentOS 7，64 位
- 8 核 / 16G 内存 / 200G 磁盘
- 已安装 Docker 与 docker-compose

### A.2 下载安装包

下载页：<https://community.fit2cloud.com/#/products/cloudexplorer-lite/downloads>

选 `cloudexplorer-offline-installer-v1.x.y-x86_64.tar.gz`，上传到服务器 `/tmp`：

```bash
cd /tmp
tar -zxvf cloudexplorer-offline-installer-v1.x.y-x86_64.tar.gz
cd cloudexplorer-offline-installer-v1.x.y-x86_64
```

### A.3（可选）修改 `.env`

默认值可直接装；要改端口或换外部数据库时才改：

| 参数 | 默认 | 说明 |
|----|----|----|
| `CE_PORT` | 80 | 对外端口 |
| `CE_EXTERNAL_MYSQL` | false | 默认自带 MySQL 8.0 |
| `CE_EXTERNAL_REDIS` | false | 默认自带 Redis |
| `CE_DOCKER_SUBNET` | 172.20.0.0/16 | Docker 网段 |
| `CE_DOCKER_GATEWAY` | 172.20.0.1 | Docker 网关 |

> 强烈建议**不要**把安装包所在路径当安装目录，脚本默认装到 `/opt/cloudexplorer`。

### A.4 执行安装

```bash
bash install.sh
```

安装脚本内部就是拉起一组 docker-compose（core + mysql + redis + elk）。

### A.5 访问

- 地址：`http://服务器IP:80`（或你设的 `CE_PORT`）
- 用户名：`admin`
- 密码：`cloudexplorer`

### A.6 常用运维

```bash
cd /opt/cloudexplorer
docker compose ps              # 查看容器状态
docker compose logs -f         # 跟踪日志
docker compose down            # 停止
docker compose up -d           # 启动
```

自带的 MySQL / Redis 凭据（默认）：

| 组件 | 库/端口 | 用户 | 密码 |
|----|----|----|----|
| MySQL 8.0 | 库 `ce` | root | `Password123@mysql` |
| Redis | 6379 | — | `Password123@redis` |

---

## 路径 B：源码自建镜像部署（适合二次开发）

适合"改了代码，要打自己的镜像发上去"。

### B.1 本地构建产物

需 JDK17 + Maven + Node：

```bash
mvn initialize                 # 装 VMware 依赖（首次）
mvn clean package -DskipTests  # 编译后端，产物在 target/
yarn install && yarn build     # 构建前端（会被打进 jar）
```

### B.2 构建 core 镜像

`build-core-image.sh` 会 **push 到你指定的镜像仓库**，所以需先有仓库（或改成 `--load` 本地加载）：

```bash
export build_with_platform=linux/amd64
export CE_IMAGE_REPOSITORY=registry.example.com/your-namespace/
# 可选：自定义版本号，默认取 pom.xml 里的 revision
# export revision=v1.0.0

bash build-core-image.sh
```

> 想本地加载而不推送：把脚本里 `--push` 改成 `--load`（仅单平台时可用）。

### B.3 打业务模块包

```bash
bash build-service-packages.sh
# 产出 target/services/*.tar.gz（vm-service 等）
# 每个 tar.gz 含：模块 jar + app.yml + modules 清单
```

### B.4 生成 docker-compose

```bash
export CE_IMAGE_REPOSITORY=registry.example.com/your-namespace/
bash build-core-docker-compose.sh
# 产出 target/docker-compose-core.yml
```

生成的 compose 文件挂载了 conf/logs/data/extra/downloads，并读 `.env`。

### B.5 服务器上准备外部依赖

core 容器**不含** MySQL/Redis/ES，需自行提供。在服务器建目录与配置：

```bash
mkdir -p /opt/cloudexplorer/{conf,logs,apps/extra,data,downloads}
```

把仓库里这两个文件拷到 `/opt/cloudexplorer/conf/`：
- `doc/cloudexplorer/conf/cloudexplorer.properties`
- `doc/cloudexplorer/conf/redisson.yml`

再在 `/opt/cloudexplorer/.env` 写入（值换成你的实际依赖）：

```env
CE_BASE=/opt
CE_PORT=9000
CE_CORE_MEMORY_LIMIT=8G

# 业务库
CE_MYSQL_HOST=mysql_host
CE_MYSQL_PORT=3306
CE_MYSQL_DB=ce
CE_MYSQL_USER=root
CE_MYSQL_PASSWORD=Password123@mysql

# Quartz 库
CE_QUARTZ_MYSQL_HOST=mysql_host
CE_QUARTZ_MYSQL_PORT=3306
CE_QUARTZ_MYSQL_DB=ce_quartz
CE_QUARTZ_MYSQL_USER=root
CE_QUARTZ_MYSQL_PASSWORD=Password123@mysql

# Redis
CE_REDIS_HOST=redis_host
CE_REDIS_PORT=6379
CE_REDIS_PASSWORD=Password123@redis

# ES（可选）
CE_ELASTICSEARCH_HOST=http://es_host:9200
CE_JWT_EXPIRE_MINUTES=100
```

建库（MySQL 端执行）：

```sql
CREATE DATABASE `ce` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE DATABASE `ce_quartz` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
```

### B.6 拉起 core

```bash
cd /opt/cloudexplorer
# 把 B.4 生成的 docker-compose-core.yml 放这里
docker compose -f docker-compose-core.yml up -d
```

健康检查：`curl -f 127.0.0.1:9000`（gateway 端口）。

### B.7 加载业务模块

把 B.3 产出的各 `*.tar.gz` 解压到 `/opt/cloudexplorer/apps/extra/`（jar + `模块名-版本.yml` + `modules` 清单文件）。core 容器的 `run-core.sh` 会读取 `modules` 清单自动拉起这些 jar。然后重启 core 容器：

```bash
docker compose -f docker-compose-core.yml restart
```

### B.8 访问

- 地址：`http://服务器IP:9000`（gateway 端口，即 `CE_PORT`）
- 用户名：`admin` / 密码：`cloudexplorer`

---

## 两条路径对比

| | 官方离线包 | 源码自建 |
|----|----|----|
| 速度 | ⭐⭐⭐⭐⭐ 几分钟 | ⭐⭐ 需编译 + 配依赖 |
| MySQL/Redis/ES | 自带 | 自行提供 |
| 适合 | 体验 / 生产使用 | 改了代码 / 自定义镜像 |
| 镜像来源 | 官方预构建 | 你 push 到私有仓库 |
| 业务模块 | 已内置 | 手动放 apps/extra |

## 常见问题

- **端口冲突**：`CE_PORT`（默认 80 或 9000）被占用时改 `.env`。
- **MySQL 连不上**：用外部 MySQL 时，`CE_EXTERNAL_MYSQL=true` 并核对 `.env` 里的 host/port/密码；库要预先建好且字符集 utf8mb4。
- **Redis database=2**：`redisson.yml` 固定用 db 2，别和其他应用冲突。
- **业务模块没起来**：检查 `/opt/cloudexplorer/apps/extra/modules` 清单格式 `名称|端口|版本`，以及对应 jar 是否存在（见 `run-core.sh` 的 `runExtra`）。
- **内存不够**：core 容器默认上限 8G（`CE_CORE_MEMORY_LIMIT`），16G 机器够用；再不够就升配。
- **架构问题**：`build-core-image.sh` 的 `build_with_platform` 必传，ARM 服务器用 `linux/arm64`，并确认基础镜像 `alpine-openjdk17` 有对应架构。
