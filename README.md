# NextBack | Nextcloud Backup Manager

A comprehensive backup management system for Nextcloud instances with support for local backups, restoration, and remote uploads.

## Features

- **Backup Creation**: Create complete Nextcloud backups including database, config, and data files
- **Backup Restoration**: Restore Nextcloud from existing backups
- **Remote Upload**: Upload backups to remote storage (S3, FTP, etc.)
- **Configuration Management**: Flexible configuration system
- **Logging**: Detailed logging for all operations
- **Modular Design**: Shared library for common functionality

## Project Structure

```
nextback/
├── README.md                 # This file
├── main.py                   # Main orchestration script
├── requirements.txt          # Python dependencies
├── .gitignore               # Git ignore file
├── config/
│   └── backup.conf.template  # Configuration template
├── scripts/
│   ├── backup.sh            # Backup creation script
│   ├── restore.sh           # Backup restoration script
│   ├── upload.py            # Remote upload script
│   └── libs/
│       └── common.sh        # Shared functions library
└── logs/                    # Log files directory
```

## Architecture

The backup system uses a modular architecture with shared functionality:

- **`scripts/libs/common.sh`**: Contains all shared functions used by both backup.sh and restore.sh
- **`scripts/backup.sh`**: Backup-specific functionality
- **`scripts/restore.sh`**: Restore-specific functionality
- **`scripts/upload.py`**: Remote upload functionality (Python)
- **`main.py`**: Unified orchestration interface

## Quick Start

1. Copy the configuration template:
   ```bash
   cp config/backup.conf.template config/backup.conf
   ```

2. Edit the configuration file with your Nextcloud settings

3. Run the main script:
   ```bash
   python main.py --help
   ```

## Configuration

Edit `config/backup.conf` with your specific settings:

- Nextcloud installation path
- Database credentials
- Backup destination paths
- Remote storage credentials

## Usage Examples

### Using the Click CLI Interface

```bash
# Show help
python main.py --help

# Create a backup
python main.py backup

# Create backup and upload to S3
python main.py backup --upload --upload-type s3

# List available backups
python main.py list

# Show backup information
python main.py info 20240101_120000

# Verify backup integrity
python main.py verify 20240101_120000

# Restore from backup (with confirmation)
python main.py restore 20240101_120000

# Force restore without confirmation
python main.py restore 20240101_120000 --force

# Upload backup to remote storage
python main.py upload 20240101_120000 --type s3

# Show system status
python main.py status

# Clean up old backups
python main.py cleanup
```

### Direct Script Usage

```bash
# Create backup
./scripts/backup.sh

# List backups
./scripts/restore.sh list

# Restore backup
./scripts/restore.sh restore 20240101_120000
```

## Shared Library Functions

The `scripts/libs/common.sh` library provides:

- **Logging**: Colored output and file logging
- **Configuration**: Loading and validation
- **Database**: Connection checking and command execution
- **Maintenance**: Nextcloud maintenance mode management
- **File Operations**: Archive creation/extraction, permissions
- **Backup Management**: Validation, metadata, cleanup

## CLI Features

The Click-based CLI provides:

- **Professional Interface**: Clean, intuitive command structure
- **Rich Help System**: Built-in help for all commands and options
- **Interactive Confirmations**: Safety prompts for destructive operations
- **Visual Feedback**: Emoji indicators and colored output
- **Error Handling**: Graceful error reporting with proper exit codes
- **Flexible Options**: Global and command-specific configuration options
- **Context Management**: Efficient resource handling

## Requirements

- Bash 4.0+
- Python 3.7+
- Required Python packages: `boto3`, `paramiko`, `pyyaml`
- Nextcloud instance with appropriate permissions
- Sufficient disk space for backups

## Security Notes

- Keep configuration files secure and restrict access
- Use encrypted connections for remote uploads
- Regularly test backup restoration procedures
- Consider encrypting backup files

## License

MIT License
