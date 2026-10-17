terraform {
  backend "s3" {
    bucket       = "terraform-state"
    key          = "infra/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true

    endpoints = {
      s3 = "http://192.168.2.4:9000"
    }

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true

    #force_path_style = true
    use_path_style = true
    insecure       = true
  }
}

