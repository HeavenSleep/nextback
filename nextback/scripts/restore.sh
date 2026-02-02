#!/bin/bash

# Nextcloud Restore Script
# Restores Nextcloud from existing backups

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

# Create current backup before restore (safety measure)
create_safety_backup() {
    log "INFO" "Creating safety backup before restore..."
    
    local safety_backup_id="safety_$(date '+%Y%m%d_%H%M%S')"
    local safety_backup_path="$BACKUP_DIR/$safety_backup_id"
    
    mkdir -p "$safety_backup_path"
    
    # Create temporary config file for secure database connection
    local temp_config=$(create_db_config)
    
    # Backup current database
    case "$DB_TYPE" in
        "mysql"|"mariadb")
            mysqldump --defaults-extra-file="$temp_config" \
                --single-transaction \
                "$DB_NAME" | gzip > "$safety_backup_path/database.sql.gz"
            ;;
        "pgsql")
            export PGPASSFILE="$temp_config"
            pg_dump -h"$DB_HOST" -U"$DB_USER" \
                "$DB_NAME" | gzip > "$safety_backup_path/database.sql.gz"
            unset PGPASSFILE
            ;;
    esac
    
    # Clean up temporary config file
    rm -f "$temp_config"
    
    # Backup current config and data
    if [[ -d "$NEXTCLOUD_PATH/config" ]]; then
        tar -czf "$safety_backup_path/config.tar.gz" -C "$NEXTCLOUD_PATH" config/
    fi
    
    if [[ -d "$NEXTCLOUD_DATA_PATH" ]]; then
        tar -czf "$safety_backup_path/data.tar.gz" -C "$(dirname "$NEXTCLOUD_DATA_PATH")" "$(basename "$NEXTCLOUD_DATA_PATH")"
    fi
    
    log "INFO" "Safety backup created: $safety_backup_id"
    echo "$safety_backup_id"
}

# Stop Nextcloud services
stop_services() {
    log "INFO" "Stopping Nextcloud services..."
    
    # Enable maintenance mode
    cd "$NEXTCLOUD_PATH"
    sudo -u "$WEB_USER" php occ maintenance:mode --on
    
    # Stop web server (optional, can be configured)
    if [[ "${STOP_WEB_SERVER:-}" == "true" ]]; then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl stop apache2 2>/dev/null || systemctl stop nginx 2>/dev/null || true
        fi
    fi
    
    log "INFO" "Services stopped"
}

# Start Nextcloud services
start_services() {
    log "INFO" "Starting Nextcloud services..."
    
    # Start web server if it was stopped
    if [[ "${STOP_WEB_SERVER:-}" == "true" ]]; then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl start apache2 2>/dev/null || systemctl start nginx 2>/dev/null || true
        fi
    fi
    
    # Disable maintenance mode
    cd "$NEXTCLOUD_PATH"
    sudo -u "$WEB_USER" php occ maintenance:mode --off
    
    log "INFO" "Services started"
}

# Restore database
restore_database() {
    local backup_id=$1
    local backup_path="$BACKUP_DIR/$backup_id"
    local db_backup="$backup_path/database.sql.gz"
    local temp_sql="/tmp/restore_db_$(date +%s).sql"
    
    log "INFO" "Restoring database..."
    
    # Cleanup function for temporary files
    cleanup_temp_files() {
        if [[ -f "$temp_sql" ]]; then
            rm -f "$temp_sql"
            log "INFO" "Cleaned up temporary file: $temp_sql"
        fi
    }
    
    # Set trap for cleanup on exit, interrupt, or termination
    trap cleanup_temp_files EXIT INT TERM
    
    # Extract database backup
    if ! gunzip -c "$db_backup" > "$temp_sql"; then
        log "ERROR" "Failed to extract database backup"
        return 1
    fi
    
    # Create temporary config file for secure database connection
    local temp_config=$(create_db_config)
    
    case "$DB_TYPE" in
        "mysql"|"mariadb")
            # Drop and recreate database
            mysql --defaults-extra-file="$temp_config" -e "DROP DATABASE IF EXISTS $DB_NAME;"
            mysql --defaults-extra-file="$temp_config" -e "CREATE DATABASE $DB_NAME;"
            
            # Restore database
            mysql --defaults-extra-file="$temp_config" "$DB_NAME" < "$temp_sql"
            ;;
        "pgsql")
            export PGPASSFILE="$temp_config"
            # Drop and recreate database
            psql -h"$DB_HOST" -U"$DB_USER" -c "DROP DATABASE IF EXISTS $DB_NAME;"
            psql -h"$DB_HOST" -U"$DB_USER" -c "CREATE DATABASE $DB_NAME;"
            
            # Restore database
            psql -h"$DB_HOST" -U"$DB_USER" -d"$DB_NAME" < "$temp_sql"
            unset PGPASSFILE
            ;;
    esac
    
    # Clean up temporary config file
    rm -f "$temp_config"
    
    log "INFO" "Database restoration completed"
}

