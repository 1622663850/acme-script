#!/bin/bash
# acme-script: persistent-menu-v1

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN='\033[0m'

red(){
    echo -e "\033[31m\033[01m$1\033[0m"
}

green(){
    echo -e "\033[32m\033[01m$1\033[0m"
}

yellow(){
    echo -e "\033[33m\033[01m$1\033[0m"
}

REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora")
PACKAGE_UPDATE=("apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update")
PACKAGE_INSTALL=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "yum -y install")
PACKAGE_REMOVE=("apt -y remove" "apt -y remove" "yum -y remove" "yum -y remove" "yum -y remove")
PACKAGE_UNINSTALL=("apt -y autoremove" "apt -y autoremove" "yum -y autoremove" "yum -y autoremove" "yum -y autoremove")

[[ $EUID -ne 0 ]] && red "注意：请在root用户下运行脚本" && exit 1

if [[ -r /etc/os-release ]]; then
    . /etc/os-release
fi

CMD=(
    "${PRETTY_NAME:-}"
    "$(hostnamectl 2>/dev/null | sed -n 's/^[[:space:]]*Operating System:[[:space:]]*//p')"
    "$(lsb_release -sd 2>/dev/null | tr -d '\"')"
    "$(grep -i '^DISTRIB_DESCRIPTION=' /etc/lsb-release 2>/dev/null | sed 's/^[^=]*=//; s/^"//; s/"$//')"
    "$(cat /etc/redhat-release 2>/dev/null)"
    "$(head -n 1 /etc/issue 2>/dev/null)"
)

for i in "${CMD[@]}"; do
    SYS="$i"
    if [[ -n $SYS ]]; then
        break
    fi
done

