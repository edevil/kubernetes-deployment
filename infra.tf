# Variables
variable "region" {
    default = "West Europe"
}

variable "resource_group_name" {
    default = "KubernetesNEW"
}

variable "virtual_network_name" {
    default = "KubeVNET"
}

variable "storage_account_name" {
    default = "brpxkubedatadisksnew"
}

variable "jumpbox_dns_name" {
    default = "kubenewjbox"
}

variable "username" {
    default = "brpxuser"
}

variable "ssh_key_location" {
    default = "/Users/andre/.ssh/id_rsa.pub"
}

variable "master_dns_name" {
    default = "kubenewbrpx"
}

variable "num_nodes" {
    default = 2
}

variable "num_etcds" {
    default = 3
}

variable "subscription_id" {}
variable "client_id" {}
variable "client_secret" {}
variable "tenant_id" {}

# Configure the Azure Resource Manager Provider
provider "azurerm" {
    subscription_id = "${var.subscription_id}"
    client_id = "${var.client_id}"
    client_secret = "${var.client_secret}"
    tenant_id = "${var.tenant_id}"
}

# Create a resource group
resource "azurerm_resource_group" "kuberg" {
    name = "${var.resource_group_name}"
    location = "${var.region}"
}

# Create a virtual network in the web_servers resource group
resource "azurerm_virtual_network" "network" {
    name = "${var.virtual_network_name}"
    address_space = ["10.0.0.0/8"]
    location = "${var.region}"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
}

resource "azurerm_subnet" "etcd" {
    name = "etcd"
    address_prefix = "10.0.1.0/24"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
    virtual_network_name = "${azurerm_virtual_network.network.name}"
}

resource "azurerm_subnet" "master" {
    name = "master"
    address_prefix = "10.0.2.0/24"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
    virtual_network_name = "${azurerm_virtual_network.network.name}"
}

resource "azurerm_subnet" "node" {
    name = "node"
    address_prefix = "10.0.3.0/24"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
    virtual_network_name = "${azurerm_virtual_network.network.name}"
}

resource "azurerm_subnet" "management" {
    name = "management"
    address_prefix = "10.0.254.0/24"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
    virtual_network_name = "${azurerm_virtual_network.network.name}"
}

resource "azurerm_storage_account" "disks_account" {
  name = "${var.storage_account_name}"
  resource_group_name = "${azurerm_resource_group.kuberg.name}"
  location = "${var.region}"
  account_type = "Standard_LRS"
}

resource "azurerm_storage_container" "disks_container" {
    name = "vhds"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
    storage_account_name = "${azurerm_storage_account.disks_account.name}"
    container_access_type = "private"
}

resource "azurerm_public_ip" "jboxPUBIP" {
    name = "jumpboxPublicIP"
    location = "${var.region}"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
    public_ip_address_allocation = "dynamic"
    domain_name_label = "${var.jumpbox_dns_name}"
}

resource "azurerm_network_interface" "jboxNIC" {
    name = "jumpboxnic"
    location = "${var.region}"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"

    ip_configuration {
        name = "jboxipconfiguration"
        subnet_id = "${azurerm_subnet.management.id}"
        private_ip_address_allocation = "dynamic"
        public_ip_address_id = "${azurerm_public_ip.jboxPUBIP.id}"
    }
}

resource "azurerm_virtual_machine" "jumpbox" {
    name = "jumpbox"
    location = "${var.region}"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
    network_interface_ids = ["${azurerm_network_interface.jboxNIC.id}"]
    vm_size = "Standard_A0"

    storage_image_reference {
        publisher = "Canonical"
        offer = "UbuntuServer"
        sku = "16.04.0-LTS"
        version = "latest"
    }

    storage_os_disk {
        name = "jumpboxdisk"
        vhd_uri = "${azurerm_storage_account.disks_account.primary_blob_endpoint}${azurerm_storage_container.disks_container.name}/${azurerm_resource_group.kuberg.name}-jumpbox.vhd"
        caching = "ReadWrite"
        create_option = "FromImage"
    }

    os_profile {
        computer_name = "jumpbox"
        admin_username = "${var.username}"
        admin_password = "Password1234!"
    }

    os_profile_linux_config {
        disable_password_authentication = true
        ssh_keys {
            path = "/home/${var.username}/.ssh/authorized_keys"
            key_data = "${file("${var.ssh_key_location}")}"
        }
    }
}

resource "azurerm_availability_set" "etcdAS" {
    name = "ETCDAS"
    location = "${var.region}"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
}

resource "azurerm_network_interface" "etcdNIC" {
    name = "etcd-${count.index}-nic"
    location = "${var.region}"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"

    ip_configuration {
        name = "etcd-${count.index}"
        subnet_id = "${azurerm_subnet.etcd.id}"
        private_ip_address_allocation = "static"
        private_ip_address = "${cidrhost(azurerm_subnet.etcd.address_prefix, count.index + 10)}"
    }
  count = "${var.num_etcds}"
}

