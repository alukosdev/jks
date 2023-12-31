####################
# PROVIDERS
####################

# We are using AWS to deploy the infrastructure for this task. Let's set this up with some structure.
provider "aws" {
    access_key = var.aws_access_key
    secret_key = var.aws_secret_key
    region = var.aws_region[0]

    default_tags {
        tags = {
            App = "jenkins"
            Env = "dev"
            Org = "devops"
            Terraform = "true"
        }
    }
}

####################
# RESOURCES
####################

# OBJECT STORAGE

# Create bucket for MongoDB backups.
resource "aws_s3_bucket" "bucket1" {
    tags = {
        Name = "mongodb-backup"
    }
    # The force_destroy command is required to ensure a bucket with objects is removed during a Terraform destroy operation.
    force_destroy = true
}

# FILE STORAGE

# Create EFS volume for persistent storage for Jenkins EKS deployment.
resource "aws_efs_file_system" "jenkins_efs" {
    encrypted = true

    lifecycle_policy {
        transition_to_ia = "AFTER_30_DAYS"
    }
}

resource "aws_efs_mount_target" "jenkins_efs_target1" {
    file_system_id = aws_efs_file_system.jenkins_efs.id
    subnet_id = aws_subnet.private_subnet1.id
    security_groups = [aws_security_group.ingress_allow_efs_from_eks.id]
}

resource "aws_efs_mount_target" "jenkins_efs_target2" {
    file_system_id = aws_efs_file_system.jenkins_efs.id
    subnet_id = aws_subnet.private_subnet2.id
    security_groups = [aws_security_group.ingress_allow_efs_from_eks.id]
}

# Set permissions to the EFS volume.
resource "aws_efs_access_point" "jenkins_efs_ap1" {
    file_system_id = aws_efs_file_system.jenkins_efs.id

    # Operating system user and group applied to all file system requests made using the access point.
    posix_user {
        uid = 1000
        gid = 1000
    }

    # Directory on the Amazon EFS file system that the access point provides access to.
    root_directory {
        path = "/jenkins"

        # Create the user and group that will be making requests and assign permissions.
        creation_info {
            owner_uid = 1000
            owner_gid = 1000
            permissions = "777"
        }
    }
}

# COMPUTE

# Create compute instance for MongoDB installation.
resource "aws_instance" "compute1" {
    # Let's use an old version of Amazon Linux 2 since we like to be insecure!
    ami = "ami-0518831b4cfc1f563"
    instance_type = "t3.micro"
    subnet_id = aws_subnet.public_subnet1.id
    vpc_security_group_ids = [
        aws_security_group.ingress_allow_ssh_from_bastion.id,
        aws_security_group.egress_allow_https_to_www.id,
        aws_security_group.ingress_allow_ssh_from_personal.id
    ]
    key_name = aws_key_pair.compute1_ssh_key_pair.key_name

    # Let's also install an old version of MongoDB to really hit it home.
    user_data = <<-EOF
        #!/bin/bash
        echo '[mongodb-org-4.0]
        name=MongoDB Repository
        baseurl=https://repo.mongodb.org/yum/amazon/2/mongodb-org/4.0/x86_64/
        gpgcheck=1
        enabled=1
        gpgkey=https://www.mongodb.org/static/pgp/server-4.0.asc' | sudo tee /etc/yum.repos.d/mongodb-org-4.0.repo

        sudo wget -qO- https://www.mongodb.org/static/pgp/server-4.0.asc | sudo apt-key add -
        sudo yum install -y mongodb-org

        sudo systemctl start mongod
        sudo systemctl enable mongod
    EOF

    iam_instance_profile = aws_iam_instance_profile.ec2_management_profile.name

    # Creating a name to maintain sanity.
    tags = {
        Name = "mongodb"
    }
}

resource "aws_instance" "bastion1" {
    ami = "ami-04823729c75214919"
    instance_type = "t3.micro"
    subnet_id = aws_subnet.public_subnet1.id
    vpc_security_group_ids = [
        aws_security_group.egress_allow_ssh_to_mongodb.id,
        aws_security_group.ingress_allow_ssh_from_personal.id,
        aws_security_group.egress_allow_https_to_www.id
    ]
    key_name = aws_key_pair.ssh_key.key_name
    iam_instance_profile = aws_iam_instance_profile.bastion_profile.name

    # Creating a name to maintain sanity.
    tags = {
        Name = "bastion"
    }
}

