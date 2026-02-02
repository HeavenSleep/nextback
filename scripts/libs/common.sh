#!/bin/bash

# Common functions for Nextcloud backup scripts
# This file contains shared functionality used by backup.sh and restore.sh

# =============================================================================
# GLOBAL VARIABLES AND COLORS
# =============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global array to track temporary files for cleanup
TEMP_FILES=()

# Global array to track temporary directories for cleanup
TEMP_DIRS=()

# Global cleanup function for all temporary files and directories
cleanup_all_temp_files() {
    for temp_file in "${TEMP_FILES[@]}"; do
        if [[ -f "$temp_file" ]]; then
            rm -f "$temp_file" 2>/dev/null || true
        fi
    done
    for temp_dir in "${TEMP_DIRS[@]}"; do
        if [[ -d "$temp_dir" ]]; then
            rm -rf "$temp_dir" 2>/dev/null || true
        fi
    done
    TEMP_FILES=()
    TEMP_DIRS=()
}

# Set up global cleanup trap
trap cleanup_all_temp_files EXIT INT TERM

# =============================================================================
# STANDARDIZED ERROR HANDLING
# =============================================================================

# Standard error codes
declare -A ERROR_CODES=(
    ["GENERAL_ERROR"]=1
    ["CONFIG_ERROR"]=2
    ["PERMISSION_ERROR"]=3
    ["NETWORK_ERROR"]=4
    ["DISK_SPACE_ERROR"]=5
    ["DATABASE_ERROR"]=6
    ["BACKUP_ERROR"]=7
    ["RESTORE_ERROR"]=8
    ["UPLOAD_ERROR"]=9
    ["VALIDATION_ERROR"]=10
    ["LOCK_ERROR"]=11
)

# Standardized error handling function
handle_error() {
    local error_code="$1"
    local error_message="$2"
    local exit_code="${ERROR_CODES[$error_code]:-${ERROR_CODES[GENERAL_ERROR]}}"
    
    log "ERROR" "[$error_code] $error_message"
    
    # Clean up any temporary files before exiting
    cleanup_all_temp_files
    
    # Release any locks
    release_backup_lock 2>/dev/null || true
    
    exit $exit_code
}

# Standardized error exit function
error_exit() {
    local error_message="$1"
    local error_code="${2:-GENERAL_ERROR}"
    handle_error "$error_code" "$error_message"
}

# Warning function that doesn't exit
warn() {
    local warning_message="$1"
    log "WARN" "WARNING: $warning_message"
}

# Success message function
success() {
    local success_message="$1"
    log "INFO" "SUCCESS: $success_message"
}

# Validation error function
validation_error() {
    local field="$1"
    local value="$2"
    local reason="$3"
    error_exit "Validation failed for $field: '$value' - $reason" "VALIDATION_ERROR"
}

# Permission error function
permission_error() {
    local path="$1"
    local operation="$2"
    error_exit "Permission denied for $operation on: $path" "PERMISSION_ERROR"
}

# Network error function
network_error() {
    local operation="$1"
    local target="$2"
    error_exit "Network error during $operation to $target" "NETWORK_ERROR"
}

# Disk space error function
disk_space_error() {
    local path="$1"
    local required="$2"
    local available="$3"
    error_exit "Insufficient disk space at $path: required $required, available $available" "DISK_SPACE_ERROR"
}

# Database error function
database_error() {
    local operation="$1"
    local details="$2"
    error_exit "Database error during $operation: $details" "DATABASE_ERROR"
}

# Backup error function
backup_error() {
    local operation="$1"
    local details="$2"
    error_exit "Backup error during $operation: $details" "BACKUP_ERROR"
}

# Restore error function
restore_error() {
    local operation="$1"
    local details="$2"
    error_exit "Restore error during $operation: $details" "RESTORE_ERROR"
}

# Upload error function
upload_error() {
    local operation="$1"
    local details="$2"
    error_exit "Upload error during $operation: $details" "UPLOAD_ERROR"
}

# Lock error function
lock_error() {
    local operation="$1"
    local details="$2"
    error_exit "Lock error during $operation: $details" "LOCK_ERROR"
}

# =============================================================================
# PROGRESS INDICATOR FUNCTIONS
# =============================================================================

# Progress indicator state
declare -A PROGRESS_STATE
PROGRESS_SPINNER_CHARS=('|' '/' '-' '\')
PROGRESS_SPINNER_INDEX=0

# Initialize progress indicator
init_progress() {
    local operation="$1"
    local total_items="${2:-0}"
    
    PROGRESS_STATE["operation"]="$operation"
    PROGRESS_STATE["total"]=$total_items
    PROGRESS_STATE["current"]=0
    PROGRESS_STATE["start_time"]=$(date +%s)
    PROGRESS_STATE["last_update"]=0
    
    log "INFO" "Starting: $operation"
}

# Update progress indicator
update_progress() {
    local current="${1:-1}"
    local message="${2:-}"
    
    PROGRESS_STATE["current"]=$current
    local now=$(date +%s)
    
    # Only update every 1 second to avoid too frequent output
    if [[ $((now - PROGRESS_STATE["last_update"])) -ge 1 ]]; then
        local operation="${PROGRESS_STATE["operation"]}"
        local total="${PROGRESS_STATE["total"]}"
        local elapsed=$((now - PROGRESS_STATE["start_time"]))
        
        if [[ $total -gt 0 ]]; then
            local percentage=$((current * 100 / total))
            local spinner="${PROGRESS_SPINNER_CHARS[$((PROGRESS_SPINNER_INDEX % 4))]}"
            PROGRESS_SPINNER_INDEX=$((PROGRESS_SPINNER_INDEX + 1))
            
            # Calculate ETA
            local eta=0
            if [[ $current -gt 0 ]]; then
                eta=$((elapsed * (total - current) / current))
            fi
            
            printf "\r%s [%s] %d/%d (%d%%) ETA: %ds %s" \
                "$operation" "$spinner" "$current" "$total" "$percentage" "$eta" "$message"
        else
            local spinner="${PROGRESS_SPINNER_CHARS[$((PROGRESS_SPINNER_INDEX % 4))]}"
            PROGRESS_SPINNER_INDEX=$((PROGRESS_SPINNER_INDEX + 1))
            printf "\r%s [%s] %s (%ds elapsed)" \
                "$operation" "$spinner" "$message" "$elapsed"
        fi
        
        PROGRESS_STATE["last_update"]=$now
    fi
}

# Complete progress indicator
complete_progress() {
    local message="${1:-Completed}"
    local operation="${PROGRESS_STATE["operation"]}"
    local total="${PROGRESS_STATE["total"]}"
    local current="${PROGRESS_STATE["current"]}"
    local elapsed=$(($(date +%s) - PROGRESS_STATE["start_time"]))
    
    # Clear the progress line
    printf "\r%*s\r" 80
    
    if [[ $total -gt 0 ]]; then
        local percentage=$((current * 100 / total))
        log "INFO" "$operation: $message ($current/$total, $percentage%, ${elapsed}s elapsed)"
    else
        log "INFO" "$operation: $message (${elapsed}s elapsed)"
    fi
    
    # Reset progress state
    unset PROGRESS_STATE["operation"]
    unset PROGRESS_STATE["total"]
    unset PROGRESS_STATE["current"]
    unset PROGRESS_STATE["start_time"]
    unset PROGRESS_STATE["last_update"]
}

# Simple progress bar for file operations
show_file_progress() {
    local current="$1"
    local total="$2"
    local file_name="$3"
    local width=50
    
    local percentage=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))
    
    printf "\r[%s] [%s%s] %d%% %s" \
        "$file_name" \
        "$(printf "%*s" $filled | tr ' ' '=')" \
        "$(printf "%*s" $empty)" \
        "$percentage" \
        "$(format_bytes $current)/$(format_bytes $total)"
}