resource "azurerm_virtual_machine" "etcdvm" {
    name = "etcd-${count.index}-vm"
    location = "${var.region}"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
    network_interface_ids = ["${element(azurerm_network_interface.etcdNIC.*.id, count.index)}"]
    availability_set_id = "${azurerm_availability_set.etcdAS.id}"
    vm_size = "Standard_A1"

    storage_image_reference {
        publisher = "CoreOS"
        offer = "CoreOS"
        sku = "Stable"
        version = "latest"
    }

    storage_os_disk {
        name = "etcddisk-${count.index}"
        vhd_uri = "${azurerm_storage_account.disks_account.primary_blob_endpoint}${azurerm_storage_container.disks_container.name}/${azurerm_resource_group.kuberg.name}-etcd-${count.index}.vhd"
        caching = "ReadWrite"
        create_option = "FromImage"
    }

    os_profile {
        computer_name = "etcd-${count.index}-vm"
        admin_username = "${var.username}"
        admin_password = "Password1234!"
    }

    os_profile_linux_config {
        disable_password_authentication = true
        ssh_keys {
            path = "/home/${var.username}/.ssh/authorized_keys"
            key_data = "${file("${var.ssh_key_location}")}"
        }
    }

    tags {
        etcd = ""
        coreos = ""
        jbox = ""
    }
  
    count = "${var.num_etcds}"
}

resource "azurerm_availability_set" "masterAS" {
    name = "MASTERAS"
    location = "${var.region}"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
}

resource "azurerm_network_security_group" "master-sg" {
    name = "allowMasterSecurityGroup"
    location = "${var.region}"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"

    security_rule {
        name = "allow_https"
        priority = 100
        direction = "Inbound"
        access = "Allow"
        protocol = "Tcp"
        source_port_range = "*"
        destination_port_range = "443"
        source_address_prefix = "*"
        destination_address_prefix = "*"
    }
}

resource "azurerm_public_ip" "masterPUBIP" {
    name = "masterPublicIP"
    location = "${var.region}"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
    public_ip_address_allocation = "dynamic"
    domain_name_label = "${var.master_dns_name}"
}

resource "azurerm_network_interface" "master1NIC" {
    name = "master1nic"
    location = "${var.region}"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
    network_security_group_id = "${azurerm_network_security_group.master-sg.id}"

    ip_configuration {
        name = "master1ipconfiguration"
        subnet_id = "${azurerm_subnet.master.id}"
        private_ip_address_allocation = "static"
        private_ip_address = "${cidrhost(azurerm_subnet.master.address_prefix, 1 + 10)}"
        public_ip_address_id = "${azurerm_public_ip.masterPUBIP.id}"
    }
}

resource "azurerm_virtual_machine" "mastervm" {
    name = "master-1-vm"
    location = "${var.region}"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
    network_interface_ids = ["${azurerm_network_interface.master1NIC.id}"]
    availability_set_id = "${azurerm_availability_set.masterAS.id}"
    vm_size = "Standard_A1"

    storage_image_reference {
        publisher = "CoreOS"
        offer = "CoreOS"
        sku = "Beta"
        version = "latest"
    }

    storage_os_disk {
        name = "masterdisk-1"
        vhd_uri = "${azurerm_storage_account.disks_account.primary_blob_endpoint}${azurerm_storage_container.disks_container.name}/${azurerm_resource_group.kuberg.name}-master-1.vhd"
        caching = "ReadWrite"
        create_option = "FromImage"
    }

    os_profile {
        computer_name = "master-1-vm"
        admin_username = "${var.username}"
        admin_password = "Password1234!"
    }

    os_profile_linux_config {
        disable_password_authentication = true
        ssh_keys {
            path = "/home/${var.username}/.ssh/authorized_keys"
            key_data = "${file("${var.ssh_key_location}")}"
        }
    }

    tags {
        master = ""
        coreos = ""
        jbox = ""
    }
}

resource "azurerm_availability_set" "nodeAS" {
    name = "NODEAS"
    location = "${var.region}"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
}

resource "azurerm_network_interface" "nodeNIC" {
    name = "node-${count.index}-nic"
    location = "${var.region}"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"

    ip_configuration {
        name = "node-${count.index}"
        subnet_id = "${azurerm_subnet.node.id}"
        private_ip_address_allocation = "static"
        private_ip_address = "${cidrhost(azurerm_subnet.node.address_prefix, count.index + 10)}"
    }
  count = "${var.num_nodes}"
}

resource "azurerm_virtual_machine" "nodevm" {
    name = "node-${count.index}-vm"
    location = "${var.region}"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
    network_interface_ids = ["${element(azurerm_network_interface.nodeNIC.*.id, count.index)}"]
    availability_set_id = "${azurerm_availability_set.nodeAS.id}"
    vm_size = "Standard_A1"

    storage_image_reference {
        publisher = "CoreOS"
        offer = "CoreOS"
        sku = "Beta"
        version = "latest"
    }

    storage_os_disk {
        name = "nodedisk-${count.index}"
        vhd_uri = "${azurerm_storage_account.disks_account.primary_blob_endpoint}${azurerm_storage_container.disks_container.name}/${azurerm_resource_group.kuberg.name}-node-${count.index}.vhd"
        caching = "ReadWrite"
        create_option = "FromImage"
    }

    os_profile {
        computer_name = "node-${count.index}-vm"
        admin_username = "${var.username}"
        admin_password = "Password1234!"
    }

    os_profile_linux_config {
        disable_password_authentication = true
        ssh_keys {
            path = "/home/${var.username}/.ssh/authorized_keys"
            key_data = "${file("${var.ssh_key_location}")}"
        }
    }

    tags {
        node = ""
        coreos = ""
        jbox = ""
    }
  
    count = "${var.num_nodes}"
}