for ((int = 0; int < ${#REGEX[@]}; int++)); do
    if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
        SYSTEM="${RELEASE[int]}" && [[ -n $SYSTEM ]] && break
    fi
done

[[ -z $SYSTEM ]] && red "不支持当前VPS系统, 请使用主流的操作系统" && exit 1

check_ip(){
    ipv4=$(curl -s4m8 ip.sb -k | sed -n 1p)
    ipv6=$(curl -s6m8 ip.sb -k | sed -n 1p)
}

install_acme_direct() {
    local email="$1" installer
    installer=$(mktemp) || { red "创建临时文件失败"; return 1; }

    yellow "正在从官方渠道安装 acme.sh..."
    if ! curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 \
        "https://get.acme.sh" -o "$installer"; then
        rm -f "$installer"
        red "官方安装脚本下载失败，请重试或选择代理安装"
        return 1
    fi

    if ! sh "$installer" "email=$email"; then
        rm -f "$installer"
        red "acme.sh 官方安装失败"
        return 1
    fi
    rm -f "$installer"

    # 官方模式启用 acme.sh 自动升级；升级失败不影响已完成的安装。
    if ! bash "$HOME/.acme.sh/acme.sh" --upgrade --auto-upgrade; then
        yellow "自动升级配置未完成，可稍后执行 acme.sh --upgrade --auto-upgrade"
    fi
}

install_acme_proxy() {
    local email="$1" tmp_dir archive_url acme_bin
    local proxy_url="https://gh.dpik.top/"

    archive_url="${proxy_url}https://github.com/acmesh-official/acme.sh/archive/master.tar.gz"
    yellow "正在通过 GitHub 代理下载 acme.sh: $proxy_url"
    yellow "注意：第三方下载代理可能不可用，且需要您信任该代理服务。"

    tmp_dir=$(mktemp -d) || { red "创建临时目录失败"; return 1; }
    if ! curl -fL --retry 3 --connect-timeout 15 --max-time 180 \
        "$archive_url" -o "$tmp_dir/master.tar.gz"; then
        rm -rf "$tmp_dir"
        red "代理下载失败，请检查代理地址或网络"
        return 1
    fi

    if ! tar -xzf "$tmp_dir/master.tar.gz" -C "$tmp_dir" || \
       [[ ! -f "$tmp_dir/acme.sh-master/acme.sh" ]]; then
        rm -rf "$tmp_dir"
        red "acme.sh 压缩包解压失败或缺少安装文件"
        return 1
    fi

    if ! (cd "$tmp_dir/acme.sh-master" && bash ./acme.sh --install -m "$email"); then
        rm -rf "$tmp_dir"
        red "acme.sh 代理安装失败"
        return 1
    fi
    rm -rf "$tmp_dir"

    # 尽量让后续 GitHub 源码升级也走代理，若上游变更需重新适配。
    acme_bin="$HOME/.acme.sh/acme.sh"
    if [[ -f "$acme_bin" ]] && \
       grep -Fq 'PROJECT="https://github.com/acmesh-official/$PROJECT_NAME"' "$acme_bin"; then
        if ! sed -i \
            's#PROJECT="https://github.com/acmesh-official/$PROJECT_NAME"#PROJECT="https://gh.dpik.top/https://github.com/acmesh-official/$PROJECT_NAME"#' \
            "$acme_bin"; then
            yellow "安装已完成，但设置后续升级代理失败"
        fi
    else
        yellow "安装已完成，但当前 acme.sh 版本的升级地址结构不匹配，无法保证升级走代理"
    fi
    yellow "代理模式未自动启用 acme.sh 自身的自动升级（不影响证书自动续期）"
}

inst_acme() {
    local install_mode="${1:-direct}" email automail
    if [[ "$install_mode" != "direct" && "$install_mode" != "proxy" ]]; then
        red "未知的安装方式"
        return 1
    fi

    if [[ "$SYSTEM" != "CentOS" ]]; then
        ${PACKAGE_UPDATE[int]}
    fi
    ${PACKAGE_INSTALL[int]} curl wget sudo socat openssl dnsutils tar || return 1

    if [[ "$SYSTEM" == "CentOS" ]]; then
        ${PACKAGE_INSTALL[int]} cronie || return 1
        systemctl start crond
        systemctl enable crond
    else
        ${PACKAGE_INSTALL[int]} cron || return 1
        systemctl start cron
        systemctl enable cron
    fi

    read -rp "请输入注册邮箱 (例: admin@gmail.com, 或留空自动生成一个gmail邮箱): " email
    if [[ -z "$email" ]]; then
        automail=$(date +%s%N | md5sum | cut -c 1-16)
        email="$automail@gmail.com"
        yellow "未填写邮箱，使用自动生成的邮箱: $email"
    fi

    if [[ "$install_mode" == "proxy" ]]; then
        install_acme_proxy "$email" || return 1
    else
        install_acme_direct "$email" || return 1
    fi

    if ! bash "$HOME/.acme.sh/acme.sh" -v >/dev/null 2>&1; then
        red "安装结束，但未检测到可用的 acme.sh"
        return 1
    fi

    source "$HOME/.bashrc" 2>/dev/null || true
    green "acme.sh 安装成功！"
    switch_provider
}

install_menu() {
    local choice
    echo ""
    echo -e " ${GREEN}1.${PLAIN} 官方直连安装 acme.sh"
    echo -e " ${GREEN}2.${PLAIN} 通过 GitHub 代理安装 acme.sh ${YELLOW}(gh.dpik.top)${PLAIN}"
    echo -e " ${GREEN}0.${PLAIN} 返回"
    read -rp "请选择安装方式 [0-2]: " choice
    case "$choice" in
        1) inst_acme direct ;;
        2) inst_acme proxy ;;
        0) return 1 ;;
        *) red "无效选项"; return 1 ;;
    esac
}

ensure_acme() {
    if [[ -f "$HOME/.acme.sh/acme.sh" ]] && \
       bash "$HOME/.acme.sh/acme.sh" -v >/dev/null 2>&1; then
        return 0
    fi
    yellow "未安装 acme.sh，请先选择安装方式"
    install_menu
}

unst_acme() {
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && yellow "未安装Acme.sh, 卸载程序无法执行!" && exit 1
    ~/.acme.sh/acme.sh --uninstall
    sed -i '/--cron/d' /etc/crontab >/dev/null 2>&1
    rm -rf ~/.acme.sh
    green "Acme.sh 证书一键申请脚本已彻底卸载!"
}