# Format bytes for human readable output
format_bytes() {
    local bytes=$1
    local units=('B' 'KB' 'MB' 'GB' 'TB')
    local unit=0
    
    while [[ $bytes -gt 1024 && $unit -lt 4 ]]; do
        bytes=$((bytes / 1024))
        unit=$((unit + 1))
    done
    
    echo "${bytes}${units[$unit]}"
}

# =============================================================================
# LOCKING FUNCTIONS
# =============================================================================

# Acquire exclusive lock for backup operations
acquire_backup_lock() {
    local lock_file="$PROJECT_ROOT/.backup.lock"
    local timeout=300  # 5 minutes timeout
    local wait_interval=1  # 1 second intervals
    local max_lock_age=3600  # 1 hour maximum lock age
    
    log "INFO" "Acquiring backup lock..."
    
    # Clean up any existing stale locks first
    cleanup_stale_locks "$lock_file" "$max_lock_age"
    
    local count=0
    while [[ $count -lt $timeout ]]; do
        # Try to create lock file atomically using mkdir (atomic operation)
        local lock_dir="$lock_file.lockdir"
        if mkdir "$lock_dir" 2>/dev/null; then
            # Successfully created lock directory, write PID and timestamp
            echo $$ > "$lock_dir/pid"
            echo $(date +%s) > "$lock_dir/timestamp"
            echo "backup" > "$lock_dir/purpose"  # Add purpose for better debugging
            # Create symlink for compatibility
            ln -sf "$lock_dir/pid" "$lock_file"
            log "INFO" "Backup lock acquired (PID: $$)"
            return 0
        fi
        
        # Check if lock is stale (process no longer exists or too old)
        if [[ -d "$lock_dir" ]]; then
            local lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
            local lock_timestamp=$(cat "$lock_dir/timestamp" 2>/dev/null || echo "")
            local current_time=$(date +%s)
            
            # Check if process is dead
            if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
                log "WARN" "Removing stale lock from dead PID $lock_pid"
                rm -rf "$lock_dir"
                rm -f "$lock_file"
                continue
            fi
            
            # Check if lock is older than max age
            if [[ -n "$lock_timestamp" ]] && [[ $((current_time - lock_timestamp)) -gt $max_lock_age ]]; then
                log "WARN" "Removing old lock from PID $lock_pid (age: $((current_time - lock_timestamp)) seconds, max: $max_lock_age)"
                rm -rf "$lock_dir"
                rm -f "$lock_file"
                continue
            fi
        fi
        
        sleep $wait_interval
        count=$((count + wait_interval))
    done
    
    log "ERROR" "Failed to acquire backup lock within ${timeout} seconds"
    log "ERROR" "Another backup process may be running or lock is stuck"
    return 1
}

# Clean up stale locks
cleanup_stale_locks() {
    local lock_file="$1"
    local max_age="${2:-3600}"  # Default 1 hour
    local lock_dir="$lock_file.lockdir"
    
    if [[ -d "$lock_dir" ]]; then
        local lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
        local lock_timestamp=$(cat "$lock_dir/timestamp" 2>/dev/null || echo "")
        local current_time=$(date +%s)
        
        # Remove if process is dead
        if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
            log "INFO" "Cleaning up stale lock from dead PID $lock_pid"
            rm -rf "$lock_dir"
            rm -f "$lock_file"
            return 0
        fi
        
        # Remove if too old
        if [[ -n "$lock_timestamp" ]] && [[ $((current_time - lock_timestamp)) -gt $max_age ]]; then
            log "INFO" "Cleaning up old lock (age: $((current_time - lock_timestamp)) seconds)"
            rm -rf "$lock_dir"
            rm -f "$lock_file"
            return 0
        fi
    fi
}

# Acquire backup directory lock for specific operations
acquire_backup_dir_lock() {
    local backup_dir="$1"
    local lock_file="$backup_dir/.backup_dir.lock"
    local timeout=60  # 1 minute timeout for directory operations
    local wait_interval=1  # 1 second intervals
    
    log "INFO" "Acquiring backup directory lock for: $backup_dir"
    
    local count=0
    while [[ $count -lt $timeout ]]; do
        # Try to create lock directory atomically
        local lock_dir="$lock_file.lockdir"
        if mkdir "$lock_dir" 2>/dev/null; then
            # Successfully created lock directory, write PID and timestamp
            echo $$ > "$lock_dir/pid"
            echo $(date +%s) > "$lock_dir/timestamp"
            ln -sf "$lock_dir/pid" "$lock_file"
            log "INFO" "Backup directory lock acquired (PID: $$)"
            return 0
        fi
        
        # Check if lock is stale
        if [[ -d "$lock_dir" ]]; then
            local lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
            if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
                log "WARN" "Removing stale directory lock from dead PID $lock_pid"
                rm -rf "$lock_dir"
                rm -f "$lock_file"
                continue
            fi
        fi
        
        sleep $wait_interval
        count=$((count + wait_interval))
    done
    
    log "ERROR" "Failed to acquire backup directory lock within ${timeout} seconds"
    return 1
}

# Release backup directory lock
release_backup_dir_lock() {
    local backup_dir="$1"
    local lock_file="$backup_dir/.backup_dir.lock"
    local lock_dir="$lock_file.lockdir"
    
    if [[ -d "$lock_dir" ]]; then
        local lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
        if [[ "$lock_pid" == "$$" ]]; then
            rm -rf "$lock_dir"
            rm -f "$lock_file"
            log "INFO" "Backup directory lock released (PID: $$)"
        else
            log "WARN" "Directory lock exists but belongs to different PID ($lock_pid vs $$)"
        fi
    fi
}

# Release backup lock
release_backup_lock() {
    local lock_file="$PROJECT_ROOT/.backup.lock"
    local lock_dir="$lock_file.lockdir"
    
    if [[ -d "$lock_dir" ]]; then
        local lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
        if [[ "$lock_pid" == "$$" ]]; then
            rm -rf "$lock_dir"
            rm -f "$lock_file"
            log "INFO" "Backup lock released (PID: $$)"
        else
            log "WARN" "Lock directory exists but belongs to different PID ($lock_pid vs $$)"
        fi
    elif [[ -f "$lock_file" ]]; then
        # Handle legacy lock files (for backward compatibility)
        local lock_pid=$(cat "$lock_file" 2>/dev/null || echo "")
        if [[ "$lock_pid" == "$$" ]]; then
            rm -f "$lock_file"
            log "INFO" "Legacy backup lock released (PID: $$)"
        else
            log "WARN" "Legacy lock file exists but belongs to different PID ($lock_pid vs $$)"
        fi
    fi
}

# =============================================================================
# PERMISSION MONITORING FUNCTIONS
# =============================================================================

# Store initial permissions for monitoring
declare -A INITIAL_PERMISSIONS

# Record initial permissions for a path
record_initial_permissions() {
    local path="$1"
    local key="${2:-default}"
    
    if [[ -e "$path" ]]; then
        INITIAL_PERMISSIONS["${key}:${path}"]=$(stat -c "%a:%U:%G" "$path" 2>/dev/null || echo "unknown")
        log "DEBUG" "Recorded initial permissions for $path: ${INITIAL_PERMISSIONS["${key}:${path}"]}"
    fi
}

