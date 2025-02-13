# Retrieve AWS regional zones
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  availability_zones = data.aws_availability_zones.available.names
}

# Initialise Random variable
resource "random_id" "id" {
  byte_length = 2
}

# Create random password for BIG-IP
resource "random_password" "password" {
  length           = 16
  special          = true
  override_special = "_%@"
}

# Create Secret Store and Store BIG-IP Password
resource "aws_secretsmanager_secret" "bigiq" {
  name = format("%s-secret-%s", var.tags.prefix, random_id.id.hex)
}

resource "aws_secretsmanager_secret_version" "bigiq-pwd" {
  secret_id     = aws_secretsmanager_secret.bigiq.id
  secret_string = random_password.password.result
}

# Create Module using community
module "aws_vpc" {
  source               = "terraform-aws-modules/vpc/aws"
  name                 = format("%s-%s-%s", var.tags.prefix, var.tags.environment, random_id.id.hex)
  cidr                 = var.aws_vpc_parameters.cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  azs = local.availability_zones

  # vpc public subnet used for external interface
  public_subnets = [
    for num in range(length(local.availability_zones)) :
    cidrsubnet(var.aws_vpc_parameters.cidr, 8, num + var.cidr_offsets.external)
  ]
  public_subnet_tags = {
    Name        = format("%s-%s-public", var.tags.prefix, random_id.id.hex)
    Terraform   = "true"
    Environment = var.tags.environment
  }

  # vpc private subnet used for internal
  private_subnets = [
    for num in range(length(local.availability_zones)) :
    cidrsubnet(var.aws_vpc_parameters.cidr, 8, num + var.cidr_offsets.internal)
  ]
  private_subnet_tags = {
    Name        = format("%s-%s-private", var.tags.prefix, random_id.id.hex)
    Terraform   = "true"
    Environment = var.tags.environment
  }

  enable_nat_gateway = true

  # using the database subnet method since it allows a public route
  database_subnets = [
    for num in range(length(local.availability_zones)) :
    cidrsubnet(var.aws_vpc_parameters.cidr, 8, num + var.cidr_offsets.management)
  ]
  create_database_subnet_group           = true
  create_database_subnet_route_table     = true
  create_database_internet_gateway_route = true
  database_subnet_tags = {
    Name        = format("%s-%s-mgmt", var.tags.prefix, random_id.id.hex)
    Terraform   = "true"
    Environment = var.tags.environment
  }

  # using the intra subnet method without public route for inspection in
  intra_subnets = [
    for num in range(length(local.availability_zones)) :
    cidrsubnet(var.aws_vpc_parameters.cidr, 8, num + var.cidr_offsets.inspect_in)
  ]
  intra_subnet_tags = {
    Name        = format("%s-%s-sslo-in", var.tags.prefix, random_id.id.hex)
    Terraform   = "true"
    Environment = var.tags.environment
  }

  # using the elasticache subnet method without public route for inspection out
  elasticache_subnets = [
    for num in range(length(local.availability_zones)) :
    cidrsubnet(var.aws_vpc_parameters.cidr, 8, num + var.cidr_offsets.inspect_out)
  ]
  elasticache_subnet_tags = {
    Name        = format("%s-%s-sslo-out", var.tags.prefix, random_id.id.hex)
    Terraform   = "true"
    Environment = var.tags.environment
  }
}

# Provision BIG-IQ (CM/DCD) for use within demo
module "big_iq_byol" {
  source = "github.com/merps/terraform-aws-bigiq"
  aws_secretmanager_secret_id = aws_secretsmanager_secret.bigiq.id
  cm_license_keys = [ var.licenses.cm_key ]
  ec2_key_name = var.ec2_public_key
  vpc_id = module.aws_vpc.vpc_id
  vpc_mgmt_subnet_ids = module.aws_vpc.database_subnets
  vpc_private_subnet_ids = module.aws_vpc.private_subnets
}

# Provision BIG-IP for the use of SSLO and BIG-IQ
/*
module "big_ip_sslo_payg" {
  source = "github.com/merps/terraform-aws-bigip"
  aws_secretmanager_secret_id = ""
  ec2_key_name = ""
}
*/