"""
Network utility functions
"""
import socket
from typing import List


def get_local_ip() -> List[str]:
    """
    Get the local IP address(es) of the server
    
    Returns:
        List[str]: List of IP addresses including localhost and actual IPs
    """
    ips = ['localhost', '127.0.0.1']
    
    try:
        # Get hostname
        hostname = socket.gethostname()
        # Get all IP addresses associated with hostname
        ip_addresses = socket.getaddrinfo(hostname, None, socket.AF_INET)
        for ip_info in ip_addresses:
            ip = str(ip_info[4][0])  # Ensure it's a string
            if ip not in ips and not ip.startswith('127.'):
                ips.append(ip)
    except Exception:
        pass
    
    # Try alternative method using UDP socket (doesn't actually send data)
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('8.8.8.8', 80))  # Google DNS, connection not actually made
        local_ip = s.getsockname()[0]
        s.close()
        if local_ip not in ips:
            ips.append(local_ip)
    except Exception:
        pass
    
    return ips
