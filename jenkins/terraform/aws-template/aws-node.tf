resource "aws_security_group" "sg_ssh_ingress" {

  name = "sg_ssh_ingress"

  ingress {
    from_port        = 22
    to_port          = 22
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"] # Feel free to lock this down
    description      = "Allow ssh access from anyone"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = -1
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_ami" "ubuntu_minimal" {
    most_recent = true
    filter {
        name = "name"
        values = [ "ubuntu-minimal/images/hvm-ssd/ubuntu-jammy-*-amd64-minimal-??????*" ]
    }
    owners = [ "099720109477" ]
}


variable "keys" {
  type = string
  default = <<EOF
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGJ/InU0oKBAtnnsqAah9uupgHY46boO2ba/GRmxsCX9 andrewg@IBM-PW05FM02
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPFLYUWLkirzBlw1LkhcVRCd+z+CFurE/lSSnt2XfNod williamspatrick@gmail.com
ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBE96goBKyOXfowXC7Ee5lVuIGW2Itw6wa9t9o2QlyKrt8Y0Uza91vUuDrNnbv14MPhWVVCMcOpO5lg6hhXZBIiQ= patrickw3@patrickw3-mbp
EOF
}

resource "aws_instance" "jenkins_node" {
    count = local.count
    ami             = data.aws_ami.ubuntu_minimal.id
    instance_type   = "m8g.8xlarge"
    security_groups = [ aws_security_group.sg_ssh_ingress.name ]
    availability_zone = local.availability_zones[count.index % length(local.availability_zones)]
    user_data       = templatefile("${path.module}/config/aws-node-config.yaml",
      {
        jenkins_service = templatefile("${path.module}/config/jenkins-agent.service", 
          { 
            jenkins_host = "builder_${local.companyId}_c${tostring(count.index)}", 
            jenkins_secret = lookup(var.jenkins_secrets, "secret${tostring(count.index)}") 
          }
        )
        jenkins_script = file("${path.module}/config/jenkins-agent")
        ssh_keys = trimspace(var.keys)
      }
    )

  root_block_device {
    delete_on_termination = true
    volume_size           = 15 
    volume_type           = "gp3"
  }

    tags = {
        Name = "builder_${local.companyId}_c${tostring(count.index)}"
    }
}

resource "aws_ebs_volume" "build_data" {
  count             = local.count
  size              = 1600
  type              = "gp3"
  availability_zone = local.availability_zones[count.index % length(local.availability_zones)]
  throughput        = 1000
  iops              = 40000

  tags = {
    Name = "builder_${local.companyId}_c${tostring(count.index)}_build_data"
  }
}

resource "aws_volume_attachment" "build_data_attachment" {
  count                          = length(aws_instance.jenkins_node)
  instance_id                    = aws_instance.jenkins_node[count.index].id
  volume_id                      = aws_ebs_volume.build_data[count.index].id
  device_name                    = "/dev/sdd"
  stop_instance_before_detaching = true
}
