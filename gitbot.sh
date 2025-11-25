#!/bin/bash

# Gitbot - Automatic Git Commit Bot
# Usage: gitbot start <seconds> [-h] | gitbot end | gitbot status

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

# Gitbot internal files (don't commit gitbot state)
.gitbot/
EOF
    
    print_msg "$GREEN" "✓ Created .gitignore with common patterns"
    log "Created .gitignore in $1"
}

# Initialize git repository
init_git_repo() {
    local repo_path="$1"
    local repo_name="$2"
    local enable_push="$3"
    
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
    
    # Setup GitHub remote if -h flag is set
    if [ "$enable_push" = "true" ]; then
        setup_github_remote "$repo_name"
    fi
    
    create_gitignore "$repo_path"
    
    # Initial commit
    git add -A
    
    # Check if there are actually files to commit
    local files_to_commit=$(git diff --cached --name-only | wc -l)
    
    if [ "$files_to_commit" -eq 0 ]; then
        print_msg "$YELLOW" "No files to commit initially."
        print_msg "$BLUE" "Current directory contents:"
        ls -la
        print_msg "$YELLOW" "Check if files are being ignored by .gitignore"
    else
        print_msg "$BLUE" "Files to commit: $files_to_commit"
        git diff --cached --name-only | sed 's/^/  - /'
        
        if git commit -m "Initial commit by Gitbot" > /dev/null 2>&1; then
            print_msg "$GREEN" "✓ Created initial commit with $files_to_commit file(s)"
            log "Created initial commit in $repo_path with $files_to_commit files"
            
            # Push initial commit if GitHub is configured
            if [ "$enable_push" = "true" ]; then
                push_to_github
            fi
        else
            print_msg "$RED" "Failed to create initial commit"
            log "ERROR: Failed to create initial commit"
        fi
    fi
}

