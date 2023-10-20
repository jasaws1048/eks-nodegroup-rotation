#!/bin/sh
# This script is used to rotate nodes in a nodegroup
# Usage: ./nodegroup_rotation.sh <cluster_name> <nodegroup_name>
# Example: ./nodegroup_rotation.sh my-cluster my-nodegroup
# This script assumes that the AWS CLI is installed and configured
# It also assumes that the kubectl command is installed and configured

CLUSTER_NAME=$1
NEW_NODEGROUP_NAME=$2

# Get the instance types of the current node groups
OLD_NODEGROUP_NAME=$(eksctl get nodegroup --cluster=$CLUSTER_NAME --output=json | jq -r '.[].Name')
echo $OLD_NODEGROUP_NAME


echo "Processing node group: $OLD_NODEGROUP_NAME"
# Get the instance type of the first node in the current node group
NODE_NAME=$(kubectl get nodes -l eks.amazonaws.com/nodegroup="$OLD_NODEGROUP_NAME" --output=jsonpath='{.items[0].metadata.name}')
INSTANCE_TYPE=$(kubectl get node "$NODE_NAME" --output=jsonpath='{.metadata.labels.beta\.kubernetes\.io/instance-type}')
echo "The $OLD_NODEGROUP_NAME has Instance Type:  $INSTANCE_TYPE"

#Creating new node group with retrieved instance types
echo "Creating new nodegroup with name $NEW_NODEGROUP_NAME with $INSTANCE_TYPE"
eksctl create nodegroup --cluster=$CLUSTER_NAME --name=$NEW_NODEGROUP_NAME --node-type=$INSTANCE_TYPE --nodes-min=1

# Specify your CloudFormation stack name
STACK_NAME="eksctl-$CLUSTER_NAME-nodegroup-$NEW_NODEGROUP_NAME"

# Wait for the stack to be created completely
echo "Waiting for the stack $STACK_NAME to be created..."

# Poll the stack status in a loop until it reaches CREATE_COMPLETE state
while true; do
    STATUS=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].StackStatus" --output text)

    if [ "$STATUS" == "CREATE_COMPLETE" ]; then
        echo "Stack $STACK_NAME has been created successfully. Proceeding to the next step."
        # Break out of the loop since the stack is in CREATE_COMPLETE state
        break
    elif [ "$STATUS" == "CREATE_FAILED" ] || [ "$STATUS" == "ROLLBACK_COMPLETE" ] || [ "$STATUS" == "DELETE_COMPLETE" ] || [ "$STATUS" == "ROLLBACK_FAILED" ] || [ "$STATUS" == "DELETE_FAILED" ]; then
        echo "Failed to create stack $STACK_NAME. Stack status: $STATUS. Exiting the script."
        exit 1
    else
        echo "Stack status: $STATUS. Waiting for the stack to complete..."
        # Wait for a few seconds before polling again (you can adjust the sleep duration)
        sleep 15
    fi
done

#Get the name of the Autoscaling group for the new nodegroup
NEW_AUTOSCALING_GROUP_NAME=$(aws eks describe-nodegroup --cluster-name $CLUSTER_NAME --nodegroup-name $NEW_NODEGROUP_NAME --query "nodegroup.resources.autoScalingGroups[0].name" --output text --no-verify-ssl)

#Verifying the autoscaling group name
echo "The autoscaling group: $NEW_AUTOSCALING_GROUP_NAME"

# Get the number of nodes in the old nodegroup
OLD_NUM_NODES=$(kubectl get nodes -l eks.amazonaws.com/nodegroup=$OLD_NODEGROUP_NAME --no-headers | wc -l)
echo "Number of nodes in $OLD_NODEGROUP_NAME: $OLD_NUM_NODES"

#Cordon Nodes of old nodegroup
nodes=$(kubectl get nodes -l eks.amazonaws.com/nodegroup=$OLD_NODEGROUP_NAME -o custom-columns=NAME:.metadata.name --no-headers)
for node in ${nodes[@]}
do
    echo "Cordon $node"
    kubectl cordon $node
done

#Getting the old autoscaling group name
OLD_AUTOSCALING_GROUP_NAME=$(aws eks describe-nodegroup --cluster-name $CLUSTER_NAME --nodegroup-name $OLD_NODEGROUP_NAME --query "nodegroup.resources.autoScalingGroups[0].name" --output text --no-verify-ssl)

#Verifying the autoscaling group name
echo "The autoscaling group: $OLD_AUTOSCALING_GROUP_NAME"

#Suspending the Launch Process of old nodegroup
echo "Suspending the Launch Process for Autoscaling Group"
aws autoscaling suspend-processes --auto-scaling-group-name $OLD_AUTOSCALING_GROUP_NAME --scaling-processes Launch

#Verifying the launch process is suspended
echo "Verifying whether the process is suspended"
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $OLD_AUTOSCALING_GROUP_NAME --query "AutoScalingGroups[0].SuspendedProcesses"
    