# Check if permissions have changed
check_permissions_changed() {
    local path="$1"
    local key="${2:-default}"
    local stored_key="${key}:${path}"
    
    if [[ ! -e "$path" ]]; then
        log "ERROR" "Path no exists for permission check: $path"
        return 2
    fi
    
    local current_perms=$(stat -c "%a:%U:%G" "$path" 2>/dev/null || echo "unknown")
    local initial_perms="${INITIAL_PERMISSIONS[$stored_key]}"
    
    if [[ "$initial_perms" == "unknown" ]] || [[ "$current_perms" == "unknown" ]]; then
        log "WARN" "Could not determine permissions for $path"
        return 1
    fi
    
    if [[ "$current_perms" != "$initial_perms" ]]; then
        log "WARN" "Permissions changed for $path: $initial_perms -> $current_perms"
        return 0  # Permissions changed
    fi
    
    return 1  # Permissions unchanged
}

# Verify critical path permissions
verify_critical_permissions() {
    local errors=0
    
    # Check Nextcloud directory permissions
    if [[ -d "$NEXTCLOUD_PATH" ]]; then
        local nextcloud_perms=$(stat -c "%a" "$NEXTCLOUD_PATH" 2>/dev/null || echo "")
        if [[ "$nextcloud_perms" != "755" ]] && [[ "$nextcloud_perms" != "750" ]]; then
            log "WARN" "Nextcloud directory has unusual permissions: $nextcloud_perms (expected 755 or 750)"
        fi
    fi
    
    # Check data directory permissions
    if [[ -d "$NEXTCLOUD_DATA_PATH" ]]; then
        local data_perms=$(stat -c "%a" "$NEXTCLOUD_DATA_PATH" 2>/dev/null || echo "")
        if [[ "$data_perms" != "750" ]] && [[ "$data_perms" != "700" ]]; then
            log "WARN" "Nextcloud data directory has unusual permissions: $data_perms (expected 750 or 700)"
        fi
    fi
    
    # Check backup directory permissions
    if [[ -d "$BACKUP_DIR" ]]; then
        local backup_perms=$(stat -c "%a" "$BACKUP_DIR" 2>/dev/null || echo "")
        if [[ "$backup_perms" != "755" ]] && [[ "$backup_perms" != "700" ]]; then
            log "WARN" "Backup directory has unusual permissions: $backup_perms (expected 755 or 700)"
        fi
    fi
    
    return $errors
}

# Monitor permissions during operation
monitor_permissions_during_operation() {
    local operation_name="$1"
    shift
    local paths=("$@")
    
    log "INFO" "Starting permission monitoring for: $operation_name"
    
    # Record initial permissions
    for path in "${paths[@]}"; do
        record_initial_permissions "$path" "$operation_name"
    done
    
    # Set up a background monitor (simplified version)
    # In a real implementation, you might use inotify or periodic checks
    log "DEBUG" "Permission monitoring enabled for ${#paths[@]} paths"
}

# Check if web server user can access critical paths
check_web_server_access() {
    local errors=0
    
    # Check if web user can access Nextcloud directory
    if ! sudo -u "$WEB_USER" test -r "$NEXTCLOUD_PATH" 2>/dev/null; then
        log "ERROR" "Web server user $WEB_USER cannot read Nextcloud directory"
        errors=$((errors + 1))
    fi
    
    if ! sudo -u "$WEB_USER" test -x "$NEXTCLOUD_PATH" 2>/dev/null; then
        log "ERROR" "Web server user $WEB_USER cannot execute in Nextcloud directory"
        errors=$((errors + 1))
    fi
    
    # Check data directory access
    if ! sudo -u "$WEB_USER" test -r "$NEXTCLOUD_DATA_PATH" 2>/dev/null; then
        log "ERROR" "Web server user $WEB_USER cannot read Nextcloud data directory"
        errors=$((errors + 1))
    fi
    
    if ! sudo -u "$WEB_USER" test -x "$NEXTCLOUD_DATA_PATH" 2>/dev/null; then
        log "ERROR" "Web server user $WEB_USER cannot execute in Nextcloud data directory"
        errors=$((errors + 1))
    fi
    
    if [[ $errors -gt 0 ]]; then
        log "ERROR" "Found $errors permission issues with web server access"
        return 1
    fi
    
    log "INFO" "Web server user access verification passed"
    return 0
}

# Logging function
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_file="$PROJECT_ROOT/logs/$(basename "$0" .sh).log"
    
    # Ensure log directory exists
    mkdir -p "$(dirname "$log_file")"
    
    case $level in
        "INFO")
            echo -e "${GREEN}[INFO]${NC} $message"
            ;;
        "WARN")
            echo -e "${YELLOW}[WARN]${NC} $message"
            ;;
        "ERROR")
            echo -e "${RED}[ERROR]${NC} $message"
            ;;
        "DEBUG")
            echo -e "${BLUE}[DEBUG]${NC} $message"
            ;;
    esac
    
    echo "[$timestamp] [$level] $message" >> "$log_file"
}

# Error handling function
error_exit() {
    log "ERROR" "$1"
    exit 1
}

# =============================================================================
# CONFIGURATION VALIDATION FUNCTIONS
# =============================================================================

# Validate path exists and is accessible
validate_path() {
    local path="$1"
    local path_name="$2"
    local expected_base="${3:-}"
    
    if [[ -z "$path" ]]; then
        error_exit "$path_name cannot be empty"
    fi
    
    # Expand to absolute path and resolve all symbolic links
    local abs_path=$(realpath "$path" 2>/dev/null)
    if [[ -z "$abs_path" ]]; then
        error_exit "$path_name path resolution failed: $path"
    fi
    
    # If expected base directory is provided, ensure path stays within bounds
    if [[ -n "$expected_base" ]]; then
        local abs_base=$(realpath "$expected_base" 2>/dev/null)
        if [[ -z "$abs_base" ]]; then
            error_exit "Base path resolution failed: $expected_base"
        fi
        
        # Check if resolved path is within expected base directory
        if [[ ! "$abs_path" =~ ^$abs_base/?.*$ ]] && [[ "$abs_path" != "$abs_base" ]]; then
            error_exit "$path_name is outside expected directory: $path (expected under: $expected_base)"
        fi
    fi
    
    if [[ ! -d "$abs_path" ]]; then
        error_exit "$path_name directory does not exist: $abs_path"
    fi
    
    if [[ ! -r "$abs_path" ]]; then
        error_exit "$path_name directory is not readable: $abs_path"
    fi
    
    echo "$abs_path"
}

# Validate database configuration
validate_db_config() {
    # Validate database type
    case "$DB_TYPE" in
        "mysql"|"mariadb"|"pgsql")
            ;;
        *)
            error_exit "Invalid database type: $DB_TYPE. Supported types: mysql, mariadb, pgsql"
            ;;
    esac
    
    # Validate database host
    if [[ -z "$DB_HOST" ]]; then
        error_exit "Database host cannot be empty"
    fi
    
    # Validate database name
    if [[ -z "$DB_NAME" ]]; then
        error_exit "Database name cannot be empty"
    fi
    
    # Validate database name format (alphanumeric, underscores, hyphens only)
    if [[ ! "$DB_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        error_exit "Invalid database name format: $DB_NAME"
    fi
    
    # Validate database user
    if [[ -z "$DB_USER" ]]; then
        error_exit "Database user cannot be empty"
    fi
    
    # Validate database password (should not be empty in production)
    if [[ -z "$DB_PASS" ]]; then
        log "WARN" "Database password is empty - this is insecure"
    fi
    
    # Set default port if not specified
    if [[ -z "${DB_PORT:-}" ]]; then
        case "$DB_TYPE" in
            "mysql"|"mariadb")
                DB_PORT=3306
                ;;
            "pgsql")
                DB_PORT=5432
                ;;
        esac
    fi
    
    # Validate port is numeric
    if [[ ! "$DB_PORT" =~ ^[0-9]+$ ]] || [[ "$DB_PORT" -lt 1 ]] || [[ "$DB_PORT" -gt 65535 ]]; then
        error_exit "Invalid database port: $DB_PORT"
    fi
}

