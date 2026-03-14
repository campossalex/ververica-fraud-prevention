    #!/bin/bash
    set -euxo pipefail

    # Run pre-install script
    sudo ./ververica-platform-playground/pre-install.sh

    # Run setup script
    sudo ./ververica-platform-playground/setup.sh -e community

    # Run post-install script   
    sudo ./ververica-platform-playground/post-install.sh
