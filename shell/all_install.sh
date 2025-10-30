#!/bin/bash
set -euo pipefail

# 初始化配置
LOG_FILE="/var/log/xray_install.log"
TMP_DIR=$(mktemp -d -t xray-install-XXXXXX)
# trap 'rm -rf "$TMP_DIR"' EXIT
startTime=$(date +%Y%m%d-%H:%M)
cleanup() {
  local exit_status=$?
  if [ $exit_status -eq 0 ]; then
    echo "Start Installed at $startTime successfully!" >>~/install.log
    rm -rf "$TMP_DIR"
    rm -rf smartdns.tar.gz smartdns.sh smartdns fastfetch-linux-amd64.deb crontab* bbr.sh install-release.sh caddy_install.sh install_bbr_expect.sh all_install.sh all_install_xray.sh install_bbr.log html1.zip v2rayud.sh
    reboot
  else
    echo "[DEBUG] 捕获退出信号，状态码: $exit_status"
    echo "Start Installed at $startTime failed!" >>~/install.log
    rm -rf "$TMP_DIR"
    rm -rf smartdns.tar.gz smartdns.sh smartdns fastfetch-linux-amd64.deb crontab* bbr.sh install-release.sh caddy_install.sh install_bbr_expect.sh all_install.sh all_install_xray.sh install_bbr.log html1.zip v2rayud.sh

  fi
  exit $exit_status

}
trap cleanup EXIT INT TERM

# 日志记录函数
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# 错误处理函数
die() {
  log "错误: $1"
  exit 1
}

# 架构检测
detect_arch() {
  case $(uname -m) in
  x86_64 | amd64) ARCH="amd64" ARCH_XRAY="64" ARCH_POSH="amd64" ;;
  aarch64) ARCH="aarch64" ARCH_XRAY="arm64-v8a" ARCH_POSH="arm64" ;;
  *) die "不支持的架构: $(uname -m)" ;;
  esac
  log "检测到架构: $ARCH"
}

# 包管理器检测
detect_pkg_mgr() {
  declare -A managers=(
    [apt]="/etc/debian_version"
    # [apt]="/etc/lsb-release"
    [yum]="/etc/redhat-release"
    [dnf]="/etc/fedora-release"
    [dnf]="/etc/almalinux-release"
    [dnf]="/etc/rocky-release"
    [dnf]="/etc/centos-release"
    [zypper]="/etc/SuSE-release"
    [pacman]="/etc/arch-release"
  )

  for mgr in "${!managers[@]}"; do
    if [[ -e ${managers[$mgr]} ]]; then
      PKG_MGR="$mgr"
      break
    fi
  done

  # 额外判断是否为 Ubuntu
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    if [[ $ID == "ubuntu" ]]; then
      PKG_MGR="apt"
    fi
    if [[ $ID == *"suse"* ]]; then
      PKG_MGR="zypper"
    fi
  fi

  [[ -n "$PKG_MGR" ]] || die "无法检测包管理器"
  log "检测到包管理器: $PKG_MGR"
}

# 安装依赖
install_deps() {
  log "安装系统依赖..."
  case $PKG_MGR in
  apt)
    apt update && apt install -y wget vim curl tar gzip jq openssl gnupg2 ca-certificates nginx uuid-runtime python3 python3-venv libaugeas-dev unzip
    python3 -m venv /opt/certbot/
    /opt/certbot/bin/pip install --upgrade pip
    /opt/certbot/bin/pip install certbot certbot-nginx
    ln -sf /opt/certbot/bin/certbot /usr/bin/certbot
    ;;
  yum | dnf)
    $PKG_MGR install -y wget vim curl tar gzip jq openssl ca-certificates nginx unzip python3 augeas-libs
    python3 -m venv /opt/certbot/
    /opt/certbot/bin/pip install --upgrade pip
    /opt/certbot/bin/pip install certbot certbot-nginx
    ln -sf /opt/certbot/bin/certbot /usr/bin/certbot
    ;;
  zypper)
    zypper refresh && zypper update -y
    zypper in -y wget vim curl tar gzip jq openssl ca-certificates nginx unzip python3 augeas
    python3 -m venv /opt/certbot/
    /opt/certbot/bin/pip install --upgrade pip
    /opt/certbot/bin/pip install certbot certbot-nginx
    ln -sf /opt/certbot/bin/certbot /usr/bin/certbot
    ;;
  pacman)
    pacman -Sy
    pacman -S --noconfirm wget vim curl tar gzip jq openssl nginx unzip python3 augeas
    python3 -m venv /opt/certbot/
    /opt/certbot/bin/pip install --upgrade pip
    /opt/certbot/bin/pip install certbot certbot-nginx
    ln -sf /opt/certbot/bin/certbot /usr/bin/certbot
    ;;
  esac || die "依赖安装失败"
}

