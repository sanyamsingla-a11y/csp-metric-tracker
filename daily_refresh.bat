@echo off
cd /d "C:\Users\Sanyam Singla\Downloads\claude_context_files\csp-metric-tracker"

echo [%date% %time%] Starting CSP Metric Tracker refresh... >> refresh.log

python refresh_workflows.py >> refresh.log 2>&1
if %errorlevel% neq 0 (
    echo [%date% %time%] ERROR: refresh_workflows.py failed >> refresh.log
    exit /b 1
)

git add workflow_data.js
git commit -m "daily refresh %date%" --author="Sanyam Singla <sanyam.singla@wiom.in>"
git push origin master >> refresh.log 2>&1

echo [%date% %time%] Refresh complete, pushed to GitHub >> refresh.log
