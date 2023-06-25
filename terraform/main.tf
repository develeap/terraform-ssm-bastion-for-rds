terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4"
    }
  }
}

provider "aws" {
  region = "us-east-2"
}

### VPC ###

resource "aws_vpc" "vpc" {
  cidr_block           = "10.55.0.0/16"
  enable_dns_hostnames = true
}

# Two private subnets in two availability zones
resource "aws_subnet" "private_subnet" {
  vpc_id               = aws_vpc.vpc.id
  count                = 2
  cidr_block           = "10.55.${count.index}.0/24"
  availability_zone_id = "use2-az${count.index + 1}"
}

### Aurora Postgres RDS ###

resource "aws_db_subnet_group" "subnet_group" {
  name       = "private"
  subnet_ids = [aws_subnet.private_subnet[0].id, aws_subnet.private_subnet[1].id]
}

resource "aws_security_group" "postgres" {
  name   = "rds-private"
  vpc_id = aws_vpc.vpc.id

  ingress {
    description     = "incoming connection from bastion"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_rds_cluster" "postgres" {
  cluster_identifier = "aurora-postgres-demo"
  engine             = "aurora-postgresql"
  //availability_zones = ["us-east-2a", "us-east-2b"]
  database_name          = "postgres"
  master_username        = "postgres"
  master_password        = "postgres"
  db_subnet_group_name   = aws_db_subnet_group.subnet_group.name
  vpc_security_group_ids = [aws_security_group.postgres.id]
  # When we delete the DB, it creates the final snapshot by default. 
  # We don’t need it for demo
  skip_final_snapshot    = true
}

resource "aws_rds_cluster_instance" "postgres" {
  identifier         = "postgres"
  cluster_identifier = aws_rds_cluster.postgres.id
  instance_class     = "db.t4g.medium"
  engine             = aws_rds_cluster.postgres.engine
}

### EC2 Bastion ###

data "aws_ami" "al2023" {
  most_recent      = true
  owners           = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"] # but not al2023* - the output can be ‘minimal’ type, that doesn’t have  SSM agent
  }
}

resource "aws_iam_role" "bastion" {
  name               = "bastion"
  assume_role_policy = <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
          "Effect": "Allow",
          "Principal": {
              "Service": ["ec2.amazonaws.com"]
          },
          "Action": "sts:AssumeRole"
        }
    ]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "bastion-ssm" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.bastion.name
}

resource "aws_iam_instance_profile" "bastion" {
  name = aws_iam_role.bastion.name
  role = aws_iam_role.bastion.name
}

# separate subnet for Bastion
resource "aws_subnet" "private_bastion_subnet" {
  vpc_id               = aws_vpc.vpc.id
  cidr_block           = "10.55.2.0/24"
  availability_zone_id = "use2-az1"
}

