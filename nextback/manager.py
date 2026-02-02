#!/usr/bin/env python3

"""
Nextcloud Backup Manager - CLI Application
Provides a unified interface for Nextcloud backup operations using Click
"""

import os
import sys
import subprocess
import json
import logging
import re
import shutil
import logging.handlers
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Optional, Any

# Add package root to path for script imports
package_root = Path(__file__).parent.parent
sys.path.insert(0, str(package_root))

try:
    import click
except ImportError:
    print("Error: click is required. Install with: pip install click")
    sys.exit(1)

class NextcloudBackupManager:
    """Main backup manager class"""
    
    def __init__(self, config_path: str = "config/backup.conf"):
        # When installed as a package, look for config in user's home directory or current directory
        if Path(config_path).is_absolute():
            self.config_path = Path(config_path)
        else:
            # Try multiple locations for config file
            possible_paths = [
                Path.cwd() / config_path,  # Current directory
                Path.home() / ".nextback" / config_path,  # User config directory
                Path(__file__).parent.parent.parent / config_path,  # Package root
            ]
            
            self.config_path = None
            for path in possible_paths:
                if path.exists():
                    self.config_path = path
                    break
            
            if self.config_path is None:
                self.config_path = possible_paths[0]  # Default to current directory
        
        self.project_root = Path(__file__).parent.parent
        self.scripts_dir = self.project_root / "nextback" / "scripts"
        self.logs_dir = Path.home() / ".nextback" / "logs"
        self._config = None  # Cached configuration
        
        # Ensure directories exist
        self.logs_dir.mkdir(exist_ok=True)
        
        # Setup logging
        self.setup_logging()
        self.logger = logging.getLogger(__name__)
        
        # Validate configuration
        self.validate_config()
    
    @property
    def config(self) -> Dict[str, str]:
        """Get cached configuration, loading if necessary"""
        if self._config is None:
            self._config = self._load_config()
        return self._config
    
    def setup_logging(self):
        """Setup structured logging configuration with rotation"""
        log_file = self.logs_dir / "manager.log"
        
        # Create structured formatter
        class StructuredFormatter(logging.Formatter):
            def format(self, record):
                log_data = {
                    'timestamp': datetime.fromtimestamp(record.created).isoformat(),
                    'level': record.levelname,
                    'logger': record.name,
                    'message': record.getMessage(),
                    'module': record.module,
                    'function': record.funcName,
                    'line': record.lineno
                }
                
                # Add exception info if present
                if record.exc_info:
                    log_data['exception'] = self.formatException(record.exc_info)
                
                return json.dumps(log_data)
        
        # Setup file handler with rotation (keep 10 files, 10MB each)
        file_handler = logging.handlers.RotatingFileHandler(
            log_file, 
            maxBytes=10*1024*1024,  # 10MB
            backupCount=10
        )
        file_handler.setFormatter(StructuredFormatter())
        
        # Setup console handler with human-readable format
        console_handler = logging.StreamHandler(sys.stdout)
        console_formatter = logging.Formatter(
            '%(asctime)s - %(name)s - %(levelname)s - %(message)s'
        )
        console_handler.setFormatter(console_formatter)
        
        # Configure root logger
        root_logger = logging.getLogger()
        root_logger.setLevel(logging.INFO)
        root_logger.addHandler(file_handler)
        root_logger.addHandler(console_handler)
    
    def validate_config(self):
        """Validate configuration file exists"""
        if not self.config_path.exists():
            self.logger.error(f"Configuration file not found: {self.config_path}")
            self.logger.info("Please copy config/backup.conf.template to config/backup.conf and configure it")
            sys.exit(1)
        
        self.logger.info(f"Configuration loaded from: {self.config_path}")
    
    def run_script(self, script_name: str, args: List[str] = None) -> subprocess.CompletedProcess:
        """Run a bash script and return the result"""
        script_path = self.scripts_dir / script_name
        
        if not script_path.exists():
            raise FileNotFoundError(f"Script not found: {script_path}")
        
        cmd = [str(script_path)]
        if args:
            cmd.extend(args)
        
        self.logger.info(f"Running script: {' '.join(cmd)}")
        
        # Set environment variable for config path
        env = os.environ.copy()
        env['CONFIG_FILE'] = str(self.config_path)
        
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                env=env,
                cwd=self.project_root
            )
        except subprocess.SubprocessError as e:
            self.logger.error(f"Subprocess error running script {script_name}: {e}")
            raise
        
        if result.returncode != 0:
            self.logger.error(f"Script failed: {script_name} (exit code: {result.returncode})")
            self.logger.error(f"STDOUT: {result.stdout}")
            self.logger.error(f"STDERR: {result.stderr}")
            raise subprocess.CalledProcessError(result.returncode, cmd, result.stdout, result.stderr)
        
        self.logger.info(f"Script completed successfully: {script_name}")
        return result
    
    def run_python_script(self, script_name: str, args: List[str] = None) -> subprocess.CompletedProcess:
        """Run a Python script and return the result"""
        script_path = self.scripts_dir / script_name
        
        if not script_path.exists():
            raise FileNotFoundError(f"Script not found: {script_path}")
        
        cmd = [sys.executable, str(script_path)]
        if args:
            cmd.extend(args)
        
        # Add config argument
        cmd.extend(['--config', str(self.config_path)])
        
        self.logger.info(f"Running Python script: {' '.join(cmd)}")
        
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                cwd=self.project_root
            )
        except subprocess.SubprocessError as e:
            self.logger.error(f"Subprocess error running Python script {script_name}: {e}")
            raise
        
        if result.returncode != 0:
            self.logger.error(f"Python script failed: {script_name} (exit code: {result.returncode})")
            self.logger.error(f"STDOUT: {result.stdout}")
            self.logger.error(f"STDERR: {result.stderr}")
            raise subprocess.CalledProcessError(result.returncode, cmd, result.stdout, result.stderr)
        
        self.logger.info(f"Python script completed successfully: {script_name}")
        return result
    
    def create_backup(self) -> str:
        """Create a new backup"""
        self.logger.info("Starting backup creation...")
        
        try:
            # Load configuration to get backup directory
            config = self._load_config()
            backup_dir = Path(config['BACKUP_DIR'])
            
            # Check disk space (require at least 5GB free)
            self.check_disk_space(backup_dir, 5.0)
            
            # Start disk space monitoring during backup
            self.monitor_disk_space_during_operation(backup_dir, "backup creation")
            
            try:
                result = self.run_script("backup.sh")
                
                # Extract backup ID from output with proper validation
                backup_id = self._extract_backup_id(result.stdout)
                
                # Verify final backup disk space
                backup_path = backup_dir / backup_id
                if not self.check_disk_space_during_backup(backup_path):
                    raise RuntimeError("Backup completed but disk space check failed")
                
                self.logger.info(f"Backup created successfully: {backup_id}")
                return backup_id
                
            finally:
                # Stop disk space monitoring
                self.stop_disk_space_monitoring()
            
        except Exception as e:
            self.logger.error(f"Backup creation failed: {e}")
            raise
    
    def _extract_backup_id(self, output: str) -> str:
        """Extract backup ID from script output with validation"""
        backup_pattern = re.compile(r'^\d{8}_\d{6}$')
        
        # Look for backup ID in output lines
        for line in output.strip().split('\n'):
            line = line.strip()
            if backup_pattern.match(line):
                return line
        
        # If no pattern match, try to find last line as fallback
        lines = output.strip().split('\n')
        if lines:
            last_line = lines[-1].strip()
            if backup_pattern.match(last_line):
                return last_line
        
        raise ValueError(f"Could not extract valid backup ID from script output. Output: {output}")
    
    def check_disk_space(self, path: Path, required_gb: float) -> None:
        """Check if sufficient disk space is available"""
        try:
            stat = shutil.disk_usage(path)
            available_gb = stat.free / (1024**3)
            
            if available_gb < required_gb:
                raise ValueError(
                    f"Insufficient disk space at {path}: "
                    f"{available_gb:.1f}GB available, {required_gb:.1f}GB required"
                )
            
            self.logger.info(f"Disk space check passed: {available_gb:.1f}GB available at {path}")
            
        except OSError as e:
            self.logger.error(f"Failed to check disk space at {path}: {e}")
            raise
    
    def monitor_disk_space_during_operation(self, path: Path, operation_name: str, interval_seconds: int = 30) -> None:
        """Monitor disk space during long-running operations"""
        import threading
        import time
        
        def monitor():
            while getattr(self, '_monitoring_active', True):
                try:
                    stat = shutil.disk_usage(path)
                    available_gb = stat.free / (1024**3)
                    
                    if available_gb < 1.0:
                        self.logger.warning(
                            f"CRITICAL: Low disk space during {operation_name}: {available_gb:.1f}GB available"
                        )
                    elif available_gb < 2.0:
                        self.logger.warning(
                            f"Low disk space during {operation_name}: {available_gb:.1f}GB available"
                        )
                    
                    time.sleep(interval_seconds)
                    
                except OSError as e:
                    self.logger.warning(f"Failed to monitor disk space during {operation_name}: {e}")
                    break
                except Exception as e:
                    self.logger.error(f"Unexpected error in disk space monitoring: {e}")
                    break
        
        # Start monitoring in background thread
        self._monitoring_active = True
        monitor_thread = threading.Thread(target=monitor, daemon=True)
        monitor_thread.start()
        self._monitor_thread = monitor_thread
    
    def stop_disk_space_monitoring(self):
        """Stop disk space monitoring"""
        if hasattr(self, '_monitoring_active'):
            self._monitoring_active = False
        if hasattr(self, '_monitor_thread'):
            self._monitor_thread.join(timeout=5)  # Wait up to 5 seconds for thread to finish
    
    def check_disk_space_during_backup(self, backup_path: Path, original_size_gb: float = 0.0) -> bool:
        """Check if disk space is sufficient during backup creation"""
        try:
            stat = shutil.disk_usage(backup_path.parent)
            available_gb = stat.free / (1024**3)
            
            # Calculate current backup size
            if backup_path.exists():
                current_size_gb = backup_path.stat().st_size / (1024**3)
            else:
                current_size_gb = 0.0
            
            # Estimate required space for completion (with 20% buffer)
            estimated_total = current_size_gb * 1.2
            if original_size_gb > 0:
                estimated_total = max(estimated_total, original_size_gb * 1.2)
            
            if available_gb < estimated_total:
                self.logger.error(
                    f"Disk space exhaustion risk: {available_gb:.1f}GB available, "
                    f"estimated {estimated_total:.1f}GB needed"
                )
                return False
            
            return True
            
        except OSError as e:
            self.logger.error(f"Failed to check disk space during backup: {e}")
            return False
    
    def _load_config(self) -> Dict[str, str]:
        """Load configuration from file"""
        try:
            with open(self.config_path, 'r') as f:
                config = {}
                for line in f:
                    line = line.strip()
                    if line and '=' in line and not line.startswith('#'):
                        key, value = line.split('=', 1)
                        config[key.strip()] = value.strip()
                return config
        except FileNotFoundError:
            raise FileNotFoundError(f"Configuration file not found: {self.config_path}")
        except Exception as e:
            raise ValueError(f"Failed to parse configuration file: {e}")
    
    def restore_backup(self, backup_id: str, force: bool = False) -> None:
        """Restore from a backup"""
        self.logger.info(f"Starting restore from backup: {backup_id}")
        
        try:
            args = ["restore", backup_id]
            if force:
                args.append("--force")
            
            self.run_script("restore.sh", args)
            
            self.logger.info(f"Restore completed successfully: {backup_id}")
            
        except Exception as e:
            self.logger.error(f"Restore failed: {e}")
            raise
    
    def upload_backup(self, backup_id: str, upload_type: str = None) -> None:
        """Upload backup to remote storage"""
        self.logger.info(f"Starting upload for backup: {backup_id}")
        
        try:
            args = [backup_id]
            if upload_type:
                args.extend(["--type", upload_type])
            
            self.run_python_script("upload.py", args)
            
            self.logger.info(f"Upload completed successfully: {backup_id}")
            
        except Exception as e:
            self.logger.error(f"Upload failed: {e}")
            raise
    
    def list_backups(self) -> List[Dict[str, Any]]:
        """List available backups sorted by newest first"""
        self.logger.info("Listing available backups...")
        
        try:
            result = self.run_script("restore.sh", ["list"])
            
            backups = []
            for line in result.stdout.strip().split('\n'):
                if line.strip():
                    parts = line.split(' - ')
                    if len(parts) >= 3:
                        backup_id = parts[0].strip()
                        timestamp = parts[1].strip()
                        size = parts[2].strip()
                        
                        backups.append({
                            'id': backup_id,
                            'timestamp': timestamp,
                            'size': size
                        })
            
            # The restore.sh script already sorts backups with 'sort -r' (newest first)
            # But we'll add a secondary sort by timestamp as a safety measure
            try:
                backups.sort(key=lambda x: x['timestamp'], reverse=True)
            except (KeyError, ValueError) as e:
                self.logger.warning(f"Could not sort backups by timestamp: {e}")
                # Keep the order from the script if timestamp sorting fails
            
            self.logger.info(f"Found {len(backups)} backups (sorted newest first)")
            return backups
            
        except Exception as e:
            self.logger.error(f"Failed to list backups: {e}")
            raise
    
    def show_backup_info(self, backup_id: str) -> Dict[str, Any]:
        """Show detailed information about a backup"""
        self.logger.info(f"Getting backup info: {backup_id}")
        
        try:
            result = self.run_script("restore.sh", ["info", backup_id])
            
            # Parse the output to extract backup information
            info = {}
            for line in result.stdout.split('\n'):
                if ':' in line:
                    key, value = line.split(':', 1)
                    info[key.strip()] = value.strip()
            
            return info
            
        except Exception as e:
            self.logger.error(f"Failed to get backup info: {e}")
            raise
    
    def verify_backup(self, backup_id: str) -> bool:
        """Verify backup integrity"""
        self.logger.info(f"Verifying backup integrity: {backup_id}")
        
        try:
            # Load configuration to get backup directory
            config = self.config
            backup_dir = Path(config['BACKUP_DIR']) / backup_id
            metadata_file = backup_dir / "metadata.json"
            
            if not metadata_file.exists():
                self.logger.error(f"Metadata file not found: {metadata_file}")
                return False
            
            # Load and validate metadata
            with open(metadata_file, 'r') as f:
                metadata = json.load(f)
            
            # Check required files
            required_files = metadata.get('files', [])
            for file_name in required_files:
                file_path = backup_dir / file_name
                if not file_path.exists():
                    self.logger.error(f"Required backup file missing: {file_path}")
                    return False
            
            self.logger.info(f"Backup verification passed: {backup_id}")
            return True
            
        except Exception as e:
            self.logger.error(f"Backup verification failed: {e}")
            return False
    
    def schedule_backup(self, upload_after: bool = True, upload_type: str = None) -> str:
        """Create a backup and optionally upload it"""
        self.logger.info("Starting scheduled backup...")
        
        try:
            # Create backup
            backup_id = self.create_backup()
            
            # Verify backup
            if not self.verify_backup(backup_id):
                raise Exception("Backup verification failed")
            
            # Upload if requested
            if upload_after:
                self.upload_backup(backup_id, upload_type)
            
            self.logger.info(f"Scheduled backup completed: {backup_id}")
            return backup_id
            
        except Exception as e:
            self.logger.error(f"Scheduled backup failed: {e}")
            raise
    
    def cleanup_old_backups(self) -> int:
        """Clean up old backups based on configuration"""
        self.logger.info("Starting backup cleanup...")
        
        try:
            # Load configuration
            config = self.config
            max_backups = int(config.get('MAX_BACKUPS', '0'))
            if max_backups <= 0:
                self.logger.info("Backup cleanup disabled (MAX_BACKUPS <= 0)")
                return 0
            
            # List backups and remove old ones
            backups = self.list_backups()
            if len(backups) <= max_backups:
                self.logger.info(f"No cleanup needed (have {len(backups)}, keep {max_backups})")
                return 0
            
            # Remove old backups
            backup_dir = Path(config['BACKUP_DIR'])
            removed_count = 0
            
            for backup in backups[max_backups:]:
                backup_path = backup_dir / backup['id']
                if backup_path.exists():
                    shutil.rmtree(backup_path)
                    self.logger.info(f"Removed old backup: {backup['id']}")
                    removed_count += 1
            
            self.logger.info(f"Cleanup completed: removed {removed_count} old backups")
            return removed_count
            
        except Exception as e:
            self.logger.error(f"Backup cleanup failed: {e}")
            raise
    
    def status(self) -> Dict[str, Any]:
        """Get backup system status"""
        self.logger.info("Getting backup system status...")
        
        try:
            # Load configuration
            config = self.config
            
            # Get backup list
            backups = self.list_backups()
            
            # Get disk usage
            backup_dir = Path(config['BACKUP_DIR'])
            if backup_dir.exists():
                total, used, free = shutil.disk_usage(backup_dir)
                disk_usage = {
                    'total': total,
                    'used': used,
                    'free': free,
                    'percent_used': (used / total) * 100
                }
            else:
                disk_usage = None
            
            status = {
                'config_file': str(self.config_path),
                'backup_directory': str(backup_dir),
                'total_backups': len(backups),
                'latest_backup': backups[0]['id'] if backups else None,
                'disk_usage': disk_usage,
                'max_backups': int(config.get('MAX_BACKUPS', '0')),
                'upload_type': config.get('UPLOAD_TYPE', 'none')
            }
            
            return status
            
        except Exception as e:
            self.logger.error(f"Failed to get status: {e}")
            raise