check_80(){
    # 感谢Wulabing前辈提供的检查80端口思路
    # Source: https://github.com/wulabing/Xray_onekey
    
    if [[ -z $(type -P lsof) ]]; then
        if [[ ! $SYSTEM == "CentOS" ]]; then
            ${PACKAGE_UPDATE[int]}
        fi
        ${PACKAGE_INSTALL[int]} lsof
    fi
    
    yellow "正在检测 80 端口是否占用..."
    sleep 1
    
    if [[  $(lsof -i:"80" | grep -i -c "listen") -eq 0 ]]; then
        green "检测到目前 80 端口未被占用"
        sleep 1
    else
        red "检测到目前 80 端口被其他程序被占用，以下为占用程序信息"
        lsof -i:"80"
        read -rp "如需结束占用进程请按Y，按其他键则退出 [Y/N]: " yn
        if [[ $yn =~ "Y"|"y" ]]; then
            lsof -i:"80" | awk '{print $2}' | grep -v "PID" | xargs kill -9
            sleep 1
        else
            exit 1
        fi
    fi
}

checktls() {
    if [[ -f /root/cert.crt && -f /root/private.key ]]; then
        if [[ -s /root/cert.crt && -s /root/private.key ]]; then
            if [[ -n $(type -P wg-quick) && -n $(type -P wgcf) ]]; then
                wg-quick up wgcf >/dev/null 2>&1
            fi
            if [[ -a "/opt/warp-go/warp-go" ]]; then
                systemctl start warp-go 
            fi

            echo $domain > /root/ca.log
            sed -i '/--cron/d' /etc/crontab >/dev/null 2>&1
            echo "0 0 * * * root bash /root/.acme.sh/acme.sh --cron -f >/dev/null 2>&1" >> /etc/crontab

            green "证书申请成功! 脚本申请到的证书 (cert.crt) 和私钥 (private.key) 文件已保存到 /root 文件夹下"
            yellow "证书 crt 文件路径如下: /root/cert.crt"
            yellow "私钥 key 文件路径如下: /root/private.key"
        else
            if [[ -n $(type -P wg-quick) && -n $(type -P wgcf) ]]; then
                wg-quick up wgcf >/dev/null 2>&1
            fi
            if [[ -a "/opt/warp-go/warp-go" ]]; then
                systemctl start warp-go 
            fi

            red "抱歉，证书申请失败"
            green "建议如下: "
            yellow "1. 自行检测防火墙是否打开, 如使用 80 端口申请模式时, 请关闭防火墙或放行 80 端口"
            yellow "2. 同一域名多次申请可能会触发 Let's Encrypt 官方风控, 请尝试使用脚本菜单的 9 选项更换证书颁发机构, 再重试申请证书, 或更换域名、或等待 7 天后再尝试执行脚本"
            yellow "3. 脚本可能跟不上时代, 建议截图发布到 GitHub Issues、GitLab Issues、论坛或 TG 群询问"
        fi
    fi
}

