#!/bin/bash
IP="192.168.100.128"
KEYSTONE_DBPASS="password"
ADMIN_PASS="Sepeda36"
#GLANCE_STORAGE variable is NFS mount point 
GLANCE_STORAGE="/glance-backend"
CINDER_STORAGE=""
#STORAGE_FOR_GLANCE,STORAGE_FOR_CINDER,and STORAGE_FOR_CINDER_BACKUP variable is the directory in NFS server
STORAGE_FOR_GLANCE="/mnt/glance-inone"
STORAGE_FOR_CINDER="/mnt/cinder-inone"
STORAGE_FOR_CINDER_BACKUP="/mnt/cinder-backup-inone"
#NFS_IP variable is the IP of the NFS Server
NFS_IP="192.168.100.129"
ADMIN_USER_FILE="/root/admin-openrc"
state_path_cinder="/var/lib/cinder"
state_path_nova="/var/lib/nova"
state_path_neutron="/var/lib/neutron"
SECOND_INTERFACE="enp0s8"
FLAT_NETWORK_NAME="physnet1"