"""
Device utility functions
"""
from typing import List


def format_device_display(device_names: List[str]) -> str:
    """
    Format device names for display
    
    Args:
        device_names: List of device names
        
    Returns:
        str: Formatted string (e.g., "Device1" or "Device1 +2 more")
    """
    if len(device_names) == 0:
        return "Unknown"
    elif len(device_names) == 1:
        return device_names[0]
    else:
        return f"{device_names[0]} +{len(device_names)-1} more"
