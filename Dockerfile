# syntax=docker/dockerfile:1
#
# 自定义 Caddy 镜像：官方 Caddy + alidns DNS-01 插件 + cache-handler 缓存插件
#
# 多阶段构建：builder 阶段用官方 `caddy:builder` 镜像跑 xcaddy，
# 运行阶段叠在官方 `caddy:alpine` 镜像上（沿用官方目录结构 / CMD）。
#
# 为什么用浮动 tag 而不是 `caddy:${CADDY_VERSION}-builder`：
# caddy-docker 发布版本化镜像比 GitHub release 晚十几到几十个小时
# （实测 v2.11.8 01:16 发布，2.11.8-builder 到当天 20:54 才出现），
# 直接用版本化 tag 会在这段时间里必然构建失败。
# 浮动 tag 永远存在，具体编译哪个版本的 Caddy 由 xcaddy 的位置参数决定。
#
# 多架构说明：Caddy 和这两个插件都是纯 Go，产物静态无依赖，
# 所以靠 GOARCH 交叉编译就够了，不需要 QEMU 模拟。

ARG CADDY_VERSION=2.11.7

# ============================================================ 编译阶段
# --platform=$BUILDPLATFORM 让编译始终跑在 runner 自己的架构上，
# 再通过 GOARCH 交叉编译出目标架构的二进制。
# 这个镜像只提供 Go 工具链和 xcaddy，和要编译的 Caddy 版本无关。
FROM --platform=$BUILDPLATFORM caddy:builder AS builder

# 空格分隔的插件清单，CI 通过 --build-arg PLUGINS=... 覆盖（CI 会传带精确版本的列表）。
# 要锁定版本就写成 github.com/caddy-dns/alidns@v1.0.29 这种形式。
ARG PLUGINS="github.com/caddy-dns/alidns github.com/caddyserver/cache-handler"

# CI 传入的构建指纹（caddy 版本 + 各插件版本 + Dockerfile 哈希）。
# 它出现在下面的 RUN 里，所以上游一发新版，这一层的 Docker 缓存就会失效，
# 不会出现「明明该重编、结果命中了旧缓存」的情况。
ARG FINGERPRINT=local

# buildx 在多架构构建时自动注入；单架构构建时为空
ARG TARGETARCH
ARG TARGETVARIANT

# xcaddy 会把 GOOS / GOARCH / GOARM 透传给 go build 完成交叉编译
# （xcaddy 自身没有 --os / --arch 参数，只能靠环境变量）
#
# 收尾用 `go version -m` 而不是 `/usr/bin/caddy version`：多架构构建时，目标架构的
# 二进制是在本机架构上交叉编译出来的，直接执行会失败 —— /bin/sh 会把它当 shell 脚本
# 解析，报 "ELF: not found" / "syntax error: unexpected ("" 然后返回 2。
# `go version -m` 只读文件不执行，任何架构都能用，还能顺带证明插件真的链进去了。
RUN set -eux; \
    echo "==> 构建指纹: ${FINGERPRINT}"; \
    ver="${CADDY_VERSION#v}"; \
    args=""; \
    for p in ${PLUGINS}; do args="${args} --with ${p}"; done; \
    export GOOS=linux; \
    export GOARCH="${TARGETARCH}"; \
    export CGO_ENABLED=0; \
    if [ -n "${TARGETVARIANT}" ]; then export "GOARM=${TARGETVARIANT#v}"; fi; \
    echo "==> xcaddy build v${ver}${args} [GOARCH=${GOARCH}]"; \
    xcaddy build "v${ver}" ${args} --output /usr/bin/caddy; \
    go version -m /usr/bin/caddy > /tmp/modinfo.txt; \
    sed -n '1,5p' /tmp/modinfo.txt; \
    if ! grep -qE "github.com/caddyserver/caddy/v2[[:space:]]+v${ver}([[:space:]]|$)" /tmp/modinfo.txt; then \
      echo "ERROR: 编译出的 Caddy 版本与 CADDY_VERSION=${ver} 不一致"; \
      grep -E 'github.com/caddyserver/caddy/v2' /tmp/modinfo.txt || true; \
      exit 1; \
    fi; \
    grep -E 'caddy-dns|cache-handler' /tmp/modinfo.txt

# ============================================================ 运行阶段
# 同理，这里只需要官方镜像提供的文件系统骨架（alpine、/etc/caddy、/data、
# /config、CA 证书）—— caddy 二进制整个会被下面覆盖，所以基座版本不必与
# 编译出来的 Caddy 版本一致，用浮动 tag 反而不会卡在 Docker 镜像发布延迟上。
FROM caddy:alpine

# 用自己编译的二进制覆盖官方的（官方镜像里 caddy 就在 /usr/bin/caddy，
# 且镜像本身没有 ENTRYPOINT，启动方式完全由下面的 CMD 决定）
COPY --from=builder /usr/bin/caddy /usr/bin/caddy

# 官方镜像本身已 EXPOSE 80 / 443 / 443/udp / 2019，这里是额外暴露你用的端口
EXPOSE 9080
EXPOSE 9443

# 与官方镜像的默认 CMD 一致，显式写出来表明启动方式
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
