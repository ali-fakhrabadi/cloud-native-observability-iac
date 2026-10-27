# Values AWS would compute. The real provider still validates arguments, so ARNs and
# IDs must look real; documentation addresses (RFC 5737) stand in for public IPs.

mock_data "aws_ami" {
  defaults = {
    id = "ami-0aaaaaaaaaaaaaaaa"
  }
}

mock_data "aws_partition" {
  defaults = {
    partition = "aws"
  }
}

mock_resource "aws_iam_role" {
  defaults = {
    arn = "arn:aws:iam::123456789012:role/obs-test-20261027"
  }
}

mock_resource "aws_ebs_volume" {
  defaults = {
    id = "vol-0123456789abcdef0"
  }
}

mock_resource "aws_eip" {
  defaults = {
    id        = "eipalloc-0123456789abcdef0"
    public_ip = "203.0.113.10"
  }
}

mock_resource "aws_instance" {
  defaults = {
    id         = "i-0123456789abcdef0"
    private_ip = "10.20.0.10"
  }
}