# Check for GitHub CLI or create via API
create_github_repo() {
    local repo_name="$1"
    local github_user="$2"
    
    # Try using GitHub CLI first (if available)
    if command -v gh &> /dev/null; then
        print_msg "$BLUE" "Creating repository using GitHub CLI..."
        if gh repo create "$repo_name" --private --source=. --remote=origin 2>> "$LOG_FILE"; then
            print_msg "$GREEN" "✓ Repository created successfully via GitHub CLI"
            log "Created GitHub repo via CLI: $repo_name"
            return 0
        else
            print_msg "$YELLOW" "GitHub CLI creation failed, trying API method..."
        fi
    fi
    
    # Fallback to API method
    print_msg "$BLUE" "Creating repository via GitHub API..."
    echo ""
    print_msg "$YELLOW" "You need a GitHub Personal Access Token (classic) with 'repo' scope."
    print_msg "$YELLOW" "Create one at: https://github.com/settings/tokens/new"
    print_msg "$YELLOW" "Required scopes: repo"
    echo ""
    print_msg "$BLUE" "Enter your GitHub Personal Access Token:"
    read -rs github_token
    echo ""
    
    if [ -z "$github_token" ]; then
        print_msg "$RED" "Error: Token cannot be empty."
        return 1
    fi
    
    # Make repo private by default
    print_msg "$YELLOW" "Make repository private? (y/n, default: y):"
    read -r make_private
    make_private=${make_private:-y}
    
    local is_private="true"
    if [[ "$make_private" =~ ^[Nn] ]]; then
        is_private="false"
    fi
    
    # Create repository via API
    local response=$(curl -s -X POST \
        -H "Authorization: token $github_token" \
        -H "Accept: application/vnd.github.v3+json" \
        https://api.github.com/user/repos \
        -d "{\"name\":\"$repo_name\",\"private\":$is_private,\"auto_init\":false}")
    
    # Check if creation was successful
    if echo "$response" | grep -q '"clone_url"'; then
        print_msg "$GREEN" "✓ Repository created successfully on GitHub"
        log "Created GitHub repo via API: $repo_name"
        
        # Store token for future pushes (encrypted in git config)
        git config credential.helper store
        
        return 0
    else
        local error_msg=$(echo "$response" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
        if [ -n "$error_msg" ]; then
            print_msg "$RED" "Failed to create repository: $error_msg"
        else
            print_msg "$RED" "Failed to create repository. Response:"
            echo "$response"
        fi
        log "ERROR: Failed to create GitHub repo: $error_msg"
        return 1
    fi
}

# Setup GitHub remote
setup_github_remote() {
    local repo_name="$1"
    
    # Check if remote already exists
    if git remote get-url origin > /dev/null 2>&1; then
        print_msg "$YELLOW" "Remote 'origin' already exists:"
        git remote get-url origin
        print_msg "$BLUE" "Using existing remote."
        return
    fi
    
    print_msg "$BLUE" "Setting up GitHub remote..."
    echo ""
    print_msg "$YELLOW" "Enter your GitHub username:"
    read -r github_user
    
    if [ -z "$github_user" ]; then
        print_msg "$RED" "Error: GitHub username cannot be empty."
        exit 1
    fi
    
    # Ask if user wants to create repo automatically
    print_msg "$YELLOW" "Do you want to create the repository on GitHub automatically? (y/n, default: y):"
    read -r auto_create
    auto_create=${auto_create:-y}
    
    if [[ "$auto_create" =~ ^[Yy] ]]; then
        if create_github_repo "$repo_name" "$github_user"; then
            # Repository created successfully
            local remote_url="https://github.com/${github_user}/${repo_name}.git"
            
            # Add remote if not already added by gh CLI
            if ! git remote get-url origin > /dev/null 2>&1; then
                git remote add origin "$remote_url"
                print_msg "$GREEN" "✓ Added GitHub remote: $remote_url"
                log "Added GitHub remote: $remote_url"
            fi
        else
            print_msg "$RED" "Failed to create repository automatically."
            print_msg "$YELLOW" "Please create it manually at: https://github.com/new"
            print_msg "$BLUE" "Press Enter when ready to continue..."
            read -r
            
            local remote_url="https://github.com/${github_user}/${repo_name}.git"
            git remote add origin "$remote_url"
            print_msg "$GREEN" "✓ Added GitHub remote: $remote_url"
            log "Added GitHub remote: $remote_url"
        fi
    else
        local remote_url="https://github.com/${github_user}/${repo_name}.git"
        
        print_msg "$BLUE" "Remote URL will be: $remote_url"
        print_msg "$YELLOW" "Make sure the repository exists on GitHub!"
        print_msg "$YELLOW" "Create it at: https://github.com/new"
        echo ""
        print_msg "$BLUE" "Press Enter when ready to continue..."
        read -r
        
        git remote add origin "$remote_url"
        print_msg "$GREEN" "✓ Added GitHub remote: $remote_url"
        log "Added GitHub remote: $remote_url"
    fi
}

# Push to GitHub
push_to_github() {
    print_msg "$BLUE" "Pushing to GitHub..."
    
    # Try to push, capture output
    local push_output=$(git push -u origin main 2>&1)
    local push_status=$?
    
    if [ $push_status -eq 0 ]; then
        print_msg "$GREEN" "✓ Pushed to GitHub successfully"
        log "Pushed to GitHub"
        return 0
    else
        print_msg "$RED" "Failed to push to GitHub."
        echo "$push_output"
        print_msg "$YELLOW" "Common issues:"
        echo "  1. Repository doesn't exist on GitHub"
        echo "  2. Authentication not configured (SSH keys or credential helper)"
        echo "  3. No push permissions"
        echo ""
        print_msg "$YELLOW" "Check the log file for details: $LOG_FILE"
        log "ERROR: Failed to push to GitHub - $push_output"
        
        # Don't exit, let monitoring continue
        print_msg "$YELLOW" "Continuing with local commits only. Fix authentication to enable push."
        return 1
    fi
}

# Monitor and auto-commit changes
monitor_changes() {
    local repo_path="$1"
    local interval="$2"
    local enable_push="$3"
    
    log "Started monitoring $repo_path with interval ${interval}s (push: $enable_push)"
    
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
                    
                    # Push to GitHub if enabled
                    if [ "$enable_push" = "true" ]; then
                        if git push origin main >> "$LOG_FILE" 2>&1; then
                            log "Pushed changes to GitHub"
                        else
                            log "ERROR: Failed to push to GitHub"
                        fi
                    fi
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
    local interval=""
    local enable_push="false"
    
    # Parse arguments - accept both orders: "30 -h" or "-h 30"
    while [ $# -gt 0 ]; do
        case "$1" in
            -h)
                enable_push="true"
                shift
                ;;
            *)
                if [[ "$1" =~ ^[0-9]+$ ]]; then
                    interval="$1"
                fi
                shift
                ;;
        esac
    done
    
    local repo_path="$(pwd)"
    
    # Validate interval
    if [ -z "$interval" ] || ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 1 ]; then
        print_msg "$RED" "Error: Invalid interval. Please provide a positive number of seconds."
        echo "Usage: gitbot start <seconds> [-h]  or  gitbot start -h <seconds>"
        echo "  -h    Enable push to GitHub"
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
    init_git_repo "$repo_path" "$repo_name" "$enable_push"
    
    # Save state
    echo "$repo_path|$interval|$repo_name|$enable_push" > "$STATE_FILE"
    
    # Create a wrapper script for the monitoring process
    local monitor_script="$GITBOT_DIR/monitor_${pid}.sh"
    cat > "$monitor_script" << 'MONITOR_EOF'
