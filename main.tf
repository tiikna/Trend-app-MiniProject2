terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = "ap-south-1"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.5"

  name = "trend-mini"
  cidr = "10.0.0.0/16"

  azs                 = ["ap-south-1a", "ap-south-1b"]
  public_subnets      = ["10.0.1.0/24", "10.0.2.0/24"]
  enable_dns_hostnames = true
  enable_dns_support   = true
  map_public_ip_on_launch = true   # ensures EKS nodes get public IPs

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  
  tags = { Project = "trend-mini" }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.11"

  cluster_name    = "trend-mini-cluster"
  cluster_version = "1.30"

  subnet_ids = module.vpc.public_subnets
  vpc_id     = module.vpc.vpc_id

  cluster_endpoint_public_access = true

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.small"]
      desired_size   = 1
      min_size       = 1
      max_size       = 1
      subnet_ids     = module.vpc.public_subnets
    }
  }

  tags = { Project = "trend-mini" }
}

resource "aws_key_pair" "this" {
  key_name   = "trend-mini-kp"
  public_key = file("C:/Users/admin/.ssh/id_rsa.pub")  # Windows path to your public key
}

resource "aws_security_group" "jenkins_sg" {
  name   = "trend-mini-jenkins-sg"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "jenkins" {
  ami                         = "ami-0b9093ea00a0fed92"  # Ubuntu 22.04 LTS Mumbai ap-south-1 (replace with correct static AMI if needed)
  instance_type               = "t3.micro"
  subnet_id                   = module.vpc.public_subnets[0]
  key_name                    = aws_key_pair.this.key_name
  vpc_security_group_ids      = [aws_security_group.jenkins_sg.id]
  associate_public_ip_address = true

  user_data = <<-EOF
    #!/bin/bash
    set -e

    apt update -y
    apt install -y docker.io git unzip curl gnupg lsb-release software-properties-common

    systemctl enable docker
    systemctl start docker
    usermod -aG docker ubuntu

    # Jenkins
    curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | sudo tee \
      /usr/share/keyrings/jenkins-keyring.asc > /dev/null
    echo deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
      https://pkg.jenkins.io/debian-stable binary/ | sudo tee \
      /etc/apt/sources.list.d/jenkins.list > /dev/null
    apt update
    apt install -y openjdk-17-jdk jenkins
    systemctl enable jenkins
    systemctl start jenkins

    # awscli v2
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip -q awscliv2.zip
    ./aws/install

    # kubectl
    curl -LO "https://dl.k8s.io/release/$(curl -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

    # helm
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

    # eksctl
    curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /usr/local/bin

  EOF

  tags = {    Name = "trend-mini-jenkins"  }
}


output "cluster_name" {  value = module.eks.cluster_name }
output "cluster_endpoint" {  value = module.eks.cluster_endpoint }
output "cluster_ca" {  value = module.eks.cluster_certificate_authority_data }
output "jenkins_public_ip" {  value = aws_instance.jenkins.public_ip }