def validate_backup_id_format(ctx, param, value):
    """Validate backup ID format (YYYYMMDD_HHMMSS)"""
    if value and not re.match(r'^\d{8}_\d{6}$', value):
        raise click.BadParameter(
            f"Invalid backup ID format: {value}. Expected format: YYYYMMDD_HHMMSS"
        )
    return value


def validate_config_file(ctx, param, value):
    """Validate configuration file exists and is readable"""
    # Skip validation for init command
    if ctx.invoked_subcommand == 'init':
        return value
    
    config_path = Path(value)
    if not config_path.exists():
        raise click.BadParameter(f"Configuration file not found: {value}")
    if not config_path.is_file():
        raise click.BadParameter(f"Configuration path is not a file: {value}")
    if not os.access(value, os.R_OK):
        raise click.BadParameter(f"Configuration file is not readable: {value}")
    return value


def validate_upload_type(ctx, param, value):
    """Validate upload type is supported"""
    if value and value not in ['s3', 'sftp', 'ftp', 'local']:
        raise click.BadParameter(
            f"Unsupported upload type: {value}. Supported types: s3, sftp, ftp, local"
        )
    return value


# Click CLI setup
@click.group()
@click.option('--config', default='config/backup.conf', 
              help='Configuration file path')
@click.option('--verbose', '-v', is_flag=True, 
              help='Enable verbose logging')
