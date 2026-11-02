# Fabric Deployment Using a Seed Node: Getting Started

## Introduction

Describes how to create/deploy first fabric using seed node.

## Steps

Use the following steps to bring up the container image and launch the Create Fabric interface:

1. Sign in to the seed node host as root or a user that can run sudo commands without being prompted for a password.

2. Download the datafabric_container_setup.sh script from GitHub. For example, download the script in its raw form by using the following:

   ```bash
   wget https://raw.githubusercontent.com/mapr-demos/edf-seednode-820-getting-started/refs/heads/main/datafabric_container_setup.sh
   ```

3. Modify the script permissions so it is executable:

   ```bash
   chmod +x datafabric_container_setup.sh
   ```

4. Running the datafabric_container_setup.sh script requires sudo privileges.

5. Run the script to deploy the container for the Data Fabric image:

   ```bash
   ./datafabric_container_setup.sh
   ```

6. The script brings up the latest Data Fabric version in containerized form. Console messages provide a link to user interface that you can use to deploy the first fabric.

### Documentation Link

For user documentation, see https://docs.ezmeral.hpe.com/datafabric/home/installation/installation_main.html

---

## Optional: Deploying a Fabric Using an Airgap Repository

### Overview

The HPE Data Fabric Airgap Repository allows you to create a local package repository for Data Fabric Core, MEP, and Installer components.

This is useful when deploying fabrics in environments where cluster nodes cannot access the public HPE package repository.

The Airgap Repository runs as a Docker or Podman container and provides packages through a local HTTP endpoint.

### Steps

**1. Download the Airgap Repository script**

```bash
wget https://raw.githubusercontent.com/mapr-demos/edf-seednode-820-getting-started/main/airgap-repository

chmod +x airgap-repository
```

To view available commands and options:

```bash
./airgap-repository --help
./airgap-repository create --help
```

**2. Configure repository access**

The initial synchronization requires access to the HPE Data Fabric package repository.

For an authenticated repository, create a protected configuration file:

```bash
sudo install -d -m 0700 /etc/mapr-airgap
sudo install -m 0600 /dev/null /etc/mapr-airgap/repository.conf
sudoedit /etc/mapr-airgap/repository.conf
```

Add your repository information:

```ini
repository_url=https://package.ezmeral.hpe.com/releases
username=<HPE_ACCOUNT_EMAIL>
password=<HPE_REPOSITORY_TOKEN>
```

**3. Create the local Airgap Repository**

For example, to synchronize Core 8.2.0, MEP 10.1.1, and Installer packages for Ubuntu:

```bash
sudo ./airgap-repository create \
  --core-versions 8.2.0 --core-os ubuntu22 \
  --mep-versions 10.1.1 --mep-os ubuntu \
  --installer-os ubuntu \
  --repo-config-file /etc/mapr-airgap/repository.conf \
  --advertise-host mirror.example.com
```

Replace `mirror.example.com` with the hostname or IP address of your repository server.

Adjust the versions and operating system selections to match your deployment requirements and the available packages.

**4. Verify the repository**

Check the container status:

```bash
sudo ./airgap-repository status
```

Retrieve the repository URL:

```bash
sudo ./airgap-repository print-url \
  --advertise-host mirror.example.com
```

For example, the resulting repository URL may look like:

```text
http://mirror.example.com:8080
```

Make sure the repository is reachable from the nodes that will use it.

**5. Use the repository when creating a fabric**

After starting the seed node and opening the Data Fabric UI:

1. Start the Create Fabric workflow.
2. Select an on-premises deployment.
3. Enter the local repository base URL in the **Airgap repository** field.
4. Continue with the fabric configuration and deployment.

Use the repository root URL, not a version-specific path such as `/v8.2.0/redhat/`.

### Important Notes

The initial repository synchronization requires access to the upstream package source. Once the required packages are synchronized, the local repository can serve them without requiring cluster nodes to reach the HPE package repository.

The seed node Docker image is obtained separately. Creating an Airgap package repository does not, by itself, provide a completely offline seed node installation.

Operating system dependencies and other deployment prerequisites must also be available in restricted-network environments.

For additional options, including repository updates and alternative operating systems, see `./airgap-repository create --help-full` and `./airgap-repository update --help`.

### Documentation Link

For user documentation, https://docs.ezmeral.hpe.com/datafabric-customer-managed/82/AdvancedInstallation/installing_with_air_gapped_installer_script.html
