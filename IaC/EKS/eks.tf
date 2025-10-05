locals {
  # Cannot use random until https://github.com/hashicorp/terraform-provider-aws/issues/19583 is fixed
  # cluster_name_full = "${var.cluster_name}-${random_string.suffix.result}"
  cluster_name_full = var.cluster_name
}

resource "random_string" "suffix" {
  length  = 4
  upper   = false
  special = false
}

data "aws_availability_zones" "available" {}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "=21.2.0"

  name               = local.cluster_name_full
  kubernetes_version = var.cluster_version

  endpoint_private_access = true
  endpoint_public_access  = true

  addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_driver_irsa_role.arn
    }
    kube-proxy = {}
    vpc-cni    = {}
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  access_entries = {
    demouser = {
      principal_arn = data.aws_iam_user.demo_user.arn
      policy_associations = {
        single = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
          access_scope = {
            namespaces = ["default"]
            type       = "namespace"
          }
        }
      }
    }
  }

  eks_managed_node_groups = {
    one = {
      min_size     = 1
      max_size     = 4
      desired_size = 2

      instance_types = ["t3.medium"]
      capacity_type  = "SPOT"
      ami_type       = "AL2023_x86_64_STANDARD"

      iam_role_additional_policies = {
        additional = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
      }
    }
  }
  node_security_group_additional_rules = {
    ingress_allow_access_for_kubeseal = {
      type                          = "ingress"
      protocol                      = "tcp"
      from_port                     = 8080
      to_port                       = 8080
      source_cluster_security_group = true
      description                   = "Allow access from kubeseal to fetch cert"
    },
    ingress_allow_access_from_nodes = {
      type        = "ingress"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      self        = true
      description = "allow_access_between_nodes_ingress"
    },
    egress_allow_from_nodes = {
      type        = "egress"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      self        = true
      description = "allow_access_between_nodes_egress"
    }
  }

  cluster_tags = var.eks_tags
}

resource "null_resource" "eks_kubecfg" {
  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --name ${module.eks.cluster_name}"
  }

  depends_on = [
    module.eks
  ]
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "pc-demo-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name_full}" = "shared"
    "kubernetes.io/role/elb"                           = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name_full}" = "shared"
    "kubernetes.io/role/internal-elb"                  = 1
  }
}

resource "aws_security_group" "allow_lb_sg" {
  # checkov:skip=CKV2_AWS_5: to be used by AWS LB
  name        = "allow-http"
  description = "Allow HTTP inbound traffic"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "http from internet/trusted to ALB"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.trusted_networks
  }

  tags = {
    Name = "allow-http"
  }
}

module "load_balancer_controller_irsa_role" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"

  name                                   = "AmazonEKSLoadBalancerControllerRole"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

module "ebs_csi_driver_irsa_role" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"

  name                  = "AmazonEKS_EBS_CSI_DriverRole"
  attach_ebs_csi_policy = true

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "kubernetes_service_account" "aws_lb_sa" {
  metadata {
    name = "aws-load-balancer-controller"
    labels = {
      "app.kubernetes.io/component" : "controller",
      "app.kubernetes.io/name" : "aws-load-balancer-controller"
    }
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" : module.load_balancer_controller_irsa_role.arn
    }
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  chart      = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  version    = "1.5.3"

  namespace = "kube-system"

  set = [
    {
      name  = "clusterName"
      value = module.eks.cluster_name
    },

    {
      name  = "serviceAccount.create"
      value = "false"
    },

    {
      name  = "serviceAccount.name"
      value = "aws-load-balancer-controller"
    }
  ]
  depends_on = [
    kubernetes_service_account.aws_lb_sa,
    module.load_balancer_controller_irsa_role,
    aws_security_group.allow_lb_sg
  ]
}

resource "aws_iam_policy" "describe_cluster_pol" {
  name        = "DescribeCluster"
  description = "Allow user ability to auth to private ECR repos"

  policy = jsonencode({
    Version : "2012-10-17",
    Statement : [
      {
        Action : [
          "eks:DescribeCluster"
        ],
        Effect : "Allow",
        Resource : "${module.eks.cluster_arn}"
      }
    ]
  })
}

resource "aws_iam_user_policy_attachment" "describe_cluster_attach" {
  user       = var.demo_user_username
  policy_arn = aws_iam_policy.describe_cluster_pol.arn
}