@click.pass_context
def cli(ctx, config, verbose):
    """Nextcloud Backup Manager - CLI tool for managing Nextcloud backups"""
    # Setup logging level
    if verbose:
        logging.getLogger().setLevel(logging.DEBUG)
    
    # Store config in context, but don't initialize manager yet
    ctx.ensure_object(dict)
    ctx.obj['config_path'] = config


def get_manager(ctx):
    """Get or create backup manager instance"""
    if 'manager' not in ctx.obj:
        # Validate config file exists before creating manager
        config_path = Path(ctx.obj['config_path'])
        if not config_path.exists():
            raise click.ClickException(f"Configuration file not found: {ctx.obj['config_path']}")
        if not config_path.is_file():
            raise click.ClickException(f"Configuration path is not a file: {ctx.obj['config_path']}")
        if not os.access(ctx.obj['config_path'], os.R_OK):
            raise click.ClickException(f"Configuration file is not readable: {ctx.obj['config_path']}")
        
        ctx.obj['manager'] = NextcloudBackupManager(ctx.obj['config_path'])
    return ctx.obj['manager']


# Add init command directly to the main CLI group
@cli.command()
@click.pass_context
def init(ctx):
    """Initialize NextBack configuration"""
    import shutil
    import importlib.resources as resources
    
    # Get config paths
    config_dir = Path.home() / ".nextback" / "config"
    config_file = config_dir / "backup.conf"
    
    try:
        # Create config directory
        config_dir.mkdir(parents=True, exist_ok=True)
        
        # Copy template if config doesn't exist
        if not config_file.exists():
            # Try to find template in package data first
            template_content = None
            
            try:
                # Try to get template from package resources
                if resources.files("nextback").joinpath("backup.conf.template").is_file():
                    template_content = (resources.files("nextback") / "backup.conf.template").read_text()
                elif resources.files("nextback").joinpath("config/backup.conf.template").is_file():
                    template_content = (resources.files("nextback") / "config/backup.conf.template").read_text()
            except Exception:
                pass
            
            if template_content:
                # Write template content to config file
                with open(config_file, 'w') as f:
                    f.write(template_content)
                click.echo(f"✅ Configuration template created: {config_file}")
                click.echo(f"📝 Please edit the configuration file with your Nextcloud settings")
                click.echo(f"💡 Run 'nextback --config {config_file} backup' to use this configuration")
            else:
                # Fallback to file system search
                template_path = None
                possible_paths = [
                    Path(__file__).parent.parent / "config" / "backup.conf.template",
                    Path(__file__).parent / "backup.conf.template",
                    Path(__file__).parent.parent / "backup.conf.template",
                ]
                
                for path in possible_paths:
                    if path.exists():
                        template_path = path
                        break
                
                if template_path:
                    shutil.copy2(template_path, config_file)
                    click.echo(f"✅ Configuration template copied to: {config_file}")
                    click.echo(f"📝 Please edit the configuration file with your Nextcloud settings")
                    click.echo(f"💡 Run 'nextback --config {config_file} backup' to use this configuration")
                else:
                    click.echo(f"❌ Configuration template not found")
                    click.echo(f"🔍 Searched in: {possible_paths}")
                    raise click.Abort()
        else:
            click.echo(f"ℹ️  Configuration already exists: {config_file}")
            click.echo(f"💡 Edit the existing file or remove it to reinitialize")
            
    except Exception as e:
        click.echo(f"❌ Error initializing configuration: {e}", err=True)
        raise click.Abort()


