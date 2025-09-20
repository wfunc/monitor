# wfunc Monitor

一个针对 Ubuntu/Linux 服务器的轻量级资源监控与告警工具，使用 Go 开发。默认支持 CPU、内存、磁盘使用率以及 CPU I/O wait，超过自定义阈值即通过 Webhook 发送告警。

## 功能概览

- 周期性采样 CPU、内存、磁盘占用
- 计算 CPU I/O wait 百分比，及时发现磁盘/IO 阻塞
- 自定义阈值与采样间隔，可通过 CLI 或环境变量配置
- 通过 Webhook 推送 JSON Payload，同时在控制台打印 `Webhook Payload: map[...]`
- 提供 systemd service 与安装脚本，便于长期运行
- GitHub Actions 自动构建 Release 包（Linux AMD64/ARM64）

## 快速开始

```bash
# 本地运行（请务必设置 --webhook-url，否则仅在控制台提示）
go run . \
  --webhook-url="https://example.com/webhook" \
  --cpu=80 --mem=80 --disk=80 --io-wait=30 \
  --disk-path=/ --interval=15s
```

启动时若未配置 `--webhook-url`，程序会提示并跳过远端告警发送。

### 主要 CLI 参数

| 参数 | 说明 |
| ---- | ---- |
| `--cpu` | CPU 使用率告警阈值（%）|
| `--mem` | 内存使用率告警阈值（%）|
| `--disk` | 指定路径的磁盘使用率告警阈值（%）|
| `--disk-path` | 要监控的磁盘路径（默认 `/`）|
| `--io-wait` | CPU I/O wait 阈值（%），设为 `<=0` 可关闭 |
| `--interval` | 采样间隔，Go duration格式，例如 `10s`、`1m` |
| `--webhook-url` | Webhook 端点地址，未配置时不会发送远端告警 |
| `--service-name`/`--alert-type` 等 | 用于 Webhook Payload 中的元数据 |

## systemd 部署

1. 复制 `systemd/monitor.service` 到 `/etc/systemd/system/monitor.service`
2. 将 `systemd/monitor.env.example` 拷贝到 `/etc/default/monitor` 并按需修改
   ```bash
   sudo cp systemd/monitor.service /etc/systemd/system/monitor.service
   sudo cp systemd/monitor.env.example /etc/default/monitor
   sudo vim /etc/default/monitor  # 设置 MONITOR_WEBHOOK_URL 等变量
   ```
3. 创建专用用户（可选）：`sudo useradd --system --home-dir /opt/wfunc-monitor --shell /usr/sbin/nologin monitor`
4. 构建并部署可执行文件到 `/usr/local/bin/monitor`
5. 启动并设置开机自启
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now monitor.service
   ```

## 一键安装脚本

服务器上执行（需 root 权限）：

```bash
curl -fsSL https://raw.githubusercontent.com/wfunc/monitor/main/install.sh | sudo bash
```

安装流程：
- 自动安装 `git`、`golang-go`（若缺失）
- 克隆仓库到 `/opt/wfunc-monitor`
- 创建 `monitor` 系统用户
- 构建二进制并安装 systemd unit & `/etc/default/monitor`
- 默认不会发送告警，请编辑 `/etc/default/monitor` 设置 `MONITOR_WEBHOOK_URL`

## Release 打包

本地快速打包（输出到 `dist/`）：

```bash
./scripts/package_release.sh 0.1.0
```

脚本会为 Linux `amd64` 与 `arm64` 交叉编译，生成包含 `monitor`、`install.sh` 与 systemd 配置的 `tar.gz` 包，同时产出 `checksums.txt`。

### GitHub Actions

`.github/workflows/release.yml` 会在：
- 推送 `v*.*.*` 标签时自动运行
- 或手动触发（需输入版本号）

流程将运行 `go test`, 调用 `scripts/package_release.sh` 构建产物，并发布 GitHub Release。

## 开发与测试

```bash
go fmt ./...
go test ./...
```

调试时可直接运行：

```bash
go run . --webhook-url=http://localhost:8080/mock
```

## 配置说明

`/etc/default/monitor`（或 CLI 参数）中的关键变量：

- `MONITOR_CPU_THRESHOLD`、`MONITOR_MEM_THRESHOLD`、`MONITOR_DISK_THRESHOLD`
- `MONITOR_IOWAIT_THRESHOLD` — I/O wait 告警阈值
- `MONITOR_INTERVAL` — 采样周期
- `MONITOR_WEBHOOK_URL` — 必填，告警发送地址
- `MONITOR_SERVICE_NAME`、`MONITOR_ALERT_TYPE`、`MONITOR_ALERT_STATUS` 等元数据

## 许可证

暂未指定许可证，可在提交到 GitHub 时按需添加。
