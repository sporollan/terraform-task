terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.98.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = ">= 5.21.0"

  name = "tftask-vpc"
  cidr = "10.0.0.0/16"

  azs = ["us-east-1a", "us-east-1b"] # 2 availability zones

  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]   # 2 public subnets
  private_subnets = ["10.0.101.0/24", "10.0.102.0/24"] # 2 private subnets

  # Enable NAT gateway for private subnet internet access
  enable_nat_gateway     = true
  single_nat_gateway     = true
  enable_dns_hostnames   = true
  enable_dns_support     = true
}

data "aws_ami" "amazon_linux2" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

# SSM Configuration
#resource "aws_iam_role" "ssm_role" {
#  name = "ssm-managed-instance-role"
#  assume_role_policy = data.aws_iam_policy_document.ssm_assume_role.json
#}
#
#data "aws_iam_policy_document" "ssm_assume_role" {
#  statement {
#    actions = ["sts:AssumeRole"]
#    principals {
#      type        = "Service"
#      identifiers = ["ec2.amazonaws.com"]
#    }
#  }
#}

#resource "aws_iam_role_policy_attachment" "ssm_attach" {
#  role       = aws_iam_role.ssm_role.name
#  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
#}
#
#resource "aws_iam_instance_profile" "ssm_profile" {
#  name = "ssm-instance-profile"
#  role = aws_iam_role.ssm_role.name
#}
# SSM CONFIGURATION END

# Security Group for the ELB
resource "aws_security_group" "elb_sg" {
  name        = "elb-sg"
  description = "Allow HTTP inbound"
  vpc_id      = module.vpc.vpc_id

  # Receive traffic on port 80
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "elb-sg"
  }
}

# Security Group for EC2 instances
resource "aws_security_group" "app_sg" {
  name        = "app-sg"
  description = "Allow HTTP from ELB"
  vpc_id      = module.vpc.vpc_id

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "app-sg"
  }
}

# Security Group Rule for ELB to App communication
resource "aws_security_group_rule" "elb_to_app" {
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.elb_sg.id
  security_group_id        = aws_security_group.app_sg.id
}

resource "aws_instance" "app" {
  count                  = 2

  # Attach ssm for initialization debug
  #iam_instance_profile   = aws_iam_instance_profile.ssm_profile.name

  ami                   = data.aws_ami.amazon_linux2.id
  instance_type         = "t2.micro"
  subnet_id             = element(module.vpc.private_subnets, count.index)
  vpc_security_group_ids = [aws_security_group.app_sg.id]

  user_data = base64encode(<<-EOF
    #!/bin/bash
    sleep 30
    yum update -y
    yum install -y httpd
    systemctl start httpd
    systemctl enable httpd
    echo "Hello from $(hostname -f)" > /var/www/html/index.html
  EOF
  )

  tags = {
    Name = "tftask-app-${count.index + 1}"
  }
}

# Load Balancer definition
resource "aws_elb" "app_lb" {
  name            = "tftask-elb"
  security_groups = [aws_security_group.elb_sg.id]
  subnets         = module.vpc.public_subnets

  listener {
    instance_port     = 80
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }

  health_check {
    target              = "HTTP:80/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  # Register the instances
  instances                   = aws_instance.app[*].id
  cross_zone_load_balancing   = true
  idle_timeout               = 400
  connection_draining        = true
  connection_draining_timeout = 400

  tags = {
    Name = "tftask-elb"
  }
}