# S3

# Allow public access to the bucket.
resource "aws_s3_bucket_public_access_block" "bucket1_makepub_config" {
    bucket = aws_s3_bucket.bucket1.id

    block_public_acls = false
    block_public_policy = false
    ignore_public_acls = false
    restrict_public_buckets = false
}

# Create bucket policy which allows public read access to the bucket.
resource "aws_s3_bucket_policy" "bucket1_makepub_policy" {
    bucket = aws_s3_bucket.bucket1.id
    policy = data.aws_iam_policy_document.bucket1_makepub_poldoc.json
}

# DATA SOURCES

# Create policy document for the bucket policy which allows public read access to the bucket.
data "aws_iam_policy_document" "bucket1_makepub_poldoc" {

    # Allow anyone to read bucket contents.
    statement {
        actions = ["s3:GetObject"]
        resources = ["${aws_s3_bucket.bucket1.arn}/*"]
        principals {
            type = "*"
            identifiers = ["*"]
        }
    }

    # Allow role attached to MongoDB instance to put objects in S3 bucket.
    statement {
        actions = ["s3:PutObject"]
        resources = ["${aws_s3_bucket.bucket1.arn}/*"]
        principals {
            type = "AWS"
            identifiers = [aws_iam_role.ec2_management_role.arn]
        }
    }
}

data "aws_iam_policy_document" "eks_assumerole" {
    statement {
        effect = "Allow"

        principals {
            type = "Service"
            identifiers = ["eks.amazonaws.com"]
        }
        
        actions = ["sts:AssumeRole"]
    }
}

# Allow only the MongoDB instance permissions to create/terminate other EC2 instances. Only allow this behavior from the EC2 service.
data "aws_iam_policy_document" "ec2_mgmt_poldoc" {
    statement {
        effect = "Allow"
        actions = [
            "ec2:RunInstances",
            "ec2:TerminateInstances"
        ]
        resources = ["*"]

        condition {
            test = "StringEquals"
            variable = "ec2:SourceInstanceARN"
            values = [aws_instance.compute1.arn]
        }
    }
}

# Create policy document to allow assuming EC2 for node group management.
data "aws_iam_policy_document" "ec2_assumerole" {
    statement {
        effect = "Allow"

        principals {
            type = "Service"
            identifiers = ["ec2.amazonaws.com"]
        }
        actions = ["sts:AssumeRole"]
    }
}

# Create policy document to allow the bastion host to use AWS Secrets Manager.
data "aws_iam_policy_document" "bastion_role_poldoc" {
    statement {
        actions = ["secretsmanager:GetSecretValue"]
        resources = [aws_secretsmanager_secret.compute1_ssh_private_key.arn]
    }
}

# CHECKME Create policy document to allow only Bastion instance profile to retrieve secret.
data "aws_iam_policy_document" "compute1_ssh_private_key_policy_poldoc" {
    statement {
        effect = "Allow"
        actions = ["secretsmanager:GetSecretValue"]
        resources = [aws_secretsmanager_secret.compute1_ssh_private_key.arn]

        principals {
            type = "AWS"
            identifiers = [aws_iam_role.bastion_role.arn]
        }
    }
}

data "aws_eks_cluster_auth" "cluster1-auth" {
    name = aws_eks_cluster.cluster1.name
}

# VPCS

resource "aws_vpc" "vpc1" {
    cidr_block = var.vpc_cidr_block
}

# SUBNETS

resource "aws_subnet" "public_subnet1" {
    cidr_block = var.vpc_subnet_cidr_block[0]
    vpc_id = aws_vpc.vpc1.id
    availability_zone = var.aws_availability_zone[0]
    map_public_ip_on_launch = true
}

resource "aws_subnet" "public_subnet2" {
    cidr_block = var.vpc_subnet_cidr_block[1]
    vpc_id = aws_vpc.vpc1.id
    availability_zone = var.aws_availability_zone[1]
    map_public_ip_on_launch = true
}