init_logdirs() {
  chmod -R 777 /var/log/
  mkdir -p /var/log/xray/
  mkdir -p /var/log/nginx
  chmod -R 777 /var/log/xray/
  chmod -R 777 /var/log/nginx
}

# 安装Fastfetch
install_fastfetch() {
  local VERSION TAG_URL="https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest"

  log "获取Fastfetch最新版本..."
  VERSION=$(curl -sSL "$TAG_URL" | jq -r '.tag_name') || die "获取版本失败"

  local URL="https://github.com/fastfetch-cli/fastfetch/releases/download/${VERSION}/fastfetch-linux-${ARCH}.tar.gz"

  log "下载Fastfetch: $URL"
  curl -fSL "$URL" -o "$TMP_DIR/fastfetch-linux-${ARCH}.tar.gz" || die "下载失败"

  tar -xzf "$TMP_DIR/fastfetch-linux-${ARCH}.tar.gz" -C "$TMP_DIR"
  cp "$TMP_DIR/fastfetch-linux-${ARCH}/usr/bin/fastfetch" /usr/bin && chmod +x /usr/bin/fastfetch
  cp -rf "$TMP_DIR/fastfetch-linux-${ARCH}/usr/share/" /usr/share/
  log "Fastfetch ${VERSION} 安装成功"
}

# 安装Xray核心
install_xray() {
  log "获取Xray最新版本..."

  # 服务配置
  detect_init_system() {
    if [[ -d /run/systemd/system ]]; then
      INIT_SYSTEM="systemd"

    elif [[ -f /etc/init.d/cron && -x /usr/sbin/update-rc.d ]]; then
      INIT_SYSTEM="sysvinit"
    else
      die "无法检测初始化系统"
    fi
    log "检测到初始化系统: $INIT_SYSTEM"
  }

  detect_init_system

  case $INIT_SYSTEM in
  systemd)
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --beta
    systemctl daemon-reload
    systemctl enable --now xray
    ;;

  sysvinit)
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --beta
    chmod +x /etc/init.d/xray
    update-rc.d xray defaults
    service xray start
    ;;
  *)
    die "该脚本仅支持systemd的系统安装"
    ;;
  esac

  log "Xray 安装成功"
}

