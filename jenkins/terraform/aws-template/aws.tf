terraform {
  required_providers {
    aws = {
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  # profile = "default"
  region  = "us-east-2"
}
