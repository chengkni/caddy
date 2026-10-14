# 用 GitHub Actions 打包带插件的 Caddy

把「本机装 Go + xcaddy，手动编译 caddy，再 docker build」这套流程搬到 GitHub Actions 上。
定时轮询上游，**Caddy 或任一插件发新版就自动重编**；也可以随时手动触发。产出：

- **多架构 Docker 镜像**：`ghcr.io/chengkni/caddy`，`linux/amd64` + `linux/arm64`
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

本地仓库和首次提交**已经做好了**。提交作者用的是 `chengkni@users.noreply.github.com`，
不会泄露真实邮箱；你的全局 git 配置没有被改动。

你只需要在 GitHub 上建一个**空仓库**（不要勾选 "Add a README" / .gitignore / license，否则 push 会冲突），然后：

```bash
cd /home/chengkni/Software/config/caddy
git remote add origin git@github.com:chengkni/<仓库名>.git
git push -u origin main
```

> 如果你习惯用 `master` 当默认分支，把 `build.yml` 里的 `branches: [main]` 改掉。

### 2. 看 Actions 跑起来

push 上去就会触发一次 "Build custom Caddy"。

注意 `schedule` 和 `workflow_dispatch` 这两个触发方式，**只有 workflow 文件已经存在于默认分支之后才会生效**，
所以第一次可以先靠 push 触发，之后手动触发就有了。

### 3. 把包改成公开（可选）

GHCR 的包**默认是 private**，这跟仓库本身是公开还是私有无关。不改的话服务器 `docker pull` 得先 `docker login`。

> GitHub → 右上角头像 → Your packages → 找到这个包 → Package settings → Change visibility → Public

⚠️ **这一步不可逆**：包改成 public 之后就再也改不回 private 了。不过里面只是 Caddy + 两个开源插件，公开没风险。

**仓库本身建议建 public**：标准 runner 在公开仓库上免费用、不计分钟数；私有仓库则走 Free 计划的
2,000 分钟/月额度（本方案一次完整构建约 10~15 分钟，而且日常只有上游真发新版才会编译，
即便私有也远够用）。仓库里没有任何机密 —— `Caddyfile.example` 全是 `{env.*}` 占位符，
凭证由你自己在服务器上通过环境变量注入。

---

## 产物怎么用

### Docker 镜像

每次构建产出的标签：

| 标签 | 含义 |
| --- | --- |
| `caddy-2.11.7` | 固定 caddy 版本，**生产建议用这个** |
| `fp-17ad3f8164aa` | 构建指纹，用来判断「这套输入是否已经构建过」（见下节） |
| `latest` | 默认分支最新构建 |
| `1.2.3` / `1.2` | 你打 `v1.2.3` tag 时自动生成 |
| `sha-abc1234` | 对应某次提交 |

```bash
docker pull ghcr.io/chengkni/caddy:caddy-2.11.7
```

`docker-compose.yml` 直接用仓库里的 [`docker-compose.example.yml`](docker-compose.example.yml)（沿用你原来的端口 9080/9443）：

```bash
cp docker-compose.example.yml docker-compose.yml
cp Caddyfile.example Caddyfile          # 改里面的域名

cat > .env <<'EOF'                       # .env 已在 .gitignore 里，不会被提交
ALIYUN_ACCESS_KEY_ID=LTAI...
ALIYUN_ACCESS_KEY_SECRET=...
EOF

docker compose up -d
```

三个要点：

- **`/data` 卷千万不能丢** —— 证书都在里面，丢了每次重启都会重新签发，很容易撞上
  Let's Encrypt 的签发频率限制（每域名每周 5 次）。compose 里已经声明成命名卷。
- **改完 Caddyfile 不用重启容器**：`docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile`
  （官方镜像没有 ENTRYPOINT，所以这里要重复写一遍 `caddy` 子命令）。
- **锁版本 还是 用 `latest`，取决于你要「可控」还是「省心」。** 注意 `latest` **不会自己更新** ——
  Docker 不会主动去比对远端，仍然要 `docker compose pull` 才生效，区别只是 pull 到的是「当时最新的那个」，
  具体版本得事后 `docker compose exec caddy caddy version` 去问。所以 `latest` 是拿确定性换省心，
  而不是拿确定性换自动化。真想要全自动就加 `pull_policy: always`（每次 `up`/重启都去拉），
  代价是某次重启后行为可能就和之前不一样了。
  好消息是两种用法都随时可回滚：每次构建都留了 `caddy-<版本>` 和 `fp-<指纹>` 标签，
  把 image 改回上一个 `caddy-2.11.x` 再 `up -d` 即可。

