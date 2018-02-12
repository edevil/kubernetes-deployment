# Variables
variable "region" {
    default = "westeurope"
}

variable "resource_group" {}

variable "virtual_network_name" {
    default = "KubeVNET"
}

variable "username" {
    default = "brpxuser"
}

variable "ssh_key_location" {
    default = "/Users/andre/.ssh/id_rsa.pub"
}

variable "etcd_cloudinit_location" {
    default = "templates/coreos-etcd-cloudconfig.yaml"
}

variable "num_masters" {
    default = 2
}

variable "num_nodes" {
    default = 2
}

variable "num_etcds" {
    default = 3
}

variable "etcd_vm_size" {
    default = "Standard_A1_v2"
}

variable "master_vm_size" {
    default = "Standard_A1_v2"
}

variable "node_vm_size" {
    default = "Standard_A2_v2"
}

variable "etcd_storage_type" {
    default = "Standard_LRS"
}

variable "master_storage_type" {
    default = "Standard_LRS"
}

variable "node_storage_type" {
    default = "Standard_LRS"
}

variable "subscription_id" {}
variable "client_id" {}
variable "client_secret" {}
variable "tenant_id" {}

# cloud-config template
data "template_file" "kubecloudconfig" {
  template = "${file("templates/coreos-cloudconfig.yaml")}"

  vars {
    tenant_id = "${var.tenant_id}"
    subscription_id = "${var.subscription_id}"
    resource_group = "${var.resource_group}"
    client_id = "${var.client_id}"
    client_secret = "${var.client_secret}"
    tenant_id = "${var.tenant_id}"
    location = "${var.region}"
    subnet_name = "${azurerm_subnet.node.name}"
    security_group = "${azurerm_network_security_group.kubesg.name}"
    vnet_name = "${var.virtual_network_name}"
    route_table_name = "${azurerm_route_table.kubetable.name}"
  }
}

# Configure the Azure Resource Manager Provider
provider "azurerm" {
    subscription_id = "${var.subscription_id}"
    client_id = "${var.client_id}"
    client_secret = "${var.client_secret}"
    tenant_id = "${var.tenant_id}"
    version = "0.3.1"
}

# Create a resource group
resource "azurerm_resource_group" "kuberg" {
    name = "${var.resource_group}"
    location = "${var.region}"
}

# Create a virtual network in the web_servers resource group
resource "azurerm_virtual_network" "network" {
    name = "${var.virtual_network_name}"
    address_space = ["10.0.0.0/8"]
    location = "${var.region}"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
}

resource "azurerm_route_table" "kubetable" {
  name = "kube-route-table"
  location = "${var.region}"
  resource_group_name = "${azurerm_resource_group.kuberg.name}"

  lifecycle {
      ignore_changes = "route"
  }
}

resource "azurerm_network_security_group" "kubesg" {
  name = "kube-security-group"
  location = "${var.region}"
  resource_group_name = "${azurerm_resource_group.kuberg.name}"
}

resource "azurerm_subnet" "etcd" {
    name = "etcd"
    address_prefix = "10.0.1.0/24"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
    virtual_network_name = "${azurerm_virtual_network.network.name}"
    route_table_id = "${azurerm_route_table.kubetable.id}"
}

resource "azurerm_subnet" "master" {
    name = "master"
    address_prefix = "10.0.2.0/24"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
    virtual_network_name = "${azurerm_virtual_network.network.name}"
    route_table_id = "${azurerm_route_table.kubetable.id}"
}

resource "azurerm_subnet" "node" {
    name = "node"
    address_prefix = "10.0.3.0/24"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
    virtual_network_name = "${azurerm_virtual_network.network.name}"
    route_table_id = "${azurerm_route_table.kubetable.id}"
    network_security_group_id = "${azurerm_network_security_group.kubesg.id}"
}