# Restore Nextcloud files
restore_files() {
    local backup_id=$1
    local backup_path="$BACKUP_DIR/$backup_id"
    
    log "INFO" "Restoring Nextcloud files..."
    
    # Backup current files (if they exist)
    if [[ -d "$NEXTCLOUD_PATH/config" ]]; then
        mv "$NEXTCLOUD_PATH/config" "$NEXTCLOUD_PATH/config.bak.$(date +%s)"
    fi
    
    if [[ -d "$NEXTCLOUD_DATA_PATH" ]]; then
        mv "$NEXTCLOUD_DATA_PATH" "$NEXTCLOUD_DATA_PATH.bak.$(date +%s)"
    fi
    
    # Restore config
    if [[ -f "$backup_path/config.tar.gz" ]]; then
        extract_archive "$backup_path/config.tar.gz" "$NEXTCLOUD_PATH"
        log "INFO" "Config files restored"
    fi
    
    # Restore data
    if [[ -f "$backup_path/data.tar.gz" ]]; then
        extract_archive "$backup_path/data.tar.gz" "$(dirname "$NEXTCLOUD_DATA_PATH")"
        log "INFO" "Data files restored"
    fi
    
    # Restore apps if exists
    if [[ -f "$backup_path/apps.tar.gz" && -d "$NEXTCLOUD_PATH" ]]; then
        if [[ -d "$NEXTCLOUD_PATH/apps" ]]; then
            mv "$NEXTCLOUD_PATH/apps" "$NEXTCLOUD_PATH/apps.bak.$(date +%s)"
        fi
        extract_archive "$backup_path/apps.tar.gz" "$NEXTCLOUD_PATH"
        log "INFO" "Apps directory restored"
    fi
    
    # Set correct permissions
    set_nextcloud_permissions
    
    log "INFO" "File restoration completed"
}

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

# Main restore function
restore_backup() {
    local backup_id=$1
    local backup_path="$BACKUP_DIR/$backup_id"
    
    log "INFO" "Starting Nextcloud restore from backup: $backup_id"
    
    # Validate backup
    validate_backup "$backup_id"
    
    # Verify backup integrity
    if ! verify_backup_integrity "$backup_id"; then
        error_exit "Backup integrity verification failed - restore aborted"
    fi
    
    # Verify checksums if available
    if ! verify_backup_checksums "$backup_id"; then
        error_exit "Checksum verification failed - restore aborted"
    fi
    
    # Show backup info
    show_backup_info "$backup_id"
    
    # Confirm restore
    if [[ "${FORCE_RESTORE:-}" != "true" ]]; then
        echo -e "${YELLOW}WARNING: This will replace your current Nextcloud installation!${NC}"
        read -p "Are you sure you want to continue? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            log "INFO" "Restore cancelled by user"
            exit 0
        fi
    fi
    
    # Create safety backup
    local safety_backup_id=$(create_safety_backup)
    log "INFO" "Safety backup created: $safety_backup_id"
    
    # Stop services
    stop_services
    enable_maintenance_mode
    
    # Restore database
    restore_database "$backup_id"
    
    # Restore files
    restore_files "$backup_id"
    
    # Update Nextcloud
    update_nextcloud
    
    # Start services
    disable_maintenance_mode
    start_services
    
    log "INFO" "Restore completed successfully!"
    log "INFO" "Backup ID: $backup_id"
    log "INFO" "Safety backup: $safety_backup_id"
    
    # Cleanup old backups if configured
    cleanup_old_backups "$safety_backup_id"
}

# Show usage
usage() {
    echo "Usage: $0 [OPTIONS] <command>"
    echo ""
    echo "Commands:"
    echo "  list                    List available backups"
    echo "  info <backup_id>        Show backup information"
    echo "  restore <backup_id>     Restore from backup"
    echo "  help                    Show this help message"
    echo ""
    echo "Options:"
    echo "  --force                 Skip confirmation prompts"
    echo "  --config <file>         Use custom configuration file"
    echo ""
    echo "Examples:"
    echo "  $0 list"
    echo "  $0 info 20240101_120000"
    echo "  $0 restore 20240101_120000"
    echo "  $0 --force restore 20240101_120000"
}

# Main execution
main() {
    local command=""
    local backup_id=""
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force)
                export FORCE_RESTORE=true
                shift
                ;;
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            list|info|restore|help)
                command="$1"
                shift
                if [[ "$command" == "info" || "$command" == "restore" ]]; then
                    backup_id="$1"
                    shift
                fi
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # Load configuration
    load_config
    
    # Execute command
    case "$command" in
        "list")
            list_backups
            ;;
        "info")
            if [[ -z "$backup_id" ]]; then
                log "ERROR" "Backup ID required for info command"
                usage
                exit 1
            fi
            validate_backup "$backup_id"
            show_backup_info "$backup_id"
            ;;
        "restore")
            if [[ -z "$backup_id" ]]; then
                log "ERROR" "Backup ID required for restore command"
                usage
                exit 1
            fi
            restore_backup "$backup_id"
            ;;
        "help"|"")
            usage
            ;;
        *)
            log "ERROR" "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