@cli.command()
@click.option('--upload', is_flag=True, help='Upload backup after creation')
@click.option('--upload-type', type=click.Choice(['s3', 'sftp', 'ftp', 'local'],
                                      case_sensitive=False),
              callback=validate_upload_type,
              help='Upload type (overrides config)')
@click.pass_context
def backup(ctx, upload, upload_type):
    """Create a new backup"""
    manager = get_manager(ctx)
    
    try:
        backup_id = manager.create_backup()
        click.echo(f"✅ Backup created: {backup_id}")
        
        if upload:
            click.echo("📤 Uploading backup...")
            manager.upload_backup(backup_id, upload_type)
            click.echo(f"✅ Backup uploaded: {backup_id}")
            
    except Exception as e:
        click.echo(f"❌ Error: {e}", err=True)
        raise click.Abort()


@cli.command()
@click.argument('backup_id', callback=validate_backup_id_format)
@click.option('--force', is_flag=True, help='Skip confirmation prompts')
@click.pass_context
def restore(ctx, backup_id, force):
    """Restore from a backup"""
    manager = get_manager(ctx)
    
    try:
        if not force:
            if not click.confirm(f"⚠️  This will replace your current Nextcloud installation! "
                                f"Restore from backup {backup_id}?"):
                click.echo("Restore cancelled.")
                return
        
        click.echo(f"🔄 Restoring from backup: {backup_id}")
        manager.restore_backup(backup_id, force)
        click.echo(f"✅ Restore completed: {backup_id}")
        
    except Exception as e:
        click.echo(f"❌ Error: {e}", err=True)
        raise click.Abort()


