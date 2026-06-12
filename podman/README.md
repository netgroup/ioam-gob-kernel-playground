# Environment Setup and Kernel Compiling Instructions

This guide explains how to build the container image, set up the VM infrastructure, compile a custom kernel and modules, and run the environment using Podman.

Note: Make sure you have Podman installed and properly configured on your system before starting!

# Prerequisites and Common Issues with Repository Ownership

## Prerequisites
To avoid permission and ownership issues and to simplify the deployment of the entire repository, it is requireed to operate directly as the root user.

### How to log in as root on Ubuntu:
```bash
 $ sudo su
```
After entering this command, you'll be logged in as root. Notice that the command prompt changes from `$` to `#`.

### Important:
- Being logged in as root gives you full control over the system.
- Use root with caution: executing random commands can harm your system.
- Only the brave should operate as root; always be responsible :-)
- You may read here and there that operating as root is not recommended. This is absolutely true for production system. In our case, you are running a VM with a development environment (and it is NOT recommended to use the VM for anything else, so you should not create harm to other critical stuff).

## Cloning the Repository
Only after logging in as root, you can clone the repository! The cloned repository will have `root` as both owner and group.

---

## The Issue Reported in Class

### Scenario:
- The repository was cloned using a user different from `root` (e.g., the default user `ubuntu`).
- The ownership of the entire repository directory (e.g., `/home/ubuntu/kernel-playground/`) is set to that user (`ubuntu`).
- When launching the container, the repository is mounted as a volume.
- Inside the container, the default user is `root`.
- The container's process attempts to initialize submodules via `git` (using `./setup-all.sh`), which detects a mismatch in ownership.

### Error Message:
```bash
root@test-vm:/home/ubuntu/kernel-playground/podman# ./setup-all.sh
+ set -e
+ pushd ../
/opt/kernel-playground /opt/kernel-playground/podman
+ git submodule update --init --recursive
fatal: detected dubious ownership in repository at '/opt/kernel-playground'
To add an exception for this directory, call:

    git config --global --add safe.directory /opt/kernel-playground
```

This error occurs because Git detects that the directory ownership is inconsistent with the current user executing the command.

---

## How to Fix the Issue 

### Solution 1 (simple and preferred):

Just delete the cloned repository and clone it again after loggin in as root.

### Solution 2 (if you really want to mess up...):
Change the ownership of the entire project directory to `root`. For example:
```bash
# From the parent directory of your project
sudo chown -R root:root kernel-playground/
```

This command recursively sets the owner and group of the `kernel-playground` directory to `root`, resolving the ownership conflict and allowing Git to initialize submodules without errors.

---

**Note:** Always prefer to operate as root only when necessary and exercise caution to prevent system issues.


## Installing Podman on Ubuntu

To install Podman on Ubuntu (20.04 or newer), run the following commands:

```bash
sudo apt update
sudo apt -y install podman
```

To verify that Podman is installed correctly:

```bash
podman --version
```

**Note:** Podman is a daemonless container engine, so you don’t need to start a service like with Docker. You can use it immediately after installation.


---

## Building the Container Image

First, build the container image that will be used to setup the environment:

```bash
# ./container-build.sh
```

This script creates a container image containing all necessary tools for the setup process.

---

## Setting Up the Infrastructure

Once the image is built, run the following script to set up the entire environment:

```bash
# ./setup-all.sh
```

This script automates the following steps:

1. **Create the VM with root filesystem**
   Sets up a virtual machine environment with a minimal root filesystem.

2. **Configure and compile the kernel and custom module**
   Applies kernel configuration, then compiles both the kernel and the custom modules.

3. **Link the compiled kernel into the VM submodule**
   Creates a soft link so the VM can use the freshly compiled kernel during the setup.

4. **Copy the custom kernel module into shared VM folder**
   Places the compiled kernel module into the shared folder accessible from within the VM at `/mnt/shared`.

---

## Running the Container

To start the container in detached mode:

```bash
# ./run-detach.sh
```

This will run the environment in the background, allowing you to interact with it later.

---

## Accessing the Container

To interact with the running container, execute:

```bash
podman exec -it ioam-kernel-builder bash
```

Once inside, navigate to the kernel playground directory:

```bash
cd /opt/kernel-playground
```

> **Note:**
> The `/opt/kernel-playground` directory inside the container is mounted from your host machine. Any changes made within this directory inside the container are immediately reflected on your host, and vice versa. This setup facilitates seamless development and testing.

---

*Note:* Make sure you have Podman installed and properly configured on your system before starting.
