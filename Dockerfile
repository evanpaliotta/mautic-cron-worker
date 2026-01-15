# Mautic Cron Worker - PRODUCTION MODE (v10 - AWS SES API support)
# Handles segment updates, campaign triggers, email sending, and daily backups
#
# FIXES APPLIED:
# v3: Creates local.php config before starting cron
# v4: Patches PendingEvent.php for PHP 8.x null metadata bug
# v5: Cron jobs now output to stdout for Railway visibility
# v6: CRITICAL - Fixed environment file quoting for values with spaces (e.g., "Evan Paliotta")
#     CRITICAL - Changed mautic:emails:send to messenger:consume email (Mautic 5 change)
# v7: Added email-stats.sh script for accurate email stats (bypasses buggy UI)
#     Hourly stats report in logs, can also run manually: railway run email-stats.sh
# v8: Added --bypass-locking to campaigns:trigger and campaigns:rebuild to prevent
#     stale lock files from blocking cron jobs (fixes "Script in progress" errors)
# v9: Added auto-republish script - campaigns keep getting unpublished by unknown cause
#     This cron job ensures all campaigns stay published every minute
# v10: Added symfony/amazon-mailer for SES API transport (Railway blocks SMTP ports)
#      Use DSN: ses+api://ACCESS_KEY:SECRET_KEY@default?region=us-east-2
FROM mautic/mautic:5-apache

