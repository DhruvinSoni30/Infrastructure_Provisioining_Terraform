#!/bin/bash
# Installing Dependencies 
ebs_device="/dev/xvdf"
sudo apt-get update -y
sudo apt-get install xfsprogs -y
sudo apt-get install jq -y
sudo apt install awscli -y
sudo apt-get update -y
sudo mkfs -t ext4 $ebs_device
splunkdir=/opt/splunk
logfile=/tmp/logs.txt
tmpfile=/tmp/tmp.txt
sudo touch $logfile
sudo touch $tmpfile

# Checking whether splunk home directory exists or not if not then creating it 
if [ -d $splunkdir ]; then
    echo "$splunkdir" exists
else
    sudo mkdir $splunkdir
    echo "dir created" >> $logfile
fi

sleep 10

# Mounting EBS volume to splunk home directory
sudo mount $ebs_device $splunkdir
mount_exitcode=$?
    if [ "$mount_exitcode" != "0" ]; then
        echo "Mount failed" >> $logfile
        echo $mount_exitcode >> $logfile
    fi

# Getting the Instance details
identity_doc=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document/)
availability_zone=$(echo "$identity_doc" | jq -r '.availabilityZone')
instance_id=$(echo "$identity_doc" | jq -r '.instanceId')
private_ip=$(echo "$identity_doc" | jq -r '.privateIp')
public_ip=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
account_id=$(echo "$identity_doc" | jq -r '.accountId')
region=$(echo "$identity_doc" | jq -r '.region')
ebs_tag_key="Snapshot"
ebs_tag_value="true"

# Getting tags from EC2 instance
tags=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$instance_id" --region="$region" | jq '.Tags[]')
echo "$tags" >> $logfile

# Getting the value of tag role
role=$(echo "$tags" | jq -r 'select(.Key == "role") .Value')
echo "$role" >> $logfile

# Creating the hostname
hostname="${role//_/-}-${instance_id}"
echo "$hostname" >> $logfile

# Setting the hostname 
sudo hostname "$instance_id"

# Creating DNS and adding in hosts file
echo "$private_ip $instance_id" | tee --append /etc/hosts

# Creating Name tag and attach it to EC2 instance
aws ec2 create-tags --resources "$instance_id" --region="$region" --tags "Key=Name,Value=$hostname"

if [ $? -eq 0 ]; then
    echo "Tag attached" >> $logfile
fi

# Retrieving the volume ids whose state is available
volume_ids=$(aws ec2 describe-volumes --region "$region" --filters Name=tag:"$ebs_tag_key",Values="$ebs_tag_value" Name=availability-zone,Values="$availability_zone" Name=status,Values=available | jq -r '.Volumes[].VolumeId')	
echo "$volume_ids"  >> $logfile	    	
if [ -n "$volume_ids" ]; then	
    break	
fi	

# Attaching the volume to the Instance (The volume will remain the same after instance gets reprovision)
for volume_id in $volume_ids; do
    aws ec2 attach-volume --region "$region" --volume-id "$volume_id" --instance-id "$instance_id" --device "$ebs_device"

    # Checking whether volume attached or not
    if [ $? -eq 0 ]; then
        echo "Volume attached" >> $logfile
        attached_volume=$volume_id
    fi
done

# Wait till volume gets attached
state=$(aws ec2 describe-volumes --region "$region" --volume-ids "$attached_volume" | jq -r '.Volumes[].Attachments[].State')	
if [ "$state" == "attached" ]; then	
    echo "Volume attached success"  >> $logfile	
fi	
sleep 5	

# Checking whether volume is already mounted or not if not then mount it
df -h | grep -i /opt/splunk
mount_code=$?

if [ "$mount_code" != "0" ]; then
    # Mounting the EBS volume to splunkdir
    sudo mount $ebs_device $splunkdir   
    mount_exitcode=$?
    if [ "$mount_exitcode" != "0" ]; then
      echo "Mount failed" >> $logfile
      echo $mount_exitcode >> $logfile
    fi
fi

# Retrieve EIPs that are not associate with any Instance
eips=$(aws ec2 describe-addresses --query "Addresses[?NetworkInterfaceId == null ].PublicIp" --region="$region" --output text)

# Attaching EIP 
aws ec2 associate-address --region "$region" --public-ip "$eips" --instance-id "$instance_id"