resource "aws_subnet" "private_subnet1" {
    cidr_block = var.vpc_subnet_cidr_block[2]
    vpc_id = aws_vpc.vpc1.id
    availability_zone = var.aws_availability_zone[0]
    map_public_ip_on_launch = false
}

resource "aws_subnet" "private_subnet2" {
    cidr_block = var.vpc_subnet_cidr_block[3]
    vpc_id = aws_vpc.vpc1.id
    availability_zone = var.aws_availability_zone[1]
    map_public_ip_on_launch = false
}

# GATEWAYS

resource "aws_internet_gateway" "igw1" {
    vpc_id = aws_vpc.vpc1.id
}

resource "aws_nat_gateway" "ngw1" {
    allocation_id = aws_eip.ngw_ip.id
    subnet_id = aws_subnet.public_subnet1.id
}

# EIPS

resource "aws_eip" "ngw_ip" {
    domain = "vpc"
}

# ROUTE TABLES

resource "aws_route_table" "rtb1" {
    vpc_id = aws_vpc.vpc1.id

    route {
        cidr_block = var.everyone_network
        gateway_id = aws_internet_gateway.igw1.id
    }
}

resource "aws_route_table" "rtb2" {
    vpc_id = aws_vpc.vpc1.id

    route {
        cidr_block = var.everyone_network
        nat_gateway_id = aws_nat_gateway.ngw1.id
    }
}

# ROUTE TABLE ASSOCIATIONS

resource "aws_route_table_association" "rta_public_subnet1" {
    subnet_id = aws_subnet.public_subnet1.id
    route_table_id = aws_route_table.rtb1.id
}

resource "aws_route_table_association" "rta_public_subnet2" {
    subnet_id = aws_subnet.public_subnet2.id
    route_table_id = aws_route_table.rtb1.id
}

resource "aws_route_table_association" "priv_rta1" {
    subnet_id = aws_subnet.private_subnet1.id
    route_table_id = aws_route_table.rtb2.id
}

resource "aws_route_table_association" "priv_rta2" {
    subnet_id = aws_subnet.private_subnet2.id
    route_table_id = aws_route_table.rtb2.id
}

# EKS

# Specify cluster configuration options.
resource "aws_eks_cluster" "cluster1" {
    name = "eks_cluster"
    role_arn = aws_iam_role.eks_assume_role.arn

    vpc_config {
        subnet_ids = [
            aws_subnet.private_subnet1.id,
            aws_subnet.private_subnet2.id
        ]
    }

    # IAM role permissions should be created before and deleted after the EKS cluster. Otherwise, EKS will not be able to properly delete EKS managed EC2 infrastructure (such as security groups). 
    depends_on = [
        # Allows use of EKS service.
        aws_iam_role_policy_attachment.eks_cluster_policy_attachment,
        # Allows security groups on pods.
        aws_iam_role_policy_attachment.eks_vpc_resource_controller_attachment
    ]
}

# Define worker nodes to join the cluster and desired configuration options.
resource "aws_eks_node_group" "eks_ng1" {
    cluster_name = aws_eks_cluster.cluster1.name
    node_group_name = "jenkins-node-group"
    node_role_arn = aws_iam_role.eks_node_group_role.arn
    subnet_ids = [
        aws_subnet.private_subnet1.id,
        aws_subnet.private_subnet2.id
    ]
    scaling_config {
        desired_size = 2
        max_size = 2
        min_size = 1
    }

    update_config {
        max_unavailable = 1
    }

    depends_on = [
        aws_iam_role_policy_attachment.AmazonEKSWorkerNodePolicy,
        aws_iam_role_policy_attachment.AmazonEKS_CNI_Policy,
        aws_iam_role_policy_attachment.AmazonEC2ContainerRegistryReadOnly
    ]
}

# SECURITY GROUPS

# Allow egress HTTPS to everywhere.
# For bastion instance, this is required for AWS Secrets Manager.
# For MongoDB instance, this is required for Amazon S3 and to install MongoDB.
resource "aws_security_group" "egress_allow_https_to_www" {
    name = "egress-https-to-www"
    description = "Allow egress HTTPS to everywhere."
    vpc_id = aws_vpc.vpc1.id
}

