# State lives in S3, encrypted, with S3-native locking (no DynamoDB table). The bucket
# and key come from a file kept outside version control:
#   cp backend.hcl.example backend.hcl && terraform init -backend-config=backend.hcl
terraform {
  backend "s3" {}
}