### 静态二进制（不用 docker 的场景）

**去 Releases 页面拿，不要用 Actions 的 Artifacts。** 两者差别很大：

| | Actions 的 Artifacts | Release 的 Assets |
| --- | --- | --- |
| 是否需要登录 | **必须登录**（公开仓库也一样） | 匿名可下载 |
| 有效期 | 90 天后自动删除 | 永久 |
| 位置 | 某次 run 页面最底部 | 仓库右侧 Releases |

每次构建都会自动发一个以 Caddy 版本命名的 Release（tag 形如 `caddy-2.11.7`），
里面是 `amd64` / `arm64` 两个 `.tar.gz` 加各自的 `.sha256`。固定下载地址：

```
https://github.com/chengkni/caddy/releases/download/caddy-2.11.7/caddy_2.11.7_linux_amd64.tar.gz
https://github.com/chengkni/caddy/releases/download/caddy-2.11.7/caddy_2.11.7_linux_arm64.tar.gz
```

想拿最新版，直接看 `https://github.com/chengkni/caddy/releases/latest`（GitHub 会自动
指向最新那个 Release）。你自己推 `v*` tag 时，同样两个文件也会额外挂到那个 tag 的 Release 上。

> Artifacts 里下载到的是个 ZIP，里面才是 `.tar.gz`（两层压缩）；Release 的 Assets 是直接给 `.tar.gz`。

```bash
curl -fLO https://github.com/chengkni/caddy/releases/download/caddy-2.11.7/caddy_2.11.7_linux_amd64.tar.gz
curl -fLO https://github.com/chengkni/caddy/releases/download/caddy-2.11.7/caddy_2.11.7_linux_amd64.tar.gz.sha256
sha256sum -c caddy_2.11.7_linux_amd64.tar.gz.sha256
tar xzf caddy_2.11.7_linux_amd64.tar.gz
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
docker run --rm ghcr.io/chengkni/caddy:caddy-2.11.7 \
  caddy list-modules | grep -E 'alidns|handlers.cache'
```

应该能看到 `dns.providers.alidns` 和 `http.handlers.cache` 两行。

配置写法见 `Caddyfile.example`，要点：

- `acme_dns alidns { ... }` 放在**全局块**里，对所有站点生效；
  只想给单个站点用，就挪到该站点的 `tls { dns alidns { ... } }` 里
- 凭证用 `{env.ALIYUN_ACCESS_KEY_ID}` 从环境变量读，别写死在文件里
- `cache` 全局块配参数，站点块里 `cache` 放在 `reverse_proxy` **前面**

---

## 什么时候会自动构建

`check` job（很轻，几秒钟，不编译任何东西）先算出「构建指纹」，再去 GHCR 查这个指纹的镜像是否已存在：

```
指纹 = caddy 版本 + 每个插件解析出的确切版本 + Dockerfile 的 sha256
```

各触发方式的行为：

| 触发 | 行为 |
| --- | --- |
| 定时（默认每 6 小时） | 上游 Caddy 或任一插件发新版 → 指纹变了 → 自动构建 |
| push 到 main | 同上；输入没变就跳过，不白烧额度 |
| 手动 Run workflow | **无条件构建**，可临时填 `caddy_version` 指定版本 |
| 打 `v*` tag | **无条件构建**，并把二进制挂到 Release |
| Pull request | 只验证能编过，不推送镜像 |

另外，**除 PR 外每次成功构建都会把二进制发成一个 `caddy-<版本>` 的 Release**（匿名可下载、不过期），
所以「拿到能直接用的二进制」这件事不依赖你手动打 tag。

### 每 6 小时一次，会不会白烧资源？

**不会。每 6 小时跑的是「探测」，不是「构建」。** 探测 job 只有十几秒：查一次上游版本号、
问一次 Go module proxy、去 GHCR 看一眼那个指纹的镜像在不在。指纹没变的话，`image` 和
`binary` 两个 job 直接整个跳过，一行编译都不会执行。

上游实际发版频率（最近 12 个月实测）：

| 项目 | 发版次数 |
| --- | --- |
| `caddyserver/caddy` | 8 |
| `caddy-dns/alidns` | 7 |
| `caddyserver/cache-handler` | 1 |
| **合计** | **约 16 次/年** |