# Allow ingress SSH from personal IP address.
resource "aws_security_group" "ingress_allow_ssh_from_personal" {
    name = "ingress-allow-ssh-from-personal"
    description = "Allow ingress SSH from personal IP address."
    vpc_id = aws_vpc.vpc1.id
}

# Allow ingress SSH into MongoDB instance from bastion instance.
resource "aws_security_group" "ingress_allow_ssh_from_bastion" {
    name = "ingress-allow-ssh-from-bastion"
    description = "Allow ingress SSH from bastion instance."
    vpc_id = aws_vpc.vpc1.id
}

# Allow egress SSH from bastion instance to SSH into MongoDB instance.
resource "aws_security_group" "egress_allow_ssh_to_mongodb" {
    name = "egress-allow-ssh-to-mongodb"
    description = "Allow egress SSH into MongoDB instance."
    vpc_id = aws_vpc.vpc1.id
}

# Allow ingress NFS traffic so EKS can use scalable and persistent storage.
resource "aws_security_group" "ingress_allow_efs_from_eks" {
    name = "ingress-allow-efs-from-eks"
    description = "Allow ingress EFS for EKS."
    vpc_id = aws_vpc.vpc1.id
}

# SECURITY GROUP RULES

resource "aws_security_group_rule" "ingress_allow_efs_from_eks" {
    type = var.security_group_rule_type[0]
    from_port = var.nfs_port
    to_port = var.nfs_port
    protocol = var.network_protocol[0]
    security_group_id = aws_security_group.ingress_allow_efs_from_eks.id
    cidr_blocks = [var.vpc_cidr_block]
}

resource "aws_security_group_rule" "ingress_allow_ssh_from_bastion" {
    description = "Allow ingress SSH from bastion instance."
    type = var.security_group_rule_type[0]
    from_port = var.ssh_port
    to_port = var.ssh_port
    protocol = var.network_protocol[0]
    security_group_id = aws_security_group.ingress_allow_ssh_from_bastion.id
    source_security_group_id = aws_security_group.egress_allow_ssh_to_mongodb.id
}

resource "aws_security_group_rule" "egress_allow_https_to_www" {
    description = "Allow egress HTTPS to everywhere."
    type = var.security_group_rule_type[1]
    from_port = var.https_port
    to_port = var.https_port
    protocol = var.network_protocol[0]
    security_group_id = aws_security_group.egress_allow_https_to_www.id
    cidr_blocks = [var.everyone_network]
}

resource "aws_security_group_rule" "egress_allow_ssh_to_mongodb" {
    description = "Allow egress SSH to MongoDB instance."
    type = var.security_group_rule_type[1]
    from_port = var.ssh_port
    to_port = var.ssh_port
    protocol = var.network_protocol[0]
    security_group_id = aws_security_group.egress_allow_ssh_to_mongodb.id
    source_security_group_id = aws_security_group.ingress_allow_ssh_from_bastion.id
}

resource "aws_security_group_rule" "ingress_allow_ssh_from_personal" {
    description = "Allow ingress SSH from personal IP address."
    type = var.security_group_rule_type[0]
    from_port = var.ssh_port
    to_port = var.ssh_port
    protocol = var.network_protocol[0]
    security_group_id = aws_security_group.ingress_allow_ssh_from_personal.id
    cidr_blocks = [var.personal_network]
}

# IAM ROLES

# Role used for EKS cluster.
# Allows EKS to assume and perform necessary cluster management operations.
resource "aws_iam_role" "eks_assume_role" {
    name = "eks-assume-role"
    assume_role_policy = data.aws_iam_policy_document.eks_assumerole.json
}

# Role used for EKS node group.
# Allows EC2 to assume and perform necessary node group management operations and use EFS.
resource "aws_iam_role" "eks_node_group_role" {
    name = "eks-node-group-role"
    assume_role_policy = data.aws_iam_policy_document.ec2_assumerole.json
}

# Role used for MongoDB EC2 instance profile.
# Allows EC2 to assume and perform privileged EC2 operations.
resource "aws_iam_role" "ec2_management_role" {
    name = "ec2-mgmt-role"
    assume_role_policy = data.aws_iam_policy_document.ec2_assumerole.json
}

