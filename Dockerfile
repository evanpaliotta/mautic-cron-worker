# Mautic Cron Worker - PRODUCTION MODE
# Handles segment updates, campaign triggers, email sending, and daily backups
# Fixed: Creates local.php config before starting cron
# Fixed: Patches PendingEvent.php for PHP 8.x null metadata bug
# Fixed: Cron jobs now output to stdout for Railway visibility
FROM mautic/mautic:5-apache

# Install cron, supervisord, and mysql-client for backups
USER root
RUN apt-get update && apt-get install -y cron supervisor default-mysql-client && \
    rm -rf /var/lib/apt/lists/*

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

# Create the Mautic command wrapper script that sources environment and logs to main process stdout
RUN cat > /usr/local/bin/mautic-cron.sh << 'MAUTICCRON'
#!/bin/bash
# Mautic Cron Wrapper - ensures environment is loaded and output goes to PID 1's stdout
# Usage: mautic-cron.sh <command> [args...]

# Redirect all output to the main process's stdout/stderr (PID 1)
exec 1>/proc/1/fd/1 2>/proc/1/fd/2

# Source the environment file if it exists
if [ -f /etc/mautic-env ]; then
    source /etc/mautic-env
fi

# Change to Mautic directory
cd /var/www/html

# Get command name for logging
CMD_NAME=$(basename "$1" 2>/dev/null || echo "unknown")
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Log start
echo "[$TIMESTAMP] CRON: Starting $CMD_NAME $@"

# Run the command as www-data
su -s /bin/bash www-data -c "php bin/console $@ --env=prod" 2>&1
EXIT_CODE=$?

# Log completion
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
if [ $EXIT_CODE -eq 0 ]; then
    echo "[$TIMESTAMP] CRON: Completed $CMD_NAME (success)"
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
*/2 * * * * root /usr/local/bin/mautic-cron.sh mautic:campaigns:rebuild

# =============================================================================
# EMAIL SENDING - RATE LIMITED (every minute)
# =============================================================================
# Trigger campaign actions (sends scheduled emails)
* * * * * root /usr/local/bin/mautic-cron.sh mautic:campaigns:trigger --limit=5

# Send queued messages
* * * * * root /usr/local/bin/mautic-cron.sh mautic:messages:send --limit=5

# Send scheduled emails
* * * * * root /usr/local/bin/mautic-cron.sh mautic:emails:send --limit=5

# Send broadcast emails
* * * * * root /usr/local/bin/mautic-cron.sh mautic:broadcasts:send --limit=5

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
# HEARTBEAT - proves cron is running (every 5 minutes)
# =============================================================================
*/5 * * * * root echo "[$(date '+\%Y-\%m-\%d \%H:\%M:\%S')] HEARTBEAT: Cron daemon is alive" >/proc/1/fd/1 2>&1

# Empty line required at end
CRONTAB

RUN chmod 0644 /etc/cron.d/mautic-cron

# Create supervisord config that captures cron output
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Create entrypoint script that sets up local.php before starting cron
RUN cat > /usr/local/bin/cron-entrypoint.sh << 'CRONENTRY'
#!/bin/bash
set -e
echo "=== Mautic Cron Worker Starting (v3 - with visible cron output) ==="

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
echo "Saving environment variables for cron..."
printenv | grep -E '^(MAUTIC_|MYSQL_|PATH=)' > /etc/mautic-env
chmod 644 /etc/mautic-env

# Clear Mautic cache
echo "Clearing Mautic cache..."
rm -rf /var/www/html/var/cache/* 2>/dev/null || true
su -s /bin/bash www-data -c "php /var/www/html/bin/console cache:clear --env=prod --no-warmup" 2>&1 || echo "Cache clear done"

# Test database connection
echo "Testing database connection..."
su -s /bin/bash www-data -c "php /var/www/html/bin/console doctrine:query:sql 'SELECT 1' --env=prod" 2>&1 && echo "Database connection: SUCCESS" || echo "Database connection: FAILED"

# Run full campaign processing sequence on startup
echo ""
echo "=== Running initial campaign processing ==="
echo "Running segment update..."
su -s /bin/bash www-data -c "php /var/www/html/bin/console mautic:segments:update --env=prod" 2>&1 || echo "Segment update done"

echo "Running campaign rebuild..."
su -s /bin/bash www-data -c "php /var/www/html/bin/console mautic:campaigns:rebuild --env=prod" 2>&1 || echo "Campaign rebuild done"

echo "Running campaign trigger..."
su -s /bin/bash www-data -c "php /var/www/html/bin/console mautic:campaigns:trigger --env=prod" 2>&1 || echo "Campaign trigger done"

echo ""
echo "=== Starting supervisord (cron will run every minute) ==="
echo "You should see HEARTBEAT messages every 5 minutes to confirm cron is working"
echo ""
exec /usr/bin/supervisord -n -c /etc/supervisor/conf.d/supervisord.conf
CRONENTRY

RUN chmod +x /usr/local/bin/cron-entrypoint.sh

# Use custom entrypoint that creates config before starting cron
ENTRYPOINT ["/usr/local/bin/cron-entrypoint.sh"]
CMD []
