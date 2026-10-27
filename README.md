# acme-script

通过 acme.sh 一键申请、安装和续期 HTTPS 证书，支持 Cloudflare API Token 的 DNS 验证及 80 端口验证。

## 运行脚本

```bash
wget -N --no-check-certificate https://raw.githubusercontent.com/1622663850/acme-script/main/acme_cf_token.sh && bash acme_cf_token.sh
```

## 安装方式

主菜单选择 **1. 安装 Acme.sh** 后，可选择：

- **1. 官方直连安装**：通过 `https://get.acme.sh` 安装，并尝试启用 acme.sh 自动升级。
- **2. 通过 GitHub 代理安装**：经 `https://gh.dpik.top/` 获取 acme.sh 源码安装，适用于无法直连 GitHub 的服务器。
- **0. 返回**：退出安装子菜单。

其他主菜单编号保持不变。未安装 acme.sh 时直接申请证书，也会提示选择安装方式。

## 菜单返回

安装成功、取消安装、输入无效或操作失败后，按回车回到 ACME 主菜单。只有在主菜单选择 **0** 才正常退出；关闭终端输入也会结束菜单。每次操作在独立子进程中执行，内部的 `exit` 不会直接退出主菜单，也不会自动重试安装或证书操作。

菜单返回契约为 `persistent-menu-v1`，可供 sing-box-manager 等入口识别；主菜单正常退出返回 `0`，操作失败不会作为退出菜单的信号。运行 `bash -n acme_cf_token.sh` 和 `python3 -m unittest discover -s tests -v` 可验证语法和返回流程，测试不会实际安装或申请证书。

**注意：** GitHub 代理是第三方服务，只有在信任该服务时才应选择代理安装。代理方式仅用于下载 acme.sh，并尝试修改其 GitHub 升级地址；**Cloudflare API、证书签发和 DNS 验证请求不会自动走代理**。代理模式不自动启用 acme.sh 本体的自动升级，与证书自动续期无关。

代理版 `acme_cf_token_proxy_all.sh` 已合并，统一使用 `acme_cf_token.sh`。
