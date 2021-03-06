#!/bin/bash

source variable.sh

setenforce 0
systemctl stop firewalld
systemctl disable firewalld
echo "Settng NTP"

sed -i "s/pool 2.centos.pool.ntp.org iburst/pool 0.id.pool.ntp.org/" /etc/chrony.conf

echo "Installing openstack ussuri"
yum -y install centos-release-openstack-ussuri
yum -y install epel-release

echo "INSTALL MARIADB"
yum -y install mariadb-server
cat <<- EOF > /etc/my.cnf
[client-server]

!includedir /etc/my.cnf.d

[mysqld]
max_connections=8192
EOF

systemctl restart mariadb
systemctl enable mariadb

mysql_secure_installation <<EOF

n
y
n
y
y
EOF

systemctl restart mariadb

echo "INSTALL MEMCHACHED"

yum -y install memcached
cat <<- EOF > /etc/sysconfig/memcached
PORT="11211"
USER="memcached"
MAXCONN="1024"
CACHESIZE="64"
OPTIONS="-l 0.0.0.0,::"
EOF

systemctl restart memcached
systemctl enable memcached
systemctl start memcached.service
systemctl enable memcached.service

yum -y install rabbitmq-server
systemctl start rabbitmq-server.service
systemctl enable rabbitmq-server.service
rabbitmqctl add_user openstack password
rabbitmqctl set_permissions openstack ".*" ".*" ".*"

# KEYSTONE

echo "Starting installation of Keystone"
dnf config-manager --set-enabled powertools
dnf --enablerepo=powertools -y install fontawesome-fonts-web
yum -y install openstack-keystone python3-openstackclient httpd mod_ssl python3-mod_wsgi python3-oauth2client
setsebool -P httpd_use_openstack on 
setsebool -P httpd_can_network_connect on
setsebool -P httpd_can_network_connect_db on

mysql <<- EOF
CREATE DATABASE keystone;
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '$KEYSTONE_DBPASS';
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '$KEYSTONE_DBPASS';
flush privileges;
EOF

sed -i "s/#memcache_servers = localhost:11211/memcache_servers = $IP:11211/" /etc/keystone/keystone.conf
sed -i "s|#connection = <None>|connection = mysql+pymysql://keystone:password@$IP/keystone|" /etc/keystone/keystone.conf
sed -i "s/#provider = fernet/provider = fernet/" /etc/keystone/keystone.conf

echo "Sync with database"
su -s /bin/bash keystone -c "keystone-manage db_sync"

echo "Keystone-manage,initialize key"
cd /etc/keystone/
keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
keystone-manage credential_setup --keystone-user keystone --keystone-group keystone

echo "Bootstrap Keystone"

keystone-manage bootstrap --bootstrap-password $ADMIN_PASS \
--bootstrap-admin-url http://$IP:5000/v3/ \
--bootstrap-internal-url http://$IP:5000/v3/ \
--bootstrap-public-url http://$IP:5000/v3/ \
--bootstrap-region-id RegionOne

echo "Configure "
ln -s /usr/share/keystone/wsgi-keystone.conf /etc/httpd/conf.d/

systemctl start httpd
systemctl enable httpd

cat <<- EOF > $ADMIN_USER_FILE
#!/bin/sh
export OS_PROJECT_DOMAIN_NAME=default
export OS_USER_DOMAIN_NAME=default
export OS_PROJECT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=$ADMIN_PASS
export OS_AUTH_URL=http://$IP:5000/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
export PS1='[\u@\h \W(keystone)]\$ '
EOF

echo "INSTALLING HORIZON"
yum -y update
dnf -y install openstack-dashboard


sed -i '39d' /etc/openstack-dashboard/local_settings

sed -i "39i ALLOWED_HOSTS = ['*', ]" /etc/openstack-dashboard/local_settings

cat <<EOF >> /etc/openstack-dashboard/local_settings
CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.memcached.MemcachedCache',
        'LOCATION': '$IP:11211',
    },
}
EOF

sed -i "s/#SESSION_ENGINE = 'django.contrib.sessions.backends.signed_cookies'/SESSION_ENGINE = 'django.contrib.sessions.backends.cache'/" /etc/openstack-dashboard/local_settings

sed -i -e 's/OPENSTACK_HOST = "127.0.0.1"/OPENSTACK_HOST = "'"$IP"'"/g' /etc/openstack-dashboard/local_settings