acme_standalone(){
    ensure_acme || return 1

    check_80

    WARPv4Status=$(curl -s4m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
    WARPv6Status=$(curl -s6m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
    if [[ $WARPv4Status =~ on|plus ]] || [[ $WARPv6Status =~ on|plus ]]; then
        wg-quick down wgcf >/dev/null 2>&1
        systemctl stop warp-go >/dev/null 2>&1
    fi
    
    check_ip
    
    echo ""
    yellow "在使用 80 端口申请模式时, 请先将您的域名解析至你的 VPS 的真实 IP 地址, 否则会导致证书申请失败"
    echo ""
    if [[ -n $ipv4 && -n $ipv6 ]]; then
        echo -e "VPS 的真实 IPv4 地址为: ${GREEN}$ipv4${PLAIN}"
        echo -e "VPS 的真实 IPv6 地址为: ${GREEN}$ipv6${PLAIN}"
    elif [[ -n $ipv4 && -z $ipv6 ]]; then
        echo -e "VPS 的真实 IPv4 地址为: ${GREEN}$ipv4${PLAIN}"
    elif [[ -z $ipv4 && -n $ipv6 ]]; then
        echo -e "VPS 的真实 IPv6 地址为: ${GREEN}$ipv6${PLAIN}"
    fi
    echo ""

    read -rp "请输入解析完成的域名: " domain
    [[ -z $domain ]] && red "未输入域名，无法执行操作！" && exit 1
    green "已输入的域名：$domain" && sleep 1

    domainIP=$(dig @8.8.8.8 +time=2 +short "$domain" 2>/dev/null | sed -n 1p)
    if echo $domainIP | grep -q "network unreachable\|timed out" || [[ -z $domainIP ]]; then
        domainIP=$(dig @2001:4860:4860::8888 +time=2 aaaa +short "$domain" 2>/dev/null | sed -n 1p)
    fi
    if echo $domainIP | grep -q "network unreachable\|timed out" || [[ -z $domainIP ]] ; then
        red "未解析出 IP，请检查域名是否输入有误" 
        yellow "是否尝试强行匹配？"
        green "1. 是，将使用强行匹配"
        green "2. 否，退出脚本"
        read -p "请输入选项 [1-2]：" ipChoice
        if [[ $ipChoice == 1 ]]; then
            yellow "将尝试强行匹配以申请域名证书"
        else
            red "将退出脚本"
            exit 1
        fi
    fi
    
    if [[ $domainIP == $ipv6 ]]; then
        bash ~/.acme.sh/acme.sh --issue -d ${domain} --standalone -k ec-256 --listen-v6 --insecure
    fi
    if [[ $domainIP == $ipv4 ]]; then
        bash ~/.acme.sh/acme.sh --issue -d ${domain} --standalone -k ec-256 --insecure
    fi
    
    if [[ -n $(echo $domainIP | grep nginx) ]]; then
        if [[ -n $(type -P wg-quick) && -n $(type -P wgcf) ]]; then
            wg-quick up wgcf >/dev/null 2>&1
        fi
        if [[ -a "/opt/warp-go/warp-go" ]]; then
            systemctl start warp-go 
        fi
        yellow "域名解析失败, 请检查域名是否正确填写或等待解析完成再执行脚本"
        exit 1
    elif [[ -n $(echo $domainIP | grep ":") || -n $(echo $domainIP | grep ".") ]]; then
        if [[ $domainIP != $ipv4 ]] && [[ $domainIP != $ipv6 ]]; then
            if [[ -n $(type -P wg-quick) && -n $(type -P wgcf) ]]; then
                wg-quick up wgcf >/dev/null 2>&1
            fi
            if [[ -a "/opt/warp-go/warp-go" ]]; then
                systemctl start warp-go 
            fi
            green "域名 ${domain} 目前解析的IP: ($domainIP)"
            red "当前域名解析的 IP 与当前 VPS 使用的真实IP不匹配"
            green "建议如下："
            yellow "1. 请确保 CloudFlare 小云朵为关闭状态 (仅限DNS), 其他域名解析或 CDN 网站设置同理"
            yellow "2. 请检查 DNS 解析设置的 IP 是否为 VPS 的真实 IP"
            yellow "3. 脚本可能跟不上时代, 建议截图发布到 GitHub Issues、GitLab Issues、论坛或 TG 群询问"
            exit 1
        fi
    fi
    
    bash ~/.acme.sh/acme.sh --install-cert -d ${domain} --key-file /root/private.key --fullchain-file /root/cert.crt --ecc
    checktls
}

acme_cfapiTLD(){
    ensure_acme || return 1

    read -rp "请输入需要申请证书的域名: " domain
    [[ -z $domain ]] && red "未输入域名，无法执行操作！" && exit 1

    if [[ $(echo ${domain:0-2}) =~ cf|ga|gq|ml|tk ]]; then
        red "检测为 Freenom 免费域名, 由于 CloudFlare API 不支持, 故无法使用本模式申请!"
        exit 1
    fi

    echo ""
    yellow "请在 Cloudflare 创建 API Token，并至少授予：Zone:Read、DNS:Edit 权限"
    read -rp "请输入 CloudFlare API Token: " cftoken
    [[ -z $cftoken ]] && red "未输入 CloudFlare API Token, 无法执行操作!" && exit 1

    # 使用新的 API Token 鉴权方式
    unset CF_Key
    unset CF_Email
    export CF_Token="$cftoken"

    # Account ID / Zone ID 都是可选项
    read -rp "请输入 CloudFlare Account ID（可留空）: " cfaccountid
    if [[ -n $cfaccountid ]]; then
        export CF_Account_ID="$cfaccountid"
    else
        unset CF_Account_ID
    fi

    read -rp "请输入 CloudFlare Zone ID（可留空）: " cfzoneid
    if [[ -n $cfzoneid ]]; then
        export CF_Zone_ID="$cfzoneid"
    else
        unset CF_Zone_ID
    fi

    echo ""
    yellow "正在通过 Cloudflare API Token 申请证书..."

    if bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d "${domain}" -k ec-256 --debug; then
        bash ~/.acme.sh/acme.sh --install-cert -d "${domain}" \
            --key-file /root/private.key \
            --fullchain-file /root/cert.crt \
            --ecc
        checktls
    else
        red "Cloudflare DNS 验证失败，证书未生成。"
        red "请检查 API Token 权限、Zone 范围以及域名是否已托管到 Cloudflare。"
        return 1
    fi
}

acme_cfapiNTLD(){
    ensure_acme || return 1

    read -rp "请输入需要申请证书的泛域名 (输入格式：example.com): " domain
    [[ -z $domain ]] && red "未输入域名，无法执行操作！" && exit 1

    if [[ $(echo ${domain:0-2}) =~ cf|ga|gq|ml|tk ]]; then
        red "检测为 Freenom 免费域名, 由于 CloudFlare API 不支持, 故无法使用本模式申请!"
        back2menu
    fi

    echo ""
    yellow "请在 Cloudflare 创建 API Token，并至少授予：Zone:Read、DNS:Edit 权限"
    read -rp "请输入 CloudFlare API Token: " cftoken
    [[ -z $cftoken ]] && red "未输入 CloudFlare API Token, 无法执行操作！" && exit 1

    # 使用新的 API Token 鉴权方式
    unset CF_Key
    unset CF_Email
    export CF_Token="$cftoken"

    # Account ID / Zone ID 都是可选项
    read -rp "请输入 CloudFlare Account ID（可留空）: " cfaccountid
    if [[ -n $cfaccountid ]]; then
        export CF_Account_ID="$cfaccountid"
    else
        unset CF_Account_ID
    fi

    read -rp "请输入 CloudFlare Zone ID（可留空）: " cfzoneid
    if [[ -n $cfzoneid ]]; then
        export CF_Zone_ID="$cfzoneid"
    else
        unset CF_Zone_ID
    fi

    echo ""
    yellow "正在通过 Cloudflare API Token 申请泛域名证书..."

    if bash ~/.acme.sh/acme.sh --issue --dns dns_cf \
        -d "*.${domain}" \
        -d "${domain}" \
        -k ec-256 \
        --debug; then

        bash ~/.acme.sh/acme.sh --install-cert -d "*.${domain}" \
            --key-file /root/private.key \
            --fullchain-file /root/cert.crt \
            --ecc
        checktls
    else
        red "Cloudflare DNS 验证失败，证书未生成。"
        red "请检查 API Token 权限、Zone 范围以及域名是否已托管到 Cloudflare。"
        return 1
    fi
}

view_cert(){
    ensure_acme || return 1
    bash ~/.acme.sh/acme.sh --list
}

revoke_cert() {
    ensure_acme || return 1

    bash ~/.acme.sh/acme.sh --list
    read -rp "请输入要撤销的域名证书 (复制 Main_Domain 下显示的域名): " domain
    [[ -z $domain ]] && red "未输入域名，无法执行操作!" && exit 1

    if [[ -n $(bash ~/.acme.sh/acme.sh --list | grep $domain) ]]; then
        bash ~/.acme.sh/acme.sh --revoke -d ${domain} --ecc
        bash ~/.acme.sh/acme.sh --remove -d ${domain} --ecc

        rm -rf ~/.acme.sh/${domain}_ecc
        rm -f /root/cert.crt /root/private.key

        green "撤销 ${domain} 的域名证书成功"
    else
        red "未找到 ${domain} 的域名证书, 请检查后重新运行!"
    fi
}

renew_cert() {
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && yellow "未安装acme.sh, 无法执行操作!" && exit 1
    bash ~/.acme.sh/acme.sh --cron -f
}

switch_provider(){
    ensure_acme || return 1

    yellow "请选择证书提供商, 默认通过 Letsencrypt.org 来申请证书 "
    yellow "如果证书申请失败, 例如一天内通过 Letsencrypt.org 申请次数过多, 可选 BuyPass.com 或 ZeroSSL.com 来申请."
    echo -e " ${GREEN}1.${PLAIN} Letsencrypt.org ${YELLOW}(默认)${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} BuyPass.com"
    echo -e " ${GREEN}3.${PLAIN} ZeroSSL.com"
    read -rp "请选择证书提供商 [1-3]: " provider
    case $provider in
        2) bash ~/.acme.sh/acme.sh --set-default-ca --server buypass && green "切换证书提供商为 BuyPass.com 成功！" ;;
        3) bash ~/.acme.sh/acme.sh --set-default-ca --server zerossl && green "切换证书提供商为 ZeroSSL.com 成功！" ;;
        *) bash ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt && green "切换证书提供商为 Letsencrypt.org 成功！" ;;
    esac
}