# Install cron, supervisord, and mysql-client for backups
USER root
RUN apt-get update && apt-get install -y cron supervisor default-mysql-client && \
    rm -rf /var/lib/apt/lists/*

# Install AWS SES API mailer (Railway blocks SMTP ports 25/465/587)
# This enables ses+api:// DSN which uses HTTPS port 443
RUN mkdir -p /var/www/.composer/cache && \
    chown -R www-data:www-data /var/www/.composer

USER www-data
WORKDIR /var/www/html
ENV COMPOSER_HOME=/var/www/.composer
RUN composer require symfony/amazon-mailer \
    --no-interaction \
    --no-scripts \
    --prefer-dist \
    --optimize-autoloader && \
    composer dump-autoload --optimize --classmap-authoritative

USER root

# CRITICAL FIX: Patch files to handle null metadata (PHP 8.x compatibility)
# Bug: array_merge() fails when getMetadata() returns null on PHP 8.x
# Fix: Add null coalescing operator to ensure metadata is always an array
# Note: Mautic 5 uses /var/www/html/docroot/ as the web root
RUN echo "=== Patching Mautic for PHP 8.x null metadata compatibility ===" && \
    DOCROOT="/var/www/html/docroot" && \
    \
    # Patch 1: PendingEvent.php
    PENDING_EVENT="$DOCROOT/app/bundles/CampaignBundle/Event/PendingEvent.php" && \
    if [ -f "$PENDING_EVENT" ]; then \
        echo "Patching PendingEvent.php..." && \
        sed -i 's/\$metadata = \$log->getMetadata();/\$metadata = \$log->getMetadata() ?? [];/' "$PENDING_EVENT" && \
        echo "  - PendingEvent.php patched"; \
    fi && \
    \
    # Patch 2: LeadEventLog.php (Entity)
    LEAD_EVENT_LOG="$DOCROOT/app/bundles/CampaignBundle/Entity/LeadEventLog.php" && \
    if [ -f "$LEAD_EVENT_LOG" ]; then \
        echo "Patching LeadEventLog.php..." && \
        sed -i 's/array_merge(\$this->metadata,/array_merge(\$this->metadata ?? [],/' "$LEAD_EVENT_LOG" && \
        sed -i 's/array_merge(\$this->getMetadata(),/array_merge(\$this->getMetadata() ?? [],/' "$LEAD_EVENT_LOG" && \
        echo "  - LeadEventLog.php patched"; \
    fi && \
    \
    # Verify patches
    echo "Verifying patches..." && \
    grep -rn "getMetadata() ??" $DOCROOT/app/bundles/CampaignBundle/ 2>/dev/null | head -10 || true && \
    grep -rn "metadata ??" $DOCROOT/app/bundles/CampaignBundle/ 2>/dev/null | head -10 || true && \
    echo "=== Patching complete ==="

# Create log directories
RUN mkdir -p /var/log/mautic /var/log/supervisor && \
    chown -R www-data:www-data /var/log/mautic

# Create database health check script
RUN cat > /usr/local/bin/check-db.sh << 'CHECKDB'
#!/bin/bash
# Database health check with retry logic
# Returns 0 if database is reachable, 1 otherwise

MAX_RETRIES=${1:-3}
RETRY_DELAY=${2:-5}

# Source environment and export all variables for PHP
if [ -f /etc/mautic-env ]; then
    set -a  # Auto-export all variables
    source /etc/mautic-env
    set +a
fi

for i in $(seq 1 $MAX_RETRIES); do
    # Try to connect using PHP/PDO (same as Mautic uses)
    php -r "
    try {
        \$host = getenv('MAUTIC_DB_HOST') ?: 'localhost';
        \$port = getenv('MAUTIC_DB_PORT') ?: '3306';
        \$name = getenv('MAUTIC_DB_NAME') ?: 'mautic';
        \$user = getenv('MAUTIC_DB_USER') ?: 'root';
        \$pass = getenv('MAUTIC_DB_PASSWORD') ?: '';

        \$dsn = \"mysql:host=\$host;port=\$port;dbname=\$name\";
        \$options = [
            PDO::ATTR_TIMEOUT => 10,
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::MYSQL_ATTR_INIT_COMMAND => 'SET NAMES utf8mb4'
        ];

        \$pdo = new PDO(\$dsn, \$user, \$pass, \$options);
        \$pdo->query('SELECT 1');
        exit(0);
    } catch (Exception \$e) {
        fwrite(STDERR, 'DB check failed: ' . \$e->getMessage() . PHP_EOL);
        exit(1);
    }
    " 2>/dev/null

    if [ $? -eq 0 ]; then
        exit 0
    fi

    if [ $i -lt $MAX_RETRIES ]; then
        sleep $RETRY_DELAY
    fi
done

exit 1
CHECKDB

RUN chmod +x /usr/local/bin/check-db.sh

# Create email stats checker script (queries database directly for accurate counts)
RUN cat > /usr/local/bin/email-stats.sh << 'EMAILSTATS'
#!/bin/bash
# Email Stats Checker - queries email_stats table for accurate send counts
# Usage: email-stats.sh [--json]
# This bypasses Mautic UI stats which can be inaccurate due to caching

exec 1>/proc/1/fd/1 2>/proc/1/fd/2

# Source environment
if [ -f /etc/mautic-env ]; then
    set -a
    source /etc/mautic-env
    set +a
fi

JSON_OUTPUT=false
if [ "$1" == "--json" ]; then
    JSON_OUTPUT=true
fi

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Query the database directly for accurate email stats
STATS=$(php -r "
try {
    \$host = getenv('MAUTIC_DB_HOST') ?: 'localhost';
    \$port = getenv('MAUTIC_DB_PORT') ?: '3306';
    \$name = getenv('MAUTIC_DB_NAME') ?: 'mautic';
    \$user = getenv('MAUTIC_DB_USER') ?: 'root';
    \$pass = getenv('MAUTIC_DB_PASSWORD') ?: '';

    \$pdo = new PDO(\"mysql:host=\$host;port=\$port;dbname=\$name\", \$user, \$pass);
    \$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);

    // Get total emails sent (from email_stats table - source of truth)
    \$total = \$pdo->query('SELECT COUNT(*) FROM email_stats')->fetchColumn();

    // Get emails sent today
    \$today = \$pdo->query(\"SELECT COUNT(*) FROM email_stats WHERE DATE(date_sent) = CURDATE()\")->fetchColumn();

    // Get emails sent in last hour
    \$lastHour = \$pdo->query(\"SELECT COUNT(*) FROM email_stats WHERE date_sent >= DATE_SUB(NOW(), INTERVAL 1 HOUR)\")->fetchColumn();

    // Get emails read
    \$read = \$pdo->query('SELECT COUNT(*) FROM email_stats WHERE is_read = 1')->fetchColumn();

    // Get per-email breakdown
    \$perEmail = \$pdo->query('
        SELECT e.id, e.name,
               COUNT(es.id) as sent_actual,
               e.sent_count as sent_cached,
               SUM(CASE WHEN es.is_read = 1 THEN 1 ELSE 0 END) as read_count
        FROM emails e
        LEFT JOIN email_stats es ON e.id = es.email_id
        GROUP BY e.id, e.name, e.sent_count
        ORDER BY e.id
    ')->fetchAll(PDO::FETCH_ASSOC);

    echo json_encode([
        'timestamp' => '$TIMESTAMP',
        'total_sent' => (int)\$total,
        'sent_today' => (int)\$today,
        'sent_last_hour' => (int)\$lastHour,
        'total_read' => (int)\$read,
        'per_email' => \$perEmail
    ]);
} catch (Exception \$e) {
    echo json_encode(['error' => \$e->getMessage()]);
}
" 2>/dev/null)

if [ "$JSON_OUTPUT" = true ]; then
    echo "$STATS"
else
    echo "[$TIMESTAMP] EMAIL-STATS: Querying database for accurate counts..."
    echo "$STATS" | php -r "
        \$data = json_decode(file_get_contents('php://stdin'), true);
        if (isset(\$data['error'])) {
            echo \"  ERROR: \" . \$data['error'] . PHP_EOL;
            exit(1);
        }
        echo \"  Total Sent (all time): \" . \$data['total_sent'] . PHP_EOL;
        echo \"  Sent Today: \" . \$data['sent_today'] . PHP_EOL;
        echo \"  Sent Last Hour: \" . \$data['sent_last_hour'] . PHP_EOL;
        echo \"  Total Read: \" . \$data['total_read'] . PHP_EOL;
        echo \"  ---\" . PHP_EOL;
        echo \"  Per Email Breakdown:\" . PHP_EOL;
        foreach (\$data['per_email'] as \$email) {
            \$name = substr(\$email['name'], 0, 40);
            \$actual = \$email['sent_actual'];
            \$cached = \$email['sent_cached'];
            \$mismatch = \$actual != \$cached ? ' (MISMATCH!)' : '';
            echo \"    [\$email[id]] \$name: \$actual sent, \$email[read_count] read\$mismatch\" . PHP_EOL;
        }
    "
fi
EMAILSTATS

RUN chmod +x /usr/local/bin/email-stats.sh

# Create auto-republish script (ensures campaigns stay published)
RUN cat > /usr/local/bin/auto-republish.sh << 'AUTOREPUB'
#!/bin/bash
# Auto-republish campaigns - fixes unknown issue causing campaigns to unpublish
# Runs every minute to ensure campaigns stay active

exec 1>/proc/1/fd/1 2>/proc/1/fd/2

# Source environment
if [ -f /etc/mautic-env ]; then
    set -a
    source /etc/mautic-env
    set +a
fi

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Update campaigns via PHP/PDO
RESULT=$(php -r "
try {
    \$host = getenv('MAUTIC_DB_HOST') ?: 'localhost';
    \$port = getenv('MAUTIC_DB_PORT') ?: '3306';
    \$name = getenv('MAUTIC_DB_NAME') ?: 'mautic';
    \$user = getenv('MAUTIC_DB_USER') ?: 'root';
    \$pass = getenv('MAUTIC_DB_PASSWORD') ?: '';

    \$pdo = new PDO(\"mysql:host=\$host;port=\$port;dbname=\$name\", \$user, \$pass);
    \$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);

    // Count unpublished campaigns
    \$stmt = \$pdo->query('SELECT COUNT(*) FROM campaigns WHERE is_published = 0');
    \$unpublished = \$stmt->fetchColumn();

    if (\$unpublished > 0) {
        // Republish all campaigns
        \$pdo->exec('UPDATE campaigns SET is_published = 1');
        echo \"REPUBLISHED:\$unpublished\";
    } else {
        echo 'OK:0';
    }
} catch (Exception \$e) {
    echo 'ERROR:' . \$e->getMessage();
}
" 2>/dev/null)

# Only log if we had to republish something
if [[ "$RESULT" == REPUBLISHED:* ]]; then
    COUNT=${RESULT#REPUBLISHED:}
    echo "[$TIMESTAMP] AUTO-REPUBLISH: Fixed $COUNT unpublished campaign(s)"
fi
AUTOREPUB

RUN chmod +x /usr/local/bin/auto-republish.sh

# Create the Mautic command wrapper script with database health check and retry
RUN cat > /usr/local/bin/mautic-cron.sh << 'MAUTICCRON'
#!/bin/bash
# Mautic Cron Wrapper - with database health check and retry logic
# Usage: mautic-cron.sh <command> [args...]

# Redirect all output to the main process's stdout/stderr (PID 1)
exec 1>/proc/1/fd/1 2>/proc/1/fd/2

# Source the environment file and export for PHP
if [ -f /etc/mautic-env ]; then
    set -a  # Auto-export all variables
    source /etc/mautic-env
    set +a
fi

# Change to Mautic directory
cd /var/www/html

# Get command name for logging
CMD_NAME=$(basename "$1" 2>/dev/null || echo "unknown")
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Log start
echo "[$TIMESTAMP] CRON: Starting $CMD_NAME $@"

# Check database connectivity with retry (5 attempts, 3 second delay)
if ! /usr/local/bin/check-db.sh 5 3; then
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$TIMESTAMP] CRON: SKIPPED $CMD_NAME - database unreachable after 5 attempts"
    exit 1
fi

# Build the full command string
FULL_CMD="php bin/console $* --env=prod"

# Run the command as www-data with timeout (5 minutes max)
timeout 300 su -s /bin/bash www-data -c "$FULL_CMD" 2>&1
EXIT_CODE=$?

# Log completion
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
if [ $EXIT_CODE -eq 0 ]; then
    echo "[$TIMESTAMP] CRON: Completed $CMD_NAME (success)"
elif [ $EXIT_CODE -eq 124 ]; then
    echo "[$TIMESTAMP] CRON: TIMEOUT $CMD_NAME (exceeded 5 minutes)"
else
    echo "[$TIMESTAMP] CRON: Completed $CMD_NAME (exit code: $EXIT_CODE)"
fi

exit $EXIT_CODE
MAUTICCRON

RUN chmod +x /usr/local/bin/mautic-cron.sh

# Create cron job file using proper /etc/cron.d/ format
# IMPORTANT: Do NOT use 'crontab' command - /etc/cron.d/ files are read directly by cron daemon
RUN cat > /etc/cron.d/mautic-cron << 'CRONTAB'
# Mautic Cron Jobs - PRODUCTION MODE
# Output goes to stdout via wrapper script for Railway visibility
# Format: minute hour day month weekday user command

# =============================================================================
# SEGMENT & CAMPAIGN PROCESSING (every 2 minutes for faster pickup)
# =============================================================================
# Update contact segments
*/2 * * * * root /usr/local/bin/mautic-cron.sh mautic:segments:update

