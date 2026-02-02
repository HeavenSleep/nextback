#!/bin/bash

# Nextcloud Backup Script
# Creates comprehensive backups of Nextcloud installation

set -euo pipefail

# Get script directory and load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBS_DIR="$SCRIPT_DIR/libs"

# Source common functions
if [[ -f "$LIBS_DIR/common.sh" ]]; then
    source "$LIBS_DIR/common.sh"
else
    echo "ERROR: Common functions library not found: $LIBS_DIR/common.sh"
    exit 1
fi

# Backup database
backup_database() {
    local backup_id=$1
    local temp_backup_path="$BACKUP_DIR/.tmp_$backup_id"
    local db_backup_file="$temp_backup_path/database.sql"
    
    log "INFO" "Backing up database..."
    
    mkdir -p "$(dirname "$db_backup_file")"
    
    # Create temporary config file for secure database connection
    local temp_config=$(create_db_config)
    
    case "$DB_TYPE" in
        "mysql"|"mariadb")
            mysqldump --defaults-extra-file="$temp_config" \
                --single-transaction \
                --routines \
                --triggers \
                "$DB_NAME" > "$db_backup_file"
            ;;
        "pgsql")
            export PGPASSFILE="$temp_config"
            pg_dump -h"$DB_HOST" -U"$DB_USER" \
                --clean \
                --if-exists \
                --create \
                "$DB_NAME" > "$db_backup_file"
            unset PGPASSFILE
            ;;
    esac
    
    # Clean up temporary config file
    rm -f "$temp_config"
    
    if [[ $? -eq 0 ]]; then
        log "INFO" "Database backup completed: $db_backup_file"
        # Compress the database backup
        gzip "$db_backup_file"
        log "INFO" "Database backup compressed: ${db_backup_file}.gz"
    else
        error_exit "Database backup failed"
    fi
}

# Backup Nextcloud files
backup_files() {
    local backup_id=$1
    local temp_backup_path="$BACKUP_DIR/.tmp_$backup_id"
    
    log "INFO" "Backing up Nextcloud files..."
    
    # Backup config directory
    local config_backup="$temp_backup_path/config.tar.gz"
    create_archive "$NEXTCLOUD_PATH" "$config_backup" "config"
    
    # Backup data directory
    local data_backup="$temp_backup_path/data.tar.gz"
    create_archive "$(dirname "$NEXTCLOUD_DATA_PATH")" "$data_backup" "$(basename "$NEXTCLOUD_DATA_PATH")"
    
    # Backup apps directory if it exists
    if [[ -d "$NEXTCLOUD_PATH/apps" ]]; then
        local apps_backup="$temp_backup_path/apps.tar.gz"
        create_archive "$NEXTCLOUD_PATH" "$apps_backup" "apps"
        log "INFO" "Apps backup completed: $apps_backup"
    fi
    
    # Encrypt backup files if enabled
    if [[ "${ENABLE_ENCRYPTION:-}" == "true" ]]; then
        log "INFO" "Encrypting backup files..."
        check_gpg_setup
        
        # Encrypt database backup
        if [[ -f "$temp_backup_path/database.sql.gz" ]]; then
            if encrypt_file "$temp_backup_path/database.sql.gz" "$temp_backup_path/database.sql.gz.gpg"; then
                rm -f "$temp_backup_path/database.sql.gz"
                log "INFO" "Database backup encrypted and original removed"
            else
                error_exit "Failed to encrypt database backup"
            fi
        fi
        
        # Encrypt config backup
        if encrypt_file "$config_backup" "$config_backup.gpg"; then
            rm -f "$config_backup"
            log "INFO" "Config backup encrypted and original removed"
        else
            error_exit "Failed to encrypt config backup"
        fi
        
        # Encrypt data backup
        if encrypt_file "$data_backup" "$data_backup.gpg"; then
            rm -f "$data_backup"
            log "INFO" "Data backup encrypted and original removed"
        else
            error_exit "Failed to encrypt data backup"
        fi
        
        # Encrypt apps backup if it exists
        if [[ -f "$apps_backup" ]]; then
            if encrypt_file "$apps_backup" "$apps_backup.gpg"; then
                rm -f "$apps_backup"
                log "INFO" "Apps backup encrypted and original removed"
            else
                error_exit "Failed to encrypt apps backup"
            fi
        fi
        
        log "INFO" "All backup files encrypted successfully"
    fi
}

# Main backup function
create_backup() {
    local backup_id=$(date '+%Y%m%d_%H%M%S')
    local backup_path="$BACKUP_DIR/$backup_id"
    local temp_backup_path="$BACKUP_DIR/.tmp_$backup_id"
    
    log "INFO" "Starting Nextcloud backup with ID: $backup_id"
    
    # Create temporary backup directory
    mkdir -p "$temp_backup_path"
    
    # Comprehensive cleanup function
    cleanup_on_backup_exit() {
        local exit_code=$?
        log "INFO" "Running cleanup on exit (code: $exit_code)"
        
        # Always try to disable maintenance mode
        disable_maintenance_mode
        
        # Always try to release backup lock
        release_backup_lock
        
        # Clean up temporary directory if it exists
        if [[ -d "$temp_backup_path" ]]; then
            log "INFO" "Cleaning up temporary backup directory: $temp_backup_path"
            rm -rf "$temp_backup_path"
        fi
        
        exit $exit_code
    }
    
    # Set trap for cleanup on exit, interrupt, or termination
    trap cleanup_on_backup_exit EXIT INT TERM
    
    # Enable maintenance mode
    enable_maintenance_mode
    
    # Backup database
    backup_database "$backup_id"
    
    # Backup files
    backup_files "$backup_id"
    
    # Create metadata
    create_metadata "$backup_id"
    
    # Create checksums for integrity verification
    create_backup_checksums "$backup_id"
    
    # Verify backup integrity if enabled
    if [[ "${VERIFY_BACKUP:-}" == "true" ]]; then
        if ! verify_backup_integrity "$backup_id"; then
            error_exit "Backup integrity verification failed"
        fi
    fi
    
    # Atomic move from temporary to final location
    if ! mv "$temp_backup_path" "$backup_path"; then
        error_exit "Failed to move backup to final location"
    fi
    
    log "INFO" "Backup atomically moved to final location: $backup_path"
    
    # Cleanup old backups
    cleanup_old_backups "$backup_id"
    
    # Calculate total backup size
    local total_size=$(du -sh "$backup_path" | cut -f1)
    
    log "INFO" "Backup completed successfully!"
    log "INFO" "Backup ID: $backup_id"
    log "INFO" "Backup location: $backup_path"
    log "INFO" "Total size: $total_size"
    
    # Create a symlink to the latest backup
    # Use ln -sf consistently to handle both creation and update
    ln -sf "$backup_path" "$BACKUP_DIR/latest"
    
    echo "$backup_id"
}

# Main execution
main() {
    log "INFO" "Starting Nextcloud backup process..."
    
    # Load configuration
    load_config
    
    # Validate environment
    validate_environment
    
    # Acquire backup lock
    if ! acquire_backup_lock; then
        log "ERROR" "Could not acquire backup lock - another backup may be running"
        exit 1
    fi
    
    # Ensure lock is released on exit
    trap 'release_backup_lock; exit $?' EXIT INT TERM
    
    # Create backup
    local backup_id=$(create_backup)
    
    log "INFO" "Backup process completed successfully"
    exit 0
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
