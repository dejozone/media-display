"""
Time parsing utilities
"""


def parse_time_to_ms(time_str: str) -> int:
    """
    Convert H:MM:SS or M:SS to milliseconds
    
    Args:
        time_str: Time string in format "H:MM:SS" or "M:SS"
        
    Returns:
        int: Time in milliseconds
    """
    try:
        if not time_str or time_str == '0:00:00':
            return 0
        parts = time_str.split(':')
        if len(parts) == 3:  # H:MM:SS
            hours, minutes, seconds = map(int, parts)
            return (hours * 3600 + minutes * 60 + seconds) * 1000
        elif len(parts) == 2:  # M:SS
            minutes, seconds = map(int, parts)
            return (minutes * 60 + seconds) * 1000
    except:
        return 0
    return 0
