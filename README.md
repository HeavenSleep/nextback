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

## Installation

### From PyPI (Recommended)

```bash
pip install nextback
```

### From Source

```bash
git clone https://github.com/heavensleep/nextback.git
cd nextback
pip install .
```

### Development Installation

```bash
git clone https://github.com/heavensleep/nextback.git
cd nextback
pip install -e .[dev]
```

## Requirements

- Python 3.8+
- Required Python packages: `click`, `boto3`, `paramiko`, `PyYAML`
- Nextcloud instance with appropriate permissions
- Sufficient disk space for backups

## Quick Start

### Option 1: Install from PyPI (Recommended)

```bash
# Install the package
pip install nextback

# Initialize configuration
nextback init

# Create your first backup
nextback backup
```

### Option 2: Install from Source

```bash
# Clone the repository
git clone https://github.com/heavensleep/nextback.git
cd nextback

# Install in development mode
pip install -e .

# Or install normally
pip install .
```

### Option 3: Run Directly from Source

```bash
# Clone the repository
git clone https://github.com/heavensleep/nextback.git
cd nextback

# Copy the configuration template
cp config/backup.conf.template config/backup.conf

# Edit the configuration file with your Nextcloud settings
nano config/backup.conf

# Run the main script
python main.py --help
```

## Configuration

### Using the Package Installation

When installed via pip, NextBack will look for configuration files in these locations (in order):

1. `./config/backup.conf` (current directory)
2. `~/.nextback/config/backup.conf` (user config directory)
3. Package installation directory

Initialize configuration with:
```bash
nextback init
```

### Manual Configuration

Copy and edit the configuration template:
```bash
cp config/backup.conf.template config/backup.conf
```

Edit the configuration file with your Nextcloud settings:

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
