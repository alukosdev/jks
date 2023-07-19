# Uses a precreated templatefile which leverages resources (so we don't need to manually configure them) to generate the persistent volume file.
resource "local_file" "persistent_volume" {
    # Create this file...
    filename ="./persistentvolume.yaml"
    # ...based on this templatefile...
    content = templatefile("${path.module}/persistentvolume.yaml.tpl", { 
        # ...and pass these variables into the file:
        aws_ap = aws_efs_access_point.jenkins_efs_ap1.id
        aws_fs = aws_efs_file_system.jenkins_efs.id
    })
}