#!/bin/bash
REPO_PATH="$1"
INTERVAL="$2"
ENABLE_PUSH="$3"
LOG_FILE="$4"

cd "$REPO_PATH" || exit 1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "Monitor started: PID $"

while true; do
    cd "$REPO_PATH" || {
        log "ERROR: Cannot access repository path $REPO_PATH"
        sleep "$INTERVAL"
        continue
    }
    
    git add -A 2>> "$LOG_FILE"
    
    if ! git diff --cached --quiet 2>> "$LOG_FILE"; then
        changed_files=$(git diff --cached --name-only | tr '\n' ', ' | sed 's/,$//')
        
        if [ -n "$changed_files" ]; then
            commit_msg="Edited: $changed_files"
            
            if git commit -m "$commit_msg" >> "$LOG_FILE" 2>&1; then
                log "Auto-committed changes: $changed_files"
                
                if [ "$ENABLE_PUSH" = "true" ]; then
                    if git push origin main >> "$LOG_FILE" 2>&1; then
                        log "Pushed changes to GitHub"
                    else
                        log "ERROR: Failed to push to GitHub"
                    fi
                fi
            else
                log "ERROR: Failed to commit changes"
            fi
        fi
    fi
    
    sleep "$INTERVAL"
done
MONITOR_EOF
    
    chmod +x "$monitor_script"
    
    # Start monitoring in background using nohup for better persistence
    nohup bash "$monitor_script" "$repo_path" "$interval" "$enable_push" "$LOG_FILE" > /dev/null 2>&1 &
    
    local pid=$!
    echo "$pid" > "$PID_FILE"
    
    # Wait a moment and verify the process started
    sleep 1
    if ! ps -p "$pid" > /dev/null 2>&1; then
        print_msg "$RED" "Error: Failed to start monitoring process"
        print_msg "$YELLOW" "Check log file: $LOG_FILE"
        rm -f "$PID_FILE"
        rm -f "$monitor_script"
        exit 1
    fi
    
    print_msg "$GREEN" "✓ Gitbot started successfully!"
    echo ""
    print_msg "$BLUE" "  Repository: $repo_name"
    print_msg "$BLUE" "  Path: $repo_path"
    print_msg "$BLUE" "  Interval: ${interval}s"
    if [ "$enable_push" = "true" ]; then
        print_msg "$BLUE" "  GitHub Push: Enabled"
    else
        print_msg "$BLUE" "  GitHub Push: Disabled"
    fi
    print_msg "$BLUE" "  PID: $pid"
    echo ""
    print_msg "$YELLOW" "Gitbot is now monitoring changes in the background."
    print_msg "$YELLOW" "Use 'gitbot end' to stop monitoring."
    
    log "Gitbot started: $repo_name at $repo_path, interval ${interval}s, push: $enable_push, PID $pid"
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
        sleep 1
        
        # Force kill if still running
        if ps -p "$pid" > /dev/null 2>&1; then
            kill -9 "$pid" 2>> "$LOG_FILE"
        fi
        
        rm -f "$PID_FILE"
        rm -f "$STATE_FILE"
        rm -f "$GITBOT_DIR/monitor_${pid}.sh" 2>/dev/null
        print_msg "$GREEN" "✓ Gitbot stopped successfully."
        log "Gitbot stopped (PID: $pid)"
    else
        print_msg "$YELLOW" "Gitbot process not found. Cleaning up..."
        rm -f "$PID_FILE"
        rm -f "$STATE_FILE"
        rm -f "$GITBOT_DIR"/monitor_*.sh 2>/dev/null
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
            IFS='|' read -r repo_path interval repo_name enable_push < "$STATE_FILE"
            print_msg "$GREEN" "Gitbot is running:"
            echo ""
            print_msg "$BLUE" "  Repository: $repo_name"
            print_msg "$BLUE" "  Path: $repo_path"
            print_msg "$BLUE" "  Interval: ${interval}s"
            if [ "$enable_push" = "true" ]; then
                print_msg "$BLUE" "  GitHub Push: Enabled"
            else
                print_msg "$BLUE" "  GitHub Push: Disabled"
            fi
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
    
    IFS='|' read -r repo_path interval repo_name enable_push < "$STATE_FILE"
    
    if [ ! -d "$repo_path" ]; then
        log "ERROR: Repository path $repo_path no longer exists"
        rm -f "$STATE_FILE"
        exit 1
    fi
    
    log "Restarting gitbot for $repo_name"
    
    cd "$repo_path" || exit 1
    
    # Create monitor script
    local pid=$
    local monitor_script="$GITBOT_DIR/monitor_${pid}.sh"
    cat > "$monitor_script" << 'MONITOR_EOF'
