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

## 证书密钥类型（ECC / RSA）

主菜单 **3、4、5** 的所有证书申请方式均支持以下密钥类型：

| 选项 | 类型 | acme.sh 参数 |
| --- | --- | --- |
| 1（默认） | ECC P-256 | `--keylength ec-256` |
| 2 | RSA 2048 | `--keylength 2048` |
| 3 | RSA 4096 | `--keylength 4096` |

如需 Let's Encrypt RSA 2048 证书：

1. 主菜单选择 **9**，然后选择 **1**（Let's Encrypt）。
2. 主菜单选择 **4**（Cloudflare API Token 单域名证书），密钥类型选择 **2**。
3. 按提示输入域名、API Token 以及可选的 Account ID / Zone ID。

证书安装路径：

| 类型 | 证书链 | 私钥 |
| --- | --- | --- |
| ECC（兼容历史路径） | `/root/cert.crt` | `/root/private.key` |
| RSA 单域名 | `/root/certs/<域名>/rsa/cert.crt` | `/root/certs/<域名>/rsa/private.key` |
| RSA 泛域名 | `/root/certs/<根域名>/wildcard/rsa/cert.crt` | `/root/certs/<根域名>/wildcard/rsa/private.key` |

ECC 与 RSA 可以在 acme.sh 中同时存在，独立续期，RSA 导出不会覆盖历史 ECC 文件。为兼容旧调用方，ECC 仍使用共享的历史导出路径；如果有多张 ECC 证书，请勿让它们同时续期到这组共享文件。RSA 2048 和 RSA 4096 共享同一域名的 RSA 槽位，切换长度会重新签发而非同时保存两张 RSA 证书。已有同类型证书未到续期时间时会安装现有证书；如需更换已有证书的 CA，请在切换 CA 后按需重新签发，切勿误撤销正在使用的证书。

主菜单 **7** 撤销时选择 ECC 或 RSA，并仅处理所选域名和密钥类型。主菜单 **8** 保留手动强制续期全部证书的行为；自动续期改用 acme.sh 自带的每日到期检查，不再每天强制签发。新安装证书成功后会尝试配置 acme.sh 定时任务并迁移本脚本的旧任务。

网站服务需要加载新证书和私钥，并在续期后重新加载；脚本不会自动修改 Lucky、Caddy 或其他网站配置。RSA 证书链长度取决于 CA 签发的实际证书链，密钥类型不保证达到指定长度。

## 菜单返回

安装成功、取消安装、输入无效或操作失败后，按回车回到 ACME 主菜单。只有在主菜单选择 **0** 才正常退出；关闭终端输入也会结束菜单。每次操作在独立子进程中执行，内部的 `exit` 不会直接退出主菜单，也不会自动重试安装或证书操作。

菜单返回契约为 `persistent-menu-v1`，可供 sing-box-manager 等入口识别；主菜单正常退出返回 `0`，操作失败不会作为退出菜单的信号。运行 `bash -n acme_cf_token.sh` 和 `python3 -m unittest discover -s tests -v` 可验证语法、返回流程和 ECC/RSA 证书操作，测试不会实际安装 acme.sh 或向 CA 申请证书。

**注意：** GitHub 代理是第三方服务，只有在信任该服务时才应选择代理安装。代理方式仅用于下载 acme.sh，并尝试修改其 GitHub 升级地址；**Cloudflare API、证书签发和 DNS 验证请求不会自动走代理**。代理模式不自动启用 acme.sh 本体的自动升级，与证书自动续期无关。

代理版 `acme_cf_token_proxy_all.sh` 已合并，统一使用 `acme_cf_token.sh`。
