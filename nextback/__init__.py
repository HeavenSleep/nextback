"""
NextBack - Nextcloud Backup Manager

A comprehensive backup management system for Nextcloud instances with support for 
local backups, restoration, and remote uploads.
"""

__version__ = "1.0.0"
__author__ = "HeavenSleep"
__email__ = "heavensleep@example.com"
__description__ = "Nextcloud Backup Manager"

from .manager import NextcloudBackupManager

__all__ = ["NextcloudBackupManager"]