#!/bin/bash
REPO_PATH="$1"
INTERVAL="$2"
ENABLE_PUSH="$3"
LOG_FILE="$4"

cd "$REPO_PATH" || exit 1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "Monitor restarted: PID $"

while true; do
    cd "$REPO_PATH" || {
        log "ERROR: Cannot access repository path $REPO_PATH"
        sleep "$INTERVAL"
        continue
    }
    
    git add -A 2>> "$LOG_FILE"
    
    if ! git diff --cached --quiet 2>> "$LOG_FILE"; then
        changed_files=$(git diff --cached --name-only | tr '\n' ', ' | sed 's/,$//')
        
        if [ -n "$changed_files" ]; then
            commit_msg="Edited: $changed_files"
            
            if git commit -m "$commit_msg" >> "$LOG_FILE" 2>&1; then
                log "Auto-committed changes: $changed_files"
                
                if [ "$ENABLE_PUSH" = "true" ]; then
                    if git push origin main >> "$LOG_FILE" 2>&1; then
                        log "Pushed changes to GitHub"
                    else
                        log "ERROR: Failed to push to GitHub"
                    fi
                fi
            else
                log "ERROR: Failed to commit changes"
            fi
        fi
    fi
    
    sleep "$INTERVAL"
done
MONITOR_EOF
    
    chmod +x "$monitor_script"
    
    nohup bash "$monitor_script" "$repo_path" "$interval" "$enable_push" "$LOG_FILE" > /dev/null 2>&1 &
    
    pid=$!
    echo "$pid" > "$PID_FILE"
    
    log "Gitbot restarted: PID $pid"
}

# Main function
main() {
    init_gitbot_dir
    check_git
    
    case "${1:-}" in
        start)
            shift
            start_gitbot "$@"
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
            echo "  gitbot start <seconds> [-h]  Start monitoring and auto-committing"
            echo "  gitbot start -h <seconds>    Alternative syntax"
            echo "                               -h: Enable push to GitHub"
            echo "  gitbot end                   Stop monitoring"
            echo "  gitbot status                Show current status"
            echo ""
            echo "Examples:"
            echo "  gitbot start 30              Monitor and commit every 30 seconds (local only)"
            echo "  gitbot start 30 -h           Monitor, commit and push to GitHub every 30 seconds"
            echo "  gitbot start -h 120          Same as above (arguments can be in any order)"
            echo "  gitbot end                   Stop gitbot"
            exit 1
            ;;
    esac
}

main "$@"