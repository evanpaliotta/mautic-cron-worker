# Mautic Cron Worker - Runs segment/campaign updates WITHOUT email triggers
# Safe for staging - contacts get added to campaigns but NO emails sent
FROM mautic/mautic:5-apache

# Install cron and supervisord
USER root
RUN apt-get update && apt-get install -y cron supervisor && \
    rm -rf /var/lib/apt/lists/*

# Create cron job file
# NOTE: mautic:campaigns:trigger is INTENTIONALLY OMITTED to prevent email sending
COPY crontab /etc/cron.d/mautic-cron
RUN chmod 0644 /etc/cron.d/mautic-cron && \
    crontab /etc/cron.d/mautic-cron

# Create supervisord config
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Create a script to run mautic commands with proper environment
RUN echo '#!/bin/bash\n\
cd /var/www/html\n\
php bin/console "$@" --env=prod 2>&1\n' > /usr/local/bin/mautic && \
    chmod +x /usr/local/bin/mautic

# Create log directory
RUN mkdir -p /var/log/mautic && \
    chown -R www-data:www-data /var/log/mautic

# Start supervisord (runs cron daemon)
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
