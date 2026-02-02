# Development Guide

## Development Setup

1. Clone the repository:
```bash
git clone https://github.com/heavensleep/nextback.git
cd nextback
```

2. Install in development mode:
```bash
pip install -e .[dev]
```

## Building the Package

1. Install build dependencies:
```bash
pip install build twine
```

2. Build the package:
```bash
python -m build
```

3. Check the package:
```bash
twine check dist/*
```

## Testing

1. Install test dependencies:
```bash
pip install -e .[test]
```

2. Run tests:
```bash
pytest
```

## Publishing to PyPI

1. Build the package (see above)
2. Upload to test PyPI:
```bash
twine upload --repository testpypi dist/*
```

3. Upload to production PyPI:
```bash
twine upload dist/*
```

## Package Structure

```
nextback/
├── nextback/                 # Main package
│   ├── __init__.py         # Package metadata
│   ├── manager.py          # Main CLI and manager class
│   ├── backup.conf.template # Configuration template
│   └── scripts/            # Shell scripts
│       ├── __init__.py
│       ├── backup.sh
│       ├── restore.sh
│       ├── upload.py
│       └── libs/
│           └── common.sh
├── pyproject.toml          # Modern packaging configuration
├── MANIFEST.in            # Files to include in distribution
├── README.md              # Project documentation
└── LICENSE                # MIT License
```

## Console Scripts

The package provides two console scripts:
- `nextback` - Primary command
- `nextcloud-backup` - Alias for compatibility

Both provide the same CLI interface with commands:
- `init` - Initialize configuration
- `backup` - Create backups
- `restore` - Restore from backup
- `list` - List available backups
- `upload` - Upload to remote storage
- `info` - Show backup information
- `verify` - Verify backup integrity
- `status` - Show system status
- `cleanup` - Clean up old backups

## Configuration

When installed via pip, NextBack looks for configuration in:
1. `./config/backup.conf` (current directory)
2. `~/.nextback/config/backup.conf` (user config directory)
3. Package installation directory

The `nextback init` command creates the configuration in the user directory.
