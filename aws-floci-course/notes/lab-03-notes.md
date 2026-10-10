# Lab 03 notes

## Review Q2 (draft): policy for a bucket that does not exist
An IAM policy is a statement about ARNs, not a reference to existing objects, so granting
access to arn:aws:s3:::usms-student-data before the bucket exists is valid. The permission
has no effect until something appears at that ARN. When the bucket is created, usms-web-01
gains the ability to write transcripts through its instance profile, with no access key on disk.
