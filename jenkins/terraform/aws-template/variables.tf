locals {
  # This is hardcoded for us-east-2
  availability_zones = [
    "us-east-2a",
    "us-east-2b",
    "us-east-2c"
  ]
  companyId = "acme" # TODO: update so name is accurate
  count = 1 # Change for more workers
}

variable "jenkins_secrets" {
  type = map(string)
  default = {
    "secret0" = "GET FROM JENKINS ADMIN" # TODO: replace with actual value
  }
}