# security group for VPC endpoints
resource "aws_security_group" "ssm_endpoints" {
  name   = "ssm_endpoints"
  vpc_id = aws_vpc.vpc.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "TCP"
    cidr_blocks = [aws_subnet.private_bastion_subnet.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# SSM endpoint
resource "aws_vpc_endpoint" "ssm" {
  vpc_endpoint_type   = "Interface"
  vpc_id              = aws_vpc.vpc.id
  service_name        = "com.amazonaws.us-east-2.ssm"
  private_dns_enabled = true
  subnet_ids          = [aws_subnet.private_bastion_subnet.id]
  security_group_ids  = [aws_security_group.ssm_endpoints.id]
}

# SSM messages endpoint
resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_endpoint_type   = "Interface"
  vpc_id              = aws_vpc.vpc.id
  service_name        = "com.amazonaws.us-east-2.ssmmessages"
  private_dns_enabled = true
  subnet_ids          = [aws_subnet.private_bastion_subnet.id]
  security_group_ids  = [aws_security_group.ssm_endpoints.id]
}

# EC2 messages endpoint
resource "aws_vpc_endpoint" "ec2messages" {
  vpc_endpoint_type   = "Interface"
  vpc_id              = aws_vpc.vpc.id
  service_name        = "com.amazonaws.us-east-2.ec2messages"
  private_dns_enabled = true
  subnet_ids          = [aws_subnet.private_bastion_subnet.id]
  security_group_ids  = [aws_security_group.ssm_endpoints.id]
}

# Security group for bastion, outbound only
resource "aws_security_group" "bastion" {
  name   = "bastion"
  vpc_id = aws_vpc.vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EC2 instance
resource "aws_instance" "bastion" {
  depends_on             = [aws_rds_cluster.postgres, aws_s3_object.socat]
  subnet_id              = aws_subnet.private_bastion_subnet.id
  ami                    = data.aws_ami.al2023.id 
  instance_type          = "t2.micro"
  iam_instance_profile   = aws_iam_instance_profile.bastion.name
  vpc_security_group_ids = [aws_security_group.bastion.id]
  user_data              = <<EOF
#!/bin/bash
cd ~
aws s3 cp s3://${aws_s3_bucket.private_bastion_resources.id}/bastion_resources/socat.rpm .
sudo yum install -y ./socat.rpm
sudo socat TCP-LISTEN:5432,reuseaddr,fork TCP4:${aws_rds_cluster.postgres.endpoint}:5432 & 
EOF
}

output instance_id {
  value = aws_instance.bastion.id
}

### S3 connection setup ###

# Route table for S3 Gateway endpoint
resource "aws_route_table" "bastion" {
  vpc_id = aws_vpc.vpc.id
}

# Bind route table to bastion's subnet
resource "aws_route_table_association" "bastion" {
  subnet_id      = aws_subnet.private_bastion_subnet.id
  route_table_id = aws_route_table.bastion.id
}

# S3 VPC Endpoint
resource "aws_vpc_endpoint" "s3" {
  vpc_id          = aws_vpc.vpc.id
  service_name    = "com.amazonaws.us-east-2.s3"
  route_table_ids = [aws_route_table.bastion.id]
}

# S3 bucket for socat utility
resource "aws_s3_bucket" "private_bastion_resources" {
  bucket_prefix = "private-bastion-resources"
}

# Basic security requirement for S3 buckets
resource "aws_s3_bucket_public_access_block" "bastion" {
  bucket = aws_s3_bucket.private_bastion_resources.id
  block_public_acls   = true
  block_public_policy = true
  ignore_public_acls = true
  restrict_public_buckets = true
}

# Download the socat utility
resource "null_resource" "socat" {
  provisioner "local-exec" {
    command = "curl -o socat.rpm https://kojipkgs.fedoraproject.org/packages/socat/1.7.4.4/2.fc38/x86_64/socat-1.7.4.4-2.fc38.x86_64.rpm"
  }
}

# And upload it to S3 bucket
resource "aws_s3_object" "socat" {
  depends_on = [null_resource.socat]
  bucket     = aws_s3_bucket.private_bastion_resources.id
  key        = "/bastion_resources/socat.rpm"
  source     = "./socat.rpm"
}

# IAM Policy to allow downloading the files
resource "aws_iam_policy" "bastion_s3" {
  name_prefix = "bastion_s3"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:GetObject"
        ]
        Effect   = "Allow"
        Resource = "${aws_s3_bucket.private_bastion_resources.arn}/bastion_resources/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "bastion_resources" {
  policy_arn = aws_iam_policy.bastion_s3.arn
  role       = aws_iam_role.bastion.name
}



### IAM Policy that allows usage of the bastion ###

resource "aws_iam_policy" "private_rds_ssm_access" {
  name_prefix = "private_rds_ssm_access"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "ssm:DescribeDocument",
          "ssm:GetDocument"
        ]
        Effect   = "Allow"
        Resource = "arn:aws:ssm:*::document/AWS-StartPortForwardingSession"
      },
      {
        Action = [
          "ssm:StartSession"
        ]
        Effect   = "Allow"
        Resource = "${aws_instance.bastion.arn}"
      },
      {
        Action = [
          "ssm:ResumeSession",
          "ssm:TerminateSession"
        ]
        Effect   = "Allow"
        Resource = "arn:aws:ssm:*:*:session/$${aws:username}-*"
      }
    ]
  })
}