# 配置生成
generate_config() {
  log "生成配置文件..."
  rm -rf /usr/local/etc/xray/*

  wget -N --no-check-certificate https://raw.githubusercontent.com/zcluo/vps/master/shell/config_xray.json -O /usr/local/etc/xray/config.json
  wget -N --no-check-certificate https://raw.githubusercontent.com/zcluo/vps/master/shell/nginx-xray-template.conf -O /etc/nginx/nginx.conf

  log "文件替换..."
  log "NGINX文件替换..."
  # 获取 Nginx 版本号
  nginx_version=$(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9]+\.[0-9]+\.[0-9]+')

  # 定义目标版本
  target_version="1.25.0"

  # 比较版本
  if [[ "$(printf '%s\n' "$nginx_version" "$target_version" | sort -V | tail -n 1)" == "$nginx_version" ]]; then
    log "Nginx 版本 ($nginx_version) 高于或等于 $target_version"
    sed -i "s/xxx\.xxxxxx\.xxx/$1/g" /etc/nginx/nginx.conf
  else
    log "Nginx 版本 ($nginx_version) 低于 $target_version"
    sed -i "s/xxx\.xxxxxx\.xxx/$1/g" /etc/nginx/nginx.conf
    sed -i '/http2  on;/ s/^/#/' /etc/nginx/nginx.conf
  fi
  sed -i "s/xxx\.xxxxxx\.xxx/$1/g" /etc/nginx/nginx.conf
  sed -i "s/xxx\.xxxxxx\.xxx/$1/g" /usr/local/etc/xray/config.json
  sed -i "s/trojanpass/$3/g" /usr/local/etc/xray/config.json
  sed -i "s/xxx\@xxx\.xxx/$4/g" /usr/local/etc/xray/config.json
  sed -i "s/xxxxxxxx\-xxxx\-xxxx\-xxxx\-xxxxxxxxxxxx/$5/g" /usr/local/etc/xray/config.json
  sed -i "s/realityprivatekey/$6/g" /usr/local/etc/xray/config.json
  sed -i "s/port_grpc/$7/g" /usr/local/etc/xray/config.json
  sed -i "s/port_tcp/$8/g" /usr/local/etc/xray/config.json
  sed -i "s/port_xhttp/$9/g" /usr/local/etc/xray/config.json
  sed -i "s/xhttp_decryption/${10}/g" /usr/local/etc/xray/config.json
  sed -i "s/xhttp_mldsa65seed/${11}/g" /usr/local/etc/xray/config.json
  mkdir -p /var/log/xray
  chmod -R 777 /var/log/xray/

}

install_ohmyposh() {
  cd ~ || exit
  #bash install_ohmyposh.sh
  wget https://github.com/JanDeDobbeleer/oh-my-posh/releases/latest/download/posh-linux-${ARCH_POSH} -O /usr/local/bin/oh-my-posh
  chmod +x /usr/local/bin/oh-my-posh

  mkdir -p ~/themes
  wget https://github.com/JanDeDobbeleer/oh-my-posh/releases/latest/download/themes.zip -O ~/themes/themes.zip
  unzip -o ~/themes/themes.zip -d ~/themes
  chmod u+rw ~/themes/*.omp.*
  rm ~/themes/themes.zip
}

generate_cron() {
  log "新增更新定时任务..."
  cd ~ || exit
  wget -N --no-check-certificate https://raw.githubusercontent.com/zcluo/vps/master/shell/xrayud.sh -O ~/xrayud.sh
  chmod +x xrayud.sh
  echo "0 1 * * * bash xrayud.sh" > crontab.bak
  crontab crontab.bak
}

init_bashrc() {
  BASHINIT_FILE=~/.bashrc
  # 额外判断是否为 Ubuntu
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    if [[ $ID == "arch" ]]; then
      BASHINIT_FILE=~/.bash_profile
    fi
  fi
  echo '[ -z "$PS1" ] && return' >>$BASHINIT_FILE
  echo 'eval "$(oh-my-posh --init --shell bash --config /root/themes/1_shell.omp.json)"' >>$BASHINIT_FILE
  echo "clear" >>$BASHINIT_FILE
  echo "fastfetch" >>$BASHINIT_FILE
  # 计算包含 "fastfetch" 的行数
  fastfetch_count=$(grep -c "fastfetch" $BASHINIT_FILE)

  # 判断是否有多余的 "fastfetch" 行
  if [ "$fastfetch_count" -ge 2 ]; then
    # 获取文件总行数
    total_lines=$(wc -l <$BASHINIT_FILE)

    # 计算需要删除的行范围
    start_line=$((total_lines - 4 + 1))
    end_line=$total_lines

    # 删除多余的行
    sed -i "${start_line},${end_line}d" $BASHINIT_FILE
  fi
}

enable_service() {
  case $INIT_SYSTEM in
  systemd) systemctl enable xray && systemctl enable nginx ;;

  sysvinit) chkconfig xray on && chkconfig nginx on ;;
  esac
}

restart_service() {
  case $INIT_SYSTEM in
  systemd) systemctl restart xray && systemctl restart nginx ;;

  sysvinit) service xray restart && service nginx restart ;;
  esac
}

stop_service() {
  case $INIT_SYSTEM in
  systemd) systemctl stop xray && systemctl stop nginx ;;

  sysvinit) service xray stop && service nginx stop ;;
  esac
}

apply_cert() {
  stop_service
  certbot certonly --standalone -d "$1" -m "$4" --agree-tos -n
  chmod -R 777 /etc/letsencrypt
}

fake_website() {
  cd ~ || exit
  mkdir -p /var/www/html
  wget -N --no-check-certificate https://raw.githubusercontent.com/zcluo/vps/master/shell/html1.zip
  unzip -o html1.zip -d /var/www/html

  dd if=/dev/urandom of=/var/www/html/test bs=100M count=1 iflag=fullblock
}

usage() {
  echo "USAGE: $0 domain_name username password emailaddress uuid realityprivkey grpc_port tcp_port xhttp_port xhttp_decryption xhttp_mldsa65seed"
  echo " e.g.: $0 abbc.com user_a password aa@abbc.com $(uuidgen) realityprivkey 8001 9001 7001 xhttp_decryption xhttp_mldsa65seed"
}

# 主安装流程
main() {
  usage "$@"
  [[ $# -eq 11 ]] || die "参数数量错误"

  log "探测CPU架构..."
  detect_arch
  log "探测安装器..."
  detect_pkg_mgr
  log "初始化日志目录..."
  init_logdirs
  log "安装依赖..."
  install_deps
  log "安装fastfetch..."
  install_fastfetch
  log "安装XRAY..."
  install_xray
  log "生成配置文件..."
  generate_config "$@"

  log "证书申请..."
  apply_cert "$@"

  log "假网站..."
  fake_website

  log "开启服务..."
  enable_service

  log "重启服务..."
  restart_service

  log "安装oh-my-posh..."
  install_ohmyposh

  log "初始化.bashrc..."
  init_bashrc

  log "安装定时更新任务..."
  generate_cron

  log "安装完成! "
}

main "$@"