@cli.command()
@click.argument('backup_id', callback=validate_backup_id_format)
@click.option('--type', 'upload_type', type=click.Choice(['s3', 'sftp', 'ftp', 'local'],
                                                    case_sensitive=False),
              callback=validate_upload_type,
              help='Upload type (overrides config)')
@click.pass_context
def upload(ctx, backup_id, upload_type):
    """Upload backup to remote storage"""
    manager = get_manager(ctx)
    
    try:
        click.echo(f"📤 Uploading backup: {backup_id}")
        manager.upload_backup(backup_id, upload_type)
        click.echo(f"✅ Upload completed: {backup_id}")
        
    except Exception as e:
        click.echo(f"❌ Error: {e}", err=True)
        raise click.Abort()


@cli.command()
@click.pass_context
def list(ctx):
    """List available backups"""
    manager = get_manager(ctx)
    
    try:
        backups = manager.list_backups()
        if backups:
            click.echo("📦 Available backups:")
            for backup in backups:
                click.echo(f"  📁 {backup['id']} - {backup['timestamp']} - {backup['size']}")
        else:
            click.echo("📭 No backups found")
            
    except Exception as e:
        click.echo(f"❌ Error: {e}", err=True)
        raise click.Abort()


@cli.command()
@click.argument('backup_id', callback=validate_backup_id_format)
@click.pass_context
def info(ctx, backup_id):
    """Show backup information"""
    manager = get_manager(ctx)
    
    try:
        info = manager.show_backup_info(backup_id)
        click.echo(f"📋 Backup Information for {backup_id}:")
        click.echo("=" * 50)
        for key, value in info.items():
            click.echo(f"{key}: {value}")
            
    except Exception as e:
        click.echo(f"❌ Error: {e}", err=True)
        raise click.Abort()