sed -i -e 's|OPENSTACK_KEYSTONE_URL = "http://%s/identity/v3" % OPENSTACK_HOST|OPENSTACK_KEYSTONE_URL = "'"http://$IP:5000/v3"'"|g' /etc/openstack-dashboard/local_settings

sed -i 's|TIME_ZONE = "UTC"|TIME_ZONE = "Asia/Jakarta"|' /etc/openstack-dashboard/local_settings

cat <<EOF >> /etc/openstack-dashboard/local_settings
WEBROOT = '/dashboard/'
LOGIN_URL = '/dashboard/auth/login/'
LOGOUT_URL = '/dashboard/auth/logout/'
LOGIN_REDIRECT_URL = '/dashboard/'
OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT = True
OPENSTACK_KEYSTONE_DEFAULT_DOMAIN = 'Default'
OPENSTACK_API_VERSIONS = {
  "identity": 3,
  "volume": 3,
  "compute": 2,
}
EOF


sed -i "4i WSGIApplicationGroup %{GLOBAL}" /etc/httpd/conf.d/openstack-dashboard.conf

systemctl restart httpd

# GLANCE


echo "Installing Glance"
dnf -y install openstack-glance
setsebool -P glance_api_can_network on 

echo "Create Glance User"
source $ADMIN_USER_FILE
openstack project create --domain default --description "Service Project" service
openstack user create --domain default --project service --password servicepassword glance
openstack role add --project service --user glance admin


echo "Create Glance Service"
openstack service create --name glance --description "OpenStack Image service" image

echo "Creating glance endpoint"
openstack endpoint create --region RegionOne image public http://$IP:9292 
openstack endpoint create --region RegionOne image internal http://$IP:9292
openstack endpoint create --region RegionOne image admin http://$IP:9292

echo "Creating glance database and glance user database"
mysql <<- EOF
create database glance; 
grant all privileges on glance.* to glance@'localhost' identified by 'password';
grant all privileges on glance.* to glance@'%' identified by 'password';
flush privileges;
EOF

echo "Setting glance-api.conf"
mkdir /root/backup-config
cp /etc/glance/glance-api.conf /root/backup-config
echo "1" > /etc/glance/glance-api.conf
cat <<- EOF > /etc/glance/glance-api.conf
[DEFAULT]
bind_host = 0.0.0.0

[glance_store]
stores = file,http
default_store = file
filesystem_store_datadir = $GLANCE_STORAGE

[database]
# MariaDB connection info
connection = mysql+pymysql://glance:password@$IP/glance

# keystone auth info
[keystone_authtoken]
www_authenticate_uri = http://$IP:5000
auth_url = http://$IP:5000
memcached_servers = $IP:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = glance
password = servicepassword

[paste_deploy]
flavor = keystone
EOF

echo "Config /etc/fstab"
cat <<EOF >> /etc/fstab
$NFS_IP:$STORAGE_FOR_GLANCE  $GLANCE_STORAGE  nfs  _netdev,defaults 0 0
EOF

echo "Mounting NFS"
showmount -e $NFS_IP
mkdir $GLANCE_STORAGE
mount -av

echo "Sync Database"
su -s /bin/bash glance -c "glance-manage db_sync"

echo "Starting the glance service"
chown -R glance:glance $GLANCE_STORAGE
systemctl start openstack-glance-api
systemctl enable openstack-glance-api
systemctl restart openstack-glance-api

# CINDER

echo "Installing cinder"
dnf install -y openstack-cinder openstack-selinux
setsebool -P virt_use_nfs on

source $ADMIN_USER_FILE

echo "create user cinder in project service"
openstack user create --domain default --project service --password servicepassword cinder
openstack role add --project service --user cinder admin 

echo "create service cinder"
openstack service create --name cinderv3 --description "OpenStack Block Storage" volumev3

echo "create endpoint cinder, public, internal, admin"
openstack endpoint create --region RegionOne volumev3 public http://$IP:8776/v3/%\(tenant_id\)s
openstack endpoint create --region RegionOne volumev3 internal http://$IP:8776/v3/%\(tenant_id\)s
openstack endpoint create --region RegionOne volumev3 admin http://$IP:8776/v3/%\(tenant_id\)s

mysql <<- EOF 
create database cinder;
grant all privileges on cinder.* to cinder@'localhost' identified by 'password';
grant all privileges on cinder.* to cinder@'%' identified by 'password';
flush privileges;
EOF

