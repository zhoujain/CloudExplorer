#!/usr/bin/env bash

CURRENT_DIR=$(
   cd "$(dirname "$0")"
   pwd
)

function log() {
   message="[CloudExplorer Log]: $1 "
   echo -e "${message}" 2>&1 | tee -a ${CURRENT_DIR}/install.log
}

args=$@
os=$(uname -a)
docker_config_folder="/etc/docker"
INSTALL_TYPE='install'
if [ -f /usr/bin/cectl ]; then
   # 获取已安装的 CE 的运行目录
   CE_BASE=$(grep "^CE_BASE=" /usr/bin/cectl | cut -d'=' -f2)
   export CE_BASE
   cectl uninstall
fi

set -a
if [[ $CE_BASE ]] && [[ -f $CE_BASE/cloudexplorer/.env ]]; then
   source $CE_BASE/cloudexplorer/.env
   INSTALL_TYPE='upgrade'
else
   source ${CURRENT_DIR}/install.conf
   INSTALL_TYPE='install'
fi
set +a

CE_RUN_BASE=$CE_BASE/cloudexplorer
conf_folder=${CE_RUN_BASE}/conf
templates_folder=${CE_RUN_BASE}/templates
cloudexplorer_conf=${conf_folder}/cloudexplorer.properties
function prop {
   [ -f "$1" ] | grep -P "^\s*[^#]?${2}=.*$" $1 | cut -d'=' -f2
}


echo -e "======================= 开始安装 =======================" 2>&1 | tee -a ${CURRENT_DIR}/install.log


