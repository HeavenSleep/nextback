#!/usr/bin/env python3

"""
Nextcloud Backup Upload Script
Uploads Nextcloud backups to remote storage services
"""

import os
import sys
import json
import argparse
import logging
import tarfile
import hashlib
import tempfile
import time
import random
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Any

# Import required libraries
try:
    import boto3
    from botocore.exceptions import ClientError, NoCredentialsError
    HAS_BOTO3 = True
except ImportError:
    HAS_BOTO3 = False

try:
    import paramiko
    HAS_PARAMIKO = True
except ImportError:
    HAS_PARAMIKO = False

try:
    import yaml
    HAS_YAML = True
except ImportError:
    HAS_YAML = False


class BackupUploader:
    """Main backup uploader class supporting multiple storage backends"""
    
    def __init__(self, config_path: str):
        self.config_path = config_path
        self.config = self.load_config()
        self.setup_logging()
        self.logger = logging.getLogger(__name__)
        self.max_retries = int(self.config.get('MAX_RETRIES', '3'))
        self.retry_delay = int(self.config.get('RETRY_DELAY', '5'))
        self.chunk_size = int(self.config.get('UPLOAD_CHUNK_SIZE', '8388608'))  # 8MB default
        self.large_file_threshold = int(self.config.get('LARGE_FILE_THRESHOLD', '104857600'))  # 100MB
    
    def is_retryable_error(self, error: Exception) -> bool:
        """Determine if an error is retryable based on its type and characteristics"""
        # Network-related errors that should be retried
        retryable_errors = (
            ConnectionError,
            TimeoutError,
            OSError,  # Network-related OS errors
        )
        
        # Specific boto3/client errors that should be retried
        if HAS_BOTO3:
            retryable_boto3_errors = (
                ClientError,
                NoCredentialsError,  # Might be temporary credential issues
            )
            retryable_errors = retryable_errors + retryable_boto3_errors
        
        # Check if it's a retryable error type
        if isinstance(error, retryable_errors):
            # For ClientError, check if it's a retryable AWS error
            if HAS_BOTO3 and isinstance(error, ClientError):
                error_code = error.response.get('Error', {}).get('Code', '')
                retryable_aws_codes = {
                    'SlowDown',  # Request throttling
                    'RequestTimeout',  # Request timeout
                    'ServiceUnavailable',  # Service is unavailable
                    'InternalError',  # Internal service error
                    'RequestLimitExceeded',  # Too many requests
                    'Throttling',  # Throttling exception
                    'ProvisionedThroughputExceededException',  # DynamoDB throttling
                    'RequestTimeTooSkewed',  # Clock skew
                    'InvalidSignatureException',  # Temporary signature issues
                }
                return error_code in retryable_aws_codes
            
            return True
        
        # Non-retryable errors
        non_retryable_errors = (
            ValueError,  # Configuration or data errors
            KeyError,    # Missing configuration
            FileNotFoundError,  # Missing files
            PermissionError,  # Permission issues
            json.JSONDecodeError,  # JSON parsing errors
        )
        
        if isinstance(error, non_retryable_errors):
            return False
        
        # Default to retrying for unknown errors (conservative approach)
        self.logger.warning(f"Unknown error type {type(error).__name__}, will retry")
        return True

    def retry_with_backoff(self, func, *args, **kwargs):
        """Retry function with exponential backoff for network operations"""
        for attempt in range(self.max_retries + 1):
            try:
                return func(*args, **kwargs)
            except Exception as e:
                if attempt == self.max_retries:
                    self.logger.error(f"Operation failed after {self.max_retries + 1} attempts: {e}")
                    raise
                
                # Check if error is retryable
                if not self.is_retryable_error(e):
                    self.logger.error(f"Non-retryable error occurred: {e}")
                    raise
                
                delay = self.retry_delay * (2 ** attempt) + random.uniform(0, 1)
                self.logger.warning(f"Retryable error (attempt {attempt + 1}/{self.max_retries + 1}): {e}")
                self.logger.info(f"Retrying in {delay:.1f} seconds...")
                time.sleep(delay)
    
    def check_network_connectivity(self):
        """Check basic network connectivity"""
        try:
            import socket
            socket.create_connection(("8.8.8.8", 53), timeout=5)
            return True
        except OSError:
            return False
        
    def load_config(self) -> Dict[str, Any]:
        """Load configuration from file"""
        if not os.path.exists(self.config_path):
            raise FileNotFoundError(f"Configuration file not found: {self.config_path}")
        
        with open(self.config_path, 'r') as f:
            if self.config_path.endswith('.yaml') or self.config_path.endswith('.yml'):
                if not HAS_YAML:
                    raise ImportError("PyYAML is required for YAML configuration files")
                return yaml.safe_load(f)
            else:
                # Parse simple key=value config file with proper handling of values containing '='
                config = {}
                for line in f:
                    line = line.strip()
                    if line and not line.startswith('#') and '=' in line:
                        # Split only on the first '=' to handle values containing '='
                        key, value = line.split('=', 1)
                        config[key.strip()] = value.strip()
                return config
    
    def setup_logging(self):
        """Setup logging configuration"""
        log_dir = Path(__file__).parent.parent / "logs"
        log_dir.mkdir(exist_ok=True)
        
        log_file = log_dir / "upload.log"
        
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
            handlers=[
                logging.FileHandler(log_file),
                logging.StreamHandler(sys.stdout)
            ]
        )
    
    def get_backup_info(self, backup_id: str) -> Dict[str, Any]:
        """Get backup information from metadata file"""
        backup_dir = Path(self.config['BACKUP_DIR']) / backup_id
        metadata_file = backup_dir / "metadata.json"
        
        if not metadata_file.exists():
            raise FileNotFoundError(f"Backup metadata not found: {metadata_file}")
        
        with open(metadata_file, 'r') as f:
            return json.load(f)
    
    def calculate_file_hash(self, file_path: Path) -> str:
        """Calculate SHA256 hash of a file"""
        hash_sha256 = hashlib.sha256()
        with open(file_path, "rb") as f:
            for chunk in iter(lambda: f.read(4096), b""):
                hash_sha256.update(chunk)
        return hash_sha256.hexdigest()
    
    def create_upload_manifest(self, backup_id: str, uploaded_files: List[Dict[str, str]]) -> Dict[str, Any]:
        """Create upload manifest"""
        backup_info = self.get_backup_info(backup_id)
        
        manifest = {
            "backup_id": backup_id,
            "upload_timestamp": datetime.now().isoformat(),
            "backup_info": backup_info,
            "uploaded_files": uploaded_files,
            "uploader_version": "1.0.0"
        }
        
        return manifest
    
    def get_upload_progress(self, backup_id: str) -> Dict[str, Any]:
        """Get upload progress from previous session"""
        progress_file = Path(self.config['BACKUP_DIR']) / backup_id / "upload_progress.json"
        
        if progress_file.exists():
            with open(progress_file, 'r') as f:
                return json.load(f)
        return {}
    
    def save_upload_progress(self, backup_id: str, progress: Dict[str, Any]) -> None:
        """Save upload progress for resume capability"""
        progress_file = Path(self.config['BACKUP_DIR']) / backup_id / "upload_progress.json"
        
        with open(progress_file, 'w') as f:
            json.dump(progress, f, indent=2)
    
    def clear_upload_progress(self, backup_id: str) -> None:
        """Clear upload progress after successful completion"""
        progress_file = Path(self.config['BACKUP_DIR']) / backup_id / "upload_progress.json"
        if progress_file.exists():
            progress_file.unlink()