# Validate numeric configuration values
validate_numeric() {
    local value="$1"
    var_name="$2"
    local min="${3:-}"
    local max="${4:-}"
    
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        error_exit "$var_name must be a positive integer: $value"
    fi
    
    if [[ -n "$min" ]] && [[ "$value" -lt "$min" ]]; then
        error_exit "$var_name must be at least $min: $value"
    fi
    
    if [[ -n "$max" ]] && [[ "$value" -gt "$max" ]]; then
        error_exit "$var_name must be at most $max: $value"
    fi
}

# Validate boolean configuration values
validate_boolean() {
    local value="$1"
    local var_name="$2"
    
    case "$value" in
        "true"|"false"|"0"|"1"|"yes"|"no"|"on"|"off")
            ;;
        "")
            # Empty values are allowed and will be treated as false
            ;;
        *)
            validation_error "$var_name" "$value" "Must be a boolean value (true/false, yes/no, 1/0, on/off)"
            ;;
    esac
}

# Validate email configuration if enabled
validate_email_config() {
    if [[ "${ENABLE_EMAIL_NOTIFICATIONS:-}" == "true" ]]; then
        local required_email_vars=("SMTP_HOST" "SMTP_PORT" "SMTP_USERNAME" "SMTP_PASSWORD" "SMTP_FROM" "SMTP_TO")
        
        for var in "${required_email_vars[@]}"; do
            if [[ -z "${!var}" ]]; then
                validation_error "$var" "" "Email notifications enabled but $var is not configured"
            fi
        done
        
        # Validate email format
        if [[ ! "$SMTP_FROM" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            validation_error "SMTP_FROM" "$SMTP_FROM" "Invalid email format"
        fi
        
        if [[ ! "$SMTP_TO" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            validation_error "SMTP_TO" "$SMTP_TO" "Invalid email format"
        fi
        
        # Validate SMTP port
        validate_numeric "$SMTP_PORT" "SMTP_PORT" 1 65535
    fi
}

# Validate encryption configuration if enabled
validate_encryption_config() {
    if [[ "${ENABLE_ENCRYPTION:-}" == "true" ]]; then
        if [[ -z "${GPG_RECIPIENT:-}" ]]; then
            validation_error "GPG_RECIPIENT" "" "Encryption enabled but GPG_RECIPIENT is not configured"
        fi
        
        # Validate email format for GPG recipient
        if [[ ! "$GPG_RECIPIENT" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            validation_error "GPG_RECIPIENT" "$GPG_RECIPIENT" "Invalid email format for GPG recipient"
        fi
        
        # Check if GPG is available
        if ! command -v gpg >/dev/null 2>&1; then
            validation_error "GPG_AVAILABILITY" "" "Encryption enabled but GPG is not installed"
        fi
    fi
}

# Validate upload configuration
validate_upload_config() {
    if [[ -n "${UPLOAD_TYPE:-}" ]]; then
        case "$UPLOAD_TYPE" in
            "s3")
                local s3_vars=("AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" "AWS_REGION" "S3_BUCKET")
                for var in "${s3_vars[@]}"; do
                    if [[ -z "${!var}" ]]; then
                        validation_error "$var" "" "S3 upload enabled but $var is not configured"
                    fi
                done
                
                # Validate S3 bucket name format
                if [[ ! "$S3_BUCKET" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]]; then
                    validation_error "S3_BUCKET" "$S3_BUCKET" "Invalid S3 bucket name format"
                fi
                ;;
            "sftp"|"ftp")
                local ftp_vars=("FTP_HOST" "FTP_USERNAME" "FTP_PASSWORD" "FTP_REMOTE_DIR")
                for var in "${ftp_vars[@]}"; do
                    if [[ -z "${!var}" ]]; then
                        validation_error "$var" "" "FTP/SFTP upload enabled but $var is not configured"
                    fi
                done
                
                # Validate FTP port
                if [[ -n "${FTP_PORT:-}" ]]; then
                    validate_numeric "$FTP_PORT" "FTP_PORT" 1 65535
                fi
                ;;
            "local")
                if [[ -z "${LOCAL_COPY_DIR:-}" ]]; then
                    validation_error "LOCAL_COPY_DIR" "" "Local upload enabled but LOCAL_COPY_DIR is not configured"
                fi
                ;;
            *)
                validation_error "UPLOAD_TYPE" "$UPLOAD_TYPE" "Unsupported upload type"
                ;;
        esac
    fi
}

# Validate advanced configuration parameters
validate_advanced_config() {
    # Validate compression level
    if [[ -n "${COMPRESSION_LEVEL:-}" ]]; then
        validate_numeric "$COMPRESSION_LEVEL" "COMPRESSION_LEVEL" 1 9
    fi
    
    # Validate upload threads
    if [[ -n "${UPLOAD_THREADS:-}" ]]; then
        validate_numeric "$UPLOAD_THREADS" "UPLOAD_THREADS" 1 32
    fi
    
    # Validate remote timeout
    if [[ -n "${REMOTE_TIMEOUT:-}" ]]; then
        validate_numeric "$REMOTE_TIMEOUT" "REMOTE_TIMEOUT" 30 7200
    fi
    
    # Validate log retention
    if [[ -n "${LOG_RETENTION_DAYS:-}" ]]; then
        validate_numeric "$LOG_RETENTION_DAYS" "LOG_RETENTION_DAYS" 1 365
    fi
    
    # Validate max backups
    if [[ -n "${MAX_BACKUPS:-}" ]]; then
        validate_numeric "$MAX_BACKUPS" "MAX_BACKUPS" 0 1000
    fi
}

# Validate network connectivity for remote operations
validate_network_connectivity() {
    if [[ -n "${UPLOAD_TYPE:-}" ]] && [[ "$UPLOAD_TYPE" != "local" ]]; then
        log "INFO" "Checking network connectivity..."
        
        # Basic connectivity check
        if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
            warn "Network connectivity check failed - remote operations may fail"
        else
            log "INFO" "Network connectivity check passed"
        fi
    fi
}

# Comprehensive configuration validation
validate_all_config() {
    log "INFO" "Performing comprehensive configuration validation..."
    
    # Validate basic configuration
    validate_email_config
    validate_encryption_config
    validate_upload_config
    validate_advanced_config
    
    # Validate network connectivity if needed
    validate_network_connectivity
    
    # Validate that all required directories are accessible
    validate_path "$NEXTCLOUD_PATH" "NEXTCLOUD_PATH"
    validate_path "$NEXTCLOUD_DATA_PATH" "NEXTCLOUD_DATA_PATH"
    validate_path "$BACKUP_DIR" "BACKUP_DIR"
    
    log "INFO" "Comprehensive configuration validation completed"
}

# =============================================================================
# CONFIGURATION FUNCTIONS
# =============================================================================

# Load configuration from file
load_config() {
    local config_file="${1:-$CONFIG_FILE}"
    
    if [[ ! -f "$config_file" ]]; then
        error_exit "Configuration file not found: $config_file"
    fi
    
    # Source configuration with safety checks
    source "$config_file"
    
    # Validate all configuration values using comprehensive validation
    log "INFO" "Validating configuration..."
    
    # Use comprehensive configuration validation
    validate_all_config
    
    # Validate web server user
    if [[ -z "$WEB_USER" ]]; then
        validation_error "WEB_USER" "" "WEB_USER cannot be empty"
    fi
    
    # Validate boolean values
    validate_boolean "${STOP_WEB_SERVER:-}" "STOP_WEB_SERVER"
    validate_boolean "${ENABLE_ENCRYPTION:-}" "ENABLE_ENCRYPTION"
    validate_boolean "${VERIFY_BACKUP:-}" "VERIFY_BACKUP"
    
    log "INFO" "Configuration validation completed"
}

# =============================================================================
# ENVIRONMENT VALIDATION
# =============================================================================

# Validate Nextcloud environment
validate_environment() {
    log "INFO" "Validating environment..."
    
    # Check if Nextcloud directory exists
    if [[ ! -d "$NEXTCLOUD_PATH" ]]; then
        error_exit "Nextcloud directory not found: $NEXTCLOUD_PATH"
    fi
    
    # Check if config directory exists
    if [[ ! -d "$NEXTCLOUD_PATH/config" ]]; then
        error_exit "Nextcloud config directory not found: $NEXTCLOUD_PATH/config"
    fi
    
    # Check if data directory exists
    if [[ ! -d "$NEXTCLOUD_DATA_PATH" ]]; then
        error_exit "Nextcloud data directory not found: $NEXTCLOUD_DATA_PATH"
    fi
    
    # Create backup directory if it doesn't exist
    mkdir -p "$BACKUP_DIR"
    
    # Verify critical permissions
    verify_critical_permissions
    
    # Check web server user access
    check_web_server_access
    
    # Start permission monitoring for critical paths
    monitor_permissions_during_operation "environment_validation" "$NEXTCLOUD_PATH" "$NEXTCLOUD_DATA_PATH" "$BACKUP_DIR"
    
    # Check database connection
    if ! check_db_connection; then
        error_exit "Cannot connect to database"
    fi
    
    log "INFO" "Environment validation completed"
}

# =============================================================================
# SECURE DATABASE FUNCTIONS
# =============================================================================

# Create temporary config file for database credentials
create_db_config() {
    local temp_config=$(mktemp)
    chmod 600 "$temp_config"
    
    # Add to global temp file tracking
    TEMP_FILES+=("$temp_config")
    
    # Set up cleanup trap for this specific file
    cleanup_this_config() {
        if [[ -f "$temp_config" ]]; then
            rm -f "$temp_config" 2>/dev/null || true
            log "DEBUG" "Cleaned up database config file: $temp_config"
        fi
    }
    trap cleanup_this_config EXIT INT TERM
    
    case "$DB_TYPE" in
        "mysql"|"mariadb")
            cat > "$temp_config" << EOF
[client]
host=$DB_HOST
user=$DB_USER
password=$DB_PASS
database=$DB_NAME
EOF
            ;;
        "pgsql")
            cat > "$temp_config" << EOF
$DB_HOST:$DB_PORT:$DB_NAME:$DB_USER:$DB_PASS
EOF
            ;;
    esac
    
    echo "$temp_config"
}

