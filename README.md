# Simple Private Internet Access WireGuard Config Generator

This script generates WireGuard configuration files for Private Internet Access (PIA) VPN service, simplifying the setup process.

## Installation

```bash
git clone https://github.com/dieskim/simple-pia-wg-config-generator
cd simple-pia-wg-config-generator
chmod +x simple-pia-wg-config-generator.sh
DEBUG=1 PIA_USER=p0123456 PIA_PASS=xxxxxxxx ./simple-pia-wg-config-generator.sh
```

This script is based on PIA FOSS manual connections.
https://github.com/pia-foss/manual-connections/tree/master

#### Changes promoted from original Dieskim version: 
Script Purpose Update:
    The description now states that the script selects the WireGuard server with the lowest latency within a region.

Added Server Responsiveness Check:
    The script now includes ping in the list of required tools.
    Before generating configuration files, it checks if the servers are responsive using ping.

Lowest Latency Selection:
    Instead of selecting any available server, the script now pings all available servers in a region.
    The server with the lowest response time is chosen for the WireGuard configuration.

Filename Update with Latency Info:
    The generated .conf file now includes the ping response time in milliseconds, e.g., pia-austria-vienna401_8ms.conf.

Credentials Handling Improvement:
    The script now reads PIA credentials from a file (credentials.properties) if available.
    If credentials are missing, it falls back to default values.

Improved Region Selection:
    The script allows for manual region selection or reads from a predefined regions.properties file.

Debugging Enhancements:
    Introduced a DEBUG mode that provides additional information if enabled.


Also thanks to @beilke for the contribution 
