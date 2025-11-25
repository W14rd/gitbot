#!/bin/bash

# Gitbot - Automatic Git Commit Bot
# Usage: gitbot start <seconds> | gitbot end | gitbot status

set -e

# Configuration
GITBOT_DIR="$HOME/.gitbot"
STATE_FILE="$GITBOT_DIR/state"
LOG_FILE="$GITBOT_DIR/gitbot.log"
PID_FILE="$GITBOT_DIR/gitbot.pid"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Initialize gitbot directory
init_gitbot_dir() {
    mkdir -p "$GITBOT_DIR"
    touch "$LOG_FILE"
}

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Print colored message
print_msg() {
    local color=$1
    shift
    echo -e "${color}$@${NC}"
}

# Check if git is installed
check_git() {
    if ! command -v git &> /dev/null; then
        print_msg "$RED" "Error: git is not installed. Please install git first."
        exit 1
    fi
}

# Create default .gitignore
create_gitignore() {
    local gitignore_file="$1/.gitignore"
    
    if [ -f "$gitignore_file" ]; then
        print_msg "$YELLOW" ".gitignore already exists, skipping creation."
        return
    fi
    
    cat > "$gitignore_file" << 'EOF'
# Dependencies
node_modules/
bower_components/
vendor/

# Build outputs
dist/
build/
out/
target/
*.o
*.so
*.exe
*.dll
*.dylib

# Logs
*.log
logs/
npm-debug.log*
yarn-debug.log*
yarn-error.log*

# OS files
.DS_Store
Thumbs.db
desktop.ini

# IDE files
.vscode/
.idea/
*.swp
*.swo
*~
.project
.classpath
.settings/

# Environment files
.env
.env.local
.env.*.local

# Python
__pycache__/
*.py[cod]
*.pyo
*.pyd
.Python
venv/
env/
ENV/

# Java
*.class
*.jar
*.war
*.ear

# Temporary files
tmp/
temp/
*.tmp
*.bak
*.cache

# Package manager lock files (optional - uncomment if needed)
# package-lock.json
# yarn.lock
# Gemfile.lock
EOF
    
    print_msg "$GREEN" "✓ Created .gitignore with common patterns"
    log "Created .gitignore in $1"
}

# Initialize git repository
init_git_repo() {
    local repo_path="$1"
    local repo_name="$2"
    
    cd "$repo_path" || exit 1
    
    if [ -d ".git" ]; then
        print_msg "$YELLOW" "Git repository already initialized."
    else
        git init -b main > /dev/null 2>&1
        print_msg "$GREEN" "✓ Initialized git repository with main branch"
        log "Initialized git repository in $repo_path"
    fi
    
    # Set user if not configured
    if [ -z "$(git config user.email)" ]; then
        git config user.email "gitbot@local"
        git config user.name "Gitbot"
        print_msg "$BLUE" "Set default git user (gitbot@local)"
    fi
    
    create_gitignore "$repo_path"
    
    # Initial commit
    git add .
    if git diff --cached --quiet; then
        print_msg "$YELLOW" "No files to commit initially."
    else
        git commit -m "Initial commit by Gitbot" > /dev/null 2>&1
        print_msg "$GREEN" "✓ Created initial commit"
        log "Created initial commit in $repo_path"
    fi
}

# Monitor and auto-commit changes
monitor_changes() {
    local repo_path="$1"
    local interval="$2"
    
    log "Started monitoring $repo_path with interval ${interval}s"
    
    while true; do
        cd "$repo_path" || {
            log "ERROR: Cannot access repository path $repo_path"
            sleep "$interval"
            continue
        }
        
        # Check for changes
        git add -A 2>> "$LOG_FILE"
        
        if ! git diff --cached --quiet 2>> "$LOG_FILE"; then
            # Get list of changed files
            local changed_files=$(git diff --cached --name-only | tr '\n' ', ' | sed 's/,$//')
            
            if [ -n "$changed_files" ]; then
                local commit_msg="Edited: $changed_files"
                
                if git commit -m "$commit_msg" >> "$LOG_FILE" 2>&1; then
                    log "Auto-committed changes: $changed_files"
                else
                    log "ERROR: Failed to commit changes"
                fi
            fi
        fi
        
        sleep "$interval"
    done
}

