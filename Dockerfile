# syntax=docker/dockerfile:1
#
# 自定义 Caddy 镜像：官方 Caddy + alidns DNS-01 插件 + cache-handler 缓存插件
#
# 多阶段构建：builder 阶段用官方 `-builder` 镜像跑 xcaddy，
# 运行阶段叠在官方 alpine 镜像上（沿用官方目录结构 / CMD）。
#
# 多架构说明：Caddy 和这两个插件都是纯 Go，产物静态无依赖，
# 所以靠 GOARCH 交叉编译就够了，不需要 QEMU 模拟。

ARG CADDY_VERSION=2.11.7

# ============================================================ 编译阶段
# --platform=$BUILDPLATFORM 让编译始终跑在 runner 自己的架构上，
# 再通过 GOARCH 交叉编译出目标架构的二进制。
FROM --platform=$BUILDPLATFORM caddy:${CADDY_VERSION}-builder AS builder

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
    args=""; \
    for p in ${PLUGINS}; do args="${args} --with ${p}"; done; \
    export GOOS=linux; \
    export GOARCH="${TARGETARCH}"; \
    export CGO_ENABLED=0; \
    if [ -n "${TARGETVARIANT}" ]; then export "GOARM=${TARGETVARIANT#v}"; fi; \
    echo "==> xcaddy build${args} [GOARCH=${GOARCH}]"; \
    xcaddy build ${args} --output /usr/bin/caddy; \
    go version -m /usr/bin/caddy > /tmp/modinfo.txt; \
    sed -n '1,3p' /tmp/modinfo.txt; \
    grep -E 'caddy-dns|cache-handler' /tmp/modinfo.txt

# ============================================================ 运行阶段
FROM caddy:${CADDY_VERSION}-alpine

# 用自己编译的二进制覆盖官方的（官方镜像里 caddy 就在 /usr/bin/caddy，
# 且镜像本身没有 ENTRYPOINT，启动方式完全由下面的 CMD 决定）
COPY --from=builder /usr/bin/caddy /usr/bin/caddy

# 官方镜像本身已 EXPOSE 80 / 443 / 443/udp / 2019，这里是额外暴露你用的端口
EXPOSE 9080
EXPOSE 9443

# 与官方镜像的默认 CMD 一致，显式写出来表明启动方式
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
