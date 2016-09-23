# Kubernetes automated deployment on Azure

Automated scripts to provision a Kubernetes cluster on the Azure cloud, based on [Terraform](https://www.terraform.io) and [Ansible](https://www.ansible.com).

## Introduction

These scripts provision a Kubernetes cluster with a separate etcd cluster. The etcd cluster has 3 VMs, this number can be overridden when launching the Terraform script. The Kubernetes cluster has 1 master VM and 2 node VMs, the number of node VMs can also be configured when launching the Terraform script. For now the number of master nodes is not configurable, but since all state is stored in etcd which has a HA configuration, a new master VMs can be spin up quickly if it has problems. There is also a jumpbox with a public SSH endpoint that can be used for accessing the VMs inside the virtual network.

## Prerequisites

 * The host node where these scripts will be run needs to have a Python 2 environment, Ansible requires it.
 * If we're rebuilding a previous infrastructure, make sure to delete previous SSH keys from `known_hosts`.
 * Ansible >= 2.1
 * Azure Python SDK >= 2.0.0rc3
 * Terraform >= 0.7 RC2
 * Azure Xplat-CLI >= 0.10.1

## Configure authentication

You need an Azure service principal in order for Ansible (through Azure's Python SDK) and Terraform (through Azure's Go SDK) to authenticate against the Azure API. You can use [this](https://azure.microsoft.com/en-us/documentation/articles/resource-group-create-service-principal-portal/) guide to create the service principal account and obtain the needed parameters:

 * subscription_id
 * client_id
 * client_secret
 * tenant_id

For [configuring Ansible](https://docs.ansible.com/ansible/guide_azure.html) you can use environment variables or store them in the file `$HOME/.azure/credentials` in an ini style format. For [configuring Terraform](https://www.terraform.io/docs/configuration/variables.html) you can set these parameters in tf var files.

Afterwards, `kubectl` uses tokens to authenticate against the Kubernetes API. The tokens can be found in the `files/tokens.csv` file.

## Choose the resource group name

The resource group name is an argument to all scripts. This resource group must not exist yet.

    export RESOURCE_GROUP=kubernetesnew

The resource group name is used to build some other parameters such as the jumpbox DNS name, `$RESOURCE_GROUP-jbox.westeurope.cloudapp.azure.com`, or the kubernetes master DNS name, `$RESOURCE_GROUP-master.westeurope.cloudapp.azure.com`.

## Spin up infrastructure

Terraform is used for provisioning the Azure infrastructure. You may also want to alter the `ssh_key_location` variable which points to the SSH key that will be associated with the `brpxuser` user in the VMs.

    terraform apply -var "resource_group=$RESOURCE_GROUP"

## Configure VMs

Ansible is used for configuring the VMs, and the Azure RM dynamic inventory script is used to fetch the VM details. This inventory script is included with Ansible, but it can also be fetched from [here](https://github.com/ansible/ansible/blob/devel/contrib/inventory/azure_rm.py).

### Bootstrap CoreOS nodes

Ansible expects nodes to have a Python interpreter on `/usr/bin/python`. CoreOS does not come with a Python interpreter installed so a bootstrap step is needed in this case.

    ansible-playbook -i azure_rm.py -e resource_group=$RESOURCE_GROUP bootstrap.yml

### Generate PKI infrastructure

The communications between the nodes and the master is authenticated via PKI. The communications between the master and the nodes is not yet authenticated, the certificates are not verified, but the PKI is already in place for when this feature is implemented in Kubernetes.

    ansible-playbook -i azure_rm.py -e resource_group=$RESOURCE_GROUP generate_certs.yml

### Install Kubernetes

This step installs all Kubernetes components and certificates.

    ansible-playbook -i azure_rm.py -e resource_group=$RESOURCE_GROUP kubernetes_setup.yml

## Configure the local kubectl

In order to manage the Kubernetes cluster you need to configure the `kubectl` command (in OSX you can install it with `brew install kubernetes-cli`). If you did not change the `files/tokens.csv` file, there is a default token which is `changeme`.

    kubectl config set-cluster $RESOURCE_GROUP-cluster --server=https://$RESOURCE_GROUP-master.westeurope.cloudapp.azure.com --certificate-authority=certs/ca.pem
    kubectl config set-credentials $RESOURCE_GROUP-admin --token=changeme
    kubectl config set-context $RESOURCE_GROUP-system --cluster=$RESOURCE_GROUP-cluster --user=$RESOURCE_GROUP-admin
    kubectl config use-context $RESOURCE_GROUP-system

## Install the DNS addon

The kubelet was configured to use a DNS service running on Kubernetes, so we need to provision the Kubernetes DNS addon. This helps in the discovery of services running in the Kubernetes cluster.

    # create service
    kubectl create -f files/kubedns-svc.yaml

    # create deployment
    kubectl create -f files/kubedns-depl.yaml

## Create Azure load-balancer for nodes

Neither Terraform nor Ansible as of now support the provisioning of Azure load-balancers, so this step needs the Azure xplat CLI. In the example bellow two applications running on Kubernetes, with NodePorts 31000 and 31082, are exposed via 2 separate DNS addresses. The `westeurope` region is used by the provisioning scripts, so you may want to:

    export A_LOCATION=westeurope

### Provision two different public IPs

One IP for each app.

    azure network public-ip create -d guestbook-brpx $RESOURCE_GROUP public-ip-guestbook $A_LOCATION
    azure network public-ip create -d roamersin-brpx $RESOURCE_GROUP public-ip-roamersin $A_LOCATION

### Create the load-balancer

    azure network lb create $RESOURCE_GROUP KubeNodeLB $A_LOCATION

### Create frontend pools

One pool per public ip.

    azure network lb frontend-ip create $RESOURCE_GROUP KubeNodeLB GuestFrontPool -i public-ip-guestbook
    azure network lb frontend-ip create $RESOURCE_GROUP KubeNodeLB RoamersFrontPool -i public-ip-roamersin

### Create backend pool

Only one backend pool is needed.

    azure network lb address-pool create $RESOURCE_GROUP KubeNodeLB NodeBackPool

### Add node NICs to backend pool

All node's NICs need to be added to the backend pool.

    azure network nic ip-config address-pool create $RESOURCE_GROUP node-0-nic -l KubeNodeLB -a NodeBackPool
    azure network nic ip-config address-pool create $RESOURCE_GROUP node-1-nic -l KubeNodeLB -a NodeBackPool

### Configure health probe

    azure network lb probe create -g $RESOURCE_GROUP -l KubeNodeLB -n healthprobe -p "tcp" -o 22 -i 10 -c 2

### Create LB rules

    azure network lb rule create $RESOURCE_GROUP KubeNodeLB guestbook -p tcp -f 80 -b 31082 -t GuestFrontPool -o NodeBackPool -a healthprobe
    azure network lb rule create $RESOURCE_GROUP KubeNodeLB roamersin -p tcp -f 80 -b 31000 -t RoamersFrontPool -o NodeBackPool -a healthprobe

## Exposing new Kubernetes app

In order to expose a new app running on the Kubernetes cluster it must have a service configured with a NodePort. Then follow the steps from the creation of the load-balancer:

 1. Create a new public IP
 2. Create a new LB frontend pool with the new IP
 3. Create LB rule to map traffic directed at that IP to the NodePort in the Kubernetes cluster
