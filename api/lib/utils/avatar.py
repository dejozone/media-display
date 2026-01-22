#!/usr/bin/env python3
"""
Avatar utilities for image processing and validation
"""
from pathlib import Path
from typing import Optional, Tuple
import mimetypes
import uuid
from datetime import datetime

ALLOWED_IMAGE_EXT = {'.jpg', '.jpeg', '.png', '.bmp', '.heic', '.heif'}
MAX_AVATAR_SIZE = 8 * 1024 * 1024  # 8MB

def validate_avatar_file(filename: str, file_size: int) -> Tuple[bool, Optional[str]]:
    """
    Validate avatar file extension and size.
    
    Args:
        filename: The original filename
        file_size: Size of the file in bytes
        
    Returns:
        Tuple of (is_valid, error_message)
    """
    if not filename or not filename.strip():
        return False, 'No filename provided'
    
    ext = Path(filename).suffix.lower()
    if ext not in ALLOWED_IMAGE_EXT:
        return False, f'Unsupported file type. Use JPG, PNG, BMP, or HEIC/HEIF.'
    
    if file_size > MAX_AVATAR_SIZE:
        return False, f'File too large. Max {MAX_AVATAR_SIZE // (1024 * 1024)}MB.'
    
    return True, None


def get_mime_type(filename: str) -> Optional[str]:
    """
    Get MIME type from filename.
    
    Args:
        filename: The filename
        
    Returns:
        MIME type string or None
    """
    mime_type, _ = mimetypes.guess_type(filename)
    return mime_type


def sanitize_avatar_filename(filename: str) -> str:
    """
    Sanitize filename for safe storage with unique identifier.
    
    Args:
        filename: Original filename
        
    Returns:
        Sanitized filename with UUID to ensure uniqueness
    """
    ext = Path(filename).suffix.lower()
    # Generate unique filename using UUID and timestamp
    unique_id = uuid.uuid4().hex[:12]  # Use first 12 chars of UUID
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    return f'avatar_{timestamp}_{unique_id}{ext}'