# Rebuild campaigns (add contacts from segments)
*/2 * * * * root /usr/local/bin/mautic-cron.sh mautic:campaigns:rebuild --bypass-locking

# =============================================================================
# EMAIL SENDING - RATE LIMITED (1 email per minute for deliverability)
# =============================================================================
# Trigger campaign actions (schedules emails from campaigns)
* * * * * root /usr/local/bin/mautic-cron.sh mautic:campaigns:trigger --batch-limit=1 --bypass-locking

# MAUTIC 5 CHANGE: messenger:consume replaces mautic:emails:send
# Process queued emails via Symfony Messenger (time-limit=50 prevents overlap)
* * * * * root /usr/local/bin/mautic-cron.sh messenger:consume email --time-limit=50 --limit=1

# Send queued messages
* * * * * root /usr/local/bin/mautic-cron.sh mautic:messages:send

# Send broadcast emails (rate limited)
* * * * * root /usr/local/bin/mautic-cron.sh mautic:broadcasts:send --limit=1

# Import contacts from queue
*/5 * * * * root /usr/local/bin/mautic-cron.sh mautic:import

# =============================================================================
# MAINTENANCE (less frequent)
# =============================================================================
# Update max mind geo data (weekly on Sunday at 3 AM)
0 3 * * 0 root /usr/local/bin/mautic-cron.sh mautic:iplookup:download

