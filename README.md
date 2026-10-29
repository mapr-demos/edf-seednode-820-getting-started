Fabric Deployment Using a Seed Node: Getting Started
Introduction
Describes how to create/deploy first fabric using seed node.

#Steps

Use the following steps to bring up the container image and launch the Create Fabric interface:

1.Sign in to the seed node host as root or a user that can run sudo commands without being prompted for a password.

2.Download the datafabric_container_setup.sh script from GitHub. For example, download the script in its raw form by using the following wget command:

 wget https://raw.githubusercontent.com/mapr-demos/edf-seednode-800-getting-started/refs/heads/main/datafabric_container_setup.sh
3.Modify the script so it is executable:

 chmod +x datafabric_container_setup.sh
4.Running the datafabric_container_setup.sh script requires sudo privileges.

5.Run the script to deploy the container for the Data Fabric image:

 ./datafabric_container_setup.sh
6.The script brings up the latest Data Fabric version in containerized form. Console messages provide a link to user interface that you can use to deploy the first fabric.

Documentation Link
For user documentation, see https://docs.ezmeral.hpe.com/datafabric/home/installation/installation_main.html
