terraform {
  # 1.11: S3 state locking without DynamoDB (use_lockfile) is generally available.
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }
}
