# 用 GitHub Actions 打包带插件的 Caddy

把「本机装 Go + xcaddy，手动编译 caddy，再 docker build」这套流程搬到 GitHub Actions 上。
以后只需要 push，或者在 Actions 页面点一下，就自动产出：

- **多架构 Docker 镜像**：`ghcr.io/<你>/<仓库>`，`linux/amd64` + `linux/arm64`
- **静态二进制**：`caddy_2.11.7_linux_amd64.tar.gz` / `_arm64`，带 sha256，可直接配 systemd

当前内置两个插件：

| 插件 | 作用 |
| --- | --- |
| `github.com/caddy-dns/alidns` | 阿里云 DNS，走 DNS-01 签证书，**不需要开放 80/443** |
| `github.com/caddyserver/cache-handler` | 反向代理内容缓存 |

---

## 目录结构

```
Dockerfile                     多阶段构建，CI 主流程用这个（自包含，可直接多架构构建）
Dockerfile.prebuilt            你原来那版：COPY 一个本地已编译好的 caddy 二进制
.github/workflows/build.yml    CI 定义
Caddyfile.example              配置示例（含 alidns + cache 的写法）
.dockerignore / .gitignore
```

`Dockerfile` 与 `Dockerfile.prebuilt` 的差别：前者在镜像里跑 xcaddy 自己编译，
后者需要你先在构建上下文里放一个 `caddy` 文件。CI 走的是前者。

---

## 三步跑起来

### 1. 推到 GitHub

```bash
cd /home/chengkni/Software/config/caddy
git init -b main
git add .
git commit -m "自定义 Caddy 构建（alidns + cache-handler）"
```

先在 GitHub 上建一个空仓库（不要勾选初始化 README），然后：

```bash
git remote add origin git@github.com:<你的用户名>/<仓库名>.git
git push -u origin main
```

> 如果你习惯用 `master` 当默认分支，把 `build.yml` 里的 `branches: [main]` 改掉。

### 2. 看 Actions 跑起来

push 上去就会触发一次 "Build custom Caddy"。

注意 `schedule` 和 `workflow_dispatch` 这两个触发方式，**只有 workflow 文件已经存在于默认分支之后才会生效**，
所以第一次可以先靠 push 触发，之后手动触发就有了。

### 3. 把包改成公开

GHCR 的包默认是 **private**。不改的话服务器 `docker pull` 得先 `docker login`。

> GitHub → 右上角头像 → Your packages → 找到这个包 → Package settings → Change visibility → Public

---

## 产物怎么用

### Docker 镜像

每次构建产出的标签：

| 标签 | 含义 |
| --- | --- |
| `caddy-2.11.7` | 固定 caddy 版本，**生产建议用这个** |
| `latest` | 默认分支最新构建 |
| `1.2.3` / `1.2` | 你打 `v1.2.3` tag 时自动生成 |
| `sha-abc1234` | 对应某次提交 |

```bash
docker pull ghcr.io/<你的用户名>/<仓库名>:caddy-2.11.7
```

`docker-compose.yml` 片段（沿用你原来的端口 9080/9443）：

```yaml
services:
  caddy:
    image: ghcr.io/<你的用户名>/<仓库名>:caddy-2.11.7
    container_name: caddy
    restart: unless-stopped
    ports:
      - "9080:9080"
      - "9443:9443"
    environment:
      ALIYUN_ACCESS_KEY_ID: ${ALIYUN_ACCESS_KEY_ID}
      ALIYUN_ACCESS_KEY_SECRET: ${ALIYUN_ACCESS_KEY_SECRET}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data          # 证书存在这里，千万别丢
      - caddy_config:/config

volumes:
  caddy_data:
  caddy_config:
```

### 静态二进制（不用 docker 的场景）

Actions 运行页面底部的 **Artifacts** 里下载 `caddy-linux-amd64`；
如果推的是 `v*` tag，还会自动挂到 Release 上，同时生成 `.sha256`。

```bash
tar xzf caddy_2.11.7_linux_amd64.tar.gz
sha256sum -c caddy_2.11.7_linux_amd64.tar.gz.sha256
sudo install -m 0755 caddy /usr/bin/caddy
/usr/bin/caddy version
```

systemd 单元：

```ini
# /etc/systemd/system/caddy.service
[Unit]
Description=Caddy
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=root
Environment=ALIYUN_ACCESS_KEY_ID=xxx
Environment=ALIYUN_ACCESS_KEY_SECRET=xxx
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

---

## 怎么确认插件真的编进去了

```bash
docker run --rm ghcr.io/<你>/<仓库>:caddy-2.11.7 \
  caddy list-modules | grep -E 'alidns|handlers.cache'