@cli.command()
@click.argument('backup_id', callback=validate_backup_id_format)
@click.pass_context
def verify(ctx, backup_id):
    """Verify backup integrity"""
    manager = get_manager(ctx)
    
    try:
        click.echo(f"🔍 Verifying backup: {backup_id}")
        if manager.verify_backup(backup_id):
            click.echo(f"✅ Backup verification passed: {backup_id}")
        else:
            click.echo(f"❌ Backup verification failed: {backup_id}")
            raise click.Abort()
            
    except Exception as e:
        click.echo(f"❌ Error: {e}", err=True)
        raise click.Abort()


@cli.command()
@click.pass_context
def status(ctx):
    """Show backup system status"""
    manager = get_manager(ctx)
    
    try:
        status = manager.status()
        click.echo("📊 Backup System Status:")
        click.echo("=" * 30)
        click.echo(f"📄 Configuration: {status['config_file']}")
        click.echo(f"📁 Backup Directory: {status['backup_directory']}")
        click.echo(f"📦 Total Backups: {status['total_backups']}")
        click.echo(f"🕐 Latest Backup: {status['latest_backup']}")
        click.echo(f"🔢 Max Backups: {status['max_backups']}")
        click.echo(f"📤 Upload Type: {status['upload_type']}")
        
        if status['disk_usage']:
            disk = status['disk_usage']
            click.echo(f"💾 Disk Usage: {disk['used']:,} / {disk['total']:,} bytes ({disk['percent_used']:.1f}%)")
            click.echo(f"💿 Free Space: {disk['free']:,} bytes")
            
    except Exception as e:
        click.echo(f"❌ Error: {e}", err=True)
        raise click.Abort()


@cli.command()
@click.pass_context
def cleanup(ctx):
    """Clean up old backups"""
    manager = get_manager(ctx)
    
    try:
        click.echo("🧹 Cleaning up old backups...")
        removed = manager.cleanup_old_backups()
        click.echo(f"✅ Cleanup completed: removed {removed} old backups")
        
    except Exception as e:
        click.echo(f"❌ Error: {e}", err=True)
        raise click.Abort()


if __name__ == '__main__':
    cli()