一年 1,460 次探测里，真正触发构建的**大约只有 16 次**，其余 1,444 次都在几秒内跳过。
这正是指纹机制存在的意义 —— 否则一年会白白产出 1,460 个内容完全相同的镜像。

消耗方面：

- **Actions 分钟**：公开仓库的标准 runner 免费不计费，探测本身零成本。
  私有仓库才计分钟，探测约 120 分钟/月（每天 4 次 × 每次 1 分钟计费下限），Free 计划 2,000 分钟/月够用。
- **镜像存储**：**公开包的存储和流量都免费**。每个镜像约 41 MB（amd64）/ 38.5 MB（arm64），
  按一年 16 个版本累计约 1.3 GB，不花你钱。
- 想更省，把 cron 从每 6 小时改成 12 或 24 小时即可，代价只是发现新版本慢半天。

> 如果哪天把仓库改成私有：镜像存储会走 500 MB 免费额度（且与 Actions artifacts 共享），
> 一年 16 个版本约 1.3 GB 就会超。那时在 Packages 页面删掉旧的 `fp-*` 标签即可释放空间 ——
> 代价仅仅是那个指纹「查不到已构建过」，下次探测会重新编译一次。

插件版本是问 Go module proxy 的 `@latest` 拿到的 —— 那正是 xcaddy 实际会拉取的版本，
比查 GitHub release 更准（仓库没发 release 时也能拿到提交伪版本号）。解析出的版本会
**带精确版本号传给 xcaddy**，所以同一个镜像标签永远对应同一份代码，构建可复现。

想改轮询频率就改 `build.yml` 里的 cron（**UTC**）：

```yaml
  schedule:
    - cron: "23 */6 * * *"    # 每 6 小时；改 "23 */12 * * *" 就是每 12 小时
```

> GitHub 的定时任务是「尽力而为」，高峰期可能延迟甚至跳过，别指望它精确到分钟。
> 真要立刻出镜像，直接用 Actions 页面上的 Run workflow。

---

## 常见改动

**加插件** —— 只改一处，`build.yml` 顶部的 `PLUGINS`：

```yaml
PLUGINS: "github.com/caddy-dns/alidns github.com/caddyserver/cache-handler github.com/mholt/caddy-webdav"
```

（`Dockerfile` 里那份默认值也顺手改一下，那只是给本地 `docker build` 用的。）

**锁定插件版本**（避免上游改动把构建搞挂）：在 `PLUGINS` 里加 `@版本号` 即可，
这个插件就不会再被自动跟进：

```
github.com/caddy-dns/alidns@v1.0.29
```

**换 Caddy 版本** —— 平时不用管，定时任务自动跟上游最新 release。
手动触发时可以在表单里填 `caddy_version` 指定；`build.yml` 里的 `FALLBACK_CADDY_VERSION`
只是查上游 API 失败时的兜底值。`Dockerfile` 的 `ARG CADDY_VERSION` 默认值只影响本地 `docker build`。

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
2. **Docker 层缓存会骗过定时构建**：`xcaddy build` 那行指令文本没变的话，层缓存会直接命中，
   插件根本没更新，但镜像照样被打上新标签 —— 变成「假装构建过了」。
   解决办法是把版本信息喂进缓存键：CI 传的 `PLUGINS` 带精确版本号，外加一个出现在 `RUN` 里的
   `FINGERPRINT` 参数，二者一变该层缓存立即失效。这比 `no-cache: true` 那种一刀切的做法精确得多。
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
   `apk add gcc musl-dev` —— 注意 builder 镜像 `caddy:2.11.7-builder` 是
   **`FROM golang:1.27-alpine3.24`，Alpine/musl 系**，用 `apk` 不是 `apt`。
   而且那时就不能靠交叉编译了，得把 `--platform=$BUILDPLATFORM` 去掉改用 QEMU。
8. **别在多架构构建里执行产物**：交叉编译出的 arm64 二进制在 amd64 容器里跑不了，
   `/bin/sh` 会把它当 shell 脚本解析，报 `ELF: not found` / `syntax error: unexpected "("`
   并以 exit code 2 失败 —— 而且报错信息里完全看不出是"架构不对"，很容易误判成编译失败。
   所以校验要用 `go version -m <二进制>`（只读文件、不执行，任何架构都能用，
   还能顺带打印出链进去的插件版本）。
9. **`docker run` 写出的文件属主是 root**：runner 不是 root，所以挂载目录里那个二进制
   直接 `chmod +x` 会 Permission denied（exit 1）。要先 `sudo chown "$(id -u):$(id -g)"`。

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