# Clean up old data (daily at 4 AM)
0 4 * * * root /usr/local/bin/mautic-cron.sh mautic:maintenance:cleanup --days-old=365

# =============================================================================
# MONITORING - email stats and heartbeat
# =============================================================================
# Email stats report (hourly) - queries database for accurate counts
0 * * * * root /usr/local/bin/email-stats.sh >/proc/1/fd/1 2>&1

# Heartbeat - proves cron is running (every 5 minutes)
*/5 * * * * root echo "[$(date '+\%Y-\%m-\%d \%H:\%M:\%S')] HEARTBEAT: Cron daemon is alive" >/proc/1/fd/1 2>&1

# Auto-republish campaigns (workaround for unknown unpublishing bug)
* * * * * root /usr/local/bin/auto-republish.sh

# Empty line required at end
CRONTAB

RUN chmod 0644 /etc/cron.d/mautic-cron

# Create supervisord config that captures cron output
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Create entrypoint script that sets up local.php before starting cron
RUN cat > /usr/local/bin/cron-entrypoint.sh << 'CRONENTRY'
#!/bin/bash
# NOTE: Do NOT use 'set -e' here - Mautic commands may return non-zero codes
# even on success, which would cause the script to exit before supervisord starts
echo "=== Mautic Cron Worker Starting (v9 - auto-republish campaigns) ==="
echo "    Fixes: env quoting, Mautic 5 messenger:consume, stale lock bypass"
echo "    New: auto-republish.sh keeps campaigns published (runs every minute)"

