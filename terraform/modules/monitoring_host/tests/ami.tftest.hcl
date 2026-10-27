# The Debian AMI is looked up once and then kept: a newer AMI must not replace the
# host (and restart the stack) on an unrelated apply. Runs share state, in order.

mock_provider "aws" {
  source = "./tests/mocks"
}

variables {
  name              = "obs-test"
  vpc_id            = "vpc-0123456789abcdef0"
  subnet_id         = "subnet-0123456789abcdef0"
  availability_zone = "eu-central-1a"
  ssh_public_keys   = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA7Cw5ej7R9CGhpYVY7xfCsA7eAE4JnZtPUT7JzxqZuy operator@example.com"]
  ssh_ingress_cidrs = ["198.51.100.10/32"]
}

run "creates_with_current_ami" {
  command = apply

  assert {
    condition     = aws_instance.this.ami == "ami-0aaaaaaaaaaaaaaaa"
    error_message = "The instance must boot the AMI found at creation."
  }
}

run "keeps_ami_when_debian_publishes_a_new_one" {
  command = apply

  override_data {
    target = data.aws_ami.debian[0]
    values = {
      id = "ami-0bbbbbbbbbbbbbbbb"
    }
  }

  assert {
    condition     = data.aws_ami.debian[0].id == "ami-0bbbbbbbbbbbbbbbb"
    error_message = "The lookup must see the newer AMI."
  }

  assert {
    condition     = aws_instance.this.ami == "ami-0aaaaaaaaaaaaaaaa"
    error_message = "The instance must keep the AMI it was created with."
  }
}

run "explicit_ami_takes_effect" {
  command = plan

  variables {
    ami_id = "ami-0cccccccccccccccc"
  }

  assert {
    condition     = aws_instance.this.ami == "ami-0cccccccccccccccc"
    error_message = "An explicit ami_id must be used."
  }

  assert {
    condition     = length(data.aws_ami.debian) == 0 && length(terraform_data.ami) == 0
    error_message = "No lookup may happen when ami_id is set."
  }
}