resource "azurerm_subnet" "management" {
    name = "management"
    address_prefix = "10.0.254.0/24"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
    virtual_network_name = "${azurerm_virtual_network.network.name}"
    route_table_id = "${azurerm_route_table.kubetable.id}"
}

resource "azurerm_storage_account" "util_disks_account" {
  name = "${lower(var.resource_group)}utildisk"
  resource_group_name = "${azurerm_resource_group.kuberg.name}"
  location = "${var.region}"
  account_tier = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "util_disks_container" {
    name = "vhds"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
    storage_account_name = "${azurerm_storage_account.util_disks_account.name}"
    container_access_type = "private"
}

resource "azurerm_public_ip" "jboxPUBIP" {
    name = "jumpboxPublicIP"
    location = "${var.region}"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
    public_ip_address_allocation = "dynamic"
    domain_name_label = "${var.resource_group}-jbox"
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
    delete_data_disks_on_termination = "true"
    delete_os_disk_on_termination = "true"

    storage_image_reference {
        publisher = "Canonical"
        offer = "UbuntuServer"
        sku = "16.04.0-LTS"
        version = "latest"
    }

    storage_os_disk {
        name = "jumpboxdisk"
        vhd_uri = "${azurerm_storage_account.util_disks_account.primary_blob_endpoint}${azurerm_storage_container.util_disks_container.name}/${azurerm_resource_group.kuberg.name}-jumpbox.vhd"
        caching = "ReadWrite"
        create_option = "FromImage"
    }

    boot_diagnostics {
        enabled = true
        storage_uri = "${azurerm_storage_account.util_disks_account.primary_blob_endpoint}"
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
    managed = true
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
    vm_size = "${var.etcd_vm_size}"
    delete_data_disks_on_termination = "true"
    delete_os_disk_on_termination = "true"

    storage_image_reference {
        publisher = "CoreOS"
        offer = "CoreOS"
        sku = "Stable"
        version = "latest"
    }

    storage_os_disk {
        name = "etcddisk-${count.index}"
        caching = "ReadWrite"
        create_option = "FromImage"
        managed_disk_type = "${var.etcd_storage_type}"
        disk_size_gb = 32
    }

    boot_diagnostics {
        enabled = true
        storage_uri = "${azurerm_storage_account.util_disks_account.primary_blob_endpoint}"
    }

    os_profile {
        computer_name = "etcd-${count.index}-vm"
        admin_username = "${var.username}"
        admin_password = "Password1234!"
        custom_data = "${base64encode(file("${var.etcd_cloudinit_location}"))}"
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
    managed = true
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
    domain_name_label = "${var.resource_group}-master"
}

resource "azurerm_lb" "masterLB" {
    name = "masterLB"
    location = "${var.region}"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"

    frontend_ip_configuration {
      name = "PublicIPAddress"
      public_ip_address_id = "${azurerm_public_ip.masterPUBIP.id}"
    }
}

resource "azurerm_lb_backend_address_pool" "masterLBapool" {
  resource_group_name = "${azurerm_resource_group.kuberg.name}"
  loadbalancer_id = "${azurerm_lb.masterLB.id}"
  name = "BackEndAddressPool"
}

resource "azurerm_lb_probe" "httpsProbe" {
  resource_group_name = "${azurerm_resource_group.kuberg.name}"
  loadbalancer_id = "${azurerm_lb.masterLB.id}"
  name = "HTTPSRunningProbe"
  port = 443
}

resource "azurerm_lb_rule" "httpsLBrule" {
  resource_group_name = "${azurerm_resource_group.kuberg.name}"
  loadbalancer_id = "${azurerm_lb.masterLB.id}"
  name = "LBRuleHTTPS"
  protocol = "Tcp"
  frontend_port = 443
  backend_port = 443
  frontend_ip_configuration_name = "PublicIPAddress"
  probe_id = "${azurerm_lb_probe.httpsProbe.id}"
  backend_address_pool_id = "${azurerm_lb_backend_address_pool.masterLBapool.id}"
}

resource "azurerm_network_interface" "masterNIC" {
    name = "master-${count.index}-nic"
    location = "${var.region}"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
    network_security_group_id = "${azurerm_network_security_group.master-sg.id}"
    enable_ip_forwarding = true

    ip_configuration {
        name = "master-${count.index}"
        subnet_id = "${azurerm_subnet.master.id}"
        private_ip_address_allocation = "static"
        private_ip_address = "${cidrhost(azurerm_subnet.master.address_prefix, count.index + 10)}"
        load_balancer_backend_address_pools_ids = ["${azurerm_lb_backend_address_pool.masterLBapool.id}"]
    }
    count = "${var.num_masters}"
}

resource "azurerm_virtual_machine" "mastervm" {
    name = "k8s-master-${count.index}"
    location = "${var.region}"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
    network_interface_ids = ["${element(azurerm_network_interface.masterNIC.*.id, count.index)}"]
    availability_set_id = "${azurerm_availability_set.masterAS.id}"
    vm_size = "${var.master_vm_size}"
    delete_data_disks_on_termination = "true"
    delete_os_disk_on_termination = "true"

    storage_image_reference {
        publisher = "CoreOS"
        offer = "CoreOS"
        sku = "Stable"
        version = "latest"
    }

    storage_os_disk {
        name = "masterdisk-${count.index}"
        caching = "ReadWrite"
        create_option = "FromImage"
        managed_disk_type = "${var.master_storage_type}"
        disk_size_gb = 40
    }

    boot_diagnostics {
        enabled = true
        storage_uri = "${azurerm_storage_account.util_disks_account.primary_blob_endpoint}"
    }

    os_profile {
        computer_name = "k8s-master-${count.index}"
        admin_username = "${var.username}"
        admin_password = "Password1234!"
        custom_data = "${base64encode(data.template_file.kubecloudconfig.rendered)}"
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

    count = "${var.num_masters}"
}

resource "azurerm_availability_set" "nodeAS" {
    name = "NODEAS"
    location = "${var.region}"
    managed = true
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
}

resource "azurerm_network_interface" "nodeNIC" {
    name = "node-${count.index}-nic"
    location = "${var.region}"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
    enable_ip_forwarding = true

    ip_configuration {
        name = "node-${count.index}"
        subnet_id = "${azurerm_subnet.node.id}"
        private_ip_address_allocation = "static"
        private_ip_address = "${cidrhost(azurerm_subnet.node.address_prefix, count.index + 10)}"
    }
  count = "${var.num_nodes}"
}

resource "azurerm_virtual_machine" "nodevm" {
    name = "k8s-agent-${count.index}"
    location = "${var.region}"
    resource_group_name = "${azurerm_resource_group.kuberg.name}"
    network_interface_ids = ["${element(azurerm_network_interface.nodeNIC.*.id, count.index)}"]
    availability_set_id = "${azurerm_availability_set.nodeAS.id}"
    vm_size = "${var.node_vm_size}"
    delete_data_disks_on_termination = "true"
    delete_os_disk_on_termination = "true"

    storage_image_reference {
        publisher = "CoreOS"
        offer = "CoreOS"
        sku = "Stable"
        version = "latest"
    }

    storage_os_disk {
        name = "nodedisk-${count.index}"
        caching = "ReadWrite"
        create_option = "FromImage"
        managed_disk_type = "${var.node_storage_type}"
        disk_size_gb = 100
    }

    boot_diagnostics {
        enabled = true
        storage_uri = "${azurerm_storage_account.util_disks_account.primary_blob_endpoint}"
    }

    os_profile {
        computer_name = "k8s-agent-${count.index}"
        admin_username = "${var.username}"
        admin_password = "Password1234!"
        custom_data = "${base64encode(data.template_file.kubecloudconfig.rendered)}"
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