# Role used for bastion EC2 instance profile.
# Allows EC2 to assume and get specific secret from AWS Secrets Manager.
resource "aws_iam_role" "bastion_role" {
    name = "bastion-role"
    assume_role_policy = data.aws_iam_policy_document.ec2_assumerole.json
}

# IAM ROLE POLICY ATTACHMENTS

resource "aws_iam_role_policy_attachment" "eks_cluster_policy_attachment" {
    policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
    role = aws_iam_role.eks_assume_role.name
}

resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller_attachment" {
    policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
    role = aws_iam_role.eks_assume_role.name
}

# Allow EKS node group to mount EFS volumes.
resource "aws_iam_role_policy_attachment" "AmazonElasticFileSystemFullAccess" {
    policy_arn = "arn:aws:iam::aws:policy/AmazonElasticFileSystemFullAccess"
    role = aws_iam_role.eks_node_group_role.name
}

resource "aws_iam_role_policy_attachment" "AmazonEKSWorkerNodePolicy" {
    policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
    role = aws_iam_role.eks_node_group_role.name
}

resource "aws_iam_role_policy_attachment" "AmazonEKS_CNI_Policy" {
    policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
    role = aws_iam_role.eks_node_group_role.name
}

resource "aws_iam_role_policy_attachment" "AmazonEC2ContainerRegistryReadOnly" {
    policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
    role = aws_iam_role.eks_node_group_role.name
}

resource "aws_iam_role_policy_attachment" "bastion_role_policy_attachment" {
    role = aws_iam_role.bastion_role.name
    policy_arn = aws_iam_policy.bastion_role_policy.arn
}

resource "aws_iam_role_policy_attachment" "ec2_management_role_attachment" {
    role = aws_iam_role.ec2_management_role.name
    policy_arn = aws_iam_policy.ec2_management_policy.arn
}

# IAM POLICIES

# Allow MongoDB instance permission to perform privileged EC2 operations.
resource "aws_iam_policy" "ec2_management_policy" {
    name = "ec2-mgmt-policy"
    policy = data.aws_iam_policy_document.ec2_mgmt_poldoc.json
}

# Allow bastion instance to get specific secret from AWS Secrets Manager.
resource "aws_iam_policy" "bastion_role_policy" {
    name = "bastion-role-policy"
    policy = data.aws_iam_policy_document.bastion_role_poldoc.json
}

# IAM INSTANCE PROFILES

resource "aws_iam_instance_profile" "ec2_management_profile" {
    name = "ec2-mgmt-profile"
    role = aws_iam_role.ec2_management_role.name
}

resource "aws_iam_instance_profile" "bastion_profile" {
    name = "bastion-profile"
    role = aws_iam_role.bastion_role.name
}

# SECRETS

# Creates an AWS Secrets Manager entry for the private key used for the bastion instance to access the MongoDB instance.
resource "aws_secretsmanager_secret" "compute1_ssh_private_key" {
    # Did not specify a name since this affects destruction/recreation.
}

# Copy private key for MongoDB instance to AWS Secrets Manager so this can be used to programmatically perform backups.
resource "aws_secretsmanager_secret_version" "compute1_ssh_private_key_version" {
    secret_id = aws_secretsmanager_secret.compute1_ssh_private_key.id
    # This key was pre-generated, stored locally, and is gitignored.
    secret_string = file("/.ssh/ssh.pem")
}

#THIS IS NEW. CHECKME.
resource "aws_secretsmanager_secret_policy" "compute1_ssh_private_key_policy" {
    secret_arn = aws_secretsmanager_secret.compute1_ssh_private_key.arn
    policy = data.aws_iam_policy_document.compute1_ssh_private_key_policy_poldoc.json
}

# KEYS

# Set the public key for the MongoDB instance using the key pair that I generated locally.
resource "aws_key_pair" "compute1_ssh_key_pair" {
    # This key was pre-generated, stored locally, and is gitignored.
    public_key = file("/.ssh/id_rsa.pub")
}

# Use the public key from the key pair that I generated locally to SSH into the bastion host or the compute host from the bastion host to test some script stuff. This can probably be removed later.
resource "aws_key_pair" "ssh_key" {
    # This key was pre-generated, stored locally, and is gitignored.
    public_key = file("/.ssh/id_rsa.pub")
}