menu() {
    local menuInput _menu_pause
    while true; do
        clear
         echo "#############################################################"
        echo -e "#                   ${RED}Acme  证书一键申请脚本${PLAIN}                  #"
        echo -e "# ${GREEN}作者${PLAIN}: 1622663850                                          #"
        echo -e "# ${GREEN}GitHub 项目${PLAIN}: https://github.com/1622663850/acme-script    #"
        echo "#############################################################"
        echo ""
        echo -e " ${GREEN}1.${PLAIN} 安装 Acme.sh 域名证书申请脚本 ${YELLOW}(官方/代理)${PLAIN}"
        echo -e " ${GREEN}2.${PLAIN} ${RED}卸载 Acme.sh 域名证书申请脚本${PLAIN}"
        echo " -------------"
        echo -e " ${GREEN}3.${PLAIN} 申请单域名证书 ${YELLOW}(80端口申请)${PLAIN}"
        echo -e " ${GREEN}4.${PLAIN} 申请单域名证书 ${YELLOW}(CF API申请)${PLAIN} ${GREEN}(无需解析)${PLAIN} ${RED}(不支持freenom域名)${PLAIN}"
        echo -e " ${GREEN}5.${PLAIN} 申请泛域名证书 ${YELLOW}(CF API申请)${PLAIN} ${GREEN}(无需解析)${PLAIN} ${RED}(不支持freenom域名)${PLAIN}"
        echo " -------------"
        echo -e " ${GREEN}6.${PLAIN} 查看已申请的证书"
        echo -e " ${GREEN}7.${PLAIN} 撤销并删除已申请的证书"
        echo -e " ${GREEN}8.${PLAIN} 手动续期已申请的证书"
        echo -e " ${GREEN}9.${PLAIN} 切换证书颁发机构"
        echo " -------------"
        echo -e " ${GREEN}0.${PLAIN} 退出脚本"
        echo ""
        read -rp "请输入选项 [0-9]: " menuInput || return 0
        case "$menuInput" in
            1 ) ( install_menu ) || true ;;
            2 ) ( unst_acme ) || true ;;
            3 ) ( acme_standalone ) || true ;;
            4 ) ( acme_cfapiTLD ) || true ;;
            5 ) ( acme_cfapiNTLD ) || true ;;
            6 ) ( view_cert ) || true ;;
            7 ) ( revoke_cert ) || true ;;
            8 ) ( renew_cert ) || true ;;
            9 ) ( switch_provider ) || true ;;
            0 ) return 0 ;;
            * ) red "无效选项，请输入 0–9。" ;;
        esac
        read -rp "按回车键返回 ACME 证书菜单..." _menu_pause || return 0
    done
}

menu