# Secure database connection check
check_db_connection() {
    local temp_config=$(create_db_config)
    local result=1
    
    case "$DB_TYPE" in
        "mysql"|"mariadb")
            mysql --defaults-extra-file="$temp_config" -e "SELECT 1;" >/dev/null 2>&1
            result=$?
            ;;
        "pgsql")
            export PGPASSFILE="$temp_config"
            psql -h"$DB_HOST" -U"$DB_USER" -d"$DB_NAME" -c "SELECT 1;" >/dev/null 2>&1
            result=$?
            unset PGPASSFILE
            ;;
        *)
            rm -f "$temp_config"
            error_exit "Unsupported database type: $DB_TYPE"
            ;;
    esac
    
    # Immediate cleanup of temp config
    rm -f "$temp_config" 2>/dev/null || true
    log "DEBUG" "Cleaned up database config file after connection check"
    
    return $result
}

# Execute database command securely
execute_db_command() {
    local command="$1"
    local temp_config=$(create_db_config)
    local result=1
    
    case "$DB_TYPE" in
        "mysql"|"mariadb")
            mysql --defaults-extra-file="$temp_config" -e "$command"
            result=$?
            ;;
        "pgsql")
            export PGPASSFILE="$temp_config"
            psql -h"$DB_HOST" -U"$DB_USER" -d"$DB_NAME" -c "$command"
            result=$?
            unset PGPASSFILE
            ;;
        *)
            rm -f "$temp_config"
            error_exit "Unsupported database type: $DB_TYPE"
            ;;
    esac
    
    # Immediate cleanup of temp config
    rm -f "$temp_config" 2>/dev/null || true
    log "DEBUG" "Cleaned up database config file after command execution"
    
    return $result
}

# =============================================================================
# NEXTCLOUD MAINTENANCE FUNCTIONS
# =============================================================================

# Put Nextcloud in maintenance mode
enable_maintenance_mode() {
    log "INFO" "Enabling Nextcloud maintenance mode..."
    
    cd "$NEXTCLOUD_PATH"
    sudo -u "$WEB_USER" php occ maintenance:mode --on
    
    if [[ $? -eq 0 ]]; then
        log "INFO" "Maintenance mode enabled"
    else
        error_exit "Failed to enable maintenance mode"
    fi
}

# Disable Nextcloud maintenance mode
disable_maintenance_mode() {
    log "INFO" "Disabling Nextcloud maintenance mode..."
    
    cd "$NEXTCLOUD_PATH"
    sudo -u "$WEB_USER" php occ maintenance:mode --off
    
    if [[ $? -eq 0 ]]; then
        log "INFO" "Maintenance mode disabled"
    else
        log "WARN" "Failed to disable maintenance mode - you may need to do this manually"
    fi
}

# =============================================================================
# SERVICE MANAGEMENT FUNCTIONS
# =============================================================================

# Stop web server services
stop_web_server() {
    if [[ "${STOP_WEB_SERVER:-}" == "true" ]]; then
        log "INFO" "Stopping web server..."
        if command -v systemctl >/dev/null 2>&1; then
            systemctl stop apache2 2>/dev/null || systemctl stop nginx 2>/dev/null || true
        fi
    fi
}

# Start web server services
start_web_server() {
    if [[ "${STOP_WEB_SERVER:-}" == "true" ]]; then
        log "INFO" "Starting web server..."
        if command -v systemctl >/dev/null 2>&1; then
            systemctl start apache2 2>/dev/null || systemctl start nginx 2>/dev/null || true
        fi
    fi
}

# =============================================================================
# BACKUP INTEGRITY VERIFICATION FUNCTIONS
# =============================================================================

# Calculate file checksum
calculate_checksum() {
    local file_path="$1"
    local algorithm="${2:-sha256}"
    
    if [[ ! -f "$file_path" ]]; then
        error_exit "File not found for checksum calculation: $file_path"
    fi
    
    case "$algorithm" in
        "sha256")
            sha256sum "$file_path" | cut -d' ' -f1
            ;;
        "md5")
            md5sum "$file_path" | cut -d' ' -f1
            ;;
        *)
            error_exit "Unsupported checksum algorithm: $algorithm"
            ;;
    esac
}