echo "Config /etc/cinder/cinder.conf"
cp /etc/cinder/cinder.conf /root/backup-config/
echo "1" > /etc/cinder/cinder.conf

cat <<- EOF > /etc/cinder/cinder.conf

[DEFAULT]
my_ip = $IP
log_dir = /var/log/cinder
auth_strategy = keystone
transport_url = rabbit://openstack:password@$IP
glance_api_servers = http://$IP:9292
enable_v3_api = True
#enable_v2_api = False
enabled_backends = nfs 

# config cinder-backup (optional)
backup_driver = cinder.backup.drivers.nfs.NFSBackupDriver
backup_mount_point_base = $state_path_cinder/backup_nfs
backup_share = $NFS_IP:$STORAGE_FOR_CINDER_BACKUP

[database]
connection = mysql+pymysql://cinder:password@$IP/cinder


[keystone_authtoken]
www_authenticate_uri = http://$IP:5000
auth_url = http://$IP:5000
memcached_servers = "$IP:11211"
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = cinder
password = servicepassword

[oslo_concurrency]
lock_path = $state_path_cinder/tmp

# line to the end 
[nfs]
volume_driver = cinder.volume.drivers.nfs.NfsDriver
nfs_shares_config = /etc/cinder/nfs_shares
nfs_mount_point_base = $state_path_cinder/mnt
EOF

echo "setting nfs_shares"
cat <<- EOF > /etc/cinder/nfs_shares
$NFS_IP:$STORAGE_FOR_CINDER
EOF

echo "changing nfs_shares owner"
chown .cinder /etc/cinder/nfs_shares

echo "database syncing"
su -s /bin/bash cinder -c "cinder-manage db sync"

echo "add OS_VOLUME_API_VERSION to admin user file"
echo "export OS_VOLUME_API_VERSION=3" >> $ADMIN_USER_FILE

echo "starting and enabling cinder service"
systemctl start openstack-cinder-api
systemctl start openstack-cinder-scheduler
systemctl start openstack-cinder-volume
systemctl enable openstack-cinder-api
systemctl enable openstack-cinder-scheduler
systemctl enable openstack-cinder-volume

# NOVA

echo "installing nova"
dnf -y install openstack-nova openstack-placement-api 
dnf -y install openstack-nova-compute

semanage port -a -t http_port_t -p tcp 8778
setsebool -P daemons_enable_cluster_mode on
setsebool -P neutron_can_network on

source $ADMIN_USER_FILE
echo "create nova user & rule in project service"
openstack user create --domain default --project service --password servicepassword nova
openstack role add --project service --user nova admin

echo "create user placement in project service"
openstack user create --domain default --project service --password servicepassword placement
openstack role add --project service --user placement admin

echo "create service nova & service placement"
openstack service create --name nova --description "OpenStack Compute service" compute
openstack service create --name placement --description "OpenStack Compute Placement service" placement

echo "Create endpoint nova"
openstack endpoint create --region RegionOne compute public http://$IP:8774/v2.1/%\(tenant_id\)s
openstack endpoint create --region RegionOne compute internal http://$IP:8774/v2.1/%\(tenant_id\)s 
openstack endpoint create --region RegionOne compute admin http://$IP:8774/v2.1/%\(tenant_id\)s

echo "Create endpoint placement"
openstack endpoint create --region RegionOne placement public http://$IP:8778 
openstack endpoint create --region RegionOne placement internal http://$IP:8778
openstack endpoint create --region RegionOne placement admin http://$IP:8778

echo "create database nova, nova_api, nova_cell0, placement"
mysql <<- EOF
create database nova;
grant all privileges on nova.* to nova@'localhost' identified by 'password';
grant all privileges on nova.* to nova@'%' identified by 'password';
create database nova_api; 
grant all privileges on nova_api.* to nova@'localhost' identified by 'password';
grant all privileges on nova_api.* to nova@'%' identified by 'password';
create database nova_cell0; 
grant all privileges on nova_cell0.* to nova@'localhost' identified by 'password';
grant all privileges on nova_cell0.* to nova@'%' identified by 'password';
create database placement;
grant all privileges on placement.* to placement@'localhost' identified by 'password'; 
grant all privileges on placement.* to placement@'%' identified by 'password';
flush privileges;
EOF

echo "config /etc/nova/nova.conf"
cp /etc/nova/nova.conf /root/backup-config
echo "1" > /etc/nova/nova.conf
cat <<- EOF > /etc/nova/nova.conf
[DEFAULT]
# define own IP address
my_ip = $IP
enabled_apis = osapi_compute,metadata
log_dir = /var/log/nova
# RabbitMQ connection info
transport_url = rabbit://openstack:password@$IP