# Create local.php using PHP to properly read environment variables
LOCAL_PHP="/var/www/html/config/local.php"
mkdir -p /var/www/html/config

echo "Creating Mautic local.php configuration via PHP..."
php -r "
\$config = [
    'db_driver' => 'pdo_mysql',
    'db_host' => getenv('MAUTIC_DB_HOST'),
    'db_port' => getenv('MAUTIC_DB_PORT') ?: '3306',
    'db_name' => getenv('MAUTIC_DB_NAME'),
    'db_user' => getenv('MAUTIC_DB_USER'),
    'db_password' => getenv('MAUTIC_DB_PASSWORD'),
    'db_table_prefix' => null,
    'db_backup_tables' => true,
    'db_backup_prefix' => 'bak_',
    'mailer_dsn' => getenv('MAUTIC_MAILER_DSN'),
    'mailer_from_name' => getenv('MAUTIC_MAILER_FROM_NAME'),
    'mailer_from_email' => getenv('MAUTIC_MAILER_FROM_EMAIL'),
    'site_url' => 'https://mautic-production-3ceb.up.railway.app',
    'secret_key' => 'mautic_cron_worker_secret_key_199os',
];

echo 'Database host: ' . \$config['db_host'] . PHP_EOL;
echo 'Database name: ' . \$config['db_name'] . PHP_EOL;
echo 'Mailer DSN set: ' . (empty(\$config['mailer_dsn']) ? 'NO' : 'YES') . PHP_EOL;

