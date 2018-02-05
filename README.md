# Kubernetes automated deployment on Azure

Automated scripts to provision a Kubernetes cluster on the Azure cloud, based on [Terraform](https://www.terraform.io) and [Ansible](https://www.ansible.com).

## Introduction

These scripts provision a Kubernetes cluster with a separate etcd cluster. The etcd cluster has 3 VMs, this number can be overridden when launching the Terraform script. The Kubernetes cluster has 2 master VMs and 2 node VMs, these numbers can also be configured when launching the Terraform script. There is also a jumpbox with a public SSH endpoint that can be used for accessing the VMs inside the virtual network.

## Prerequisites

 * The host node where these scripts will be run needs to have a Python 2 environment, Ansible requires it.
 * If we're rebuilding a previous infrastructure, make sure to delete previous SSH keys from `known_hosts`.
 * Ansible >= 2.2.1.0
 * Azure Python SDK == 2.0.0rc5
 * Terraform >= 0.10.7

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

## Install the Calico CNI plugin

The kubelet was configured to use a CNI plugin, but there isn't one installed yet. We need to install the Calico CNI plugin, relevant RBAC config and Calico components.

    # create RBAC definitions
    kubectl create -f files/calico-rbac.yaml

    # create Calico components
    kubectl create -f files/calico.yaml
## Configure storage class

Configure the default storage class when one is not specified in the descriptor:

    kubectl apply -f files/default-storage-class.yaml

Usage examples can be found [here](https://github.com/kubernetes/examples/tree/master/staging/volumes/azure_disk/claim). Azure-file is fine for when only one pod is using the volume, when you need multiple pods using the same volume and/or multiple writers you need to use azure-file and examples can be found [here](https://github.com/kubernetes/examples/tree/master/staging/volumes/azure_file).

## Install the DNS addon

The kubelet was configured to use a DNS service running on Kubernetes, so we need to provision the Kubernetes DNS addon. This helps in the discovery of services running in the Kubernetes cluster.

    # create service account
    kubectl create -f files/kubedns-sa.yaml

    # create service
    kubectl create -f files/kubedns-svc.yaml

    # create deployment
    kubectl create -f files/kubedns-depl.yaml

# Optional components

## Dashboard

### Add permissions to default namespace account

    kubectl create clusterrolebinding system-cluster-admin --clusterrole=cluster-admin --serviceaccount=kube-system:default --namespace=kube-system

### Create deployment and service

    kubectl create -f https://raw.githubusercontent.com/kubernetes/dashboard/v1.6.3/src/deploy/kubernetes-dashboard.yaml

## Heapster

### Create account and add cluster role

    kubectl create serviceaccount heapster --namespace=kube-system
    kubectl create clusterrolebinding heapster-role --clusterrole=system:heapster --serviceaccount=kube-system:heapster --namespace=kube-system

### Create deployment and service

    kubectl create -f files/kube-heapster-service.yaml
    kubectl create -f files/kube-heapster-deployment.yaml

## Logging - Fluentd

### Create ConfigMap

The file ```files/td-agent.conf``` contains an example configuration that can be adapted to logz.io or logentries.com.  After editing it, create the configmap.

    kubectl create configmap fluentd-config --from-file=files/td-agent.conf --namespace=kube-system

### Create DaemonSet

This DaemonSet will ensure that a fluentd daemon will run on every node.

    kubectl create -f files/fluentd-ds.yml

## Logging - OMS

### Configuration

The correct workspace ID ```<WSID>``` and key ```<KEY>``` need to be configured on the daemonset configuration file ```oms-daemonset.yaml```. These values can be obtained from the "Connected Sources" menu of the OMS Portal.

### Creating DaemonSet

    kubectl create -f files/oms-daemonset.yaml --namespace=kube-system

## Nginx Ingress Controller + Kube-Lego

Based on [this](https://github.com/jetstack/kube-lego/tree/master/examples/nginx).
Nginx rbac permissions based on [this](https://github.com/kubernetes/ingress-nginx/blob/master/deploy/rbac.md) and lego permissions based on [this](https://github.com/jetstack/kube-lego/blob/master/examples/gce/lego/cluster-role.yaml).

### Create namespaces

    kubectl apply -f nginx_ingress/nginx/00-namespace.yaml
    kubectl apply -f nginx_ingress/lego/00-namespace.yaml

### Add permissions

    kubectl apply -f nginx_ingress/nginx/rbac.yaml
    kubectl apply -f nginx_ingress/lego/rbac.yaml

### Create default backend

    kubectl apply -f nginx_ingress/nginx/default-deployment.yaml
    kubectl apply -f nginx_ingress/nginx/default-service.yaml

### Nginx config, deployment and service

    kubectl apply -f nginx_ingress/nginx/configmap.yaml
    kubectl apply -f nginx_ingress/nginx/service.yaml
    kubectl apply -f nginx_ingress/nginx/deployment.yaml

### Kube-Lego config and deployment

Change the email address on the config file before creating it.

    kubectl apply -f nginx_ingress/lego/configmap.yaml
    kubectl apply -f nginx_ingress/lego/deployment.yaml


# Upgrade notes

1. On the master components, alter the image tag on the pod manifests (/etc/kubernetes/manifests/). Be careful not to edit the files in place otherwise the editor may place swap files, etc, on the manifests dir, which will cause havoc with kubelet. It's best to edit the files somewhere else and then copy over. The apiserver needs to be upgraded before kubelets.
1. Upgrade kubelet image version that is used with kubelet-wrapper. This is done on the kubelet.service unit file on master and node components.
1. systemctl daemon-reload && systemctl restart kubelet
1. On the node components, alter the image tag on the kube proxy manifest. The same care should be taken as in the case of the master components.
1. Wait for the last components to come up. The upgrade is finished.


# Procedure to re-create node (ex: node-0-vm)

## Drain node

Drain kube node (for schedulable nodes) in order to move all running pods to an healthy node. If DaemonSet are used, the --force flag has to be used since there pods will stay running in the node.

    kubectl drain node-0-vm --ignore-daemonsets --force

## Taint VM

Taint terraform resource in order for the infrastructure to be re-created.

    terraform taint "azurerm_virtual_machine.nodevm.0"

## Apply Terraform

Apply terraform and restrict to that resource. This will delete and create the VM, and just that VM.

    terraform apply -var "resource_group=$RESOURCE_GROUP" -target="azurerm_virtual_machine.nodevm[0]"

## Run Ansible playbook

Run ansible playbooks restricted to that resource.

    export ANSIBLE_GATHERING=smart
    export ANSIBLE_CACHE_PLUGIN=jsonfile
    export ANSIBLE_CACHE_PLUGIN_CONNECTION=/tmp/ansible_cache
    export ANSIBLE_CACHE_PLUGIN_TIMEOUT=86400
    rm -fr /tmp/ansible_cache
    ansible-playbook -i azure_rm.py -e resource_group=$RESOURCE_GROUP bootstrap.yml --limit node-0-vm
    ansible -i azure_rm.py all --limit $RESOURCE_GROUP -m setup
    ansible-playbook -i azure_rm.py -e resource_group=$RESOURCE_GROUP kubernetes_setup.yml --limit node-0-vm

## Upgrading etcd 2 -> 3

Stop and disable etcd2:

    systemctl stop etcd2
    systemctl disable etcd2

Don't forget to copy data dir:

    rm -fr /var/lib/etcd
    cp -rp /var/lib/etcd2 /var/lib/etcd

Start and enable etcd3 service or run the ansible setup again:

    systemctl start etcd-member
    systemctl enable etcd-member

## Migrating data etcd 2 -> 3

1. Stop all API servers
1. Enter the etcd RKT containers `rkt enter XXX /bin/sh`
1. Stop the etcd-member service `systemctl stop etcd-member`
1. Run the migration script on the data dir `cd /var/lib/etcd; ETCDCTL_API=3 /usr/local/bin/etcdctl migrate`
1. Start the etcd-member service `systemctl start etcd-member`
1. Alter the storage-backend flag of the API descriptor `--storage-backend=etcd3`
1. Start all API servers

## Change storage media type to protobuf

After all previous steps have been taken and the cluster is stable, alter the API server descriptor to change the `storage-media-type` flag from `application/json` to `application/vnd.kubernetes.protobuf`.