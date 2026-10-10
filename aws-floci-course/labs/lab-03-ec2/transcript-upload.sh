#!/usr/bin/env bash
# Upload a student transcript to S3 from usms-web-01.
# Usage: transcript-upload.sh <student-id> <file>
# No credentials are read or set here: the instance profile supplies them at run time.
set -euo pipefail

BUCKET="${USMS_BUCKET_NAME:-usms-student-data}"

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <student-id> <file>" >&2
  exit 64
fi

STUDENT_ID="$1"
FILE="$2"

if ! [[ "$STUDENT_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "error: student id must be letters, digits, '-' or '_' (got: '$STUDENT_ID')" >&2
  exit 64
fi
if [ ! -f "$FILE" ] || [ ! -r "$FILE" ]; then
  echo "error: '$FILE' is not a readable file" >&2
  exit 66
fi

DEST="s3://${BUCKET}/transcripts/${STUDENT_ID}/$(basename "$FILE")"
aws s3 cp "$FILE" "$DEST"
echo "uploaded to $DEST"
