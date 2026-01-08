# Mautic Cron Worker - PRODUCTION MODE
# Handles segment updates, campaign triggers, email sending, and daily backups
# Fixed: Creates local.php config before starting cron
# Fixed: Patches PendingEvent.php for PHP 8.x null metadata bug
FROM mautic/mautic:5-apache

# Install cron, supervisord, and mysql-client for backups
USER root
RUN apt-get update && apt-get install -y cron supervisor default-mysql-client && \
    rm -rf /var/lib/apt/lists/*

# CRITICAL FIX: Patch PendingEvent.php to handle null metadata
# Bug: array_merge() fails when $log->getMetadata() returns null on PHP 8.x
# Fix: Add null coalescing operator to ensure metadata is always an array
# Note: Mautic 5 uses /var/www/html/docroot/ as the web root
RUN PENDING_EVENT="/var/www/html/docroot/app/bundles/CampaignBundle/Event/PendingEvent.php" && \
    if [ -f "$PENDING_EVENT" ]; then \
        echo "Patching PendingEvent.php for null metadata bug..." && \
        sed -i 's/\$metadata = \$log->getMetadata();/\$metadata = \$log->getMetadata() ?? [];/' "$PENDING_EVENT" && \
        echo "Patch applied successfully" && \
        grep -n "getMetadata" "$PENDING_EVENT" | head -5; \
    else \
        echo "WARNING: PendingEvent.php not found at expected location"; \
        find /var/www/html -name "PendingEvent.php" 2>/dev/null; \
    fi

# Create cron job file (email sending ENABLED, daily backups at 2 AM)
COPY crontab /etc/cron.d/mautic-cron
RUN chmod 0644 /etc/cron.d/mautic-cron && \
    crontab /etc/cron.d/mautic-cron

# Create supervisord config
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Create log directories
RUN mkdir -p /var/log/mautic /var/log/supervisor && \
    chown -R www-data:www-data /var/log/mautic

# Create entrypoint script that sets up local.php before starting cron
RUN cat > /usr/local/bin/cron-entrypoint.sh << 'CRONENTRY'
#!/bin/bash
echo "=== Mautic Cron Worker Starting (v2) ==="

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

# Clear Mautic cache
echo "Clearing Mautic cache..."
rm -rf /var/www/html/var/cache/* 2>/dev/null || true
su -s /bin/bash www-data -c "php /var/www/html/bin/console cache:clear --env=prod --no-warmup" 2>&1 || echo "Cache clear done"

# Test database connection
echo "Testing database connection..."
su -s /bin/bash www-data -c "php /var/www/html/bin/console doctrine:query:sql 'SELECT 1' --env=prod" 2>&1 && echo "Database connection: SUCCESS" || echo "Database connection: FAILED"

# Run initial campaign trigger to process pending events
echo "Running initial campaign trigger..."
su -s /bin/bash www-data -c "php /var/www/html/bin/console mautic:campaigns:trigger --env=prod" 2>&1 || echo "Initial trigger done"

echo "=== Starting supervisord ==="
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
CRONENTRY

RUN chmod +x /usr/local/bin/cron-entrypoint.sh

# Use custom entrypoint that creates config before starting cron
ENTRYPOINT ["/usr/local/bin/cron-entrypoint.sh"]
CMD []
