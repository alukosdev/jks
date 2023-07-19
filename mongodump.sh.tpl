#!/bin/bash

# Specify the AWS region.
export AWS_DEFAULT_REGION=${aws_region}
echo "Region set: ${aws_region}."

# Retrieve the private key from AWS Secrets Manager.
SECRET_NAME=${secret_name}
PRIVATE_KEY=$(aws secretsmanager get-secret-value --secret-id $SECRET_NAME --query 'SecretString' --output text)
echo "Key retrieved."

# Create a temporary file to store the private key.
TMP_FILE=$(mktemp)
echo "$PRIVATE_KEY" > "$TMP_FILE"
chmod 400 "$TMP_FILE"
echo "Key stored."

# Load the private key into the SSH agent.
eval "$(ssh-agent -s)"
ssh-add "$TMP_FILE"
echo "Key locked and loaded. Fire away!"

# SSH into the EC2 instance using the SSH agent.
ssh ec2-user@${compute_instance_private_ip} '
    BACKUP_DIR="/tmp/mongodb/backups" &&
    mkdir -p $${BACKUP_DIR} &&
    echo "Backup directory created: $${BACKUP_DIR}."
    TIMESTAMP=$(date +%Y%m%d%H%M%S) &&
    BACKUP_FILE="$${BACKUP_DIR}/backup_$${TIMESTAMP}.tar.gz" &&
    mongodump --archive="$${BACKUP_FILE}" --gzip &&
    echo "Backup created: $${BACKUP_FILE}."
    aws s3 cp "$${BACKUP_FILE}" "s3://${s3_bucket_name}"
    echo "Backup uploaded to S3 bucket: ${s3_bucket_name}."
'
echo "Session completed. Terminating connection."

# Clean up after yourself.
ssh-agent -k
rm "$TMP_FILE"