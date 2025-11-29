#!/bin/bash

####

set -e

project_id() {
    echo -n "$PWD" | sha256sum | cut -c1-16
}

GITBOT_DIR="$HOME/.gitbot"
PROJECT_ID=$(project_id)

PID_FILE="$GITBOT_DIR/pids/$PROJECT_ID.pid"
STATE_FILE="$GITBOT_DIR/states/$PROJECT_ID.state"
LOG_FILE="$GITBOT_DIR/logs/$PROJECT_ID.log"
BOOT_FILE="$GITBOT_DIR/boot_check"

mkdir -p "$GITBOT_DIR/pids" "$GITBOT_DIR/logs" "$GITBOT_DIR/states"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

init_gitbot_dir() {
    mkdir -p "$GITBOT_DIR"
    touch "$LOG_FILE"
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

print_msg() {
    local color=$1
    shift
    echo -e "${color}$@${NC}"
}

check_git() {
    if ! command -v git &> /dev/null; then
        print_msg "$RED" "Error: git is not installed"
        exit 1
    fi
}

check_boot_and_restart() {
    local current_boot_time=$(who -b 2>/dev/null | awk '{print $3" "$4}' || uptime -s 2>/dev/null || echo "unknown")
    local last_boot_time=""
    
    if [ -f "$BOOT_FILE" ]; then
        last_boot_time=$(cat "$BOOT_FILE")
    fi
    
    if [ "$current_boot_time" != "$last_boot_time" ] && [ "$current_boot_time" != "unknown" ]; then
        log "Boot detected. Previous: $last_boot_time, Current: $current_boot_time"
        echo "$current_boot_time" > "$BOOT_FILE"
        
        for state_file in "$GITBOT_DIR/states"/*.state; do
            if [ -f "$state_file" ]; then
                local state_project_id=$(basename "$state_file" .state)
                IFS='|' read -r repo_path interval repo_name enable_push < "$state_file"
                
                if [ -d "$repo_path" ]; then
                    log "Auto-restarting gitbot for: $repo_name at $repo_path"
                    
                    cd "$repo_path" || continue
                    
                    local monitor_script="$GITBOT_DIR/monitor_${state_project_id}.sh"
                    create_monitor_script "$monitor_script"
                    
                    nohup bash "$monitor_script" "$repo_path" "$interval" "$enable_push" "$GITBOT_DIR/logs/${state_project_id}.log" > /dev/null 2>&1 &
                    
                    local new_pid=$!
                    echo "$new_pid" > "$GITBOT_DIR/pids/${state_project_id}.pid"
                    
                    log "Restarted gitbot for $repo_name with PID $new_pid"
                fi
            fi
        done
    elif [ "$current_boot_time" = "unknown" ]; then
        for state_file in "$GITBOT_DIR/states"/*.state; do
            if [ -f "$state_file" ]; then
                local state_project_id=$(basename "$state_file" .state)
                local pid_file="$GITBOT_DIR/pids/${state_project_id}.pid"
                
                if [ -f "$pid_file" ]; then
                    local old_pid=$(cat "$pid_file")
                    if ! ps -p "$old_pid" > /dev/null 2>&1; then
                        IFS='|' read -r repo_path interval repo_name enable_push < "$state_file"
                        
                        if [ -d "$repo_path" ]; then
                            log "Detected dead process for $repo_name, restarting..."
                            
                            cd "$repo_path" || continue
                            
                            local monitor_script="$GITBOT_DIR/monitor_${state_project_id}.sh"
                            create_monitor_script "$monitor_script"
                            
                            nohup bash "$monitor_script" "$repo_path" "$interval" "$enable_push" "$GITBOT_DIR/logs/${state_project_id}.log" > /dev/null 2>&1 &
                            
                            local new_pid=$!
                            echo "$new_pid" > "$pid_file"
                            
                            log "Restarted gitbot for $repo_name with PID $new_pid"
                        fi
                    fi
                fi
            fi
        done
    fi
}

setup_systemd_service() {
    local service_dir="$HOME/.config/systemd/user"
    local service_file="$service_dir/gitbot-restore.service"
    local timer_file="$service_dir/gitbot-restore.timer"
    
    mkdir -p "$service_dir"
    
    cat > "$service_file" << EOF
[Unit]
Description=Gitbot Auto-Restore Service
After=network.target

[Service]
Type=oneshot
ExecStart=$HOME/.gitbot/restore_all.sh
RemainAfterExit=no

[Install]
WantedBy=default.target
EOF

    cat > "$timer_file" << EOF
[Unit]
Description=Gitbot Auto-Restore Timer

[Timer]
OnBootSec=1min
OnUnitActiveSec=1h

[Install]
WantedBy=timers.target
EOF

    cat > "$GITBOT_DIR/restore_all.sh" << 'EOF'
#!/bin/bash
GITBOT_DIR="$HOME/.gitbot"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$GITBOT_DIR/logs/restore.log"
}

log "Restore script started"

for state_file in "$GITBOT_DIR/states"/*.state; do
    if [ -f "$state_file" ]; then
        state_project_id=$(basename "$state_file" .state)
        pid_file="$GITBOT_DIR/pids/${state_project_id}.pid"
        
        if [ -f "$pid_file" ]; then
            old_pid=$(cat "$pid_file")
            if ps -p "$old_pid" > /dev/null 2>&1; then
                log "Gitbot already running for project $state_project_id (PID: $old_pid)"
                continue
            fi
        fi
        
        IFS='|' read -r repo_path interval repo_name enable_push < "$state_file"
        
        if [ -d "$repo_path" ]; then
            log "Restoring gitbot for: $repo_name at $repo_path"
            
            cd "$repo_path" || continue
            
            monitor_script="$GITBOT_DIR/monitor_${state_project_id}.sh"
            
            if [ -f "$monitor_script" ]; then
                nohup bash "$monitor_script" "$repo_path" "$interval" "$enable_push" "$GITBOT_DIR/logs/${state_project_id}.log" > /dev/null 2>&1 &
                
                new_pid=$!
                echo "$new_pid" > "$pid_file"
                
                log "Restored gitbot for $repo_name with PID $new_pid"
            fi
        fi
    fi
done

log "Restore script completed"
EOF

    chmod +x "$GITBOT_DIR/restore_all.sh"
    
    if command -v systemctl &> /dev/null; then
        systemctl --user daemon-reload 2>/dev/null
        systemctl --user enable gitbot-restore.timer 2>/dev/null
        systemctl --user start gitbot-restore.timer 2>/dev/null
        
        if systemctl --user is-active --quiet gitbot-restore.timer; then
            print_msg "$GREEN" "Systemd auto-restore enabled"
            log "Systemd service enabled"
            return 0
        fi
    fi
    
    setup_cron_fallback
}

setup_cron_fallback() {
    local cron_entry="@reboot $GITBOT_DIR/restore_all.sh"
    
    if crontab -l 2>/dev/null | grep -q "restore_all.sh"; then
        log "Cron entry already exists"
        return 0
    fi
    
    (crontab -l 2>/dev/null; echo "$cron_entry") | crontab - 2>/dev/null
    
    if crontab -l 2>/dev/null | grep -q "restore_all.sh"; then
        print_msg "$GREEN" "Cron auto-restore enabled"
        log "Cron entry added for boot persistence"
        return 0
    else
        print_msg  "Note: Could not enable auto-restore. Manually add to crontab: $cron_entry"
        log "Warning: Could not enable auto-restore automatically"
        return 1
    fi
}

create_gitignore() {
    local gitignore_file="$1/.gitignore"
    
    if [ -f "$gitignore_file" ]; then
        print_msg  ".gitignore already exists, skipping creation."
        return
    fi
    
    cat > "$gitignore_file" << 'EOF'
node_modules/
bower_components/
vendor/

dist/
build/
out/
target/
*.o
*.so
*.exe
*.dll
*.dylib

*.log
logs/
npm-debug.log*
yarn-debug.log*
yarn-error.log*

.DS_Store
Thumbs.db
desktop.ini

.vscode/
.idea/
*.swp
*.swo
*~
.project
.classpath
.settings/

.env
.env.local
.env.*.local

__pycache__/
*.py[cod]
*.pyo
*.pyd
.Python
venv/
env/
ENV/

*.class
*.jar
*.war
*.ear

tmp/
temp/
*.tmp
*.bak
*.cache

# package-lock.json
# yarn.lock
# Gemfile.lock

.gitbot/
EOF
    
    print_msg "$GREEN" "Created standard .gitignore"
    log "Created .gitignore in $1"
}

init_git_repo() {
    local repo_path="$1"
    local repo_name="$2"
    local enable_push="$3"
    
    cd "$repo_path" || exit 1
    
    if [ -d ".git" ]; then
        print_msg "Git repository already initialized"
    else
        git init -b main > /dev/null 2>&1
        print_msg "$GREEN" "Initialized git repository (main)"
        log "Initialized git repository in $repo_path"
    fi
    
    if [ -z "$(git config user.email)" ]; then
        git config user.email "gitbot@local"
        git config user.name "Gitbot"
        print_msg "Set default git user (gitbot@local)"
    fi
    
    if [ "$enable_push" = "true" ]; then
        setup_github_remote "$repo_name"
    fi
    
    create_gitignore "$repo_path"
    
    git add -A
    
    local files_to_commit=$(git diff --cached --name-only | wc -l)
    
    if [ "$files_to_commit" -eq 0 ]; then
        print_msg "No files to commit initially. Current directory contents:"
        ls -la
        print_msg "Check if files are being ignored by .gitignore or push manually"
    else
        print_msg  "Files to commit: $files_to_commit"
        git diff --cached --name-only | sed 's/^/  - /'
        
        if git commit -m "Initial commit" > /dev/null 2>&1; then
            print_msg  "Created initial commit with $files_to_commit file(s)"
            log "Created initial commit in $repo_path with $files_to_commit files"
            
            if [ "$enable_push" = "true" ]; then
                push_to_github
            fi
        else
            print_msg "$RED" "Failed to create initial commit"
            log "Error: Failed to create initial commit"
        fi
    fi
}

create_github_repo() {
    local repo_name="$1"
    local github_user="$2"
    
    if command -v gh &> /dev/null; then
        print_msg  "Creating repository..."
        if gh repo create "$repo_name" --private --source=. --remote=origin 2>> "$LOG_FILE"; then
            print_msg "$GREEN" "Repository created successfully"
            log "Created GitHub repo via CLI: $repo_name"
            return 0
        else
            print_msg "GitHub CLI creation failed, fallback to API:"
        fi
    fi
    
    print_msg "Creating repository via GitHub API..."
    echo ""
    print_msg "You need a GitHub Personal Access Token with 'repo' scope: https://github.com/settings/tokens/new"
    echo ""
    print_msg  "Enter your GitHub token:"
    read -rs github_token
    echo ""
    
    if [ -z "$github_token" ]; then
        print_msg "$RED" "Token empty"
        return 1
    fi
    
    print_msg "Make repository private? (Y/n):"
    read -r make_private
    make_private=${make_private:-y}
    
    local is_private="true"
    if [[ "$make_private" =~ ^[Nn] ]]; then
        is_private="false"
    fi
    
    local response=$(curl -s -X POST \
        -H "Authorization: token $github_token" \
        -H "Accept: application/vnd.github.v3+json" \
        https://api.github.com/user/repos \
        -d "{\"name\":\"$repo_name\",\"private\":$is_private,\"auto_init\":false}")
    
    if echo "$response" | grep -q '"clone_url"'; then
        print_msg "$GREEN" "Repository created successfully on GitHub"
        log "Created GitHub repo via API: $repo_name"
        
        git config credential.helper store
        
        return 0
    else
        local error_msg=$(echo "$response" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
        if [ -n "$error_msg" ]; then
            print_msg "$RED" "Failed to create repository: $error_msg"
        else
            print_msg "$RED" "Failed to create repository:"
            echo "$response"
        fi
        log "Error: Failed to create GitHub repo: $error_msg"
        return 1
    fi
}

setup_github_remote() {
    local repo_name="$1"
    
    if git remote get-url origin > /dev/null 2>&1; then
        print_msg "Remote 'origin' already exists:"
        git remote get-url origin
        print_msg "Using existing remote."
        return
    fi
    
    print_msg "Setting up GitHub remote..."
    echo ""
    print_msg "Username:"
    read -r github_user
    
    if [ -z "$github_user" ]; then
        print_msg "$RED" "Username empty"
        exit 1
    fi
    
    print_msg "Create the repository on GitHub? (Y/n):"
    read -r auto_create
    auto_create=${auto_create:-y}
    
    if [[ "$auto_create" =~ ^[Yy] ]]; then
        if create_github_repo "$repo_name" "$github_user"; then
            local remote_url="https://github.com/${github_user}/${repo_name}.git"
            
            if ! git remote get-url origin > /dev/null 2>&1; then
                git remote add origin "$remote_url"
                print_msg "$GREEN" "Added GitHub remote: $remote_url"
                log "Added GitHub remote: $remote_url"
            fi
        else
            print_msg "$RED" "Failed to create repository automatically, do it manually: https://github.com/new. Press Enter when done"
            read -r
            
            local remote_url="https://github.com/${github_user}/${repo_name}.git"
            git remote add origin "$remote_url"
            print_msg "$GREEN" "Added GitHub remote: $remote_url"
            log "Added GitHub remote: $remote_url"
        fi
    else
        local remote_url="https://github.com/${github_user}/${repo_name}.git"
        
        print_msg  "Remote URL will be: $remote_url"
        print_msg "Make sure such repository exists on GitHub. Press Enter when done"
        read -r
        
        git remote add origin "$remote_url"
        print_msg "$GREEN" "Added GitHub remote: $remote_url"
        log "Added GitHub remote: $remote_url"
    fi
}

push_to_github() {
    print_msg "Pushing to GitHub..."
    
    local push_output=$(git push -u origin main 2>&1)
    local push_status=$?
    
    if [ $push_status -eq 0 ]; then
        print_msg "$GREEN" "Pushed to GitHub"
        log "Pushed to GitHub"
        return 0
    else
        print_msg "$RED" "Failed to push to GitHub. Check URLs, permissions, auth and stuff. Details: $LOG_FILE,"
        echo "$push_output"
        log "Error: Failed to push to GitHub - $push_output"
        
        print_msg "Continuing with local commits only. Fix issues for pushes"
        return 1
    fi
}

create_monitor_script() {
    local monitor_script="$1"
    
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

log "Monitor started: PID $$"

while true; do
    cd "$REPO_PATH" || {
        log "Error: Cannot access repository path $REPO_PATH"
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
                        log "Error: Failed to push to GitHub"
                    fi
                fi
            else
                log "Error: Failed to commit changes"
            fi
        fi
    fi
    
    sleep "$INTERVAL"
done
MONITOR_EOF
    
    chmod +x "$monitor_script"
}

start_gitbot() {
    local interval=""
    local enable_push="false"
    
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
    
    if [ -z "$interval" ] || ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 1 ]; then
        print_msg "$RED" "Invalid interval"
        exit 1
    fi
    
    local default_name=$(basename "$repo_path")
    print_msg "Repository name [$default_name]: "
    read -r repo_name
    repo_name=${repo_name:-$default_name}
    
    print_msg  "Starting gitbot for '$repo_name'..."
    
    init_git_repo "$repo_path" "$repo_name" "$enable_push"
    
    echo "$repo_path|$interval|$repo_name|$enable_push" > "$STATE_FILE"
    
    local monitor_script="$GITBOT_DIR/monitor_${PROJECT_ID}.sh"
    create_monitor_script "$monitor_script"
    
    nohup bash "$monitor_script" "$repo_path" "$interval" "$enable_push" "$LOG_FILE" > /dev/null 2>&1 &
    
    local pid=$!
    echo "$pid" > "$PID_FILE"
    
    sleep 1
    if ! ps -p "$pid" > /dev/null 2>&1; then
        print_msg "$RED" "Error: Failed to start monitoring process. Check log file: $LOG_FILE"
        rm -f "$PID_FILE"
        rm -f "$monitor_script"
        exit 1
    fi
    
    if [ ! -f "$GITBOT_DIR/restore_all.sh" ]; then
        setup_systemd_service
    fi
    
    print_msg "$GREEN" "gitbot started"
    echo ""
    print_msg  "  Repository: $repo_name"
    print_msg  "  Path: $repo_path"
    print_msg  "  Interval: ${interval}s"
    if [ "$enable_push" = "true" ]; then
        print_msg  "  GitHub push: enabled"
    else
        print_msg  "  GitHub push: disabled"
    fi
    print_msg  "  PID: $pid"
    echo ""
    print_msg "gitbot is now monitoring changes in the background."
    print_msg "Auto-restart on boot is enabled."
    print_msg "Use 'gitbot end' to halt"
    
    log "gitbot started: $repo_name at $repo_path, interval ${interval}s, push: $enable_push, PID $pid"
}

stop_gitbot() {
    if [ ! -f "$PID_FILE" ]; then
        echo "No gitbot running for this project"
        exit 0
    fi

    PID=$(cat "$PID_FILE")

    if kill "$PID" 2>/dev/null; then
        rm -f "$PID_FILE" "$STATE_FILE"
        echo "Stopped gitbot for project: $PWD"
        log "Stopped gitbot manually"
    else
        echo "Process dead; cleaning stale PID"
        rm -f "$PID_FILE"
    fi
}

show_status() {
    if [ ! -f "$PID_FILE" ]; then
        print_msg  "gitbot is not running."
        return
    fi
    
    local pid=$(cat "$PID_FILE")
    
    if ps -p "$pid" > /dev/null 2>&1; then
        if [ -f "$STATE_FILE" ]; then
            IFS='|' read -r repo_path interval repo_name enable_push < "$STATE_FILE"
            print_msg "$GREEN" "gitbot is running:"
            echo ""
            print_msg  "  Repository: $repo_name"
            print_msg  "  Path: $repo_path"
            print_msg  "  Interval: ${interval}s"
            if [ "$enable_push" = "true" ]; then
                print_msg  "  GitHub push: enabled"
            else
                print_msg  "  GitHub push: disabled"
            fi
            print_msg  "  PID: $pid"
        else
            print_msg "$GREEN" "gitbot is running. PID: $pid"
        fi
    else
        print_msg  "gitbot process not found"
        rm -f "$PID_FILE"
        rm -f "$STATE_FILE"
    fi
}

restart_gitbot() {
    if [ ! -f "$STATE_FILE" ]; then
        log "No state file found for restart"
        exit 0
    fi
    
    IFS='|' read -r repo_path interval repo_name enable_push < "$STATE_FILE"
    
    if [ ! -d "$repo_path" ]; then
        log "Error: Repository path $repo_path no longer exists"
        rm -f "$STATE_FILE"
        exit 1
    fi
    
    log "Restarting gitbot for $repo_name"
    
    cd "$repo_path" || exit 1
    
    local monitor_script="$GITBOT_DIR/monitor_${PROJECT_ID}.sh"
    create_monitor_script "$monitor_script"
    
    nohup bash "$monitor_script" "$repo_path" "$interval" "$enable_push" "$LOG_FILE" > /dev/null 2>&1 &
    
    local pid=$!
    echo "$pid" > "$PID_FILE"
    
    log "gitbot restarted. PID $pid"
}

main() {
    init_gitbot_dir
    check_git
    
    check_boot_and_restart
    
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
            echo "Simple bot for automated commits and pushes"
            echo ""
            echo "Usage:"
            echo "  gitbot start <seconds> [-h]  Start monitoring and auto-committing"
            echo "                               -h: Enable push to GitHub"
            echo "  gitbot end                   Stop monitoring this project"
            echo "  gitbot status                Show current status"
            echo ""
            echo "Example: gitbot start 600 -h   Monitor, commit and push current directory ./ to GitHub every 10 minutes"
            echo ""
            echo "Auto-restart on boot is enabled automatically."
            exit 1
            ;;
    esac
}

main "$@"