[api]
auth_strategy = keystone

# Glance connection info
[glance]
api_servers = http://$IP:9292

[cinder]
os_region_name = RegionOne

[oslo_concurrency]
lock_path = $state_path_nova/tmp

# MariaDB connection info
[api_database]
connection = mysql+pymysql://nova:password@$IP/nova_api

[database]
connection = mysql+pymysql://nova:password@$IP/nova

# Keystone auth info
[keystone_authtoken]
www_authenticate_uri = http://$IP:5000
auth_url = http://$IP:5000
memcached_servers = $IP:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = nova
password = servicepassword

[placement]
auth_url = http://$IP:5000
os_region_name = RegionOne
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = placement
password = servicepassword

[wsgi]
api_paste_config = /etc/nova/api-paste.ini
EOF

echo "config /etc/placement/placement.conf"
cp /etc/placement/placement.conf /root/backup-config
echo "1" > /etc/placement/placement.conf
cat <<- EOF > /etc/placement/placement.conf
[DEFAULT]
debug = false

[api]
auth_strategy = keystone

[keystone_authtoken]
www_authenticate_uri = http://$IP:5000
auth_url = http://$IP:5000
memcached_servers = $IP:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = placement
password = servicepassword

[placement_database]
connection = mysql+pymysql://placement:password@$IP/placement
EOF

echo "Setting /etc/httpd/conf.d/00-placement-api.conf"
sed -i "16i \ \ <Directory /usr/bin>\n    Require all granted\n  </Directory>" /etc/httpd/conf.d/00-placement-api.conf

echo "Syncing database"
su -s /bin/bash placement -c "placement-manage db sync" 
su -s /bin/bash nova -c "nova-manage api_db sync"
su -s /bin/bash nova -c "nova-manage cell_v2 map_cell0" 
su -s /bin/bash nova -c "nova-manage db sync"
su -s /bin/bash nova -c "nova-manage cell_v2 create_cell --name cell1"

nova-manage cell_v2 discover_hosts --verbose

systemctl restart httpd 

cat <<- EOF > /var/log/placement/placement-api.log

EOF

echo "change ownership"
chown placement:root /var/log/placement
chown placement. /var/log/placement/placement-api.log

echo "enabling nova services"
systemctl enable --now openstack-nova-api
systemctl enable --now openstack-nova-conductor
systemctl enable --now openstack-nova-scheduler
systemctl enable --now openstack-nova-novncproxy

echo "configuring /etc/nova/nova.conf"
cat <<EOF >> /etc/nova/nova.conf
[vnc]
enabled = True
server_listen = 0.0.0.0
server_proxyclient_address = $IP
novncproxy_base_url = http://$IP:6080/vnc_auto.html
EOF

echo "starting nova services"
systemctl enable --now openstack-nova-compute
systemctl restart openstack-nova-api
systemctl restart openstack-nova-conductor
systemctl restart openstack-nova-scheduler
systemctl restart openstack-nova-novncproxy

# NEUTRON

echo "installing neutron"
dnf -y install openstack-neutron openstack-neutron-ml2 openstack-neutron-openvswitch

echo "set selinux seboolean"
setsebool -P neutron_can_network on 
setsebool -P haproxy_connect_any on 
setsebool -P daemons_enable_cluster_mode on

source $ADMIN_USER_FILE

echo "create user neutron in project service"
openstack user create --domain default --project service --password servicepassword neutron
openstack role add --project service --user neutron admin 

echo "create service neutron"
openstack service create --name neutron --description "OpenStack Networking service" network

echo "create endpoint neutron"
openstack endpoint create --region RegionOne network public http://$IP:9696
openstack endpoint create --region RegionOne network internal http://$IP:9696 
openstack endpoint create --region RegionOne network admin http://$IP:9696

echo "creating database"
mysql <<- EOF
create database neutron_ml2;
grant all privileges on neutron_ml2.* to neutron@'localhost' identified by 'password'; 
grant all privileges on neutron_ml2.* to neutron@'%' identified by 'password'; 
flush privileges;
EOF