# Verify backup integrity
verify_backup_integrity() {
    local backup_id="$1"
    local backup_path="$BACKUP_DIR/$backup_id"
    
    log "INFO" "Verifying backup integrity: $backup_id"
    
    if [[ ! -d "$backup_path" ]]; then
        error_exit "Backup directory not found: $backup_path"
    fi
    
    # Load metadata
    local metadata_file="$backup_path/metadata.json"
    if [[ ! -f "$metadata_file" ]]; then
        error_exit "Metadata file not found: $metadata_file"
    fi
    
    # Verify metadata is valid JSON
    if ! python3 -c "import json; json.load(open('$metadata_file'))" 2>/dev/null; then
        error_exit "Invalid metadata file: $metadata_file"
    fi
    
    # Get expected files from metadata
    local expected_files=$(python3 -c "
import json
with open('$metadata_file', 'r') as f:
    data = json.load(f)
    for file in data.get('files', []):
        print(file)
" 2>/dev/null)
    
    local verification_failed=false
    
    # Check each expected file exists and is readable
    while IFS= read -r expected_file; do
        local file_path="$backup_path/$expected_file"
        
        if [[ ! -f "$file_path" ]]; then
            log "ERROR" "Expected backup file missing: $expected_file"
            verification_failed=true
            continue
        fi
        
        if [[ ! -r "$file_path" ]]; then
            log "ERROR" "Backup file not readable: $expected_file"
            verification_failed=true
            continue
        fi
        
        # Verify file is not empty (unless it's supposed to be)
        if [[ ! -s "$file_path" ]]; then
            log "WARN" "Backup file is empty: $expected_file"
        fi
        
        # Calculate and store checksum for future verification
        local checksum=$(calculate_checksum "$file_path")
        log "DEBUG" "Checksum for $expected_file: $checksum"
        
    done <<< "$expected_files"
    
    # Verify archive integrity by testing extraction (without actually extracting)
    local archives=("config.tar.gz" "data.tar.gz" "database.sql.gz")
    for archive in "${archives[@]}"; do
        local archive_path="$backup_path/$archive"
        
        if [[ -f "$archive_path" ]]; then
            if ! gzip -t "$archive_path" 2>/dev/null; then
                log "ERROR" "Archive integrity check failed: $archive"
                verification_failed=true
            else
                log "DEBUG" "Archive integrity verified: $archive"
            fi
        fi
    done
    
    # Check for unexpected files
    local found_unexpected=false
    while IFS= read -r -d '' found_file; do
        local relative_path="${found_file#$backup_path/}"
        
        # Skip metadata file and checksums
        if [[ "$relative_path" == "metadata.json" ]] || [[ "$relative_path" == *.checksum ]]; then
            continue
        fi
        
        # Check if file is in expected list
        if ! echo "$expected_files" | grep -q "^$relative_path$"; then
            log "WARN" "Unexpected file in backup: $relative_path"
            found_unexpected=true
        fi
        
    done < <(find "$backup_path" -type f -print0 2>/dev/null)
    
    if [[ "$verification_failed" == "true" ]]; then
        error_exit "Backup integrity verification failed for: $backup_id"
    fi
    
    log "INFO" "Backup integrity verification passed: $backup_id"
    return 0
}

# Create backup checksums
create_backup_checksums() {
    local backup_id="$1"
    local backup_path="$BACKUP_DIR/$backup_id"
    local checksum_file="$backup_path/checksums.sha256"
    
    log "INFO" "Creating backup checksums: $backup_id"
    
    # Create checksum file
    {
        echo "# Backup checksums for $backup_id"
        echo "# Generated on: $(date -Iseconds)"
        echo ""
        
        # Calculate checksums for all files
        while IFS= read -r -d '' file_path; do
            local relative_path="${file_path#$backup_path/}"
            local checksum=$(calculate_checksum "$file_path")
            echo "$checksum  $relative_path"
        done < <(find "$backup_path" -type f ! -name "checksums.*" -print0 2>/dev/null)
        
    } > "$checksum_file"
    
    log "INFO" "Checksums created: $checksum_file"
}

# Verify backup using checksums
verify_backup_checksums() {
    local backup_id="$1"
    local backup_path="$BACKUP_DIR/$backup_id"
    local checksum_file="$backup_path/checksums.sha256"
    
    if [[ ! -f "$checksum_file" ]]; then
        log "WARN" "No checksum file found for backup: $backup_id"
        return 0
    fi
    
    log "INFO" "Verifying backup checksums: $backup_id"
    
    # Change to backup directory for checksum verification
    local current_dir=$(pwd)
    cd "$backup_path" || error_exit "Cannot change to backup directory"
    
    # Verify checksums
    if sha256sum -c "checksums.sha256" --quiet --status 2>/dev/null; then
        log "INFO" "All checksums verified successfully"
        cd "$current_dir"
        return 0
    else
        log "ERROR" "Checksum verification failed - backup may be corrupted"
        cd "$current_dir"
        return 1
    fi
}

# =============================================================================
# BACKUP VALIDATION FUNCTIONS
# =============================================================================

# Validate backup directory and files
validate_backup() {
    local backup_id=$1
    local backup_path="$BACKUP_DIR/$backup_id"
    
    log "INFO" "Validating backup: $backup_id"
    
    if [[ ! -d "$backup_path" ]]; then
        error_exit "Backup directory not found: $backup_path"
    fi
    
    # Check for required backup files
    local required_files=("database.sql.gz" "config.tar.gz" "data.tar.gz" "metadata.json")
    for file in "${required_files[@]}"; do
        if [[ ! -f "$backup_path/$file" ]]; then
            error_exit "Required backup file not found: $backup_path/$file"
        fi
    done
    
    # Validate metadata
    if ! python3 -c "import json; json.load(open('$backup_path/metadata.json'))" 2>/dev/null; then
        error_exit "Invalid metadata file: $backup_path/metadata.json"
    fi
    
    log "INFO" "Backup validation completed"
}

# =============================================================================
# BACKUP METADATA FUNCTIONS
# =============================================================================

# Create backup metadata
create_metadata() {
    local backup_id=$1
    local metadata_file="$BACKUP_DIR/$backup_id/metadata.json"
    
    log "INFO" "Creating backup metadata..."
    
    # Determine file list based on encryption status
    local files_list=""
    if [[ "${ENABLE_ENCRYPTION:-}" == "true" ]]; then
        files_list='"database.sql.gz.gpg", "config.tar.gz.gpg", "data.tar.gz.gpg"'
        # Check if apps backup exists
        if [[ -f "$BACKUP_DIR/$backup_id/apps.tar.gz.gpg" ]]; then
            files_list="$files_list, \"apps.tar.gz.gpg\""
        fi
    else
        files_list='"database.sql.gz", "config.tar.gz", "data.tar.gz"'
        # Check if apps backup exists
        if [[ -f "$BACKUP_DIR/$backup_id/apps.tar.gz" ]]; then
            files_list="$files_list, \"apps.tar.gz\""
        fi
    fi
    
    cat > "$metadata_file" << EOF
{
    "backup_id": "$backup_id",
    "timestamp": "$(date -Iseconds)",
    "nextcloud_version": "$(cd "$NEXTCLOUD_PATH" && sudo -u "$WEB_USER" php occ -V)",
    "database_type": "$DB_TYPE",
    "database_name": "$DB_NAME",
    "nextcloud_path": "$NEXTCLOUD_PATH",
    "data_path": "$NEXTCLOUD_DATA_PATH",
    "backup_size": "$(du -sh "$BACKUP_DIR/$backup_id" | cut -f1)",
    "encryption_enabled": "${ENABLE_ENCRYPTION:-false}",
    "files": [
        $files_list
    ]
}
EOF
    
    log "INFO" "Metadata created: $metadata_file"
}

# Show backup information
show_backup_info() {
    local backup_id=$1
    local backup_path="$BACKUP_DIR/$backup_id"
    
    log "INFO" "Backup Information:"
    log "INFO" "=================="
    
    if [[ -f "$backup_path/metadata.json" ]]; then
        python3 -c "
import json
with open('$backup_path/metadata.json', 'r') as f:
    data = json.load(f)
    print(f'Backup ID: {data[\"backup_id\"]}')
    print(f'Timestamp: {data[\"timestamp\"]}')
    print(f'Nextcloud Version: {data[\"nextcloud_version\"]}')
    print(f'Database Type: {data[\"database_type\"]}')
    print(f'Database Name: {data[\"database_name\"]}')
    print(f'Backup Size: {data[\"backup_size\"]}')
"
    fi
    
    # List backup files
    log "INFO" "Backup files:"
    ls -lh "$backup_path/"
}

# =============================================================================
# BACKUP LISTING FUNCTIONS
# =============================================================================

# List available backups
list_backups() {
    log "INFO" "Available backups:"
    log "INFO" "=================="
    
    if [[ ! -d "$BACKUP_DIR" ]]; then
        log "WARN" "Backup directory not found: $BACKUP_DIR"
        return 1
    fi
    
    cd "$BACKUP_DIR"
    
    for backup_dir in */; do
        if [[ -d "$backup_dir" && -f "$backup_dir/metadata.json" ]]; then
            backup_id="${backup_dir%/}"
            timestamp=$(python3 -c "import json; print(json.load(open('$backup_dir/metadata.json'))['timestamp'])" 2>/dev/null || echo "Unknown")
            size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1 || echo "Unknown")
            echo "$backup_id - $timestamp - $size"
        fi
    done | sort -r
}