\$content = '<?php' . PHP_EOL . 'return ' . var_export(\$config, true) . ';' . PHP_EOL;
file_put_contents('$LOCAL_PHP', \$content);
echo 'Configuration written to $LOCAL_PHP' . PHP_EOL;
"

chown www-data:www-data "$LOCAL_PHP"
chmod 644 "$LOCAL_PHP"

# Save environment variables for cron jobs to use
# CRITICAL FIX: Properly quote values to handle spaces (e.g., "Evan Paliotta")
# and values containing = signs (e.g., database URLs)
echo "Saving environment variables for cron..."
printenv | grep -E '^(MAUTIC_|MYSQL_|PATH=)' | sed 's/^\([^=]*\)=\(.*\)$/export \1="\2"/' > /etc/mautic-env
chmod 644 /etc/mautic-env
echo "Environment file created with $(wc -l < /etc/mautic-env) variables"

# CRITICAL: Verify environment file can be sourced without errors
echo "Verifying environment file syntax..."
if bash -n /etc/mautic-env 2>&1; then
    echo "  ✓ Environment file syntax OK"
else
    echo "  ✗ Environment file has syntax errors! Contents:"
    cat /etc/mautic-env
    exit 1
fi

# CRITICAL: Wait for database to be available before proceeding
echo ""
echo "=== Waiting for database to be available ==="
MAX_WAIT=120
WAITED=0
while ! /usr/local/bin/check-db.sh 1 1 2>/dev/null; do
    WAITED=$((WAITED + 5))
    if [ $WAITED -ge $MAX_WAIT ]; then
        echo "ERROR: Database not available after ${MAX_WAIT}s - starting anyway (cron will retry)"
        break
    fi
    echo "Waiting for database... (${WAITED}s/${MAX_WAIT}s)"
    sleep 5
done

if [ $WAITED -lt $MAX_WAIT ]; then
    echo "Database connection: SUCCESS"
fi

# Clear Mautic cache
echo ""
echo "Clearing Mautic cache..."
rm -rf /var/www/html/var/cache/* 2>/dev/null || true
su -s /bin/bash www-data -c "php /var/www/html/bin/console cache:clear --env=prod --no-warmup" 2>&1 || echo "Cache clear done"

# Run full campaign processing sequence on startup (with DB check)
echo ""
echo "=== Running initial campaign processing ==="

if /usr/local/bin/check-db.sh 3 2; then
    echo "Running segment update..."
    su -s /bin/bash www-data -c "php /var/www/html/bin/console mautic:segments:update --env=prod" 2>&1 || echo "Segment update done"

    echo "Running campaign rebuild..."
    su -s /bin/bash www-data -c "php /var/www/html/bin/console mautic:campaigns:rebuild --env=prod" 2>&1 || echo "Campaign rebuild done"

    echo "Running campaign trigger..."
    su -s /bin/bash www-data -c "php /var/www/html/bin/console mautic:campaigns:trigger --env=prod" 2>&1 || echo "Campaign trigger done"
else
    echo "SKIPPED initial processing - database not available (cron will handle it)"
fi

echo ""
echo "=== Starting supervisord ==="
echo "Services: cron (every minute), db-watchdog (every 60s), keepalive (every 30s)"
echo "Each cron job checks DB connectivity before running (5 retries, 3s delay)"
echo "You should see HEARTBEAT messages every 5 minutes to confirm cron is working"
echo ""
exec /usr/bin/supervisord -n -c /etc/supervisor/conf.d/supervisord.conf
CRONENTRY

RUN chmod +x /usr/local/bin/cron-entrypoint.sh

# Use custom entrypoint that creates config before starting cron
ENTRYPOINT ["/usr/local/bin/cron-entrypoint.sh"]
CMD []