class S3Uploader(BackupUploader):
    """Amazon S3 backup uploader"""
    
    def __init__(self, config_path: str):
        super().__init__(config_path)
        self.validate_s3_config()
        self.s3_client = self.create_s3_client()
    
    def validate_s3_config(self):
        """Validate S3 configuration"""
        required_keys = ['AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 
                        'AWS_REGION', 'S3_BUCKET']
        
        for key in required_keys:
            if key not in self.config:
                raise ValueError(f"Missing required S3 configuration: {key}")
        
        if not HAS_BOTO3:
            raise ImportError("boto3 is required for S3 uploads")
    
    def create_s3_client(self):
        """Create S3 client"""
        return boto3.client(
            's3',
            aws_access_key_id=self.config['AWS_ACCESS_KEY_ID'],
            aws_secret_access_key=self.config['AWS_SECRET_ACCESS_KEY'],
            region_name=self.config['AWS_REGION']
        )
    
    def upload_file_chunked(self, file_path: Path, s3_key: str) -> Dict[str, str]:
        """Upload large file to S3 using multipart upload"""
        file_size = file_path.stat().st_size
        self.logger.info(f"Starting chunked upload for {file_path.name} ({file_size:,} bytes)")
        
        def _upload_chunked():
            # Calculate file hash for integrity check
            file_hash = self.calculate_file_hash(file_path)
            
            # Initiate multipart upload
            response = self.s3_client.create_multipart_upload(
                Bucket=self.config['S3_BUCKET'],
                Key=s3_key,
                Metadata={
                    'original-hash': file_hash,
                    'backup-id': str(file_path.parent.name),
                    'upload-timestamp': datetime.now().isoformat(),
                    'chunked-upload': 'true'
                }
            )
            
            upload_id = response['UploadId']
            parts = []
            
            try:
                # Upload file in chunks
                with open(file_path, 'rb') as f:
                    part_number = 1
                    while True:
                        chunk = f.read(self.chunk_size)
                        if not chunk:
                            break
                        
                        # Upload part
                        part_response = self.s3_client.upload_part(
                            Bucket=self.config['S3_BUCKET'],
                            Key=s3_key,
                            PartNumber=part_number,
                            UploadId=upload_id,
                            Body=chunk
                        )
                        
                        parts.append({
                            'ETag': part_response['ETag'],
                            'PartNumber': part_number
                        })
                        
                        # Log progress
                        uploaded_bytes = min(part_number * self.chunk_size, file_size)
                        progress = (uploaded_bytes / file_size) * 100
                        self.logger.info(f"Upload progress: {progress:.1f}% ({uploaded_bytes:,}/{file_size:,} bytes)")
                        
                        part_number += 1
                
                # Complete multipart upload
                self.s3_client.complete_multipart_upload(
                    Bucket=self.config['S3_BUCKET'],
                    Key=s3_key,
                    UploadId=upload_id,
                    MultipartUpload={'Parts': parts}
                )
                
                # Verify final upload
                response = self.s3_client.head_object(
                    Bucket=self.config['S3_BUCKET'],
                    Key=s3_key
                )
                
                uploaded_size = response['ContentLength']
                if uploaded_size != file_size:
                    raise ValueError(f"Size mismatch after chunked upload: {uploaded_size} vs {file_size}")
                
                return {
                    'local_path': str(file_path),
                    'remote_path': f"s3://{self.config['S3_BUCKET']}/{s3_key}",
                    'size': uploaded_size,
                    'hash': file_hash,
                    'upload_time': datetime.now().isoformat(),
                    'chunked': True
                }
                
            except Exception as e:
                # Abort multipart upload on error
                try:
                    self.s3_client.abort_multipart_upload(
                        Bucket=self.config['S3_BUCKET'],
                        Key=s3_key,
                        UploadId=upload_id
                    )
                    self.logger.info(f"Successfully aborted multipart upload for {file_path.name}")
                except Exception as abort_error:
                    self.logger.error(f"Failed to abort multipart upload for {file_path.name}: {abort_error}")
                    # Note: Failed abort may leave orphaned multipart uploads
                    # Consider implementing cleanup mechanism for orphaned uploads
                raise
        
        try:
            result = self.retry_with_backoff(_upload_chunked)
            self.logger.info(f"Successfully uploaded {file_path.name} using chunked upload ({result['size']} bytes)")
            return result
            
        except Exception as e:
            self.logger.error(f"Chunked S3 upload failed: {e}")
            raise
    
    def upload_file(self, file_path: Path, s3_key: str) -> Dict[str, str]:
        """Upload single file to S3 with retry logic and chunking for large files"""
        file_size = file_path.stat().st_size
        
        # Use chunked upload for large files
        if file_size > self.large_file_threshold:
            return self.upload_file_chunked(file_path, s3_key)
        
        self.logger.info(f"Uploading {file_path} to s3://{self.config['S3_BUCKET']}/{s3_key}")
        
        def _upload():
            # Calculate file hash for integrity check
            file_hash = self.calculate_file_hash(file_path)
            
            # Upload file
            self.s3_client.upload_file(
                str(file_path),
                self.config['S3_BUCKET'],
                s3_key,
                ExtraArgs={
                    'Metadata': {
                        'original-hash': file_hash,
                        'backup-id': str(file_path.parent.name),
                        'upload-timestamp': datetime.now().isoformat()
                    }
                }
            )
            
            # Verify upload
            response = self.s3_client.head_object(
                Bucket=self.config['S3_BUCKET'],
                Key=s3_key
            )
            
            uploaded_size = response['ContentLength']
            original_size = file_path.stat().st_size
            
            if uploaded_size != original_size:
                raise ValueError(f"Size mismatch after upload: {uploaded_size} vs {original_size}")
            
            return {
                'local_path': str(file_path),
                'remote_path': f"s3://{self.config['S3_BUCKET']}/{s3_key}",
                'size': uploaded_size,
                'hash': file_hash,
                'upload_time': datetime.now().isoformat(),
                'chunked': False
            }
        
        try:
            result = self.retry_with_backoff(_upload)
            self.logger.info(f"Successfully uploaded {file_path.name} ({result['size']} bytes)")
            return result
            
        except Exception as e:
            self.logger.error(f"S3 upload failed: {e}")
            raise
    
    def upload_backup(self, backup_id: str) -> Dict[str, Any]:
        """Upload entire backup to S3 with resume capability"""
        backup_dir = Path(self.config['BACKUP_DIR']) / backup_id
        
        if not backup_dir.exists():
            raise FileNotFoundError(f"Backup directory not found: {backup_dir}")
        
        self.logger.info(f"Starting S3 upload for backup: {backup_id}")
        
        # Check for existing progress
        progress = self.get_upload_progress(backup_id)
        uploaded_files = progress.get('uploaded_files', [])
        failed_files = progress.get('failed_files', [])
        
        # Create S3 prefix for this backup
        s3_prefix = f"nextcloud-backups/{backup_id}/"
        
        # Get all files that need to be uploaded
        all_files = list(backup_dir.rglob('*'))
        all_files = [f for f in all_files if f.is_file()]
        
        # Filter out already successfully uploaded files
        files_to_upload = []
        for file_path in all_files:
            relative_path = str(file_path.relative_to(backup_dir))
            if not any(uf.get('local_path', '').endswith(relative_path) for uf in uploaded_files):
                files_to_upload.append(file_path)
        
        if not files_to_upload:
            self.logger.info("All files already uploaded, completing manifest upload")
        else:
            self.logger.info(f"Resuming upload: {len(files_to_upload)} files remaining")
        
        # Upload remaining files
        for file_path in files_to_upload:
            relative_path = file_path.relative_to(backup_dir)
            s3_key = s3_prefix + str(relative_path)
            
            try:
                upload_info = self.upload_file(file_path, s3_key)
                uploaded_files.append(upload_info)
                
                # Save progress after each successful upload
                progress['uploaded_files'] = uploaded_files
                progress['failed_files'] = failed_files
                self.save_upload_progress(backup_id, progress)
                
            except Exception as e:
                self.logger.error(f"Failed to upload {file_path}: {e}")
                failed_files.append({
                    'local_path': str(file_path),
                    'error': str(e),
                    'timestamp': datetime.now().isoformat()
                })
                progress['uploaded_files'] = uploaded_files
                progress['failed_files'] = failed_files
                self.save_upload_progress(backup_id, progress)
                raise
        
        # Create and upload manifest
        manifest = self.create_upload_manifest(backup_id, uploaded_files)
        manifest_key = f"{s3_prefix}upload_manifest.json"
        
        manifest_content = json.dumps(manifest, indent=2)
        self.s3_client.put_object(
            Bucket=self.config['S3_BUCKET'],
            Key=manifest_key,
            Body=manifest_content,
            ContentType='application/json'
        )
        
        # Clear progress after successful completion
        self.clear_upload_progress(backup_id)
        
        self.logger.info(f"S3 upload completed for backup: {backup_id}")
        return manifest