echo "configuring /etc/neutron/neutron.conf"
cp /etc/neutron/neutron.conf /root/backup-config/
echo "1" > /etc/neutron/neutron.conf
cat <<- EOF > /etc/neutron/neutron.conf
[DEFAULT]
core_plugin = ml2
service_plugins = router
auth_strategy = keystone
dhcp_agent_notification = True
allow_overlapping_ips = True
notify_nova_on_port_status_changes = True
notify_nova_on_port_data_changes = True
# RabbitMQ connection info
transport_url = rabbit://openstack:password@$IP


# Keystone auth info
[keystone_authtoken]
www_authenticate_uri = http://$IP:5000
auth_url = http://$IP:5000
memcached_servers = $IP:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = neutron
password = servicepassword

# MariaDB connection info
[database]
connection = mysql+pymysql://neutron:password@$IP/neutron_ml2

# Nova connection info
[nova]
auth_url = http://$IP:5000
auth_type = password
project_domain_name = default
user_domain_name = default
region_name = RegionOne
project_name = service
username = nova
password = servicepassword

[oslo_concurrency]
lock_path = $state_path_neutron/tmp
EOF

echo "configuring /etc/neutron/l3_agent.ini"
sed -i "2i interface_driver = openvswitch" /etc/neutron/l3_agent.ini

echo "configuring /etc/neutron/dhcp_agent.ini"
sed -i "2i interface_driver = openvswitch\ndhcp_driver = neutron.agent.linux.dhcp.Dnsmasq\nenable_isolated_metadata = true " /etc/neutron/dhcp_agent.ini

echo "configuring /etc/neutron/metadata_agent.ini"
sed -i "2i nova_metadata_host = $IP\nmetadata_proxy_shared_secret = metadata_secret" /etc/neutron/metadata_agent.ini
sed -i "s/#memcache_servers = localhost:11211/memcache_servers = $IP:11211/" /etc/neutron/metadata_agent.ini

echo "configuring /etc/neutron/plugins/ml2/ml2_conf.ini"
cat <<EOF >> /etc/neutron/plugins/ml2/ml2_conf.ini
[ml2]
type_drivers = flat,vlan,gre,vxlan
tenant_network_types = vxlan
mechanism_drivers = openvswitch
extension_drivers = port_security
 
[ml2_type_flat]
flat_networks = $FLAT_NETWORK_NAME

[ml2_type_vxlan]
vni_ranges = 1:1000
EOF

echo "configuring /etc/neutron/plugins/ml2/openvswitch_agent.ini"
cat <<EOF >> /etc/neutron/plugins/ml2/openvswitch_agent.ini
[securitygroup]
firewall_driver = openvswitch
enable_security_group = true
enable_ipset = true

[agent]
tunnel_types = vxlan
prevent_arp_spoofing = True

[ovs]
# specify IP address of this host for [local_ip]
local_ip = $IP
bridge_mappings = $FLAT_NETWORK_NAME:br-$SECOND_INTERFACE
EOF

echo "configuring /etc/nova/nova.conf"
sed -i "2i use_neutron = True\nlinuxnet_interface_driver = nova.network.linux_net.LinuxOVSInterfaceDriver\nfirewall_driver = nova.virt.firewall.NoopFirewallDriver\nvif_plugging_is_fatal = True\nvif_plugging_timeout = 300" /etc/nova/nova.conf

cat <<EOF >> /etc/nova/nova.conf
[neutron]
auth_url = http://$IP:5000
auth_type = password
project_domain_name = default
user_domain_name = default
region_name = RegionOne
project_name = service
username = neutron
password = servicepassword
service_metadata_proxy = True
metadata_proxy_shared_secret = metadata_secret
EOF

echo "enable openvswitch"
systemctl enable --now openvswitch
ovs-vsctl add-br br-int 
ovs-vsctl add-br br-$SECOND_INTERFACE
ovs-vsctl add-port br-$SECOND_INTERFACE $SECOND_INTERFACE

ln -s /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini

echo "Syncing database"
su -s /bin/bash neutron -c "neutron-db-manage --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugin.ini upgrade head"

echo "enabling and starting neutron services"
systemctl enable --now neutron-dhcp-agent
systemctl enable --now neutron-l3-agent
systemctl enable --now neutron-metadata-agent
systemctl enable --now neutron-openvswitch-agent
systemctl enable --now neutron-server.service
 
systemctl restart openstack-nova-api
systemctl restart openstack-nova-conductor
systemctl restart openstack-nova-scheduler
systemctl restart openstack-nova-novncproxy

systemctl stop libvirtd.service openstack-nova-compute.service
systemctl restart libvirtd.service openstack-nova-compute.service





