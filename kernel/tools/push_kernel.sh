#!/bin/bash

# ==============================================================================
# STRATEGY FOR UPLOADING THE LINUX KERNEL TO GITHUB
# ==============================================================================
# The Linux kernel is too large to push in one go (your .pack can be >= 2GB).
# This script uses a "Milestone Strategy":
# 1. We optimize Git to use less RAM/CPU (critical for Docker/limited envs).
# 2. We break the 2.7GB monolith pack into 100MB chunks.
# 3. We push the real history in jumps of 5,000 commits at a time.
# 4. We use --no-thin to stop GitHub from choking on complex delta calculations.
# ==============================================================================

# ------------------------------------------------------------------------------
# STEP 1: SSH CONFIGURATION (PREVENT DISCONNECTS)
# ------------------------------------------------------------------------------
# To prevent the "unexpected disconnect while reading sideband packet" error,
# you should ensure your SSH connection stays alive during long operations.
#
# MANUALLY RUN THIS ONCE in your terminal (outside the script):
# cat <<EOF >> ~/.ssh/config
# Host github.com
#     Hostname github.com
#     User <YOUR-USER>
#     ServerAliveInterval 60
#     ServerAliveCountMax 10
#     IPQoS throughput
# EOF
#
# WHY: ServerAliveInterval sends a "ping" every 60s so routers/firewalls
# don't kill the connection while GitHub is busy processing your 2.7GB of data.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# STEP 2: GIT GLOBAL OPTIMIZATIONS
# ------------------------------------------------------------------------------
# Run these commands manually or uncomment them to prepare your environment:

# LIMIT THREADS: Using 32 threads on a kernel-sized repo can exceed Docker RAM.
# git config pack.threads 2

# LIMIT RAM: Prevents Git from trying to load the whole 2.7GB pack into RAM.
# git config pack.deltaCacheSize 256m
# git config pack.windowMemory 256m

# DISABLE AUTO-TAGS: Prevents pushing thousands of tags with every small chunk.
# git config push.followTags false

# SPLIT THE 2.7GB PACK: Forces Git to store data in 100MB files instead of one
# giant file.
# git config pack.packSizeLimit 100m

# REPACK: This is the most important step. It recreates your database into the
# 100MB chunks defined above. This will take a long time but is REQUIRED.
# git repack -a -d --depth=250 --window=250
# ------------------------------------------------------------------------------

# --- Configuration Variables ---
# Your SSH remote (e.g., git@github.com:user/repo.git)
REMOTE="origin"

# The branch you are pushing FROM
SOURCE_BRANCH="<local-branch>"
# The branch on GitHub
DEST_BRANCH="<remote-branch>"

# NOTE: successfully tested with 100k commits pushed each time.
# How many commits to "jump" per push
STEP=10000
STATE_FILE=".push_progress"
# -------------------------------

# 1. Analyze History
echo "Analyzing Linux Kernel history..."
commits=($(git rev-list --reverse $SOURCE_BRANCH))
total=${#commits[@]}

if [ $total -eq 0 ]; then
    echo "Error: No commits found. Ensure you are on the correct branch."
    exit 1
fi

# 2. Check for Checkpoint (Resumability)
if [ -f "$STATE_FILE" ]; then
    i=$(cat "$STATE_FILE")
    echo "Checkpoint found! Resuming from index: $i"
else
    i=0
    echo "Starting fresh push..."
fi

# 3. The Milestone Push Loop
while [ $i -lt $total ]; do
    # Calculate the next milestone hash
    i=$((i + STEP))
    [ $i -gt $total ] && i=$total

    # We pick the REAL hash from your history. No fake commits are created.
    target_hash=${commits[$((i - 1))]}

    echo "--------------------------------------------------------"
    echo "PROGRESS: $i / $total commits"
    echo "TARGET: ${target_hash}"
    echo "--------------------------------------------------------"

    # --no-thin: This is the "Magic Flag".
    # Usually, Git sends 'deltas' (just the changes). For the kernel,
    # calculating these deltas on a 2.7GB pack causes the server to timeout.
    # --no-thin sends the full objects for that chunk, which is much
    # easier for GitHub's servers to process without disconnecting.
    if git push $REMOTE ${target_hash}:refs/heads/$DEST_BRANCH --no-thin --force; then
        echo $i > "$STATE_FILE"
        echo "Milestone reached and saved."
    else
        echo "!!! PUSH FAILED at index $i !!!"
        echo "Check your internet. The script saved your progress."
        echo "Simply run the script again to resume from this point."
        exit 1
    fi
done

# 4. Final Synchronization
echo "--------------------------------------------------------"
echo "All chunks uploaded. Performing final sync..."
echo "--------------------------------------------------------"

# Now that all objects exist on GitHub, this final push links the
# history perfectly and uploads all version tags.
git push $REMOTE $SOURCE_BRANCH:$DEST_BRANCH --force
git push $REMOTE --tags

echo "SUCCESS: The Linux Kernel has been fully mirrored to GitHub."
rm "$STATE_FILE"
