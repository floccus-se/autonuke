FROM alpine:3.22.1

# Install dependencies
RUN apk add --no-cache bash curl jq unzip aws-cli coreutils

# Fetch the latest version of aws-nuke dynamically and install it
RUN REPO="ekristen/aws-nuke" && \
    ARCH=$(uname -m | sed 's/aarch64/arm64/' | sed 's/x86_64/amd64/') && \
    OS=$(uname -s | tr '[:upper:]' '[:lower:]') && \
    LATEST_RELEASE=$(curl -s https://api.github.com/repos/$REPO/releases/latest) && \
    VERSION=$(echo "$LATEST_RELEASE" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/') && \
    DOWNLOAD_URL="https://github.com/$REPO/releases/download/$VERSION/aws-nuke-$VERSION-$OS-$ARCH.tar.gz" && \
    echo "Downloading aws-nuke from $DOWNLOAD_URL" && \
    curl -Lo aws-nuke.tar.gz "$DOWNLOAD_URL" && \
    tar -tzf aws-nuke.tar.gz && \
    tar -xzf aws-nuke.tar.gz -C /usr/local/bin aws-nuke && \
    chmod +x /usr/local/bin/aws-nuke && \
    rm aws-nuke.tar.gz

# Add a shell script to generate the aws-nuke config and run aws-nuke
COPY run-nuke.sh /usr/local/bin/run-nuke.sh
COPY config.yaml.template /root/config.yaml.template
RUN chmod +x /usr/local/bin/run-nuke.sh

# Set entrypoint
ENTRYPOINT ["/usr/local/bin/run-nuke.sh"]