```

应该能看到 `dns.providers.alidns` 和 `http.handlers.cache` 两行。

配置写法见 `Caddyfile.example`，要点：

- `acme_dns alidns { ... }` 放在**全局块**里，对所有站点生效；
  只想给单个站点用，就挪到该站点的 `tls { dns alidns { ... } }` 里
- 凭证用 `{env.ALIYUN_ACCESS_KEY_ID}` 从环境变量读，别写死在文件里
- `cache` 全局块配参数，站点块里 `cache` 放在 `reverse_proxy` **前面**

---

## 常见改动

**加插件** —— 只改一处，`build.yml` 顶部的 `PLUGINS`：

```yaml
PLUGINS: "github.com/caddy-dns/alidns github.com/caddyserver/cache-handler github.com/mholt/caddy-webdav"
```

（`Dockerfile` 里那份默认值也顺手改一下，那只是给本地 `docker build` 用的。）

**锁定插件版本**（避免上游改动把构建搞挂）：

```
github.com/caddy-dns/alidns@v1.1.1
```

**换 Caddy 版本** —— 改 `build.yml` 的 `CADDY_VERSION`，或手动触发时填；
`Dockerfile` 的 `ARG CADDY_VERSION` 默认值同步改一下。

**只要 amd64**（省时间）—— 删掉 `platforms` 里的 `linux/arm64`。

**顺便推 Docker Hub** —— 在仓库 Settings → Secrets 里加 `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`，
然后：

```yaml
      - name: 登录 Docker Hub
        if: github.event_name != 'pull_request'
        uses: docker/login-action@v4
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}
```

再把 metadata 步骤的 `images:` 补一行 `docker.io/<你的dockerhub用户名>/caddy`。

**只要二进制、不要镜像** —— 把 `image` 那个 job 整段删掉即可，`binary` job 是独立的。

---

## 几个已经避开的坑

1. **镜像名必须全小写**，而 `github.repository` 会保留仓库名大小写 —— 所以 workflow 里先用
   `${GITHUB_REPOSITORY,,}` 转小写。注意 `env` 上下文**读不到** `GITHUB_ENV` 写的值，必须用 step output 传。
2. **定时构建会被缓存骗过去**：`xcaddy build` 这条指令没变，Docker 层缓存会直接命中，
   插件根本不会更新。所以定时那一跑加了 `no-cache: true`。
3. **多架构不需要 QEMU**：Caddy 和这两个插件都是纯 Go 产物，靠 `GOARCH` 交叉编译就行
   （xcaddy 没有 `--os/--arch` 参数，它透传 `GOOS/GOARCH/GOARM` 环境变量）。
   所以 Dockerfile 用了 `FROM --platform=$BUILDPLATFORM`，比 QEMU 模拟快得多。
4. **官方 `caddy:alpine` 镜像没有 ENTRYPOINT**，启动完全由 `CMD` 决定，
   所以 `Dockerfile.prebuilt` 里 `rm /usr/bin/caddy` + `COPY` 的做法是成立的。
5. **插件和 caddy 版本要配套**：`cache-handler` 的 `go.mod` 要求 caddy `v2.11.4+`，
   把 caddy 降回旧版本可能编不过。
6. **`packages: write` 权限**：workflow 里已经声明，否则推 GHCR 会 403。
7. **`CGO_ENABLED=0` 的前提是插件都是纯 Go**：现在的 alidns / cache-handler 都是。
   哪天加了依赖 CGO 的插件（比如要用系统库的），得把它改成 `1`，并在 builder 阶段
   `apk add gcc musl-dev`（builder 镜像是 Debian 系，用 `apt-get install gcc`），
   而且那时就不能靠交叉编译了，得把 `--platform=$BUILDPLATFORM` 去掉改用 QEMU。

---

## 本地想先验证一下

```bash
docker buildx build --platform linux/amd64 -t my-caddy:test --load .
docker run --rm my-caddy:test caddy list-modules | grep -E 'alidns|handlers.cache'
```

或者用你原来的流程（`Dockerfile.prebuilt`）：

```bash
# 需要本机有 go 和 xcaddy
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 xcaddy build \
  --with github.com/caddy-dns/alidns \
  --with github.com/caddyserver/cache-handler
docker build -f Dockerfile.prebuilt -t my-caddy:2.11.7 .
```