mkdir -p ${CE_RUN_BASE}
cp -r $CURRENT_DIR/cloudexplorer/* ${CE_RUN_BASE}/

cd $CE_RUN_BASE

if [[ $CE_BASE ]] && [[ -f $CE_BASE/cloudexplorer/.env ]]; then
   log "使用原env文件"
else
   cp ${CURRENT_DIR}/install.conf $CE_RUN_BASE/.env
fi

sed -i "s/CE_SERVER_HOST_PLACE_HOLDER/`hostname -I|awk '{print $1}'`/" $CE_RUN_BASE/.env
#替换 CE_BASE=
sed -i -e "s#CE_BASE=.*#CE_BASE=${CE_BASE}#g" $CE_RUN_BASE/.env

source $CE_RUN_BASE/.env

sed -i -e "s#CE_BASE=.*#CE_BASE=${CE_BASE}#g" $CURRENT_DIR/cectl


if [[ "${CE_EXTERNAL_MYSQL}" == "false" ]]; then
  sed -i "s/#health_check_mysql/    depends_on:\n      mysql:\n        condition: service_healthy/" ${CE_BASE}/cloudexplorer/apps/docker-compose-core.yml
fi

\cp $CURRENT_DIR/cectl /usr/local/bin && chmod +x /usr/local/bin/cectl
if [ ! -f /usr/bin/cectl ]; then
  ln -s /usr/local/bin/cectl /usr/bin/cectl 2>/dev/null
fi

chmod g+rwx -R ${CE_RUN_BASE}
chgrp 0 -R ${CE_RUN_BASE}
#chmod 755 ${CE_RUN_BASE}/apps/run-java.sh


#todo touch init.sql 后续做好flyway后实现


if which getenforce && [ $(getenforce) == "Enforcing" ];then
   log  "... 关闭 SELINUX"
   setenforce 0
   sed -i "s/SELINUX=enforcing/SELINUX=disabled/g" /etc/selinux/config
fi

#Install docker & docker-compose
##Install Latest Stable Docker Release
if which docker >/dev/null; then
   log "检测到 Docker 已安装，跳过安装步骤"
   log "启动 Docker "
   service docker start 2>&1 | tee -a ${CURRENT_DIR}/install.log
else
   if [[ -d $CURRENT_DIR/docker ]]; then
      log "... 离线安装 docker"
      cp $CURRENT_DIR/docker/bin/docker/* /usr/bin/
      cp $CURRENT_DIR/docker/service/*.service /etc/systemd/system/
      cp $CURRENT_DIR/docker/service/*.socket /lib/systemd/system/
      chmod +x /usr/bin/docker*
      chmod 754 /etc/systemd/system/docker.service
      chmod 754 /etc/systemd/system/containerd.service
      chmod 754 /lib/systemd/system/docker.socket
      log "... groupadd docker"
      groupadd docker;
      log "... usermod -aG docker $USER"
      usermod -aG docker $USER;
      #log "... newgrp docker"
      #newgrp docker
      log "... 启动 docker"
      systemctl enable docker; systemctl enable containerd; systemctl daemon-reload; service docker start 2>&1 | tee -a ${CURRENT_DIR}/install.log
   else
      log "... 在线安装 docker"
      curl -fsSL https://resource.fit2cloud.com/get-docker-linux.sh -o get-docker.sh 2>&1 | tee -a ${CURRENT_DIR}/install.log
      sudo sh get-docker.sh 2>&1 | tee -a ${CURRENT_DIR}/install.log
      log "... 启动 docker"
      systemctl enable docker; systemctl daemon-reload; service docker start 2>&1 | tee -a ${CURRENT_DIR}/install.log
   fi

   if [ ! -d "$docker_config_folder" ];then
      mkdir -p "$docker_config_folder"
   fi

   docker version >/dev/null
   if [ $? -ne 0 ]; then
      log "docker 安装失败"
      exit 1
   else
      log "docker 安装成功"
   fi
fi

##Install Latest Stable Docker Compose Release
docker-compose version &>/dev/null
if [ $? -ne 0 ]; then
  docker compose version &>/dev/null
  if [ $? -ne 0 ]; then
     if [[ -d $CURRENT_DIR/docker ]]; then
        log "... 离线安装 docker-compose"
        cp $CURRENT_DIR/docker/bin/docker-compose /usr/bin/
        chmod +x /usr/bin/docker-compose
     else
        log "... 在线安装 docker-compose"
        curl -L https://resource.fit2cloud.com/docker/compose/releases/download/v2.16.0/docker-compose-$(uname -s | tr A-Z a-z)-`uname -m` > /usr/local/bin/docker-compose 2>&1 | tee -a ${CURRENT_DIR}/install.log
        chmod +x /usr/local/bin/docker-compose
        ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
     fi

     docker-compose version >/dev/null
     if [ $? -ne 0 ]; then
        log "docker-compose 安装失败"
        exit 1
     else
        log "docker-compose 安装成功"
     fi
  else
     log "检测到 Docker Compose 已安装，跳过安装步骤"
  fi
else
   log "检测到 Docker Compose 已安装，跳过安装步骤"
fi

# 加载镜像
if [[ -d $CURRENT_DIR/images ]]; then
   log "加载镜像"
   for i in $(ls $CURRENT_DIR/images); do
      docker load -i $CURRENT_DIR/images/$i 2>&1 | tee -a ${CURRENT_DIR}/install.log
   done
else
   log "拉取镜像"
   CE_VERSION=$(cat ${CURRENT_DIR}/cloudexplorer/VERSION)
   curl -sfL https://resource.fit2cloud.com/installation-log.sh | sh -s ce ${INSTALL_TYPE} ${CE_VERSION}
   cectl pull
fi

log "配置 cloudexplorer Service"
cp ${CE_RUN_BASE}/bin/cloudexplorer.service /etc/init.d/cloudexplorer
chmod a+x /etc/init.d/cloudexplorer
if which chkconfig;then
   chkconfig --add cloudexplorer
fi

if [ -f /etc/rc.d/rc.local ];then
   cloudexplorerService=$(grep "service cloudexplorer start" /etc/rc.d/rc.local | wc -l)
   if [ "$cloudexplorerService" -eq 0 ]; then
      echo "sleep 10" >> /etc/rc.d/rc.local
      echo "service cloudexplorer start" >> /etc/rc.d/rc.local
   fi
   chmod +x /etc/rc.d/rc.local
fi


if [[ $(grep "vm.max_map_count" /etc/sysctl.conf | wc -l) -eq 0 ]];then
   sysctl -w vm.max_map_count=2000000
   echo "vm.max_map_count=2000000" >> /etc/sysctl.conf
elif (( $(grep "vm.max_map_count" /etc/sysctl.conf | awk -F'=' '{print $2}') < 2000000 ));then
   sysctl -w vm.max_map_count=2000000
   sed -i 's/^vm\.max_map_count.*/vm\.max_map_count=2000000/' /etc/sysctl.conf
fi

if [ $(grep "net.ipv4.ip_forward" /etc/sysctl.conf | wc -l) -eq 0 ];then
   sysctl -w net.ipv4.ip_forward=1
   echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
else
   sed -i 's/^net\.ipv4\.ip_forward.*/net\.ipv4\.ip_forward=1/' /etc/sysctl.conf
fi

if which firewall-cmd >/dev/null; then
   if systemctl is-active firewalld &>/dev/null ;then
      log "防火墙端口开放"
      firewall-cmd --zone=public --add-port=${CE_PORT}/tcp --permanent
      firewall-cmd --reload
   else
      log "防火墙未开启，忽略端口开放"
   fi
fi

http_code=$(curl -siLw "%{http_code}\n" http://localhost:${CE_PORT} -o /dev/null)
if [[ $http_code == 200 ]];then
   log "停止服务进行升级..."
   cectl uninstall
fi

log "启动服务"
cectl reload | tee -a ${CURRENT_DIR}/install.log
cectl status 2>&1 | tee -a ${CURRENT_DIR}/install.log



echo -e "======================= 安装完成 =======================\n" 2>&1 | tee -a ${CURRENT_DIR}/install.log

echo -e "请通过以下方式访问:\n URL: http://\$LOCAL_IP:${CE_PORT}\n 用户名: admin\n 初始密码: cloudexplorer" 2>&1 | tee -a ${CURRENT_DIR}/install.log
