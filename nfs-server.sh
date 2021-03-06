#!/bin/bash

source variable.sh

echo "disabling firewall"
systemctl stop firewalld
systemctl disable firewalld

echo "Installing nfs server"
dnf install nfs-utils 
systemctl start nfs-server.service
systemctl enable nfs-server.service

mkdir $STORAGE_FOR_GLANCE $STORAGE_FOR_CINDER $STORAGE_FOR_CINDER_BACKUP

echo "config /etc/exports"
cat <<- EOF > /etc/exports
$STORAGE_FOR_GLANCE *(rw,sync,no_root_squash)
$STORAGE_FOR_CINDER *(rw,sync,no_root_squash)
$STORAGE_FOR_CINDER_BACKUP *(rw,sync,no_root_squash)
EOF

exportfs -rv

echo "change chown"
chown -R 161:161 $STORAGE_FOR_GLANCE
chown -R 165:165 $STORAGE_FOR_CINDER
chown -R 165:165 $STORAGE_FOR_CINDER_BACKUP

echo "restarting nfs server"

systemctl restart nfs-server.service