#Draining nodes, Terminating nodes, Updating Autoscaling group size
for node in ${nodes[@]}
do
    # Get the number of nodes in the new nodegroup
    NEW_NUM_NODES=$(kubectl get nodes -l eks.amazonaws.com/nodegroup=$NEW_NODEGROUP_NAME --no-headers | wc -l)
    echo "Number of nodes in $NEW_NODEGROUP_NAME: $NEW_NUM_NODES"

    # Break the loop if the number of nodes in the new nodegroup matches the old nodegroup
    if [ "$NEW_NUM_NODES" -eq "$OLD_NUM_NODES" ]; then
        echo "Number of nodes in the new nodegroup matches the old nodegroup."
        break
    fi
    echo "Number of nodes in the new nodegroup does not match the old nodegroup."
    echo "Waiting for the number of nodes in the new nodegroup to match the old nodegroup..."
    
    # Add one node to the new nodegroup by Updating the autoscaling group of new nodegroup
    echo "Updating the autoscaling group of new nodegroup"

    # Get current desired capacity and max size
    current_desired_capacity_new_nodegroup=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $NEW_AUTOSCALING_GROUP_NAME --query "AutoScalingGroups[0].DesiredCapacity" --output text)
    echo "The current desired capacity of new asg $current_desired_capacity_new_nodegroup"
    current_max_size_new_nodegroup=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $NEW_AUTOSCALING_GROUP_NAME --query "AutoScalingGroups[0].MaxSize" --output text)
    echo "The current max size of new asg $current_max_size_new_nodegroup"

    # Increase desired capacity and max size by 1
    updated_desired_capacity_new_nodegroup=$((current_desired_capacity_new_nodegroup + 1))
    echo "The updated desired capacity of asg $updated_desired_capacity_new_nodegroup"
    updated_max_size_new_nodegroup=$((current_max_size_new_nodegroup + 1))
    echo "The updated max size of asg $updated_max_size_new_nodegroup"

    # Update the size
    aws autoscaling update-auto-scaling-group --auto-scaling-group-name $NEW_AUTOSCALING_GROUP_NAME --desired-capacity $updated_desired_capacity_new_nodegroup --max-size $updated_max_size_new_nodegroup
    echo "The size of new asg is updated"
    
    # Wait for the new node to be ready
    while true
    do
        #Getting the number of ready nodes
        num_ready_nodes=$(kubectl get nodes -l eks.amazonaws.com/nodegroup=$NEW_NODEGROUP_NAME --no-headers | grep -c 'Ready')
        if [ "$num_ready_nodes" == "$updated_desired_capacity_new_nodegroup" ]; then
            echo "All nodes are ready"
            #move to the deletion of another node from old nodegroup
            break
        fi
    done
    echo "Waiting for new node to be ready  is completed"

    # Drain the node
    echo "Draining $node"
    kubectl drain $node --ignore-daemonsets --delete-local-data

    echo "Draining $node is completed"
    echo "Terminating $node"

    # Getting the instance Id from the node name
    INSTANCE_ID=$(kubectl get nodes $node -o=jsonpath='{.spec.providerID}' | awk -F'/' '{print $NF}')

    # Terminating the instance
    echo "Terminating the instance with instance id: $INSTANCE_ID"
    aws autoscaling terminate-instance-in-auto-scaling-group --instance-id $INSTANCE_ID --no-should-decrement-desired-capacity
    echo "Terminating the instance is completed"

    # Updating the autoscaling group of old nodegroup
    echo "Updating the autoscaling group of old nodegroup"
    # Get current desired capacity and min size
    current_desired_capacity_old_nodegroup=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $OLD_AUTOSCALING_GROUP_NAME --query "AutoScalingGroups[0].DesiredCapacity" --output text)
    echo "The current desired capacity of old asg $current_desired_capacity_old_nodegroup"
    current_min_size_old_nodegroup=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $OLD_AUTOSCALING_GROUP_NAME --query "AutoScalingGroups[0].MinSize" --output text)
    echo "The current min size of old asg $current_min_size_old_nodegroup"

    # Reduce desired capacity and min size by 1 of old nodegroup
    updated_desired_capacity_old_nodegroup=$((current_desired_capacity_old_nodegroup - 1))
    echo "The updated desired capacity of old asg $updated_desired_capacity_old_nodegroup"
    updated_min_size_old_nodegroup=$((current_min_size_old_nodegroup - 1))
    echo "The updated min size of old asg $updated_min_size_old_nodegroup"

    # Update the size
    aws autoscaling update-auto-scaling-group --auto-scaling-group-name $OLD_AUTOSCALING_GROUP_NAME --desired-capacity $updated_desired_capacity_old_nodegroup --min-size $updated_min_size_old_nodegroup
    echo "The size of old asg is updated"
done

#Deleting the EKS Nodegroup 
echo "Deleting the nodegroup cloudformation stack"
aws eks delete-nodegroup --cluster-name $CLUSTER_NAME --nodegroup-name $OLD_NODEGROUP_NAME

#Deleting the cloudformation 
aws cloudformation delete-stack --stack-name eksctl-$CLUSTER_NAME-nodegroup-$OLD_NODEGROUP_NAME