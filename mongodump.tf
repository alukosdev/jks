# Uses a precreated templatefile which leverages resources (so we don't need to manually configure them) to generate the backup script.
resource "local_file" "backup_script" {
    # Create this file...
    filename ="./mongodump.sh"
    # ...based on this templatefile...
    content = templatefile("${path.module}/mongodump.sh.tpl", { 
        # ...and pass these variables into the file:
        aws_region = var.aws_region[0]
        secret_name = aws_secretsmanager_secret.compute1_ssh_private_key.name
        compute_instance_private_ip = aws_instance.compute1.private_ip
        s3_bucket_name = aws_s3_bucket.bucket1.id
    })
}