variable "aws_access_key" {
    type = string
    description = "AWS access key to be used."
    sensitive = true
}

variable "aws_secret_key" {
    type = string
    description = "AWS secret key to be used."
    sensitive = true
}

variable "aws_region" {
    type = list(string)
    description = "AWS region to use for AWS resources."
    default = ["us-east-1", "us-east-2"]
}

variable "enable_dns_hostnames" { #not sure why this is needed
    type = bool
    description = "Enable DNS hostnames in VPC."
    default = true
}

variable "vpc_cidr_block" {
    type = string
    description = "Base CIDR block to use for VPC."
    default = "10.0.0.0/16"
}

variable "vpc_subnet_cidr_block" {
    type = list(string)
    description = "CIDR block to use for subnet."
    default = ["10.0.0.0/24", "10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "aws_availability_zone" {
    type = list(string)
    description = "AWS availability zone to use for AWS resources."
    default = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"]
}

variable "everyone_network" {
    type = string
    description = "Network to use when all IP addresses are needed."
    default = "0.0.0.0/0"
}

variable "security_group_rule_type" {
    type = list(string)
    description = "Security group rule type."
    default = ["ingress", "egress"]
}

variable "ssh_port" {
    type = number
    description = "Port used for SSH."
    default = 22
}

variable "network_protocol" {
    type = list(string)
    description = "Network protocol to be used."
    default = ["tcp", "udp"]
}

variable "https_port" {
    type = number
    description = "Port used for HTTPS."
    default = 443
}

variable "nfs_port" {
    type = number
    description = "Port used for NFS."
    default = 2049
}

variable "personal_network" {
    type = string
    description = "Personal home network address(es)."
    default = "108.7.180.150/32"
}