class FTPUploader(BackupUploader):
    """FTP/SFTP backup uploader"""
    
    def __init__(self, config_path: str):
        super().__init__(config_path)
        self.validate_ftp_config()
        self.ssh_client = None
        self.ftp_client = None
    
    def __enter__(self):
        """Context manager entry"""
        return self
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit - ensure cleanup"""
        self.disconnect_sftp()
        return False
    
    def validate_ftp_config(self):
        """Validate FTP configuration"""
        required_keys = ['FTP_HOST', 'FTP_USERNAME', 'FTP_PASSWORD', 'FTP_REMOTE_DIR']
        
        for key in required_keys:
            if key not in self.config:
                raise ValueError(f"Missing required FTP configuration: {key}")
        
        if not HAS_PARAMIKO:
            raise ImportError("paramiko is required for SFTP uploads")
    
    def connect_sftp(self):
        """Establish SFTP connection with retry logic"""
        self.logger.info(f"Connecting to SFTP server: {self.config['FTP_HOST']}")
        
        def _connect():
            self.ssh_client = paramiko.SSHClient()
            self.ssh_client.load_system_host_keys()
            self.ssh_client.set_missing_host_key_policy(paramiko.RejectPolicy)
            
            self.ssh_client.connect(
                hostname=self.config['FTP_HOST'],
                port=int(self.config.get('FTP_PORT', 22)),
                username=self.config['FTP_USERNAME'],
                password=self.config['FTP_PASSWORD'],
                timeout=30
            )
            
            self.ftp_client = self.ssh_client.open_sftp()
        
        try:
            self.retry_with_backoff(_connect)
            self.logger.info("SFTP connection established")
            
        except Exception as e:
            self.logger.error(f"SFTP connection failed: {e}")
            raise
    
    def disconnect_sftp(self):
        """Close SFTP connection"""
        if self.ftp_client:
            self.ftp_client.close()
        if self.ssh_client:
            self.ssh_client.close()
        self.logger.info("SFTP connection closed")
    
    def ensure_remote_directory(self, remote_path: str):
        """Ensure remote directory exists"""
        try:
            self.ftp_client.stat(remote_path)
        except FileNotFoundError:
            self.logger.info(f"Creating remote directory: {remote_path}")
            self.ftp_client.mkdir(remote_path)
    
    def upload_file(self, local_path: Path, remote_path: str) -> Dict[str, str]:
        """Upload single file via SFTP with retry logic"""
        self.logger.info(f"Uploading {local_path} to {remote_path}")
        
        def _upload():
            # Ensure remote directory exists
            remote_dir = str(Path(remote_path).parent)
            self.ensure_remote_directory(remote_dir)
            
            # Calculate file hash
            file_hash = self.calculate_file_hash(local_path)
            
            # Upload file
            self.ftp_client.put(str(local_path), remote_path)
            
            # Verify upload
            remote_stat = self.ftp_client.stat(remote_path)
            local_stat = local_path.stat()
            
            if remote_stat.st_size != local_stat.st_size:
                raise ValueError(f"Size mismatch after upload: {remote_stat.st_size} vs {local_stat.st_size}")
            
            return {
                'local_path': str(local_path),
                'remote_path': remote_path,
                'size': remote_stat.st_size,
                'hash': file_hash,
                'upload_time': datetime.now().isoformat()
            }
        
        try:
            result = self.retry_with_backoff(_upload)
            self.logger.info(f"Successfully uploaded {local_path.name} ({result['size']} bytes)")
            return result
            
        except Exception as e:
            self.logger.error(f"SFTP upload failed: {e}")
            raise
    
    def upload_backup(self, backup_id: str) -> Dict[str, Any]:
        """Upload entire backup via SFTP"""
        backup_dir = Path(self.config['BACKUP_DIR']) / backup_id
        
        if not backup_dir.exists():
            raise FileNotFoundError(f"Backup directory not found: {backup_dir}")
        
        self.logger.info(f"Starting SFTP upload for backup: {backup_id}")
        
        # Connect to SFTP server
        self.connect_sftp()
        
        try:
            # Create remote directory for this backup
            remote_backup_dir = f"{self.config['FTP_REMOTE_DIR']}/{backup_id}"
            self.ensure_remote_directory(remote_backup_dir)
            
            uploaded_files = []
            
            # Upload all files in backup directory
            for file_path in backup_dir.rglob('*'):
                if file_path.is_file():
                    # Create remote path
                    relative_path = file_path.relative_to(backup_dir)
                    remote_path = f"{remote_backup_dir}/{relative_path}"
                    
                    try:
                        upload_info = self.upload_file(file_path, remote_path)
                        uploaded_files.append(upload_info)
                    except Exception as e:
                        self.logger.error(f"Failed to upload {file_path}: {e}")
                        raise
            
            # Create and upload manifest using proper temp file handling
            manifest = self.create_upload_manifest(backup_id, uploaded_files)
            manifest_path = f"{remote_backup_dir}/upload_manifest.json"
            
            temp_file = None
            try:
                # Create temporary file with secure permissions
                temp_file = tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False)
                json.dump(manifest, temp_file, indent=2)
                temp_file.flush()
                os.fsync(temp_file.fileno())  # Ensure data is written to disk
                temp_file.close()
                
                # Upload the manifest
                self.ftp_client.put(temp_file.name, manifest_path)
                
            except Exception as e:
                self.logger.error(f"Failed to upload manifest: {e}")
                raise
            finally:
                # Clean up temporary file
                if temp_file and os.path.exists(temp_file.name):
                    try:
                        os.unlink(temp_file.name)
                        self.logger.debug(f"Cleaned up temporary file: {temp_file.name}")
                    except OSError as cleanup_error:
                        self.logger.warning(f"Failed to clean up temporary file {temp_file.name}: {cleanup_error}")
            
            self.logger.info(f"SFTP upload completed for backup: {backup_id}")
            return manifest
            
        finally:
            self.disconnect_sftp()


class LocalUploader(BackupUploader):
    """Local backup uploader (for testing or local copy)"""
    
    def upload_backup(self, backup_id: str) -> Dict[str, Any]:
        """Copy backup to local directory"""
        backup_dir = Path(self.config['BACKUP_DIR']) / backup_id
        local_copy_dir = Path(self.config.get('LOCAL_COPY_DIR', '/tmp/nextcloud-backups')) / backup_id
        
        if not backup_dir.exists():
            raise FileNotFoundError(f"Backup directory not found: {backup_dir}")
        
        self.logger.info(f"Creating local copy of backup: {backup_id}")
        
        # Create target directory
        local_copy_dir.mkdir(parents=True, exist_ok=True)
        
        uploaded_files = []
        
        # Copy all files
        for file_path in backup_dir.rglob('*'):
            if file_path.is_file():
                # Create target path
                relative_path = file_path.relative_to(backup_dir)
                target_path = local_copy_dir / relative_path
                
                # Ensure target directory exists
                target_path.parent.mkdir(parents=True, exist_ok=True)
                
                # Copy file
                import shutil
                shutil.copy2(file_path, target_path)
                
                upload_info = {
                    'local_path': str(file_path),
                    'remote_path': str(target_path),
                    'size': file_path.stat().st_size,
                    'hash': self.calculate_file_hash(file_path),
                    'upload_time': datetime.now().isoformat()
                }
                uploaded_files.append(upload_info)
        
        # Create manifest
        manifest = self.create_upload_manifest(backup_id, uploaded_files)
        manifest_file = local_copy_dir / "upload_manifest.json"
        
        with open(manifest_file, 'w') as f:
            json.dump(manifest, f, indent=2)
        
        self.logger.info(f"Local copy completed for backup: {backup_id}")
        return manifest


def create_uploader(config_path: str, upload_type: str) -> BackupUploader:
    """Factory function to create appropriate uploader"""
    uploaders = {
        's3': S3Uploader,
        'sftp': FTPUploader,
        'ftp': FTPUploader,
        'local': LocalUploader
    }
    
    if upload_type not in uploaders:
        raise ValueError(f"Unsupported upload type: {upload_type}")
    
    return uploaders[upload_type](config_path)


def main():
    parser = argparse.ArgumentParser(description='Upload Nextcloud backups to remote storage')
    parser.add_argument('backup_id', help='Backup ID to upload')
    parser.add_argument('--config', default='config/backup.conf', 
                       help='Configuration file path')
    parser.add_argument('--type', choices=['s3', 'sftp', 'ftp', 'local'], 
                       default='s3', help='Upload type')
    parser.add_argument('--verbose', '-v', action='store_true', 
                       help='Enable verbose logging')
    
    args = parser.parse_args()
    
    # Setup logging level
    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
    
    try:
        # Create uploader
        uploader = create_uploader(args.config, args.type)
        
        # Upload backup
        manifest = uploader.upload_backup(args.backup_id)
        
        print(f"\nUpload completed successfully!")
        print(f"Backup ID: {manifest['backup_id']}")
        print(f"Files uploaded: {len(manifest['uploaded_files'])}")
        print(f"Total size: {sum(f['size'] for f in manifest['uploaded_files']):,} bytes")
        
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