# Start gitbot
start_gitbot() {
    local interval="$1"
    local repo_path="$(pwd)"
    
    # Validate interval
    if [ -z "$interval" ] || ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 1 ]; then
        print_msg "$RED" "Error: Invalid interval. Please provide a positive number of seconds."
        echo "Usage: gitbot start <seconds>"
        exit 1
    fi
    
    # Check if already running
    if [ -f "$PID_FILE" ]; then
        local old_pid=$(cat "$PID_FILE")
        if ps -p "$old_pid" > /dev/null 2>&1; then
            print_msg "$RED" "Error: Gitbot is already running (PID: $old_pid)"
            echo "Use 'gitbot end' to stop it first."
            exit 1
        else
            print_msg "$YELLOW" "Removing stale PID file..."
            rm -f "$PID_FILE"
        fi
    fi
    
    # Get repository name
    local default_name=$(basename "$repo_path")
    print_msg "$BLUE" "Repository name (press Enter for '$default_name'): "
    read -r repo_name
    repo_name=${repo_name:-$default_name}
    
    print_msg "$BLUE" "Starting Gitbot for '$repo_name'..."
    
    # Initialize repository
    init_git_repo "$repo_path" "$repo_name"
    
    # Save state
    echo "$repo_path|$interval|$repo_name" > "$STATE_FILE"
    
    # Start monitoring in background
    (
        trap 'log "Gitbot stopped"; rm -f "$PID_FILE"; exit 0' SIGTERM SIGINT
        monitor_changes "$repo_path" "$interval"
    ) &
    
    local pid=$!
    echo "$pid" > "$PID_FILE"
    
    # Make the background process independent
    disown
    
    print_msg "$GREEN" "✓ Gitbot started successfully!"
    echo ""
    print_msg "$BLUE" "  Repository: $repo_name"
    print_msg "$BLUE" "  Path: $repo_path"
    print_msg "$BLUE" "  Interval: ${interval}s"
    print_msg "$BLUE" "  PID: $pid"
    echo ""
    print_msg "$YELLOW" "Gitbot is now monitoring changes in the background."
    print_msg "$YELLOW" "Use 'gitbot end' to stop monitoring."
    
    log "Gitbot started: $repo_name at $repo_path, interval ${interval}s, PID $pid"
}

# Stop gitbot
stop_gitbot() {
    if [ ! -f "$PID_FILE" ]; then
        print_msg "$YELLOW" "Gitbot is not running."
        exit 0
    fi
    
    local pid=$(cat "$PID_FILE")
    
    if ps -p "$pid" > /dev/null 2>&1; then
        kill "$pid" 2>> "$LOG_FILE"
        rm -f "$PID_FILE"
        rm -f "$STATE_FILE"
        print_msg "$GREEN" "✓ Gitbot stopped successfully."
        log "Gitbot stopped (PID: $pid)"
    else
        print_msg "$YELLOW" "Gitbot process not found. Cleaning up..."
        rm -f "$PID_FILE"
        rm -f "$STATE_FILE"
    fi
}

# Show status
show_status() {
    if [ ! -f "$PID_FILE" ]; then
        print_msg "$YELLOW" "Gitbot is not running."
        return
    fi
    
    local pid=$(cat "$PID_FILE")
    
    if ps -p "$pid" > /dev/null 2>&1; then
        if [ -f "$STATE_FILE" ]; then
            IFS='|' read -r repo_path interval repo_name < "$STATE_FILE"
            print_msg "$GREEN" "Gitbot is running:"
            echo ""
            print_msg "$BLUE" "  Repository: $repo_name"
            print_msg "$BLUE" "  Path: $repo_path"
            print_msg "$BLUE" "  Interval: ${interval}s"
            print_msg "$BLUE" "  PID: $pid"
        else
            print_msg "$GREEN" "Gitbot is running (PID: $pid)"
        fi
    else
        print_msg "$YELLOW" "Gitbot process not found. Cleaning up..."
        rm -f "$PID_FILE"
        rm -f "$STATE_FILE"
    fi
}

# Restart gitbot (for persistence)
restart_gitbot() {
    if [ ! -f "$STATE_FILE" ]; then
        log "No state file found for restart"
        exit 0
    fi
    
    IFS='|' read -r repo_path interval repo_name < "$STATE_FILE"
    
    if [ ! -d "$repo_path" ]; then
        log "ERROR: Repository path $repo_path no longer exists"
        rm -f "$STATE_FILE"
        exit 1
    fi
    
    log "Restarting gitbot for $repo_name"
    
    cd "$repo_path" || exit 1
    
    # Start monitoring in background
    (
        trap 'log "Gitbot stopped"; rm -f "$PID_FILE"; exit 0' SIGTERM SIGINT
        monitor_changes "$repo_path" "$interval"
    ) &
    
    local pid=$!
    echo "$pid" > "$PID_FILE"
    disown
    
    log "Gitbot restarted: PID $pid"
}

# Main function
main() {
    init_gitbot_dir
    check_git
    
    case "${1:-}" in
        start)
            start_gitbot "$2"
            ;;
        end)
            stop_gitbot
            ;;
        status)
            show_status
            ;;
        restart)
            restart_gitbot
            ;;
        *)
            echo "Gitbot - Automatic Git Commit Bot"
            echo ""
            echo "Usage:"
            echo "  gitbot start <seconds>   Start monitoring and auto-committing"
            echo "  gitbot end               Stop monitoring"
            echo "  gitbot status            Show current status"
            echo ""
            echo "Examples:"
            echo "  gitbot start 30          Monitor and commit every 30 seconds"
            echo "  gitbot end               Stop gitbot"
            exit 1
            ;;
    esac
}

main "$@"