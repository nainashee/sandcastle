terraform {
  backend "s3" {
    backend = "sandcastle-terraform-state-989126024881"
    key     = "phase-1/terraform.tfstate"
    region  = "us-east-1"

  }
}
