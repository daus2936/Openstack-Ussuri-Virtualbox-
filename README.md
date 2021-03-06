# Openstack-Ussuri-Virtualbox-

This is the Openstack Ussuri installation script . The installation step is from the youtube channel named “freakos” youtube channel link : https://www.youtube.com/channel/UCktYL2xWfwmdVcOc3RNGX0w ,i just follow his installation step and make the script of it.
Requirement: <br />
- Virtualbox with 2 VM : <br />
1 VM is for all openstack services (i will call this VM : openstackVM) <br />
1 VM is for cinder and glance backend - Using NFS (i will call this VM : storageVM) <br />

![NFS backend](https://user-images.githubusercontent.com/55316038/110206473-71970a80-7eb0-11eb-81d9-849714a1da74.PNG) <br />

- Operating System : CentOS 8 <br />

- Make sure we have 2 network interfaces on openstackVM and the network interfaces can access internet,in my case ,i'm using bridge adapter on my 2 network interfaces.For storageVM you just need 1 network interface.
and make sure "Promiscuous Mode" is "Allow All"<br />
- ![network1](https://user-images.githubusercontent.com/55316038/110206769-5200e180-7eb2-11eb-882c-6b06768f7bcc.PNG)<br />
<br />

- ![network2](https://user-images.githubusercontent.com/55316038/110207509-81b1e880-7eb6-11eb-9945-2f8a7ad2bcbc.PNG)<br />
<br />

- enable Nested VT-X/AMD-V on VM setting ,go to your virtualbox directory and type this on your command prompt(cmd) or terminal : <br />
`VBoxManage modifyvm YourVirtualBoxName --nested-hw-virt on` <br />

- clone my repository on openstackVM and storageVM: <br />
`git clone https://github.com/daus2936/Openstack-Ussuri-Virtualbox-.git` <br />

- after cloning,give file permission to execute the script: <br />
`chmod +x nfs-server.sh openstackussuri.sh variable.sh` <br />

- First,run the nfs-server.sh script on storageVM ,don't forget to change the IP and another variable on variable.sh! <br />
`./nfs-server.sh` <br />

- Second,run the openstackussuri.sh ,don't forget to change the IP and another variable on variable.sh! <br />
`./openstackussuri.sh` <br />
