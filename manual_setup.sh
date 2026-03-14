    #!/bin/bash
    set -euxo pipefail

    # Install git
    yum update -y
    yum install -y git

    # Clone the repo
    cd /root
    git clone https://github.com/campossalex/ververica-fraud-prevention ververica-platform-playground

    # Run pre-install script
    sudo ./ververica-platform-playground/pre-install.sh

    # Run setup script
    sudo ./ververica-platform-playground/setup.sh -e community

    # Run post-install script   
    sudo ./ververica-platform-playground/post-install.sh