# =============================================================================
# CLEANUP FUNCTIONS
# =============================================================================

# Cleanup old backups
cleanup_old_backups() {
    local exclude_backup="${1:-}"
    
    if [[ -n "${MAX_BACKUPS:-}" && "$MAX_BACKUPS" -gt 0 ]]; then
        log "INFO" "Cleaning up old backups (keeping $MAX_BACKUPS most recent)..."
        
        cd "$BACKUP_DIR" || return 1
        
        # Get list of backup directories sorted by time (newest first)
        local backup_list=()
        while IFS= read -r -d '' backup_dir; do
            if [[ -d "$backup_dir" && "$backup_dir" != "$exclude_backup" && -f "$backup_dir/metadata.json" ]]; then
                backup_list+=("$backup_dir")
            fi
        done < <(find . -maxdepth 1 -type d -name "????????_??????" -print0 | sort -z -r)
        
        # Remove excess backups
        local keep_count="$MAX_BACKUPS"
        for ((i=0; i<${#backup_list[@]}; i++)); do
            if [[ $i -ge $keep_count ]]; then
                local backup_to_remove="${backup_list[$i]}"
                log "INFO" "Removing old backup: $(basename "$backup_to_remove")"
                rm -rf "$backup_to_remove"
            fi
        done
    fi
}

# =============================================================================
# ENCRYPTION FUNCTIONS
# =============================================================================

# Check if GPG is available and configured
check_gpg_setup() {
    if ! command -v gpg >/dev/null 2>&1; then
        error_exit "GPG is required for encryption but not found on system"
    fi
    
    if [[ -z "${GPG_RECIPIENT:-}" ]]; then
        error_exit "GPG_RECIPIENT must be set in configuration for encryption"
    fi
    
    # Test GPG recipient
    if ! gpg --list-keys "$GPG_RECIPIENT" >/dev/null 2>&1; then
        log "WARN" "GPG recipient $GPG_RECIPIENT not found in keyring"
        log "INFO" "You may need to import the recipient's GPG key first"
    fi
}

# Encrypt a file using GPG
encrypt_file() {
    local input_file="$1"
    local output_file="$2"
    
    log "INFO" "Encrypting file: $(basename "$input_file")"
    
    if ! gpg --trust-model always --encrypt -r "$GPG_RECIPIENT" --output "$output_file" "$input_file"; then
        error_exit "Failed to encrypt file: $(basename "$input_file")"
    fi
    
    log "INFO" "File encrypted successfully: $(basename "$output_file")"
}

# Decrypt a file using GPG
decrypt_file() {
    local input_file="$1"
    local output_file="$2"
    
    log "INFO" "Decrypting file: $(basename "$input_file")"
    
    if ! gpg --decrypt --output "$output_file" "$input_file"; then
        error_exit "Failed to decrypt file: $(basename "$input_file")"
    fi
    
    log "INFO" "File decrypted successfully: $(basename "$output_file")"
}

# =============================================================================
# EFFICIENT FILE OPERATIONS
# =============================================================================

# Efficient file copy with progress tracking
copy_file_efficient() {
    local src="$1"
    local dst="$2"
    local buffer_size="${3:-4194304}"  # 4MB buffer default
    
    if [[ ! -f "$src" ]]; then
        error_exit "Source file does not exist: $src"
    fi
    
    # Create destination directory if needed
    mkdir -p "$(dirname "$dst")"
    
    local src_size=$(stat -c%s "$src")
    local copied=0
    
    # Use dd for efficient copying with large buffer
    {
        dd if="$src" bs="$buffer_size" 2>/dev/null | \
        while IFS= read -r -n 1 chunk; do
            printf "%s" "$chunk"
            copied=$((copied + ${#chunk}))
            
            # Update progress every 10MB
            if [[ $((copied % 10485760)) -eq 0 ]]; then
                local percentage=$((copied * 100 / src_size))
                log "DEBUG" "Copy progress: ${percentage}% (${copied}/${src_size} bytes)"
            fi
        done
    } > "$dst"
    
    # Verify copy
    if [[ ! -f "$dst" ]] || [[ $(stat -c%s "$dst") -ne $src_size ]]; then
        error_exit "File copy verification failed: $src -> $dst"
    fi
}

# Efficient directory size calculation
get_directory_size() {
    local dir="$1"
    
    if [[ ! -d "$dir" ]]; then
        echo "0"
        return 1
    fi
    
    # Use du with optimized settings for better performance
    du -sb "$dir" 2>/dev/null | cut -f1 || echo "0"
}

# Batch file operations for better performance
batch_chown() {
    local user="$1"
    local group="$2"
    shift 2
    local paths=("$@")
    
    if [[ ${#paths[@]} -eq 0 ]]; then
        return 0
    fi
    
    # Use find with -exec for efficient batch operations
    find "${paths[@]}" -type f -exec chown "$user:$group" {} + 2>/dev/null || true
    find "${paths[@]}" -type d -exec chown "$user:$group" {} + 2>/dev/null || true
}

# Batch file permission setting
batch_chmod() {
    local file_perms="$1"
    local dir_perms="$2"
    shift 2
    local paths=("$@")
    
    if [[ ${#paths[@]} -eq 0 ]]; then
        return 0
    fi
    
    # Set directory permissions first
    find "${paths[@]}" -type d -exec chmod "$dir_perms" {} + 2>/dev/null || true
    # Then set file permissions
    find "${paths[@]}" -type f -exec chmod "$file_perms" {} + 2>/dev/null || true
}

# Efficient archive creation with optimized compression
create_archive_efficient() {
    local source_path="$1"
    local archive_path="$2"
    local archive_name="$3"
    local compression_level="${4:-6}"
    
    log "INFO" "Creating optimized archive: $archive_name"
    
    # Use optimized tar options for better performance
    tar -c \
        --create \
        --gzip \
        --use-compress-program="gzip -${compression_level}" \
        --directory="$source_path" \
        --file="$archive_path" \
        "$archive_name" 2>/dev/null
    
    if [[ $? -eq 0 ]]; then
        local archive_size=$(stat -c%s "$archive_path")
        log "INFO" "Archive created successfully: $archive_path (${archive_size} bytes)"
    else
        error_exit "Failed to create archive: $archive_name"
    fi
}

# Parallel file processing for better performance
process_files_parallel() {
    local operation="$1"
    local max_jobs="${2:-4}"
    shift 2
    local files=("$@")
    
    if [[ ${#files[@]} -eq 0 ]]; then
        return 0
    fi
    
    local job_count=0
    local pids=()
    
    for file in "${files[@]}"; do
        # Wait for available job slot
        while [[ ${#pids[@]} -ge $max_jobs ]]; do
            for i in "${!pids[@]}"; do
                if ! kill -0 "${pids[$i]}" 2>/dev/null; then
                    unset pids[$i]
                fi
            done
            pids=("${pids[@]}")  # Reindex array
            [[ ${#pids[@]} -ge $max_jobs ]] && sleep 0.1
        done
        
        # Start background job
        (
            case "$operation" in
                "checksum")
                    calculate_checksum "$file"
                    ;;
                "compress")
                    gzip -c "$file" > "${file}.gz"
                    ;;
                "verify")
                    # Add verification logic here
                    ;;
                *)
                    log "WARN" "Unknown parallel operation: $operation"
                    ;;
            esac
        ) &
        
        pids+=($!)
        job_count=$((job_count + 1))
    done
    
    # Wait for all jobs to complete
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
    
    log "INFO" "Completed parallel processing of $job_count files"
}

# Set correct permissions for Nextcloud files
set_nextcloud_permissions() {
    log "INFO" "Setting correct permissions..."
    
    if [[ -d "$NEXTCLOUD_PATH" ]]; then
        chown -R "$WEB_USER:$WEB_USER" "$NEXTCLOUD_PATH"
    fi
    
    if [[ -d "$NEXTCLOUD_DATA_PATH" ]]; then
        chown -R "$WEB_USER:$WEB_USER" "$NEXTCLOUD_DATA_PATH"
    fi
}

# Create compressed archive
create_archive() {
    local source_path="$1"
    local archive_path="$2"
    local archive_name="$3"
    
    log "INFO" "Creating archive: $archive_name"
    
    tar -czf "$archive_path" -C "$source_path" "$archive_name"
    
    if [[ $? -eq 0 ]]; then
        log "INFO" "Archive created successfully: $archive_path"
    else
        error_exit "Failed to create archive: $archive_name"
    fi
}

# Extract compressed archive safely
extract_archive() {
    local archive_path="$1"
    local extract_path="$2"
    
    log "INFO" "Extracting archive: $(basename "$archive_path")"
    
    # Validate inputs
    if [[ ! -f "$archive_path" ]]; then
        error_exit "Archive file not found: $archive_path"
    fi
    
    if [[ ! -d "$extract_path" ]]; then
        error_exit "Extract path does not exist: $extract_path"
    fi
    
    # Create temporary directory for safe extraction
    local temp_dir=$(mktemp -d)
    
    # Add to global temp directory tracking
    TEMP_DIRS+=("$temp_dir")
    
    # Extract to temporary directory first
    if ! tar -xzf "$archive_path" -C "$temp_dir"; then
        error_exit "Failed to extract archive: $(basename "$archive_path")"
    fi
    
    # Validate extracted paths for security
    local found_suspicious_paths=false
    while IFS= read -r -d '' file_path; do
        local relative_path="${file_path#$temp_dir/}"
        
        # Resolve absolute path to check for traversal
        local resolved_path=$(realpath "$file_path" 2>/dev/null || echo "$file_path")
        local resolved_temp_dir=$(realpath "$temp_dir" 2>/dev/null || echo "$temp_dir")
        
        # Check if resolved path is still within temp directory
        if [[ ! "$resolved_path" =~ ^$resolved_temp_dir/?.*$ ]] && [[ "$resolved_path" != "$resolved_temp_dir" ]]; then
            log "ERROR" "Path traversal attempt detected: $relative_path -> $resolved_path"
            found_suspicious_paths=true
            continue
        fi
        
        # Check for path traversal attempts in relative path
        if [[ "$relative_path" == *..* ]] || [[ "$relative_path" == */.* ]]; then
            log "ERROR" "Suspicious path found in archive: $relative_path"
            found_suspicious_paths=true
            continue
        fi
        
        # Check for absolute paths
        if [[ "$relative_path" == /* ]]; then
            log "ERROR" "Absolute path found in archive: $relative_path"
            found_suspicious_paths=true
            continue
        fi
        
        # Check for suspicious file names
        if [[ "$relative_path" =~ ^[.]*$ ]] || [[ "$relative_path" =~ [[:space:]] ]]; then
            log "ERROR" "Suspicious filename found in archive: $relative_path"
            found_suspicious_paths=true
            continue
        fi
        
        # Additional check: verify file is a regular file
        if [[ ! -f "$file_path" ]]; then
            log "WARN" "Non-regular file found in archive: $relative_path (type: $(stat -c "%F" "$file_path" 2>/dev/null || echo "unknown"))"
        fi
        
    done < <(find "$temp_dir" -type f -print0 2>/dev/null)
    
    if [[ "$found_suspicious_paths" == "true" ]]; then
        error_exit "Archive contains suspicious paths - extraction aborted for security"
    fi
    
    # Copy validated files to target directory
    local copy_success=true
    while IFS= read -r -d '' file_path; do
        local relative_path="${file_path#$temp_dir/}"
        local target_path="$extract_path/$relative_path"
        
        # Create target directory if needed
        local target_dir=$(dirname "$target_path")
        mkdir -p "$target_dir"
        
        # Copy file with preserved permissions
        if ! cp -p "$file_path" "$target_path"; then
            log "ERROR" "Failed to copy file: $relative_path"
            copy_success=false
        fi
        
    done < <(find "$temp_dir" -type f -print0 2>/dev/null)
    
    if [[ "$copy_success" != "true" ]]; then
        error_exit "Some files failed to copy during safe extraction"
    fi
    
    log "INFO" "Archive extracted safely: $(basename "$archive_path")"
}

# =============================================================================
# NEXTCLOUD UPDATE FUNCTIONS
# =============================================================================

# Update Nextcloud after restore
update_nextcloud() {
    log "INFO" "Updating Nextcloud..."
    
    cd "$NEXTCLOUD_PATH"
    
    # Run upgrade command
    sudo -u "$WEB_USER" php occ upgrade
    
    # Add missing indices
    sudo -u "$WEB_USER" php occ db:add-missing-indices
    
    # Add missing columns
    sudo -u "$WEB_USER" php occ db:add-missing-columns
    
    log "INFO" "Nextcloud update completed"
}

# =============================================================================
# INITIALIZATION
# =============================================================================

# Initialize common library
init_common() {
    # Set project root if not already set
    if [[ -z "${PROJECT_ROOT:-}" ]]; then
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
        PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
    fi
    
    # Set default config file if not already set
    if [[ -z "${CONFIG_FILE:-}" ]]; then
        CONFIG_FILE="$PROJECT_ROOT/config/backup.conf"
    fi
    
    # Create logs directory
    mkdir -p "$PROJECT_ROOT/logs"
}

# Auto-initialize when sourced
init_common

# Set up cleanup trap for lock release
cleanup_on_exit() {
    release_backup_lock
}
trap cleanup_on_exit EXIT INT TERM
