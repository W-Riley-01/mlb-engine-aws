resource "aws_s3_bucket" "practice" {
  bucket = "mlb-engine-practice-4462"
}

resource "aws_s3_bucket_versioning" "practice" {
  bucket = aws_s3_bucket.practice.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "practice" {
  bucket = aws_s3_bucket.practice.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

resource "aws_s3_bucket" "mlb_engine_data" {
  bucket = "mlb-engine-data-4462"

  tags = {
    Project     = "mlb-engine"
    Environment = "dev"
    Owner       = "william"
  }
}

resource "aws_s3_bucket_versioning" "mlb_engine_data" {
  bucket = aws_s3_bucket.mlb_engine_data.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "mlb_engine_data" {
  bucket = aws_s3_bucket.mlb_engine_data.id

  rule {
    id     = "transition-to-ia-then-glacier"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }
  }
}