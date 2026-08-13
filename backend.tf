terraform {
  backend "s3" {
    bucket         = "mlb-engine-tfstate-4462"
    key            = "weekend1/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "mlb-engine-tfstate-lock"
    encrypt        = true
  }
}